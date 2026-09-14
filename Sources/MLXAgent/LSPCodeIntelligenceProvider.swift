import Foundation

// MARK: - v0.30 LSP backend (persistent JSON-RPC client + adapter)
//
// Real SourceKit-LSP integration, proven against the locally installed
// server (initialize/didOpen/documentSymbol/prepareRename/rename verified
// 2026-09-14 on Xcode toolchain sourcekit-lsp). NOT shell-grep:
// persistent Process, stdin/stdout pipes, Content-Length framing, request
// IDs, pending continuations with timeouts, notifications, stderr drain,
// initialize/initialized/shutdown/exit, root URI, negotiated encoding.
//
// Document sync carries EXACT revision content; per-document version is the
// EditEngine revision number (monotonic per path). A rename whose server
// state predates the requested revision throws .staleBasis.

/// Parsed diagnostic (Sendable; produced inside actor isolation).
struct LSPDiagnostic: Sendable {
    var version: Int
    var message: String
    var severity: String
}

enum LSPError: Error, Sendable {
    case notStarted
    case timeout(String)
    case serverError(code: Int, message: String)
    case protocolError(String)
    case cancelled
}

// MARK: - Persistent connection (actor)

actor LSPConnection {
    private var process: Process?
    private var input: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var readBuffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var diagnostics: [String: (version: Int, items: [[String: Any]])] = [:]

    /// Diagnostics parsed into Sendable values inside actor isolation.
    func cachedDiagnostics(uri: String) -> [LSPDiagnostic] {
        guard let entry = diagnostics[uri] else { return [] }
        return entry.items.compactMap { item in
            guard let message = item["message"] as? String else { return nil }
            let severity = (item["severity"] as? Int).map { String($0) } ?? "unknown"
            return LSPDiagnostic(version: entry.version, message: message, severity: severity)
        }
    }

    func start(executable: URL, workingDirectory: URL) throws {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = []
        process.currentDirectoryURL = workingDirectory
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        self.outputHandle = outHandle
        self.errorHandle = errHandle
        // Classic readabilityHandler pump: FileHandle.AsyncBytes was
        // observed to stall pipe data (bytes sat 40s+ undelivered).
        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.received(data) }
        }
        errHandle.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    /// Actor-owned reassembly: appends bytes, extracts complete frames.
    private func received(_ data: Data) {
        if data.isEmpty {
            failAll(LSPError.cancelled)
            return
        }
        readBuffer.append(data)
        while let message = Self.extractMessage(from: &readBuffer) {
            deliver(message)
        }
    }

    private static func extractMessage(from buffer: inout Data) -> [String: Any]? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) ?? ""
        var length: Int?
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let length else { return nil }
        let bodyStart = separator.upperBound
        guard buffer.count >= bodyStart + length else { return nil }
        let body = buffer[bodyStart..<(bodyStart + length)]
        buffer.removeSubrange(..<(bodyStart + length))
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// Single response contract: deliver settles the raw result value
    /// EXACTLY ONCE (JSON-encoded as-is, no envelope). Query code decodes
    /// with lspResult() and reads the value directly — never a second
    /// ["result"] lookup.
    private func deliver(_ message: [String: Any]) {
        if let id = message["id"] as? Int, pending[id] != nil {
            if let error = message["error"] as? [String: Any] {
                settle(id: id, with: .failure(LSPError.serverError(
                    code: error["code"] as? Int ?? -1,
                    message: error["message"] as? String ?? "unknown"
                )))
            } else if message.keys.contains("result") {
                // Top-level null included: fragmentsAllowed covers it.
                let value = message["result"]!
                if value is NSNull {
                    settle(id: id, with: .success(Data("null".utf8)))
                } else if let data = try? JSONSerialization.data(
                    withJSONObject: value,
                    options: [.sortedKeys, .fragmentsAllowed]
                ) {
                    settle(id: id, with: .success(data))
                } else {
                    settle(id: id, with: .failure(LSPError.protocolError("unencodable result")))
                }
            } else {
                settle(id: id, with: .failure(LSPError.protocolError("missing result")))
            }
        } else if (message["method"] as? String) == "textDocument/publishDiagnostics",
                  let params = message["params"] as? [String: Any],
                  let uri = params["uri"] as? String {
            diagnostics[uri] = (
                version: params["version"] as? Int ?? -1,
                items: params["diagnostics"] as? [[String: Any]] ?? []
            )
        }
    }

    /// Exactly-once settlement shared by responses, timeouts and close.
    /// A late response after a timeout is dropped, never double-resumed.
    private func settle(id: Int, with result: Result<Data, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func failAll(_ error: Error) {
        let waiting = pending.keys
        for id in waiting {
            settle(id: id, with: .failure(error))
        }
    }

    /// Raw response body (Sendable): JSON encoding of the result value
    /// itself (no envelope; decode with lspResult()). The id is reserved
    /// atomically in actor isolation before any suspension, so onCancel can
    /// always settle. Pending + timeout are armed BEFORE the write, inside
    /// the actor, so a fast answer can never arrive unregistered — and a
    /// failed write settles instead of hanging. Exactly one suspension.
    func request(method: String, params: [String: Any], timeoutSeconds: Double = 20) async throws -> Data {
        let id: Int = nextID
        nextID += 1
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        payload["params"] = params
        let body = try JSONSerialization.data(withJSONObject: payload)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.sendAndWait(
                        id: id, continuation: continuation,
                        timeout: timeoutSeconds, method: method, framed: framed
                    )
                }
            }
        } onCancel: {
            Task { await self.settle(id: id, with: .failure(CancellationError())) }
        }
    }

    /// Armed send: register pending + timeout FIRST, then write.
    /// Write failure settles immediately (no hang, no leak).
    private func sendAndWait(
        id: Int,
        continuation: CheckedContinuation<Data, Error>,
        timeout: Double,
        method: String,
        framed: Data
    ) {
        register(id: id, continuation: continuation, timeout: timeout, method: method)
        do {
            guard let input else { throw LSPError.notStarted }
            try input.write(contentsOf: framed)
        } catch {
            settle(id: id, with: .failure(error))
        }
    }

    private func register(
        id: Int,
        continuation: CheckedContinuation<Data, Error>,
        timeout: Double,
        method: String
    ) {
        pending[id] = continuation
        timeouts[id] = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self.settle(id: id, with: .failure(LSPError.timeout(method)))
            } catch {}
        }
    }

    func notify(method: String, params: [String: Any]) throws {
        guard let input else { throw LSPError.notStarted }
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try input.write(contentsOf: framed)
    }

    func close() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
        readBuffer.removeAll()
        for task in timeouts.values {
            task.cancel()
        }
        timeouts.removeAll()
        failAll(LSPError.cancelled)
        try? input?.close()
        input = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
    }
}

// MARK: - SourceKit-LSP backed provider

/// LSP adapter. Converts server line/character (negotiated encoding,
/// default UTF-16) to UTF-8 byte offsets on EXACT snapshot content.
/// Never reads files, never writes, never touches runtime state.
// MARK: - Envelope decoding (caller side, Sendable-safe)

/// Decode a raw LSP result body (see request contract above).
/// Returns nil for JSON null / unparseable bodies. Callers cast the value
/// directly to the expected shape — never a second ["result"] lookup.
func lspResult(_ data: Data) -> Any? {
    guard let value = try? JSONSerialization.jsonObject(
        with: data, options: [.fragmentsAllowed]
    ), !(value is NSNull) else {
        return nil
    }
    return value
}

/// Dict-shaped result (capabilities, edits, ranges).
func lspDecodeDict(_ data: Data) -> [String: Any] {
    lspResult(data) as? [String: Any] ?? [:]
}

final class LSPCodeIntelligenceProvider: CodeIntelligenceProvider, @unchecked Sendable {
    let providerID = CodeIntelligenceProviderID("lsp-sourcekit")
    let capabilities = CodeIntelligenceCapabilities.full

    private let root: URL
    private let executable: URL
    private let lock = NSLock()
    private let initializationTimeout: Double
    private var connection: LSPConnection?
    private final class BootBox {
        let task: Task<LSPConnection, Error>
        init(_ task: Task<LSPConnection, Error>) { self.task = task }
    }
    private var starting: BootBox?
    private var initializedEncoding: LSPPositionEncoding = .utf16
    private var syncedVersions: [String: Int] = [:]
    private var syncedBasis: [String: ArtifactRevisionID] = [:]

    init?(projectRoot: URL, executable: URL? = nil, initializationTimeout: Double = 90) {
        self.initializationTimeout = initializationTimeout
        let resolved: URL?
        if let executable {
            resolved = executable
        } else {
            let found = Process()
            found.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            found.arguments = ["--find", "sourcekit-lsp"]
            let pipe = Pipe()
            found.standardOutput = pipe
            found.standardError = FileHandle.nullDevice
            guard (try? found.run()) != nil else { return nil }
            found.waitUntilExit()
            guard found.terminationStatus == 0 else { return nil }
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            resolved = output.map { URL(fileURLWithPath: $0) }
        }
        guard let resolved,
              FileManager.default.isExecutableFile(atPath: resolved.path) else {
            return nil
        }
        self.root = projectRoot
        self.executable = resolved
    }

    // MARK: lifecycle

    // Made internal for the opt-in integration scenario.
    // Serialized: concurrent callers share one in-flight startup
    // (duplicate servers on slow cold init was observed live).
    func ensureStarted() async throws -> LSPConnection {
        if let connection = lock.withLock({ connection }) {
            return connection
        }
        let box: BootBox = lock.withLock {
            if let starting {
                return starting
            }
            let box = BootBox(Task { try await self.boot() })
            starting = box
            return box
        }
        do {
            let connection = try await box.task.value
            lock.withLock {
                if self.starting === box { self.starting = nil }
            }
            return connection
        } catch {
            lock.withLock {
                if self.starting === box { self.starting = nil }
            }
            throw error
        }
    }

    private func boot() async throws -> LSPConnection {
        let connection = LSPConnection()
        do {
            try await bootInner(connection)
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    private func bootInner(_ connection: LSPConnection) async throws -> LSPConnection {
        try await connection.start(executable: executable, workingDirectory: root)
        let rawInit = try await connection.request(method: "initialize", params: [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "capabilities": [
                "textDocument": ["publishDiagnostics": ["relatedInformation": true]],
                "general": ["positionEncodings": ["utf-8", "utf-16"]]
            ],
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]]
        ], timeoutSeconds: initializationTimeout)
        let result = lspDecodeDict(rawInit)
        if let caps = result["capabilities"] as? [String: Any],
           let encoding = caps["positionEncoding"] as? String,
           let parsed = LSPPositionEncoding(rawValue: encoding) {
            initializedEncoding = parsed
        }
        try await connection.notify(method: "initialized", params: [:])
        lock.withLock { self.connection = connection }
        return connection
    }

    private func connectionIfStarted() -> LSPConnection? {
        lock.withLock { connection }
    }

    func shutdown() async {
        guard let connection = connectionIfStarted() else { return }
        _ = try? await connection.request(method: "shutdown", params: [:], timeoutSeconds: 10)
        try? await connection.notify(method: "exit", params: [:])
        await connection.close()
        lock.withLock {
            self.connection = nil
            syncedVersions.removeAll()
        }
    }

    // MARK: sync (exact revision content, version = revision number)

    private func sync(_ snapshot: CodeDocumentSnapshot, revisionNumber: Int) async throws -> LSPConnection {
        let connection = try await ensureStarted()
        let uri = root.appendingPathComponent(snapshot.path).absoluteString
        let known = lock.withLock { syncedVersions[uri] }
        if known == nil {
            try await connection.notify(method: "textDocument/didOpen", params: [
                "textDocument": [
                    "uri": uri,
                    "languageId": snapshot.languageID,
                    "version": revisionNumber,
                    "text": snapshot.content
                ] as [String: Any]
            ])
            lock.withLock {
                syncedVersions[uri] = revisionNumber
                syncedBasis[uri] = snapshot.revision
            }
        } else if known != revisionNumber {
            try await connection.notify(method: "textDocument/didChange", params: [
                "textDocument": ["uri": uri, "version": revisionNumber],
                "contentChanges": [["text": snapshot.content]]
            ])
            lock.withLock {
                syncedVersions[uri] = revisionNumber
                syncedBasis[uri] = snapshot.revision
            }
        }
        return connection
    }

    // MARK: queries

    func query(_ query: SemanticQuery) async throws -> SemanticQueryResult {
        switch query {
        case .documentSymbols(let snapshot):
            let connection = try await sync(snapshot, revisionNumber: snapshotRevisionNumber(snapshot))
            let rawSymbols = try await connection.request(method: "textDocument/documentSymbol", params: [
                "textDocument": ["uri": documentURI(snapshot.path)]
            ])
            let symbols = try Self.convertSymbols(
                lspResult(rawSymbols), path: snapshot.path,
                revision: snapshot.revision, content: snapshot.content,
                encoding: initializedEncoding
            )
            return .symbols(symbols)

        case .workspaceSymbols(let pattern):
            let connection = try await ensureStarted()
            let rawWS = try await connection.request(method: "workspace/symbol", params: ["query": pattern])
            var out: [UnresolvedSymbol] = []
            if let items = lspResult(rawWS) as? [[String: Any]] {
                for item in items {
                    if let symbol = Self.convertPendingSymbol(item) {
                        out.append(symbol)
                    }
                }
            }
            return .workspaceSymbols(out)

        case .definition(let snapshot, let byteOffset):
            let (connection, position) = try await syncAndPosition(snapshot, byteOffset: byteOffset)
            let rawDef = try await connection.request(method: "textDocument/definition", params: [
                "textDocument": ["uri": documentURI(snapshot.path)],
                "position": ["line": position.line, "character": position.character]
            ])
            return .locations(Self.convertPendingLocations(
                lspResult(rawDef), root: root
            ))

        case .references(let snapshot, let byteOffset):
            let (connection, position) = try await syncAndPosition(snapshot, byteOffset: byteOffset)
            let rawRefs = try await connection.request(method: "textDocument/references", params: [
                "textDocument": ["uri": documentURI(snapshot.path)],
                "position": ["line": position.line, "character": position.character],
                "context": ["includeDeclaration": true]
            ])
            return .locations(Self.convertPendingLocations(
                lspResult(rawRefs), root: root
            ))

        case .prepareRename(let snapshot, let byteOffset):
            let (connection, position) = try await syncAndPosition(snapshot, byteOffset: byteOffset)
            do {
                let rawPrep = try await connection.request(method: "textDocument/prepareRename", params: [
                    "textDocument": ["uri": documentURI(snapshot.path)],
                    "position": ["line": position.line, "character": position.character]
                ])
                let result = lspDecodeDict(rawPrep)
                // Single contract: result IS the prepare value
                // ({range} or {placeholder, range}), read directly.
                if let range = result["range"] as? [String: Any] {
                    let span = Self.convertRange(
                        range, content: snapshot.content,
                        revision: snapshot.revision, encoding: initializedEncoding
                    )
                    return .renameRange(span)
                }
                return .renameRange(nil)
            } catch {
                // Server without prepare support: fall back to the
                // engine-provided symbol span (never fail the pipeline here).
                return .renameRange(nil)
            }

        case .rename(let snapshot, let byteOffset, let newName, let context):
            let (connection, position) = try await syncAndPosition(snapshot, byteOffset: byteOffset)
            // Sync every context file so cross-file edits bind exact bases.
            for extra in context {
                _ = try await sync(extra, revisionNumber: snapshotRevisionNumber(extra))
            }
            let rawRename = try await connection.request(method: "textDocument/rename", params: [
                "textDocument": ["uri": documentURI(snapshot.path)],
                "position": ["line": position.line, "character": position.character],
                "newName": newName
            ], timeoutSeconds: 30)
            let result = lspDecodeDict(rawRename)
            // Single contract: result IS the WorkspaceEdit, read directly.
            guard !result.isEmpty else {
                throw CodeIntelligenceError.providerFailure("rename returned no edit")
            }
            // Per-file bases from engine-supplied snapshots (target+context).
            // Files the engine never snapshotted fail closed in validation.
            var contents = [snapshot.path: snapshot.content]
            var revisions = [snapshot.path: snapshot.revision]
            for extra in context {
                contents[extra.path] = extra.content
                revisions[extra.path] = extra.revision
            }
            let edits = try Self.convertWorkspaceEdit(
                result, root: root, contents: contents,
                revisions: revisions, encoding: initializedEncoding
            )
            return .workspaceEdit(SemanticWorkspaceEdit(
                edits: edits, source: .rename, provider: providerID,
                basis: "rename to \(newName)"
            ))

        case .diagnostics(let snapshot):
            let uri = documentURI(snapshot.path)
            _ = try await sync(snapshot, revisionNumber: snapshotRevisionNumber(snapshot))
            let diags = await connectionIfStarted()?.cachedDiagnostics(uri: uri) ?? []
            let items = diags
                .filter { $0.version == snapshotRevisionNumber(snapshot) }
                .map {
                    DiagnosticFact(
                        path: snapshot.path, revision: snapshot.revision,
                        message: $0.message, severity: $0.severity
                    )
                }
            return .diagnostics(items)
        }
    }

    /// Revision the server view of a file is based on (engine staleness checks).
    func basisRevision(path: String) -> ArtifactRevisionID? {
        lock.withLock { syncedBasis[documentURI(path)] }
    }

    // MARK: helpers

    private func documentURI(_ path: String) -> String {
        root.appendingPathComponent(path).absoluteString
    }

    private func snapshotRevisionNumber(_ snapshot: CodeDocumentSnapshot) -> Int {
        // EditEngine revision numbers are monotonic per path: ideal LSP versions.
        max(0, snapshot.revisionNumber)
    }

    private func syncAndPosition(
        _ snapshot: CodeDocumentSnapshot,
        byteOffset: Int
    ) async throws -> (LSPConnection, (line: Int, character: Int)) {
        let connection = try await sync(snapshot, revisionNumber: snapshotRevisionNumber(snapshot))
        guard let position = UTF8SpanConverter.lineAndCharacter(
            content: snapshot.content,
            byteOffset: byteOffset,
            encoding: initializedEncoding
        ) else {
            throw CodeIntelligenceError.invalidQuery("byte offset outside snapshot")
        }
        return (connection, position)
    }

    // MARK: converters (all UTF-16 line/char -> UTF-8 bytes on exact content)

    static func convertSymbols(
        _ node: Any?,
        path: String,
        revision: ArtifactRevisionID,
        content: String,
        encoding: LSPPositionEncoding
    ) -> [CodeSymbol] {
        var out: [CodeSymbol] = []
        func visit(_ item: [String: Any], container: String?) {
            guard let name = item["name"] as? String,
                  let range = item["range"] as? [String: Any] else {
                return
            }
            let selRange = item["selectionRange"] as? [String: Any] ?? range
            let nameSpan = convertRange(selRange, content: content, revision: revision, encoding: encoding)
            let fullSpan = convertRange(range, content: content, revision: revision, encoding: encoding)
            guard let nameSpan else { return }
            let kindInt = item["kind"] as? Int ?? 0
            out.append(CodeSymbol(
                id: "\(path)#\(nameSpan.startByte)-\(nameSpan.endByte)",
                name: name,
                kind: symbolKind(kindInt),
                path: path,
                nameSpan: nameSpan,
                fullSpan: fullSpan,
                container: container,
                detail: item["detail"] as? String,
                providerTag: "lsp:\(kindInt)"
            ))
            if let children = item["children"] as? [[String: Any]] {
                for child in children { visit(child, container: name) }
            }
        }
        if let array = node as? [[String: Any]] {
            for item in array { visit(item, container: nil) }
        } else if let single = node as? [String: Any] {
            visit(single, container: nil)
        }
        return out
    }

    static func convertPendingSymbol(
        _ item: [String: Any]
    ) -> UnresolvedSymbol? {
        // Index hit without snapshot basis: identity + server range only.
        // No spans, no revisions — the engine re-resolves per file.
        guard let name = item["name"] as? String else { return nil }
        let kindInt = item["kind"] as? Int ?? 0
        var path = ""
        var range: [String: Any]? = nil
        if let location = item["location"] as? [String: Any],
           let uri = location["uri"] as? String {
            path = uri
            range = location["range"] as? [String: Any]
        }
        func int(_ dict: [String: Any]?, _ key: String) -> Int? {
            (dict?[key] as? Int) ?? ((dict?[key] as? NSNumber)?.intValue)
        }
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        return UnresolvedSymbol(
            name: name,
            kind: symbolKind(kindInt),
            path: path,
            container: item["containerName"] as? String,
            startLine: start.flatMap { int($0, "line") },
            startCharacter: start.flatMap { int($0, "character") },
            endLine: end.flatMap { int($0, "line") },
            endCharacter: end.flatMap { int($0, "character") }
        )
    }

    static func convertPendingLocations(
        _ node: Any?,
        root: URL
    ) -> [UnresolvedLocation] {
        // Reference/definition hits carry URIs (+ ranges) but no snapshot
        // basis. Ranges are preserved verbatim; revisions are bound later
        // by the engine when it snapshots each file. Never fabricated.
        var out: [UnresolvedLocation] = []
        func ints(_ dict: [String: Any]?, _ key: String) -> Int? {
            (dict?[key] as? Int) ?? ((dict?[key] as? NSNumber)?.intValue)
        }
        func visit(_ item: [String: Any]) {
            let uri: String?
            let range: [String: Any]?
            if let direct = item["uri"] as? String {
                uri = direct
                range = item["range"] as? [String: Any]
            } else {
                uri = item["targetUri"] as? String
                range = (item["targetRange"] as? [String: Any])
                    ?? (item["targetSelectionRange"] as? [String: Any])
            }
            guard let uri,
                  let url = URL(string: uri),
                  url.path.hasPrefix(root.path) else {
                return
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let start = range?["start"] as? [String: Any]
            let end = range?["end"] as? [String: Any]
            out.append(UnresolvedLocation(
                path: relative,
                startLine: start.flatMap { ints($0, "line") },
                startCharacter: start.flatMap { ints($0, "character") },
                endLine: end.flatMap { ints($0, "line") },
                endCharacter: end.flatMap { ints($0, "character") }
            ))
        }
        if let array = node as? [[String: Any]] {
            for item in array { visit(item) }
        } else if let single = node as? [String: Any] {
            visit(single)
        }
        return out
    }

    static func convertRange(
        _ range: [String: Any],
        content: String,
        revision: ArtifactRevisionID,
        encoding: LSPPositionEncoding
    ) -> CodeSpan? {
        guard let start = range["start"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let sLine = start["line"] as? Int,
              let sChar = start["character"] as? Int,
              let eLine = end["line"] as? Int,
              let eChar = end["character"] as? Int,
              let sByte = UTF8SpanConverter.byteOffset(
                content: content, line: sLine, character: sChar, encoding: encoding
              ),
              let eByte = UTF8SpanConverter.byteOffset(
                content: content, line: eLine, character: eChar, encoding: encoding
              ),
              sByte <= eByte else {
            return nil
        }
        return CodeSpan(revision: revision, startByte: sByte, endByte: eByte)
    }

    /// Every edited path MUST resolve to an exact caller-supplied
    /// revision. No default: borrowing another file's revision would bind
    /// offsets to the wrong content generation.
    static func convertWorkspaceEdit(
        _ edit: [String: Any],
        root: URL,
        contents: [String: String],
        revisions: [String: ArtifactRevisionID],
        encoding: LSPPositionEncoding
    ) throws -> [SemanticTextEdit] {
        var out: [SemanticTextEdit] = []
        if let changes = edit["changes"] as? [String: [[String: Any]]] {
            for (uri, edits) in changes {
                guard let url = URL(string: uri),
                      url.path.hasPrefix(root.path + "/") else {
                    throw CodeIntelligenceError.providerFailure(
                        "rename edit outside workspace: \(uri)"
                    )
                }
                let path = String(url.path.dropFirst(root.path.count + 1))
                guard let content = contents[path],
                      let revision = revisions[path] else {
                    throw CodeIntelligenceError.staleBasis(
                        "no exact snapshot basis for \(path)"
                    )
                }
                for item in edits {
                    guard let range = item["range"] as? [String: Any],
                          let newText = item["newText"] as? String,
                          let span = convertRange(
                            range, content: content,
                            revision: revision, encoding: encoding
                          ) else {
                        throw CodeIntelligenceError.providerFailure(
                            "unconvertible rename range in \(path)"
                        )
                    }
                    out.append(SemanticTextEdit(
                        path: path,
                        baseRevision: revision,
                        startByteOffset: span.startByte,
                        endByteOffset: span.endByte,
                        replacement: newText
                    ))
                }
            }
            return out
        }
        if let documentChanges = edit["documentChanges"] as? [[String: Any]] {
            for change in documentChanges {
                guard let doc = change["textDocument"] as? [String: Any],
                      let uri = doc["uri"] as? String,
                      let url = URL(string: uri),
                      url.path.hasPrefix(root.path + "/") else {
                    throw CodeIntelligenceError.providerFailure(
                        "rename edit outside workspace"
                    )
                }
                let path = String(url.path.dropFirst(root.path.count + 1))
                guard let content = contents[path],
                      let revision = revisions[path] else {
                    throw CodeIntelligenceError.staleBasis(
                        "no exact snapshot basis for \(path)"
                    )
                }
                guard let edits = change["edits"] as? [[String: Any]] else { continue }
                for item in edits {
                    guard let range = item["range"] as? [String: Any],
                          let newText = item["newText"] as? String,
                          let span = convertRange(
                            range, content: content,
                            revision: revision, encoding: encoding
                          ) else {
                        throw CodeIntelligenceError.providerFailure(
                            "unconvertible rename range in \(path)"
                        )
                    }
                    out.append(SemanticTextEdit(
                        path: path,
                        baseRevision: revision,
                        startByteOffset: span.startByte,
                        endByteOffset: span.endByte,
                        replacement: newText
                    ))
                }
            }
            return out
        }
        throw CodeIntelligenceError.providerFailure("empty rename edit")
    }

    static func symbolKind(_ lsp: Int) -> CodeSymbolKind {
        switch lsp {
        case 5: return .class
        case 11: return .interface
        case 23: return .struct
        case 10: return .enum
        case 12: return .function
        case 6, 9: return .method
        case 7, 8: return .property
        case 13: return .variable
        case 14: return .constant
        case 26: return .typeParameter
        case 3: return .namespace
        default: return .other
        }
    }
}

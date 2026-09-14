import Foundation
import SLTACore

private final class WorkspaceTaskCache: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var readPaths: Set<String> = []
    private var createdPaths: Set<String> = []
    private var readCache: [String: (UInt64, String)] = [:]
    private var listCache: [String: (UInt64, String)] = [:]
    private var searchCache: [String: (UInt64, String)] = [:]

    @inline(__always)
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func reset() {
        withLock {
            revision = 0
            readPaths.removeAll(keepingCapacity: true)
            createdPaths.removeAll(keepingCapacity: true)
            readCache.removeAll(keepingCapacity: true)
            listCache.removeAll(keepingCapacity: true)
            searchCache.removeAll(keepingCapacity: true)
        }
    }

    func cachedRead(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = readCache[path], item.0 == revision else { return nil }
        readPaths.insert(path)
        return item.1
    }

    func storeRead(_ path: String, content: String) {
        withLock {
            readPaths.insert(path)
            readCache[path] = (revision, content)
        }
    }

    func cachedList(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = listCache[key], item.0 == revision else { return nil }
        return item.1
    }

    func storeList(_ key: String, result: String) {
        withLock {
            listCache[key] = (revision, result)
        }
    }

    func cachedSearch(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = searchCache[key], item.0 == revision else { return nil }
        return item.1
    }

    func storeSearch(_ key: String, result: String) {
        withLock {
            searchCache[key] = (revision, result)
        }
    }

    func mayOverwrite(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readPaths.contains(path) || createdPaths.contains(path)
    }

    func markCreated(_ path: String) {
        _ = withLock {
            createdPaths.insert(path)
        }
    }

    func mutation(targetPath: String?) {
        withLock {
            revision &+= 1
            readCache.removeAll(keepingCapacity: true)
            listCache.removeAll(keepingCapacity: true)
            searchCache.removeAll(keepingCapacity: true)

            if let targetPath {
                readPaths.insert(targetPath)
            }
        }
    }

    func unknownShellMutation() {
        withLock {
            revision &+= 1
            readPaths.removeAll(keepingCapacity: true)
            readCache.removeAll(keepingCapacity: true)
            listCache.removeAll(keepingCapacity: true)
            searchCache.removeAll(keepingCapacity: true)
        }
    }
}

// MARK: - Smart Cursor-style Block Matcher
enum SmartBlockMatcher {
    /// Resolves only a unique target: first byte-for-byte, then by canonical
    /// line structure. It never guesses between multiple similar blocks.
    static func findRange(of oldText: String, in fullText: String) -> Range<String.Index>? {
        let exactMatches = allRanges(of: oldText, in: fullText)
        if exactMatches.count == 1 {
            return exactMatches[0]
        }

        let fullLines = fullText.components(separatedBy: "\n")
        var oldLines = oldText.components(separatedBy: "\n")
        while oldLines.first.map(canonicalLine)?.isEmpty == true { oldLines.removeFirst() }
        while oldLines.last.map(canonicalLine)?.isEmpty == true { oldLines.removeLast() }

        guard !oldLines.isEmpty, fullLines.count >= oldLines.count else { return nil }
        let canonicalOld = oldLines.map(canonicalLine)
        var structuralMatches: [Range<String.Index>] = []

        for startLine in 0...(fullLines.count - oldLines.count) {
            let candidate = fullLines[startLine..<(startLine + oldLines.count)]
                .map(canonicalLine)
            guard candidate == canonicalOld,
                  let start = lineIndex(to: startLine, in: fullText),
                  let lineBoundary = lineIndex(
                    to: startLine + oldLines.count,
                    in: fullText,
                    isEnd: true
                  ) else { continue }
            let end: String.Index
            if lineBoundary > start,
               fullText[fullText.index(before: lineBoundary)] == "\n" {
                end = fullText.index(before: lineBoundary)
            } else {
                end = lineBoundary
            }
            structuralMatches.append(start..<end)
        }

        return structuralMatches.count == 1 ? structuralMatches[0] : nil
    }

    private static func canonicalLine(_ line: String) -> String {
        line.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func allRanges(
        of needle: String,
        in haystack: String
    ) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var matches: [Range<String.Index>] = []
        var cursor = haystack.startIndex
        while cursor < haystack.endIndex,
              let range = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            matches.append(range)
            cursor = range.upperBound
        }
        return matches
    }

    private static func lineIndex(to lineNum: Int, in text: String, isEnd: Bool = false) -> String.Index? {
        var current = 0
        var idx = text.startIndex
        while current < lineNum && idx < text.endIndex {
            if text[idx] == "\n" {
                current += 1
            }
            idx = text.index(after: idx)
        }
        return idx
    }
}

final class Workspace: @unchecked Sendable {
    let root: URL
    let shellTimeoutSeconds: Int
    let limits: SLTALimits
    /// v0.29 single ArtifactGraph per project (revision-aware source of truth).
    let graph: ArtifactGraph

    private let fm = FileManager.default
    private let policy: PolicyEngine
    private let runtime: RuntimeEnvironment
    private let taskCache = WorkspaceTaskCache()
    private let editEngine: EditEngine
    private let invariantLock = NSLock()
    private var minimumLineCount: Int?

    private static let ignored: Set<String> = [
        ".git", "node_modules", "DerivedData", ".build", "dist",
        "build", "vendor", ".next", "Pods"
    ]

    init(
        root: URL,
        shellTimeoutSeconds: Int,
        policy: PolicyEngine,
        runtime: RuntimeEnvironment,
        editHistoryRoot: URL? = nil,
        limits: SLTALimits = .fromEnvironment(),
        artifactGraph: ArtifactGraph? = nil
    ) {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        self.root = resolvedRoot
        self.shellTimeoutSeconds = shellTimeoutSeconds
        self.policy = policy
        self.runtime = runtime
        self.limits = limits
        self.graph = artifactGraph ?? ArtifactGraph()
        self.editEngine = EditEngine(
            projectRoot: resolvedRoot,
            historyRoot: editHistoryRoot
        )
    }

    // MARK: v0.29 ArtifactGraph integration

    /// Canonical graph key: project-relative path. Falls back to the raw
    /// argument when it cannot be resolved inside the sandbox.
    func canonicalKey(_ path: String) -> String {
        if let url = try? resolve(path) {
            let key = relative(url)
            if !key.isEmpty { return key }
        }
        return path
    }

    /// Sandbox membership without throwing (semantic plan validation).
    func contains(path: String) -> Bool {
        (try? resolve(path)) != nil
    }

    /// Exact revision snapshot for code intelligence: disk content +
    /// EditEngine base revision, WITHOUT task evidence or task cache.
    /// External changes are detected and recorded like any other access.
    func readSnapshot(path: String) throws -> (content: String, revision: ArtifactRevision) {
        try policy.authorize(tool: "read_file", risk: .read)
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            _ = detectExternalDeletion(key: canonicalKey(path))
            throw SLTAError.fileNotFound(path)
        }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > limits.fileMaxBytes {
            throw SLTAError.fileTooLarge(path: path, limit: limits.fileMaxBytes)
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        let key = canonicalKey(path)
        _ = detectExternalChange(key: key, url: url, knownContent: content)
        let revision = try editEngine.observe(path: key, content: content)
        noteObserved(key: key, revision: revision, content: content)
        return (content, revision)
    }

    /// Apply a validated SemanticWorkspaceEdit: ONE EditEngine transaction
    /// per file (operation .semanticEdit). Validate-all-first, then commit;
    /// a mid-way commit failure rolls back already-committed files, so a
    /// logical operation never leaves a partial result behind. NOT
    /// filesystem-atomic across files (documented): concurrent external
    /// writers can still interleave between per-file commits.
    /// Returns new revision IDs per file. Throws RECOVERABLE_CONFLICT when a
    /// base moved (no partial state survives: committed files are reverted).
    func applySemanticPlan(
        _ edits: [SemanticTextEdit],
        contents: [String: String]
    ) throws -> [String: ArtifactRevisionID] {
        // Group per file; contents keyed by canonical path.
        var byFile: [String: [SemanticTextEdit]] = [:]
        for edit in edits {
            let key = canonicalKey(edit.path)
            byFile[key, default: []].append(edit)
        }
        // Phase 1: every file must still be on its expected base.
        for (key, _) in byFile {
            let url = try resolve(key)
            guard let expected = contents[key] else {
                throw SLTAError.revisionConflict("no base content for \(key)")
            }
            try verifyUnchangedBase(url: url, expectedContent: expected,
                                    expectedExists: true, path: key)
        }
        // Phase 2: commit each file as a single transaction.
        var committed: [(key: String, content: String)] = []
        var result: [String: ArtifactRevisionID] = [:]
        do {
            for (key, items) in byFile.sorted(by: { $0.key < $1.key }) {
                guard let base = contents[key] else {
                    throw SLTAError.revisionConflict("no base content for \(key)")
                }
                let updated = Self.applyByteEdits(to: base, edits: items)
                let url = try resolve(key)
                try verifyUnchangedBase(url: url, expectedContent: base,
                                        expectedExists: true, path: key)
                let prepared = try editEngine.prepare(
                    path: key, before: base, after: updated,
                    operation: .semanticEdit
                )
                do {
                    try Data(updated.utf8).write(to: url, options: .atomic)
                    _ = try editEngine.commit(prepared)
                } catch {
                    editEngine.reject(prepared)
                    throw error
                }
                taskCache.mutation(targetPath: url.path)
                noteMutated(key: key, newContent: updated)
                committed.append((key, updated))
                if let rev = editEngine.latestRevision(path: key) {
                    result[key] = rev.id
                }
            }
        } catch {
            // Logical all-or-revert: undo committed files in reverse order.
            for (key, _) in committed.reversed() {
                _ = try? rollbackLastEdit(key)
            }
            throw error
        }
        return result
    }

    /// Apply descending byte-offset edits to in-memory content.
    static func applyByteEdits(to content: String, edits: [SemanticTextEdit]) -> String {
        var bytes = Array(content.utf8)
        for edit in edits.sorted(by: { $0.startByteOffset > $1.startByteOffset }) {
            let start = min(edit.startByteOffset, bytes.count)
            let end = min(max(edit.endByteOffset, start), bytes.count)
            bytes.replaceSubrange(start..<end, with: Array(edit.replacement.utf8))
        }
        return String(bytes: bytes, encoding: .utf8) ?? content
    }

    /// Full revision record: EditEngine history first, graph external markers second.
    func revisionRecord(_ id: ArtifactRevisionID) -> ArtifactRevision? {
        editEngine.revision(id) ?? graph.externalRecord(id)
    }

    /// First sight adopts the observed revision as current (reads never bump).
    /// A divergent observe (disk moved under us) is reconciled as external.
    private func noteObserved(key: String, revision: ArtifactRevision, content: String) {
        if graph.currentRevisionID(path: key) == nil {
            graph.adoptIfUnknown(
                revision,
                contentHash: ArtifactHash.sha256(content),
                taskID: revision.originTask
            )
        } else if graph.currentRevisionID(path: key) != revision.id {
            _ = graph.markExternal(
                path: key,
                contentHash: ArtifactHash.sha256(content),
                exists: true,
                byteCount: content.utf8.count,
                lineCount: content.components(separatedBy: "\n").count
            )
        }
    }

    /// One logical transaction creates one new current revision per artifact.
    /// Hash comes from in-memory resulting content — no disk re-read (§7).
    private func noteMutated(key: String, newContent: String) {
        guard let revision = editEngine.latestRevision(path: key) else { return }
        graph.registerRevision(
            revision,
            contentHash: ArtifactHash.sha256(newContent),
            taskID: revision.originTask,
            kind: ArtifactType.infer(path: key)
        )
    }

    /// Hash/metadata comparison on access (§8). No filesystem watcher.
    /// Returns true when an external change was recorded (old evidence stale).
    @discardableResult
    private func detectExternalChange(key: String, url: URL, knownContent: String?) -> Bool {
        guard graph.node(path: key) != nil else { return false }
        if let content = knownContent {
            let hash = ArtifactHash.sha256(content)
            guard hash != graph.currentHash(path: key) else { return false }
            _ = graph.markExternal(
                path: key,
                contentHash: hash,
                exists: true,
                byteCount: content.utf8.count,
                lineCount: content.components(separatedBy: "\n").count
            )
            return true
        }
        // validate path without in-memory content: bounded disk hash.
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue <= limits.fileMaxBytes,
              let hash = ArtifactHash.sha256File(at: url) else {
            return false
        }
        guard hash != graph.currentHash(path: key) else { return false }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        _ = graph.markExternal(
            path: key,
            contentHash: hash,
            exists: true,
            byteCount: size.intValue,
            lineCount: text.components(separatedBy: "\n").count
        )
        return true
    }

    /// v0.29.1 TOCTOU guard: re-verify the expected base maximally close to
    /// the atomic commit. Throws RECOVERABLE_CONFLICT (no mutation evidence,
    /// no graph update) instead of overwriting an external change.
    private func verifyUnchangedBase(
        url: URL,
        expectedContent: String?,
        expectedExists: Bool,
        path: String
    ) throws {
        let current: String? = try? String(contentsOf: url, encoding: .utf8)
        if expectedExists {
            guard let current else {
                throw SLTAError.revisionConflict(
                    "file disappeared under runtime for \(path); reread before mutating"
                )
            }
            guard ArtifactHash.sha256(current) == ArtifactHash.sha256(expectedContent ?? "") else {
                throw SLTAError.revisionConflict(
                    "file changed under runtime for \(path); expected base no longer current"
                )
            }
        } else if current != nil {
            throw SLTAError.revisionConflict(
                "file appeared under runtime for \(path); reread before creating"
            )
        }
    }

    /// Deletion is an external change too: record it before throwing not-found.
    @discardableResult
    private func detectExternalDeletion(key: String) -> Bool {
        guard let node = graph.node(path: key), node.exists else { return false }
        _ = graph.markExternal(
            path: key,
            contentHash: "missing",
            exists: false,
            byteCount: 0,
            lineCount: 0
        )
        return true
    }

    @inline(__always)
    private func withInvariantLock<T>(_ body: () throws -> T) rethrows -> T {
        invariantLock.lock()
        defer { invariantLock.unlock() }
        return try body()
    }

    /// Общий helper: resolve + проверка файл/директория + чтение UTF-8.
    /// Убирает дублирование readFile / readFileRange / editFile / editFileRange.
    private func loadTextFile(path: String, url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SLTAError.fileNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw SLTAError.isDirectory(path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func observeAndCache(path: String, url: URL, text: String) throws {
        _ = try editEngine.observe(path: path, content: text)
        taskCache.storeRead(url.path, content: text)
    }

    func beginTask(
        taskID: TaskID? = nil,
        constraints: [TaskConstraint] = []
    ) {
        taskCache.reset()
        editEngine.beginTask(taskID)

        let minimum = constraints.compactMap { constraint -> Int? in
            if case .minimumLineCount(let count) = constraint {
                return count
            }
            return nil
        }.max()

        withInvariantLock {
            minimumLineCount = minimum
        }
    }

    func listDir(_ path: String) throws -> String {
        try policy.authorize(tool: "list_dir", risk: .read)
        let url = try resolve(path)
        let key = url.path

        if let cached = taskCache.cachedList(key) {
            return cached
        }

        let names = try fm.contentsOfDirectory(atPath: url.path).sorted()
        let result = names.prefix(limits.listDirMaxEntries).joined(separator: "\n")
        taskCache.storeList(key, result: result)
        return result
    }

    func readFile(_ path: String) throws -> String {
        try policy.authorize(tool: "read_file", risk: .read)
        let url = try resolve(path)
        let key = url.path

        if let cached = taskCache.cachedRead(key) {
            return cached
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            _ = detectExternalDeletion(key: canonicalKey(path))
            throw SLTAError.fileNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw SLTAError.isDirectory(path)
        }

        let attributes = try fm.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > limits.fileMaxBytes {
            throw SLTAError.fileTooLarge(path: path, limit: limits.fileMaxBytes)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let gkey = canonicalKey(path)
        _ = detectExternalChange(key: gkey, url: url, knownContent: text)
        let observed = try editEngine.observe(
            path: gkey,
            content: text
        )
        noteObserved(key: gkey, revision: observed, content: text)
        taskCache.storeRead(key, content: text)
        return text
    }

    func writeFile(_ path: String, content: String) throws -> String {
        try policy.authorize(tool: "write_file", risk: .write)
        let url = try resolve(path)
        let key = url.path
        let data = Data(content.utf8)

        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        var previousContent: String?
        var existingPerms: NSNumber? = nil

        if exists {
            guard !isDirectory.boolValue else {
                throw CLIError("path is a directory: \(path)")
            }

            let attrs = try? fm.attributesOfItem(atPath: url.path)
            existingPerms = attrs?[.posixPermissions] as? NSNumber

            let oldText = try String(contentsOf: url, encoding: .utf8)
            previousContent = oldText
            let gkey = canonicalKey(path)
            _ = detectExternalChange(key: gkey, url: url, knownContent: oldText)
            _ = try editEngine.observe(path: gkey, content: oldText)

            if !taskCache.mayOverwrite(key) {
                taskCache.storeRead(key, content: oldText)
            }

            if oldText == content {
                return "unchanged \(path) · content already matches"
            }
        } else {
            _ = try editEngine.observe(path: canonicalKey(path), content: nil)
        }

        try validateArtifactInvariants(path: path, content: content)

        let operation: EditOperationKind = exists ? .fullReplace : .create
        let prepared = try editEngine.prepare(
            path: canonicalKey(path),
            before: previousContent,
            after: content,
            operation: operation
        )

        do {
            try verifyUnchangedBase(url: url, expectedContent: previousContent, expectedExists: exists, path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)

            // Восстанавливаем права на исполнение
            if let perms = existingPerms {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            }

            let receipt = try editEngine.commit(prepared)
            if !exists { taskCache.markCreated(key) }
            taskCache.mutation(targetPath: key)
            noteMutated(key: canonicalKey(path), newContent: content)

            return "wrote \(path) · \(data.count) B · \(receipt)"
        } catch {
            editEngine.reject(prepared)
            throw error
        }
    }

    /// Умное редактирование файла (как в Cursor): с интеллектуальным поиском места вставки
    func editFile(_ path: String, old: String, new: String) throws -> String {
        try policy.authorize(tool: "edit_file", risk: .write)
        guard !old.isEmpty else {
            throw CLIError("old text must not be empty")
        }

        let url = try resolve(path)
        let key = url.path

        guard fm.fileExists(atPath: url.path) else {
            throw CLIError("file not found: \(path)")
        }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let existingPerms = attrs?[.posixPermissions] as? NSNumber

        let text = try String(contentsOf: url, encoding: .utf8)
        let gkey = canonicalKey(path)
        _ = detectExternalChange(key: gkey, url: url, knownContent: text)
        let observed = try editEngine.observe(path: gkey, content: text)
        noteObserved(key: gkey, revision: observed, content: text)
        taskCache.storeRead(key, content: text)

        // ИСПОЛЬЗУЕМ КУРСОРОВСКИЙ УМНЫЙ МАТЧЕР
        guard let range = SmartBlockMatcher.findRange(of: old, in: text) else {
            throw CLIError(
                "unique edit target not found in \(path); reread the current file and retry with edit_file_range using exact line numbers"
            )
        }

        var updated = text
        updated.replaceSubrange(range, with: new)

        if updated == text {
            return "unchanged \(path)"
        }

        try validateArtifactInvariants(path: path, content: updated)

        let prepared = try editEngine.prepare(
            path: gkey,
            before: text,
            after: updated,
            operation: .exactReplace
        )

        do {
            try verifyUnchangedBase(url: url, expectedContent: text, expectedExists: true, path: path)
            try Data(updated.utf8).write(to: url, options: .atomic)

            if let perms = existingPerms {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            }

            let receipt = try editEngine.commit(prepared)
            taskCache.mutation(targetPath: key)
            noteMutated(key: gkey, newContent: updated)

            let oldLines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let newLines = updated.split(separator: "\n", omittingEmptySubsequences: false).count
            return "updated \(path) · \(oldLines)→\(newLines) lines · \(receipt)"
        } catch {
            editEngine.reject(prepared)
            throw error
        }
    }

    func readFileRange(
        _ path: String,
        startLine: Int,
        endLine: Int
    ) throws -> String {
        try policy.authorize(tool: "read_file_range", risk: .read)
        guard startLine >= 1, endLine >= startLine else {
            throw CLIError("invalid line range: \(startLine)-\(endLine)")
        }

        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError("file not found: \(path)")
        }
        guard !isDirectory.boolValue else {
            throw CLIError("path is a directory: \(path)")
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let gkey = canonicalKey(path)
        _ = detectExternalChange(key: gkey, url: url, knownContent: text)
        let observed = try editEngine.observe(path: gkey, content: text)
        noteObserved(key: gkey, revision: observed, content: text)
        taskCache.storeRead(url.path, content: text)

        let lines = text.components(separatedBy: "\n")
        guard startLine <= max(1, lines.count) else {
            throw CLIError("start line \(startLine) exceeds file line count \(lines.count)")
        }

        let upper = min(endLine, lines.count)
        let selected = lines[(startLine - 1)..<upper]
        var output = ["range \(path) lines \(startLine)-\(upper)/\(lines.count)"]
        output.append(contentsOf: selected.enumerated().map { offset, line in
            "\(startLine + offset)│\(line)"
        })
        return output.joined(separator: "\n")
    }

    func editFileRange(
        _ path: String,
        startLine: Int,
        endLine: Int,
        replacement: String
    ) throws -> String {
        try policy.authorize(tool: "edit_file_range", risk: .write)
        guard startLine >= 1, endLine >= startLine else {
            throw CLIError("invalid line range: \(startLine)-\(endLine)")
        }

        let url = try resolve(path)
        let key = url.path
        guard fm.fileExists(atPath: url.path) else {
            throw CLIError("file not found: \(path)")
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let gkey = canonicalKey(path)
        _ = detectExternalChange(key: gkey, url: url, knownContent: text)
        let observed = try editEngine.observe(path: gkey, content: text)
        noteObserved(key: gkey, revision: observed, content: text)
        taskCache.storeRead(key, content: text)

        var lines = text.components(separatedBy: "\n")
        guard startLine <= lines.count, endLine <= lines.count else {
            throw CLIError("line range \(startLine)-\(endLine) exceeds file line count \(lines.count)")
        }

        let replacementLines = replacement.components(separatedBy: "\n")
        lines.replaceSubrange((startLine - 1)..<endLine, with: replacementLines)
        let updated = lines.joined(separator: "\n")

        if updated == text {
            return "unchanged \(path)"
        }

        try validateArtifactInvariants(path: path, content: updated)

        let prepared = try editEngine.prepare(
            path: gkey,
            before: text,
            after: updated,
            operation: .rangeReplace
        )

        do {
            try verifyUnchangedBase(url: url, expectedContent: text, expectedExists: true, path: path)
            try Data(updated.utf8).write(to: url, options: .atomic)
            let receipt = try editEngine.commit(prepared)
            taskCache.mutation(targetPath: key)
            noteMutated(key: gkey, newContent: updated)
            return "updated range \(path) · lines \(startLine)-\(endLine) · \(receipt)"
        } catch {
            editEngine.reject(prepared)
            throw error
        }
    }

    func search(_ query: String, path: String) throws -> String {
        try policy.authorize(tool: "search", risk: .read)
        let base = try resolve(path)
        let cacheKey = base.path + "\u{1F}" + query

        if let cached = taskCache.cachedSearch(cacheKey) {
            return cached
        }

        let result: String

        if let rg = runtime.executables["rg"] {
            let relativeBase = relative(base)
            let arguments = [
                "-n", "--no-heading", "--color", "never",
                "--smart-case",
                "--max-count", String(limits.searchMaxHits),
                "--glob", "!.git/**",
                "--glob", "!node_modules/**",
                "--glob", "!DerivedData/**",
                "--glob", "!.build/**",
                "--glob", "!dist/**",
                query,
                relativeBase.isEmpty ? "." : relativeBase
            ]

            let runResult = try run(rg, arguments, limits.searchTimeoutSeconds, allow: [1])
            result = runResult.status == 1 ? "no matches" : runResult.output
        } else {
            var hits: [String] = []
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]

            guard let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return "no matches"
            }

            outer: for case let url as URL in enumerator {
                if Self.ignored.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true,
                      (values?.fileSize ?? 0) < limits.searchFallbackMaxBytes,
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }

                for (lineNumber, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    where line.localizedCaseInsensitiveContains(query) {
                    hits.append("\(relative(url)):\(lineNumber + 1):\(line)")
                    if hits.count >= limits.searchMaxHits { break outer }
                }
            }

            result = hits.isEmpty ? "no matches" : String(hits.joined(separator: "\n").prefix(limits.searchOutputMaxChars))
        }

        taskCache.storeSearch(cacheKey, result: result)
        return result
    }

    func literalSearch(_ query: String, path: String) throws -> String {
        try policy.authorize(tool: "search", risk: .read)
        let base = try resolve(path)
        let cacheKey = base.path + "\u{1F}literal\u{1F}" + query
        if let cached = taskCache.cachedSearch(cacheKey) {
            return cached
        }

        let result: String
        if let rg = runtime.executables["rg"] {
            let relativeBase = relative(base)
            let arguments = [
                "-n", "--no-heading", "--color", "never", "--fixed-strings",
                "--smart-case", "--max-count", String(limits.searchMaxHits),
                "--glob", "!.git/**", "--glob", "!node_modules/**",
                "--glob", "!DerivedData/**", "--glob", "!.build/**",
                "--glob", "!dist/**", query,
                relativeBase.isEmpty ? "." : relativeBase
            ]
            let runResult = try run(
                rg, arguments, limits.searchTimeoutSeconds, allow: [1]
            )
            result = runResult.status == 1 ? "no matches" : runResult.output
        } else {
            var hits: [String] = []
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey, .isDirectoryKey, .fileSizeKey
            ]
            guard let enumerator = fm.enumerator(
                at: base, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return "no matches" }
            outer: for case let url as URL in enumerator {
                if Self.ignored.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true,
                      (values?.fileSize ?? 0) < limits.searchFallbackMaxBytes,
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }
                for (lineNumber, line) in text.split(
                    separator: "\n", omittingEmptySubsequences: false
                ).enumerated() where line.localizedCaseInsensitiveContains(query) {
                    hits.append("\(relative(url)):\(lineNumber + 1):\(line)")
                    if hits.count >= limits.searchMaxHits { break outer }
                }
            }
            result = hits.isEmpty
                ? "no matches"
                : String(hits.joined(separator: "\n").prefix(limits.searchOutputMaxChars))
        }
        taskCache.storeSearch(cacheKey, result: result)
        return result
    }

    func shell(_ command: String) throws -> String {
        try policy.authorize(tool: "shell", risk: .shell)
        try policy.validateShell(command)

        let result = try run(limits.shellPath, ["-lc", command], shellTimeoutSeconds)
        taskCache.unknownShellMutation()
        return "exit=\(result.status)\n\(result.output)"
    }

    func validateFile(_ path: String) throws -> String {
        try policy.authorize(tool: "validate_file", risk: .shell)
        let url = try resolve(path)
        var isDirectory: ObjCBool = false

        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            _ = detectExternalDeletion(key: canonicalKey(path))
            throw CLIError("file not found: \(path)")
        }
        // External change invalidates prior validation before we re-validate.
        _ = detectExternalChange(key: canonicalKey(path), url: url, knownContent: nil)
        guard !isDirectory.boolValue else {
            throw CLIError("validate_file expects a file: \(path)")
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "html", "htm":
            return try validateHTML(url, path: path)
        case "swift":
            guard let swiftc = runtime.executables["swiftc"] else { throw CLIError("swiftc is not available") }
            _ = try run(swiftc, ["-parse", url.path], limits.swiftcTimeoutSeconds)
            return "swift syntax valid: \(path)"
        case "json":
            let data = try Data(contentsOf: url)
            _ = try JSONSerialization.jsonObject(with: data)
            return "valid JSON: \(path)"
        case "py":
            guard let python = runtime.executables["python3"] ?? runtime.executables["python"] else {
                throw CLIError("python is not available")
            }
            let script = "import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())"
            _ = try run(python, ["-c", script, url.path], limits.validateTimeoutSeconds)
            return "python syntax valid: \(path)"
        case "js", "mjs", "cjs":
            guard let node = runtime.executables["node"] else { throw CLIError("node is not available") }
            _ = try run(node, ["--check", url.path], limits.validateTimeoutSeconds)
            return "javascript syntax valid: \(path)"
        case "rb":
            guard let ruby = runtime.executables["ruby"] else { throw CLIError("ruby is not available") }
            _ = try run(ruby, ["-c", url.path], limits.validateTimeoutSeconds)
            return "ruby syntax valid: \(path)"
        case "php":
            guard let php = runtime.executables["php"] else { throw CLIError("php is not available") }
            _ = try run(php, ["-l", url.path], limits.validateTimeoutSeconds)
            return "PHP syntax valid: \(path)"
        case "sh", "bash", "zsh":
            let shellName = ext == "sh" ? "zsh" : ext
            guard let shell = runtime.executables[shellName] else {
                throw CLIError("\(shellName) is not available")
            }
            _ = try run(shell, ["-n", url.path], limits.validateTimeoutSeconds)
            return "shell syntax valid: \(path)"
        default:
            throw CLIError("no deterministic validator for .\(ext)")
        }
    }

    private func validateHTML(_ url: URL, path: String) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("HTML file is empty: \(path)")
        }

        let lower = text.lowercased()
        if lower.contains("<html"), !lower.contains("</html>") {
            throw CLIError("HTML validation failed: missing </html> in \(path)")
        }
        if lower.contains("<body"), !lower.contains("</body>") {
            throw CLIError("HTML validation failed: missing </body> in \(path)")
        }

        let imagePattern = #"<img\b[^>]*\bsrc\s*=\s*([\"'])(.*?)\1[^>]*>"#
        if lower.contains("<img") {
            guard let regex = try? NSRegularExpression(
                pattern: imagePattern,
                options: [.caseInsensitive]
            ) else {
                throw CLIError("HTML image validator is unavailable")
            }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            guard !matches.isEmpty else {
                throw CLIError("HTML validation failed: <img> has no quoted src in \(path)")
            }
            for match in matches {
                guard let srcRange = Range(match.range(at: 2), in: text),
                      !text[srcRange].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError("HTML validation failed: <img> has an empty src in \(path)")
                }
            }
        }

        return "HTML structure valid: \(path)"
    }

    func openFile(
        _ path: String,
        application requestedApplication: String? = nil
    ) throws -> String {
        try policy.authorize(tool: "open_file", risk: .shell)
        let url = try resolve(path)
        let executable = runtime.executables["open"] ?? "/usr/bin/open"

        if let requestedApplication,
           !requestedApplication.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let application = try resolveInstalledApplication(requestedApplication)
            _ = try run(executable, ["-a", application.path, url.path], 15)
            return "opened \(path)"
        }

        let ext = url.pathExtension.lowercased()

        if ext == "html" || ext == "htm" {
            // Opening the same file path in Safari may only focus an existing tab,
            // leaving the pre-edit page visible. A harmless query makes every launch
            // a fresh navigation while the browser still reads the same local file.
            let freshURL = url.appending(
                queryItems: [
                    URLQueryItem(
                        name: "slta_reload",
                        value: String(Int(Date().timeIntervalSince1970 * 1_000))
                    )
                ]
            )
            _ = try run(executable, [freshURL.absoluteString], 15)
            return "opened fresh \(path)"
        }

        _ = try run(executable, [url.path], 15)
        return "opened \(path)"
    }

    private func resolveInstalledApplication(_ requested: String) throws -> URL {
        let requestedKey = applicationKey(requested)
        let requestedTokens = Set(requestedKey.split(separator: " ").map(String.init))
        guard !requestedKey.isEmpty else {
            throw CLIError("Не указано приложение для открытия файла")
        }

        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
                .appendingPathComponent("Applications", isDirectory: true)
        ]
        var candidates: [(url: URL, score: Int, name: String)] = []

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                let nameKey = applicationKey(name)
                let nameTokens = Set(nameKey.split(separator: " ").map(String.init))
                let bundleKey = Bundle(url: url)?.bundleIdentifier.map(applicationKey) ?? ""

                let score: Int
                if requestedKey == nameKey || requestedKey == bundleKey {
                    score = 1_000
                } else if !requestedTokens.isEmpty && requestedTokens.isSubset(of: nameTokens) {
                    score = 800 - max(0, nameTokens.count - requestedTokens.count)
                } else if nameKey.contains(requestedKey) || bundleKey.contains(requestedKey) {
                    score = 600 - abs(nameKey.count - requestedKey.count)
                } else {
                    continue
                }
                candidates.append((url, score, name))
            }
        }

        guard let match = candidates.max(by: {
            if $0.score == $1.score { return $0.name.count > $1.name.count }
            return $0.score < $1.score
        }) else {
            throw CLIError("Приложение «\(requested)» не найдено на этом Mac")
        }
        return match.url
    }

    private func applicationKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func openURL(_ value: String) throws -> String {
        try policy.authorize(tool: "open_url", risk: .external)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw CLIError("open_url requires absolute http(s) URL")
        }
        let executable = runtime.executables["open"] ?? "/usr/bin/open"
        _ = try run(executable, [url.absoluteString], 15)
        return "opened URL \(url.absoluteString)"
    }

    func latestEditReceipt(path: String) -> EditTransactionRef? { editEngine.latestReceipt(path: path) }

    /// v0.29.1 retention closure: every revision ID still referenced by live
    /// runtime structures. The graph prunes around this set, never through it.
    func pinnedRevisionIDs(
        journal: [EvidenceRecord],
        current: [String: ArtifactRevisionID]
    ) -> Set<ArtifactRevisionID> {
        var out = Set(current.values)
        for record in journal {
            if let id = record.revisionID {
                out.insert(ArtifactRevisionID(id))
            }
        }
        for tx in editEngine.recentTransactions(limit: 2000) {
            out.insert(tx.proposal.baseRevisionID)
            out.insert(tx.proposal.proposedRevisionID)
        }
        for checkpoint in editEngine.checkpointHistory(limit: 500) {
            out.insert(checkpoint.revisionID)
        }
        return out
    }
    func editHistoryText(limit: Int = 20) -> String { editEngine.transactionHistoryText(limit: limit) }
    func editDiffText(transactionPrefix: String? = nil) throws -> String { try editEngine.diffText(prefix: transactionPrefix) }
    func revisionHistoryText(path: String, limit: Int = 30) -> String { editEngine.revisionHistoryText(path: path, limit: limit) }
    func checkpointHistoryText(path: String? = nil, limit: Int = 30) -> String { editEngine.checkpointHistoryText(path: path, limit: limit) }
    func createCheckpoint(_ path: String, label: String = "manual") throws -> String {
        let url = try resolve(path)
        let content = try String(contentsOf: url, encoding: .utf8)
        return try editEngine.createCheckpoint(path: path, currentContent: content, label: label).description
    }
    func rollbackLastEdit(_ path: String) throws -> String {
        let url = try resolve(path)
        let current = try String(contentsOf: url, encoding: .utf8)
        let prepared = try editEngine.prepareRollback(path: path, currentContent: current)
        guard let target = try editEngine.revisionContent(prepared.transaction.proposal.proposedRevisionID) else {
            throw CLIError("rollback target does not exist")
        }
        try Data(target.utf8).write(to: url, options: .atomic)
        let receipt = try editEngine.commit(prepared)
        taskCache.mutation(targetPath: url.path)
        noteMutated(key: canonicalKey(path), newContent: target)
        return "rolled back \(path) · \(receipt)"
    }
    func restoreCheckpoint(_ prefix: String) throws -> String {
        guard let checkpoint = editEngine.checkpointHistory(limit: 500).reversed().first(where: {
            $0.id.rawValue.uuidString.lowercased().hasPrefix(prefix.lowercased())
        }) else { throw CLIError("checkpoint not found: \(prefix)") }
        let url = try resolve(checkpoint.path)
        let current = try String(contentsOf: url, encoding: .utf8)
        let prepared = try editEngine.prepareRestoreCheckpoint(prefix: prefix, currentPath: checkpoint.path, currentContent: current)
        guard let target = try editEngine.revisionContent(prepared.transaction.proposal.proposedRevisionID) else {
            throw CLIError("checkpoint target does not exist")
        }
        try Data(target.utf8).write(to: url, options: .atomic)
        let receipt = try editEngine.commit(prepared)
        taskCache.mutation(targetPath: url.path)
        noteMutated(key: canonicalKey(checkpoint.path), newContent: target)
        return "restored checkpoint \(checkpoint.id) · \(receipt)"
    }
    func gitStatus() throws -> String {
        guard let git = runtime.executables["git"] else { throw CLIError("git not available") }
        return try run(git, ["status", "--short"], 20).output
    }
    func gitDiff() throws -> String {
        guard let git = runtime.executables["git"] else { throw CLIError("git not available") }
        return try run(git, ["diff", "--", "."], 20).output
    }

    private func validateArtifactInvariants(path: String, content: String) throws {
        invariantLock.lock()
        let requiredMinimum = minimumLineCount
        invariantLock.unlock()
        guard let requiredMinimum else { return }
        let actual = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
        guard actual >= requiredMinimum else {
            throw CLIError("artifact invariant violated for \(path): requires at least \(requiredMinimum) lines, got \(actual)")
        }
    }

    private struct ProcessResult { let status: Int32; let output: String }

    private func run(_ executable: String, _ arguments: [String], _ timeout: Int, allow: Set<Int32> = []) throws -> ProcessResult {
        let directory = fm.temporaryDirectory.appendingPathComponent("slta-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        _ = fm.createFile(atPath: stdoutURL.path, contents: nil)
        _ = fm.createFile(atPath: stderrURL.path, contents: nil)

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = runtime.shellEnvironment
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()

        let timedOut = semaphore.wait(timeout: .now() + .seconds(timeout)) == .timedOut
        if timedOut {
            let pid = process.processIdentifier
            if pid > 0 { kill(-pid, SIGTERM) }
            process.terminate()
            _ = semaphore.wait(timeout: .now() + .seconds(2))
        }

        try? stdout.synchronize()
        try? stderr.synchronize()

        let out = try bounded(stdoutURL)
        let err = try bounded(stderrURL)
        let combined = out + (err.isEmpty ? "" : (out.isEmpty ? "" : "\n") + err)

        if timedOut { throw CLIError("process timed out after \(timeout)s\n\(combined)") }
        let status = process.terminationStatus
        guard status == 0 || allow.contains(status) else { throw CLIError("exit=\(status)\n\(combined)") }
        return ProcessResult(status: status, output: combined)
    }

    private func bounded(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let head: UInt64 = 4_096
        let tail: UInt64 = 12_288
        if size <= head + tail {
            try handle.seek(toOffset: 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        }
        try handle.seek(toOffset: 0)
        let first = try handle.read(upToCount: Int(head)) ?? Data()
        try handle.seek(toOffset: size - tail)
        let last = try handle.readToEnd() ?? Data()
        return String(decoding: first, as: UTF8.self) + "\n… [omitted] …\n" + String(decoding: last, as: UTF8.self)
    }

    private func resolve(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let sltaHome = fm.homeDirectoryForCurrentUser.appendingPathComponent(".slta").path
        let isConfig = candidate.path.hasPrefix(sltaHome)

        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) || isConfig else {
            throw CLIError("path escapes project sandbox: \(path)")
        }
        return candidate
    }

    private func relative(_ url: URL) -> String {
        let prefix = root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : ""
    }
}

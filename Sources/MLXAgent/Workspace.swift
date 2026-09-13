import Foundation

private final class WorkspaceTaskCache: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var readPaths: Set<String> = []
    private var createdPaths: Set<String> = []
    private var readCache: [String: (UInt64, String)] = [:]
    private var listCache: [String: (UInt64, String)] = [:]
    private var searchCache: [String: (UInt64, String)] = [:]

    func reset() {
        lock.lock()
        revision = 0
        readPaths.removeAll(keepingCapacity: true)
        createdPaths.removeAll(keepingCapacity: true)
        readCache.removeAll(keepingCapacity: true)
        listCache.removeAll(keepingCapacity: true)
        searchCache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func cachedRead(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = readCache[path], item.0 == revision else { return nil }
        readPaths.insert(path)
        return item.1
    }

    func storeRead(_ path: String, content: String) {
        lock.lock()
        readPaths.insert(path)
        readCache[path] = (revision, content)
        lock.unlock()
    }

    func cachedList(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = listCache[key], item.0 == revision else { return nil }
        return item.1
    }

    func storeList(_ key: String, result: String) {
        lock.lock()
        listCache[key] = (revision, result)
        lock.unlock()
    }

    func cachedSearch(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = searchCache[key], item.0 == revision else { return nil }
        return item.1
    }

    func storeSearch(_ key: String, result: String) {
        lock.lock()
        searchCache[key] = (revision, result)
        lock.unlock()
    }

    func mayOverwrite(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readPaths.contains(path) || createdPaths.contains(path)
    }

    func markCreated(_ path: String) {
        lock.lock()
        createdPaths.insert(path)
        lock.unlock()
    }

    func mutation(targetPath: String?) {
        lock.lock()
        revision &+= 1
        readCache.removeAll(keepingCapacity: true)
        listCache.removeAll(keepingCapacity: true)
        searchCache.removeAll(keepingCapacity: true)

        if let targetPath {
            readPaths.insert(targetPath)
        }
        lock.unlock()
    }

    func unknownShellMutation() {
        lock.lock()
        revision &+= 1
        readPaths.removeAll(keepingCapacity: true)
        readCache.removeAll(keepingCapacity: true)
        listCache.removeAll(keepingCapacity: true)
        searchCache.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

// MARK: - Smart Cursor-style Block Matcher
enum SmartBlockMatcher {
    /// Ищет диапазон для замены в файле в 3 уровня:
    /// 1. Exact match (точное совпадение)
    /// 2. Whitespace-normalized match (игнорирует разницу в пробелах на концах строк и CRLF/LF)
    /// 3. Context-anchored match (привязка по первой и последней строке блока)
    static func findRange(of oldText: String, in fullText: String) -> Range<String.Index>? {
        // Уровень 1: Точное посимвольное совпадение
        if let exactRange = fullText.range(of: oldText) {
            // Проверяем уникальность
            if fullText[exactRange.upperBound...].range(of: oldText) == nil {
                return exactRange
            }
        }

        let fullLines = fullText.components(separatedBy: "\n")
        let oldLines = oldText.components(separatedBy: "\n")

        guard !oldLines.isEmpty else { return nil }

        // Уровень 2: Сопоставление с триммингом пробелов по краям строк
        let trimmedOld = oldLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !trimmedOld.isEmpty {
            for i in 0...(fullLines.count - trimmedOld.count) {
                let candidateSlice = fullLines[i..<(i + trimmedOld.count)].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if candidateSlice == trimmedOld {
                    // Нашли совпадение строк! Восстанавливаем точный Range в исходном тексте
                    if let startIdx = lineIndex(to: i, in: fullText),
                       let endIdx = lineIndex(to: i + trimmedOld.count, in: fullText, isEnd: true) {
                        return startIdx..<endIdx
                    }
                }
            }
        }

        // Уровень 3: Якорное сопоставление (первая и последняя строка)
        if oldLines.count >= 3 {
            let firstLine = oldLines.first!.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastLine = oldLines.last!.trimmingCharacters(in: .whitespacesAndNewlines)

            var matchingIndices: [Int] = []
            for (idx, line) in fullLines.enumerated() {
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == firstLine {
                    matchingIndices.append(idx)
                }
            }

            for startLine in matchingIndices {
                let expectedEnd = startLine + oldLines.count - 1
                if expectedEnd < fullLines.count {
                    if fullLines[expectedEnd].trimmingCharacters(in: .whitespacesAndNewlines) == lastLine {
                        if let startIdx = lineIndex(to: startLine, in: fullText),
                           let endIdx = lineIndex(to: expectedEnd + 1, in: fullText, isEnd: true) {
                            return startIdx..<endIdx
                        }
                    }
                }
            }
        }

        return nil
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
        editHistoryRoot: URL? = nil
    ) {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        self.root = resolvedRoot
        self.shellTimeoutSeconds = shellTimeoutSeconds
        self.policy = policy
        self.runtime = runtime
        self.editEngine = EditEngine(
            projectRoot: resolvedRoot,
            historyRoot: editHistoryRoot
        )
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

        invariantLock.lock()
        minimumLineCount = minimum
        invariantLock.unlock()
    }

    func listDir(_ path: String) throws -> String {
        try policy.authorize(tool: "list_dir", risk: .read)
        let url = try resolve(path)
        let key = url.path

        if let cached = taskCache.cachedList(key) {
            return cached
        }

        let names = try fm.contentsOfDirectory(atPath: url.path).sorted()
        let result = names.prefix(300).joined(separator: "\n")
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
            throw CLIError("file not found: \(path)")
        }
        guard !isDirectory.boolValue else {
            throw CLIError("path is a directory: \(path)")
        }

        let attributes = try fm.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > 1_500_000 {
            throw CLIError("file too large (>1.5MB): \(path)")
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        _ = try editEngine.observe(
            path: relative(url),
            content: text
        )
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
            _ = try editEngine.observe(path: path, content: oldText)

            if !taskCache.mayOverwrite(key) {
                taskCache.storeRead(key, content: oldText)
            }

            if oldText == content {
                return "unchanged \(path) · content already matches"
            }
        } else {
            _ = try editEngine.observe(path: path, content: nil)
        }

        try validateArtifactInvariants(path: path, content: content)

        let operation: EditOperationKind = exists ? .fullReplace : .create
        let prepared = try editEngine.prepare(
            path: path,
            before: previousContent,
            after: content,
            operation: operation
        )

        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)

            // Восстанавливаем права на исполнение
            if let perms = existingPerms {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            }

            let receipt = try editEngine.commit(prepared)
            if !exists { taskCache.markCreated(key) }
            taskCache.mutation(targetPath: key)

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
        _ = try editEngine.observe(path: path, content: text)
        taskCache.storeRead(key, content: text)

        // ИСПОЛЬЗУЕМ КУРСОРОВСКИЙ УМНЫЙ МАТЧЕР
        guard let range = SmartBlockMatcher.findRange(of: old, in: text) else {
            throw CLIError("old text block not found in \(path). Make sure to provide 2-3 exact surrounding lines as context.")
        }

        var updated = text
        updated.replaceSubrange(range, with: new)

        if updated == text {
            return "unchanged \(path)"
        }

        try validateArtifactInvariants(path: path, content: updated)

        let prepared = try editEngine.prepare(
            path: path,
            before: text,
            after: updated,
            operation: .exactReplace
        )

        do {
            try Data(updated.utf8).write(to: url, options: .atomic)

            if let perms = existingPerms {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            }

            let receipt = try editEngine.commit(prepared)
            taskCache.mutation(targetPath: key)

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
        _ = try editEngine.observe(path: path, content: text)
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
        _ = try editEngine.observe(path: path, content: text)
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
            path: path,
            before: text,
            after: updated,
            operation: .rangeReplace
        )

        do {
            try Data(updated.utf8).write(to: url, options: .atomic)
            let receipt = try editEngine.commit(prepared)
            taskCache.mutation(targetPath: key)
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
                "--max-count", "300",
                "--glob", "!.git/**",
                "--glob", "!node_modules/**",
                "--glob", "!DerivedData/**",
                "--glob", "!.build/**",
                "--glob", "!dist/**",
                query,
                relativeBase.isEmpty ? "." : relativeBase
            ]

            let runResult = try run(rg, arguments, 20, allow: [1])
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
                      (values?.fileSize ?? 0) < 750_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }

                for (lineNumber, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    where line.localizedCaseInsensitiveContains(query) {
                    hits.append("\(relative(url)):\(lineNumber + 1):\(line)")
                    if hits.count >= 300 { break outer }
                }
            }

            result = hits.isEmpty ? "no matches" : String(hits.joined(separator: "\n").prefix(32_000))
        }

        taskCache.storeSearch(cacheKey, result: result)
        return result
    }

    func shell(_ command: String) throws -> String {
        try policy.authorize(tool: "shell", risk: .shell)
        try policy.validateShell(command)

        let result = try run("/bin/zsh", ["-lc", command], shellTimeoutSeconds)
        taskCache.unknownShellMutation()
        return "exit=\(result.status)\n\(result.output)"
    }

    func validateFile(_ path: String) throws -> String {
        try policy.authorize(tool: "validate_file", risk: .shell)
        let url = try resolve(path)
        var isDirectory: ObjCBool = false

        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError("file not found: \(path)")
        }
        guard !isDirectory.boolValue else {
            throw CLIError("validate_file expects a file: \(path)")
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "swift":
            guard let swiftc = runtime.executables["swiftc"] else { throw CLIError("swiftc is not available") }
            _ = try run(swiftc, ["-parse", url.path], 60)
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
            _ = try run(python, ["-c", script, url.path], 30)
            return "python syntax valid: \(path)"
        case "js", "mjs", "cjs":
            guard let node = runtime.executables["node"] else { throw CLIError("node is not available") }
            _ = try run(node, ["--check", url.path], 30)
            return "javascript syntax valid: \(path)"
        default:
            return "syntax validation skipped for .\(ext)"
        }
    }

    func openFile(_ path: String) throws -> String {
        try policy.authorize(tool: "open_file", risk: .shell)
        let url = try resolve(path)
        let executable = runtime.executables["open"] ?? "/usr/bin/open"
        _ = try run(executable, [url.path], 15)
        return "opened \(path)"
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

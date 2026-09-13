import Foundation
import SLTACore

struct ArtifactRevisionID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        String(rawValue.uuidString.prefix(8)).lowercased()
    }
}

struct EditTransactionID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        String(rawValue.uuidString.prefix(8)).lowercased()
    }
}

struct CheckpointID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        String(rawValue.uuidString.prefix(8)).lowercased()
    }
}

enum ArtifactRevisionState: String, Codable, Sendable {
    case observed
    case proposed
    case applied
    case rejected
}

struct ArtifactRevision: Codable, Hashable, Sendable, CustomStringConvertible {
    let id: ArtifactRevisionID
    let path: String
    let number: Int
    let exists: Bool
    let byteCount: Int
    let lineCount: Int
    let snapshotFile: String
    let originTask: String?
    let createdAt: Date
    var state: ArtifactRevisionState
    /// SHA-256 hex of the revision content ("empty" hash when !exists).
    /// Added in v0.29; decoded as nil for pre-v0.29 persisted revisions.
    let contentHash: String?
    /// v0.29 revision origin (task mutation / external change / observation).
    /// Decoded as `.task` for pre-v0.29 persisted revisions.
    let origin: RevisionOrigin

    enum CodingKeys: String, CodingKey {
        case id, path, number, exists, byteCount, lineCount
        case snapshotFile, originTask, createdAt, state
        case contentHash, origin
    }

    init(
        id: ArtifactRevisionID,
        path: String,
        number: Int,
        exists: Bool,
        byteCount: Int,
        lineCount: Int,
        snapshotFile: String,
        originTask: String?,
        createdAt: Date,
        state: ArtifactRevisionState,
        contentHash: String? = nil,
        origin: RevisionOrigin = .task
    ) {
        self.id = id
        self.path = path
        self.number = number
        self.exists = exists
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.snapshotFile = snapshotFile
        self.originTask = originTask
        self.createdAt = createdAt
        self.state = state
        self.contentHash = contentHash
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ArtifactRevisionID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        number = try container.decode(Int.self, forKey: .number)
        exists = try container.decode(Bool.self, forKey: .exists)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        lineCount = try container.decode(Int.self, forKey: .lineCount)
        snapshotFile = try container.decode(String.self, forKey: .snapshotFile)
        originTask = try container.decodeIfPresent(String.self, forKey: .originTask)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        state = try container.decode(ArtifactRevisionState.self, forKey: .state)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        origin = try container.decodeIfPresent(RevisionOrigin.self, forKey: .origin) ?? .task
    }

    var description: String {
        "r\(number) \(state.rawValue) \(path) · \(byteCount) B · \(lineCount) lines"
    }
}

/// v0.29: where a revision came from. Persisted; unknown old data → .task.
enum RevisionOrigin: String, Codable, Sendable {
    case task
    case external
    case observed
    /// New revision restoring earlier content (undo/rollback).
    case rollback
    /// New revision restoring a checkpoint.
    case restore
}

struct EditLineRange: Codable, Hashable, Sendable, CustomStringConvertible {
    let startLine: Int
    let lineCount: Int

    var description: String {
        lineCount == 0
            ? "\(startLine),0"
            : "\(startLine),\(lineCount)"
    }
}

struct EditHunk: Codable, Hashable, Sendable, CustomStringConvertible {
    let oldRange: EditLineRange
    let newRange: EditLineRange
    let removedLines: [String]
    let addedLines: [String]

    var description: String {
        "@@ -\(oldRange) +\(newRange) @@ · -\(removedLines.count) +\(addedLines.count)"
    }

    func unifiedText(maxLines: Int = 400) -> String {
        var lines = ["@@ -\(oldRange) +\(newRange) @@"]
        let removed = removedLines.prefix(maxLines)
        let remainingAfterRemoved = max(0, maxLines - removed.count)
        let added = addedLines.prefix(remainingAfterRemoved)

        lines.append(contentsOf: removed.map { "-" + $0 })
        lines.append(contentsOf: added.map { "+" + $0 })

        let omitted = removedLines.count + addedLines.count - removed.count - added.count
        if omitted > 0 {
            lines.append("… \(omitted) changed lines omitted")
        }

        return lines.joined(separator: "\n")
    }
}

enum EditOperationKind: String, Codable, Sendable {
    case create
    case fullReplace
    case exactReplace
    case rangeReplace
    case rollback
    case restoreCheckpoint
}

enum EditTransactionStatus: String, Codable, Sendable {
    case proposed
    case applied
    case rejected
    case rolledBack
}

struct EditProposal: Codable, Hashable, Sendable, CustomStringConvertible {
    let path: String
    let operation: EditOperationKind
    let baseRevisionID: ArtifactRevisionID
    let proposedRevisionID: ArtifactRevisionID
    let hunks: [EditHunk]
    let originTask: String?

    var description: String {
        "\(operation.rawValue) \(path) · \(hunks.count) hunk(s)"
    }
}

struct EditTransaction: Codable, Hashable, Sendable, CustomStringConvertible {
    let id: EditTransactionID
    let proposal: EditProposal
    let baseRevisionNumber: Int
    let proposedRevisionNumber: Int
    let createdAt: Date
    var status: EditTransactionStatus
    var rollbackOf: EditTransactionID?
    var checkpointID: CheckpointID?

    var description: String {
        "tx \(id) \(status.rawValue) \(proposal.path) r\(baseRevisionNumber)→r\(proposedRevisionNumber) · \(proposal.hunks.count) hunk(s)"
    }

    func unifiedDiff(maxLinesPerHunk: Int = 400) -> String {
        var output = [
            "--- a/\(proposal.path)  (r\(baseRevisionNumber))",
            "+++ b/\(proposal.path)  (r\(proposedRevisionNumber))"
        ]

        if proposal.hunks.isEmpty {
            output.append("(no textual changes)")
        } else {
            for hunk in proposal.hunks {
                output.append(hunk.unifiedText(maxLines: maxLinesPerHunk))
            }
        }

        return output.joined(separator: "\n")
    }
}

struct EditTransactionRef: Hashable, Sendable, CustomStringConvertible {
    let id: EditTransactionID
    let path: String
    let baseRevision: Int
    let newRevision: Int

    var description: String {
        "tx=\(id) r\(baseRevision)→r\(newRevision)"
    }
}

struct EditCheckpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    let id: CheckpointID
    let path: String
    let revisionID: ArtifactRevisionID
    let revisionNumber: Int
    let label: String
    let originTask: String?
    let createdAt: Date

    var description: String {
        "checkpoint \(id) \(path)@r\(revisionNumber) · \(label)"
    }
}

struct PreparedEdit: Sendable {
    let transaction: EditTransaction
}

private struct RevisionStoreState: Codable {
    var revisions: [ArtifactRevision] = []
}

final class RevisionStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fm = FileManager.default
    private let root: URL
    private let metadataURL: URL
    private let snapshotsURL: URL
    private var state: RevisionStoreState

    init(root: URL) {
        self.root = root
        self.metadataURL = root.appendingPathComponent("revisions.json")
        self.snapshotsURL = root.appendingPathComponent("snapshots", isDirectory: true)

        try? fm.createDirectory(
            at: snapshotsURL,
            withIntermediateDirectories: true
        )

        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder.slta.decode(RevisionStoreState.self, from: data) {
            self.state = decoded
        } else {
            self.state = RevisionStoreState()
        }
    }

    func synchronize(
        path: String,
        content: String?,
        originTask: String?
    ) throws -> ArtifactRevision {
        lock.lock()
        defer { lock.unlock() }

        if let latest = latestCurrentLocked(path: path),
           try snapshotContentLocked(latest) == (content ?? ""),
           latest.exists == (content != nil) {
            return latest
        }

        let number = (latestCurrentLocked(path: path)?.number ?? -1) + 1
        let revision = try createRevisionLocked(
            path: path,
            number: number,
            content: content,
            originTask: originTask,
            state: .observed
        )
        persistLocked()
        return revision
    }

    func prepareRevision(
        path: String,
        content: String,
        originTask: String?,
        origin: RevisionOrigin = .task
    ) throws -> ArtifactRevision {
        lock.lock()
        defer { lock.unlock() }

        let number = latestNumberLocked(path: path) + 1
        let revision = try createRevisionLocked(
            path: path,
            number: number,
            content: content,
            originTask: originTask,
            state: .proposed,
            origin: origin
        )
        persistLocked()
        return revision
    }

    func commit(_ id: ArtifactRevisionID) throws -> ArtifactRevision {
        lock.lock()
        defer { lock.unlock() }

        guard let index = state.revisions.firstIndex(where: { $0.id == id }) else {
            throw CLIError("revision not found: \(id)")
        }

        state.revisions[index].state = .applied
        let revision = state.revisions[index]
        persistLocked()
        return revision
    }

    func reject(_ id: ArtifactRevisionID) {
        lock.lock()
        defer { lock.unlock() }

        guard let index = state.revisions.firstIndex(where: { $0.id == id }) else {
            return
        }
        state.revisions[index].state = .rejected
        persistLocked()
    }

    func latestCurrent(path: String) -> ArtifactRevision? {
        lock.lock()
        defer { lock.unlock() }
        return latestCurrentLocked(path: path)
    }

    func revision(_ id: ArtifactRevisionID) -> ArtifactRevision? {
        lock.lock()
        defer { lock.unlock() }
        return state.revisions.first(where: { $0.id == id })
    }

    func content(_ id: ArtifactRevisionID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let revision = state.revisions.first(where: { $0.id == id }) else {
            throw CLIError("revision not found: \(id)")
        }
        guard revision.exists else {
            return nil
        }
        return try snapshotContentLocked(revision)
    }

    func history(path: String, limit: Int = 30) -> [ArtifactRevision] {
        lock.lock()
        defer { lock.unlock() }

        return Array(
            state.revisions
                .filter { $0.path == path && $0.state != .rejected }
                .sorted { $0.number < $1.number }
                .suffix(limit)
        )
    }

    private func latestCurrentLocked(path: String) -> ArtifactRevision? {
        state.revisions
            .filter {
                $0.path == path &&
                ($0.state == .observed || $0.state == .applied)
            }
            .max(by: { $0.number < $1.number })
    }

    private func latestNumberLocked(path: String) -> Int {
        state.revisions
            .filter { $0.path == path && $0.state != .rejected }
            .map(\.number)
            .max() ?? -1
    }

    private func createRevisionLocked(
        path: String,
        number: Int,
        content: String?,
        originTask: String?,
        state revisionState: ArtifactRevisionState,
        origin: RevisionOrigin = .task
    ) throws -> ArtifactRevision {
        let id = ArtifactRevisionID()
        let snapshotFile = id.rawValue.uuidString.lowercased() + ".txt"
        let snapshotURL = snapshotsURL.appendingPathComponent(snapshotFile)
        let bytes = Data((content ?? "").utf8)
        try bytes.write(to: snapshotURL, options: .atomic)

        let revision = ArtifactRevision(
            id: id,
            path: path,
            number: number,
            exists: content != nil,
            byteCount: bytes.count,
            lineCount: Self.lineCount(content),
            snapshotFile: snapshotFile,
            originTask: originTask,
            createdAt: Date(),
            state: revisionState,
            contentHash: ArtifactHash.sha256(content ?? ""),
            origin: origin
        )
        state.revisions.append(revision)
        return revision
    }

    private func snapshotContentLocked(_ revision: ArtifactRevision) throws -> String {
        let url = snapshotsURL.appendingPathComponent(revision.snapshotFile)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func persistLocked() {
        do {
            let data = try JSONEncoder.pretty.encode(state)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            AppLog.persistenceError("persistLocked \(type(of: self)): \(error.localizedDescription)")
        }
    }

    private static func lineCount(_ content: String?) -> Int {
        guard let content, !content.isEmpty else { return 0 }
        return content.components(separatedBy: "\n").count
    }
}

private struct CheckpointStoreState: Codable {
    var checkpoints: [EditCheckpoint] = []
}

final class CheckpointStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fm = FileManager.default
    private let root: URL
    private let metadataURL: URL
    private var state: CheckpointStoreState

    init(root: URL) {
        self.root = root
        self.metadataURL = root.appendingPathComponent("checkpoints.json")

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder.slta.decode(CheckpointStoreState.self, from: data) {
            self.state = decoded
        } else {
            self.state = CheckpointStoreState()
        }
    }

    func create(
        path: String,
        revision: ArtifactRevision,
        label: String,
        originTask: String?
    ) -> EditCheckpoint {
        lock.lock()
        defer { lock.unlock() }

        let checkpoint = EditCheckpoint(
            id: CheckpointID(),
            path: path,
            revisionID: revision.id,
            revisionNumber: revision.number,
            label: label,
            originTask: originTask,
            createdAt: Date()
        )
        state.checkpoints.append(checkpoint)
        if state.checkpoints.count > 500 {
            state.checkpoints.removeFirst(state.checkpoints.count - 500)
        }
        persistLocked()
        return checkpoint
    }

    func contains(
        path: String,
        originTask: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return state.checkpoints.contains {
            $0.path == path &&
            $0.originTask == originTask
        }
    }

    func resolve(prefix: String) -> EditCheckpoint? {
        lock.lock()
        defer { lock.unlock() }

        let normalized = prefix.lowercased()
        return state.checkpoints.reversed().first {
            $0.id.rawValue.uuidString.lowercased().hasPrefix(normalized)
        }
    }

    func list(path: String? = nil, limit: Int = 30) -> [EditCheckpoint] {
        lock.lock()
        defer { lock.unlock() }

        let filtered = path.map { expected in
            state.checkpoints.filter { $0.path == expected }
        } ?? state.checkpoints

        return Array(filtered.suffix(limit))
    }

    private func persistLocked() {
        do {
            let data = try JSONEncoder.pretty.encode(state)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            AppLog.persistenceError("persistLocked \(type(of: self)): \(error.localizedDescription)")
        }
    }
}

private struct EditTransactionStoreState: Codable {
    var transactions: [EditTransaction] = []
}

final class EditEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let fm = FileManager.default
    private let root: URL
    private let transactionsURL: URL
    private let revisions: RevisionStore
    private let checkpoints: CheckpointStore
    private var transactionState: EditTransactionStoreState
    private var currentTaskID: String?

    init(
        projectRoot: URL,
        historyRoot: URL? = nil
    ) {
        let baseRoot: URL
        if let historyRoot {
            baseRoot = historyRoot
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            baseRoot = home
                .appendingPathComponent(".slta", isDirectory: true)
                .appendingPathComponent("edit-history", isDirectory: true)
                .appendingPathComponent(Self.stableProjectKey(projectRoot.path), isDirectory: true)
        }

        self.root = baseRoot
        self.transactionsURL = baseRoot.appendingPathComponent("transactions.json")
        self.revisions = RevisionStore(
            root: baseRoot.appendingPathComponent("revisions", isDirectory: true)
        )
        self.checkpoints = CheckpointStore(
            root: baseRoot.appendingPathComponent("checkpoints", isDirectory: true)
        )

        try? fm.createDirectory(at: baseRoot, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: transactionsURL),
           let decoded = try? JSONDecoder.slta.decode(EditTransactionStoreState.self, from: data) {
            self.transactionState = decoded
        } else {
            self.transactionState = EditTransactionStoreState()
        }
    }

    func beginTask(_ taskID: TaskID?) {
        lock.lock()
        currentTaskID = taskID?.rawValue.uuidString.lowercased()
        lock.unlock()
    }

    @discardableResult
    func observe(path: String, content: String?) throws -> ArtifactRevision {
        let task = currentTask()
        return try revisions.synchronize(
            path: path,
            content: content,
            originTask: task
        )
    }

    func prepare(
        path: String,
        before: String?,
        after: String,
        operation: EditOperationKind,
        rollbackOf: EditTransactionID? = nil,
        checkpointID: CheckpointID? = nil,
        origin: RevisionOrigin = .task
    ) throws -> PreparedEdit {
        let task = currentTask()
        let base = try revisions.synchronize(
            path: path,
            content: before,
            originTask: task
        )

        if let task,
           base.exists,
           operation == .fullReplace ||
           operation == .exactReplace ||
           operation == .rangeReplace {
            if !checkpoints.contains(
                path: path,
                originTask: task
            ) {
                _ = checkpoints.create(
                    path: path,
                    revision: base,
                    label: "automatic · before task " + String(task.prefix(8)),
                    originTask: task
                )
            }
        }

        let proposed = try revisions.prepareRevision(
            path: path,
            content: after,
            originTask: task,
            origin: origin
        )

        let proposal = EditProposal(
            path: path,
            operation: operation,
            baseRevisionID: base.id,
            proposedRevisionID: proposed.id,
            hunks: Self.buildHunks(before: before, after: after),
            originTask: task
        )

        let transaction = EditTransaction(
            id: EditTransactionID(),
            proposal: proposal,
            baseRevisionNumber: base.number,
            proposedRevisionNumber: proposed.number,
            createdAt: Date(),
            status: .proposed,
            rollbackOf: rollbackOf,
            checkpointID: checkpointID
        )

        lock.lock()
        transactionState.transactions.append(transaction)
        trimTransactionsLocked()
        persistTransactionsLocked()
        lock.unlock()

        return PreparedEdit(transaction: transaction)
    }

    @discardableResult
    func commit(_ prepared: PreparedEdit) throws -> EditTransactionRef {
        _ = try revisions.commit(prepared.transaction.proposal.proposedRevisionID)

        lock.lock()
        defer { lock.unlock() }

        guard let index = transactionState.transactions.firstIndex(
            where: { $0.id == prepared.transaction.id }
        ) else {
            throw CLIError("edit transaction not found: \(prepared.transaction.id)")
        }

        transactionState.transactions[index].status = .applied

        if let rollbackOf = transactionState.transactions[index].rollbackOf,
           let originalIndex = transactionState.transactions.firstIndex(where: { $0.id == rollbackOf }),
           transactionState.transactions[originalIndex].status == .applied {
            transactionState.transactions[originalIndex].status = .rolledBack
        }

        let transaction = transactionState.transactions[index]
        persistTransactionsLocked()

        return EditTransactionRef(
            id: transaction.id,
            path: transaction.proposal.path,
            baseRevision: transaction.baseRevisionNumber,
            newRevision: transaction.proposedRevisionNumber
        )
    }

    func reject(_ prepared: PreparedEdit) {
        revisions.reject(prepared.transaction.proposal.proposedRevisionID)

        lock.lock()
        defer { lock.unlock() }

        guard let index = transactionState.transactions.firstIndex(
            where: { $0.id == prepared.transaction.id }
        ) else {
            return
        }
        transactionState.transactions[index].status = .rejected
        persistTransactionsLocked()
    }

    func rejectTransaction(prefix: String) throws -> EditTransaction {
        lock.lock()
        defer { lock.unlock() }

        guard let index = resolveTransactionIndexLocked(prefix: prefix) else {
            throw CLIError("edit transaction not found: \(prefix)")
        }
        guard transactionState.transactions[index].status == .proposed else {
            throw CLIError("transaction is not pending: \(prefix)")
        }

        let revisionID = transactionState.transactions[index].proposal.proposedRevisionID
        revisions.reject(revisionID)
        transactionState.transactions[index].status = .rejected
        let transaction = transactionState.transactions[index]
        persistTransactionsLocked()
        return transaction
    }

    func latestReceipt(path: String) -> EditTransactionRef? {
        lock.lock()
        defer { lock.unlock() }

        guard let transaction = transactionState.transactions.reversed().first(
            where: { $0.proposal.path == path && $0.status == .applied }
        ) else {
            return nil
        }

        return EditTransactionRef(
            id: transaction.id,
            path: path,
            baseRevision: transaction.baseRevisionNumber,
            newRevision: transaction.proposedRevisionNumber
        )
    }

    func latestAppliedTransaction(path: String) -> EditTransaction? {
        lock.lock()
        defer { lock.unlock() }
        return transactionState.transactions.reversed().first {
            $0.proposal.path == path &&
            $0.status == .applied
        }
    }

    func latestUndoCandidate(path: String) -> EditTransaction? {
        lock.lock()
        defer { lock.unlock() }

        return transactionState.transactions.reversed().first {
            guard $0.proposal.path == path,
                  $0.status == .applied else {
                return false
            }

            switch $0.proposal.operation {
            case .rollback:
                return false
            case .create, .fullReplace, .exactReplace, .rangeReplace, .restoreCheckpoint:
                return true
            }
        }
    }

    func prepareRollback(path: String, currentContent: String) throws -> PreparedEdit {
        guard let original = latestUndoCandidate(path: path) else {
            throw CLIError("no applied edit transaction to roll back for \(path)")
        }

        let baseContent = try revisions.content(original.proposal.baseRevisionID)
        guard let baseContent else {
            throw CLIError("rollback would delete \(path); file deletion is not implemented in v0.26")
        }

        return try prepare(
            path: path,
            before: currentContent,
            after: baseContent,
            operation: .rollback,
            rollbackOf: original.id,
            origin: .rollback
        )
    }

    func createCheckpoint(
        path: String,
        currentContent: String,
        label: String
    ) throws -> EditCheckpoint {
        let revision = try revisions.synchronize(
            path: path,
            content: currentContent,
            originTask: currentTask()
        )
        return checkpoints.create(
            path: path,
            revision: revision,
            label: label,
            originTask: currentTask()
        )
    }

    func prepareRestoreCheckpoint(
        prefix: String,
        currentPath: String,
        currentContent: String
    ) throws -> PreparedEdit {
        guard let checkpoint = checkpoints.resolve(prefix: prefix) else {
            throw CLIError("checkpoint not found: \(prefix)")
        }
        guard checkpoint.path == currentPath else {
            throw CLIError(
                "checkpoint \(checkpoint.id) belongs to \(checkpoint.path), not \(currentPath)"
            )
        }
        guard let targetContent = try revisions.content(checkpoint.revisionID) else {
            throw CLIError("checkpoint points to a non-existing file revision")
        }

        return try prepare(
            path: currentPath,
            before: currentContent,
            after: targetContent,
            operation: .restoreCheckpoint,
            checkpointID: checkpoint.id,
            origin: .restore
        )
    }

    func transaction(prefix: String?) -> EditTransaction? {
        lock.lock()
        defer { lock.unlock() }

        guard let prefix, !prefix.isEmpty else {
            return transactionState.transactions.last
        }
        guard let index = resolveTransactionIndexLocked(prefix: prefix) else {
            return nil
        }
        return transactionState.transactions[index]
    }

    func recentTransactions(limit: Int = 20) -> [EditTransaction] {
        lock.lock()
        defer { lock.unlock() }
        return Array(transactionState.transactions.suffix(limit))
    }

    func revisionHistory(path: String, limit: Int = 30) -> [ArtifactRevision] {
        revisions.history(path: path, limit: limit)
    }

    /// v0.29: latest live revision for ArtifactGraph registration.
    func latestRevision(path: String) -> ArtifactRevision? {
        revisions.latestCurrent(path: path)
    }

    /// v0.29: revision record by ID for persistence snapshots.
    func revision(_ id: ArtifactRevisionID) -> ArtifactRevision? {
        revisions.revision(id)
    }

    func checkpointHistory(path: String? = nil, limit: Int = 30) -> [EditCheckpoint] {
        checkpoints.list(path: path, limit: limit)
    }

    func revisionContent(_ id: ArtifactRevisionID) throws -> String? {
        try revisions.content(id)
    }

    func diffText(prefix: String? = nil) throws -> String {
        guard let transaction = transaction(prefix: prefix) else {
            throw CLIError(prefix == nil ? "no edit transactions yet" : "edit transaction not found: \(prefix!)")
        }
        return transaction.description + "\n" + transaction.unifiedDiff()
    }

    func transactionHistoryText(limit: Int = 20) -> String {
        let items = recentTransactions(limit: limit)
        guard !items.isEmpty else {
            return "no edit transactions yet"
        }
        return items.map(\.description).joined(separator: "\n")
    }

    func revisionHistoryText(path: String, limit: Int = 30) -> String {
        let items = revisionHistory(path: path, limit: limit)
        guard !items.isEmpty else {
            return "no revisions recorded for \(path)"
        }
        return items.map(\.description).joined(separator: "\n")
    }

    func checkpointHistoryText(path: String? = nil, limit: Int = 30) -> String {
        let items = checkpointHistory(path: path, limit: limit)
        guard !items.isEmpty else {
            return "no checkpoints yet"
        }
        return items.map(\.description).joined(separator: "\n")
    }

    private func currentTask() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return currentTaskID
    }

    private func resolveTransactionIndexLocked(prefix: String) -> Int? {
        let normalized = prefix.lowercased()
        return transactionState.transactions.indices.reversed().first {
            transactionState.transactions[$0]
                .id.rawValue.uuidString.lowercased()
                .hasPrefix(normalized)
        }
    }

    private func trimTransactionsLocked() {
        if transactionState.transactions.count > 2_000 {
            transactionState.transactions.removeFirst(
                transactionState.transactions.count - 2_000
            )
        }
    }

    private func persistTransactionsLocked() {
        do {
            let data = try JSONEncoder.pretty.encode(transactionState)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: transactionsURL, options: .atomic)
        } catch {
            AppLog.persistenceError("persistTransactionsLocked: \(error.localizedDescription)")
        }
    }

    private static func buildHunks(
        before: String?,
        after: String
    ) -> [EditHunk] {
        let oldLines = lines(before)
        let newLines = lines(after)

        guard oldLines != newLines else {
            return []
        }

        let difference = newLines.difference(from: oldLines)
        let removedOffsets: Set<Int> = Set(
            difference.compactMap { change in
                guard case .remove(let offset, _, _) = change else {
                    return nil
                }
                return offset
            }
        )
        let insertedOffsets: Set<Int> = Set(
            difference.compactMap { change in
                guard case .insert(let offset, _, _) = change else {
                    return nil
                }
                return offset
            }
        )

        var hunks: [EditHunk] = []
        var oldIndex = 0
        var newIndex = 0

        var hunkOldStart: Int?
        var hunkNewStart: Int?
        var removed: [String] = []
        var added: [String] = []

        func flushHunk() {
            guard let oldStart = hunkOldStart,
                  let newStart = hunkNewStart else {
                return
            }

            hunks.append(
                EditHunk(
                    oldRange: EditLineRange(
                        startLine: oldStart + 1,
                        lineCount: removed.count
                    ),
                    newRange: EditLineRange(
                        startLine: newStart + 1,
                        lineCount: added.count
                    ),
                    removedLines: removed,
                    addedLines: added
                )
            )

            hunkOldStart = nil
            hunkNewStart = nil
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        while oldIndex < oldLines.count ||
              newIndex < newLines.count {
            if oldIndex < oldLines.count,
               removedOffsets.contains(oldIndex) {
                if hunkOldStart == nil {
                    hunkOldStart = oldIndex
                    hunkNewStart = newIndex
                }
                removed.append(oldLines[oldIndex])
                oldIndex += 1
                continue
            }

            if newIndex < newLines.count,
               insertedOffsets.contains(newIndex) {
                if hunkOldStart == nil {
                    hunkOldStart = oldIndex
                    hunkNewStart = newIndex
                }
                added.append(newLines[newIndex])
                newIndex += 1
                continue
            }

            if oldIndex < oldLines.count,
               newIndex < newLines.count,
               oldLines[oldIndex] == newLines[newIndex] {
                flushHunk()
                oldIndex += 1
                newIndex += 1
                continue
            }

            // CollectionDifference should align all unchanged lines after
            // consuming its remove/insert offsets. If an unexpected mismatch
            // appears, fall back to one safe central hunk instead of emitting
            // a misleading diff.
            return buildCentralHunk(
                oldLines: oldLines,
                newLines: newLines
            )
        }

        flushHunk()

        return hunks.isEmpty
            ? buildCentralHunk(
                oldLines: oldLines,
                newLines: newLines
            )
            : hunks
    }

    private static func buildCentralHunk(
        oldLines: [String],
        newLines: [String]
    ) -> [EditHunk] {
        var prefix = 0
        let commonMaximum = min(
            oldLines.count,
            newLines.count
        )

        while prefix < commonMaximum,
              oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] ==
                newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let oldEnd = oldLines.count - suffix
        let newEnd = newLines.count - suffix

        let removed = prefix < oldEnd
            ? Array(oldLines[prefix..<oldEnd])
            : []
        let added = prefix < newEnd
            ? Array(newLines[prefix..<newEnd])
            : []

        return [
            EditHunk(
                oldRange: EditLineRange(
                    startLine: oldLines.isEmpty ? 0 : prefix + 1,
                    lineCount: removed.count
                ),
                newRange: EditLineRange(
                    startLine: newLines.isEmpty ? 0 : prefix + 1,
                    lineCount: added.count
                ),
                removedLines: removed,
                addedLines: added
            )
        ]
    }

    private static func lines(_ content: String?) -> [String] {
        guard let content, !content.isEmpty else {
            return []
        }
        return content.components(separatedBy: "\n")
    }

    private static func stableProjectKey(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        let leaf = URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]"#,
                with: "_",
                options: .regularExpression
            )
        return "\(leaf)-\(String(hash, radix: 16))"
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}


private extension JSONDecoder {
    static var slta: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

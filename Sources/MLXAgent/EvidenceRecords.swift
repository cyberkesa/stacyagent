import Foundation

// MARK: - v0.29 Typed, revision-aware evidence records
//
// One EvidenceRecord per evidence event. Every record that concerns a file
// binds to a CONCRETE ArtifactRevisionID — never to "the file" in general.
// Stored inside the existing EvidenceStore (TaskSemantics.swift), not in a
// parallel store: EvidenceStore.items stays the legacy order-based
// projection consumed by snapshots/descriptions, records[] is the
// revision-aware truth used for freshness AND persistence.
//
// Restore rebuilds legacy items 1:1 from records, so every record maps to
// exactly one legacy item (diagnostics become .toolFailed).

enum EvidenceKind: String, Codable, Sendable {
    case observed
    case readBack
    case mutation
    case validation
    case launch
    case test
    case external
    case diagnostic
}

struct EvidenceRecord: Codable, Sendable {
    var id: UUID
    /// Owning task, string form of TaskID ("no-task" when taskless).
    var taskID: String
    var kind: EvidenceKind
    /// Producing tool, e.g. "read_file", "edit_file", "pytest".
    var tool: String
    var path: String?
    /// Concrete revision this evidence belongs to. Nil only for
    /// pathless evidence (external effects, chat-level diagnostics).
    var revisionID: UUID?
    var createdAt: Date
    /// Compact human payload, e.g. "wrote a.html · 120 B".
    var detail: String
    // MARK: fidelity fields for 1:1 legacy rebuild
    var changed: Bool?
    var matched: Bool?
    var server: String?
    var operation: String?
    var urls: [String]

    init(
        id: UUID = UUID(),
        taskID: String,
        kind: EvidenceKind,
        tool: String,
        path: String? = nil,
        revisionID: UUID? = nil,
        createdAt: Date = Date(),
        detail: String,
        changed: Bool? = nil,
        matched: Bool? = nil,
        server: String? = nil,
        operation: String? = nil,
        urls: [String] = []
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.tool = tool
        self.path = path
        self.revisionID = revisionID
        self.createdAt = createdAt
        self.detail = detail
        self.changed = changed
        self.matched = matched
        self.server = server
        self.operation = operation
        self.urls = urls
    }

    /// Legacy TaskEvidence projection rebuilt from this record on restore.
    /// Revision linkage lives in parallel (TaskRuntimeSnapshot), not here.
    func legacyEvidence(transaction: EditTransactionRef?) -> TaskEvidence {
        switch kind {
        case .observed:
            return .observed(tool: tool, path: path)
        case .readBack:
            return .readBack(path: path ?? "", matched: matched ?? true)
        case .mutation:
            return .mutated(tool: tool, path: path, changed: changed ?? true, transaction: transaction)
        case .validation:
            return .validated(tool: tool, path: path)
        case .launch:
            return .launched(tool: tool, path: path)
        case .test:
            // Test runs validate the artifact under test.
            return .validated(tool: tool, path: path)
        case .external:
            return .externalEffect(tool: tool, server: server, operation: operation, urls: urls)
        case .diagnostic:
            let prefix = "tool failed: "
            if detail.hasPrefix(prefix) {
                return .toolFailed(tool: tool, message: String(detail.dropFirst(prefix.count)))
            }
            return .toolFailed(tool: tool, message: detail)
        }
    }
}

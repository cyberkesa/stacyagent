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
    /// v0.30 structural completion (e.g. rename), with per-path revisions.
    case semantic
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
    // MARK: v0.30 semantic completion linkage
    var symbol: String?
    var newName: String?
    var paths: [String]
    /// Per-path resulting revisions (path -> revision UUID).
    var revisions: [String: UUID]

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
        urls: [String] = [],
        symbol: String? = nil,
        newName: String? = nil,
        paths: [String] = [],
        revisions: [String: UUID] = [:]
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
        self.symbol = symbol
        self.newName = newName
        self.paths = paths
        self.revisions = revisions
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskID, kind, tool, path, revisionID, createdAt, detail
        case changed, matched, server, operation, urls
        case symbol, newName, paths, revisions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        taskID = try container.decode(String.self, forKey: .taskID)
        kind = try container.decode(EvidenceKind.self, forKey: .kind)
        tool = try container.decode(String.self, forKey: .tool)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        revisionID = try container.decodeIfPresent(UUID.self, forKey: .revisionID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        detail = try container.decode(String.self, forKey: .detail)
        changed = try container.decodeIfPresent(Bool.self, forKey: .changed)
        matched = try container.decodeIfPresent(Bool.self, forKey: .matched)
        server = try container.decodeIfPresent(String.self, forKey: .server)
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
        urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        newName = try container.decodeIfPresent(String.self, forKey: .newName)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        revisions = try container.decodeIfPresent([String: UUID].self, forKey: .revisions) ?? [:]
    }

    /// All per-path resulting revisions still current (non-empty).
    func revisionsAllCurrent(_ current: [String: ArtifactRevisionID]) -> Bool {
        guard !revisions.isEmpty else { return false }
        return revisions.allSatisfy { path, id in current[path]?.rawValue == id }
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
        case .semantic:
            return .mutated(
                tool: tool,
                path: path ?? paths.first,
                changed: true,
                transaction: transaction
            )
        }
    }
}

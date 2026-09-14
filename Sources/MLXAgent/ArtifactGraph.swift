import CryptoKit
import Foundation

// MARK: - v0.29 ArtifactGraph
//
// Model-independent runtime component: the single revision-aware source of
// truth about project artifacts. No MLX imports. No SessionContext.
//
// Revision records REUSE EditEngine.ArtifactRevision (extended with
// contentHash/origin) — no parallel revision system. The graph keeps the
// *current* pointer per canonical workspace-relative path plus bounded
// history references and task relationships.
//
// Freshness rule (single rule, used everywhere):
//   evidence bound to revision R of path P is fresh  <=>  R == current(P).
//   evidence with unknown revision on a tracked path  =>  stale.
//   evidence on an untracked path                     =>  legacy order-based.

// MARK: - Hashing

enum ArtifactHash {
    /// SHA-256 hex of UTF-8 content. Canonical "empty" digest for missing files.
    static func sha256(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256File(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Node

/// Runtime view of one artifact. History entries are EditEngine revisions
/// (same IDs); the graph only owns the current pointer + relationships.
struct ArtifactNode: Sendable {
    var path: String
    var currentRevisionID: ArtifactRevisionID?
    var currentNumber: Int = -1
    var currentHash: String?
    var exists: Bool = false
    var kind: ArtifactType = .unknown
    var language: String?
    /// Bounded newest-last history of revision IDs (default cap 50).
    var history: [ArtifactRevisionID] = []
    /// Task IDs (string form) that touched this artifact.
    var taskIDs: Set<String> = []
}

// MARK: - Persisted form

struct PersistedArtifactNode: Codable, Sendable {
    var path: String
    var currentRevisionID: UUID?
    var currentNumber: Int
    var currentHash: String?
    var exists: Bool
    var kind: String
    var language: String?
    var history: [UUID]
    var taskIDs: [String]
    /// Full revision records so restore does not depend on the
    /// EditEngine snapshot store alone.
    var revisions: [ArtifactRevision]
}

struct PersistedArtifactGraph: Codable, Sendable {
    var schemaVersion: Int
    var nodes: [PersistedArtifactNode]
    /// v0.30 monotonic semantic generation (defaults to 0 for v0.29 files).
    var generation: UInt64

    enum CodingKeys: String, CodingKey {
        case schemaVersion, nodes, generation
    }

    init(schemaVersion: Int, nodes: [PersistedArtifactNode], generation: UInt64 = 0) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
        self.generation = generation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        nodes = try container.decode([PersistedArtifactNode].self, forKey: .nodes)
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
    }
}

// MARK: - Graph

/// Lock-guarded, Sendable. Owned by Workspace (single instance per project),
/// read by ToolRegistry/RuntimeState, persisted by RuntimePersistence.
final class ArtifactGraph: @unchecked Sendable {
    static let schemaVersion = 1
    static let historyCap = 50

    private let lock = NSLock()
    private var nodes: [String: ArtifactNode] = [:]
    /// Full records of synthetic external revisions (EditEngine never sees
    /// them; persistence carries them inside node.revisions).
    private var externalRecords: [ArtifactRevisionID: ArtifactRevision] = [:]
    private var lastExternal: [String: ArtifactRevisionID] = [:]
    /// Revision IDs that must never be evicted: referenced by evidence
    /// journal, edit transactions, checkpoints or persisted tasks.
    private var pinned: Set<ArtifactRevisionID> = []
    /// v0.30 monotonic workspace semantic generation. Bumped on EVERY
    /// current-revision change (register/markExternal/restore), so
    /// workspace-scoped semantic facts can detect staleness cheaply.
    private var semanticGenerationValue: UInt64 = 0

    init() {}

    // MARK: Queries (synchronous, cheap)

    func node(path: String) -> ArtifactNode? {
        lock.withLock { nodes[path] }
    }

    func currentRevisionID(path: String) -> ArtifactRevisionID? {
        lock.withLock { nodes[path]?.currentRevisionID }
    }

    func currentHash(path: String) -> String? {
        lock.withLock { nodes[path]?.currentHash }
    }

    func allPaths() -> [String] {
        lock.withLock { Array(nodes.keys) }
    }

    /// path -> current revision ID. Pushed into RuntimeState per snapshot.
    func currentMap() -> [String: ArtifactRevisionID] {
        lock.withLock {
            var out: [String: ArtifactRevisionID] = [:]
            for (path, node) in nodes {
                if let id = node.currentRevisionID {
                    out[path] = id
                }
            }
            return out
        }
    }

    /// Freshness predicate: revision R of P is fresh iff R == current(P).
    /// Unknown revision on a TRACKED path is stale; untracked paths defer
    /// to legacy order-based evidence (migration-safe).
    func isFresh(path: String, revision: ArtifactRevisionID?) -> Bool {
        lock.withLock {
            guard let node = nodes[path] else { return true }
            guard let revision else { return false }
            return node.currentRevisionID == revision
        }
    }

    // MARK: Updates

    /// Register an EditEngine revision as current for its path.
    /// Returns true when the current pointer actually moved.
    /// Current semantic generation (monotonic).
    func semanticGeneration() -> UInt64 {
        lock.withLock { semanticGenerationValue }
    }

    @discardableResult
    func registerRevision(
        _ revision: ArtifactRevision,
        contentHash: String?,
        taskID: String?,
        kind: ArtifactType? = nil,
        language: String? = nil
    ) -> Bool {
        lock.withLock {
            var node = nodes[revision.path] ?? ArtifactNode(path: revision.path)
            let moved = node.currentRevisionID != revision.id
            node.currentRevisionID = revision.id
            node.currentNumber = revision.number
            node.currentHash = contentHash ?? revision.contentHash
            node.exists = revision.exists
            if let kind { node.kind = kind }
            if let language { node.language = language }
            if let taskID { node.taskIDs.insert(taskID) }
            if !node.history.contains(revision.id) {
                // No live cap: eviction happens only in retain(pinned:),
                // which keeps newest 50 UNION pinned. Live history is just
                // UUIDs; bounding happens at persist time (v0.29.1 inv.4).
                node.history.append(revision.id)
            }
            nodes[revision.path] = node
            if moved {
                semanticGenerationValue &+= 1
            }
            return moved
        }
    }

    /// First sight of a path (read before any SLTA mutation): adopt the
    /// observed revision as current WITHOUT bumping (reads never create
    /// new current revisions).
    func adoptIfUnknown(
        _ revision: ArtifactRevision,
        contentHash: String?,
        taskID: String?
    ) {
        lock.withLock {
            guard nodes[revision.path] == nil else { return }
            var node = ArtifactNode(path: revision.path)
            node.currentRevisionID = revision.id
            node.currentNumber = revision.number
            node.currentHash = contentHash ?? revision.contentHash
            node.exists = revision.exists
            node.kind = ArtifactType.infer(path: revision.path)
            if let taskID { node.taskIDs.insert(taskID) }
            node.history = [revision.id]
            nodes[revision.path] = node
        }
    }

    /// External disk change: the file no longer matches the known revision.
    /// Records a synthetic external revision and moves current. Previous
    /// observation/validation evidence automatically goes stale via isFresh.
    /// Returns the new revision record, or nil when nothing changed.
    func markExternal(
        path: String,
        contentHash: String,
        exists: Bool,
        byteCount: Int,
        lineCount: Int
    ) -> ArtifactRevision? {
        lock.withLock {
            if let node = nodes[path],
               node.currentHash == contentHash,
               node.exists == exists {
                return nil
            }
            var node = nodes[path] ?? ArtifactNode(path: path)
            let number = node.currentNumber + 1
            let revision = ArtifactRevision(
                id: ArtifactRevisionID(),
                path: path,
                number: number,
                exists: exists,
                byteCount: byteCount,
                lineCount: lineCount,
                snapshotFile: "",
                originTask: nil,
                createdAt: Date(),
                state: .observed,
                contentHash: contentHash,
                origin: .external
            )
            node.currentRevisionID = revision.id
            node.currentNumber = number
            node.currentHash = contentHash
            node.exists = exists
            node.kind = ArtifactType.infer(path: path)
            node.history.append(revision.id)
            nodes[path] = node
            semanticGenerationValue &+= 1
            externalRecords[revision.id] = revision
            lastExternal[path] = revision.id
            return revision
        }
    }

    func externalRecord(_ id: ArtifactRevisionID) -> ArtifactRevision? {
        lock.withLock { externalRecords[id] }
    }

    /// Current revision came from an external change (for event emission).
    func isExternalCurrent(path: String) -> Bool {
        lock.withLock {
            guard let current = nodes[path]?.currentRevisionID else { return false }
            return lastExternal[path] == current
        }
    }

    /// Declare the referenced set, then prune history to
    /// (newest 50 per node) UNION pinned. Pinned metadata always stays
    /// resolvable via snapshot(); unpinned overflow compacts to IDs.
    /// Called with the journal+transaction+checkpoint closure before persist.
    func retain(pinned ids: Set<ArtifactRevisionID>) {
        lock.withLock {
            pinned = ids
            for path in nodes.keys {
                guard var node = nodes[path] else { continue }
                if node.history.count > Self.historyCap {
                    let overflow = node.history.dropLast(Self.historyCap)
                    let keepOverflow = overflow.filter { pinned.contains($0) }
                    node.history = keepOverflow + node.history.suffix(Self.historyCap)
                    nodes[path] = node
                }
            }
            externalRecords = externalRecords.filter { id, _ in
                pinned.contains(id) || nodes.values.contains { $0.history.contains(id) }
            }
        }
    }

    func noteTask(path: String, taskID: String) {
        lock.withLock {
            guard var node = nodes[path] else { return }
            node.taskIDs.insert(taskID)
            nodes[path] = node
        }
    }

    // MARK: Persistence

    /// revisionProvider resolves full ArtifactRevision records by ID
    /// (EditEngine history + in-memory external revisions).
    func snapshot(revisionProvider: (ArtifactRevisionID) -> ArtifactRevision?) -> PersistedArtifactGraph {
        lock.withLock {
            let persisted = nodes.values.map { node in
                PersistedArtifactNode(
                    path: node.path,
                    currentRevisionID: node.currentRevisionID?.rawValue,
                    currentNumber: node.currentNumber,
                    currentHash: node.currentHash,
                    exists: node.exists,
                    kind: node.kind.rawValue,
                    language: node.language,
                    history: node.history.map(\.rawValue),
                    taskIDs: Array(node.taskIDs),
                    revisions: node.history.compactMap(revisionProvider)
                )
            }
            return PersistedArtifactGraph(
                schemaVersion: Self.schemaVersion,
                nodes: persisted,
                generation: semanticGenerationValue
            )
        }
    }

    /// IDs currently protected from eviction (diagnostics/tests).
    func pinnedIDs() -> Set<ArtifactRevisionID> {
        lock.withLock { pinned }
    }

    /// Persisted generation support: caller saves semanticGeneration()
    /// alongside the graph; restore carries it forward monotonically.
    func restoreGeneration(_ value: UInt64) {
        lock.withLock {
            if value > semanticGenerationValue {
                semanticGenerationValue = value
            }
        }
    }

    func restore(_ persisted: PersistedArtifactGraph) {
        lock.withLock {
            var rebuilt: [String: ArtifactNode] = [:]
            var rebuiltExternal: [ArtifactRevisionID: ArtifactRevision] = [:]
            var rebuiltLastExternal: [String: ArtifactRevisionID] = [:]
            for item in persisted.nodes {
                var node = ArtifactNode(path: item.path)
                node.currentRevisionID = item.currentRevisionID.map(ArtifactRevisionID.init)
                node.currentNumber = item.currentNumber
                node.currentHash = item.currentHash
                node.exists = item.exists
                node.kind = ArtifactType(rawValue: item.kind) ?? .unknown
                node.language = item.language
                node.history = item.history.map(ArtifactRevisionID.init)
                node.taskIDs = Set(item.taskIDs)
                rebuilt[item.path] = node
                for revision in item.revisions where revision.origin == .external {
                    rebuiltExternal[revision.id] = revision
                    if node.currentRevisionID == revision.id {
                        rebuiltLastExternal[item.path] = revision.id
                    }
                }
            }
            nodes = rebuilt
            externalRecords = rebuiltExternal
            lastExternal = rebuiltLastExternal
            // A restore replaces truth: invalidate workspace-scoped facts.
            semanticGenerationValue &+= 1
        }
    }

    /// Full revision records carried inside a persisted snapshot, by ID.
    static func revisionIndex(of persisted: PersistedArtifactGraph) -> [ArtifactRevisionID: ArtifactRevision] {
        var out: [ArtifactRevisionID: ArtifactRevision] = [:]
        for node in persisted.nodes {
            for revision in node.revisions {
                out[revision.id] = revision
            }
        }
        return out
    }
}

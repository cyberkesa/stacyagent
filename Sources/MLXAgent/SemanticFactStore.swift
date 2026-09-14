import Foundation

// MARK: - v0.30 SemanticFactStore
//
// CACHE of derived semantic facts — NEVER a source of truth about files.
// Truth stays in ArtifactGraph + EditEngine + EvidenceStore.
//
// Every cached fact carries its basis:
// - document-scoped: exact ArtifactRevisionID per path,
// - workspace-scoped: semantic generation (epoch).
// A fact whose basis moved is stale and MUST NOT back a mutation.
// The whole store can be wiped and rebuilt by deterministic re-query
// without losing project truth (invariant 15).

enum SemanticFactKind: String, Sendable {
    case documentSymbols
    case workspaceSymbols
    case definition
    case references
    case diagnostics
}

struct SemanticFactKey: Hashable, Sendable {
    var kind: SemanticFactKind
    /// Document path for document-scoped facts, nil for workspace scope.
    var path: String?
    /// Query subject, e.g. symbol name or "path:offset".
    var subject: String
    var provider: String
}

struct CachedSemanticFact: Sendable {
    var key: SemanticFactKey
    var symbols: [CodeSymbol]
    var locations: [CodeLocation]
    var diagnostics: [DiagnosticFact]
    /// Exact revisions this result was computed from (path -> revision).
    var basisRevisions: [String: ArtifactRevisionID]
    /// Workspace epoch at computation time.
    var basisEpoch: UInt64
    var createdAt: Date
}

/// Freshness verdict for a cached fact against live graph truth.
enum SemanticFactFreshness: Sendable {
    case fresh
    /// Basis moved; re-query before any mutation use.
    case stale(reason: String)
}

final class SemanticFactStore: @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [SemanticFactKey: CachedSemanticFact] = [:]
    private let capacity = 512

    init() {}

    func lookup(_ key: SemanticFactKey) -> CachedSemanticFact? {
        lock.withLock { facts[key] }
    }

    func store(_ fact: CachedSemanticFact) {
        lock.withLock {
            facts[fact.key] = fact
            if facts.count > capacity {
                let overflow = facts.count - capacity
                let oldest = facts.sorted { $0.value.createdAt < $1.value.createdAt }
                    .prefix(overflow).map(\.key)
                for key in oldest { facts.removeValue(forKey: key) }
            }
        }
    }

    /// Document fact freshness: every basis revision must still be current.
    func freshness(
        of fact: CachedSemanticFact,
        currentRevisions: [String: ArtifactRevisionID]
    ) -> SemanticFactFreshness {
        for (path, basis) in fact.basisRevisions {
            guard let current = currentRevisions[path] else { continue }
            if current != basis {
                return .stale(reason: "\(path) moved past basis revision")
            }
        }
        return .fresh
    }

    /// Workspace fact freshness: epoch must be unchanged (conservative:
    /// ANY artifact revision change invalidates workspace-wide facts).
    func workspaceFreshness(of fact: CachedSemanticFact, epoch: UInt64) -> SemanticFactFreshness {
        fact.basisEpoch == epoch
            ? .fresh
            : .stale(reason: "workspace epoch \(fact.basisEpoch) -> \(epoch)")
    }

    /// Drop everything (invariant 15: truth survives; re-query rebuilds).
    func clear() {
        lock.withLock { facts.removeAll() }
    }

    func count() -> Int {
        lock.withLock { facts.count }
    }
}

import Foundation

// MARK: - v0.31 Context Engine (model-independent)
//
// Compiles a minimal, revision-safe, structured ContextBundle before each
// intelligence request — so the ModelProvider receives prepared data
// instead of exploring the project itself. Spend context only where
// context is useful.
//
// Reads: TaskSpec/snapshot fragments (passed in, never owned), Workspace,
// ArtifactGraph, EvidenceStore (via snapshot), CodeIntelligenceEngine,
// ProjectProfile, RuntimeEnvironment.
// NEVER: writes files, creates transactions, completes tasks, calls
// ModelProvider, mutates ProtocolEngine state, creates project truth.

// MARK: - Request

/// Intelligence purpose selecting which levels matter.
enum ContextPurpose: Sendable {
    case resolveTarget
    case generateContent
    case editArtifact
    case diagnoseAndEdit
    case externalAction
    case synthesize
    case chat

    init(_ kind: IntelligenceKind) {
        switch kind {
        case .resolveTarget: self = .resolveTarget
        case .generateContent: self = .generateContent
        case .editArtifact: self = .editArtifact
        case .diagnoseAndEdit: self = .diagnoseAndEdit
        case .externalAction: self = .externalAction
        case .synthesize: self = .synthesize
        }
    }
}

struct UserPinnedContext: Sendable {
    var path: String?
    var symbol: String?
    var selection: String?
}

struct ContextRequest: Sendable {
    var taskID: String
    /// Original user text (framing only, never evidence).
    var userText: String
    /// Compiled spec description (deterministic facts).
    var specSummary: String
    /// Current unresolved requirement, if any.
    var requirement: String?
    var purpose: ContextPurpose
    var targetPath: String?
    var targetSymbol: String?
    var budget: ContextBudget
    var pinned: UserPinnedContext?
    var recentFailure: String?
    /// L0..L4 cap (default .l2).
    var maxLevel: ContextLevel
    /// Recent evidence summaries (already truncated by caller).
    var recentEvidence: [String]
    /// Conversational excerpt (SessionContext text, kept as conversation).
    var conversation: String
    /// Project instructions text (moved out of the model adapter).
    var projectInstructions: String
    var maxTokensHint: Int?
}

// MARK: - Items

enum ContextItemKind: String, Sendable, Codable {
    case task
    case conversation
    case projectInstruction
    case targetSymbol
    case targetRange
    case definition
    case reference
    case dependency
    case sourceImport = "import"
    case diagnostic
    case test
    case gitDiff
    case evidence
    case failureContext
    case userPinned
}

enum ContextSelectionReason: String, Sendable, Codable {
    case requiredTaskFraming
    case explicitTarget
    case nameMatch
    case definitionOfTarget
    case referenceOfTarget
    case dependencyOfTarget
    case importOfTargetFile
    case freshDiagnosticOnTarget
    case failingTest
    case testOfTarget
    case recentMutation
    case recoveryFromFailure
    case userPinnedExplicit
    case projectRule
    case conversationalContinuity
    case validationContext
}

enum ContextProvenance: String, Sendable, Codable {
    case taskCompiler
    case artifactGraph
    case evidenceStore
    case codeIntelligence
    case diagnostics
    case git
    case user
    case session
    case projectProfile
}

enum ContextFreshness: String, Sendable, Codable {
    case current
    case stale
    case unversioned
}

struct ContextItem: Sendable {
    /// Stable identity for dedupe: "kind:path:symbol:span".
    var id: String
    var kind: ContextItemKind
    var path: String?
    var revision: ArtifactRevisionID?
    var symbol: String?
    /// Exact content or span text (never a whole file by default).
    var content: String
    var reason: ContextSelectionReason
    /// Lower runs first and survives budget cuts.
    var priority: Int
    var provenance: ContextProvenance
    var freshness: ContextFreshness
    var estimatedTokens: Int
}

// MARK: - Budget & estimation

struct ContextBudget: Sendable {
    var maxEstimatedTokens: Int
    var maxFiles: Int
    var maxSymbols: Int
    var maxDepth: Int

    static let `default` = ContextBudget(
        maxEstimatedTokens: 6000,
        maxFiles: 12,
        maxSymbols: 40,
        maxDepth: 2
    )
}

/// Provider-neutral rough estimator: deterministic bytes/4.
/// A stable comparative metric, not model accuracy (spec §16).
enum ContextTokenEstimator {
    static func estimate(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }
}

// MARK: - Levels

enum ContextLevel: Int, Sendable, Comparable {
    case l0 = 0, l1, l2, l3, l4

    static func < (lhs: ContextLevel, rhs: ContextLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Bundle

struct ContextBundle: Sendable {
    var requestID: String
    var taskID: String
    var purpose: ContextPurpose
    /// Basis: epoch + exact revisions covered.
    var epoch: UInt64
    var revisions: [String: ArtifactRevisionID]
    var generatedAt: Date
    var items: [ContextItem]
    var levelsReached: ContextLevel
    var dropped: [(id: String, reason: String)]
    var estimatedTokens: Int
    var fromCache: Bool

    /// Deterministic serialization: stable sort, provenance headers.
    /// Same project state + task + budget => identical bytes.
    func serialize() -> String {
        var lines: [String] = []
        lines.append("CONTEXT BUNDLE task=\(taskID) epoch=\(epoch) items=\(items.count) tokens~\(estimatedTokens)")
        let sorted = items.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if ($0.path ?? "") != ($1.path ?? "") { return ($0.path ?? "") < ($1.path ?? "") }
            return $0.id < $1.id
        }
        for item in sorted {
            let whereText: String
            if let path = item.path {
                whereText = item.symbol.map { "\(path)::\($0)" } ?? path
            } else {
                whereText = item.symbol ?? item.kind.rawValue
            }
            lines.append("--- \(item.kind.rawValue) [\(whereText)] pri=\(item.priority) why=\(item.reason.rawValue) src=\(item.provenance.rawValue) fresh=\(item.freshness.rawValue) ~\(item.estimatedTokens)tok")
            lines.append(item.content)
        }
        return lines.joined(separator: "\n")
    }
}

struct ContextBundleTelemetry: Sendable {
    var taskID: String
    var durationMs: Double
    var itemCount: Int
    var droppedCount: Int
    var artifactCount: Int
    var symbolCount: Int
    var estimatedTokens: Int
    var levelsReached: Int
    var cacheHit: Bool
    var reasons: [String: Int]
}

// MARK: - Engine

/// Compiles ContextBundles. Value-in/data-out; owns no project truth.
final class ContextEngine: @unchecked Sendable {
    private let workspace: Workspace
    private let codeIntel: CodeIntelligenceEngine?
    private let events: EventBus
    private let lock = NSLock()
    private var cache: [String: ContextBundle] = [:]
    private let cacheCapacity = 64
    private(set) var compileCount = 0

    init(
        workspace: Workspace,
        codeIntel: CodeIntelligenceEngine?,
        events: EventBus
    ) {
        self.workspace = workspace
        self.codeIntel = codeIntel
        self.events = events
    }

    // MARK: compile

    func compile(_ request: ContextRequest) async -> (bundle: ContextBundle, telemetry: ContextBundleTelemetry) {
        let started = ContinuousClock.now
        let key = cacheKey(for: request)
        if let cached = lock.withLock({ cache[key] }),
           bundleFresh(cached) {
            await events.emit(.contextCompilationFinished(
                taskID: request.taskID, durationMs: 0, itemCount: cached.items.count,
                estimatedTokens: cached.estimatedTokens, cacheHit: true,
                levelsReached: cached.levelsReached.rawValue
            ))
            var hit = cached
            hit.requestID = UUID().uuidString
            hit.fromCache = true
            let telemetry = ContextBundleTelemetry(
                taskID: request.taskID, durationMs: 0,
                itemCount: cached.items.count, droppedCount: cached.dropped.count,
                artifactCount: Set(cached.items.compactMap(\.path)).count,
                symbolCount: cached.items.filter { $0.symbol != nil }.count,
                estimatedTokens: cached.estimatedTokens,
                levelsReached: cached.levelsReached.rawValue,
                cacheHit: true, reasons: [:]
            )
            return (hit, telemetry)
        }
        await events.emit(.contextCompilationStarted(
            taskID: request.taskID,
            purpose: "\(request.purpose)"
        ))
        lock.withLock { compileCount += 1 }

        var items: [ContextItem] = []
        var dropped: [(id: String, reason: String)] = []
        var seen = Set<String>()
        var reached = ContextLevel.l0

        var add: (ContextItem) -> Void = { item in
            guard !seen.contains(item.id) else { return }
            seen.insert(item.id)
            items.append(item)
        }

        // ---- L0 deterministic facts (always) ----
        add(taskItem(request))
        if !request.conversation.isEmpty {
            add(conversationItem(request))
        }
        if !request.projectInstructions.isEmpty {
            add(projectInstructionsItem(request))
        }
        if let failure = request.recentFailure, !failure.isEmpty {
            add(failureItem(request, failure: failure))
        }
        for (index, evidence) in request.recentEvidence.prefix(6).enumerated() {
            add(evidenceItem(request, text: evidence, index: index))
        }
        if let pinned = request.pinned {
            addPinned(pinned, request: request, add: &add, dropped: &dropped)
        }

        // ---- target resolution (shared by L1+) ----
        var targetSnapshot: CodeDocumentSnapshot?
        var targetSymbol: CodeSymbol?
        if request.maxLevel >= .l1 {
            let resolved = await resolveTarget(request)
            targetSnapshot = resolved.snapshot
            targetSymbol = resolved.symbol
            if let snap = resolved.snapshot {
                add(targetRangeItem(request, snapshot: snap, symbol: resolved.symbol))
                reached = .l1
            } else if request.targetPath != nil || request.targetSymbol != nil {
                // Target named but unresolvable: record the gap explicitly
                // instead of silently widening scope.
                dropped.append((
                    id: "target:unresolved",
                    reason: "target not resolvable to an exact revision; no whole-file fallback"
                ))
            }
        }

        // ---- L2 direct semantic neighborhood ----
        if request.maxLevel >= .l2, let snap = targetSnapshot {
            reached = .l2
            await collectL2(
                request: request, snapshot: snap, symbol: targetSymbol,
                add: &add
            )
        }

        // ---- L3 validation neighborhood ----
        if request.maxLevel >= .l3 {
            reached = .l3
            await collectL3(
                request: request, snapshot: targetSnapshot, symbol: targetSymbol,
                add: &add, dropped: &dropped
            )
        }

        // ---- L4 broader project (capped, only when asked) ----
        if request.maxLevel >= .l4 {
            reached = .l4
            collectL4(
                request: request,
                anchor: targetSnapshot?.path ?? request.targetPath,
                add: &add, seen: &seen
            )
        }

        // ---- budget: drop by priority (never userPinned without cause) ----
        let budgeted = applyBudget(
            items: items, budget: request.budget, dropped: &dropped
        )
        let tokens = budgeted.reduce(0) { $0 + $1.estimatedTokens }
        var reasons: [String: Int] = [:]
        for item in budgeted {
            reasons[item.reason.rawValue, default: 0] += 1
        }
        let bundle = ContextBundle(
            requestID: UUID().uuidString,
            taskID: request.taskID,
            purpose: request.purpose,
            epoch: workspace.graph.semanticGeneration(),
            revisions: basisRevisions(budgeted),
            generatedAt: Date(),
            items: budgeted,
            levelsReached: reached,
            dropped: dropped,
            estimatedTokens: tokens,
            fromCache: false
        )
        lock.withLock {
            cache[key] = bundle
            if cache.count > cacheCapacity {
                let overflow = cache.count - cacheCapacity
                for k in cache.keys.prefix(overflow) { cache.removeValue(forKey: k) }
            }
        }
        let ms = Self.ms(ContinuousClock.now - started)
        await events.emit(.contextCompilationFinished(
            taskID: request.taskID, durationMs: ms, itemCount: budgeted.count,
            estimatedTokens: tokens, cacheHit: false,
            levelsReached: reached.rawValue
        ))
        for item in budgeted {
            await events.emit(.contextItemAdded(
                taskID: request.taskID, itemID: item.id,
                kind: item.kind.rawValue
            ))
        }
        for drop in dropped {
            await events.emit(.contextItemDropped(
                taskID: request.taskID, itemID: drop.id, reason: drop.reason
            ))
        }
        let telemetry = ContextBundleTelemetry(
            taskID: request.taskID, durationMs: ms,
            itemCount: budgeted.count, droppedCount: dropped.count,
            artifactCount: Set(budgeted.compactMap(\.path)).count,
            symbolCount: budgeted.filter { $0.symbol != nil }.count,
            estimatedTokens: tokens, levelsReached: reached.rawValue,
            cacheHit: false, reasons: reasons
        )
        return (bundle, telemetry)
    }

    /// Pre-send freshness gate (§5): every basis revision still current
    /// and the epoch unchanged. Stale bundles are recompiled, never sent.
    func isFresh(_ bundle: ContextBundle) -> Bool {
        let current = workspace.graph.currentMap()
        if bundle.epoch != workspace.graph.semanticGeneration() {
            return false
        }
        for (path, rev) in bundle.revisions {
            guard current[path] == rev else { return false }
        }
        return true
    }

    /// Revision change invalidates dependent bundles (derived data only).
    func invalidate(path: String) async {
        lock.withLock {
            cache = cache.filter { _, bundle in
                !bundle.revisions.keys.contains(path)
            }
        }
        await events.emit(.contextBundleInvalidated(path: path))
    }

    func clearCache() {
        lock.withLock { cache.removeAll() }
    }

    func cachedCount() -> Int {
        lock.withLock { cache.count }
    }

    // MARK: - cache key & freshness

    private func cacheKey(for request: ContextRequest) -> String {
        let live = workspace.graph.currentMap()
        let liveEpoch = workspace.graph.semanticGeneration()
        let revs = live
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let pinned = request.pinned.map {
            "\($0.path ?? "")|\($0.symbol ?? "")|\($0.selection ?? "")"
        } ?? ""
        return [
            request.taskID,
            request.userText,
            request.specSummary,
            request.requirement ?? "",
            "\(request.purpose)",
            request.targetPath ?? "",
            request.targetSymbol ?? "",
            "\(liveEpoch)",
            revs,
            "\(request.budget.maxEstimatedTokens)/\(request.budget.maxFiles)/\(request.budget.maxSymbols)/\(request.budget.maxDepth)",
            "\(request.maxLevel.rawValue)",
            pinned,
            request.recentFailure ?? "",
            request.projectInstructions,
            request.conversation,
            request.recentEvidence.joined(separator: "\u{1e}")
        ].joined(separator: "|")
    }

    private func bundleFresh(_ bundle: ContextBundle) -> Bool {
        let current = workspace.graph.currentMap()
        guard bundle.epoch == workspace.graph.semanticGeneration() else { return false }
        for (path, rev) in bundle.revisions {
            guard current[path] == rev else { return false }
        }
        return true
    }

    // MARK: - L0 items

    private func taskItem(_ request: ContextRequest) -> ContextItem {
        var text = "TASK \(request.taskID)\nORIGINAL USER REQUEST:\n\(request.userText)\n\(request.specSummary)"
        if let requirement = request.requirement, !requirement.isEmpty {
            text += "\nCURRENT REQUIREMENT: \(requirement)"
        }
        if let target = request.targetPath {
            text += "\nTARGET: \(target)"
        } else if let symbol = request.targetSymbol {
            text += "\nTARGET SYMBOL: \(symbol)"
        }
        return ContextItem(
            id: "task:\(request.taskID)", kind: .task, path: nil,
            revision: nil, symbol: request.targetSymbol,
            content: text, reason: .requiredTaskFraming, priority: 0,
            provenance: .taskCompiler, freshness: .unversioned,
            estimatedTokens: ContextTokenEstimator.estimate(text)
        )
    }

    private func conversationItem(_ request: ContextRequest) -> ContextItem {
        ContextItem(
            id: "conversation:\(request.taskID)", kind: .conversation, path: nil,
            revision: nil, symbol: nil, content: request.conversation,
            reason: .conversationalContinuity, priority: 5,
            provenance: .session, freshness: .unversioned,
            estimatedTokens: ContextTokenEstimator.estimate(request.conversation)
        )
    }

    private func projectInstructionsItem(_ request: ContextRequest) -> ContextItem {
        ContextItem(
            id: "instructions:\(request.taskID)", kind: .projectInstruction,
            path: nil, revision: nil, symbol: nil,
            content: request.projectInstructions, reason: .projectRule,
            priority: 4, provenance: .projectProfile, freshness: .unversioned,
            estimatedTokens: ContextTokenEstimator.estimate(request.projectInstructions)
        )
    }

    private func failureItem(_ request: ContextRequest, failure: String) -> ContextItem {
        let text = "PREVIOUS FAILURE (do not repeat the same bundle):\n\(failure)"
        return ContextItem(
            id: "failure:\(request.taskID)", kind: .failureContext, path: nil,
            revision: nil, symbol: nil, content: text,
            reason: .recoveryFromFailure, priority: 3,
            provenance: .evidenceStore, freshness: .unversioned,
            estimatedTokens: ContextTokenEstimator.estimate(text)
        )
    }

    private func evidenceItem(
        _ request: ContextRequest, text: String, index: Int
    ) -> ContextItem {
        ContextItem(
            id: "evidence:\(request.taskID):\(index)", kind: .evidence,
            path: nil, revision: nil, symbol: nil, content: text,
            reason: .recentMutation, priority: 30,
            provenance: .evidenceStore, freshness: .unversioned,
            estimatedTokens: ContextTokenEstimator.estimate(text)
        )
    }

    private func addPinned(
        _ pinned: UserPinnedContext,
        request: ContextRequest,
        add: inout (ContextItem) -> Void,
        dropped: inout [(id: String, reason: String)]
    ) {
        // Pinned content resolves against CURRENT revisions only.
        if let path = pinned.path {
            let key = workspace.canonicalKey(path)
            if let current = workspace.graph.currentMap()[key] {
                var content = "(pinned content unavailable)"
                var freshness = ContextFreshness.stale
                if let data = try? Data(
                    contentsOf: workspace.root.appendingPathComponent(key)
                ), let text = String(data: data, encoding: .utf8) {
                    // Whole pinned file only when small; else head slice
                    // with an explicit note (never silently full).
                    if text.utf8.count <= 6000 {
                        content = text
                    } else {
                        content = String(text.prefix(6000))
                            + "\n… [pinned file truncated: head slice]"
                    }
                    freshness = .current
                } else {
                    dropped.append((
                        id: "pinned:\(key)",
                        reason: "pinned file unreadable at current revision"
                    ))
                    return
                }
                add(ContextItem(
                    id: "pinned:\(key)", kind: .userPinned, path: key,
                    revision: current, symbol: pinned.symbol,
                    content: content, reason: .userPinnedExplicit,
                    priority: 1, provenance: .user, freshness: freshness,
                    estimatedTokens: ContextTokenEstimator.estimate(content)
                ))
            } else {
                dropped.append((
                    id: "pinned:\(key)",
                    reason: "pinned artifact has no current revision"
                ))
            }
        } else if let symbol = pinned.symbol {
            add(ContextItem(
                id: "pinned-symbol:\(symbol)", kind: .userPinned, path: nil,
                revision: nil, symbol: symbol,
                content: "User pinned symbol: \(symbol)" +
                    (pinned.selection.map { "\nSelection:\n\($0)" } ?? ""),
                reason: .userPinnedExplicit, priority: 1,
                provenance: .user, freshness: .unversioned,
                estimatedTokens: ContextTokenEstimator.estimate(symbol)
            ))
        }
    }

    // MARK: - target resolution

    private func resolveTarget(
        _ request: ContextRequest
    ) async -> (snapshot: CodeDocumentSnapshot?, symbol: CodeSymbol?) {
        guard let intel = codeIntel else { return (nil, nil) }
        // Prefer explicit path, then symbol.
        if let path = request.targetPath {
            do {
                let snap = try intel.snapshot(path: path)
                if let name = request.targetSymbol {
                    let candidates = await intel.resolve(symbol: name, path: snap.path)
                    if let first = candidates.first {
                        return (snap, first.symbol)
                    }
                }
                return (snap, nil)
            } catch {
                return (nil, nil)
            }
        }
        if let name = request.targetSymbol {
            let candidates = await intel.resolve(symbol: name, path: nil)
            guard let first = candidates.first else { return (nil, nil) }
            do {
                let snap = try intel.snapshot(path: first.symbol.path)
                return (snap, first.symbol)
            } catch {
                return (nil, nil)
            }
        }
        return (nil, nil)
    }

    private func targetRangeItem(
        _ request: ContextRequest,
        snapshot: CodeDocumentSnapshot,
        symbol: CodeSymbol?
    ) -> ContextItem {
        // Narrowest first: symbol body > relevant range > whole file.
        if let symbol {
            let span = symbol.fullSpan ?? symbol.nameSpan
            if let slice = utf8Slice(snapshot.content, span: span),
               slice.utf8.count <= 12000 {
                let text = "TARGET \(symbol.name) (\(symbol.kind.rawValue)) in \(snapshot.path):\n\(slice)"
                return ContextItem(
                    id: "target:\(snapshot.path):\(symbol.name)",
                    kind: .targetSymbol, path: snapshot.path,
                    revision: snapshot.revision, symbol: symbol.name,
                    content: text, reason: .explicitTarget, priority: 2,
                    provenance: .codeIntelligence, freshness: .current,
                    estimatedTokens: ContextTokenEstimator.estimate(text)
                )
            }
            // Symbol span unusable: fall through to whole-file rules below.
        }
        let whole = snapshot.content
        if whole.utf8.count <= 6000 {
            let text = "TARGET FILE \(snapshot.path) (small, whole):\n\(whole)"
            return ContextItem(
                id: "target:\(snapshot.path)", kind: .targetRange,
                path: snapshot.path, revision: snapshot.revision,
                symbol: symbol?.name, content: text,
                reason: .explicitTarget, priority: 6,
                provenance: .artifactGraph, freshness: .current,
                estimatedTokens: ContextTokenEstimator.estimate(text)
            )
        }
        let head = String(whole.prefix(6000)) + "\n… [large target: head slice]"
        return ContextItem(
            id: "target:\(snapshot.path)", kind: .targetRange,
            path: snapshot.path, revision: snapshot.revision,
            symbol: symbol?.name, content: head,
            reason: .explicitTarget, priority: 6,
            provenance: .artifactGraph, freshness: .current,
            estimatedTokens: ContextTokenEstimator.estimate(head)
        )
    }

    private func utf8Slice(_ content: String, span: CodeSpan) -> String? {
        let view = content.utf8
        guard span.startByte >= 0, span.endByte <= view.count,
              span.startByte <= span.endByte,
              let lower = view.index(
                view.startIndex, offsetBy: span.startByte,
                limitedBy: view.endIndex
              ),
              let upper = view.index(
                lower, offsetBy: span.endByte - span.startByte,
                limitedBy: view.endIndex
              ) else {
            return nil
        }
        return String(bytes: Array(view[lower..<upper]), encoding: .utf8)
    }

    // MARK: - L2/L3/L4 collectors

    private func collectL2(
        request: ContextRequest,
        snapshot: CodeDocumentSnapshot,
        symbol: CodeSymbol?,
        add: inout (ContextItem) -> Void
    ) async {
        guard let intel = codeIntel else { return }
        // Local imports (top-of-file, deterministic).
        let imports = Self.topImports(snapshot.content).prefix(12)
        if !imports.isEmpty {
            let text = "IMPORTS of \(snapshot.path):\n" + imports.joined(separator: "\n")
            add(ContextItem(
                id: "imports:\(snapshot.path)", kind: .sourceImport,
                path: snapshot.path, revision: snapshot.revision,
                symbol: nil, content: text, reason: .importOfTargetFile,
                priority: 14, provenance: .artifactGraph,
                freshness: .current,
                estimatedTokens: ContextTokenEstimator.estimate(text)
            ))
        }
        // Definition + direct references of the target symbol.
        if let symbol {
            let offset = symbol.nameSpan.startByte
            if let defs = await intel.definition(snapshot: snapshot, offset: offset) {
                for loc in defs.prefix(4) {
                    if let item = locationItem(
                        request: request, path: loc.path, symbol: symbol.name,
                        role: "definition", location: loc
                    ) {
                        add(item)
                    }
                }
            }
            if let refs = await intel.references(snapshot: snapshot, offset: offset) {
                for loc in refs.prefix(10) {
                    // Skip self-file self-symbol duplicates already covered.
                    if loc.path == snapshot.path { continue }
                    if let item = locationItem(
                        request: request, path: loc.path, symbol: symbol.name,
                        role: "reference", location: loc
                    ) {
                        add(item)
                    }
                }
            }
        }
    }

    private func locationItem(
        request: ContextRequest,
        path: String,
        symbol: String,
        role: String,
        location: CodeLocation
    ) -> ContextItem? {
        let key = workspace.canonicalKey(path)
        guard let intel = codeIntel,
              let snapshot = try? intel.snapshot(path: key),
              snapshot.revision == location.revision,
              let source = utf8Slice(snapshot.content, span: location.span) else {
            return nil
        }
        let text = "\(role.uppercased()) of \(symbol) in \(key) " +
            "bytes \(location.span.startByte)..<\(location.span.endByte) @\(location.revision):\n" +
            source
        return ContextItem(
            id: "\(role):\(key):\(symbol):\(location.span.startByte):\(location.span.endByte)",
            kind: role == "definition" ? .definition : .reference,
            path: key, revision: location.revision, symbol: symbol, content: text,
            reason: role == "definition" ? .definitionOfTarget : .referenceOfTarget,
            priority: role == "definition" ? 10 : 22,
            provenance: .codeIntelligence,
            freshness: .current,
            estimatedTokens: ContextTokenEstimator.estimate(text)
        )
    }

    private func collectL3(
        request: ContextRequest,
        snapshot: CodeDocumentSnapshot?,
        symbol: CodeSymbol?,
        add: inout (ContextItem) -> Void,
        dropped: inout [(id: String, reason: String)]
    ) async {
        guard let intel = codeIntel else { return }
        // Fresh diagnostics on the target (never stale revisions).
        if let snap = snapshot {
            let diagnostics = await intel.diagnostics(path: snap.path)
            let fresh = diagnostics.filter { $0.revision == snap.revision }
            for (index, diagnostic) in fresh.prefix(8).enumerated() {
                var text = "DIAGNOSTIC \(snap.path): \(diagnostic.message)"
                if let symbol {
                    text += "\nEnclosing symbol: \(symbol.name)"
                }
                add(ContextItem(
                    id: "diagnostic:\(snap.path):\(index)",
                    kind: .diagnostic, path: snap.path,
                    revision: snap.revision, symbol: symbol?.name,
                    content: text, reason: .freshDiagnosticOnTarget,
                    priority: 8, provenance: .diagnostics,
                    freshness: .current,
                    estimatedTokens: ContextTokenEstimator.estimate(text)
                ))
            }
            if diagnostics.count != fresh.count {
                dropped.append((
                    id: "diagnostics:\(snap.path):stale",
                    reason: "stale diagnostics excluded (revision moved)"
                ))
            }
        }
        // Relevant tests: filename convention + symbol references.
        for test in discoverTests(request: request, symbol: symbol) {
            add(test)
        }
    }

    /// Deterministic test discovery: filename convention, test targets,
    /// symbol references. Unproven links carry low confidence explicitly.
    func discoverTests(
        request: ContextRequest,
        symbol: CodeSymbol?
    ) -> [ContextItem] {
        var out: [ContextItem] = []
        let live = workspace.graph.currentMap()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: workspace.root.path) else {
            return out
        }
        // Test targets by convention.
        var testDirs: [String] = []
        for entry in entries where entry.hasSuffix("Tests") || entry == "Tests" {
            var isDir: ObjCBool = false
            let full = workspace.root.appendingPathComponent(entry).path
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                testDirs.append(entry)
            }
        }
        guard !testDirs.isEmpty else { return out }
        let symbolName = symbol?.name ?? request.targetSymbol ?? ""
        var scored: [(path: String, confidence: String)] = []
        for dir in testDirs {
            guard let files = try? fm.contentsOfDirectory(
                atPath: workspace.root.appendingPathComponent(dir).path
            ) else { continue }
            for file in files.sorted() where file.hasSuffix(".swift") {
                let path = "\(dir)/\(file)"
                var confidence = "convention-only"
                if !symbolName.isEmpty,
                   file.localizedCaseInsensitiveContains(symbolName) {
                    confidence = "filename-match"
                }
                scored.append((path, confidence))
            }
        }
        for entry in scored.prefix(8) {
            let text = "TEST CANDIDATE \(entry.path) [\(entry.confidence)]" +
                (symbolName.isEmpty ? "" : " for \(symbolName)")
            out.append(ContextItem(
                id: "test:\(entry.path)", kind: .test,
                path: entry.path,
                revision: live[entry.path],
                symbol: symbolName.isEmpty ? nil : symbolName,
                content: text, reason: .testOfTarget, priority: 20,
                provenance: .codeIntelligence,
                freshness: live[entry.path] == nil
                    ? .unversioned : .current,
                estimatedTokens: ContextTokenEstimator.estimate(text)
            ))
        }
        return out
    }

    private func collectL4(
        request: ContextRequest,
        anchor: String?,
        add: inout (ContextItem) -> Void,
        seen: inout Set<String>
    ) {
        // Broader project context: same-directory Swift siblings, hard-capped.
        // Only reached when explicitly requested (maxLevel .l4).
        guard let anchor else {
            return
        }
        let dirURL = workspace.root.appendingPathComponent(anchor).deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) else {
            return
        }
        var added = 0
        for entry in entries.sorted() where entry.hasSuffix(".swift") {
            let rel: String
            if anchor.contains("/") {
                rel = (anchor as NSString).deletingLastPathComponent + "/" + entry
            } else {
                rel = entry
            }
            if rel == anchor || seen.contains("l4:\(rel)") { continue }
            seen.insert("l4:\(rel)")
            let text = "RELATED FILE \(rel) (same module directory)"
            let liveRel = workspace.graph.currentMap()[rel]
            add(ContextItem(
                id: "l4:\(rel)", kind: .dependency, path: rel,
                revision: liveRel, symbol: nil,
                content: text, reason: .dependencyOfTarget, priority: 40,
                provenance: .artifactGraph,
                freshness: liveRel == nil ? .unversioned : .current,
                estimatedTokens: ContextTokenEstimator.estimate(text)
            ))
            added += 1
            if added >= 6 { break }
        }
    }

    // MARK: - budget & basis

    private func applyBudget(
        items: [ContextItem],
        budget: ContextBudget,
        dropped: inout [(id: String, reason: String)]
    ) -> [ContextItem] {
        // Never drop userPinned without cause: partition first.
        let pinned = items.filter { $0.kind == .userPinned }
        var rest = items.filter { $0.kind != .userPinned }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.id < $1.id
            }
        var kept: [ContextItem] = pinned
        var tokens = pinned.reduce(0) { $0 + $1.estimatedTokens }
        var files = Set(pinned.compactMap(\.path)).count
        var symbols = pinned.filter { $0.symbol != nil }.count
        for item in rest {
            let newFiles = item.path.map { files + (Set(kept.compactMap(\.path)).contains($0) ? 0 : 1) } ?? files
            let newSymbols = symbols + (item.symbol != nil ? 1 : 0)
            if tokens + item.estimatedTokens > budget.maxEstimatedTokens ||
               newFiles > budget.maxFiles ||
               newSymbols > budget.maxSymbols {
                dropped.append((id: item.id, reason: "budget: lower priority first"))
                continue
            }
            kept.append(item)
            tokens += item.estimatedTokens
            files = newFiles
            symbols = newSymbols
        }
        return kept
    }

    private func basisRevisions(
        _ items: [ContextItem]
    ) -> [String: ArtifactRevisionID] {
        var out: [String: ArtifactRevisionID] = [:]
        for item in items {
            if let path = item.path, let rev = item.revision {
                out[path] = rev
            }
        }
        return out
    }

    static func topImports(_ content: String) -> [String] {
        var out: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import ") {
                out.append(trimmed)
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("//") && !trimmed.hasPrefix("/*") {
                // Imports live at the top: stop at first real code.
                if out.isEmpty { continue }
                break
            }
            if out.count >= 24 { break }
        }
        return out
    }

    static func ms(_ duration: Duration) -> Double {
        let c = duration.components
        return (Double(c.seconds) + Double(c.attoseconds) / 1e18) * 1000
    }
}

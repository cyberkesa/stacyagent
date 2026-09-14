import Foundation

// MARK: - v0.31.5 provider-neutral computation routing

enum ComputationStrategy: String, Sendable {
    case literalSearch
    case regexSearch
    case semanticQuery
    case structuralQuery
    case contextAndModel
    case unsupported
    case ambiguous
}

enum ComputationLatencyClass: String, Sendable {
    case immediate, low, medium, high
}

enum ComputationCPUCostClass: String, Sendable {
    case trivial, low, medium, high
}

enum ComputationPrecisionClass: Int, Sendable, Comparable {
    case textualCandidate = 0
    case exactText = 1
    case structural = 2
    case semanticIdentity = 3
    case reasoned = 4

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ComputationCostEstimate: Sendable {
    var expectedLatencyClass: ComputationLatencyClass
    var cpuCostClass: ComputationCPUCostClass
    var modelCalls: Int
    var tokenCostExpected: Int
    var semanticPrecisionClass: ComputationPrecisionClass
}

enum ComputationOperationIntent: Sendable {
    case literalSearch(query: String, path: String)
    case regexSearch(pattern: String, path: String)
    case exactLocation(path: String)
    case symbolIdentity(symbol: String, path: String?)
    case definition(symbol: String, path: String?)
    case references(symbol: String, path: String?)
    case semanticRename(symbol: String, newName: String, path: String?)
    case diagnostics(path: String)
    case structural(description: String, available: Bool)
    case reasoning
    case unknown

    var description: String {
        switch self {
        case .literalSearch(let query, let path):
            return "literal:\(path):\(query)"
        case .regexSearch(let pattern, let path):
            return "regex:\(path):\(pattern)"
        case .exactLocation(let path):
            return "location:\(path)"
        case .symbolIdentity(let symbol, let path):
            return "symbol:\(path ?? "*"):\(symbol)"
        case .definition(let symbol, let path):
            return "definition:\(path ?? "*"):\(symbol)"
        case .references(let symbol, let path):
            return "references:\(path ?? "*"):\(symbol)"
        case .semanticRename(let symbol, let newName, let path):
            return "rename:\(path ?? "*"):\(symbol)->\(newName)"
        case .diagnostics(let path):
            return "diagnostics:\(path)"
        case .structural(let description, let available):
            return "structural:\(available):\(description)"
        case .reasoning:
            return "reasoning"
        case .unknown:
            return "unknown"
        }
    }
}

struct ComputationRequest: Sendable {
    var taskID: String
    var requirement: String
    var intent: ComputationOperationIntent
    var target: String?
    var workspaceEpoch: UInt64
    var revisions: [String: ArtifactRevisionID]
    var requiredPrecision: ComputationPrecisionClass
    var requiredConfidence: Double

    var cacheKey: String {
        let basis = revisions.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return [
            taskID, requirement, intent.description, target ?? "",
            "epoch=\(workspaceEpoch)", basis,
            "precision=\(requiredPrecision.rawValue)",
            "confidence=\(String(format: "%.4f", requiredConfidence))"
        ].joined(separator: "|")
    }
}

enum ComputationResultStatus: String, Sendable {
    case success, ambiguous, unsupported, failed
}

struct ComputationResult: Sendable {
    var status: ComputationResultStatus
    var output: String
    var candidateCount: Int
    var evidenceSufficient: Bool
    var modelAvoided: Bool
}

struct ComputationDecision: Sendable {
    var strategy: ComputationStrategy
    var cost: ComputationCostEstimate
    var sufficientForRequest: Bool
    var cacheHit: Bool
    var reason: String
    var reusedResult: ComputationResult?
}

final class ComputationRouter: @unchecked Sendable {
    private struct Cached {
        var decision: ComputationDecision
        var result: ComputationResult
    }

    private let events: EventBus
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    private let cacheCapacity = 64

    init(events: EventBus) {
        self.events = events
    }

    func route(_ request: ComputationRequest) async -> ComputationDecision {
        await events.emit(.computationRequested(
            taskID: request.taskID, intent: request.intent.description
        ))
        if let cached = lock.withLock({ cache[request.cacheKey] }) {
            var decision = cached.decision
            decision.cacheHit = true
            decision.reusedResult = cached.result
            await emitRouted(request: request, decision: decision)
            return decision
        }

        let decision: ComputationDecision
        switch request.intent {
        case .literalSearch:
            decision = makeDecision(
                .literalSearch, request: request,
                availablePrecision: .exactText,
                reason: "exact textual answer is sufficient"
            )
        case .regexSearch:
            decision = makeDecision(
                .regexSearch, request: request,
                availablePrecision: .exactText,
                reason: "textual pattern requires regex matching"
            )
        case .exactLocation:
            decision = makeDecision(
                .literalSearch, request: request,
                availablePrecision: .exactText,
                reason: "exact path can be read without semantic indexing"
            )
        case .symbolIdentity:
            if request.requiredPrecision >= .semanticIdentity {
                decision = makeDecision(
                    .literalSearch, request: request,
                    availablePrecision: .textualCandidate,
                    reason: "cheap discovery only; semantic identity still required"
                )
            } else {
                decision = makeDecision(
                    .literalSearch, request: request,
                    availablePrecision: .exactText,
                    reason: "textual candidates satisfy requested precision"
                )
            }
        case .definition, .references, .semanticRename, .diagnostics:
            decision = makeDecision(
                .semanticQuery, request: request,
                availablePrecision: .semanticIdentity,
                reason: "operation requires semantic identity"
            )
        case .structural(_, let available):
            decision = available
                ? makeDecision(
                    .structuralQuery, request: request,
                    availablePrecision: .structural,
                    reason: "available structural validator is sufficient"
                )
                : makeDecision(
                    .unsupported, request: request,
                    availablePrecision: .textualCandidate,
                    reason: "no structural provider is available"
                )
        case .reasoning:
            decision = makeDecision(
                .contextAndModel, request: request,
                availablePrecision: .reasoned,
                reason: "reasoning cannot be proven by textual or semantic lookup"
            )
        case .unknown:
            decision = makeDecision(
                .ambiguous, request: request,
                availablePrecision: .textualCandidate,
                reason: "operation intent is ambiguous"
            )
        }
        await emitRouted(request: request, decision: decision)
        return decision
    }

    func escalate(
        _ request: ComputationRequest,
        from prior: ComputationDecision,
        result: ComputationResult
    ) async -> ComputationDecision {
        let nextStrategy: ComputationStrategy
        let reason: String
        switch prior.strategy {
        case .literalSearch, .regexSearch:
            if request.requiredPrecision >= .semanticIdentity {
                nextStrategy = .semanticQuery
                reason = result.status == .ambiguous
                    ? "textual candidates are ambiguous for semantic identity"
                    : "textual result lacks required semantic precision"
            } else if result.status == .unsupported || result.status == .failed {
                nextStrategy = .contextAndModel
                reason = "text search could not answer the request"
            } else {
                return prior
            }
        case .semanticQuery, .structuralQuery:
            guard result.status == .ambiguous ||
                    result.status == .unsupported ||
                    result.status == .failed || !result.evidenceSufficient else {
                return prior
            }
            nextStrategy = .contextAndModel
            reason = "precise deterministic provider could not prove an answer"
        case .unsupported, .ambiguous:
            nextStrategy = .contextAndModel
            reason = "deterministic routing requires intelligent fallback"
        case .contextAndModel:
            return prior
        }
        let next = ComputationDecision(
            strategy: nextStrategy,
            cost: Self.cost(for: nextStrategy),
            sufficientForRequest: nextStrategy == .contextAndModel ||
                Self.cost(for: nextStrategy).semanticPrecisionClass >= request.requiredPrecision,
            cacheHit: false,
            reason: reason,
            reusedResult: nil
        )
        await events.emit(.computationEscalated(
            taskID: request.taskID, from: prior.strategy.rawValue,
            to: next.strategy.rawValue, reason: reason
        ))
        await emitRouted(request: request, decision: next)
        return next
    }

    func record(
        _ request: ComputationRequest,
        decision: ComputationDecision,
        result: ComputationResult,
        durationMs: Double
    ) async {
        if decision.strategy != .contextAndModel,
           result.status == .success,
           result.evidenceSufficient {
            lock.withLock {
                var stored = decision
                stored.cacheHit = false
                stored.reusedResult = nil
                cache[request.cacheKey] = Cached(decision: stored, result: result)
                if cache.count > cacheCapacity {
                    for key in cache.keys.prefix(cache.count - cacheCapacity) {
                        cache.removeValue(forKey: key)
                    }
                }
            }
        }
        await events.emit(.computationFinished(
            taskID: request.taskID, strategy: decision.strategy.rawValue,
            durationMs: durationMs, candidateCount: result.candidateCount,
            cacheHit: decision.cacheHit, modelAvoided: result.modelAvoided
        ))
    }

    func clearCache() {
        lock.withLock { cache.removeAll() }
    }

    private func makeDecision(
        _ strategy: ComputationStrategy,
        request: ComputationRequest,
        availablePrecision: ComputationPrecisionClass,
        reason: String
    ) -> ComputationDecision {
        ComputationDecision(
            strategy: strategy,
            cost: Self.cost(for: strategy),
            sufficientForRequest: availablePrecision >= request.requiredPrecision,
            cacheHit: false,
            reason: reason,
            reusedResult: nil
        )
    }

    private func emitRouted(
        request: ComputationRequest,
        decision: ComputationDecision
    ) async {
        await events.emit(.computationRouted(
            taskID: request.taskID, strategy: decision.strategy.rawValue,
            latencyClass: decision.cost.expectedLatencyClass.rawValue,
            modelCalls: decision.cost.modelCalls,
            cacheHit: decision.cacheHit
        ))
    }

    static func cost(for strategy: ComputationStrategy) -> ComputationCostEstimate {
        switch strategy {
        case .literalSearch:
            return ComputationCostEstimate(
                expectedLatencyClass: .immediate, cpuCostClass: .trivial,
                modelCalls: 0, tokenCostExpected: 0,
                semanticPrecisionClass: .exactText
            )
        case .regexSearch:
            return ComputationCostEstimate(
                expectedLatencyClass: .low, cpuCostClass: .low,
                modelCalls: 0, tokenCostExpected: 0,
                semanticPrecisionClass: .exactText
            )
        case .semanticQuery:
            return ComputationCostEstimate(
                expectedLatencyClass: .medium, cpuCostClass: .medium,
                modelCalls: 0, tokenCostExpected: 0,
                semanticPrecisionClass: .semanticIdentity
            )
        case .structuralQuery:
            return ComputationCostEstimate(
                expectedLatencyClass: .medium, cpuCostClass: .medium,
                modelCalls: 0, tokenCostExpected: 0,
                semanticPrecisionClass: .structural
            )
        case .contextAndModel:
            return ComputationCostEstimate(
                expectedLatencyClass: .high, cpuCostClass: .high,
                modelCalls: 1, tokenCostExpected: 1,
                semanticPrecisionClass: .reasoned
            )
        case .unsupported, .ambiguous:
            return ComputationCostEstimate(
                expectedLatencyClass: .immediate, cpuCostClass: .trivial,
                modelCalls: 0, tokenCostExpected: 0,
                semanticPrecisionClass: .textualCandidate
            )
        }
    }
}

enum ComputationIntentParser {
    static func searchIntent(_ text: String) -> ComputationOperationIntent? {
        let lower = text.lowercased()
        let asksSearch = [
            "find", "search", "locate", "найди", "поищи", "отыщи"
        ].contains { lower.contains($0) }
        guard asksSearch else { return nil }

        if lower.contains("regex") || lower.contains("regular expression") ||
           lower.contains("регуляр") {
            if let pattern = delimitedValue(in: text, delimiter: "/") ??
                quotedValue(in: text) {
                return .regexSearch(pattern: pattern, path: ".")
            }
        }
        if let query = quotedValue(in: text) {
            return .literalSearch(query: query, path: ".")
        }
        return nil
    }

    private static func quotedValue(in text: String) -> String? {
        for delimiter: Character in ["\"", "'", "`"] {
            if let value = delimitedValue(in: text, delimiter: delimiter), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func delimitedValue(
        in text: String, delimiter: Character
    ) -> String? {
        guard let start = text.firstIndex(of: delimiter) else { return nil }
        let tail = text.index(after: start)
        guard tail < text.endIndex,
              let end = text[tail...].firstIndex(of: delimiter) else {
            return nil
        }
        return String(text[tail..<end])
    }
}

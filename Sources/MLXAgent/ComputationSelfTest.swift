import Foundation

// MARK: - v0.31.5 Computation Router deterministic scenarios A-K

struct ComputationCheckResult {
    var passed: Bool
    var name: String
}

private final class ComputationEventSink: AgentEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var requestedCount = 0
    private var routedStrategies: [String] = []
    private var finishedCount = 0
    private var escalatedCount = 0

    func emit(_ event: AgentEvent) async {
        record(event)
    }

    private func record(_ event: AgentEvent) {
        lock.withLock {
            switch event {
            case .computationRequested:
                requestedCount += 1
            case .computationRouted(_, let strategy, _, _, _):
                routedStrategies.append(strategy)
            case .computationFinished:
                finishedCount += 1
            case .computationEscalated:
                escalatedCount += 1
            default:
                break
            }
        }
    }

    var snapshot: (requested: Int, routed: [String], finished: Int, escalated: Int) {
        lock.withLock {
            (requestedCount, routedStrategies, finishedCount, escalatedCount)
        }
    }
}

enum ComputationSelfTest {
    private static func request(
        intent: ComputationOperationIntent,
        precision: ComputationPrecisionClass,
        epoch: UInt64 = 1,
        revisions: [String: ArtifactRevisionID] = [:],
        task: String = "comp-task"
    ) -> ComputationRequest {
        ComputationRequest(
            taskID: task,
            requirement: "test requirement",
            intent: intent,
            target: nil,
            workspaceEpoch: epoch,
            revisions: revisions,
            requiredPrecision: precision,
            requiredConfidence: 1
        )
    }

    static func runAll() async -> [ComputationCheckResult] {
        var out: [ComputationCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(ComputationCheckResult(passed: passed, name: name))
        }

        // A/E. Exact literal search is completed by Workspace, without CI/model.
        do {
            let (dir, workspace, fake, codeIntel, context) = try ContextSelfTest.makeWorld(
                files: ["Search.swift": "let marker = \"TODO\"\n"]
            )
            defer { ContextSelfTest.cleanup(dir) }
            let sink = ComputationEventSink()
            let bus = EventBus(sink: sink)
            let router = ComputationRouter(events: bus)
            let policy = PolicyEngine(mode: .workspace, allowMCP: false)
            let runtime = RuntimeEnvironment.probe(projectURL: dir)
            let registry = ToolRegistry(
                workspace: workspace, mcp: MCPBridge(policy: policy),
                events: bus, runtime: runtime, codeIntelligence: codeIntel,
                computationRouter: router
            )
            let text = "Find exact string \"TODO\" in project files."
            let decision = TurnDecision.forMode(.agent, source: .fast)
            await registry.beginTask(text, decision: decision)
            let model = FakeModelProvider()
            let coordinator = RuntimeCoordinator(
                executor: registry, events: bus, projectInstructions: "test",
                contextEngine: context, computationRouter: router
            )
            let result = try await coordinator.run(
                RuntimeTaskInput(
                    userText: text, decision: decision, maxRounds: 2,
                    sessionExcerpt: "", projectInstructions: "test",
                    runtimeContext: "", allowedTools: [], agentMaxTokens: nil
                ),
                provider: model
            )
            let events = sink.snapshot
            record(
                result.snapshot.isComplete && result.displayText.contains("TODO") &&
                model.callCount == 0 && fake.queryCount == 0 &&
                events.routed.contains(ComputationStrategy.literalSearch.rawValue),
                "comp-A exact literal search: workspace, 0 CI, 0 model"
            )
        } catch {
            record(false, "comp-A exact literal search: workspace, 0 CI, 0 model")
        }

        let sink = ComputationEventSink()
        let router = ComputationRouter(events: EventBus(sink: sink))

        // B. Semantic rename cannot be downgraded to text search.
        let rename = request(
            intent: .semanticRename(symbol: "UserManager", newName: "AccountManager", path: nil),
            precision: .semanticIdentity
        )
        let renameDecision = await router.route(rename)
        record(
            renameDecision.strategy == .semanticQuery &&
            renameDecision.cost.modelCalls == 0 && renameDecision.sufficientForRequest,
            "comp-B semantic rename routes to CodeIntelligence"
        )

        // C/F. Text discovery is only a candidate step; ambiguity escalates to semantics.
        let identity = request(
            intent: .symbolIdentity(symbol: "Widget", path: nil),
            precision: .semanticIdentity
        )
        let discovery = await router.route(identity)
        let semantic = await router.escalate(
            identity, from: discovery,
            result: ComputationResult(
                status: .ambiguous, output: "12 textual candidates",
                candidateCount: 12, evidenceSufficient: false, modelAvoided: true
            )
        )
        record(
            discovery.strategy == .literalSearch && !discovery.sufficientForRequest &&
            semantic.strategy == .semanticQuery && semantic.cost.modelCalls == 0,
            "comp-C/F discovery candidates escalate to semantic identity"
        )

        // D. Reasoning is routed to ContextEngine + exactly one provider call.
        do {
            let (dir, _, _, _, context) = try ContextSelfTest.makeWorld(
                files: ["Architecture.swift": "struct RuntimeCore {}\n"]
            )
            defer { ContextSelfTest.cleanup(dir) }
            let executor = ScriptExecutor()
            let text = "Explain the architecture of this project."
            let decision = TurnDecision.forMode(.agent, source: .fast)
            await executor.begin(TaskCompiler.compile(userText: text, decision: decision))
            let model = FakeModelProvider()
            model.script([.doneProse])
            let coordinator = RuntimeCoordinator(
                executor: executor, events: EventBus(sink: NullSink()),
                projectInstructions: "test", contextEngine: context,
                computationRouter: router
            )
            let result = try await coordinator.run(
                RuntimeTaskInput(
                    userText: text, decision: decision, maxRounds: 1,
                    sessionExcerpt: "", projectInstructions: "test",
                    runtimeContext: "", allowedTools: CoordinatorSelfTest.allTools,
                    agentMaxTokens: nil
                ),
                provider: model
            )
            let prompt = model.requests.first?.prompt ?? ""
            record(result.snapshot.isComplete, "comp-D1 reasoning task completes")
            record(model.callCount == 1, "comp-D2 reasoning uses one model call")
            record(context.compileCount == 1, "comp-D3 reasoning compiles one context")
            record(prompt.contains("CONTEXT BUNDLE"), "comp-D4 model receives context bundle")
            record(
                prompt.contains("ORIGINAL USER REQUEST:\n\(text)"),
                "comp-D5 context preserves original user intent"
            )
        } catch {
            record(false, "comp-D reasoning integration")
        }

        // G. An unavailable deterministic semantic provider escalates once to model.
        let semanticFailure = ComputationResult(
            status: .unsupported, output: "provider unavailable", candidateCount: 0,
            evidenceSufficient: false, modelAvoided: true
        )
        let fallback = await router.escalate(
            rename, from: renameDecision, result: semanticFailure
        )
        let bounded = await router.escalate(rename, from: fallback, result: semanticFailure)
        record(
            fallback.strategy == .contextAndModel && fallback.cost.modelCalls == 1 &&
            bounded.strategy == .contextAndModel,
            "comp-G semantic fallback is one bounded model escalation"
        )

        // H. Successful derived evidence is reused for the exact same state.
        let cacheRequest = request(
            intent: .literalSearch(query: "TODO", path: "."),
            precision: .exactText, task: "cache-task"
        )
        let first = await router.route(cacheRequest)
        await router.record(
            cacheRequest, decision: first,
            result: ComputationResult(
                status: .success, output: "A.swift:1:TODO", candidateCount: 1,
                evidenceSufficient: true, modelAvoided: true
            ),
            durationMs: 1
        )
        let cached = await router.route(cacheRequest)
        record(
            !first.cacheHit && cached.cacheHit && cached.reusedResult?.candidateCount == 1,
            "comp-H identical revision reuses derived result"
        )

        // I. Epoch/revision changes invalidate the derived-result key.
        let changed = request(
            intent: .literalSearch(query: "TODO", path: "."),
            precision: .exactText, epoch: 2,
            revisions: [
                "A.swift": ArtifactRevisionID(
                    UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                )
            ],
            task: "cache-task"
        )
        let fresh = await router.route(changed)
        record(!fresh.cacheHit, "comp-I changed epoch/revision recomputes")

        // Telemetry must cover request, route, completion and escalation.
        let telemetry = sink.snapshot
        record(
            telemetry.requested >= 5 && telemetry.finished >= 1 &&
            telemetry.escalated >= 2 &&
            telemetry.routed.contains(ComputationStrategy.contextAndModel.rawValue),
            "comp-telemetry requested/routed/finished/escalated"
        )

        // J/K remain covered by the existing v0.30 rename and v0.31 context suites.
        return out
    }
}

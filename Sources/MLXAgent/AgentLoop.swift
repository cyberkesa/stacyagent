import Foundation
import SLTACore

// MARK: - v0.28 AgentLoop (thin turn layer)
//
// Owns: user turn intake, ConversationDirectRouter, conversational
// continuity (SessionContext), TaskCompiler/turn routing, chat turns,
// delegating project tasks to RuntimeCoordinator, SessionContext writes,
// UI events.
//
// Does NOT own: model/task execution lifecycle (RuntimeCoordinator),
// completion policy (ProtocolEngine), tool execution (ToolRegistry).

final class AgentLoop: @unchecked Sendable {
    private let mlx: MLXProvider
    private let coordinator: RuntimeCoordinator
    private let registry: ToolRegistry
    private let events: EventBus
    private let maxRounds: Int
    private let chatMaxTokens: Int?
    private let agentMaxTokens: Int?
    private let sessionContext: SessionContext

    private var lastStats: GenerationStats?
    private var sessionName: String?

    init(
        mlx: MLXProvider,
        coordinator: RuntimeCoordinator,
        registry: ToolRegistry,
        events: EventBus,
        maxRounds: Int,
        chatMaxTokens: Int? = nil,
        agentMaxTokens: Int? = nil
    ) {
        self.mlx = mlx
        self.coordinator = coordinator
        self.registry = registry
        self.events = events
        self.maxRounds = maxRounds
        self.chatMaxTokens = chatMaxTokens
        self.agentMaxTokens = agentMaxTokens
        self.sessionContext = SessionContext(projectPath: registry.projectPath)
    }

    func toggleDebug() -> Bool {
        mlx.toggleDebug()
    }

    func clear() async {
        mlx.endTaskSession()
        await registry.state.resetTask()
        await sessionContext.clear()
        sessionName = nil
        lastStats = nil
    }

    func contextText() async -> String {
        let snapshot = await sessionContext.snapshot()
        return snapshot.debugSummary
    }

    func taskText() async -> String {
        let snapshot = await registry.taskSnapshot()

        guard let spec = snapshot.spec else {
            return "no semantic task is active"
        }

        let kinds = spec.kinds.map(\.rawValue).sorted().joined(separator: "+")
        let targets = spec.targets.map(\.path).joined(separator: ", ")

        return "task: \(spec.id) kinds=\(kinds) targets=\(targets.isEmpty ? "none" : targets)"
    }

    func statsText() -> String {
        guard let stats = lastStats else { return "no stats yet" }
        return "tokens: \(stats.outputTokens) elapsed: \(TerminalRenderer.format(stats.elapsed))"
    }

    func run(_ task: String) async throws {
        await registry.state.resetTask()
        await events.emit(.taskStarted(task))

        var stats = GenerationStats()
        let sessionBefore = await sessionContext.snapshot()

        if let direct = ConversationDirectRouter.match(task) {
            let answer: String
            switch direct {
            case .greeting(let response):
                answer = response
            case .rememberName(let name, let response):
                sessionName = name
                answer = response
            case .recallName:
                answer = sessionName != nil ? "Тебя зовут \(sessionName!)." : "Я пока не знаю твоего имени."
            }

            stats.routeSource = .direct
            stats.taskStatus = "direct"
            await events.emit(.assistant(answer))
            await sessionContext.recordDirect(user: task, assistant: answer)
            stats.finish()
            lastStats = stats
            await events.emit(.completed(stats))
            return
        }

        if let answer = sessionBefore.directAnswer(for: task) {
            stats.routeSource = .direct
            stats.taskStatus = "continuation"
            await events.emit(.assistant(answer))
            await sessionContext.recordDirect(user: task, assistant: answer)
            stats.finish()
            lastStats = stats
            await events.emit(.completed(stats))
            return
        }

        if let answer = registry.directAnswer(for: task) {
            stats.routeSource = .direct
            stats.taskStatus = "direct"
            await events.emit(.assistant(answer))
            await sessionContext.recordDirect(user: task, assistant: answer)
            stats.finish()
            lastStats = stats
            await events.emit(.completed(stats))
            return
        }

        let routeStarted = ContinuousClock.now
        var decision: TurnDecision

        if let continuationDecision = sessionBefore.continuationDecision(for: task) {
            decision = continuationDecision
        } else if let fast = FastTurnRouter.decide(task) {
            decision = fast
        } else {
            // Single model generation owned by the provider; mode parsing is
            // deterministic runtime policy.
            let raw = try await mlx.classify(
                task,
                sessionContext: sessionBefore.routerContext(currentUserText: task)
            )
            decision = TurnModeParser.parse(raw)
        }

        stats.routerSeconds = Self.seconds(ContinuousClock.now - routeStarted)
        stats.routeSource = decision.source

        var continuity = sessionBefore.taskContinuity(
            for: task,
            decision: decision
        )
        var promptContext = sessionBefore.promptContext(
            currentUserText: task,
            decision: decision
        )

        if decision.mode == .chat {
            stats.taskStatus = "chat"
            let answer = try await respondChat(to: task, sessionContext: promptContext, stats: &stats)
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)

            if let corrected = RouteSafety.correctedDecision(
                routed: decision,
                draftResponse: clean,
                hasProjectContext: sessionBefore.hasProjectContinuity
            ) {
                // Do not expose the discarded implementation draft. Re-enter the
                // same request through the evidence-backed project executor.
                decision = corrected
                continuity = sessionBefore.taskContinuity(
                    for: task,
                    decision: corrected
                )
                promptContext = sessionBefore.promptContext(
                    currentUserText: task,
                    decision: corrected
                )
                stats.routeSource = corrected.source
                stats.taskStatus = "route-corrected"
                await events.emit(
                    .notice("project implementation redirected from chat to tools")
                )
            } else {
                if !clean.isEmpty {
                    await events.emit(.assistant(clean))
                }
                await sessionContext.recordChat(user: task, assistant: clean)
                stats.finish()
                lastStats = stats
                await events.emit(.completed(stats))
                return
            }
        }

        await registry.beginTask(task, decision: decision, continuity: continuity)
        let compiled = await registry.taskSnapshot()
        if let spec = compiled.spec {
            await events.emit(.taskCompiled(taskID: "\(spec.id)"))
        }

        let allowed = registry.allowedToolNames(for: decision.capabilities)
        let taskInput = RuntimeTaskInput(
            userText: task,
            decision: decision,
            maxRounds: maxRounds,
            sessionExcerpt: promptContext,
            projectInstructions: "",
            runtimeContext: registry.runtimeContext,
            allowedTools: allowed,
            agentMaxTokens: agentMaxTokens
        )

        let result: RuntimeTaskResult
        do {
            result = try await coordinator.run(taskInput, provider: mlx)
        } catch {
            let failedState = await registry.taskSnapshot()
            await sessionContext.recordProject(
                user: task,
                assistant: "",
                decision: decision,
                task: failedState,
                continuity: continuity
            )
            throw error
        }

        // Aggregate per-physical-generation telemetry. passes now means
        // physical model generations — never conflated with tool calls.
        for call in result.providerCalls {
            stats.modelSeconds += call.durationSeconds
            stats.promptTokens += call.promptTokens ?? 0
            stats.outputTokens += call.outputTokens ?? 0
            if stats.firstTokenSeconds == nil {
                stats.firstTokenSeconds = call.firstTokenSeconds
            }
        }
        stats.passes = result.physicalGenerations
        stats.tools = await registry.state.tools()
        stats.toolSeconds = await registry.state.toolSeconds()

        let taskState = result.snapshot
        stats.taskStatus = taskState.phase.rawValue
        stats.finish()
        lastStats = stats

        let clean = result.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.outcome {
        case .blocked(let reason):
            await sessionContext.recordProject(
                user: task,
                assistant: "",
                decision: decision,
                task: taskState,
                continuity: continuity
            )
            throw CLIError("Задача заблокирована: \(reason)")
        case .incomplete:
            guard taskState.isComplete else {
                await sessionContext.recordProject(
                    user: task,
                    assistant: "",
                    decision: decision,
                    task: taskState,
                    continuity: continuity
                )
                throw CLIError("Задача не завершена: \(taskState.incompleteReason)")
            }
        case .completedDeterministic, .completedSynthesis:
            break
        }

        if !clean.isEmpty {
            await events.emit(.assistant(clean))
        }

        await sessionContext.recordProject(
            user: task,
            assistant: clean.isEmpty ? "Готово." : clean,
            decision: decision,
            task: taskState,
            continuity: continuity
        )
        // v0.29: persist revision-aware truth for crash/restart recovery.
        await registry.persistRuntime()

        await events.emit(.completed(stats))
    }

    /// Single chat generation through the provider (no tools, no task loop).
    private func respondChat(
        to text: String,
        sessionContext: String,
        stats: inout GenerationStats
    ) async throws -> String {
        let instructions = sessionContext.isEmpty
            ? SystemPrompt.identity
            : SystemPrompt.identity + "\n\n" + sessionContext
        let request = ModelRequest(
            purpose: .chat,
            instructions: instructions,
            prompt: text,
            tools: [],
            maxTokens: chatMaxTokens
        )
        let response = try await mlx.generate(request)
        stats.passes += 1
        stats.modelSeconds += response.telemetry.durationSeconds
        stats.promptTokens += response.telemetry.promptTokens ?? 0
        stats.outputTokens += response.telemetry.outputTokens ?? 0
        if stats.firstTokenSeconds == nil {
            stats.firstTokenSeconds = response.telemetry.firstTokenSeconds
        }
        return response.text
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

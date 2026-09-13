import Foundation

final class AgentLoop: @unchecked Sendable {
    private let model: MLXModelAdapter
    private let registry: ToolRegistry
    private let events: EventBus
    private let maxRounds: Int
    private let sessionContext: SessionContext

    private var lastStats: GenerationStats?
    private var sessionName: String?

    init(
        model: MLXModelAdapter,
        registry: ToolRegistry,
        events: EventBus,
        maxRounds: Int
    ) {
        self.model = model
        self.registry = registry
        self.events = events
        self.maxRounds = maxRounds
        self.sessionContext = SessionContext(projectPath: registry.projectPath)
    }

    func toggleDebug() -> Bool {
        model.toggleDebug()
    }

    func clear() async {
        await model.clear()
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
        } else {
            decision = try await model.route(
                task,
                sessionContext: sessionBefore.routerContext(currentUserText: task)
            )
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
            let answer = try await model.respondChat(to: task, sessionContext: promptContext, stats: &stats)
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

        let response: String
        do {
            response = try await model.respondTask(
                to: task,
                decision: decision,
                maxPasses: maxRounds,
                sessionContext: promptContext,
                stats: &stats
            )
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

        let taskState = await registry.taskSnapshot()
        stats.tools = await registry.state.tools()
        stats.toolSeconds = await registry.state.toolSeconds()
        stats.taskStatus = taskState.phase.rawValue
        stats.finish()
        lastStats = stats

        let clean = response.trimmingCharacters(in: .whitespacesAndNewlines)
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

        await events.emit(.completed(stats))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

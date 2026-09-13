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
        let decision: TurnDecision

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

        let continuity = sessionBefore.taskContinuity(for: task)
        let promptContext = sessionBefore.promptContext(currentUserText: task)

        if decision.mode != .chat {
            await registry.beginTask(task, decision: decision, continuity: continuity)
        }

        if decision.mode == .chat {
            stats.taskStatus = "chat"
            let answer = try await model.respondChat(to: task, sessionContext: promptContext, stats: &stats)
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                await events.emit(.assistant(clean))
            }
            await sessionContext.recordChat(user: task, assistant: clean)
            stats.finish()
            lastStats = stats
            await events.emit(.completed(stats))
            return
        }

        var response = ""
        do {
            response = try await model.respondTask(
                to: task,
                decision: decision,
                maxPasses: maxRounds,
                sessionContext: promptContext,
                stats: &stats
            )
        } catch {
            // Если тулы выполнились (например поиск), но цикл оборвался на пустом тексте —
            // закрываем задачу успехом и отдаем подтверждение вместо падения с CLIError
            let toolCount = await registry.state.tools()
            if toolCount > 0 {
                response = "Поиск успешно выполнен! Результаты отображены выше. ✨"
            } else {
                throw error
            }
        }

        let taskState = await registry.taskSnapshot()
        stats.tools = await registry.state.tools()
        stats.toolSeconds = await registry.state.toolSeconds()
        stats.taskStatus = taskState.phase.rawValue
        stats.finish()
        lastStats = stats

        let clean = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            await events.emit(.assistant(clean))
        }

        await sessionContext.recordProject(
            user: task,
            assistant: clean.isEmpty ? "Готово!" : clean,
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

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

        let kinds = spec.kinds
            .map(\.rawValue)
            .sorted()
            .joined(separator: "+")

        let targets: String
        if !spec.targets.isEmpty {
            targets = spec.targets
                .map(\.path)
                .joined(separator: ", ")
        } else if let resolved = snapshot.resolvedTargetPath {
            targets = resolved + " (runtime-resolved)"
        } else {
            targets = "unresolved"
        }

        let requirements = snapshot.requirements.isEmpty
            ? "none"
            : snapshot.requirements
                .map(\.description)
                .joined(separator: "; ")

        let missing = snapshot.missingRequirements.isEmpty
            ? "none"
            : snapshot.missingRequirements
                .map(\.description)
                .joined(separator: "; ")

        let evidence = snapshot.evidence.isEmpty
            ? "none"
            : snapshot.evidence
                .suffix(12)
                .map(\.description)
                .joined(separator: " | ")

        let capabilities = TurnDecision.forMode(
            spec.mode,
            source: .fast
        ).capabilities
        let allowed = registry.allowedToolNames(for: capabilities)
        let protocolDecision = ProtocolEngine.decision(
            for: snapshot,
            allowed: allowed
        )

        return [
            "id           \(spec.id)",
            "parent       \(spec.parentID?.description ?? "none")",
            "state        \(snapshot.semanticState.rawValue)",
            "kinds        \(kinds)",
            "targets      \(targets)",
            "confidence   \(String(format: "%.2f", spec.compileConfidence))",
            "compiler     \(spec.compilerNotes.isEmpty ? "none" : spec.compilerNotes.joined(separator: "; "))",
            "protocol     \(protocolDecision.description)",
            "requirements \(requirements)",
            "missing      \(missing)",
            "evidence     \(evidence)"
        ].joined(separator: "\n")
    }

    func statsText() -> String {
        guard let stats = lastStats else {
            return "no task statistics yet"
        }

        var lines = [
            "wall      \(TerminalRenderer.format(stats.elapsed))",
            "route     \(String(format: "%.3fs", stats.routerSeconds)) · \(stats.routeSource?.rawValue ?? "unknown")",
            "task      \(stats.taskStatus ?? "unknown")",
            "model     \(String(format: "%.3fs", stats.modelSeconds)) · \(stats.passes) " + (stats.passes == 1 ? "pass" : "passes"),
            "tools     \(String(format: "%.3fs", stats.toolSeconds)) · \(stats.tools) " + (stats.tools == 1 ? "call" : "calls"),
            "tokens    prompt \(stats.promptTokens) · output \(stats.outputTokens)"
        ]

        if let decodeTPS = stats.generationTokensPerSecond {
            lines.append("decode    \(String(format: "%.1f", decodeTPS)) tok/s")
        }
        if let prefillTPS = stats.promptTokensPerSecond {
            lines.append("prefill   \(String(format: "%.1f", prefillTPS)) tok/s")
        }
        if let ttft = stats.firstTokenSeconds {
            lines.append("ttft      \(String(format: "%.3fs", ttft))")
        }

        return lines.joined(separator: "\n")
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
                if let sessionName {
                    answer = "Тебя зовут \(sessionName)."
                } else {
                    answer = "Я пока не знаю, как тебя зовут."
                }
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

        if continuity.failureFeedback {
            await sessionContext.recordUserFailure(
                message: task,
                continuity: continuity
            )
        }

        let promptContext = sessionBefore.promptContext(currentUserText: task)

        if decision.mode != .chat {
            await registry.beginTask(
                task,
                decision: decision,
                continuity: continuity
            )
        }

        if decision.mode == .chat {
            stats.taskStatus = continuity.isContinuation ? "continuation" : "chat"

            let answer = try await model.respondChat(
                to: task,
                sessionContext: promptContext,
                stats: &stats
            )
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)

            if !clean.isEmpty {
                await events.emit(.assistant(clean))
            }

            await sessionContext.recordChat(
                user: task,
                assistant: clean
            )

            stats.finish()
            lastStats = stats
            await events.emit(.completed(stats))
            return
        }

        let response = try await model.respondTask(
            to: task,
            decision: decision,
            maxPasses: maxRounds,
            sessionContext: promptContext,
            stats: &stats
        )

        let taskState = await registry.taskSnapshot()
        stats.tools = await registry.state.tools()
        stats.toolSeconds = await registry.state.toolSeconds()
        stats.taskStatus = taskState.phase.rawValue
        stats.finish()
        lastStats = stats

        if taskState.validation.lastToolFailed {
            let message = "task stopped with unresolved tool failure: \(taskState.validation.lastFailure ?? "unknown tool error")"

            await sessionContext.recordProject(
                user: task,
                assistant: message,
                decision: decision,
                task: taskState,
                continuity: continuity
            )

            throw CLIError(message)
        }

        guard taskState.isComplete else {
            let message = "task stopped incomplete after \(stats.passes) model passes: \(taskState.incompleteReason)"

            await sessionContext.recordProject(
                user: task,
                assistant: message,
                decision: decision,
                task: taskState,
                continuity: continuity
            )

            throw CLIError(message)
        }

        let clean = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            await events.emit(.assistant(clean))
        }

        await sessionContext.recordProject(
            user: task,
            assistant: clean,
            decision: decision,
            task: taskState,
            continuity: continuity
        )

        await events.emit(.completed(stats))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

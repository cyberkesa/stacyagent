import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers


private final class GenerationHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity = Date()

    func pulse() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    func idleSeconds() -> Double {
        lock.lock()
        let value = Date().timeIntervalSince(lastActivity)
        lock.unlock()
        return value
    }
}

final class MLXModelAdapter: @unchecked Sendable {
    private let model: ModelContainer
    private let registry: ToolRegistry
    private let events: EventBus
    private let timeoutSeconds: Int
    private let controller: TurnController
    private let chatMaxTokens: Int?
    private let agentMaxTokens: Int?
    private let speculative: SpeculativeDecodingConfig?
    private let projectInstructions: String
    private var debug = false

    init(
        modelID: String,
        projectURL: URL,
        registry: ToolRegistry,
        events: EventBus,
        chatMaxTokens: Int?,
        agentMaxTokens: Int?,
        timeoutSeconds: Int,
        controllerTimeoutSeconds: Int,
        draftModelID: String?
    ) async throws {
        self.registry = registry
        self.events = events
        self.timeoutSeconds = timeoutSeconds
        self.chatMaxTokens = chatMaxTokens
        self.agentMaxTokens = agentMaxTokens
        self.projectInstructions = ProjectInstructions.load(root: projectURL)

        await events.emit(.modelLoading)
        let configuration = ModelConfiguration(id: modelID)
        let main = try await #huggingFaceLoadModelContainer(configuration: configuration)
        self.model = main

        if let draftModelID {
            await events.emit(.notice("loading draft model for speculative decoding"))
            let draftConfig = ModelConfiguration(id: draftModelID)
            let draft = try await #huggingFaceLoadModelContainer(configuration: draftConfig)
            self.speculative = SpeculativeDecodingConfig(draftModel: draft, numDraftTokens: 5)
        } else {
            self.speculative = nil
        }

        self.controller = TurnController(model: main, timeoutSeconds: controllerTimeoutSeconds)

        await events.emit(.modelReady)
    }

    func route(
        _ text: String,
        sessionContext: String = ""
    ) async throws -> TurnDecision {
        let decision = try await controller.decide(
            text,
            sessionContext: sessionContext
        )
        if debug { await events.emit(.notice("route: \(decision.mode.rawValue)")) }
        return decision
    }

    func toggleDebug() -> Bool {
        debug.toggle()
        return debug
    }

    func clear() async {
        // Conversation continuity is owned by SessionContext in AgentLoop.
        // Per-turn ChatSessions are intentionally ephemeral.
    }

    func respondChat(
        to text: String,
        sessionContext: String,
        stats: inout GenerationStats
    ) async throws -> String {
        let instructions = sessionContext.isEmpty
            ? SystemPrompt.identity
            : SystemPrompt.identity + "\n\n" + sessionContext

        let session = ChatSession(
            model,
            instructions: instructions,
            speculativeDecoding: speculative,
            generateParameters: Self.parameters(maxTokens: chatMaxTokens)
        )

        return try await stream(
            session: session,
            prompt: text,
            label: "thinking",
            stats: &stats
        )
    }

    func respondTask(
        to text: String,
        decision: TurnDecision,
        maxPasses: Int,
        sessionContext: String,
        stats: inout GenerationStats
    ) async throws -> String {
        let allowed = registry.allowedToolNames(for: decision.capabilities)

        let instructions: String
        switch decision.mode {
        case .mcpRead, .mcpAgent:
            instructions = sessionContext.isEmpty
                ? SystemPrompt.mcp
                : SystemPrompt.mcp + "\n\n" + sessionContext
        default:
            let base = SystemPrompt.agent(
                projectInstructions: projectInstructions,
                runtimeContext: registry.runtimeContext
            )
            let runtimeTask = await registry.taskSnapshot()
            let semantics = semanticTaskContext(runtimeTask)

            var parts = [base]
            if !sessionContext.isEmpty {
                parts.append(sessionContext)
            }
            if !semantics.isEmpty {
                parts.append(semantics)
            }

            instructions = parts.joined(separator: "\n\n")
        }

        // Deterministic protocol actions run before the first model pass when the
        // next missing requirement is already mechanically known (read/validate/open).
        let preflight = await registry.advanceProtocol(
            allowed: allowed
        )
        let preflightEvidence = evidenceBlocks(preflight)
        let preflightState = await registry.taskSnapshot()

        if preflightState.isComplete &&
           !preflightState.requiresSynthesis {
            return deterministicCompletion(
                for: text,
                state: preflightState
            )
        }

        let initialProtocolDecision = ProtocolEngine.decision(
            for: preflightState,
            allowed: allowed
        )
        var intelligenceAllowed = Self.intelligenceTools(
            from: initialProtocolDecision
        )
        var tools = registry.schemas(named: intelligenceAllowed)

        // Exactly one model session per request. The protocol engine may remove
        // mechanical work before generation, but reasoning stays in this session.
        let session = ChatSession(
            model,
            instructions: instructions,
            speculativeDecoding: speculative,
            generateParameters: Self.parameters(maxTokens: agentMaxTokens),
            tools: tools,
            toolDispatch: { [registry] call in
                let state = await registry.taskSnapshot()
                let currentDecision = ProtocolEngine.decision(
                    for: state,
                    allowed: allowed
                )
                let semanticAllowed = Self.intelligenceTools(
                    from: currentDecision
                )
                return await registry.execute(
                    call,
                    allowed: semanticAllowed
                )
            }
        )

        if preflightState.isComplete {
            session.tools = []
            session.toolDispatch = nil
        }

        var synthesisOnly =
            preflightState.isComplete &&
            preflightState.requiresSynthesis

        var nextPrompt: String
        if synthesisOnly {
            nextPrompt = synthesisPrompt(
                originalRequest: text,
                evidence: preflightEvidence
            )
        } else {
            nextPrompt = intelligencePrompt(
                originalRequest: text,
                decision: initialProtocolDecision,
                evidence: preflightEvidence
            )
        }

        var consecutiveNoProgressPasses = 0

        passLoop: for pass in 0..<maxPasses {
            let passStartState = await registry.taskSnapshot()
            let passStartFingerprint = Self.taskProgressFingerprint(
                passStartState
            )

            let passDecision = ProtocolEngine.decision(
                for: passStartState,
                allowed: allowed
            )
            intelligenceAllowed = Self.intelligenceTools(
                from: passDecision
            )
            tools = registry.schemas(named: intelligenceAllowed)
            session.tools = tools

            let raw = try await stream(
                session: session,
                prompt: nextPrompt,
                label: pass == 0
                    ? "thinking p1/\(maxPasses)"
                    : "working p\(pass + 1)/\(maxPasses)",
                stats: &stats
            )

            // Once runtime evidence is already complete, synthesis gets exactly one
            // tool-free pass. We accept its prose and stop; no second planning loop.
            if synthesisOnly {
                let clean = Qwen3CoderProtocol.removingToolMarkup(from: raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty {
                    let snapshot = await registry.taskSnapshot()
                    return deterministicCompletion(for: text, state: snapshot)
                }
                return clean
            }

            switch Qwen3CoderProtocol.analyze(raw) {
            case .none:
                let clean = Qwen3CoderProtocol.removingToolMarkup(from: raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let taskState = await registry.taskSnapshot()

                if taskState.validation.lastToolFailed {
                    if taskState.validation.consecutiveToolFailures >= 3 {
                        break passLoop
                    }

                    nextPrompt = """
                    RECOVERABLE TOOL ERROR.
                    Correct only the unresolved failed tool call and continue the SAME task.
                    Real error: \(taskState.validation.lastFailure ?? "unknown tool error")
                    """
                    continue
                }

                if taskState.isComplete {
                    if !clean.isEmpty {
                        return clean
                    }
                    return deterministicCompletion(for: text, state: taskState)
                }

                let protocolExecuted = await registry.advanceProtocol(
                    allowed: allowed
                )
                let protocolEvidence = evidenceBlocks(
                    protocolExecuted
                )
                let advancedState = await registry.taskSnapshot()

                if advancedState.validation.lastToolFailed {
                    nextPrompt = """
                    RECOVERABLE TOOL ERROR.
                    Correct only the unresolved failed action and continue the SAME task.
                    Real error: \(advancedState.validation.lastFailure ?? "unknown tool error")

                    \(protocolEvidence.joined(separator: "\n\n"))
                    """
                    continue
                }

                if advancedState.isComplete {
                    if advancedState.requiresSynthesis {
                        session.tools = []
                        session.toolDispatch = nil
                        synthesisOnly = true
                        nextPrompt = synthesisPrompt(
                            originalRequest: text,
                            evidence: protocolEvidence
                        )
                        continue
                    }

                    return deterministicCompletion(
                        for: text,
                        state: advancedState
                    )
                }

                let advancedFingerprint = Self.taskProgressFingerprint(
                    advancedState
                )

                if advancedFingerprint == passStartFingerprint {
                    consecutiveNoProgressPasses += 1

                    if consecutiveNoProgressPasses >= 2 {
                        await events.emit(
                            .warning(
                                "model made no semantic progress for 2 consecutive passes; stopping instead of retrying blindly"
                            )
                        )
                        break passLoop
                    }
                } else {
                    consecutiveNoProgressPasses = 0
                }

                let nextDecision = ProtocolEngine.decision(
                    for: advancedState,
                    allowed: allowed
                )
                let requiredTools = Self.intelligenceTools(
                    from: nextDecision
                )
                session.tools = registry.schemas(named: requiredTools)

                nextPrompt = intelligencePrompt(
                    originalRequest: text,
                    decision: nextDecision,
                    evidence: protocolEvidence
                )
                continue

            case .incomplete(let tail):
                let currentState = await registry.taskSnapshot()
                let currentFingerprint = Self.taskProgressFingerprint(
                    currentState
                )

                if currentFingerprint == passStartFingerprint {
                    consecutiveNoProgressPasses += 1
                    if consecutiveNoProgressPasses >= 2 {
                        await events.emit(
                            .warning(
                                "model produced 2 incomplete tool-call passes without task progress; stopping"
                            )
                        )
                        break passLoop
                    }
                } else {
                    consecutiveNoProgressPasses = 0
                }

                nextPrompt = """
                The previous textual tool call was incomplete and was not executed.
                Retry that same required action exactly once with all required arguments
                and closing tags. Do not switch to another tool and do not add prose.

                Incomplete tail:
                \(tail)
                """
                continue

            case .complete(let invocations):
                // Textual Qwen fallback calls must obey the same semantic tool scope
                // as native MLX tool calls. Broad turn capabilities are not enough:
                // during an edit phase, for example, read/shell/open are runtime-owned.
                let currentDecision = ProtocolEngine.decision(
                    for: passStartState,
                    allowed: allowed
                )
                let semanticAllowed = Self.intelligenceTools(
                    from: currentDecision
                )
                let executed = await registry.executeModelInvocations(
                    invocations,
                    allowed: semanticAllowed
                )
                if !executed.isEmpty {
                    consecutiveNoProgressPasses = 0
                }

                var results = evidenceBlocks(executed)
                var taskState = await registry.taskSnapshot()

                if !taskState.validation.lastToolFailed &&
                   !taskState.isComplete {
                    let protocolExecuted = await registry.advanceProtocol(
                        allowed: allowed
                    )
                    results.append(
                        contentsOf: evidenceBlocks(
                            protocolExecuted
                        )
                    )
                    taskState = await registry.taskSnapshot()
                }

                if taskState.validation.lastToolFailed {
                    if taskState.validation.consecutiveToolFailures >= 3 {
                        break passLoop
                    }

                    nextPrompt = """
                    RECOVERABLE TOOL ERROR.
                    Correct only the unresolved failed tool call.
                    Real error: \(taskState.validation.lastFailure ?? "unknown tool error")

                    \(results.joined(separator: "\n\n"))
                    """
                    continue
                }

                if taskState.isComplete {
                    if taskState.requiresSynthesis {
                        // The previous v0.17 bug dropped the real tool result here.
                        // Give the synthesis pass the actual evidence and no tools.
                        session.tools = []
                        session.toolDispatch = nil
                        synthesisOnly = true
                        nextPrompt = synthesisPrompt(
                            originalRequest: text,
                            evidence: results
                        )
                        continue
                    }

                    // Mutation/launch tasks need no extra LLM prose pass.
                    return deterministicCompletion(for: text, state: taskState)
                }

                let currentFingerprint = Self.taskProgressFingerprint(
                    taskState
                )

                if currentFingerprint == passStartFingerprint {
                    consecutiveNoProgressPasses += 1

                    if consecutiveNoProgressPasses >= 2 {
                        await events.emit(
                            .warning(
                                "tool/model loop made no semantic progress for 2 consecutive passes; stopping"
                            )
                        )
                        break passLoop
                    }
                } else {
                    consecutiveNoProgressPasses = 0
                }

                let nextDecision = ProtocolEngine.decision(
                    for: taskState,
                    allowed: allowed
                )
                let requiredTools = Self.intelligenceTools(
                    from: nextDecision
                )
                session.tools = registry.schemas(named: requiredTools)

                nextPrompt = intelligencePrompt(
                    originalRequest: text,
                    decision: nextDecision,
                    evidence: results
                )
                continue
            }
        }

        let finalState = await registry.taskSnapshot()
        return finalState.isComplete
            ? deterministicCompletion(for: text, state: finalState)
            : ""
    }

    private func deterministicCompletion(
        for userText: String,
        state: TaskRuntimeSnapshot
    ) -> String {
        let isRussian = userText.range(
            of: #"[А-Яа-яЁё]"#,
            options: .regularExpression
        ) != nil

        guard let spec = state.spec else {
            return isRussian ? "Готово." : "Done."
        }

        if isRussian {
            if spec.kinds.contains(.debug) &&
               spec.requiresLaunch {
                return "Готово. Исправление выполнено, проверено и результат запущен."
            }

            if spec.kinds.contains(.modify) &&
               spec.requiresLaunch {
                return spec.explicitValidation
                    ? "Готово. Изменения выполнены, проверены и результат запущен."
                    : "Готово. Изменения выполнены и результат запущен."
            }

            if spec.kinds.contains(.create) &&
               spec.requiresLaunch {
                return "Готово. Запрошенный результат создан, проверен и запущен."
            }

            if spec.requiresLaunch {
                return "Готово. Запрошенный результат запущен."
            }

            if spec.requiresMutation &&
               (spec.explicitValidation || spec.explicitReadBack) {
                return "Готово. Изменения выполнены и проверены."
            }

            if spec.requiresMutation {
                return "Готово."
            }

            return "Готово."
        }

        if spec.kinds.contains(.modify) &&
           spec.requiresLaunch {
            return spec.explicitValidation
                ? "Done. The changes were completed, verified, and launched."
                : "Done. The changes were completed and launched."
        }

        if spec.kinds.contains(.create) &&
           spec.requiresLaunch {
            return "Done. The requested result was created, verified, and launched."
        }

        if spec.requiresLaunch {
            return "Done. The requested result was launched."
        }

        if spec.requiresMutation &&
           (spec.explicitValidation || spec.explicitReadBack) {
            return "Done. The changes were completed and verified."
        }

        return "Done."
    }

    private static func taskProgressFingerprint(
        _ state: TaskRuntimeSnapshot
    ) -> String {
        let missing = state.missingRequirements
            .map(\.description)
            .joined(separator: "|")

        let changedMutations = state.evidence.reduce(into: 0) { count, item in
            if case .mutated(_, _, let changed, _) = item, changed {
                count += 1
            }
        }

        let uniqueObservations = Set(
            state.evidence.compactMap { item -> String? in
                switch item {
                case .observed(let tool, let path):
                    return tool + ":" + (path ?? "")
                case .readBack(let path, _):
                    return "readBack:" + path
                default:
                    return nil
                }
            }
        ).sorted().joined(separator: ",")

        let externalProgress = state.evidence.compactMap { item -> String? in
            guard case .externalEffect(_, let server, let operation, let urls) = item else {
                return nil
            }
            return [
                server ?? "unknown",
                operation ?? "unknown",
                urls.joined(separator: ",")
            ].joined(separator: ":")
        }.joined(separator: "|")

        return [
            state.semanticState.rawValue,
            "missing=\(missing)",
            "changedMutations=\(changedMutations)",
            "observations=\(uniqueObservations)",
            "external=\(externalProgress)",
            "failed=\(state.validation.lastToolFailed ? "1" : "0")",
            "failure=\(state.validation.lastFailure ?? "")"
        ].joined(separator: ";")
    }

    private static func intelligenceTools(
        from decision: ProtocolDecision
    ) -> Set<String> {
        if case .intelligence(let request) = decision {
            return request.allowedTools
        }
        return []
    }

    private func intelligencePrompt(
        originalRequest: String,
        decision: ProtocolDecision,
        evidence: [String]
    ) -> String {
        let evidenceText = evidence.isEmpty
            ? "none"
            : evidence.joined(separator: "\n\n")

        switch decision {
        case .intelligence(let request):
            return """
            ORIGINAL REQUEST:
            \(originalRequest)

            INTELLIGENCE REQUEST — runtime selected this reasoning step:
            kind: \(request.kind.rawValue)
            target: \(request.target ?? "unresolved")
            reason: \(request.reason)
            exposed tools: \(request.allowedTools.sorted().joined(separator: ", "))

            DETERMINISTIC RUNTIME EVIDENCE:
            \(evidenceText)

            Do only this intelligence step. Use a tool when tools are exposed.
            If the intelligence request requires mutation and a mutation tool is exposed,
            prose, markdown, or a fenced code proposal does NOT satisfy the task: you MUST
            call the mutation tool with the actual change. Never claim that a file was changed
            unless the tool call succeeds.
            Do not repeat reads, validation, launch, project probing, or other work
            already owned by the runtime.
            """

        case .deterministic(let action):
            return "Runtime still owns the next deterministic action: \(action). Do not replace it with prose."

        case .done:
            return originalRequest

        case .blocked(let reason):
            return "Task is blocked by runtime state: \(reason)"
        }
    }

    private func evidenceBlocks(
        _ items: [(name: String, result: String)]
    ) -> [String] {
        items.map { item in
            """
            TOOL_RESULT
            name: \(item.name)
            result:
            \(promptResult(item.result))
            """
        }
    }

    private func synthesisPrompt(
        originalRequest: String,
        evidence: [String]
    ) -> String {
        """
        Answer the ORIGINAL user request using only the real tool evidence below.
        Do not invent facts that are not present in the evidence.
        Keep the answer concise and in the user's language.
        If the original request is Russian, the FINAL answer must contain
        no standalone English prose words copied from comments or tool output.
        Translate prose into natural Russian before answering. Keep Latin text
        only for exact code identifiers, paths, commands, extensions and literal
        technical names.

        ORIGINAL REQUEST:
        \(originalRequest)

        REAL TOOL EVIDENCE:
        \(evidence.joined(separator: "\n\n"))
        """
    }

    private func promptResult(_ result: String) -> String {
        let limit = 32_000
        guard result.count > limit else { return result }
        return String(result.prefix(limit))
            + "\n… [tool result truncated for synthesis] …"
    }

    private func semanticTaskContext(
        _ snapshot: TaskRuntimeSnapshot
    ) -> String {
        guard let spec = snapshot.spec else {
            return ""
        }

        let kinds = spec.kinds
            .map(\.rawValue)
            .sorted()
            .joined(separator: "+")

        let targets = snapshot.resolvedTargetPath ??
            (spec.targets.isEmpty
                ? "unresolved"
                : spec.targets.map(\.path).joined(separator: ", "))

        let desired = spec.desiredState.isEmpty
            ? "unspecified"
            : spec.desiredState
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")

        let requirements = spec.requirements.isEmpty
            ? "none"
            : spec.requirements
                .map(\.description)
                .joined(separator: "; ")

        let constraints = spec.constraints.isEmpty
            ? "none"
            : spec.constraints
                .map(\.description)
                .joined(separator: "; ")

        return """
        TASK SEMANTICS — compiled by deterministic runtime:
        id: \(spec.id)
        parent: \(spec.parentID?.description ?? "none")
        kinds: \(kinds)
        targets: \(targets)
        desired state: \(desired)
        required evidence: \(requirements)
        constraints: \(constraints)
        output policy: \(spec.outputPolicy.rawValue)
        compile confidence: \(String(format: "%.2f", spec.compileConfidence))
        compiler notes: \(spec.compilerNotes.isEmpty ? "none" : spec.compilerNotes.joined(separator: "; "))

        This block is the task's compile-time semantic contract. The runtime may bind
        an initially unresolved target after concrete tool evidence appears. On later
        passes, the current INTELLIGENCE REQUEST and DETERMINISTIC RUNTIME EVIDENCE are
        authoritative for that resolved target and current missing requirement. Use
        reasoning only for information the runtime cannot determine: content generation,
        diagnosis, design choices, explanation, or genuinely ambiguous target resolution.
        """
    }

    private func stream(session: ChatSession, prompt: String, label: String, stats: inout GenerationStats) async throws -> String {
        stats.passes += 1
        let uiOffsetSeconds = stats.modelSeconds
        await events.emit(
            .generationProgress(
                label: label,
                seconds: uiOffsetSeconds,
                chunks: 0
            )
        )
        let started = ContinuousClock.now
        let stallTimeout = timeoutSeconds
        let eventBus = events
        let debugEnabled = debug
        let heartbeat = stallTimeout > 0 ? GenerationHeartbeat() : nil
        let generationStream = session.streamDetails(to: prompt)

        struct Outcome: Sendable {
            let text: String
            let telemetry: ModelPassTelemetry
        }

        let outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var output = ""
                output.reserveCapacity(4_096)

                var chunks = 0
                var first: Double? = nil
                var telemetry: ModelPassTelemetry? = nil
                var lastUIUpdate = ContinuousClock.now

                for try await item in generationStream {
                    if Task.isCancelled { break }

                    heartbeat?.pulse()

                    switch item {
                    case .chunk(let chunk):
                        guard !chunk.isEmpty else { continue }

                        if first == nil {
                            first = Self.seconds(ContinuousClock.now - started)
                        }

                        output.append(chunk)
                        chunks += 1

                        let now = ContinuousClock.now
                        if Self.seconds(now - lastUIUpdate) >= 0.20 {
                            lastUIUpdate = now
                            await eventBus.emit(.generationProgress(
                                label: label,
                                seconds: uiOffsetSeconds + Self.seconds(now - started),
                                chunks: chunks
                            ))
                        }

                    case .info(let info):
                        telemetry = TelemetryExtractor.capture(
                            info,
                            wallSeconds: Self.seconds(ContinuousClock.now - started),
                            firstTokenSeconds: first
                        )
                        if debugEnabled {
                            await eventBus.emit(.notice("MLX: " + info.summary()))
                        }

                    default:
                        break
                    }
                }

                return Outcome(
                    text: output,
                    telemetry: telemetry ?? ModelPassTelemetry(
                        promptTokens: nil,
                        outputTokens: nil,
                        promptTokensPerSecond: nil,
                        generationTokensPerSecond: nil,
                        firstTokenSeconds: first,
                        wallSeconds: Self.seconds(ContinuousClock.now - started)
                    )
                )
            }

            if stallTimeout > 0 {
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))

                        guard let heartbeat else { throw CancellationError() }
                        let idle = heartbeat.idleSeconds()
                        if idle >= Double(stallTimeout) {
                            throw CLIError(
                                String(
                                    format: "generation stalled for %.1fs (optional watchdog %ds)",
                                    idle,
                                    stallTimeout
                                )
                            )
                        }
                    }

                    throw CancellationError()
                }
            }

            guard let first = try await group.next() else {
                throw CLIError("generation returned no result")
            }

            group.cancelAll()
            return first
        }
        await events.emit(.generationFinished)
        stats.modelSeconds += outcome.telemetry.wallSeconds
        stats.promptTokens += outcome.telemetry.promptTokens ?? 0
        stats.outputTokens += outcome.telemetry.outputTokens ?? 0
        if stats.firstTokenSeconds==nil { stats.firstTokenSeconds=outcome.telemetry.firstTokenSeconds }
        if let x=outcome.telemetry.promptTokensPerSecond { stats.promptTokensPerSecond=x }
        if let x=outcome.telemetry.generationTokensPerSecond { stats.generationTokensPerSecond=x }
        if debug { await events.emit(.notice("model tail:\n"+String(outcome.text.suffix(900)))) }
        return outcome.text
    }

    private static func parameters(maxTokens: Int?) -> GenerateParameters {
        var parameters = GenerateParameters()
        parameters.maxTokens = maxTokens
        parameters.temperature = 0.2
        parameters.topP = 0.92
        parameters.topK = 40
        parameters.minP = 0.02
        parameters.repetitionPenalty = 1.08
        parameters.repetitionContextSize = 96
        parameters.presencePenalty = 0.04
        parameters.presenceContextSize = 96
        parameters.frequencyPenalty = 0.03
        parameters.frequencyContextSize = 96
        return parameters
    }

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }
}

import Foundation
import SLTACore

// MARK: - v0.28 RuntimeCoordinator
//
// Authoritative task loop. Owns NEXT / DONE / BLOCKED / RECOVERABLE.
// Model-independent: no MLX imports, no ToolRegistry/Workspace/SessionContext
// concrete references (only the narrow RuntimeToolExecutor protocol).
//
// Target cycle per iteration:
//   snapshot = executor.taskSnapshot()
//   decision = ProtocolEngine.decision(snapshot, allowed)
//   .done                     -> runtime completion (no model call)
//   .blocked                  -> blocked state (no model call)
//   .deterministic(action)     -> execute, store evidence, continue (no model call)
//   .intelligence(request)     -> ONE provider.generate, execute returned
//                               tool calls, store evidence, continue
//
// A ModelResponse alone NEVER means DONE: only ProtocolEngine over
// RuntimeState evidence decides completion. Model prose ("done/fixed") is
// never evidence.

// MARK: - Executor boundary

/// Narrow runtime-owned tool boundary. Implemented by ToolRegistry.
/// Test doubles implement this without Workspace/MCP/MLX.
protocol RuntimeToolExecutor: Sendable {
    func taskSnapshot() async -> TaskRuntimeSnapshot
    func advanceProtocol(allowed: Set<String>) async -> [(name: String, result: String)]
    func executeNormalized(
        _ invocation: NormalizedToolInvocation,
        allowed: Set<String>
    ) async -> String
    func executeInvocations(
        _ invocations: [NormalizedToolInvocation],
        allowed: Set<String>
    ) async -> [(name: String, result: String)]
    func providerToolSpecs(named: Set<String>) -> [ProviderToolSpec]
}

// MARK: - Input / result

struct RuntimeTaskInput: Sendable {
    var userText: String
    var decision: TurnDecision
    var maxRounds: Int
    /// Conversational excerpt assembled by AgentLoop (text only — never
    /// used as operational truth; RuntimeState evidence is the truth).
    var sessionExcerpt: String
    var projectInstructions: String
    var runtimeContext: String
    var allowedTools: Set<String>
    var agentMaxTokens: Int?

    init(
        userText: String,
        decision: TurnDecision,
        maxRounds: Int,
        sessionExcerpt: String = "",
        projectInstructions: String = "",
        runtimeContext: String = "",
        allowedTools: Set<String>,
        agentMaxTokens: Int? = nil
    ) {
        self.userText = userText
        self.decision = decision
        self.maxRounds = maxRounds
        self.sessionExcerpt = sessionExcerpt
        self.projectInstructions = projectInstructions
        self.runtimeContext = runtimeContext
        self.allowedTools = allowedTools
        self.agentMaxTokens = agentMaxTokens
    }
}

enum RuntimeOutcome: Sendable {
    case completedDeterministic
    case completedSynthesis
    case blocked(String)
    case incomplete(String)
}

struct RuntimeTaskResult: Sendable {
    var displayText: String
    var snapshot: TaskRuntimeSnapshot
    var providerCalls: [ProviderCallTelemetry]
    var deterministicActions: Int
    var toolResults: Int
    var rounds: Int
    var outcome: RuntimeOutcome

    /// Physical model generations performed. Never conflated with
    /// deterministic actions, tool calls or loop rounds.
    var physicalGenerations: Int { providerCalls.count }
}

// MARK: - Coordinator

/// Stateless across runs (all mutable state is local to `run`), therefore
/// unconditionally Sendable given a Sendable executor.
public final class RuntimeCoordinator: Sendable {
    private let executor: any RuntimeToolExecutor
    private let events: EventBus
    private let projectInstructions: String

    init(
        executor: any RuntimeToolExecutor,
        events: EventBus,
        projectInstructions: String = ""
    ) {
        self.executor = executor
        self.events = events
        self.projectInstructions = projectInstructions
    }

    // MARK: Entry point

    func run(
        _ input: RuntimeTaskInput,
        provider: any ModelProvider
    ) async throws -> RuntimeTaskResult {
        let allowed = input.allowedTools
        let baseInstructions = Self.baseInstructions(
            projectInstructions: projectInstructions.isEmpty ? input.projectInstructions : projectInstructions,
            runtimeContext: input.runtimeContext,
            sessionExcerpt: input.sessionExcerpt
        )
        provider.beginTaskSession(instructions: baseInstructions)
        defer { provider.endTaskSession() }

        var providerCalls: [ProviderCallTelemetry] = []
        var deterministicActions = 0
        var toolResults = 0

        // Deterministic preflight runs before the first model pass when the
        // next missing requirement is already mechanically known.
        let preflight = await executor.advanceProtocol(allowed: allowed)
        deterministicActions += preflight.count
        var evidence = Self.evidenceBlocks(preflight)
        var snapshot = await executor.taskSnapshot()
        let taskID = Self.taskID(of: snapshot)
        await events.emit(.taskStateChanged(taskID: taskID, phase: snapshot.phase.rawValue))

        if snapshot.isComplete, !snapshot.requiresSynthesis {
            await events.emit(.taskCompleted(taskID: taskID))
            return RuntimeTaskResult(
                displayText: Self.deterministicCompletion(for: input.userText, state: snapshot),
                snapshot: snapshot,
                providerCalls: providerCalls,
                deterministicActions: deterministicActions,
                toolResults: toolResults,
                rounds: 0,
                outcome: .completedDeterministic
            )
        }

        var synthesisOnly = snapshot.isComplete && snapshot.requiresSynthesis
        if synthesisOnly {
            return try await performSynthesis(
                input: input,
                provider: provider,
                evidence: evidence,
                baseInstructions: baseInstructions,
                providerCalls: &providerCalls,
                deterministicActions: deterministicActions,
                toolResults: toolResults
            )
        }

        var decision = ProtocolEngine.decision(for: snapshot, allowed: allowed)
        var nextPrompt = Self.intelligencePrompt(
            originalRequest: input.userText,
            decision: decision,
            evidence: evidence
        )
        var consecutiveNoProgress = 0

        roundLoop: for _ in 0..<input.maxRounds {
            let roundStart = await executor.taskSnapshot()
            let roundFingerprint = Self.taskProgressFingerprint(roundStart)
            decision = ProtocolEngine.decision(for: roundStart, allowed: allowed)
            await events.emit(.protocolDecision(taskID: Self.taskID(of: roundStart), decision: "\(decision)"))

            switch decision {
            case .done:
                let doneSnapshot = await executor.taskSnapshot()
                if doneSnapshot.requiresSynthesis, !synthesisOnly {
                    return try await performSynthesis(
                        input: input,
                        provider: provider,
                        evidence: [],
                        baseInstructions: baseInstructions,
                        providerCalls: &providerCalls,
                        deterministicActions: deterministicActions,
                        toolResults: toolResults
                    )
                }
                await events.emit(.taskCompleted(taskID: Self.taskID(of: doneSnapshot)))
                return RuntimeTaskResult(
                    displayText: Self.deterministicCompletion(for: input.userText, state: doneSnapshot),
                    snapshot: doneSnapshot,
                    providerCalls: providerCalls,
                    deterministicActions: deterministicActions,
                    toolResults: toolResults,
                    rounds: providerCalls.count,
                    outcome: .completedDeterministic
                )

            case .blocked(let reason):
                let blockedSnapshot = await executor.taskSnapshot()
                await events.emit(.taskBlocked(taskID: Self.taskID(of: blockedSnapshot), reason: reason))
                return RuntimeTaskResult(
                    displayText: "",
                    snapshot: blockedSnapshot,
                    providerCalls: providerCalls,
                    deterministicActions: deterministicActions,
                    toolResults: toolResults,
                    rounds: providerCalls.count,
                    outcome: .blocked(reason)
                )

            case .deterministic(let action):
                let result = await executor.executeNormalized(action.normalizedInvocation, allowed: allowed)
                deterministicActions += 1
                toolResults += 1
                evidence = Self.evidenceBlocks([(name: action.toolName, result: result)])
                let after = await executor.taskSnapshot()
                if after.validation.lastToolFailed {
                    let reason = after.validation.lastFailure ?? "deterministic action failed"
                    await events.emit(.taskBlocked(taskID: Self.taskID(of: after), reason: reason))
                    return RuntimeTaskResult(
                        displayText: "",
                        snapshot: after,
                        providerCalls: providerCalls,
                        deterministicActions: deterministicActions,
                        toolResults: toolResults,
                        rounds: providerCalls.count,
                        outcome: .blocked(reason)
                    )
                }
                if after.isComplete {
                    if after.requiresSynthesis {
                        return try await performSynthesis(
                            input: input,
                            provider: provider,
                            evidence: evidence,
                            baseInstructions: baseInstructions,
                            providerCalls: &providerCalls,
                            deterministicActions: deterministicActions,
                            toolResults: toolResults
                        )
                    }
                    await events.emit(.taskCompleted(taskID: Self.taskID(of: after)))
                    return RuntimeTaskResult(
                        displayText: Self.deterministicCompletion(for: input.userText, state: after),
                        snapshot: after,
                        providerCalls: providerCalls,
                        deterministicActions: deterministicActions,
                        toolResults: toolResults,
                        rounds: providerCalls.count,
                        outcome: .completedDeterministic
                    )
                }
                if Self.taskProgressFingerprint(after) == roundFingerprint {
                    consecutiveNoProgress += 1
                    if consecutiveNoProgress >= 2 {
                        await events.emit(.warning("runtime made no semantic progress for 2 consecutive rounds; stopping"))
                        break roundLoop
                    }
                } else {
                    consecutiveNoProgress = 0
                }
                nextPrompt = Self.intelligencePrompt(
                    originalRequest: input.userText,
                    decision: ProtocolEngine.decision(for: after, allowed: allowed),
                    evidence: evidence
                )
                continue

            case .intelligence(let request):
                // Defensive narrowing: the provider only ever sees the
                // runtime-selected tool subset for this exact step.
                let stepTools = request.allowedTools.intersection(allowed)
                let modelRequest = ModelRequest(
                    purpose: .intelligence(request.kind),
                    instructions: baseInstructions,
                    prompt: nextPrompt,
                    tools: executor.providerToolSpecs(named: stepTools),
                    maxTokens: input.agentMaxTokens
                )
                await events.emit(.intelligenceStarted(taskID: Self.taskID(of: roundStart), kind: request.kind.rawValue))
                // Exactly ONE physical generation per loop iteration.
                let response = try await provider.generate(modelRequest)
                providerCalls.append(response.telemetry)
                await events.emit(.intelligenceFinished(
                    taskID: Self.taskID(of: roundStart),
                    provider: "\(response.telemetry.provider)",
                    durationSeconds: response.telemetry.durationSeconds
                ))

                if !response.toolCalls.isEmpty {
                    consecutiveNoProgress = 0
                    let executed = await executor.executeInvocations(response.toolCalls, allowed: stepTools)
                    toolResults += executed.count
                    evidence = Self.evidenceBlocks(executed)
                    var state = await executor.taskSnapshot()

                    if !state.validation.lastToolFailed, !state.isComplete {
                        let followed = await executor.advanceProtocol(allowed: allowed)
                        deterministicActions += followed.count
                        evidence.append(contentsOf: Self.evidenceBlocks(followed))
                        state = await executor.taskSnapshot()
                    }

                    if state.validation.lastToolFailed {
                        if state.validation.consecutiveToolFailures >= 3 {
                            break roundLoop
                        }
                        nextPrompt = Self.recoverablePrompt(state: state, evidence: evidence)
                        continue
                    }

                    if state.isComplete {
                        if state.requiresSynthesis {
                            return try await performSynthesis(
                                input: input,
                                provider: provider,
                                evidence: evidence,
                                baseInstructions: baseInstructions,
                                providerCalls: &providerCalls,
                                deterministicActions: deterministicActions,
                                toolResults: toolResults
                            )
                        }
                        await events.emit(.taskCompleted(taskID: Self.taskID(of: state)))
                        return RuntimeTaskResult(
                            displayText: Self.deterministicCompletion(for: input.userText, state: state),
                            snapshot: state,
                            providerCalls: providerCalls,
                            deterministicActions: deterministicActions,
                            toolResults: toolResults,
                            rounds: providerCalls.count,
                            outcome: .completedDeterministic
                        )
                    }

                    if Self.taskProgressFingerprint(state) == roundFingerprint {
                        consecutiveNoProgress += 1
                        if consecutiveNoProgress >= 2 {
                            await events.emit(.warning("tool/model loop made no semantic progress for 2 consecutive rounds; stopping"))
                            break roundLoop
                        }
                    } else {
                        consecutiveNoProgress = 0
                    }
                    nextPrompt = Self.intelligencePrompt(
                        originalRequest: input.userText,
                        decision: ProtocolEngine.decision(for: state, allowed: allowed),
                        evidence: evidence
                    )
                    continue
                }

                // Prose-only response. Prose is NEVER evidence and NEVER
                // completes a task by itself (scenario D).
                let proseState = await executor.taskSnapshot()
                if proseState.validation.lastToolFailed {
                    if proseState.validation.consecutiveToolFailures >= 3 {
                        break roundLoop
                    }
                    nextPrompt = Self.recoverablePrompt(state: proseState, evidence: [])
                    continue
                }
                if proseState.isComplete {
                    let clean = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await events.emit(.taskCompleted(taskID: Self.taskID(of: proseState)))
                    return RuntimeTaskResult(
                        displayText: clean.isEmpty
                            ? Self.deterministicCompletion(for: input.userText, state: proseState)
                            : clean,
                        snapshot: proseState,
                        providerCalls: providerCalls,
                        deterministicActions: deterministicActions,
                        toolResults: toolResults,
                        rounds: providerCalls.count,
                        outcome: .completedSynthesis
                    )
                }
                let followed = await executor.advanceProtocol(allowed: allowed)
                deterministicActions += followed.count
                evidence = Self.evidenceBlocks(followed)
                var advanced = await executor.taskSnapshot()
                if advanced.validation.lastToolFailed {
                    nextPrompt = Self.recoverablePrompt(state: advanced, evidence: evidence)
                    continue
                }
                if advanced.isComplete {
                    if advanced.requiresSynthesis {
                        return try await performSynthesis(
                            input: input,
                            provider: provider,
                            evidence: evidence,
                            baseInstructions: baseInstructions,
                            providerCalls: &providerCalls,
                            deterministicActions: deterministicActions,
                            toolResults: toolResults
                        )
                    }
                    await events.emit(.taskCompleted(taskID: Self.taskID(of: advanced)))
                    return RuntimeTaskResult(
                        displayText: Self.deterministicCompletion(for: input.userText, state: advanced),
                        snapshot: advanced,
                        providerCalls: providerCalls,
                        deterministicActions: deterministicActions,
                        toolResults: toolResults,
                        rounds: providerCalls.count,
                        outcome: .completedDeterministic
                    )
                }
                if Self.taskProgressFingerprint(advanced) == roundFingerprint {
                    consecutiveNoProgress += 1
                    if consecutiveNoProgress >= 2 {
                        await events.emit(.warning("model made no semantic progress for 2 consecutive rounds; stopping instead of retrying blindly"))
                        break roundLoop
                    }
                } else {
                    consecutiveNoProgress = 0
                }
                if response.format == .textFallback {
                    // Incomplete textual tool call: targeted single retry.
                    // The provider never retries internally; the runtime owns it.
                    nextPrompt = Self.incompleteRetryPrompt(tail: response.text)
                } else {
                    advanced = await executor.taskSnapshot()
                    nextPrompt = Self.intelligencePrompt(
                        originalRequest: input.userText,
                        decision: ProtocolEngine.decision(for: advanced, allowed: allowed),
                        evidence: evidence
                    )
                }
            }
        }

        let final = await executor.taskSnapshot()
        if final.isComplete {
            await events.emit(.taskCompleted(taskID: Self.taskID(of: final)))
            return RuntimeTaskResult(
                displayText: Self.deterministicCompletion(for: input.userText, state: final),
                snapshot: final,
                providerCalls: providerCalls,
                deterministicActions: deterministicActions,
                toolResults: toolResults,
                rounds: providerCalls.count,
                outcome: .completedDeterministic
            )
        }
        return RuntimeTaskResult(
            displayText: "",
            snapshot: final,
            providerCalls: providerCalls,
            deterministicActions: deterministicActions,
            toolResults: toolResults,
            rounds: providerCalls.count,
            outcome: .incomplete(final.incompleteReason)
        )
    }

    // MARK: Synthesis (exactly one tool-free pass)

    private func performSynthesis(
        input: RuntimeTaskInput,
        provider: any ModelProvider,
        evidence: [String],
        baseInstructions: String,
        providerCalls: inout [ProviderCallTelemetry],
        deterministicActions: Int,
        toolResults: Int
    ) async throws -> RuntimeTaskResult {
        let snapshot = await executor.taskSnapshot()
        let taskID = Self.taskID(of: snapshot)
        let request = ModelRequest(
            purpose: .synthesis,
            instructions: baseInstructions,
            prompt: Self.synthesisPrompt(originalRequest: input.userText, evidence: evidence),
            tools: [],
            maxTokens: input.agentMaxTokens
        )
        await events.emit(.intelligenceStarted(taskID: taskID, kind: IntelligenceKind.synthesize.rawValue))
        // Synthesis errors propagate like any provider failure: the runtime
        // owns recovery policy and never hides a failed generation.
        do {
            let response = try await provider.generate(request)
            providerCalls.append(response.telemetry)
            await events.emit(.intelligenceFinished(
                taskID: taskID,
                provider: "\(response.telemetry.provider)",
                durationSeconds: response.telemetry.durationSeconds
            ))
            let clean = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let after = await executor.taskSnapshot()
            await events.emit(.taskCompleted(taskID: Self.taskID(of: after)))
            return RuntimeTaskResult(
                displayText: clean.isEmpty
                    ? Self.deterministicCompletion(for: input.userText, state: after)
                    : clean,
                snapshot: after,
                providerCalls: providerCalls,
                deterministicActions: deterministicActions,
                toolResults: toolResults,
                rounds: providerCalls.count,
                outcome: .completedSynthesis
            )
        } catch {
            await events.emit(.warning("synthesis generation failed: \(error.localizedDescription)"))
            throw error
        }
    }

    // MARK: - Pure runtime prompt builders (moved out of MLXModelAdapter)

    static func baseInstructions(
        projectInstructions: String,
        runtimeContext: String,
        sessionExcerpt: String
    ) -> String {
        var parts = [SystemPrompt.agent(
            projectInstructions: projectInstructions,
            runtimeContext: runtimeContext
        )]
        if !sessionExcerpt.isEmpty { parts.append(sessionExcerpt) }
        return parts.joined(separator: "\n\n")
    }

    static func taskID(of snapshot: TaskRuntimeSnapshot) -> String {
        snapshot.spec.map { "\($0.id)" } ?? "no-task"
    }

    static func evidenceBlocks(_ items: [(name: String, result: String)]) -> [String] {
        items.map { item in
            """
            TOOL_RESULT
            name: \(item.name)
            result:
            \(promptResult(item.result))
            """
        }
    }

    static func promptResult(_ result: String) -> String {
        let limit = 32_000
        guard result.count > limit else { return result }
        return String(result.prefix(limit)) + "\n… [tool result truncated for synthesis] …"
    }

    static func recoverablePrompt(state: TaskRuntimeSnapshot, evidence: [String]) -> String {
        """
        RECOVERABLE TOOL ERROR.
        Correct only the unresolved failed tool call and continue the SAME task.
        Real error: \(state.validation.lastFailure ?? "unknown tool error")

        \(evidence.joined(separator: "\n\n"))
        """
    }

    static func incompleteRetryPrompt(tail: String) -> String {
        """
        The previous textual tool call was incomplete and was not executed.
        Retry that same required action exactly once with all required arguments
        and closing tags. Do not switch to another tool and do not add prose.

        Incomplete tail:
        \(String(tail.suffix(2_000)))
        """
    }

    static func intelligencePrompt(
        originalRequest: String,
        decision: ProtocolDecision,
        evidence: [String]
    ) -> String {
        let evidenceText = evidence.isEmpty ? "none" : evidence.joined(separator: "\n\n")
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

    static func synthesisPrompt(originalRequest: String, evidence: [String]) -> String {
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

    static func deterministicCompletion(for userText: String, state: TaskRuntimeSnapshot) -> String {
        let isRussian = userText.range(of: #"[А-Яа-яЁё]"#, options: .regularExpression) != nil
        guard let spec = state.spec else {
            return isRussian ? "Готово." : "Done."
        }
        if isRussian {
            if spec.kinds.contains(.debug) && spec.requiresLaunch {
                return "Готово. Исправление выполнено, проверено и результат запущен."
            }
            if spec.kinds.contains(.modify) && spec.requiresLaunch {
                return spec.explicitValidation
                    ? "Готово. Изменения выполнены, проверены и результат запущен."
                    : "Готово. Изменения выполнены и результат запущен."
            }
            if spec.kinds.contains(.create) && spec.requiresLaunch {
                return "Готово. Запрошенный результат создан, проверен и запущен."
            }
            if spec.requiresLaunch {
                return "Готово. Запрошенный результат запущен."
            }
            if spec.requiresMutation && (spec.explicitValidation || spec.explicitReadBack) {
                return "Готово. Изменения выполнены и проверены."
            }
            if spec.requiresMutation {
                return "Готово."
            }
            return "Готово."
        }
        if spec.kinds.contains(.modify) && spec.requiresLaunch {
            return spec.explicitValidation
                ? "Done. The changes were completed, verified, and launched."
                : "Done. The changes were completed and launched."
        }
        if spec.kinds.contains(.create) && spec.requiresLaunch {
            return "Done. The requested result was created, verified, and launched."
        }
        if spec.requiresLaunch {
            return "Done. The requested result was launched."
        }
        if spec.requiresMutation && (spec.explicitValidation || spec.explicitReadBack) {
            return "Done. The changes were completed and verified."
        }
        return "Done."
    }

    static func taskProgressFingerprint(_ state: TaskRuntimeSnapshot) -> String {
        let missing = state.missingRequirements.map(\.description).joined(separator: "|")
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
            return [server ?? "unknown", operation ?? "unknown", urls.joined(separator: ",")].joined(separator: ":")
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
}

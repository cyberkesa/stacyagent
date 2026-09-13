import Foundation

// MARK: - v0.28 RuntimeCoordinator deterministic tests (A-G)
//
// No MLX model. Real TaskCompiler + real RuntimeState + real ProtocolEngine,
// scripted RuntimeToolExecutor, FakeModelProvider. Collected by SLTASelfTest.

struct CoordinatorCheckResult {
    var passed: Bool
    var name: String
}

/// Scripted executor: REAL RuntimeState evidence, canned tool effects.
final class ScriptExecutor: RuntimeToolExecutor, @unchecked Sendable {
    let state = RuntimeState()
    /// Tool names that fail recoverably exactly once (then succeed).
    var failOnce: Set<String> = []

    func begin(_ spec: TaskSpec) async {
        await state.beginTask(spec)
    }

    func taskSnapshot() async -> TaskRuntimeSnapshot {
        await state.taskSnapshot()
    }

    func advanceProtocol(allowed: Set<String>) async -> [(name: String, result: String)] {
        var output: [(name: String, result: String)] = []
        for _ in 0..<8 {
            let before = await state.taskSnapshot()
            guard case .deterministic(let action) = ProtocolEngine.decision(
                for: before,
                allowed: allowed
            ) else { break }
            let result = await executeNormalized(action.normalizedInvocation, allowed: allowed)
            output.append((name: action.toolName, result: result))
            let after = await state.taskSnapshot()
            if after.isComplete || after.validation.lastToolFailed { break }
        }
        return output
    }

    func executeNormalized(
        _ invocation: NormalizedToolInvocation,
        allowed: Set<String>
    ) async -> String {
        let name = invocation.name
        let args = invocation.arguments
        if failOnce.contains(name) {
            failOnce.remove(name)
            await state.recoverableFailure(name, message: "unique edit target not found (scripted)")
            return #"{"ok":false,"error":"unique edit target not found","retry":true}"#
        }
        switch name {
        case "read_file":
            let path = args["path"] ?? "budget_lab.html"
            let content = "<html>scripted</html>"
            await state.readBack(path: path, content: content)
            return content
        case "read_file_range":
            let path = args["path"] ?? "budget_lab.html"
            await state.observation(name, path: path)
            return "range \(path) lines 1-1/1"
        case "write_file":
            let path = args["path"] ?? "budget_lab.html"
            await state.mutation(name, path: path, content: args["content"], changed: true)
            return "wrote \(path)"
        case "edit_file", "edit_file_range":
            let path = args["path"] ?? "budget_lab.html"
            await state.mutation(name, path: path, content: nil, changed: true)
            return "updated \(path)"
        case "validate_file":
            let path = args["path"] ?? "budget_lab.html"
            await state.validationSuccess(name, isRealValidation: true, path: path)
            return "valid \(path)"
        case "open_file":
            let path = args["path"] ?? "budget_lab.html"
            await state.launchSuccess(name, path: path)
            return "opened \(path)"
        case "shell":
            await state.validationSuccess(name, isRealValidation: true)
            return "exit=0"
        default:
            await state.observation(name)
            return "ok"
        }
    }

    func executeInvocations(
        _ invocations: [NormalizedToolInvocation],
        allowed: Set<String>
    ) async -> [(name: String, result: String)] {
        var output: [(name: String, result: String)] = []
        for invocation in invocations {
            let before = await state.taskSnapshot()
            if before.isComplete || before.validation.lastToolFailed { break }
            let result = await executeNormalized(invocation, allowed: allowed)
            output.append((name: invocation.name, result: result))
            let after = await state.taskSnapshot()
            if after.isComplete || after.validation.lastToolFailed { break }
            if SemanticToolCatalog.isMutating(invocation.name),
               ProtocolEngine.shouldYieldAfterMutation(after) {
                break
            }
        }
        return output
    }

    func providerToolSpecs(named allowed: Set<String>) -> [ProviderToolSpec] {
        allowed.sorted().map { ProviderToolSpec(name: $0, description: $0) }
    }
}

final class NullSink: AgentEventSink, @unchecked Sendable {
    func emit(_ event: AgentEvent) async {}
}

enum CoordinatorSelfTest {
    static let allTools: Set<String> = [
        "list_dir", "read_file", "search", "write_file", "edit_file",
        "validate_file", "shell", "open_file"
    ]

    static func runAll() async -> [CoordinatorCheckResult] {
        var out: [CoordinatorCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(CoordinatorCheckResult(passed: passed, name: name))
        }

        let agent = TurnDecision.forMode(.agent, source: .fast)
        let bus = EventBus(sink: NullSink())

        func modifyExecutor() async -> ScriptExecutor {
            let executor = ScriptExecutor()
            let createText = "Создай budget_lab.html, проверь файл и запусти его."
            let create = TaskCompiler.compile(userText: createText, decision: agent)
            let continuity = TaskContinuity(
                isContinuation: true,
                priorTaskID: create.id,
                priorGoal: createText,
                rootGoal: nil,
                artifactMinimumLineCount: nil,
                lastArtifact: "budget_lab.html",
                previousRequiredLaunch: true,
                failureFeedback: false,
                failureKind: .none,
                bareAction: false,
                revisionRequest: false,
                requestsNewArtifact: false
            )
            let modify = TaskCompiler.compile(
                userText: "Теперь измени его: добавь редактирование суммы. Проверь и снова запусти.",
                decision: agent,
                continuity: continuity
            )
            await executor.begin(modify)
            return executor
        }

        func input(_ decision: TurnDecision, maxRounds: Int) -> RuntimeTaskInput {
            RuntimeTaskInput(
                userText: "test",
                decision: decision,
                maxRounds: maxRounds,
                sessionExcerpt: "",
                projectInstructions: "test",
                runtimeContext: "",
                allowedTools: allTools,
                agentMaxTokens: nil
            )
        }

        // A. Deterministic read executes with zero provider calls.
        do {
            let executor = await modifyExecutor()
            let before = await executor.taskSnapshot()
            let firstIsDeterministic: Bool = {
                if case .deterministic = ProtocolEngine.decision(for: before, allowed: allTools) {
                    return true
                }
                return false
            }()
            let provider = FakeModelProvider()
            let coordinator = RuntimeCoordinator(executor: executor, events: bus)
            let result = try await coordinator.run(input(agent, maxRounds: 0), provider: provider)
            let hasObservation = result.snapshot.evidence.contains { item in
                if case .observed = item { return true }
                return false
            }
            record(
                firstIsDeterministic && provider.callCount == 0 &&
                result.deterministicActions >= 1 && hasObservation,
                "coord-A deterministic without provider"
            )
        } catch {
            record(false, "coord-A deterministic without provider")
        }

        // B. Intelligence step calls the fake provider exactly once per round.
        do {
            let executor = await modifyExecutor()
            let provider = FakeModelProvider()
            provider.script([.doneProse, .doneProse, .doneProse, .doneProse, .doneProse])
            let coordinator = RuntimeCoordinator(executor: executor, events: bus)
            let result = try await coordinator.run(input(agent, maxRounds: 5), provider: provider)
            let firstTools = provider.requests.first.map { Set($0.tools.map(\.name)) } ?? []
            record(
                provider.callCount >= 1 && result.physicalGenerations == provider.callCount &&
                firstTools == Set(["write_file", "edit_file"]),
                "coord-B intelligence calls provider once per round"
            )
        } catch {
            record(false, "coord-B intelligence calls provider once per round")
        }

        // C. Provider tool request executes; runtime-owned follow-through
        // (validate+launch) completes the task with NO further model calls.
        do {
            let executor = await modifyExecutor()
            let provider = FakeModelProvider()
            provider.script([
                ScriptedResponse(
                    text: "",
                    toolCalls: [NormalizedToolInvocation(
                        name: "edit_file",
                        arguments: ["path": "budget_lab.html", "old": "a", "new": "b"],
                        source: .provider
                    )],
                    format: .native
                )
            ])
            let coordinator = RuntimeCoordinator(executor: executor, events: bus)
            let result = try await coordinator.run(input(agent, maxRounds: 1), provider: provider)
            let snapshot = await executor.taskSnapshot()
            let mutated = snapshot.evidence.contains { item in
                if case .mutated(_, _, let changed, _) = item { return changed }
                return false
            }
            let completed: Bool = {
                if case .completedDeterministic = result.outcome { return true }
                return false
            }()
            record(
                provider.callCount == 1 && mutated && completed && snapshot.isComplete,
                "coord-C tool request becomes runtime evidence"
            )
        } catch {
            record(false, "coord-C tool request becomes runtime evidence")
        }

        // D. Prose "done" with unmet requirements never completes the task.
        do {
            let executor = await modifyExecutor()
            let provider = FakeModelProvider()
            provider.script([.doneProse])
            let coordinator = RuntimeCoordinator(executor: executor, events: bus)
            let result = try await coordinator.run(input(agent, maxRounds: 1), provider: provider)
            let completed: Bool = {
                if case .completedDeterministic = result.outcome { return true }
                if case .completedSynthesis = result.outcome { return true }
                return false
            }()
            record(
                provider.callCount == 1 && !completed && result.displayText.isEmpty,
                "coord-D prose done is not evidence"
            )
        } catch {
            record(false, "coord-D prose done is not evidence")
        }

        // E. Satisfied requirements complete with zero additional model calls.
        do {
            let executor = ScriptExecutor()
            let create = TaskCompiler.compile(
                userText: "Создай budget_lab.html, проверь файл и запусти его.",
                decision: agent
            )
            await executor.begin(create)
            await executor.state.mutation(
                "write_file",
                path: "budget_lab.html",
                content: "<html><body></body></html>",
                changed: true
            )
            await executor.state.validationSuccess(
                "validate_file",
                isRealValidation: true,
                path: "budget_lab.html"
            )
            await executor.state.launchSuccess("open_file", path: "budget_lab.html")
            let provider = FakeModelProvider()
            provider.script([.doneProse])
            let coordinator = RuntimeCoordinator(executor: executor, events: bus)
            let result = try await coordinator.run(input(agent, maxRounds: 4), provider: provider)
            let completed: Bool = {
                if case .completedDeterministic = result.outcome { return true }
                return false
            }()
            record(
                provider.callCount == 0 && completed && !result.displayText.isEmpty,
                "coord-E done needs no model call"
            )
        } catch {
            record(false, "coord-E done needs no model call")
        }

        // F. Recoverable tool failure keeps the task active (not blocked).
        do {
            let executor = await modifyExecutor()
            executor.failOnce = ["edit_file"]
            let provider = FakeModelProvider()
            provider.script([
                ScriptedResponse(
                    text: "",
                    toolCalls: [NormalizedToolInvocation(
                        name: "edit_file",
                        arguments: ["path": "budget_lab.html", "old": "a", "new": "b"],
                        source: .provider
                    )],
                    format: .native
                )
            ])
            let coordinator = RuntimeCoordinator(executor: executor, events: bus)
            let result = try await coordinator.run(input(agent, maxRounds: 1), provider: provider)
            let snapshot = await executor.taskSnapshot()
            let blocked: Bool = {
                if case .blocked = result.outcome { return true }
                return false
            }()
            record(
                provider.callCount == 1 && !blocked &&
                !snapshot.validation.lastToolFailed &&
                snapshot.validation.consecutiveToolFailures >= 1,
                "coord-F recoverable failure stays active"
            )
        } catch {
            record(false, "coord-F recoverable failure stays active")
        }

        // G. No-progress guard bounds the loop without endless model calls.
        do {
            let executor = await modifyExecutor()
            let provider = FakeModelProvider()
            provider.script(Array(repeating: .doneProse, count: 10))
            let coordinator = RuntimeCoordinator(executor: executor, events: bus)
            let result = try await coordinator.run(input(agent, maxRounds: 10), provider: provider)
            let incomplete: Bool = {
                if case .incomplete = result.outcome { return true }
                return false
            }()
            record(
                provider.callCount == 2 && provider.callCount < 10 && incomplete,
                "coord-G no-progress guard bounds model loop"
            )
        } catch {
            record(false, "coord-G no-progress guard bounds model loop")
        }

        // H1. Provider has no ToolRegistry reference (boundary is data-only).
        do {
            let request = ModelRequest(
                purpose: .intelligence(.editArtifact),
                instructions: "i",
                prompt: "p",
                tools: [ProviderToolSpec(name: "edit_file", description: "e")]
            )
            let mirror = Mirror(reflecting: request)
            let hasRegistry = "\(mirror)".contains("ToolRegistry")
            record(
                !hasRegistry && request.tools.count == 1 &&
                Mirror(reflecting: ModelResponse(
                    requestID: request.id,
                    text: "t",
                    telemetry: ProviderCallTelemetry(
                        provider: ModelProviderID("x"),
                        model: "m",
                        requestID: request.id,
                        purpose: .chat
                    )
                )).children.count > 0,
                "coord-H provider boundary is data-only"
            )
        }

        return out
    }
}

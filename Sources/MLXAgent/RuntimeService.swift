import Foundation
import Darwin
import SLTAIPC
import SLTACore

final class RuntimeEventRelay: AgentEventSink, @unchecked Sendable {
    private let workspaceID: String
    private let lock = NSLock()
    private weak var server: UnixSocketServer?
    private var sequence: UInt64 = 0
    private var requestID: UUID?
    private var taskID: String?
    private var telemetry = RuntimeTelemetrySnapshot()

    init(workspaceID: String) { self.workspaceID = workspaceID }

    func attach(_ server: UnixSocketServer) {
        lock.withLock { self.server = server }
    }

    func correlate(requestID: UUID?, taskID: String?) {
        lock.withLock {
            self.requestID = requestID
            self.taskID = taskID
        }
    }

    func telemetrySnapshot() -> RuntimeTelemetrySnapshot {
        lock.withLock { telemetry }
    }

    func emit(_ event: AgentEvent) async {
        let translated = translate(event)
        let correlatedTaskID = eventTaskID(event)
        let values = lock.withLock { () -> (UInt64, UUID?, String?, UnixSocketServer?) in
            switch event {
            case .intelligenceFinished:
                telemetry.modelCalls += 1
            case .toolFinished:
                telemetry.toolResults += 1
            case .computationFinished(_, _, _, _, _, let modelAvoided):
                if modelAvoided { telemetry.deterministicActions += 1 }
            case .contextCompilationFinished(_, _, _, let tokens, _, _):
                telemetry.contextTokens += tokens
            default:
                break
            }
            guard translated != nil else {
                return (sequence, requestID, correlatedTaskID ?? taskID, server)
            }
            sequence &+= 1
            return (sequence, requestID, correlatedTaskID ?? taskID, server)
        }
        guard let translated else { return }
        let runtimeEvent = RuntimeEvent(
            sequence: values.0, requestID: values.1,
            taskID: values.2, payload: translated
        )
        values.3?.broadcast(IPCEnvelope(
            requestID: values.1 ?? UUID(), workspaceID: workspaceID,
            kind: .event, payload: .event(runtimeEvent)
        ))
    }

    private func translate(_ event: AgentEvent) -> RuntimeEventPayload? {
        switch event {
        case .modelLoading: return .modelLoading
        case .modelReady: return .modelReady
        case .taskStarted(let text): return .taskStarted(text: sanitize(text))
        case .taskStateChanged(let taskID, let phase):
            return .taskState(taskID: taskID, phase: phase)
        case .generationStarted(let label): return .generationStarted(label: label)
        case .generationProgress(let label, let seconds, let chunks):
            return .generationProgress(label: label, seconds: seconds, chunks: chunks)
        case .generationFinished: return .generationFinished
        case .toolStarted(let name): return .toolStarted(name: name)
        case .toolFinished(let name, let ok, let detail, let duration):
            return .toolFinished(
                name: name, ok: ok, detail: sanitize(detail),
                durationSeconds: Self.seconds(duration)
            )
        case .assistant(let text): return .assistant(text: sanitize(text))
        case .notice(let text): return .notice(text: sanitize(text))
        case .warning(let text): return .warning(text: sanitize(text))
        case .completed(let stats):
            return .completed(
                elapsedSeconds: Self.seconds(stats.elapsed), outputTokens: stats.outputTokens
            )
        case .computationRouted(_, let strategy, let latency, let calls, let hit):
            return .telemetry(
                name: "computationRouted",
                detail: "strategy=\(strategy) latency=\(latency) modelCalls=\(calls) cacheHit=\(hit)"
            )
        case .computationEscalated(_, let from, let to, let reason):
            return .telemetry(
                name: "computationEscalated",
                detail: "\(from)->\(to): \(sanitize(reason))"
            )
        case .taskBlocked(let taskID, let reason):
            return .taskState(taskID: taskID, phase: "blocked: \(sanitize(reason))")
        case .taskCompiled(let taskID):
            return .telemetry(name: "taskCompiled", detail: taskID)
        case .protocolDecision(_, let decision):
            return .telemetry(name: "protocolDecision", detail: sanitize(decision))
        case .intelligenceStarted(_, let kind):
            return .telemetry(name: "intelligenceStarted", detail: kind)
        case .intelligenceFinished(_, let provider, let duration):
            return .telemetry(name: "intelligenceFinished", detail: "provider=\(provider) duration=\(duration)")
        case .proposalCreated(_, let path):
            return .telemetry(name: "proposalCreated", detail: path)
        case .transactionApplied(_, let path, let transaction):
            return .telemetry(name: "transactionApplied", detail: "\(path): \(sanitize(transaction))")
        case .validationFinished(let path, let ok):
            return .telemetry(name: "validationFinished", detail: "path=\(path) ok=\(ok)")
        case .taskCompleted(let taskID):
            return .taskState(taskID: taskID, phase: "done")
        case .artifactRevisionCreated(_, let path, let revision):
            return .telemetry(name: "artifactRevisionCreated", detail: "\(path)@\(revision)")
        case .artifactExternalChangeDetected(let path, let revision):
            return .telemetry(name: "artifactExternalChangeDetected", detail: "\(path)@\(revision)")
        case .evidenceRecorded(_, let kind, let path):
            return .telemetry(name: "evidenceRecorded", detail: "kind=\(kind) path=\(path ?? "")")
        case .evidenceBecameStale(_, let path):
            return .telemetry(name: "evidenceBecameStale", detail: path)
        case .runtimeStatePersisted(let projectID):
            return .telemetry(name: "runtimeStatePersisted", detail: projectID)
        case .runtimeStateRestored(let projectID):
            return .telemetry(name: "runtimeStateRestored", detail: projectID)
        case .codeIntelligenceStarted(let provider, let operation):
            return .telemetry(name: "codeIntelligenceStarted", detail: "\(provider):\(operation)")
        case .codeIntelligenceFinished(let provider, let operation, let duration, let hit, let count):
            return .telemetry(name: "codeIntelligenceFinished", detail: "\(provider):\(operation) duration=\(duration) cacheHit=\(hit) results=\(count)")
        case .semanticFactRecorded(let kind, let path, let revision):
            return .telemetry(name: "semanticFactRecorded", detail: "\(kind) \(path)@\(revision)")
        case .semanticFactBecameStale(let kind, let path):
            return .telemetry(name: "semanticFactBecameStale", detail: "\(kind) \(path)")
        case .semanticEditPlanned(_, let files, let edits):
            return .telemetry(name: "semanticEditPlanned", detail: "files=\(files.joined(separator: ",")) edits=\(edits)")
        case .semanticEditApplied(_, let files):
            return .telemetry(name: "semanticEditApplied", detail: files.joined(separator: ","))
        case .semanticAmbiguityDetected(let symbol, let candidates):
            return .telemetry(name: "semanticAmbiguityDetected", detail: "\(symbol): \(candidates.joined(separator: ","))")
        case .contextCompilationStarted(_, let purpose):
            return .telemetry(name: "contextCompilationStarted", detail: purpose)
        case .contextCompilationFinished(_, let duration, let items, let tokens, let hit, let levels):
            return .telemetry(name: "contextCompilationFinished", detail: "duration=\(duration) items=\(items) tokens=\(tokens) cacheHit=\(hit) levels=\(levels)")
        case .contextItemAdded(_, let itemID, let kind):
            return .telemetry(name: "contextItemAdded", detail: "\(itemID):\(kind)")
        case .contextItemDropped(_, let itemID, let reason):
            return .telemetry(name: "contextItemDropped", detail: "\(itemID): \(sanitize(reason))")
        case .contextBundleInvalidated(let path):
            return .telemetry(name: "contextBundleInvalidated", detail: path)
        case .computationRequested(_, let intent):
            return .telemetry(name: "computationRequested", detail: intent)
        case .computationFinished(_, let strategy, let duration, let count, let hit, let avoided):
            return .telemetry(name: "computationFinished", detail: "strategy=\(strategy) duration=\(duration) candidates=\(count) cacheHit=\(hit) modelAvoided=\(avoided)")
        }
    }

    private func eventTaskID(_ event: AgentEvent) -> String? {
        switch event {
        case .taskCompiled(let id), .taskStateChanged(let id, _),
             .protocolDecision(let id, _), .intelligenceStarted(let id, _),
             .intelligenceFinished(let id, _, _), .proposalCreated(let id, _),
             .transactionApplied(let id, _, _), .taskCompleted(let id),
             .taskBlocked(let id, _), .artifactRevisionCreated(let id, _, _),
             .evidenceRecorded(let id, _, _), .evidenceBecameStale(let id, _),
             .semanticEditPlanned(let id, _, _), .semanticEditApplied(let id, _),
             .contextCompilationStarted(let id, _),
             .contextCompilationFinished(let id, _, _, _, _, _),
             .contextItemAdded(let id, _, _), .contextItemDropped(let id, _, _),
             .computationRequested(let id, _), .computationRouted(let id, _, _, _, _),
             .computationFinished(let id, _, _, _, _, _),
             .computationEscalated(let id, _, _, _):
            return id
        default:
            return nil
        }
    }

    private func sanitize(_ text: String) -> String {
        var result = text
        let patterns = [
            #"sk-[A-Za-z0-9_-]{12,}"#,
            #"(?i)(api[_-]?key\s*[:=]\s*)\S+"#,
            #"(?i)(authorization:\s*bearer\s+)\S+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: "$1[REDACTED]"
            )
        }
        return result
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private final class RuntimeSubmitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var completed: String?

    func wait() async -> String {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> String? in
                if let completed { return completed }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func finish(_ result: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Never>? in
            guard completed == nil else { return nil }
            completed = result
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(returning: result)
    }
}

private actor RuntimeServiceController {
    let workspaceID: String
    let workspacePath: String
    let registry: ToolRegistry
    let relay: RuntimeEventRelay
    let runTurn: @Sendable (String) async throws -> Void
    var activeTask: Task<Void, Never>?
    var activeWaiter: RuntimeSubmitWaiter?
    var activeTaskID: String?
    var recentTaskSummary: String?
    var outcome: String?
    var cancelled = Set<String>()
    var shutdownHandler: (@Sendable () -> Void)?

    init(
        workspaceID: String,
        workspacePath: String,
        registry: ToolRegistry,
        relay: RuntimeEventRelay,
        runTurn: @escaping @Sendable (String) async throws -> Void
    ) {
        self.workspaceID = workspaceID
        self.workspacePath = workspacePath
        self.registry = registry
        self.relay = relay
        self.runTurn = runTurn
    }

    func setShutdownHandler(_ handler: @escaping @Sendable () -> Void) {
        shutdownHandler = handler
    }

    func handle(_ envelope: IPCEnvelope) async -> IPCEnvelope? {
        guard envelope.protocolVersion == SLTAIPCProtocolVersion else {
            return error(
                envelope, code: "version_mismatch",
                message: "runtime supports protocol \(SLTAIPCProtocolVersion)"
            )
        }
        if envelope.kind != .handshake, envelope.workspaceID != workspaceID {
            return error(envelope, code: "workspace_mismatch", message: "wrong workspace runtime")
        }

        switch (envelope.kind, envelope.payload) {
        case (.handshake, .handshake(let value)):
            guard value.supportedVersion == SLTAIPCProtocolVersion else {
                return error(
                    envelope, code: "version_mismatch",
                    message: "runtime supports protocol \(SLTAIPCProtocolVersion)"
                )
            }
            return response(envelope, message: "handshake accepted")

        case (.openWorkspace, .openWorkspace(let value)):
            let incoming = WorkspaceIdentity.canonicalPath(URL(fileURLWithPath: value.canonicalPath))
            guard incoming == workspacePath else {
                return error(envelope, code: "workspace_mismatch", message: "canonical path differs")
            }
            return response(envelope, message: "workspace open", snapshot: await snapshot())

        case (.getSnapshot, .getSnapshot):
            return response(envelope, message: "snapshot", snapshot: await snapshot())

        case (.ping, .ping):
            return IPCEnvelope(
                requestID: envelope.requestID, workspaceID: workspaceID,
                kind: .pong, payload: .pong
            )

        case (.submitTurn, .submitTurn(let value)):
            guard activeTask == nil else {
                return error(envelope, code: "runtime_busy", message: "workspace task already running")
            }
            let id = envelope.requestID.uuidString
            activeTaskID = id
            recentTaskSummary = String(value.text.prefix(240))
            outcome = "running"
            relay.correlate(requestID: envelope.requestID, taskID: id)
            let waiter = RuntimeSubmitWaiter()
            let task = Task { [weak self] in
                let result: String
                do {
                    try await self?.runTurn(value.text)
                    result = "completed"
                } catch is CancellationError {
                    result = "cancelled"
                } catch {
                    result = "failed: \(error.localizedDescription)"
                }
                await self?.executionFinished(id: id, result: result)
            }
            activeTask = task
            activeWaiter = waiter
            let result = await waiter.wait()
            return response(envelope, message: result, snapshot: await snapshot())

        case (.cancelTask, .cancelTask(let value)):
            guard value.taskID == activeTaskID, let task = activeTask else {
                return response(envelope, accepted: true, message: "task is no longer active")
            }
            cancelled.insert(value.taskID)
            outcome = "cancelled"
            task.cancel()
            activeWaiter?.finish("cancelled")
            return response(envelope, accepted: true, message: "cancellation recorded")

        case (.shutdown, .shutdown):
            activeTask?.cancel()
            outcome = "shutdown"
            let reply = response(envelope, message: "shutting down")
            let callback = shutdownHandler
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { callback?() }
            return reply

        default:
            return error(envelope, code: "invalid_message", message: "kind/payload mismatch")
        }
    }

    private func executionFinished(id: String, result: String) async {
        let final: String
        if cancelled.contains(id) {
            final = "cancelled"
        } else if result == "completed" {
            let state = await registry.taskSnapshot()
            final = state.isComplete ? "completed" : "incomplete"
        } else {
            final = result
        }
        outcome = final
        activeWaiter?.finish(final)
        if activeTaskID == id {
            activeTask = nil
            activeWaiter = nil
            activeTaskID = nil
            relay.correlate(requestID: nil, taskID: nil)
        }
    }

    func snapshot() async -> RuntimeSnapshot {
        let state = await registry.taskSnapshot()
        return RuntimeSnapshot(
            workspaceID: workspaceID,
            canonicalWorkspacePath: workspacePath,
            runtimeStatus: activeTask == nil ? "ready" : "busy",
            activeTaskID: activeTaskID,
            recentTaskSummary: recentTaskSummary,
            taskPhase: state.spec == nil ? nil : state.phase.rawValue,
            taskOutcome: outcome,
            artifactRevisions: state.artifactRevisions.map {
                ArtifactRevisionSummary(path: $0.key, revision: $0.value.description)
            }.sorted { $0.path < $1.path },
            unresolvedRequirements: state.missingRequirements.map(\.description),
            lastFailure: state.validation.lastFailure,
            telemetry: relay.telemetrySnapshot()
        )
    }

    private func response(
        _ request: IPCEnvelope,
        accepted: Bool = true,
        message: String,
        snapshot: RuntimeSnapshot? = nil
    ) -> IPCEnvelope {
        IPCEnvelope(
            requestID: request.requestID, workspaceID: workspaceID,
            kind: .response,
            payload: .response(.init(accepted: accepted, message: message, snapshot: snapshot))
        )
    }

    private func error(_ request: IPCEnvelope, code: String, message: String) -> IPCEnvelope {
        IPCEnvelope(
            requestID: request.requestID, workspaceID: workspaceID,
            kind: .error, payload: .error(.init(code: code, message: message))
        )
    }
}

final class RuntimeServiceHost: @unchecked Sendable {
    let server: UnixSocketServer
    private let controller: RuntimeServiceController
    let stopSemaphore = DispatchSemaphore(value: 0)
    private let ownership: WorkspaceRuntimeLock

    private init(
        server: UnixSocketServer,
        controller: RuntimeServiceController,
        ownership: WorkspaceRuntimeLock
    ) {
        self.server = server
        self.controller = controller
        self.ownership = ownership
    }

    static func make(options: AgentOptions, fakeModel: Bool = false) async throws -> RuntimeServiceHost {
        let canonical = WorkspaceIdentity.canonicalPath(options.projectURL)
        let workspaceURL = URL(fileURLWithPath: canonical)
        // Acquire ownership before model/LSP initialization so concurrent UIs
        // cannot start two authoritative compute environments.
        let ownership = try WorkspaceRuntimeLock(workspaceURL: workspaceURL)
        let workspaceID = WorkspaceIdentity.stableID(forCanonicalPath: canonical)
        let relay = RuntimeEventRelay(workspaceID: workspaceID)
        let events = EventBus(sink: relay)
        let policy = PolicyEngine(mode: options.approvalMode, allowMCP: options.allowMCP)
        let runtime = RuntimeEnvironment.probe(projectURL: workspaceURL)
        let workspace = Workspace(
            root: workspaceURL, shellTimeoutSeconds: options.shellTimeoutSeconds,
            policy: policy, runtime: runtime
        )
        let mcp = MCPBridge(policy: policy)
        var providers: [any CodeIntelligenceProvider] = []
        if fakeModel {
            if let fake = configureFakeCodeIntelligence(workspaceURL: workspaceURL) {
                providers.append(fake)
            }
        } else if let lsp = LSPCodeIntelligenceProvider(projectRoot: workspaceURL) {
            providers.append(lsp)
        }
        let codeIntel = CodeIntelligenceEngine(
            workspace: workspace, providers: providers, events: events
        )
        let router = ComputationRouter(events: events)
        let registry = ToolRegistry(
            workspace: workspace, mcp: mcp, events: events, runtime: runtime,
            codeIntelligence: codeIntel, computationRouter: router
        )
        _ = await registry.restoreRuntime()
        let context = ContextEngine(workspace: workspace, codeIntel: codeIntel, events: events)
        let coordinator = RuntimeCoordinator(
            executor: registry, events: events,
            projectInstructions: ProjectInstructions.load(root: workspaceURL),
            contextEngine: context, computationRouter: router
        )

        let runTurn: @Sendable (String) async throws -> Void
        if fakeModel {
            let model = FakeModelProvider()
            model.script(Array(repeating: .doneProse, count: 32))
            runTurn = { text in
                try Task.checkCancellation()
                if text == "__ipc_test_block__" {
                    try await Task.sleep(for: .seconds(30))
                    return
                }
                let decision = FastTurnRouter.decide(text) ?? .forMode(.agent, source: .fast)
                await registry.beginTask(text, decision: decision)
                let result = try await coordinator.run(
                    RuntimeTaskInput(
                        userText: text, decision: decision, maxRounds: options.maxRounds,
                        sessionExcerpt: "", projectInstructions: "",
                        runtimeContext: registry.runtimeContext,
                        allowedTools: registry.allowedToolNames(for: decision.capabilities),
                        agentMaxTokens: options.agentMaxTokens
                    ),
                    provider: model
                )
                try Task.checkCancellation()
                if !result.displayText.isEmpty { await events.emit(.assistant(result.displayText)) }
            }
        } else {
            await events.emit(.modelLoading)
            let model = try await MLXProvider(
                modelID: options.modelID, draftModelID: options.draftModelID,
                events: events, chatMaxTokens: options.chatMaxTokens,
                agentMaxTokens: options.agentMaxTokens,
                timeoutSeconds: options.generationTimeoutSeconds,
                controllerTimeoutSeconds: options.controllerTimeoutSeconds
            )
            let agent = AgentLoop(
                mlx: model, coordinator: coordinator, registry: registry,
                events: events, maxRounds: options.maxRounds,
                chatMaxTokens: options.chatMaxTokens,
                agentMaxTokens: options.agentMaxTokens
            )
            runTurn = { text in
                try Task.checkCancellation()
                try await agent.run(text)
                try Task.checkCancellation()
            }
        }

        let controller = RuntimeServiceController(
            workspaceID: workspaceID, workspacePath: canonical,
            registry: registry, relay: relay, runTurn: runTurn
        )
        let server = UnixSocketServer(socketURL: WorkspaceIdentity.socketURL(for: workspaceURL)) {
            envelope, _ in await controller.handle(envelope)
        }
        let host = RuntimeServiceHost(
            server: server, controller: controller, ownership: ownership
        )
        relay.attach(server)
        await controller.setShutdownHandler { [weak host] in
            host?.server.stop()
            host?.stopSemaphore.signal()
        }
        return host
    }

    static func configureFakeCodeIntelligence(
        workspaceURL: URL
    ) -> FakeCodeIntelligenceProvider? {
        let canonicalRoot = WorkspaceIdentity.canonicalPath(workspaceURL)
        guard let enumerator = FileManager.default.enumerator(
            at: workspaceURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var contents: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let canonicalFile = WorkspaceIdentity.canonicalPath(url)
            guard canonicalFile.hasPrefix(canonicalRoot + "/") else { continue }
            let relative = String(canonicalFile.dropFirst(canonicalRoot.count + 1))
            contents[relative] = text
        }
        let fake = FakeCodeIntelligenceProvider()
        fake.define(contents: contents)

        var occurrences: [(path: String, line: Int, start: Int, end: Int)] = []
        for (path, content) in contents {
            for (lineIndex, line) in content.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                var search = line.startIndex
                while let range = line.range(of: "UserManager", range: search..<line.endIndex) {
                    let start = line[..<range.lowerBound].utf16.count
                    occurrences.append((path, lineIndex, start, start + "UserManager".utf16.count))
                    search = range.upperBound
                }
            }
        }
        guard let definition = occurrences.first(where: { item in
            guard let content = contents[item.path] else { return false }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            return item.line < lines.count && lines[item.line].contains("struct UserManager")
        }) else { return fake }
        fake.define(symbols: [FakeSymbolDef(
            name: "UserManager", kind: .struct, path: definition.path,
            line: definition.line, utf16Start: definition.start,
            utf16End: definition.end, container: nil
        )])
        fake.defineReferences(
            symbol: "UserManager",
            refs: occurrences.filter {
                !($0.path == definition.path && $0.line == definition.line && $0.start == definition.start)
            }.map {
                FakeRefDef(
                    path: $0.path, line: $0.line,
                    utf16Start: $0.start, utf16End: $0.end
                )
            }
        )
        fake.defineRename(
            symbol: "UserManager", newName: "AccountManager",
            edits: occurrences.map {
                FakeEditDef(
                    path: $0.path, startLine: $0.line, startChar: $0.start,
                    endLine: $0.line, endChar: $0.end,
                    newText: "AccountManager"
                )
            }
        )
        return fake
    }

    func run() throws {
        try server.start()
        stopSemaphore.wait()
    }
}

enum RuntimeProcess {
    static func ensureRunning(options: AgentOptions) async throws {
        let probe = RuntimeClient(workspaceURL: options.projectURL)
        if (try? await probe.connect(clientName: "probe")) != nil {
            probe.close()
            return
        }
        let ownURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let launcher = ownURL.deletingLastPathComponent().appendingPathComponent("slta-runtime")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw CLIError("slta-runtime executable not found beside mlxagent")
        }
        let process = Process()
        process.executableURL = launcher
        var arguments = [
            options.projectURL.path,
            "--model", options.modelID,
            "--max-rounds", "\(options.maxRounds)",
            "--shell-timeout", "\(options.shellTimeoutSeconds)",
            "--approval-mode", options.approvalMode.rawValue,
            "--controller-timeout", "\(options.controllerTimeoutSeconds)",
            "--generation-timeout", "\(options.generationTimeoutSeconds)"
        ]
        if let value = options.chatMaxTokens {
            arguments += ["--chat-max-tokens", "\(value)"]
        }
        if let value = options.agentMaxTokens {
            arguments += ["--agent-max-tokens", "\(value)"]
        }
        if let value = options.draftModelID {
            arguments += ["--draft-model", value]
        }
        if !options.allowMCP { arguments.append("--no-mcp") }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        // The first launch may include local model loading before the socket
        // becomes ready. Waiting is asynchronous and never freezes the GUI.
        for _ in 0..<6000 {
            try await Task.sleep(for: .milliseconds(100))
            let client = RuntimeClient(workspaceURL: options.projectURL)
            if (try? await client.connect(clientName: "startup-probe")) != nil {
                client.close()
                return
            }
            // The launcher may lose the ownership race to another runtime;
            // keep probing the authoritative socket in that case.
        }
        throw CLIError("slta-runtime did not become ready")
    }
}

enum IPCEventAdapter {
    static func agentEvent(_ event: RuntimeEvent) -> AgentEvent? {
        switch event.payload {
        case .modelLoading: return .modelLoading
        case .modelReady: return .modelReady
        case .taskStarted(let text): return .taskStarted(text)
        case .taskState(let taskID, let phase): return .taskStateChanged(taskID: taskID, phase: phase)
        case .generationStarted(let label): return .generationStarted(label)
        case .generationProgress(let label, let seconds, let chunks):
            return .generationProgress(label: label, seconds: seconds, chunks: chunks)
        case .generationFinished: return .generationFinished
        case .toolStarted(let name): return .toolStarted(name: name)
        case .toolFinished(let name, let ok, let detail, let seconds):
            return .toolFinished(name: name, ok: ok, detail: detail, duration: .seconds(seconds))
        case .assistant(let text): return .assistant(text)
        case .notice(let text): return .notice(text)
        case .warning(let text): return .warning(text)
        case .completed(_, let outputTokens):
            var stats = GenerationStats()
            stats.outputTokens = outputTokens
            stats.finish()
            return .completed(stats)
        case .telemetry(let name, let detail): return .notice("\(name): \(detail)")
        }
    }
}

func runRuntimeServiceMode() {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let options = try AgentOptions.parse(CommandLine.arguments)
            let fake = CommandLine.arguments.contains("--fake-runtime")
            let host = try await RuntimeServiceHost.make(options: options, fakeModel: fake)
            try host.run()
        } catch {
            fputs("slta-runtime: \(error)\n", stderr)
        }
        semaphore.signal()
    }
    semaphore.wait()
}

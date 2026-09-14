import Foundation
import StacyAgentCore
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - v0.28 MLXProvider (Qwen/MLX-specific)
//
// Owns: ModelContainer, generation parameters, speculative decoding,
// runtime ModelRequest -> MLX request mapping, MLX response -> ModelResponse
// mapping, Qwen textual fallback parsing, MLX telemetry.
//
// MUST NOT own: ToolRegistry, ProtocolEngine, Workspace, SessionContext,
// task completion, fingerprints, passLoop, deterministic preflight,
// recovery policy. All of that lives in RuntimeCoordinator.
//
// Single-generation boundary (proven against local mlx-swift-lm):
// ChatSession runs its hidden `restart:` tool loop ONLY when `toolDispatch`
// is non-nil (ChatSession.swift: pendingToolCalls collected only
// `if ... toolDispatch != nil`; dispatch + `continue restart` only
// `if let toolDispatch, !pendingToolCalls.isEmpty`). With toolDispatch == nil
// native calls surface as Generation.toolCall items through streamDetails and
// NO automatic redispatch happens — exactly one physical generation per
// streamDetails call, fully visible to the runtime.

public final class MLXProvider: ModelProvider, @unchecked Sendable {
     let providerID = ModelProviderID("mlx-local")
     let modelID: String
     let capabilities = ModelCapabilities(
         supportsNativeToolCalls: true,
         maxContextTokens: nil,
         supportsVision: false
     )
 
     private let model: ModelContainer
     private let speculative: SpeculativeDecodingConfig?
     private let events: EventBus
     private let timeoutSeconds: Int
     private let chatMaxTokens: Int?
     private let agentMaxTokens: Int?
     private let controllerTimeoutSeconds: Int
     private var debug = false
 
     private let sessionLock = NSLock()
     private var taskSession: ChatSession?
     private let outbox = GenerationOutbox()
 
     init(
         modelID: String,
         draftModelID: String? = nil,
         events: EventBus,
         chatMaxTokens: Int? = nil,
         agentMaxTokens: Int? = nil,
         timeoutSeconds: Int = 0,
         controllerTimeoutSeconds: Int = 4
     ) async throws {
         self.modelID = modelID
         self.events = events
         self.timeoutSeconds = timeoutSeconds
         self.chatMaxTokens = chatMaxTokens
         self.agentMaxTokens = agentMaxTokens
         self.controllerTimeoutSeconds = controllerTimeoutSeconds
 
         let startTime = ContinuousClock.now
         await events.emit(.modelLoading)
         fputs("[MLXProvider] init start, modelID=\(modelID)\n", stderr)
 
         let configuration = try Self.resolveConfiguration(modelID: modelID)
         fputs("[MLXProvider] resolved model path: \(Self.describeConfiguration(configuration))\n", stderr)
 
         fputs("[MLXProvider] BEFORE huggingFaceLoadModelContainer\n", stderr)
         let beforeLoad = ContinuousClock.now
         let main = try await #huggingFaceLoadModelContainer(configuration: configuration)
         let loadDuration = beforeLoad.duration(to: ContinuousClock.now)
         fputs("[MLXProvider] AFTER huggingFaceLoadModelContainer (\(Self.durationString(loadDuration)))\n", stderr)
         self.model = main
 
         if let draftModelID {
             await events.emit(.notice("loading draft model for speculative decoding"))
             let draftConfig = ModelConfiguration(id: draftModelID)
             let draft = try await #huggingFaceLoadModelContainer(configuration: draftConfig)
             self.speculative = SpeculativeDecodingConfig(draftModel: draft, numDraftTokens: 5)
         } else {
             self.speculative = nil
         }
 
         let totalMs = UInt64(max(0, Self.seconds(startTime.duration(to: ContinuousClock.now)) * 1000))
         fputs("[MLXProvider] init complete, total \(totalMs)ms\n", stderr)
         await events.emit(.modelReady)
     }

    func toggleDebug() -> Bool {
        debug.toggle()
        return debug
    }

    // MARK: Task session (KV-cache reuse within one task)

    func beginTaskSession(instructions: String) {
        let session = ChatSession(
            model,
            instructions: instructions,
            speculativeDecoding: speculative,
            generateParameters: Self.parameters(maxTokens: agentMaxTokens)
        )
        sessionLock.lock()
        taskSession = session
        sessionLock.unlock()
    }

    func endTaskSession() {
        sessionLock.lock()
        taskSession = nil
        sessionLock.unlock()
    }

    // MARK: Single physical generation

    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        let started = Date()
        let clockStart = ContinuousClock.now
        let maxTokens: Int?
        switch request.purpose {
        case .chat, .route:
            maxTokens = request.maxTokens ?? chatMaxTokens
        case .intelligence, .synthesis:
            maxTokens = request.maxTokens ?? agentMaxTokens
        }

        let session: ChatSession = {
            sessionLock.lock()
            defer { sessionLock.unlock() }
            if let active = taskSession {
                active.setTools(Self.mlxSpecs(request.tools))
                return active
            }
            return ChatSession(
                model,
                instructions: request.instructions,
                speculativeDecoding: speculative,
                generateParameters: Self.parameters(maxTokens: maxTokens),
                tools: Self.mlxSpecs(request.tools),
                toolDispatch: nil // critical: no hidden tool lifecycle
            )
        }()

        await events.emit(.generationProgress(label: "thinking", seconds: 0, chunks: 0))
        var stats = GenerationStats()
        let raw = try await streamSingle(session: session, prompt: request.prompt, stats: &stats)
        await events.emit(.generationFinished)

        // 1. Native function calls surfaced as Generation.toolCall items.
        let native = streamNativeCalls(of: session, rawText: raw.text)
        let nativeInvocations = native.map {
            NormalizedToolInvocation(
                name: $0.function.name,
                arguments: Self.stringifyArguments($0.function.arguments),
                source: .provider
            )
        }
        if !nativeInvocations.isEmpty {
            let text = Qwen3CoderProtocol.removingToolMarkup(from: raw.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ModelResponse(
                requestID: request.id,
                text: text,
                toolCalls: nativeInvocations,
                format: .native,
                telemetry: Self.telemetry(
                    providerID: providerID,
                    modelID: modelID,
                    request: request,
                    started: started,
                    clockStart: clockStart,
                    pass: raw.telemetry,
                    stats: stats
                )
            )
        }

        // 2. Qwen textual fallback stays INSIDE this adapter layer and is
        // converted to NormalizedToolInvocation before crossing the boundary.
        switch Qwen3CoderProtocol.analyze(raw.text) {
        case .complete(let invocations):
            let normalized = invocations.map {
                NormalizedToolInvocation(name: $0.name, arguments: $0.arguments, source: .provider)
            }
            let text = Qwen3CoderProtocol.removingToolMarkup(from: raw.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ModelResponse(
                requestID: request.id,
                text: text,
                toolCalls: normalized,
                format: .textFallback,
                telemetry: Self.telemetry(
                    providerID: providerID,
                    modelID: modelID,
                    request: request,
                    started: started,
                    clockStart: clockStart,
                    pass: raw.telemetry,
                    stats: stats
                )
            )
        case .incomplete:
            // Returned as-is with .textFallback so the RUNTIME can issue one
            // targeted retry. The provider never retries internally.
            return ModelResponse(
                requestID: request.id,
                text: raw.text,
                toolCalls: [],
                format: .textFallback,
                telemetry: Self.telemetry(
                    providerID: providerID,
                    modelID: modelID,
                    request: request,
                    started: started,
                    clockStart: clockStart,
                    pass: raw.telemetry,
                    stats: stats
                )
            )
        case .none:
            return ModelResponse(
                requestID: request.id,
                text: raw.text,
                toolCalls: [],
                format: .none,
                telemetry: Self.telemetry(
                    providerID: providerID,
                    modelID: modelID,
                    request: request,
                    started: started,
                    clockStart: clockStart,
                    pass: raw.telemetry,
                    stats: stats
                )
            )
        }
    }

    // MARK: Routing classification (tiny single generation, no tools)

    /// Runs the controller prompt and returns the RAW classification text.
    /// Mode parsing is runtime-owned (TurnModeParser); this is pure inference.
    func classify(_ text: String, sessionContext: String = "") async throws -> String {
        let routedPrompt: String
        if sessionContext.isEmpty {
            routedPrompt = text
        } else {
            routedPrompt = """
            \(sessionContext)

            CURRENT USER MESSAGE:
            \(text)

            Classify the CURRENT USER MESSAGE, resolving short follow-ups against the session context.
            """
        }
        let session = ChatSession(
            model,
            instructions: SystemPrompt.controller,
            generateParameters: GenerateParameters(
                maxTokens: 8,
                temperature: 0.0,
                topP: 1.0,
                repetitionPenalty: 1.04,
                repetitionContextSize: 24
            ),
            tools: [],
            toolDispatch: nil
        )
        let timeout = controllerTimeoutSeconds
        let responseStream = session.streamResponse(to: routedPrompt)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var output = ""
                for try await chunk in responseStream {
                    output += chunk
                }
                return output
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw StacyAgentError.io("turn controller timed out after \(timeout)s")
            }
            guard let value = try await group.next() else {
                throw StacyAgentError.io("turn controller returned no decision")
            }
            group.cancelAll()
            return value
        }
    }

     // MARK: - Local cache resolution
 
     private static func resolveConfiguration(modelID: String) throws -> ModelConfiguration {
         if let localPath = try Self.localCachePath(for: modelID) {
             fputs("[MLXProvider] using local cache: \(localPath)\n", stderr)
             return ModelConfiguration(directory: localPath)
         }
         return ModelConfiguration(id: modelID)
     }
 
     private static func localCachePath(for modelID: String) throws -> URL? {
         let parts = modelID.split(separator: "/")
         guard parts.count == 2 else { return nil }
         let cacheBase = try Self.huggingFaceCacheDirectory()
         let hfDir = cacheBase
             .appendingPathComponent("models--\(parts[0])--\(parts[1])")
         let refsFile = hfDir.appendingPathComponent("refs/main")
         guard FileManager.default.fileExists(atPath: refsFile.path),
               let commit = try? String(contentsOf: refsFile, encoding: .utf8)
                 .trimmingCharacters(in: .whitespacesAndNewlines),
               !commit.isEmpty else { return nil }
         let snapshotDir = hfDir.appendingPathComponent("snapshots")
             .appendingPathComponent(commit)
         guard FileManager.default.fileExists(atPath: snapshotDir.path) else { return nil }
         return snapshotDir
     }
 
     static func huggingFaceCacheDirectory() throws -> URL {
         if let env = ProcessInfo.processInfo.environment["HF_HUB_CACHE"] {
             return URL(fileURLWithPath: env)
         }
         if let env = ProcessInfo.processInfo.environment["HF_HOME"] {
             return URL(fileURLWithPath: env).appendingPathComponent("hub")
         }
         let home = FileManager.default.homeDirectoryForCurrentUser
         let candidate = home.appendingPathComponent(".cache/huggingface/hub")
         if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
         let sandbox = home.appendingPathComponent(
             "Library/Caches/huggingface/hub"
         )
         if FileManager.default.fileExists(atPath: sandbox.path) { return sandbox }
         throw StacyAgentError.io("cannot locate HuggingFace cache directory")
     }
 
     private static func describeConfiguration(_ config: ModelConfiguration) -> String {
         switch config.id {
         case .id(let id, let revision): return "id:\(id)@\(revision)"
         case .directory(let url): return "dir:\(url.path)"
         }
     }
 
     static func durationString(_ duration: Duration) -> String {
         let c = duration.components
         return String(format: "%.1fs", Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000)
     }

    /// Native calls observed on the LAST single generation. Because
    /// toolDispatch is nil, ChatSession does not consume them; they arrive
    /// as Generation.toolCall items. We re-derive them deterministically by
    /// replaying nothing — instead we capture them during streaming.
    ///
    /// Implementation note: streamSingle collects toolCall items alongside
    /// text, so this helper just forwards the captured calls.
    private func streamNativeCalls(of session: ChatSession, rawText: String) -> [ToolCall] {
        // Calls are captured in streamSingle via its outbox; the session is
        // single-flight per task so the latest outbox belongs to this call.
        outbox.take()
    }

    private struct SingleGeneration: Sendable {
        var text: String
        var telemetry: ModelPassTelemetry
    }

    private func streamSingle(
        session: ChatSession,
        prompt: String,
        stats: inout GenerationStats
    ) async throws -> SingleGeneration {
        stats.passes += 1
        let started = ContinuousClock.now
        let stallTimeout = timeoutSeconds
        let eventBus = events
        let debugEnabled = debug
        let heartbeat = stallTimeout > 0 ? GenerationHeartbeat() : nil
        // toolDispatch is nil -> exactly one generation, no hidden restart loop.
        let generationStream = session.streamDetails(to: prompt)

        struct Outcome: Sendable {
            let text: String
            let toolCalls: [ToolCall]
            let telemetry: ModelPassTelemetry
        }

        let outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var output = ""
                output.reserveCapacity(4_096)
                var calls: [ToolCall] = []
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
                                label: "thinking",
                                seconds: Self.seconds(now - started),
                                chunks: chunks
                            ))
                        }
                    case .toolCall(let call):
                        calls.append(call)
                    case .info(let info):
                        telemetry = TelemetryExtractor.capture(
                            info,
                            wallSeconds: Self.seconds(ContinuousClock.now - started),
                            firstTokenSeconds: first
                        )
                        if debugEnabled {
                            await eventBus.emit(.notice("MLX: " + info.summary()))
                        }
                    }
                }
                self.outbox.store(calls)
                return Outcome(
                    text: output,
                    toolCalls: calls,
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
                            throw StacyAgentError.io(String(
                                format: "generation stalled for %.1fs (optional watchdog %ds)",
                                idle,
                                stallTimeout
                            ))
                        }
                    }
                    throw CancellationError()
                }
            }

            guard let first = try await group.next() else {
                throw StacyAgentError.io("generation returned no result")
            }
            group.cancelAll()
            return first
        }
        stats.modelSeconds += outcome.telemetry.wallSeconds
        stats.promptTokens += outcome.telemetry.promptTokens ?? 0
        stats.outputTokens += outcome.telemetry.outputTokens ?? 0
        if stats.firstTokenSeconds == nil { stats.firstTokenSeconds = outcome.telemetry.firstTokenSeconds }
        if let x = outcome.telemetry.promptTokensPerSecond { stats.promptTokensPerSecond = x }
        if let x = outcome.telemetry.generationTokensPerSecond { stats.generationTokensPerSecond = x }
        if debug { await events.emit(.notice("model tail:\n" + String(outcome.text.suffix(900)))) }
        return SingleGeneration(text: outcome.text, telemetry: outcome.telemetry)
    }

    // MARK: Schema conversion (ProviderToolSpec <-> MLX ToolSpec)

    static func mlxSpecs(_ tools: [ProviderToolSpec]) -> [ToolSpec] {
        tools.map { spec in
            var parameters: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
            if let data = spec.parametersJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parameters = parsed
            }
            return [
                "type": "function",
                "function": [
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": sendable(parameters)
                ] as [String: any Sendable]
            ] as ToolSpec
        }
    }

    private static func sendable(_ value: Any) -> any Sendable {
        if let dict = value as? [String: Any] {
            return dict.mapValues { sendable($0) }
        }
        if let array = value as? [Any] {
            return array.map { sendable($0) }
        }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n }
        if let b = value as? Bool { return b }
        return String(describing: value)
    }

    static func stringifyArguments(_ args: [String: JSONValue]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(args.count)
        for (key, value) in args {
            switch value {
            case .string(let s):
                out[key] = s
            case .int(let n):
                out[key] = String(n)
            case .double(let d):
                if d.rounded() == d, d.isFinite {
                    out[key] = String(Int(d))
                } else {
                    out[key] = String(d)
                }
            case .bool(let b):
                out[key] = b ? "true" : "false"
            case .null:
                out[key] = ""
            case .array, .object:
                if let data = try? JSONEncoder().encode(value),
                   let s = String(data: data, encoding: .utf8) {
                    out[key] = s
                } else {
                    out[key] = String(describing: value)
                }
            }
        }
        return out
    }

    private static func telemetry(
        providerID: ModelProviderID,
        modelID: String,
        request: ModelRequest,
        started: Date,
        clockStart: ContinuousClock.Instant,
        pass: ModelPassTelemetry,
        stats: GenerationStats
    ) -> ProviderCallTelemetry {
        ProviderCallTelemetry(
            provider: providerID,
            model: modelID,
            requestID: request.id,
            purpose: request.purpose,
            startedAt: started,
            durationSeconds: pass.wallSeconds,
            promptTokens: pass.promptTokens,
            outputTokens: pass.outputTokens,
            cachedTokens: nil,
            firstTokenSeconds: pass.firstTokenSeconds,
            estimatedCost: nil
        )
    }

    static func parameters(maxTokens: Int?) -> GenerateParameters {
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

    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }
}

// MARK: - Single-generation native-call outbox
//
// ChatSession streams tool calls inline; with toolDispatch == nil nothing
// consumes them. streamSingle stores them here so generate() can forward
// them to the runtime. Single-flight per task session (the coordinator
// never overlaps generations). Instance-scoped (no global mutable state),
// guarded by lock.

final class GenerationOutbox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCall] = []

    func store(_ value: [ToolCall]) {
        lock.withLock { calls = value }
    }

    func take() -> [ToolCall] {
        lock.withLock {
            let out = calls
            calls = []
            return out
        }
    }
}

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

// ChatSession tools are mutable per step (the coordinator narrows them to
// the current intelligence request). Helper keeps the call site readable.
private extension ChatSession {
    func setTools(_ specs: [ToolSpec]) {
        self.tools = specs
    }
}

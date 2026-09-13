import Foundation
import SLTACore

// MARK: - v0.28 Runtime / ModelProvider boundary
//
// This file is the model-independent runtime core. It MUST NOT import
// MLXLMCommon, MLXLLM, MLXHuggingFace, HuggingFace or Tokenizers.
// It MUST NOT reference ToolRegistry, Workspace, SessionContext,
// RuntimeState or ProtocolEngine.
//
// A ModelProvider owns exactly one thing: a single intelligence inference.
// It receives one concrete ModelRequest and returns one structured
// ModelResponse plus per-call telemetry. It never decides NEXT/DONE/BLOCKED,
// never touches task completion, and never executes tools.

// MARK: - Identity & capabilities

/// Opaque provider identifier, e.g. "mlx-qwen3-coder", "fake-test".
struct ModelProviderID: Hashable, Sendable, CustomStringConvertible, Codable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

struct ModelCapabilities: Sendable {
    var supportsNativeToolCalls: Bool
    var maxContextTokens: Int?
    var supportsVision: Bool

    init(supportsNativeToolCalls: Bool, maxContextTokens: Int? = nil, supportsVision: Bool = false) {
        self.supportsNativeToolCalls = supportsNativeToolCalls
        self.maxContextTokens = maxContextTokens
        self.supportsVision = supportsVision
    }
}

// MARK: - Request

/// Why the runtime asks the model for intelligence. Mirrors the runtime-owned
/// IntelligenceKind without importing ProtocolEngine.
enum ModelRequestPurpose: Sendable {
    case chat
    case route
    case intelligence(IntelligenceKind)
    case synthesis
}

/// Model-independent tool schema: plain data, convertible to any
/// provider-native function-calling format (MLX ToolSpec, OpenAI tools, ...).
struct ProviderToolSpec: Sendable {
    var name: String
    var description: String
    /// JSON object string describing the parameters object (JSON Schema).
    var parametersJSON: String

    init(name: String, description: String, parametersJSON: String = #"{"type":"object","properties":{}}"#) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// One concrete intelligence request. Minimal by design: instructions + one
/// prompt + the exact tool schemas exposed for this step — never the whole
/// RuntimeState, never the ToolRegistry.
struct ModelRequest: Sendable {
    var id: UUID
    var purpose: ModelRequestPurpose
    var instructions: String
    var prompt: String
    var tools: [ProviderToolSpec]
    var maxTokens: Int?

    init(
        id: UUID = UUID(),
        purpose: ModelRequestPurpose,
        instructions: String,
        prompt: String,
        tools: [ProviderToolSpec] = [],
        maxTokens: Int? = nil
    ) {
        self.id = id
        self.purpose = purpose
        self.instructions = instructions
        self.prompt = prompt
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

// MARK: - Response

/// How the provider produced its tool calls (transparency for the runtime).
enum ProviderToolFormat: String, Sendable {
    /// No tool calls, prose only.
    case none
    /// Provider-native function calling (e.g. MLX ToolCall stream items).
    case native
    /// Provider-specific textual fallback (e.g. Qwen <tool_call> blocks).
    /// The runtime may retry an incomplete textual call exactly once with a
    /// targeted prompt; the provider itself never retries internally.
    case textFallback
}

/// Structured result of exactly ONE physical model generation.
/// Prose in `text` NEVER constitutes task evidence and NEVER means DONE —
/// only RuntimeState evidence observed by ProtocolEngine does.
struct ModelResponse: Sendable {
    var requestID: UUID
    /// Prose answer with provider tool markup removed.
    var text: String
    /// Normalized invocations ready for the runtime ToolExecutor.
    /// Always `.provider`-sourced; provider-specific formats must be
    /// converted before crossing this boundary.
    var toolCalls: [NormalizedToolInvocation]
    var format: ProviderToolFormat
    var telemetry: ProviderCallTelemetry

    init(
        requestID: UUID,
        text: String,
        toolCalls: [NormalizedToolInvocation] = [],
        format: ProviderToolFormat = .none,
        telemetry: ProviderCallTelemetry
    ) {
        self.requestID = requestID
        self.text = text
        self.toolCalls = toolCalls
        self.format = format
        self.telemetry = telemetry
    }
}

// MARK: - Per-call telemetry

/// One record per physical model call. `passes`/`rounds`/`toolCalls` are
/// tracked separately by the RuntimeCoordinator — never conflated here.
struct ProviderCallTelemetry: Sendable {
    var provider: ModelProviderID
    var model: String
    var requestID: UUID
    var purpose: ModelRequestPurpose
    var startedAt: Date
    var durationSeconds: Double
    var promptTokens: Int?
    var outputTokens: Int?
    var cachedTokens: Int?
    var firstTokenSeconds: Double?
    /// Nil for local MLX inference.
    var estimatedCost: Double?

    init(
        provider: ModelProviderID,
        model: String,
        requestID: UUID,
        purpose: ModelRequestPurpose,
        startedAt: Date = Date(),
        durationSeconds: Double = 0,
        promptTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedTokens: Int? = nil,
        firstTokenSeconds: Double? = nil,
        estimatedCost: Double? = nil
    ) {
        self.provider = provider
        self.model = model
        self.requestID = requestID
        self.purpose = purpose
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.firstTokenSeconds = firstTokenSeconds
        self.estimatedCost = estimatedCost
    }
}

// MARK: - Protocol

/// A single-inference intelligence provider.
///
/// Implementations MUST:
/// - perform exactly one physical generation per `generate` call;
/// - surface every native tool call as NormalizedToolInvocation;
/// - convert provider-specific textual formats before returning;
/// - attach one ProviderCallTelemetry per call.
///
/// Implementations MUST NOT:
/// - reference ToolRegistry / Workspace / SessionContext / RuntimeState;
/// - call ProtocolEngine or decide task completion;
/// - execute tools or run internal generation retry loops.
protocol ModelProvider: Sendable {
    var providerID: ModelProviderID { get }
    var modelID: String { get }
    var capabilities: ModelCapabilities { get }

    /// Exactly one physical generation. Throws on generation failure;
    /// the RuntimeCoordinator owns recovery policy.
    func generate(_ request: ModelRequest) async throws -> ModelResponse

    /// Optional per-task session bracket so providers can reuse KV cache
    /// within a task session (PERFORMANCE.md rule 5). Default: no-op.
    func beginTaskSession(instructions: String)
    func endTaskSession()
}

extension ModelProvider {
    func beginTaskSession(instructions: String) {}
    func endTaskSession() {}
}

// MARK: - Provider-agnostic output-shape check
//
// Detects a concrete implementation artifact in ordinary prose (fenced code
// or a full HTML document). This is output shape, not provider logic, so it
// lives in the runtime core. Qwen3CoderProtocol delegates to it; RouteSafety
// uses it directly — no Qwen-specific type crosses the boundary.

enum ProviderArtifactCheck {
    public static func containsImplementationArtifact(_ text: String) -> Bool {
        let fencedSource = #"(?s)```[^\n]*\n.+?```"#
        if let regex = try? NSRegularExpression(pattern: fencedSource),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }
        let lower = text.lowercased()
        return (lower.contains("<!doctype html") || lower.contains("<html")) &&
            lower.contains("</html>")
    }
}

import Foundation

public let StacyAgentIPCProtocolVersion = 1

public enum IPCMessageKind: String, Codable, Sendable {
    case handshake, openWorkspace, submitTurn, cancelTask, getSnapshot
    case response, event, error, ping, pong, shutdown
}

public struct IPCEnvelope: Codable, Sendable {
    public var protocolVersion: Int
    public var requestID: UUID
    public var workspaceID: String
    public var kind: IPCMessageKind
    public var payload: IPCPayload

    public init(
        protocolVersion: Int = StacyAgentIPCProtocolVersion,
        requestID: UUID = UUID(),
        workspaceID: String,
        kind: IPCMessageKind,
        payload: IPCPayload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.workspaceID = workspaceID
        self.kind = kind
        self.payload = payload
    }
}

public enum IPCPayload: Codable, Sendable {
    case handshake(HandshakePayload)
    case openWorkspace(OpenWorkspacePayload)
    case submitTurn(SubmitTurnPayload)
    case cancelTask(CancelTaskPayload)
    case getSnapshot
    case response(ResponsePayload)
    case event(RuntimeEvent)
    case error(IPCErrorPayload)
    case ping
    case pong
    case shutdown
}

public struct HandshakePayload: Codable, Sendable {
    public var clientName: String
    public var supportedVersion: Int

    public init(clientName: String, supportedVersion: Int = StacyAgentIPCProtocolVersion) {
        self.clientName = clientName
        self.supportedVersion = supportedVersion
    }
}

public struct OpenWorkspacePayload: Codable, Sendable {
    public var canonicalPath: String
    public init(canonicalPath: String) { self.canonicalPath = canonicalPath }
}

public struct SubmitTurnPayload: Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct CancelTaskPayload: Codable, Sendable {
    public var taskID: String
    public init(taskID: String) { self.taskID = taskID }
}

public struct ResponsePayload: Codable, Sendable {
    public var accepted: Bool
    public var message: String
    public var snapshot: RuntimeSnapshot?

    public init(accepted: Bool, message: String, snapshot: RuntimeSnapshot? = nil) {
        self.accepted = accepted
        self.message = message
        self.snapshot = snapshot
    }
}

public struct IPCErrorPayload: Codable, Error, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ArtifactRevisionSummary: Codable, Sendable, Equatable {
    public var path: String
    public var revision: String
    public init(path: String, revision: String) {
        self.path = path
        self.revision = revision
    }
}

public struct RuntimeTelemetrySnapshot: Codable, Sendable, Equatable {
    public var modelCalls: Int
    public var deterministicActions: Int
    public var toolResults: Int
    public var contextTokens: Int

    public init(
        modelCalls: Int = 0,
        deterministicActions: Int = 0,
        toolResults: Int = 0,
        contextTokens: Int = 0
    ) {
        self.modelCalls = modelCalls
        self.deterministicActions = deterministicActions
        self.toolResults = toolResults
        self.contextTokens = contextTokens
    }
}

public struct RuntimeSnapshot: Codable, Sendable, Equatable {
    public var workspaceID: String
    public var canonicalWorkspacePath: String
    public var runtimeStatus: String
    public var activeTaskID: String?
    public var recentTaskSummary: String?
    public var taskPhase: String?
    public var taskOutcome: String?
    public var artifactRevisions: [ArtifactRevisionSummary]
    public var unresolvedRequirements: [String]
    public var lastFailure: String?
    public var telemetry: RuntimeTelemetrySnapshot

    public init(
        workspaceID: String,
        canonicalWorkspacePath: String,
        runtimeStatus: String,
        activeTaskID: String? = nil,
        recentTaskSummary: String? = nil,
        taskPhase: String? = nil,
        taskOutcome: String? = nil,
        artifactRevisions: [ArtifactRevisionSummary] = [],
        unresolvedRequirements: [String] = [],
        lastFailure: String? = nil,
        telemetry: RuntimeTelemetrySnapshot = .init()
    ) {
        self.workspaceID = workspaceID
        self.canonicalWorkspacePath = canonicalWorkspacePath
        self.runtimeStatus = runtimeStatus
        self.activeTaskID = activeTaskID
        self.recentTaskSummary = recentTaskSummary
        self.taskPhase = taskPhase
        self.taskOutcome = taskOutcome
        self.artifactRevisions = artifactRevisions
        self.unresolvedRequirements = unresolvedRequirements
        self.lastFailure = lastFailure
        self.telemetry = telemetry
    }
}

public enum RuntimeEventPayload: Codable, Sendable {
    case modelLoading
    case modelReady
    case taskStarted(text: String)
    case taskState(taskID: String, phase: String)
    case generationStarted(label: String)
    case generationProgress(label: String, seconds: Double, chunks: Int)
    case generationFinished
    case toolStarted(name: String)
    case toolFinished(name: String, ok: Bool, detail: String, durationSeconds: Double)
    case assistant(text: String)
    case notice(text: String)
    case warning(text: String)
    case completed(elapsedSeconds: Double, outputTokens: Int)
    case telemetry(name: String, detail: String)
}

public struct RuntimeEvent: Codable, Sendable {
    public var sequence: UInt64
    public var requestID: UUID?
    public var taskID: String?
    public var payload: RuntimeEventPayload

    public init(
        sequence: UInt64,
        requestID: UUID?,
        taskID: String?,
        payload: RuntimeEventPayload
    ) {
        self.sequence = sequence
        self.requestID = requestID
        self.taskID = taskID
        self.payload = payload
    }
}

public enum IPCProtocolError: Error, CustomStringConvertible, Sendable {
    case invalidPayload(String)
    case versionMismatch(expected: Int, received: Int)
    case remote(IPCErrorPayload)
    case disconnected
    case timeout

    public var description: String {
        switch self {
        case .invalidPayload(let value): return "invalid IPC payload: \(value)"
        case .versionMismatch(let expected, let received):
            return "IPC protocol mismatch: expected \(expected), received \(received)"
        case .remote(let error): return "\(error.code): \(error.message)"
        case .disconnected: return "runtime disconnected"
        case .timeout: return "runtime request timed out"
        }
    }
}

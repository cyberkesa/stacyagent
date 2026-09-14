import Foundation

enum AgentEvent: Sendable {
    // --- compat (v0.27, UI-facing) ---
    case modelLoading
    case modelReady
    case taskStarted(String)
    case generationStarted(String)
    case generationProgress(label: String, seconds: Double, chunks: Int)
    case generationFinished
    case toolStarted(name: String)
    case toolFinished(name: String, ok: Bool, detail: String, duration: Duration)
    case notice(String)
    case warning(String)
    case assistant(String)
    case completed(GenerationStats)

    // --- v0.28 runtime-oriented events (future IPC stream for Code - OSS) ---
    // Structured IDs where possible: taskID, provider ID, artifact path.
    case taskCompiled(taskID: String)
    case taskStateChanged(taskID: String, phase: String)
    case protocolDecision(taskID: String, decision: String)
    case intelligenceStarted(taskID: String, kind: String)
    case intelligenceFinished(taskID: String, provider: String, durationSeconds: Double)
    case proposalCreated(taskID: String, path: String)
    case transactionApplied(taskID: String, path: String, transaction: String)
    case validationFinished(path: String, ok: Bool)
    case taskCompleted(taskID: String)
    case taskBlocked(taskID: String, reason: String)

    // --- v0.29 artifact/evidence/persistence stream (Code - OSS Workbench) ---
    case artifactRevisionCreated(taskID: String, path: String, revision: String)
    case artifactExternalChangeDetected(path: String, revision: String)
    case evidenceRecorded(taskID: String, kind: String, path: String?)
    case evidenceBecameStale(taskID: String, path: String)
    case runtimeStatePersisted(projectID: String)
    case runtimeStateRestored(projectID: String)

    // --- v0.30 code intelligence stream (GUI ignores; Workbench IPC later) ---
    case codeIntelligenceStarted(provider: String, operation: String)
    case codeIntelligenceFinished(provider: String, operation: String, durationMs: Double, cacheHit: Bool, resultCount: Int)
    case semanticFactRecorded(kind: String, path: String, revision: String)
    case semanticFactBecameStale(kind: String, path: String)
    case semanticEditPlanned(taskID: String, files: [String], edits: Int)
    case semanticEditApplied(taskID: String, files: [String])
    case semanticAmbiguityDetected(symbol: String, candidates: [String])
}

protocol AgentEventSink: Sendable {
    func emit(_ event: AgentEvent) async
}

actor EventBus {
    private let sink: any AgentEventSink

    init(sink: any AgentEventSink) {
        self.sink = sink
    }

    func emit(_ event: AgentEvent) async {
        await sink.emit(event)
    }
}

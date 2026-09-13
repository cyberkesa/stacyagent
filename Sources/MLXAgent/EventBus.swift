import Foundation

enum AgentEvent: Sendable {
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

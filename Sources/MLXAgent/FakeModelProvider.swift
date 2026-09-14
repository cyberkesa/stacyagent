import Foundation
import StacyAgentCore

// MARK: - v0.28 FakeModelProvider (deterministic tests, no MLX)
//
// Scriptable ModelProvider for coordinator tests A-G. Records every request;
// the handler decides the response. Prose "done" never completes anything by
// itself — only RuntimeState evidence does (asserted by scenario D).
//
// Locking lives in synchronous helpers only (Swift 6: NSLock is unavailable
// from async contexts).

final class FakeModelProvider: ModelProvider, @unchecked Sendable {
    let providerID = ModelProviderID("fake-test")
    let modelID = "fake-test-model"
    let capabilities = ModelCapabilities(supportsNativeToolCalls: true)

    typealias Handler = @Sendable (ModelRequest) -> ModelResponse

    private let lock = NSLock()
    private var storedRequests: [ModelRequest] = []
    private var storedHandler: Handler?

    var requests: [ModelRequest] {
        lock.withLock { storedRequests }
    }

    var callCount: Int { requests.count }

    /// Script a fixed response sequence (consumed in order).
    func script(_ responses: [ScriptedResponse]) {
        let box = ResponseQueue(responses: responses)
        lock.withLock {
            storedHandler = { request in box.next(for: request) }
        }
    }

    func onGenerate(_ handler: @escaping Handler) {
        lock.withLock { storedHandler = handler }
    }

    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        let handler = record(request)
        if let handler {
            return handler(request)
        }
        return ModelResponse(
            requestID: request.id,
            text: "",
            toolCalls: [],
            format: .none,
            telemetry: ProviderCallTelemetry(
                provider: providerID,
                model: modelID,
                requestID: request.id,
                purpose: request.purpose
            )
        )
    }

    // MARK: - Synchronous locking helpers

    private func record(_ request: ModelRequest) -> Handler? {
        lock.withLock {
            storedRequests.append(request)
            return storedHandler
        }
    }
}

/// Ordered scripted answers. Reference box so a @Sendable handler closure
/// can consume the queue without capturing a mutable variable.
private final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ScriptedResponse]

    init(responses: [ScriptedResponse]) {
        self.queue = responses
    }

    func next(for request: ModelRequest) -> ModelResponse {
        let item: ScriptedResponse? = lock.withLock {
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }
        guard let item else {
            return ModelResponse(
                requestID: request.id,
                text: "",
                toolCalls: [],
                format: .none,
                telemetry: ProviderCallTelemetry(
                    provider: ModelProviderID("fake-test"),
                    model: "fake-test-model",
                    requestID: request.id,
                    purpose: request.purpose
                )
            )
        }
        return item.response(for: request)
    }
}

/// One scripted provider answer.
struct ScriptedResponse: Sendable {
    var text: String
    var toolCalls: [NormalizedToolInvocation]
    var format: ProviderToolFormat

    init(
        text: String = "",
        toolCalls: [NormalizedToolInvocation] = [],
        format: ProviderToolFormat = .none
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.format = format
    }

    /// "done" prose with no evidence behind it.
    static var doneProse: ScriptedResponse {
        ScriptedResponse(text: "done, fixed everything", toolCalls: [], format: .none)
    }

    func response(for request: ModelRequest) -> ModelResponse {
        ModelResponse(
            requestID: request.id,
            text: text,
            toolCalls: toolCalls,
            format: format,
            telemetry: ProviderCallTelemetry(
                provider: ModelProviderID("fake-test"),
                model: "fake-test-model",
                requestID: request.id,
                purpose: request.purpose
            )
        )
    }
}

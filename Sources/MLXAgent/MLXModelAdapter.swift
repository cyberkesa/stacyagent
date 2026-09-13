import Foundation

// MARK: - v0.28 compatibility shim
//
// MLXModelAdapter was split (v0.28 Runtime / ModelProvider Boundary):
//
//   ModelContainer / inference / telemetry  -> MLXProvider (MLXProvider.swift)
//   ModelRequest / ModelResponse / protocol -> ModelProvider.swift (model-independent)
//   passLoop / preflight / completion      -> RuntimeCoordinator (RuntimeCoordinator.swift)
//   prompts / fingerprint / synthesis      -> RuntimeCoordinator (pure runtime builders)
//   routing inference                      -> MLXProvider.classify (+ TurnModeParser)
//
// The old god-object is intentionally gone: the runtime must not depend on
// it. This alias keeps the name resolvable for external tooling; it cannot
// be constructed with the old (registry/events/controller) initializer.

@available(*, deprecated, renamed: "MLXProvider")
typealias MLXModelAdapter = MLXProvider

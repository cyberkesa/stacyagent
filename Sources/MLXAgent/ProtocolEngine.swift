import Foundation

enum ProtocolAction: Sendable, CustomStringConvertible {
    case readFile(String)
    case validateFile(String)
    case openFile(String)

    var toolName: String {
        switch self {
        case .readFile:
            return "read_file"
        case .validateFile:
            return "validate_file"
        case .openFile:
            return "open_file"
        }
    }

    var path: String {
        switch self {
        case .readFile(let path),
             .validateFile(let path),
             .openFile(let path):
            return path
        }
    }

    var description: String {
        "\(toolName) \(path)"
    }

    var normalizedInvocation: NormalizedToolInvocation {
        NormalizedToolInvocation(
            name: toolName,
            arguments: ["path": path],
            source: .protocolEngine
        )
    }
}

enum IntelligenceKind: String, Sendable {
    case resolveTarget
    case generateContent
    case editArtifact
    case diagnoseAndEdit
    case externalAction
    case synthesize
}

struct IntelligenceRequest: Sendable, CustomStringConvertible {
    let kind: IntelligenceKind
    let target: String?
    let reason: String
    let allowedTools: Set<String>

    var description: String {
        let toolText = allowedTools.sorted().joined(separator: ",")
        return "\(kind.rawValue) target=\(target ?? "unresolved") tools=[\(toolText)] reason=\(reason)"
    }
}

enum ProtocolDecision: Sendable, CustomStringConvertible {
    case deterministic(ProtocolAction)
    case intelligence(IntelligenceRequest)
    case done
    case blocked(String)

    var description: String {
        switch self {
        case .deterministic(let action):
            return "deterministic: \(action)"
        case .intelligence(let request):
            return "intelligence: \(request)"
        case .done:
            return "done"
        case .blocked(let reason):
            return "blocked: \(reason)"
        }
    }
}

enum ProtocolEngine {
    static func decision(
        for snapshot: TaskRuntimeSnapshot,
        allowed: Set<String>
    ) -> ProtocolDecision {
        guard let spec = snapshot.spec else {
            return .blocked("no active task")
        }

        if snapshot.validation.lastToolFailed {
            return .blocked(
                snapshot.validation.lastFailure ?? "unresolved tool failure"
            )
        }

        if snapshot.isComplete {
            return .done
        }

        if let action = nextAction(for: snapshot) {
            guard allowed.contains(action.toolName) else {
                return .blocked("required tool is not granted: \(action.toolName)")
            }
            return .deterministic(action)
        }

        let tools = intelligenceToolNames(
            for: snapshot,
            allowed: allowed
        )

        if needsTargetResolution(snapshot) {
            return .intelligence(
                IntelligenceRequest(
                    kind: .resolveTarget,
                    target: nil,
                    reason: "task target is unresolved",
                    allowedTools: tools
                )
            )
        }

        if hasPendingExternalWork(snapshot) {
            let tools = SemanticToolCatalog.names(
                withRole: .external,
                allowed: allowed
            )
            return .intelligence(
                IntelligenceRequest(
                    kind: .externalAction,
                    target: nil,
                    reason: snapshot.incompleteReason,
                    allowedTools: tools
                )
            )
        }

        if hasPendingMutation(snapshot) {
            let kind: IntelligenceKind
            if spec.kinds.contains(.debug) {
                kind = .diagnoseAndEdit
            } else if spec.kinds.contains(.create) && snapshot.mutatedPaths.isEmpty {
                kind = .generateContent
            } else {
                kind = .editArtifact
            }

            return .intelligence(
                IntelligenceRequest(
                    kind: kind,
                    target: snapshot.resolvedTargetPath,
                    reason: snapshot.incompleteReason,
                    allowedTools: tools
                )
            )
        }

        return .blocked(snapshot.incompleteReason)
    }

    static func nextAction(
        for snapshot: TaskRuntimeSnapshot
    ) -> ProtocolAction? {
        guard snapshot.spec != nil,
              !snapshot.isComplete,
              !snapshot.validation.lastToolFailed else {
            return nil
        }

        // Observations that unlock intelligence come before mutation.
        for requirement in snapshot.missingRequirements {
            switch requirement {
            case .observeAfterMutation(.path(let path)):
                if hasMutation(
                    path: path,
                    evidence: snapshot.evidence
                ) {
                    return .readFile(path)
                }

            case .observe(.path(let path)):
                return .readFile(path)

            case .inspectBeforeLaunch(.path(let path)):
                if !hasFreshObservation(
                    path: path,
                    evidence: snapshot.evidence
                ) {
                    return .readFile(path)
                }

                // This requirement means inspect THEN launch. Once the fresh
                // observation exists, relaunch is mechanical. Functional repair
                // tasks carry mutation requirements separately.
                return .openFile(path)

            default:
                break
            }
        }

        if hasPendingMutation(snapshot) {
            return nil
        }

        for requirement in snapshot.missingRequirements {
            if case .readBack(.path(let path)) = requirement {
                return .readFile(path)
            }
        }

        // Validation is deterministic and precedes launch for the latest revision.
        for requirement in snapshot.missingRequirements {
            if case .validate(.path(let path)) = requirement {
                return .validateFile(path)
            }
        }

        for requirement in snapshot.missingRequirements {
            if case .launch(.path(let path)) = requirement {
                return .openFile(path)
            }
        }

        return nil
    }

    static func intelligenceToolNames(
        for snapshot: TaskRuntimeSnapshot,
        allowed: Set<String>
    ) -> Set<String> {
        guard let spec = snapshot.spec,
              !snapshot.isComplete,
              !snapshot.validation.lastToolFailed else {
            return []
        }

        if hasPendingExternalWork(snapshot) {
            return SemanticToolCatalog.names(
                withRole: .external,
                allowed: allowed
            )
        }

        let mutationPending = hasPendingMutation(snapshot)
        guard mutationPending else {
            return []
        }

        if needsTargetResolution(snapshot) {
            // Target resolution genuinely needs intelligence. Allow observation/search
            // plus mutation, but still exclude shell/launch/validation choices.
            let observation = SemanticToolCatalog.names(
                withRole: .observe,
                allowed: allowed
            )
            let mutation = SemanticToolCatalog.names(
                withRole: .mutate,
                allowed: allowed
            )
            return observation.union(mutation)
        }

        if spec.kinds.contains(.create) && snapshot.mutatedPaths.isEmpty {
            return allowed.intersection(["write_file"])
        }

        return SemanticToolCatalog.names(
            withRole: .mutate,
            allowed: allowed
        )
    }

    static func blockReason(
        forTool toolName: String,
        snapshot: TaskRuntimeSnapshot
    ) -> String? {
        guard !snapshot.isComplete,
              !snapshot.validation.lastToolFailed else {
            return nil
        }

        let role = SemanticToolCatalog.descriptor(toolName)?.role

        let observationPending = snapshot.missingRequirements.contains { requirement in
            switch requirement {
            case .observe:
                return true

            case .observeAfterMutation(.path(let path)):
                return hasMutation(
                    path: path,
                    evidence: snapshot.evidence
                )

            case .observeAfterMutation(.any):
                return hasAnyMutation(
                    evidence: snapshot.evidence
                )

            default:
                return false
            }
        }

        let mutationPending = hasPendingMutation(snapshot)

        let validationPending = snapshot.missingRequirements.contains { requirement in
            if case .validate = requirement {
                return true
            }
            return false
        }

        if role == .mutate && observationPending {
            return "runtime requires a fresh observation of the target before the next mutation"
        }

        if (role == .validate || role == .launch) && mutationPending {
            return "runtime requires the requested mutation stage to finish before validation or launch"
        }

        if role == .launch && validationPending {
            return "runtime requires validation of the latest artifact revision before launch"
        }

        return nil
    }

    static func shouldYieldAfterMutation(
        _ snapshot: TaskRuntimeSnapshot
    ) -> Bool {
        snapshot.missingRequirements.contains { requirement in
            if case .observeAfterMutation = requirement {
                return true
            }
            return false
        }
    }

    private static func hasPendingExternalWork(
        _ snapshot: TaskRuntimeSnapshot
    ) -> Bool {
        snapshot.missingRequirements.contains { requirement in
            switch requirement {
            case .externalEffect, .externalArtifact:
                return true
            default:
                return false
            }
        }
    }

    static func semanticRevision(
        path: String,
        evidence: [TaskEvidence]
    ) -> Int {
        evidence.reduce(into: 0) { revision, item in
            guard case .mutated(_, let evidencePath, let changed, _) = item,
                  changed,
                  evidencePath == path else {
                return
            }
            revision += 1
        }
    }

    private static func needsTargetResolution(
        _ snapshot: TaskRuntimeSnapshot
    ) -> Bool {
        guard snapshot.resolvedTargetPath == nil else {
            return false
        }

        return snapshot.missingRequirements.contains { requirement in
            switch requirement {
            case .observe(.any),
                 .observeAfterMutation(.any),
                 .mutate(.any),
                 .mutateCount(.any, _),
                 .launch(.any),
                 .inspectBeforeLaunch(.any),
                 .validate(.any),
                 .readBack(.any):
                return true
            default:
                return false
            }
        }
    }

    private static func hasPendingMutation(
        _ snapshot: TaskRuntimeSnapshot
    ) -> Bool {
        snapshot.missingRequirements.contains { requirement in
            switch requirement {
            case .mutate, .mutateCount:
                return true
            default:
                return false
            }
        }
    }

    private static func hasMutation(
        path: String,
        evidence: [TaskEvidence]
    ) -> Bool {
        evidence.contains { item in
            guard case .mutated(_, let evidencePath, let changed, _) = item else {
                return false
            }
            return changed && evidencePath == path
        }
    }

    private static func hasAnyMutation(
        evidence: [TaskEvidence]
    ) -> Bool {
        evidence.contains { item in
            if case .mutated(_, _, let changed, _) = item {
                return changed
            }
            return false
        }
    }

    private static func hasFreshObservation(
        path: String,
        evidence: [TaskEvidence]
    ) -> Bool {
        var lastMutation = -1

        for index in evidence.indices {
            if case .mutated(_, let evidencePath, let changed, _) = evidence[index],
               changed,
               evidencePath == path {
                lastMutation = index
            }
        }

        for index in evidence.indices where index > lastMutation {
            switch evidence[index] {
            case .observed(_, let evidencePath):
                if evidencePath == path {
                    return true
                }

            case .validated(_, let evidencePath):
                if evidencePath == path {
                    return true
                }

            case .readBack(let evidencePath, _):
                if evidencePath == path {
                    return true
                }

            default:
                break
            }
        }

        return false
    }
}

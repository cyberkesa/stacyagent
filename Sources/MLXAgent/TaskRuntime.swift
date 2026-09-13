import Foundation

enum TaskPhase: String, Sendable {
    case requested
    case inProgress
    case evidenceSatisfied
    case validationSatisfied
    case done
}

struct TaskRuntimeSnapshot: Sendable {
    let phase: TaskPhase
    let semanticState: TaskState
    let validation: ValidationState
    let spec: TaskSpec?
    let requirements: [TaskRequirement]
    let missingRequirements: [TaskRequirement]
    let evidence: [TaskEvidence]
    let mutatedPaths: [String]
    let readPaths: [String]
    let openedPaths: [String]
    let validatedPaths: [String]
    let resolvedTargetPath: String?

    var isComplete: Bool {
        spec != nil &&
        !validation.lastToolFailed &&
        missingRequirements.isEmpty
    }

    var requiresSynthesis: Bool {
        spec?.requiresSynthesis ?? false
    }

    var incompleteReason: String {
        if validation.lastToolFailed {
            return validation.lastFailure ?? "there is an unresolved tool failure"
        }

        if let first = missingRequirements.first {
            return "missing evidence: \(first.description)"
        }

        if spec == nil {
            return "task specification is not initialized"
        }

        return "task evidence is incomplete"
    }
}

actor RuntimeState {
    private(set) var validation = ValidationState()
    private(set) var toolCount = 0

    private var accumulatedToolSeconds: Double = 0
    private var spec: TaskSpec?
    private var state: TaskState = .requested
    private var evidenceStore = EvidenceStore()
    private var runtimeRequirements: [TaskRequirement] = []

    private var mutationPath: String?
    private var mutationContent: String?

    private var mutatedPaths: [String] = []
    private var readPaths: [String] = []
    private var openedPaths: [String] = []
    private var validatedPaths: [String] = []

    private var failedTool: String?
    private var failedMessage: String?
    private var failureCount = 0

    private var signatureCounts: [String: Int] = [:]

    func beginTask(_ spec: TaskSpec) {
        self.spec = spec
        state = .requested
        evidenceStore = EvidenceStore()
        runtimeRequirements = spec.requirements

        validation = ValidationState()
        toolCount = 0
        accumulatedToolSeconds = 0

        mutationPath = nil
        mutationContent = nil

        mutatedPaths.removeAll(keepingCapacity: true)
        readPaths.removeAll(keepingCapacity: true)
        openedPaths.removeAll(keepingCapacity: true)
        validatedPaths.removeAll(keepingCapacity: true)

        failedTool = nil
        failedMessage = nil
        failureCount = 0
        signatureCounts.removeAll(keepingCapacity: true)
    }

    func resetTask() {
        spec = nil
        state = .requested
        evidenceStore = EvidenceStore()
        runtimeRequirements.removeAll(keepingCapacity: true)

        validation = ValidationState()
        toolCount = 0
        accumulatedToolSeconds = 0

        mutationPath = nil
        mutationContent = nil

        mutatedPaths.removeAll(keepingCapacity: true)
        readPaths.removeAll(keepingCapacity: true)
        openedPaths.removeAll(keepingCapacity: true)
        validatedPaths.removeAll(keepingCapacity: true)

        failedTool = nil
        failedMessage = nil
        failureCount = 0
        signatureCounts.removeAll(keepingCapacity: true)
    }

    func toolStarted() {
        toolCount += 1
        if state == .requested {
            state = .inProgress
        }
    }

    func toolFinished(seconds: Double) {
        accumulatedToolSeconds += seconds
    }

    func mayExecute(signature: String, mutating: Bool) -> Bool {
        let count = signatureCounts[signature, default: 0]
        signatureCounts[signature] = count + 1

        if mutating && count >= 1 {
            return false
        }

        return count < 4
    }

    func observation(_ name: String, path: String? = nil) {
        resolveFailureIfSameTool(name)

        let effectivePath =
            path ??
            (
                name == "read_file"
                    ? singleSpecTargetPath()
                    : nil
            )

        evidenceStore.append(
            .observed(
                tool: name,
                path: effectivePath
            )
        )

        if let effectivePath {
            appendUnique(
                effectivePath,
                to: &readPaths
            )
            specializeTargetRequirements(path: effectivePath)
        }

        updateValidationCompatibility()
        updateState()
    }

    func mutation(
        _ name: String,
        path: String?,
        content: String?,
        changed: Bool,
        transaction: EditTransactionRef? = nil
    ) {
        resolveFailureIfSameTool(name)

        mutationPath = path
        mutationContent = content
        validation.lastMutation = name

        evidenceStore.append(
            .mutated(
                tool: name,
                path: path,
                changed: changed,
                transaction: transaction
            )
        )

        if let path {
            if changed {
                appendUnique(path, to: &mutatedPaths)
            }
            specializeTargetRequirements(path: path)
            specializeMutationRequirements(path: path)
        }

        updateValidationCompatibility()
        updateState()
    }

    func nativeMutation(
        _ name: String,
        result: String,
        changed: Bool,
        transaction: EditTransactionRef? = nil
    ) {
        let path = Self.pathFromMutationResult(result)
        mutation(
            name,
            path: path,
            content: nil,
            changed: changed,
            transaction: transaction
        )
    }

    func readBack(path: String, content: String) {
        resolveFailureIfSameTool("read_file")

        appendUnique(path, to: &readPaths)
        specializeTargetRequirements(path: path)
        evidenceStore.append(
            .observed(
                tool: "read_file",
                path: path
            )
        )

        let needsReadBackEvidence = runtimeRequirements.contains { requirement in
            guard case .readBack(let target) = requirement else {
                return false
            }
            return target.matches(path)
        }

        if needsReadBackEvidence {
            let matched: Bool
            if let expected = mutationContent,
               mutationPath == path {
                matched = expected == content
            } else {
                matched = true
            }

            evidenceStore.append(
                .readBack(
                    path: path,
                    matched: matched
                )
            )

            if matched {
                validation.lastValidation = "read_back"
            }
        }

        updateValidationCompatibility()
        updateState()
    }

    func validationSuccess(
        _ name: String,
        isRealValidation: Bool,
        path: String? = nil
    ) {
        resolveFailureIfSameTool(name)

        let effectivePath =
            path ??
            mutationPath ??
            singleSpecTargetPath()

        if let effectivePath {
            specializeTargetRequirements(path: effectivePath)
        }

        if isRealValidation {
            evidenceStore.append(
                .validated(
                    tool: name,
                    path: effectivePath
                )
            )

            if let effectivePath {
                appendUnique(effectivePath, to: &validatedPaths)
            }

            validation.lastValidation = name
        } else {
            evidenceStore.append(.observed(tool: name, path: effectivePath))
        }

        updateValidationCompatibility()
        updateState()
    }

    func launchSuccess(
        _ name: String,
        path: String? = nil
    ) {
        resolveFailureIfSameTool(name)

        if let path {
            specializeTargetRequirements(path: path)
        }

        evidenceStore.append(
            .launched(
                tool: name,
                path: path
            )
        )

        if let path {
            appendUnique(path, to: &openedPaths)
        }

        updateState()
    }

    func nativeLaunchSuccess(
        _ name: String,
        result: String
    ) {
        let freshPrefix = "opened fresh "
        let normalPrefix = "opened "

        let path: String?
        if result.hasPrefix(freshPrefix) {
            path = String(result.dropFirst(freshPrefix.count))
        } else if result.hasPrefix(normalPrefix) {
            path = String(result.dropFirst(normalPrefix.count))
        } else {
            path = nil
        }

        launchSuccess(name, path: path)
    }

    func ordinarySuccess(_ name: String) {
        observation(name)
    }

    func externalSuccess(
        _ name: String,
        server: String? = nil,
        operation: String? = nil,
        urls: [String] = []
    ) {
        resolveFailureIfSameTool(name)
        evidenceStore.append(
            .externalEffect(
                tool: name,
                server: server,
                operation: operation,
                urls: urls
            )
        )
        updateState()
    }

    func recoverableFailure(
        _ name: String,
        message: String
    ) {
        if failedTool == name {
            failureCount += 1
        } else {
            failedTool = name
            failureCount = 1
        }

        failedMessage = message

        // A stale/over-specific edit proposal is not a failed TASK. Keep the
        // semantic requirements open and let the model repair the invocation
        // against the same known artifact.
        validation.lastToolFailed = false
        validation.consecutiveToolFailures = failureCount
        validation.lastFailure = message
        validation.lastValidation = name

        if state == .requested {
            state = .inProgress
        } else if state == .failed {
            state = .inProgress
        }

        updateValidationCompatibility()
        updateState()
    }

    func failure(
        _ name: String,
        message: String
    ) {
        if failedTool == name {
            failureCount += 1
        } else {
            failedTool = name
            failureCount = 1
        }

        failedMessage = message

        validation.lastToolFailed = true
        validation.consecutiveToolFailures = failureCount
        validation.lastFailure = message
        validation.lastValidation = name

        evidenceStore.append(
            .toolFailed(
                tool: name,
                message: message
            )
        )

        state = .failed
    }

    func snapshot() -> ValidationState {
        validation
    }

    func taskSnapshot() -> TaskRuntimeSnapshot {
        updateValidationCompatibility()

        let missing = evidenceStore.missing(from: runtimeRequirements)
        let complete =
            spec != nil &&
            !validation.lastToolFailed &&
            missing.isEmpty

        if complete {
            state = .completed
        } else if validation.lastToolFailed {
            state = .failed
        } else if !evidenceStore.items.isEmpty {
            state = .inProgress
        }

        return TaskRuntimeSnapshot(
            phase: phase(for: state, missing: missing),
            semanticState: state,
            validation: validation,
            spec: spec,
            requirements: runtimeRequirements,
            missingRequirements: missing,
            evidence: evidenceStore.items,
            mutatedPaths: mutatedPaths,
            readPaths: readPaths,
            openedPaths: openedPaths,
            validatedPaths: validatedPaths,
            resolvedTargetPath: effectiveTargetPath()
        )
    }

    func tools() -> Int {
        toolCount
    }

    func toolSeconds() -> Double {
        accumulatedToolSeconds
    }

    private func effectiveTargetPath() -> String? {
        if let explicit = singleSpecTargetPath() {
            return explicit
        }

        // Prefer concrete mutation evidence, then the latest concrete observation
        // or side-effect path. The arrays are bounded and ordered by recency.
        return mutationPath ??
            mutatedPaths.last ??
            readPaths.last ??
            validatedPaths.last ??
            openedPaths.last
    }

    private func singleSpecTargetPath() -> String? {
        guard let targets = spec?.targets,
              targets.count == 1 else {
            return nil
        }

        return targets[0].path
    }

    /// Bind generic `any target` requirements to the first concrete artifact path
    /// discovered by runtime evidence. This turns target discovery into durable
    /// semantic state instead of forcing the model to resolve the same referent again.
    private func specializeTargetRequirements(path: String) {
        let exact = TargetSelector.path(path)

        for index in runtimeRequirements.indices {
            switch runtimeRequirements[index] {
            case .observe(.any):
                runtimeRequirements[index] = .observe(exact)
            case .observeAfterMutation(.any):
                runtimeRequirements[index] = .observeAfterMutation(exact)
            case .mutate(.any):
                runtimeRequirements[index] = .mutate(exact)
            case .mutateCount(.any, let count):
                runtimeRequirements[index] = .mutateCount(exact, count)
            case .launch(.any):
                runtimeRequirements[index] = .launch(exact)
            case .inspectBeforeLaunch(.any):
                runtimeRequirements[index] = .inspectBeforeLaunch(exact)
            case .validate(.any):
                runtimeRequirements[index] = .validate(exact)
            case .readBack(.any):
                runtimeRequirements[index] = .readBack(exact)
            default:
                break
            }
        }
    }

    private func specializeMutationRequirements(path: String) {
        let exact = TargetSelector.path(path)

        if spec?.explicitReadBack == true {
            appendRequirement(.readBack(exact))
        }

        let sourceNeedsValidation =
            ArtifactType.infer(path: path) == .source

        let userRequestedVerification =
            spec?.kinds.contains(.verify) == true

        let launchNeedsFreshValidation =
            spec?.requiresLaunch == true

        if Self.supportsDeterministicValidation(path: path) &&
           (sourceNeedsValidation ||
            userRequestedVerification ||
            launchNeedsFreshValidation) {
            appendRequirement(.validate(exact))
        }
    }

    private static func supportsDeterministicValidation(
        path: String
    ) -> Bool {
        SemanticToolCatalog.supportsDeterministicFileValidation(path: path)
    }

    private func appendRequirement(_ requirement: TaskRequirement) {
        if !runtimeRequirements.contains(requirement) {
            runtimeRequirements.append(requirement)
        }
    }

    private func replaceRequirement(
        _ generic: TaskRequirement,
        with exact: TaskRequirement
    ) {
        if let index = runtimeRequirements.firstIndex(of: generic) {
            runtimeRequirements[index] = exact
        }
    }

    private func resolveFailureIfSameTool(_ name: String) {
        guard failedTool == nil || failedTool == name else {
            return
        }

        failedTool = nil
        failedMessage = nil
        failureCount = 0

        validation.lastToolFailed = false
        validation.consecutiveToolFailures = 0
        validation.lastFailure = nil
    }

    private func updateValidationCompatibility() {
        let missing = evidenceStore.missing(from: runtimeRequirements)

        validation.needsValidation = missing.contains { requirement in
            switch requirement {
            case .validate, .readBack:
                return true
            default:
                return false
            }
        }
    }

    private func updateState() {
        let missing = evidenceStore.missing(from: runtimeRequirements)

        if spec != nil &&
           !validation.lastToolFailed &&
           missing.isEmpty {
            state = .completed
        } else if validation.lastToolFailed {
            state = .failed
        } else {
            state = .inProgress
        }
    }

    private func phase(
        for state: TaskState,
        missing: [TaskRequirement]
    ) -> TaskPhase {
        switch state {
        case .requested:
            return .requested
        case .completed:
            return .done
        case .failed, .blocked:
            return .inProgress
        case .inProgress:
            if missing.allSatisfy({
                switch $0 {
                case .validate, .readBack:
                    return true
                default:
                    return false
                }
            }) && !missing.isEmpty {
                return .evidenceSatisfied
            }
            return .inProgress
        }
    }

    private func appendUnique(
        _ value: String,
        to values: inout [String]
    ) {
        values.removeAll(where: { $0 == value })
        values.append(value)

        if values.count > 20 {
            values.removeFirst(values.count - 20)
        }
    }

    static func pathFromMutationResult(
        _ result: String
    ) -> String? {
        let prefixes = [
            "wrote ",
            "updated range ",
            "updated ",
            "rolled back ",
            "unchanged "
        ]

        guard let prefix = prefixes.first(
            where: { result.hasPrefix($0) }
        ) else {
            return nil
        }

        let remainder = result.dropFirst(prefix.count)

        if let separator = remainder.range(of: " ·") {
            return String(
                remainder[..<separator.lowerBound]
            )
        }

        return String(remainder)
    }
}

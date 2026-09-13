import Foundation

struct TaskID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        String(rawValue.uuidString.prefix(8)).lowercased()
    }
}

struct ArtifactID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        String(rawValue.uuidString.prefix(8)).lowercased()
    }
}

enum ArtifactType: String, Hashable, Sendable {
    case source
    case document
    case web
    case image
    case data
    case executable
    case directory
    case unknown

    static func infer(path: String) -> ArtifactType {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

        switch ext {
        case "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx",
             "rs", "go", "java", "kt", "kts", "c", "h", "cc", "cpp",
             "hpp", "cs", "rb", "php", "sh", "zsh", "bash", "sql":
            return .source
        case "html", "htm", "css", "scss", "vue", "svelte":
            return .web
        case "json", "yaml", "yml", "toml", "csv", "xml":
            return .data
        case "md", "txt", "pdf", "doc", "docx":
            return .document
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            return .image
        case "app", "exe":
            return .executable
        default:
            return .unknown
        }
    }
}

struct ArtifactRef: Hashable, Sendable, CustomStringConvertible {
    let id: ArtifactID
    let path: String
    let type: ArtifactType
    let originTask: TaskID?
    let revision: Int

    init(
        id: ArtifactID = ArtifactID(),
        path: String,
        type: ArtifactType? = nil,
        originTask: TaskID? = nil,
        revision: Int = 0
    ) {
        self.id = id
        self.path = path
        self.type = type ?? ArtifactType.infer(path: path)
        self.originTask = originTask
        self.revision = revision
    }

    var description: String {
        "\(path) [\(type.rawValue), r\(revision)]"
    }
}

enum TaskKind: String, Hashable, Sendable {
    case create
    case modify
    case inspect
    case explain
    case debug
    case run
    case verify
    case search
    case operate
    case externalAction
    case converse
}

enum DesiredState: String, Hashable, Sendable {
    case exists
    case observed
    case modified
    case explained
    case validated
    case launched
    case functional
    case externalEffect
}

enum TaskConstraint: Hashable, Sendable, CustomStringConvertible {
    case noDependencyInstall
    case simplestImplementation
    case explicitReadBack
    case preserveExisting
    case minimumLineCount(Int)
    case userSpecified(String)

    var description: String {
        switch self {
        case .noDependencyInstall:
            return "no dependency installation"
        case .simplestImplementation:
            return "prefer simplest implementation"
        case .explicitReadBack:
            return "read artifact back exactly"
        case .preserveExisting:
            return "preserve unrelated existing content"
        case .minimumLineCount(let count):
            return "artifact must contain at least \(count) lines"
        case .userSpecified(let value):
            return value
        }
    }
}

enum TargetSelector: Hashable, Sendable, CustomStringConvertible {
    case any
    case path(String)

    var path: String? {
        if case .path(let value) = self { return value }
        return nil
    }

    var description: String {
        switch self {
        case .any:
            return "any target"
        case .path(let path):
            return path
        }
    }

    func matches(_ path: String?) -> Bool {
        switch self {
        case .any:
            return true
        case .path(let expected):
            return path == expected
        }
    }
}

enum TaskRequirement: Hashable, Sendable, CustomStringConvertible {
    case observe(TargetSelector)
    case observeAfterMutation(TargetSelector)
    case mutate(TargetSelector)
    case mutateCount(TargetSelector, Int)
    case launch(TargetSelector)
    case inspectBeforeLaunch(TargetSelector)
    case validate(TargetSelector)
    case readBack(TargetSelector)
    case externalEffect
    case externalArtifact(ArtifactType)

    var description: String {
        switch self {
        case .observe(let target):
            return "observe \(target)"
        case .observeAfterMutation(let target):
            return "observe \(target) after first mutation"
        case .mutate(let target):
            return "mutate \(target)"
        case .mutateCount(let target, let count):
            return "mutate \(target) \(count)x"
        case .launch(let target):
            return "launch \(target)"
        case .inspectBeforeLaunch(let target):
            return "inspect \(target) before launch"
        case .validate(let target):
            return "validate \(target)"
        case .readBack(let target):
            return "read back \(target)"
        case .externalEffect:
            return "perform external effect"
        case .externalArtifact(let type):
            return "obtain external \(type.rawValue) URL"
        }
    }
}

enum TaskOutputPolicy: String, Sendable {
    case deterministicAck
    case synthesis
}

struct TaskSpec: Sendable, CustomStringConvertible {
    let id: TaskID
    let parentID: TaskID?
    let mode: TurnMode
    let kinds: Set<TaskKind>
    let originalRequest: String
    let targets: [ArtifactRef]
    let launchApplication: String?
    let desiredState: Set<DesiredState>
    let requirements: [TaskRequirement]
    let constraints: [TaskConstraint]
    let outputPolicy: TaskOutputPolicy
    let compileConfidence: Double
    let compilerNotes: [String]

    var requiresSynthesis: Bool {
        outputPolicy == .synthesis
    }

    var requiresMutation: Bool {
        requirements.contains {
            switch $0 {
            case .mutate, .mutateCount:
                return true
            default:
                return false
            }
        }
    }

    var requiresLaunch: Bool {
        requirements.contains {
            switch $0 {
            case .launch, .inspectBeforeLaunch:
                return true
            default:
                return false
            }
        }
    }

    var requiresObservation: Bool {
        requirements.contains {
            switch $0 {
            case .observe, .inspectBeforeLaunch:
                return true
            default:
                return false
            }
        }
    }

    var explicitReadBack: Bool {
        constraints.contains {
            if case .explicitReadBack = $0 { return true }
            return false
        }
    }

    var explicitValidation: Bool {
        kinds.contains(.verify)
    }

    var inspectionTarget: String? {
        for requirement in requirements {
            if case .inspectBeforeLaunch(let target) = requirement {
                return target.path
            }
        }
        return nil
    }

    var description: String {
        let kindText = kinds.map(\.rawValue).sorted().joined(separator: "+")
        let targetText = targets.map(\.path).joined(separator: ", ")
        let requirementText = requirements.map(\.description).joined(separator: "; ")
        return "task \(id) [\(kindText)] targets=[\(targetText)] requirements=[\(requirementText)] confidence=\(String(format: "%.2f", compileConfidence))"
    }
}

enum TaskState: String, Sendable {
    case requested
    case inProgress
    case blocked
    case completed
    case failed
}

enum TaskEvidence: Sendable, CustomStringConvertible {
    case observed(tool: String, path: String?)
    case mutated(tool: String, path: String?, changed: Bool, transaction: EditTransactionRef?)
    case validated(tool: String, path: String?)
    case readBack(path: String, matched: Bool)
    case launched(tool: String, path: String?)
    case externalEffect(tool: String, server: String?, operation: String?, urls: [String])
    case toolFailed(tool: String, message: String)
    case userReportedFailure(path: String?, message: String)

    var path: String? {
        switch self {
        case .observed(_, let path),
             .mutated(_, let path, _, _),
             .validated(_, let path),
             .launched(_, let path),
             .userReportedFailure(let path, _):
            return path
        case .readBack(let path, _):
            return path
        case .externalEffect, .toolFailed:
            return nil
        }
    }

    var description: String {
        switch self {
        case .observed(let tool, let path):
            return "observed via \(tool)\(path.map { " \($0)" } ?? "")"
        case .mutated(let tool, let path, let changed, let transaction):
            let receipt = transaction.map { " · \($0)" } ?? ""
            return "\(changed ? "mutated" : "confirmed") via \(tool)\(path.map { " \($0)" } ?? "")\(receipt)"
        case .validated(let tool, let path):
            return "validated via \(tool)\(path.map { " \($0)" } ?? "")"
        case .readBack(let path, let matched):
            return "read back \(path) matched=\(matched)"
        case .launched(let tool, let path):
            return "launched via \(tool)\(path.map { " \($0)" } ?? "")"
        case .externalEffect(let tool, let server, let operation, let urls):
            let route = [server, operation].compactMap { $0 }.joined(separator: ".")
            let suffix = urls.isEmpty ? "" : " urls=" + urls.joined(separator: ",")
            return "external effect via \(route.isEmpty ? tool : route)\(suffix)"
        case .toolFailed(let tool, let message):
            return "\(tool) failed: \(message)"
        case .userReportedFailure(let path, let message):
            return "user reported failure\(path.map { " for \($0)" } ?? ""): \(message)"
        }
    }
}

struct EvidenceStore: Sendable {
    private(set) var items: [TaskEvidence] = []

    mutating func append(_ evidence: TaskEvidence) {
        items.append(evidence)
    }

    func satisfies(_ requirement: TaskRequirement) -> Bool {
        switch requirement {
        case .observe(let target):
            return items.contains { evidence in
                switch evidence {
                case .observed(_, let path),
                     .validated(_, let path):
                    return target.matches(path)
                case .readBack(let path, _):
                    return target.matches(path)
                default:
                    return false
                }
            }

        case .observeAfterMutation(let target):
            guard let firstMutation = firstMutationIndex(target) else {
                return false
            }

            return items.indices.contains { index in
                guard index > firstMutation else { return false }

                switch items[index] {
                case .observed(_, let path),
                     .validated(_, let path):
                    return target.matches(path)
                case .readBack(let path, _):
                    return target.matches(path)
                default:
                    return false
                }
            }

        case .mutate(let target):
            return mutationAttemptCount(target) >= 1

        case .mutateCount(let target, let count):
            return changedMutationCount(target) >= count

        case .launch(let target):
            let after = lastMutationIndex(target) ?? -1

            return items.indices.contains { index in
                guard index > after else { return false }
                guard case .launched(_, let path) = items[index] else {
                    return false
                }
                return target.matches(path)
            }

        case .validate(let target):
            let after = lastMutationIndex(target) ?? -1

            return items.indices.contains { index in
                guard index > after else { return false }
                guard case .validated(_, let path) = items[index] else {
                    return false
                }
                return target.matches(path)
            }

        case .readBack(let target):
            let after = lastMutationIndex(target) ?? -1

            return items.indices.contains { index in
                guard index > after else { return false }
                guard case .readBack(let path, let matched) = items[index],
                      matched else {
                    return false
                }
                return target.matches(path)
            }

        case .inspectBeforeLaunch(let target):
            let after = lastMutationIndex(target) ?? -1
            var inspected = false

            for index in items.indices where index > after {
                switch items[index] {
                case .observed(let tool, let path):
                    if target.matches(path) || (path == nil && tool == "read_file") {
                        inspected = true
                    }

                case .validated(_, let path):
                    if target.matches(path) {
                        inspected = true
                    }

                case .readBack(let path, _):
                    if target.matches(path) {
                        inspected = true
                    }

                case .launched(_, let path):
                    if inspected && target.matches(path) {
                        return true
                    }

                default:
                    break
                }
            }

            return false
      

        case .externalEffect:
            return items.contains { evidence in
                if case .externalEffect = evidence {
                    return true
                }
                return false
            }

        case .externalArtifact(let type):
            return items.contains { evidence in
                guard case .externalEffect(_, _, let operation, let urls) = evidence else {
                    return false
                }
                return urls.contains { url in
                    Self.externalURL(url, matches: type, operation: operation)
                }
            }
        }
    }

    private static func externalURL(
        _ value: String,
        matches type: ArtifactType,
        operation: String?
    ) -> Bool {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        guard type == .image else { return true }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif"]
        return imageExtensions.contains(url.pathExtension.lowercased()) ||
            (operation?.lowercased().contains("image") == true)
    }

    private func mutationAttemptCount(_ target: TargetSelector) -> Int {
        items.reduce(into: 0) { count, evidence in
            guard case .mutated(_, let path, _, _) = evidence,
                  target.matches(path) else {
                return
            }
            count += 1
        }
    }

    private func changedMutationCount(_ target: TargetSelector) -> Int {
        items.reduce(into: 0) { count, evidence in
            guard case .mutated(_, let path, let changed, _) = evidence,
                  changed,
                  target.matches(path) else {
                return
            }
            count += 1
        }
    }

    private func firstMutationIndex(_ target: TargetSelector) -> Int? {
        items.indices.first { index in
            guard case .mutated(_, let path, _, _) = items[index] else {
                return false
            }
            return target.matches(path)
        }
    }

    private func lastMutationIndex(_ target: TargetSelector) -> Int? {
        items.indices.reversed().first { index in
            guard case .mutated(_, let path, _, _) = items[index] else {
                return false
            }
            return target.matches(path)
        }
    }

    func missing(from requirements: [TaskRequirement]) -> [TaskRequirement] {
        requirements.filter { !satisfies($0) }
    }
}

enum SessionLedgerEvent: Sendable, CustomStringConvertible {
    case userMessage(String)
    case assistantMessage(String)
    case taskStarted(TaskSpec)
    case evidenceAdded(taskID: TaskID, TaskEvidence)
    case taskFinished(taskID: TaskID, state: TaskState)
    case artifactReferenced(taskID: TaskID?, ArtifactRef)
    case userReportedFailure(taskID: TaskID?, path: String?, message: String)

    var description: String {
        switch self {
        case .userMessage(let text):
            return "user: \(text)"
        case .assistantMessage(let text):
            return "assistant: \(text)"
        case .taskStarted(let spec):
            return "task started: \(spec)"
        case .evidenceAdded(let taskID, let evidence):
            return "task \(taskID) evidence: \(evidence)"
        case .taskFinished(let taskID, let state):
            return "task \(taskID) \(state.rawValue)"
        case .artifactReferenced(let taskID, let artifact):
            return "artifact \(artifact.path) task=\(taskID?.description ?? "none")"
        case .userReportedFailure(let taskID, let path, let message):
            return "user failure task=\(taskID?.description ?? "none") path=\(path ?? "none"): \(message)"
        }
    }
}

struct SessionLedger: Sendable {
    /// The append-only canonical history lives in events.jsonl. In memory we keep only
    /// a bounded diagnostic tail; semantic session state is stored separately.
    private(set) var events: [SessionLedgerEvent] = []
    private(set) var totalAppended: Int = 0
    private let capacity = 256

    mutating func append(_ event: SessionLedgerEvent) {
        totalAppended += 1
        events.append(event)

        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    mutating func clear() {
        events.removeAll(keepingCapacity: true)
        totalAppended = 0
    }
}

enum TaskCompiler {
    static func compile(
        userText: String,
        decision: TurnDecision,
        continuity: TaskContinuity? = nil
    ) -> TaskSpec {
        let text = normalize(userText)
        let parentID = continuity?.isContinuation == true
            ? continuity?.priorTaskID
            : nil

        var kinds: Set<TaskKind> = []
        var desired: Set<DesiredState> = []
        var requirements: [TaskRequirement] = []
        var constraints: [TaskConstraint] = []
        var targets: [ArtifactRef] = []

        let explicitTarget = extractPath(from: userText)
        let inheritedTarget = continuity?.isContinuation == true
            ? continuity?.lastArtifact
            : nil
        let targetPath = explicitTarget ?? inheritedTarget

        if let targetPath {
            targets.append(
                ArtifactRef(
                    path: targetPath,
                    originTask: parentID
                )
            )
        }

        // Natural-language task signals are centralized in DiscourseResolver so
        // continuation routing and TaskCompiler cannot silently drift apart.
        let discourse = DiscourseResolver.analyze(userText)
        let stagedBreakAndRepair = discourse.stagedBreakAndRepair
        let requestedApplication = discourse.requestedApplication

        let failureFeedback = continuity?.failureFeedback == true
        let failureKind = continuity?.failureKind ?? .none
        let createRequested =
            discourse.createVerb ||
            continuity?.requestsNewArtifact == true
        let implicitFocusedMutation =
            decision.mode == .agent &&
            targetPath != nil &&
            !createRequested &&
            requestedApplication == nil &&
            !discourse.launchRequest &&
            !discourse.inspectionRequest &&
            !discourse.explainRequest &&
            !discourse.verifyRequest

        let repairRequested =
            discourse.revisionRequest ||
            continuity?.revisionRequest == true ||
            failureKind == .notChanged ||
            failureKind == .functional ||
            implicitFocusedMutation

        if decision.mode == .chat {
            kinds.insert(.converse)
        }
        if decision.mode == .mcpAgent {
            kinds.insert(.externalAction)
            desired.insert(.externalEffect)
            appendUnique(.externalEffect, to: &requirements)
            if containsImageRequest(text) {
                appendUnique(.externalArtifact(.image), to: &requirements)
            }
        }

        // A request such as "вставь в него фото крота" is a hybrid task:
        // first obtain a real image URL, then mutate the local artifact. Without
        // this requirement the runtime used to expose only edit tools and could
        // accept a fabricated/broken URL as a completed file change.
        let embedsExternalImage =
            decision.mode == .agent &&
            requestsExternalImage(text) &&
            (createRequested || repairRequested || isWebPath(targetPath))

        if embedsExternalImage {
            desired.insert(.externalEffect)
            appendUnique(.externalArtifact(.image), to: &requirements)
        }
        if decision.mode == .mcpRead {
            kinds.insert(.inspect)
            desired.insert(.observed)
            appendUnique(.observe(.any), to: &requirements)
        }

        if createRequested {
            kinds.insert(.create)
            desired.insert(.exists)
            appendUnique(.mutate(targetPath.map(TargetSelector.path) ?? .any), to: &requirements)
        }

        if repairRequested && !createRequested {
            kinds.insert(.modify)
            desired.insert(.modified)

            let selector = targetPath.map(TargetSelector.path) ?? .any
            if !constraints.contains(.preserveExisting) {
                constraints.append(.preserveExisting)
            }

            // Existing artifacts should be observed before intelligence is spent on
            // generating an edit. Runtime can satisfy this read deterministically.
            appendUnique(.observe(selector), to: &requirements)

            if stagedBreakAndRepair {
                kinds.insert(.debug)
                desired.insert(.functional)
                appendUnique(.mutateCount(selector, 2), to: &requirements)
                appendUnique(.observeAfterMutation(selector), to: &requirements)
            } else {
                // MODIFY means an actual changed revision, not merely a no-op tool call.
                appendUnique(.mutateCount(selector, 1), to: &requirements)
            }
        }

        if decision.mode == .inspect ||
           (decision.mode == .agent && discourse.inspectionRequest) {
            kinds.insert(.inspect)
            desired.insert(.observed)
            appendUnique(.observe(targetPath.map(TargetSelector.path) ?? .any), to: &requirements)
        }

        if discourse.explainRequest {
            kinds.insert(.explain)
            desired.insert(.explained)
        }

        let launchRequested =
            discourse.launchRequest ||
            requestedApplication != nil ||
            (
                continuity?.isContinuation == true &&
                continuity?.previousRequiredLaunch == true &&
                (failureFeedback || continuity?.bareAction == true)
            )

        if decision.mode == .agent && launchRequested {
            kinds.insert(.run)
            desired.insert(.launched)
            let selector = targetPath.map(TargetSelector.path) ?? .any

            if failureKind == .notLaunched {
                kinds.insert(.debug)
                appendUnique(.inspectBeforeLaunch(selector), to: &requirements)
            } else {
                // When a failed/unsatisfactory artifact is being repaired, the
                // mutation+validation pipeline already establishes a fresh revision.
                // Launch that latest revision instead of demanding another read.
                appendUnique(.launch(selector), to: &requirements)
            }
        }

        if failureFeedback {
            kinds.insert(.debug)
            desired.insert(.functional)

            if !launchRequested && decision.mode != .mcpAgent {
                appendUnique(.observe(targetPath.map(TargetSelector.path) ?? .any), to: &requirements)
            }

            if (failureKind == .notChanged || failureKind == .functional),
               let targetPath,
               SemanticToolCatalog.supportsDeterministicFileValidation(path: targetPath) {
                appendUnique(.validate(.path(targetPath)), to: &requirements)
            }
        }

        if discourse.verifyRequest {
            kinds.insert(.verify)
            desired.insert(.validated)

            if let targetPath,
               SemanticToolCatalog.supportsDeterministicFileValidation(path: targetPath) {
                appendUnique(
                    .validate(.path(targetPath)),
                    to: &requirements
                )
            }
        }

        let explicitReadBack =
            text.contains("прочитай обратно") ||
            text.contains("прочти обратно") ||
            text.contains("считай обратно") ||
            ((text.contains("прочитай") || text.contains("прочти") || text.contains("считай")) &&
             text.contains("обратно")) ||
            (text.contains("read") && text.contains("back"))

        if explicitReadBack {
            constraints.append(.explicitReadBack)
            appendUnique(.readBack(targetPath.map(TargetSelector.path) ?? .any), to: &requirements)
        }

        if embedsExternalImage {
            // Confirm the edit is present on disk before reporting success.
            appendUnique(.readBack(targetPath.map(TargetSelector.path) ?? .any), to: &requirements)
        }

        if text.contains("без установки") ||
           text.contains("без зависим") ||
           text.contains("no dependencies") {
            constraints.append(.noDependencyInstall)
        }

        if text.contains("самый простой") ||
           text.contains("минимальн") ||
           text.contains("simplest") ||
           text.contains("minimal") {
            constraints.append(.simplestImplementation)
        }

        if let minimumLines =
            extractMinimumLineCount(userText) ??
            continuity?.artifactMinimumLineCount ??
            minimumLineCount(
                currentRequest: userText,
                rootGoal: continuity?.rootGoal
            ) {
            constraints.removeAll {
                if case .minimumLineCount = $0 { return true }
                return false
            }
            constraints.append(.minimumLineCount(minimumLines))
        }

        if kinds.isEmpty {
            switch decision.mode {
            case .agent:
                kinds.insert(.operate)
                appendUnique(.observe(targetPath.map(TargetSelector.path) ?? .any), to: &requirements)
            case .inspect:
                kinds.insert(.inspect)
                desired.insert(.observed)
                appendUnique(.observe(targetPath.map(TargetSelector.path) ?? .any), to: &requirements)
            case .mcpAgent:
                kinds.insert(.externalAction)
            case .mcpRead:
                kinds.insert(.inspect)
            case .chat:
                kinds.insert(.converse)
            }
        }

        let outputPolicy: TaskOutputPolicy
        if kinds.contains(.externalAction) ||
           kinds.contains(.explain) ||
           (
               decision.mode == .inspect &&
               !kinds.contains(.run) &&
               !kinds.contains(.modify) &&
               !kinds.contains(.create)
           ) ||
           (
               decision.mode == .agent &&
               !kinds.contains(.run) &&
               !kinds.contains(.modify) &&
               !kinds.contains(.create)
           ) {
            outputPolicy = .synthesis
        } else {
            outputPolicy = .deterministicAck
        }

        var compileConfidence = 0.45
        var compilerNotes: [String] = []

        if let explicitTarget {
            compileConfidence += 0.28
            compilerNotes.append("explicit target: \(explicitTarget)")
        } else if let inheritedTarget {
            compileConfidence += 0.20
            compilerNotes.append("inherited target: \(inheritedTarget)")
        } else if kinds.contains(.create) || kinds.contains(.modify) || kinds.contains(.run) {
            compileConfidence -= 0.22
            compilerNotes.append("target unresolved")
        }

        if !kinds.isEmpty {
            compileConfidence += 0.12
            compilerNotes.append("task kinds recognized")
        }

        if decision.source == .fast {
            compileConfidence += 0.08
            compilerNotes.append("high-confidence route")
        }

        if stagedBreakAndRepair {
            compileConfidence += 0.05
            compilerNotes.append("ordered break/repair workflow")
        }

        compileConfidence = min(1.0, max(0.0, compileConfidence))

        return TaskSpec(
            id: TaskID(),
            parentID: parentID,
            mode: decision.mode,
            kinds: kinds,
            originalRequest: userText,
            targets: targets,
            launchApplication: requestedApplication,
            desiredState: desired,
            requirements: requirements,
            constraints: constraints,
            outputPolicy: outputPolicy,
            compileConfidence: compileConfidence,
            compilerNotes: compilerNotes
        )
    }

    private static func containsImageRequest(_ text: String) -> Bool {
        [
            "картин", "изображ", "фото", "фотограф", "image", "photo", "picture"
        ].contains(where: text.contains)
    }

    private static func requestsExternalImage(_ text: String) -> Bool {
        guard containsImageRequest(text) else { return false }
        return [
            "найди", "поищи", "подбери", "встав", "добав", "помести",
            "загрузи", "скачай", "из интернета", "из сети",
            "find", "search", "insert", "add", "embed", "download"
        ].contains(where: text.contains)
    }

    private static func isWebPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return ["html", "htm"].contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        )
    }

    private static func minimumLineCount(
        currentRequest: String,
        rootGoal: String?
    ) -> Int? {
        if let current = extractMinimumLineCount(currentRequest) {
            return current
        }

        let current = normalize(currentRequest)
        let overridesLineCount =
            current.contains("сократ") ||
            current.contains("не больше") ||
            current.contains("максимум") ||
            current.contains("до ") && current.contains("строк") ||
            current.contains("at most") ||
            current.contains("maximum")

        if overridesLineCount {
            return nil
        }

        guard let rootGoal else { return nil }
        return extractMinimumLineCount(rootGoal)
    }

    private static func extractMinimumLineCount(
        _ value: String
    ) -> Int? {
        let patterns = [
            #"(?i)(?:минимум|не\s+менее)\s*(\d{1,7})\s*(?:строк|строки|строка)"#,
            #"(?i)(?:at\s+least|minimum(?:\s+of)?)\s*(\d{1,7})\s*lines?"#
        ]

        let ns = value as NSString

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern
            ) else {
                continue
            }

            guard let match = regex.firstMatch(
                in: value,
                range: NSRange(
                    location: 0,
                    length: ns.length
                )
            ),
            match.numberOfRanges > 1 else {
                continue
            }

            let range = match.range(at: 1)
            guard range.location != NSNotFound,
                  let count = Int(ns.substring(with: range)),
                  count > 0 else {
                continue
            }

            return count
        }

        return nil
    }

    private static func normalize(_ value: String) -> String {
        InputNormalizer.lexical(value)
    }

    private static func extractPath(from text: String) -> String? {
        let ns = text as NSString
        let pattern = #"(?i)(?:^|[\s`"'«])((?:[\w.\-]+/)*[\w.\-]+\.(?:html?|swift|py|js|mjs|cjs|ts|tsx|jsx|json|ya?ml|toml|md|txt|css|scss|rs|go|java|kt|kts|cs|php|rb|sh|sql|pdf|png|jpe?g|gif|svg|app))(?:$|[\s`"',.!?»:])"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(location: 0, length: ns.length)
              ),
              match.numberOfRanges > 1 else {
            return nil
        }

        return ns.substring(with: match.range(at: 1))
    }

    private static func appendUnique(
        _ requirement: TaskRequirement,
        to requirements: inout [TaskRequirement]
    ) {
        if !requirements.contains(requirement) {
            requirements.append(requirement)
        }
    }
}

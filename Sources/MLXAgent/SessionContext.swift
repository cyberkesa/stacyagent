import Foundation

struct TaskContinuity: Sendable {
    let isContinuation: Bool
    let priorTaskID: TaskID?
    let priorGoal: String?
    let rootGoal: String?
    let artifactMinimumLineCount: Int?
    /// Resolved conversational artifact referent for the current turn.
    /// This may be a newly allocated sibling path for requests such as
    /// "создай новый".
    let lastArtifact: String?
    let previousRequiredLaunch: Bool
    let failureFeedback: Bool
    let failureKind: FailureFeedbackKind
    let bareAction: Bool
    let revisionRequest: Bool
    let requestsNewArtifact: Bool
}

struct SessionTurn: Sendable {
    let user: String
    let assistant: String
    let mode: TurnMode
    let status: String
}

struct ArtifactProjection: Sendable {
    var ref: ArtifactRef
    var wasRead = false
    var wasMutated = false
    var wasValidated = false
    var wasOpened = false
    var minimumLineCount: Int? = nil
}

struct SessionSnapshot: Sendable {
    let projectPath: String
    let persistencePath: String
    let turns: [SessionTurn]
    let ledgerEventCount: Int
    let lastProjectRequest: String?
    let lastOperationalRequest: String?
    let lastProjectMode: TurnMode?
    let lastTaskID: TaskID?
    let lastTaskKinds: Set<TaskKind>
    let artifacts: [ArtifactProjection]
    let lastArtifact: String?
    let lastOpenedArtifact: String?
    let lastExternalURL: String?
    let previousRequiredLaunch: Bool
    let previousTaskComplete: Bool
    let lastTaskMutationCount: Int
    let lastFailure: String?

    var knownArtifacts: [String] {
        artifacts.map(\.ref.path)
    }

    var hasProjectContinuity: Bool {
        lastProjectRequest != nil ||
        lastOperationalRequest != nil ||
        lastTaskID != nil ||
        lastArtifact != nil
    }

    var debugSummary: String {
        var lines = [
            "project        \(projectPath)",
            "storage        \(persistencePath)",
            "ledger events  \(ledgerEventCount)",
            "turns          \(turns.count)",
            "task id        \(lastTaskID?.description ?? "none")",
            "task kinds     \(lastTaskKinds.isEmpty ? "none" : lastTaskKinds.map(\.rawValue).sorted().joined(separator: "+"))"
        ]

        if let lastProjectRequest {
            lines.append(
                "project goal   \(Self.clip(lastProjectRequest, limit: 180))"
            )
        } else {
            lines.append("project goal   none")
        }

        if let lastOperationalRequest {
            lines.append(
                "last action    " + Self.clip(lastOperationalRequest, limit: 180)
            )
        } else {
            lines.append("last action    none")
        }

        lines.append("last artifact  \(lastArtifact ?? "none")")
        lines.append("last opened    \(lastOpenedArtifact ?? "none")")
        lines.append("external URL  \(lastExternalURL ?? "none")")
        lines.append(
            "artifacts      \(knownArtifacts.isEmpty ? "none" : knownArtifacts.suffix(8).joined(separator: ", "))"
        )
        lines.append(
            "launch goal    \(previousRequiredLaunch ? "yes" : "no")"
        )
        lines.append(
            "last complete  \(previousTaskComplete ? "yes" : "no")"
        )
        lines.append(
            "last mutations \(lastTaskMutationCount)"
        )

        if let lastFailure {
            lines.append(
                "last failure   \(Self.clip(lastFailure, limit: 180))"
            )
        }

        return lines.joined(separator: "\n")
    }

    func directAnswer(for userText: String) -> String? {
        let text = InputNormalizer.lexical(userText)

        if let lastExternalURL,
           Self.asksExternalResourceLocation(text) {
            return "Последний найденный внешний ресурс: \(lastExternalURL)"
        }

        // Project-state claims must come from runtime evidence, never from model
        // memory. Explicit failure feedback is intentionally NOT answered here;
        // it is routed back into the task runtime for corrective action.
        if !previousTaskComplete,
           let lastFailure,
           isFrustrationReaction(text) {
            return "Предыдущая проектная задача не завершена: " +
                Self.clip(lastFailure, limit: 260) +
                ". Я не буду считать файл изменённым, пока runtime не получит нужное evidence."
        }

        if asksWhatHappened(text),
           let lastFailure {
            let artifact = lastArtifact ?? lastOpenedArtifact
            let suffix = artifact.map {
                " Текущий рабочий файл: `" +
                Self.absolutePath(projectPath: projectPath, artifact: $0) +
                "`."
            } ?? ""
            return "Последняя проектная операция не завершилась: " +
                Self.clip(lastFailure, limit: 320) + "." + suffix
        }

        if asksFileContextDiagnostic(text),
           let artifact = lastArtifact ?? lastOpenedArtifact {
            let projection = artifacts.first {
                $0.ref.path == artifact
            }
            let fullPath = Self.absolutePath(
                projectPath: projectPath,
                artifact: artifact
            )

            if projection?.wasRead == true {
                if let lastFailure {
                    return "Файл `\(fullPath)` есть в состоянии сессии и уже был прочитан runtime. Последняя проблема не в отсутствии файла в контексте: \(Self.clip(lastFailure, limit: 260))."
                }
                return "Да, runtime уже прочитал `\(fullPath)` и удерживает его как текущий артефакт."
            }

            return "Файл `\(fullPath)` известен runtime, но для безопасного частичного редактирования его ещё нужно прочитать."
        }

        if asksEditContinuityDiagnostic(text),
           let artifact = lastArtifact ?? lastOpenedArtifact {
            let fullPath = Self.absolutePath(
                projectPath: projectPath,
                artifact: artifact
            )
            var answer = "Да, это текущий артефакт: `\(fullPath)`. SLTA может читать и редактировать его через workspace-инструменты."
            if let lastFailure {
                answer += " Предыдущая попытка редактирования не завершилась: " +
                    Self.clip(lastFailure, limit: 260) + "."
            }
            return answer
        }

        if DiscourseResolver.analyze(userText).failureKind == .none,
           DiscourseResolver.asksMutationTruth(text) {
            if lastTaskMutationCount > 0 {
                return "Да. Runtime зафиксировал \(lastTaskMutationCount) изменяющ\(lastTaskMutationCount == 1 ? "ую" : "их") операци\(lastTaskMutationCount == 1 ? "ю" : "и") в последней проектной задаче."
            }
            return "Нет. По runtime evidence последняя проектная задача не внесла ни одного изменения в файл."
        }

        if asksWhatChanged(text),
           let artifact = lastArtifact ?? lastOpenedArtifact {
            let taskTurn = turns.reversed().first {
                $0.mode != .chat
            }

            let taskText = taskTurn?.user ?? lastOperationalRequest ?? lastProjectRequest ?? "последняя проектная задача"
            let fullPath = Self.absolutePath(
                projectPath: projectPath,
                artifact: artifact
            )

            var answer =
                "Последняя проектная задача: «" +
                Self.clip(taskText, limit: 260) +
                "»."

            if lastTaskMutationCount == 0 {
                answer += " В этой задаче файл ещё не был изменён."
            } else {
                answer += " Изменения выполнялись в файле `\(fullPath)`."
            }

            if previousTaskComplete {
                answer += " Runtime считает последнюю задачу завершённой."
            } else {
                answer += " Последняя задача не завершена."
                if let lastFailure {
                    answer += " Ошибка: " + Self.clip(lastFailure, limit: 220) + "."
                }
            }

            return answer
        }

        if asksForKnownArtifacts(text) {
            guard !knownArtifacts.isEmpty else {
                return "В этой сессии проектные файлы ещё не зафиксированы."
            }

            return "Известные файлы этой сессии: " +
                knownArtifacts.suffix(12)
                    .map { "`\(Self.absolutePath(projectPath: projectPath, artifact: $0))`" }
                    .joined(separator: ", ") +
                "."
        }

        guard let artifact = lastArtifact ?? lastOpenedArtifact else {
            return nil
        }

        let asksWhere =
            text.contains("где") ||
            text.contains("where")

        let refersToPriorResult =
            text.contains("игр") ||
            text.contains("файл") ||
            text.contains("результат") ||
            text.contains("она") ||
            text.contains("он ") ||
            text.contains("это") ||
            text.contains("it") ||
            text.contains("game")

        guard asksWhere && refersToPriorResult else {
            return nil
        }

        let fullPath = Self.absolutePath(
            projectPath: projectPath,
            artifact: artifact
        )

        if text.contains("игр") || text.contains("game") {
            return "Игра находится здесь: `\(fullPath)`."
        }

        return "Последний рабочий файл находится здесь: `\(fullPath)`."
    }

    func continuationDecision(
        for userText: String
    ) -> TurnDecision? {
        let continuity = taskContinuity(for: userText)

        guard continuity.isContinuation else {
            return nil
        }

        let discourse = DiscourseResolver.analyze(userText)

        if lastProjectMode == .mcpAgent,
           lastExternalURL != nil,
           (continuity.bareAction ||
            discourse.actionVerb ||
            discourse.inspectVerb ||
            discourse.priorReference) {
            return .forMode(.mcpAgent, source: .fast)
        }

        if continuity.failureFeedback ||
           continuity.revisionRequest ||
           continuity.requestsNewArtifact ||
           continuity.bareAction ||
           discourse.actionVerb {
            return .forMode(.agent, source: .fast)
        }

        if discourse.inspectVerb {
            return .forMode(.inspect, source: .fast)
        }

        let priorWasOperational =
            !lastTaskKinds.isDisjoint(with: [
                .create, .modify, .run, .debug, .operate
            ])

        if priorWasOperational &&
           discourse.priorReference &&
           lastArtifact != nil {
            // Ambiguous artifact feedback ("там странный квадрат", "там что-то не так")
            // must not be prematurely demoted to CHAT. The tiny controller can classify
            // it with the session state.
            return nil
        }

        return .forMode(.chat, source: .fast)
    }

    func taskContinuity(
        for userText: String
    ) -> TaskContinuity {
        let discourse = DiscourseResolver.analyze(userText)

        // Negative phrases only invalidate a prior ACTION, not an arbitrary completed
        // inspection/chat turn. This prevents statements such as "там нет ошибок" after
        // a read-only review from being miscompiled as a repair task.
        let priorCanFail =
            !previousTaskComplete ||
            previousRequiredLaunch ||
            !lastTaskKinds.isDisjoint(with: [
                .create, .modify, .run, .debug, .operate, .externalAction
            ])
        let failureKind = priorCanFail ? discourse.failureKind : .none
        let failure = failureKind != .none
        let bare = discourse.bareAction
        let revision = discourse.revisionRequest

        guard hasProjectContinuity else {
            return TaskContinuity(
                isContinuation: false,
                priorTaskID: nil,
                priorGoal: nil,
                rootGoal: nil,
                artifactMinimumLineCount: nil,
                lastArtifact: nil,
                previousRequiredLaunch: false,
                failureFeedback: failure,
                failureKind: failureKind,
                bareAction: bare,
                revisionRequest: false,
                requestsNewArtifact: false
            )
        }

        let explicitTarget = discourse.explicitFileTarget
        let requestsNewArtifact =
            discourse.createVerb &&
            discourse.strongNewMarker &&
            !explicitTarget &&
            !discourse.newProjectScope

        let newScope = discourse.newProjectScope

        let unresolvedPriorActionResume =
            !previousTaskComplete &&
            !discourse.explicitFileTarget &&
            !discourse.newProjectScope &&
            !discourse.createVerb &&
            (discourse.actionVerb || bare)

        let referencesPrior =
            failure ||
            bare ||
            revision ||
            requestsNewArtifact ||
            discourse.genericArtifactReference ||
            discourse.priorReference ||
            unresolvedPriorActionResume

        // A request with its own concrete path owns that target even if it also
        // contains a local pronoun ("его", "it").
        let selfContainedProjectTask =
            explicitTarget &&
            (
                discourse.actionVerb ||
                discourse.inspectVerb
            ) &&
            !failure

        let isContinuation =
            referencesPrior &&
            !selfContainedProjectTask &&
            !newScope

        let resolvedArtifact: String?
        if isContinuation && requestsNewArtifact {
            resolvedArtifact = DiscourseResolver.suggestSiblingPath(
                from: lastArtifact,
                knownArtifacts: Set(knownArtifacts)
            )
        } else if isContinuation && discourse.genericArtifactReference {
            resolvedArtifact =
                lastArtifact ??
                lastOpenedArtifact ??
                knownArtifacts.last
        } else {
            resolvedArtifact = isContinuation ? lastArtifact : nil
        }

        let inheritedMinimumLineCount = resolvedArtifact.flatMap { path in
            artifacts.first {
                $0.ref.path == path
            }?.minimumLineCount
        }

        return TaskContinuity(
            isContinuation: isContinuation,
            priorTaskID: isContinuation ? lastTaskID : nil,
            priorGoal: isContinuation ? (lastOperationalRequest ?? lastProjectRequest) : nil,
            rootGoal: isContinuation ? lastProjectRequest : nil,
            artifactMinimumLineCount: isContinuation ? inheritedMinimumLineCount : nil,
            lastArtifact: resolvedArtifact,
            previousRequiredLaunch:
                isContinuation ? previousRequiredLaunch : false,
            failureFeedback: failure,
            failureKind: failureKind,
            bareAction: bare,
            revisionRequest: isContinuation && revision,
            requestsNewArtifact: isContinuation && requestsNewArtifact
        )
    }

    func promptContext(
        currentUserText: String
    ) -> String {
        guard hasProjectContinuity || !turns.isEmpty else {
            return ""
        }

        let continuity = taskContinuity(
            for: currentUserText
        )

        var lines: [String] = [
            "SESSION STATE — trusted runtime projection:",
            "project: \(projectPath)"
        ]

        if let lastTaskID {
            lines.append("last task id: \(lastTaskID)")
        }

        if !lastTaskKinds.isEmpty {
            lines.append(
                "last task kinds: " +
                lastTaskKinds.map(\.rawValue)
                    .sorted()
                    .joined(separator: "+")
            )
        }

        if let lastProjectRequest {
            lines.append(
                "root project goal: " +
                Self.clip(
                    lastProjectRequest,
                    limit: 500
                )
            )
        }

        if let lastOperationalRequest {
            lines.append(
                "latest operational intent: " +
                Self.clip(
                    lastOperationalRequest,
                    limit: 500
                )
            )
        }

        if !artifacts.isEmpty {
            let artifactText = artifacts.suffix(8).map {
                var flags: [String] = []
                if $0.wasRead { flags.append("read") }
                if $0.wasMutated { flags.append("mutated") }
                if $0.wasValidated { flags.append("validated") }
                if $0.wasOpened { flags.append("opened") }

                let suffix = flags.isEmpty
                    ? ""
                    : " [" + flags.joined(separator: ",") + "]"

                return $0.ref.path + suffix
            }

            lines.append(
                "known artifacts: " +
                artifactText.joined(separator: ", ")
            )
        }

        if let lastArtifact {
            lines.append(
                "current artifact referent: \(lastArtifact)"
            )
        }

        if let lastOpenedArtifact {
            lines.append(
                "last opened artifact: \(lastOpenedArtifact)"
            )
        }

        if let lastExternalURL {
            lines.append("last external resource: \(lastExternalURL)")
        }

        lines.append(
            "previous launch requirement: " +
            (previousRequiredLaunch ? "yes" : "no")
        )
        lines.append(
            "previous runtime completion: " +
            (previousTaskComplete ? "yes" : "no")
        )

        if let lastFailure {
            lines.append(
                "latest user/runtime failure: " +
                Self.clip(lastFailure, limit: 300)
            )
        }

        if continuity.isContinuation {
            lines.append(
                "CURRENT MESSAGE IS A FOLLOW-UP to task " +
                (continuity.priorTaskID?.description ?? "unknown") +
                "."
            )

            if continuity.failureFeedback {
                lines.append(
                    "The user reports that the previous real-world result did not work. " +
                    "failure kind: \(continuity.failureKind.rawValue). The prior goal is unresolved."
                )
            }

            if continuity.revisionRequest {
                lines.append(
                    "The current message requests a revision of the focused artifact; " +
                    "this is an action, not conversational brainstorming."
                )
            }

            if continuity.requestsNewArtifact,
               let target = continuity.lastArtifact {
                lines.append(
                    "The current message requests a new sibling artifact. Runtime target: \(target)."
                )
            }

            if continuity.bareAction {
                lines.append(
                    "Resolve the short imperative against the current task/artifact. " +
                    "Do not ask for the referent again."
                )
            }
        }

        // Keep only a tiny conversational tail for wording that is not yet represented
        // structurally. Operational state above is the source of truth.
        if !turns.isEmpty {
            lines.append("recent conversational tail:")

            for turn in turns.suffix(2) {
                lines.append(
                    "USER: " +
                    Self.clip(turn.user, limit: 280)
                )
                lines.append(
                    "ASSISTANT: " +
                    Self.clip(turn.assistant, limit: 320)
                )
            }
        }

        lines.append(
            "Never replace these runtime facts with a guessed project, file tree, artifact, " +
            "command, or dependency."
        )

        return lines.joined(separator: "\n")
    }

    func routerContext(
        currentUserText: String
    ) -> String {
        guard hasProjectContinuity else {
            return ""
        }

        let continuity = taskContinuity(
            for: currentUserText
        )

        var lines = [
            "Session state:",
            "project: \(projectPath)",
            "task: \(lastTaskID?.description ?? "none")"
        ]

        if let lastProjectRequest {
            lines.append(
                "root goal: " +
                Self.clip(lastProjectRequest, limit: 260)
            )
        }

        if let lastOperationalRequest {
            lines.append(
                "last action: " +
                Self.clip(lastOperationalRequest, limit: 260)
            )
        }

        if let lastArtifact {
            lines.append(
                "artifact: \(lastArtifact)"
            )
        }

        if continuity.isContinuation {
            lines.append(
                "current message continues the previous task"
            )
        }

        if continuity.failureFeedback {
            lines.append(
                "current message invalidates previous real-world success; kind=\(continuity.failureKind.rawValue)"
            )
        }

        if continuity.revisionRequest {
            lines.append("current message requests artifact revision")
        }

        if continuity.requestsNewArtifact,
           let target = continuity.lastArtifact {
            lines.append("new artifact target: \(target)")
        }

        return lines.joined(separator: "\n")
    }

    private func isFrustrationReaction(_ text: String) -> Bool {
        let compact = InputNormalizer.commandLexical(text)
        return compact.count <= 40 && [
            "эээ", "ээээ", "эээээ", "эм", "блин", "ну блин",
            "что это", "что за", "wtf", "uh", "umm"
        ].contains(where: { compact == $0 || compact.hasPrefix($0) })
    }

    private func asksWhatHappened(
        _ text: String
    ) -> Bool {
        [
            "что случилось", "что произошло", "что не так",
            "почему не получилось", "почему ошибка", "что значит",
            "что это значит", "what happened", "what went wrong",
            "why did it fail", "what does that mean"
        ].contains(where: text.contains)
    }

    private func asksFileContextDiagnostic(
        _ text: String
    ) -> Bool {
        let contextTerms = [
            "в контексте", "контекста", "context"
        ]
        let fileTerms = [
            "файл", "его", "страниц", "html", "file", "it"
        ]

        return contextTerms.contains(where: text.contains) &&
            fileTerms.contains(where: text.contains)
    }

    private func asksEditContinuityDiagnostic(
        _ text: String
    ) -> Bool {
        let temporal = [
            "только что", "сам создал", "сама создала",
            "ты же создал", "ты же создала", "just created"
        ]
        let editing = [
            "не можешь", "можешь", "редакт", "править", "измен",
            "can't edit", "can edit", "modify"
        ]

        return temporal.contains(where: text.contains) &&
            editing.contains(where: text.contains)
    }

    private func asksWhatChanged(
        _ text: String
    ) -> Bool {
        let asksWhat =
            text.contains("что именно") ||
            text.contains("что ты сейчас") ||
            text.contains("что ты только что") ||
            text.contains("what exactly") ||
            text.contains("what did you just")

        let changeTerms = [
            "исправ", "измен", "сделал", "сделала", "поменял", "поменяла",
            "fix", "change", "changed", "modified"
        ]

        let asksFile =
            text.contains("каком файле") ||
            text.contains("какой файл") ||
            text.contains("в каком") ||
            text.contains("which file")

        return asksWhat &&
            changeTerms.contains(where: text.contains) &&
            asksFile
    }

    private func asksForKnownArtifacts(
        _ text: String
    ) -> Bool {
        (
            text.contains("какие файлы") ||
            text.contains("что ты создал") ||
            text.contains("что создал") ||
            text.contains("which files") ||
            text.contains("what files")
        ) &&
        (
            text.contains("создал") ||
            text.contains("файл") ||
            text.contains("files")
        )
    }

    private static func clip(
        _ value: String,
        limit: Int
    ) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard oneLine.count > limit else {
            return oneLine
        }

        return String(
            oneLine.prefix(limit)
        ) + "…"
    }

    private static func asksExternalResourceLocation(_ text: String) -> Bool {
        let asksWhere = text.contains("где") || text.contains("ссылк") || text.contains("url") || text.contains("where")
        let referencesResource = text.contains("картин") || text.contains("изображ") || text.contains("фото") || text.contains("это") || text.contains("ресурс") || text.contains("image") || text.contains("photo") || text.contains("it")
        return asksWhere && referencesResource
    }

    private static func absolutePath(
        projectPath: String,
        artifact: String
    ) -> String {
        if artifact.hasPrefix("/") {
            return artifact
        }

        return URL(
            fileURLWithPath: projectPath
        )
        .appendingPathComponent(artifact)
        .standardizedFileURL
        .path
    }
}

actor SessionContext {
    private let projectPath: String
    private let persistence: SessionPersistence
    private var historicalEventCount = 0
    private var ledger = SessionLedger()

    private var turns: [SessionTurn] = []
    private var lastProjectRequest: String?
    private var lastOperationalRequest: String?
    private var lastProjectMode: TurnMode?
    private var lastTaskID: TaskID?
    private var lastTaskKinds: Set<TaskKind> = []

    private var artifactsByPath: [String: ArtifactProjection] = [:]
    private var artifactOrder: [String] = []

    private var lastArtifact: String?
    private var lastOpenedArtifact: String?
    private var lastExternalURL: String?
    private var previousRequiredLaunch = false
    private var previousTaskComplete = false
    private var lastTaskMutationCount = 0
    private var lastFailure: String?

    init(projectPath: String) {
        self.projectPath = projectPath
        self.persistence = SessionPersistence(projectPath: projectPath)

        guard let saved = persistence.load(),
              saved.projectPath == projectPath else {
            return
        }

        historicalEventCount = saved.eventCount
        turns = saved.turns.compactMap { item in
            guard let mode = TurnMode(rawValue: item.mode) else {
                return nil
            }
            return SessionTurn(
                user: item.user,
                assistant: item.assistant,
                mode: mode,
                status: item.status
            )
        }

        lastProjectRequest = saved.lastProjectRequest
        lastOperationalRequest = saved.lastOperationalRequest
        lastProjectMode = saved.lastProjectMode.flatMap(TurnMode.init(rawValue:))
        lastTaskID = saved.lastTaskID
            .flatMap(UUID.init(uuidString:))
            .map(TaskID.init)
        lastTaskKinds = Set(
            saved.lastTaskKinds.compactMap(TaskKind.init(rawValue:))
        )

        artifactsByPath = [:]
        for item in saved.artifacts {
            guard let artifactUUID = UUID(uuidString: item.id),
                  let type = ArtifactType(rawValue: item.type) else {
                continue
            }

            let origin = item.originTask
                .flatMap(UUID.init(uuidString:))
                .map(TaskID.init)

            let projection = ArtifactProjection(
                ref: ArtifactRef(
                    id: ArtifactID(artifactUUID),
                    path: item.path,
                    type: type,
                    originTask: origin,
                    revision: item.revision
                ),
                wasRead: item.wasRead,
                wasMutated: item.wasMutated,
                wasValidated: item.wasValidated,
                wasOpened: item.wasOpened,
                minimumLineCount: item.minimumLineCount
            )
            artifactsByPath[item.path] = projection
        }

        artifactOrder = []
        for path in saved.artifactOrder {
            if artifactsByPath[path] != nil {
                artifactOrder.append(path)
            }
        }
        lastArtifact = saved.lastArtifact
        lastOpenedArtifact = saved.lastOpenedArtifact
        lastExternalURL = saved.lastExternalURL
        previousRequiredLaunch = saved.previousRequiredLaunch
        previousTaskComplete = saved.previousTaskComplete
        lastTaskMutationCount = saved.lastTaskMutationCount
        lastFailure = saved.lastFailure
    }

    func clear() {
        ledger.clear()
        historicalEventCount = 0

        turns.removeAll(keepingCapacity: true)
        lastProjectRequest = nil
        lastOperationalRequest = nil
        lastProjectMode = nil
        lastTaskID = nil
        lastTaskKinds.removeAll(keepingCapacity: true)

        artifactsByPath.removeAll(keepingCapacity: true)
        artifactOrder.removeAll(keepingCapacity: true)

        lastArtifact = nil
        lastOpenedArtifact = nil
        lastExternalURL = nil
        previousRequiredLaunch = false
        previousTaskComplete = false
        lastTaskMutationCount = 0
        lastFailure = nil
        persistence.clearState()
    }

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            projectPath: projectPath,
            persistencePath: persistence.directory.path,
            turns: turns,
            ledgerEventCount: historicalEventCount + ledger.totalAppended,
            lastProjectRequest: lastProjectRequest,
            lastOperationalRequest: lastOperationalRequest,
            lastProjectMode: lastProjectMode,
            lastTaskID: lastTaskID,
            lastTaskKinds: lastTaskKinds,
            artifacts: artifactOrder.compactMap {
                artifactsByPath[$0]
            },
            lastArtifact: lastArtifact,
            lastOpenedArtifact: lastOpenedArtifact,
            lastExternalURL: lastExternalURL,
            previousRequiredLaunch: previousRequiredLaunch,
            previousTaskComplete: previousTaskComplete,
            lastTaskMutationCount: lastTaskMutationCount,
            lastFailure: lastFailure
        )
    }

    func recordDirect(
        user: String,
        assistant: String
    ) {
        ledger.append(.userMessage(user))
        ledger.append(.assistantMessage(assistant))

        appendTurn(
            SessionTurn(
                user: user,
                assistant: assistant,
                mode: .chat,
                status: "direct"
            )
        )
        persistence.appendEvent(
            kind: "turn.direct",
            fields: ["user": user, "assistant": assistant]
        )
        persistState()
    }

    func recordChat(
        user: String,
        assistant: String
    ) {
        ledger.append(.userMessage(user))
        ledger.append(.assistantMessage(assistant))

        appendTurn(
            SessionTurn(
                user: user,
                assistant: assistant,
                mode: .chat,
                status: "chat"
            )
        )
        persistence.appendEvent(
            kind: "turn.chat",
            fields: ["user": user, "assistant": assistant]
        )
        persistState()
    }

    func recordUserFailure(
        message: String,
        continuity: TaskContinuity
    ) {
        guard continuity.failureFeedback else {
            return
        }

        lastFailure = message
        previousTaskComplete = false

        ledger.append(
            .userReportedFailure(
                taskID: continuity.priorTaskID,
                path: continuity.lastArtifact,
                message: message
            )
        )
        persistence.appendEvent(
            kind: "user.failure",
            fields: [
                "message": message,
                "path": continuity.lastArtifact ?? "",
                "task": continuity.priorTaskID?.rawValue.uuidString ?? ""
            ]
        )
        persistState()
    }

    func recordProject(
        user: String,
        assistant: String,
        decision: TurnDecision,
        task: TaskRuntimeSnapshot,
        continuity: TaskContinuity? = nil
    ) {
        guard let spec = task.spec else {
            return
        }

        ledger.append(.userMessage(user))
        ledger.append(.taskStarted(spec))

        for evidence in task.evidence {
            ledger.append(
                .evidenceAdded(
                    taskID: spec.id,
                    evidence
                )
            )
        }

        if continuity?.isContinuation != true ||
           lastProjectRequest == nil {
            lastProjectRequest = user
        }

        // Keep the root goal stable, but preserve the latest concrete operational
        // intent separately. Pure failure feedback ("nothing changed", "didn't open")
        // describes evidence about the previous action; it must not overwrite the action
        // we still need to satisfy. If the same feedback also contains a new revision
        // instruction, that combined message becomes the new operational intent.
        if continuity?.failureFeedback != true ||
           continuity?.revisionRequest == true {
            lastOperationalRequest = user
        }

        lastProjectMode = decision.mode
        lastTaskID = spec.id
        lastTaskKinds = spec.kinds
        previousRequiredLaunch = spec.requiresLaunch
        previousTaskComplete = task.isComplete
        let requiresImage = spec.requirements.contains(.externalArtifact(.image))
        for evidence in task.evidence.reversed() {
            guard case .externalEffect(_, _, let operation, let urls) = evidence else {
                continue
            }
            let candidate = urls.reversed().first { value in
                guard requiresImage else { return true }
                let ext = URL(string: value)?.pathExtension.lowercased() ?? ""
                return ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif"].contains(ext) ||
                    operation?.lowercased().contains("image") == true
            }
            if let candidate {
                lastExternalURL = candidate
                break
            }
        }
        lastTaskMutationCount = task.evidence.reduce(into: 0) { count, evidence in
            if case .mutated(_, _, let changed, _) = evidence, changed {
                count += 1
            }
        }

        if task.validation.lastToolFailed {
            lastFailure = task.validation.lastFailure
        } else if task.isComplete {
            lastFailure = nil
        } else if let recoverableFailure = task.validation.lastFailure {
            lastFailure = recoverableFailure
        } else {
            lastFailure = task.incompleteReason
        }

        if task.isComplete {
            ledger.append(
                .taskFinished(
                    taskID: spec.id,
                    state: .completed
                )
            )
        } else if task.validation.lastToolFailed {
            ledger.append(
                .taskFinished(
                    taskID: spec.id,
                    state: .failed
                )
            )
        } else {
            ledger.append(
                .taskFinished(
                    taskID: spec.id,
                    state: .blocked
                )
            )
        }

        applyArtifacts(
            task: task,
            taskID: spec.id
        )

        let minimumLineCount = spec.constraints.compactMap { constraint -> Int? in
            if case .minimumLineCount(let count) = constraint {
                return count
            }
            return nil
        }.max()

        if let minimumLineCount {
            let paths: [String]
            if !spec.targets.isEmpty {
                paths = spec.targets.map(\.path)
            } else if let resolved = task.resolvedTargetPath {
                paths = [resolved]
            } else {
                paths = []
            }

            for path in paths {
                if var projection = artifactsByPath[path] {
                    projection.minimumLineCount = max(
                        projection.minimumLineCount ?? 0,
                        minimumLineCount
                    )
                    artifactsByPath[path] = projection
                }
            }
        }

        if !assistant.isEmpty {
            ledger.append(
                .assistantMessage(assistant)
            )
        }

        appendTurn(
            SessionTurn(
                user: user,
                assistant: assistant,
                mode: decision.mode,
                status:
                    task.isComplete
                        ? "done"
                        : "incomplete"
            )
        )

        persistence.appendEvent(
            kind: "task.finished",
            fields: [
                "task": spec.id.rawValue.uuidString,
                "parent": spec.parentID?.rawValue.uuidString ?? "",
                "kinds": spec.kinds.map(\.rawValue).sorted().joined(separator: "+"),
                "target": spec.targets.first?.path ?? "",
                "complete": task.isComplete ? "true" : "false",
                "failure": task.validation.lastFailure ?? ""
            ]
        )
        for evidence in task.evidence {
            persistence.appendEvent(
                kind: "task.evidence",
                fields: [
                    "task": spec.id.rawValue.uuidString,
                    "evidence": evidence.description
                ]
            )
        }
        persistState()
    }

    private func applyArtifacts(
        task: TaskRuntimeSnapshot,
        taskID: TaskID
    ) {
        if let spec = task.spec {
            for target in spec.targets {
                updateArtifact(
                    path: target.path,
                    taskID: taskID
                )
            }
        }

        for path in task.readPaths {
            updateArtifact(
                path: path,
                taskID: taskID,
                read: true
            )
        }

        for path in task.validatedPaths {
            updateArtifact(
                path: path,
                taskID: taskID,
                validated: true
            )
        }

        for path in task.mutatedPaths {
            updateArtifact(
                path: path,
                taskID: taskID,
                mutated: true
            )
        }

        for path in task.openedPaths {
            updateArtifact(
                path: path,
                taskID: taskID,
                opened: true
            )
        }

        if let opened = task.openedPaths.last {
            lastOpenedArtifact = opened
            lastArtifact = opened
        } else if let mutated = task.mutatedPaths.last {
            lastArtifact = mutated
        } else if let read = task.readPaths.last {
            lastArtifact = read
        } else if let validated = task.validatedPaths.last {
            lastArtifact = validated
        }
    }

    private func updateArtifact(
        path: String,
        taskID: TaskID,
        read: Bool = false,
        mutated: Bool = false,
        validated: Bool = false,
        opened: Bool = false
    ) {
        guard !path.isEmpty else {
            return
        }

        var projection = artifactsByPath[path] ??
            ArtifactProjection(
                ref: ArtifactRef(
                    path: path,
                    originTask: taskID
                )
            )

        if mutated {
            projection.ref = ArtifactRef(
                id: projection.ref.id,
                path: path,
                type: projection.ref.type,
                originTask:
                    projection.ref.originTask ?? taskID,
                revision: projection.ref.revision + 1
            )
        }

        projection.wasRead =
            projection.wasRead || read
        projection.wasMutated =
            projection.wasMutated || mutated
        projection.wasValidated =
            projection.wasValidated || validated
        projection.wasOpened =
            projection.wasOpened || opened

        artifactsByPath[path] = projection

        artifactOrder.removeAll(
            where: { $0 == path }
        )
        artifactOrder.append(path)

        if artifactOrder.count > 30 {
            let dropCount = artifactOrder.count - 30
            let dropped = Array(artifactOrder.prefix(dropCount))
            artifactOrder.removeFirst(dropCount)

            for path in dropped {
                artifactsByPath.removeValue(
                    forKey: path
                )
            }
        }

        ledger.append(
            .artifactReferenced(
                taskID: taskID,
                projection.ref
            )
        )
    }

    private func persistState() {
        let persistedTurns = turns.map { turn in
            PersistedSessionTurn(
                user: turn.user,
                assistant: turn.assistant,
                mode: turn.mode.rawValue,
                status: turn.status
            )
        }

        let persistedArtifacts = artifactOrder.compactMap { path -> PersistedArtifactProjection? in
            guard let projection = artifactsByPath[path] else {
                return nil
            }

            return PersistedArtifactProjection(
                id: projection.ref.id.rawValue.uuidString,
                path: projection.ref.path,
                type: projection.ref.type.rawValue,
                originTask: projection.ref.originTask?.rawValue.uuidString,
                revision: projection.ref.revision,
                wasRead: projection.wasRead,
                wasMutated: projection.wasMutated,
                wasValidated: projection.wasValidated,
                wasOpened: projection.wasOpened,
                minimumLineCount: projection.minimumLineCount
            )
        }

        persistence.save(
            PersistedSessionState(
                schemaVersion: 1,
                projectPath: projectPath,
                eventCount: historicalEventCount + ledger.totalAppended,
                turns: persistedTurns,
                lastProjectRequest: lastProjectRequest,
                lastOperationalRequest: lastOperationalRequest,
                lastProjectMode: lastProjectMode?.rawValue,
                lastTaskID: lastTaskID?.rawValue.uuidString,
                lastTaskKinds: lastTaskKinds.map(\.rawValue).sorted(),
                artifacts: persistedArtifacts,
                artifactOrder: artifactOrder,
                lastArtifact: lastArtifact,
                lastOpenedArtifact: lastOpenedArtifact,
                lastExternalURL: lastExternalURL,
                previousRequiredLaunch: previousRequiredLaunch,
                previousTaskComplete: previousTaskComplete,
                lastTaskMutationCount: lastTaskMutationCount,
                lastFailure: lastFailure
            )
        )
    }

    private func appendTurn(
        _ turn: SessionTurn
    ) {
        turns.append(turn)

        if turns.count > 10 {
            turns.removeFirst(
                turns.count - 10
            )
        }
    }
}

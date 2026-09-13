import Foundation

enum FailureFeedbackKind: String, Sendable {
    case none
    case notChanged
    case notLaunched
    case functional
}

struct DiscourseAnalysis: Sendable {
    let text: String
    let failureKind: FailureFeedbackKind
    let bareAction: Bool
    let revisionRequest: Bool
    let priorReference: Bool
    let strongNewMarker: Bool
    let createVerb: Bool
    let actionVerb: Bool
    let inspectVerb: Bool
    let inspectionRequest: Bool
    let explainRequest: Bool
    let launchRequest: Bool
    let verifyRequest: Bool
    let stagedBreakAndRepair: Bool
    let explicitFileTarget: Bool
    let genericArtifactReference: Bool
    let newProjectScope: Bool

    var failureFeedback: Bool { failureKind != .none }
}

enum DiscourseResolver {
    static func analyze(_ raw: String) -> DiscourseAnalysis {
        let text = InputNormalizer.lexical(raw)
        let create = hasCreateVerb(text)
        let action = hasActionVerb(text)
        let inspection = hasInspectionRequest(text)
        let explain = hasExplainRequest(text)
        let verify = hasVerifyRequest(text)

        return DiscourseAnalysis(
            text: text,
            failureKind: failureKind(text),
            bareAction: hasBareAction(text),
            revisionRequest: hasRevisionRequest(text),
            priorReference: hasPriorReference(text),
            strongNewMarker: hasStrongNewMarker(text),
            createVerb: create,
            actionVerb: action,
            inspectVerb: inspection || explain || verify,
            inspectionRequest: inspection,
            explainRequest: explain,
            launchRequest: hasLaunchRequest(text),
            verifyRequest: verify,
            stagedBreakAndRepair: hasStagedBreakAndRepair(text),
            explicitFileTarget: hasExplicitFileTarget(raw),
            genericArtifactReference: hasGenericArtifactReference(text),
            newProjectScope: requestsNewProjectScope(text)
        )
    }

    static func suggestSiblingPath(
        from current: String?,
        knownArtifacts: Set<String>
    ) -> String? {
        guard let current else { return nil }

        let ns = current as NSString
        let ext = ns.pathExtension
        let filename = ns.lastPathComponent as NSString
        let stem = filename.deletingPathExtension
        let parent = ns.deletingLastPathComponent
        let relativeParent = parent == "." || parent == "/" ? "" : parent

        for index in 2...99 {
            let name = ext.isEmpty
                ? "\(stem)_\(index)"
                : "\(stem)_\(index).\(ext)"
            let candidate = relativeParent.isEmpty
                ? name
                : relativeParent + "/" + name
            if !knownArtifacts.contains(candidate) {
                return candidate
            }
        }

        let suffix = UUID().uuidString.prefix(6).lowercased()
        let name = ext.isEmpty
            ? "\(stem)_\(suffix)"
            : "\(stem)_\(suffix).\(ext)"
        return relativeParent.isEmpty ? name : relativeParent + "/" + name
    }

    static func asksMutationTruth(_ text: String) -> Bool {
        [
            "ты точно внес",
            "ты точно измен",
            "ты реально внес",
            "ты действительно внес",
            "ты это внес",
            "ты изменил файл",
            "ты изменила файл",
            "did you actually change",
            "did you really change",
            "did you modify the file"
        ].contains(where: text.contains)
    }

    private static func failureKind(_ text: String) -> FailureFeedbackKind {
        if [
            "ничего не помен",
            "ничего не измен",
            "изменений нет",
            "нет изменений",
            "все так же",
            "всё так же",
            "осталось так же",
            "не поменялось",
            "не изменилось",
            "не добавил",
            "не добавила",
            "не появилось",
            "там нет",
            "no changes",
            "nothing changed",
            "still the same",
            "didn't change",
            "did not change"
        ].contains(where: text.contains) {
            return .notChanged
        }

        if [
            "не открыл",
            "ничего не открыл",
            "не запуст",
            "didn't open",
            "did not open",
            "nothing opened",
            "didn't launch",
            "did not launch"
        ].contains(where: text.contains) {
            return .notLaunched
        }

        if [
            "не работает",
            "не сработ",
            "белый экран",
            "пустой экран",
            "черный экран",
            "ошибк",
            "баг",
            "глюч",
            "слом",
            "не получилось",
            "неправиль",
            "все еще",
            "всё ещё",
            "знак вопроса",
            "не загруз",
            "не отображ",
            "не видно",
            "крив",
            "съех",
            "лишн",
            "странн",
            "артефакт",
            "doesn't work",
            "does not work",
            "failed",
            "error",
            "bug",
            "broken",
            "wrong",
            "weird"
        ].contains(where: text.contains) {
            return .functional
        }

        return .none
    }

    private static func hasBareAction(_ text: String) -> Bool {
        let command = InputNormalizer.commandLexical(text)
        let exact: Set<String> = [
            "выполни", "сделай", "запусти", "открой", "повтори",
            "исправь", "почини", "попробуй еще раз", "еще раз",
            "внеси", "добавь", "обнови", "доработай",
            "редактируй", "редактируй его", "редактируй ее", "редактируй её",
            "правь", "продолжай",
            "do it", "run it", "open it", "fix it", "try again", "again"
        ]

        if exact.contains(command) { return true }

        return command.count <= 100 && [
            "выполни ", "запусти ", "открой ", "повтори ",
            "исправь ", "почини ", "сделай это", "внеси ",
            "добавь ", "обнови ", "доработай ", "редактируй ",
            "правь ", "продолжай ",
            "run it ", "open it ", "fix it "
        ].contains(where: command.hasPrefix)
    }

    private static func hasPriorReference(_ text: String) -> Bool {
        [
            "а где", "где сама", "где он", "где она",
            "его", "ее", "её", "это", "этот", "эта ", "эту",
            "там", "снова", "еще раз", "предыдущ", "только что", "тогда",
            "который ты", "которую ты", "в этот html", "в этом html",
            "эту страниц", "этой страниц", "новую", "новый", "новое",
            "it", "that", "there", "previous", "again", "same", "new one"
        ].contains(where: text.contains)
    }

    private static func hasStrongNewMarker(_ text: String) -> Bool {
        [
            "новый", "новую", "новое", "новом", "нового", "новой",
            "другой", "другую", "другом", "отдельный", "отдельную",
            "отдельном", "new", "another", "different"
        ].contains(where: text.contains)
    }

    private static func hasActionVerb(_ text: String) -> Bool {
        [
            "создай", "измени", "исправ", "почини", "удал", "запусти",
            "открой", "выполни", "сделай", "добавь", "внес", "доработ",
            "улучш", "обнов", "переработ", "сохрани", "перепиши",
            "редакт", "правь",
            "create", "edit", "fix", "run", "open", "execute", "improve",
            "update", "add", "do it"
        ].contains(where: text.contains)
    }

    private static func hasInspectionRequest(_ text: String) -> Bool {
        [
            "посмотри", "прочитай", "проанализ", "найди", "покажи",
            "inspect", "read", "review", "analy", "find", "search"
        ].contains(where: text.contains)
    }

    private static func hasExplainRequest(_ text: String) -> Bool {
        [
            "объясни", "что делает", "расскажи что делает",
            "explain", "what does"
        ].contains(where: text.contains)
    }

    private static func hasLaunchRequest(_ text: String) -> Bool {
        [
            "запусти", "запустить", "открой", "открыть", "выполни",
            "run", "launch", "open", "execute"
        ].contains(where: text.contains)
    }

    private static func hasVerifyRequest(_ text: String) -> Bool {
        [
            "проверь", "проверить", "протестируй", "тест", "убедись",
            "verify", "validate", "test", "check"
        ].contains(where: text.contains)
    }

    private static func hasStagedBreakAndRepair(_ text: String) -> Bool {
        let breakTerms = [
            "сломай", "внеси ошиб", "добавь ошиб", "сделай неправиль",
            "намеренно слом", "специально слом",
            "break it", "introduce a bug", "make it fail", "make it wrong"
        ]
        let repairTerms = [
            "исправ", "почини", "устрани ошиб", "repair", "fix", "correct"
        ]
        return breakTerms.contains(where: text.contains) &&
            repairTerms.contains(where: text.contains)
    }

    private static func hasCreateVerb(_ text: String) -> Bool {
        [
            "создай", "создать", "сделай новый", "сделай новую",
            "create", "make a new", "make new"
        ].contains(where: text.contains)
    }

    private static func hasRevisionRequest(_ text: String) -> Bool {
        if hasActionVerb(text) && [
            "измени", "исправ", "почини", "добавь", "внес", "доработ",
            "улучш", "обнов", "переработ", "перепиши", "удал", "замени",
            "рефактор", "сохрани",
            "редакт", "правь",
            "edit", "fix", "add", "improve", "update", "rewrite",
            "delete", "replace", "refactor", "save"
        ].contains(where: text.contains) {
            return true
        }

        return [
            "хочу чтобы", "я хочу чтобы", "хочу, чтобы", "сделай более",
            "сделай красив", "сделай мил", "не мило", "не красиво",
            "не нравится", "пусть будет", "хочу больше", "хочу меньше",
            "i want it to", "make it more", "make it less", "i don't like", "not enough"
        ].contains(where: text.contains)
    }

    private static func hasGenericArtifactReference(
        _ text: String
    ) -> Bool {
        [
            "любой файл", "любой html", "любой документ",
            "какой-нибудь файл", "какой нибудь файл",
            "какую-нибудь страницу", "какую нибудь страницу",
            "любой из файлов", "один из файлов",
            "any file", "any html", "any document", "one of the files"
        ].contains(where: text.contains)
    }

    private static func requestsNewProjectScope(_ text: String) -> Bool {
        [
            "новый проект", "новую папку проекта", "другой проект",
            "new project", "another project"
        ].contains(where: text.contains)
    }

    private static func hasExplicitFileTarget(_ value: String) -> Bool {
        let ns = value as NSString
        let pattern = #"(?i)(?:^|[\s`\"'«])((?:[\w.\-]+/)*[\w.\-]+\.(?:html?|swift|py|js|mjs|cjs|ts|tsx|jsx|json|ya?ml|toml|md|txt|css|scss|rs|go|java|kt|kts|cs|php|rb|sh|sql|pdf|png|jpe?g|gif|svg|app))(?:$|[\s`\"',.!?»:])"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        return regex.firstMatch(
            in: value,
            range: NSRange(location: 0, length: ns.length)
        ) != nil
    }
}

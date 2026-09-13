import Foundation
import MLXLMCommon

final class TurnController: @unchecked Sendable {
    private let model: ModelContainer
    private let timeoutSeconds: Int

    init(model: ModelContainer, timeoutSeconds: Int) {
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func decide(
        _ userText: String,
        sessionContext: String = ""
    ) async throws -> TurnDecision {
        if let fast = FastTurnRouter.decide(userText) {
            return fast
        }

        let session = ChatSession(
            model,
            instructions: SystemPrompt.controller,
            generateParameters: GenerateParameters(
                maxTokens: 8,
                temperature: 0.0,
                topP: 1.0,
                repetitionPenalty: 1.04,
                repetitionContextSize: 24
            )
        )

        let routedPrompt: String
        if sessionContext.isEmpty {
            routedPrompt = userText
        } else {
            routedPrompt = """
            \(sessionContext)

            CURRENT USER MESSAGE:
            \(userText)

            Classify the CURRENT USER MESSAGE, resolving short follow-ups against the session context.
            """
        }

        let responseStream = session.streamResponse(to: routedPrompt)
        let timeout = timeoutSeconds

        let raw = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var output = ""
                for try await chunk in responseStream { output += chunk }
                return output
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CLIError("turn controller timed out after \(timeout)s")
            }
            guard let value = try await group.next() else {
                throw CLIError("turn controller returned no decision")
            }
            group.cancelAll()
            return value
        }

        let upper = raw.uppercased()
        for mode in [TurnMode.mcpAgent, .mcpRead, .agent, .inspect, .chat] {
            if upper.contains(mode.rawValue) { return .forMode(mode, source: .model) }
        }
        return .forMode(.chat, source: .model)
    }
}

/// Zero-model-pass routing for high-confidence cases only.
/// Ambiguous input deliberately falls through to TurnController's tiny model pass.
enum FastTurnRouter {
    static func decide(_ original: String) -> TurnDecision? {
        let text = normalize(original)
        guard !text.isEmpty else { return .forMode(.chat, source: .fast) }
        let discourse = DiscourseResolver.analyze(original)

        // Explicit web/browser work is external even when the user does not know
        // or mention the MCP implementation. Never route it to local INSPECT,
        // which would incorrectly require observation of a project file.
        let externalWebIntent = containsAny(text, [
            "в интернете", "из интернета", "в сети", "онлайн", "в браузере",
            "открой сайт", "найди сайт", "internet", "online", "in browser",
            "on the web", "from the web", "web search"
        ])
        if externalWebIntent &&
           (discourse.actionVerb || containsAny(text, [
               "найди", "поищи", "покажи", "открой", "search", "find", "show", "open"
           ])) {
            return .forMode(.mcpAgent, source: .fast)
        }

        // Explicit MCP discovery is side-effect free and needs no classifier inference.
        if containsAny(text, ["mcp", "мсп"]) {
            let explicitInvocation = containsAny(text, [
                "через mcp", "через мсп", "using mcp", "via mcp"
            ])
            let explicitListRequest = containsAny(text, [
                "список mcp", "список сервер", "какие mcp", "mcp servers",
                "list mcp", "list servers"
            ])

            if explicitInvocation && !explicitListRequest {
                return .forMode(.mcpAgent, source: .fast)
            }

            if containsAny(text, [
                "покажи", "какие", "доступн", "список", "list", "show", "available",
                "tools", "servers", "сервер", "инструмент", "resources", "ресурс"
            ]) {
                return .forMode(.mcpRead, source: .fast)
            }
            if containsAny(text, [
                "создай", "измени", "отправ", "удал", "выполни", "сделай",
                "create", "update", "send", "delete", "execute", "call"
            ]) {
                return .forMode(.mcpAgent, source: .fast)
            }
        }

        // Identity / greetings / translation / general conversation: no project tools.
        if containsAny(text, [
            "кто тебя создал", "как тебя зовут", "расскажи о себе", "что ты умеешь",
            "привет", "hello", "hi ", "hallo", "übersetz", "переведи", "на немецком",
            "на английском", "объясни что такое", "что такое"
        ]) && !hasProjectTarget(text) {
            return .forMode(.chat, source: .fast)
        }

        // High-confidence project mutation requires both an action and a concrete
        // software/project target. This avoids routing "создай сказку" as AGENT.
        if discourse.actionVerb && hasProjectTarget(text) {
            return .forMode(.agent, source: .fast)
        }

        // High-confidence project inspection.
        if discourse.inspectVerb && hasProjectTarget(text) {
            return .forMode(.inspect, source: .fast)
        }

        return nil
    }

    private static func normalize(_ s: String) -> String {
        InputNormalizer.lexical(s)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func hasProjectTarget(_ text: String) -> Bool {
        if containsAny(text, [
            "проект", "репозитор", "код", "файл", "папк", "тест", "сборк", "git",
            "html", "страниц", "сайт", "скрипт", "приложен", "игр",
            "project", "repo", "code", "file", "folder", "test", "build",
            "page", "website", "script", "app", "game"
        ]) { return true }

        let extensions = [
            ".py", ".swift", ".rs", ".go", ".ts", ".tsx", ".js", ".jsx", ".json",
            ".yaml", ".yml", ".toml", ".md", ".txt", ".c", ".cpp", ".h", ".hpp",
            ".java", ".kt", ".kts", ".cs", ".php", ".rb", ".sh", ".sql", ".html",
            ".css", ".scss", ".vue", ".svelte", "package.json", "package.swift",
            "cargo.toml", "go.mod", "dockerfile"
        ]
        return extensions.contains { text.contains($0) } || text.contains("/") || text.contains("\\")
    }
}

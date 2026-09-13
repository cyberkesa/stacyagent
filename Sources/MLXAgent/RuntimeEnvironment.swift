import Foundation

struct RuntimeEnvironment: Sendable {
    let projectPath: String
    let osName: String
    let architecture: String
    let executables: [String: String]
    let shellEnvironment: [String: String]
    let projectProfile: ProjectProfile

    static func probe(projectURL: URL) -> RuntimeEnvironment {
        let process = ProcessInfo.processInfo
        var environment = process.environment
        let path = normalizedPATH(environment["PATH"])
        environment["PATH"] = path

        let directories = path.split(separator: ":").map(String.init)
        let names = [
            "python3", "python", "pip3", "pip",
            "node", "npm", "npx",
            "swift", "swiftc", "xcodebuild",
            "git", "rg", "cargo", "go",
            "ruby", "php", "java", "sh", "bash", "zsh", "open", "brew"
        ]

        let fm = FileManager.default
        var found: [String: String] = [:]
        found.reserveCapacity(names.count)

        for name in names {
            for directory in directories {
                let candidate = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name)
                    .path
                if fm.isExecutableFile(atPath: candidate) {
                    found[name] = candidate
                    break
                }
            }
        }

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        return RuntimeEnvironment(
            projectPath: projectURL.standardizedFileURL.path,
            osName: process.operatingSystemVersionString,
            architecture: architecture,
            executables: found,
            shellEnvironment: environment,
            projectProfile: ProjectProfile.scan(root: projectURL)
        )
    }

    var modelContext: String {
        let keys = [
            "python3", "node", "npm", "npx", "swift",
            "xcodebuild", "git", "rg", "open", "brew"
        ]

        let tools = keys.compactMap { key -> String? in
            guard let executable = executables[key] else { return nil }
            return "\(key)=\(executable)"
        }.joined(separator: ", ")

        return """
        Runtime facts (trusted; do not probe them again):
        cwd: \(projectPath)
        host: \(osName) \(architecture)
        executables: \(tools.isEmpty ? "none detected" : tools)

        \(projectProfile.promptContext)
        """
    }

    private static func normalizedPATH(_ existing: String?) -> String {
        var values = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        if let existing {
            for part in existing.split(separator: ":").map(String.init)
            where !values.contains(part) {
                values.append(part)
            }
        }

        return values.joined(separator: ":")
    }
}

enum DirectRuntimeRouter {
    static func answer(
        _ input: String,
        runtime: RuntimeEnvironment,
        mcpServers: String
    ) -> String? {
        let text = InputNormalizer.lexical(input)

        let cwdQueries = [
            "ты сейчас в какой папке",
            "в какой папке ты сейчас",
            "в какой ты папке",
            "в какой папке",
            "ты где сейчас",
            "где ты сейчас",
            "где ты находишься",
            "где находишься",
            "а где ты",
            "где ты зай",
            "текущая директория",
            "рабочая директория",
            "current directory",
            "working directory",
            "where are you now",
            "pwd"
        ]

        if cwdQueries.contains(where: text.contains) {
            return "Если ты про мою рабочую среду: я сейчас работаю в `\(runtime.projectPath)`."
        }

        let fileCapabilityTerms = [
            "можешь читать файл", "можешь читать файлы",
            "можешь изменять файл", "можешь изменять файлы",
            "можешь редактировать", "можешь править",
            "ты можешь видеть файлы", "ты можешь работать с файлами",
            "can you read files", "can you edit files", "can you modify files"
        ]

        if fileCapabilityTerms.contains(where: text.contains) ||
           text == "можешь" {
            return "Да. В рабочем проекте SLTA может читать, создавать и изменять файлы через runtime-инструменты. Эти действия считаются выполненными только после реального tool/evidence."
        }

        let isMCP = text.contains("mcp") || text.contains("мсп")
        let explicitMCPInvocation = [
            "через mcp", "через мсп", "using mcp", "via mcp"
        ].contains(where: text.contains)

        if isMCP,
           !explicitMCPInvocation,
           ["покажи", "какие", "доступн", "список", "available", "list", "servers", "сервер"]
            .contains(where: text.contains),
           !["подключи", "подключить", "добавь", "connect ", "configure "]
            .contains(where: text.contains) {
            return mcpServers == "no MCP servers configured"
                ? "Сейчас MCP-серверы не настроены."
                : "Подключённые MCP-серверы:\n\(mcpServers)"
        }

        if isMCP,
           ["подключи", "подключить", "добавь", "connect", "configure"]
            .contains(where: text.contains) {
            let concreteMarkers = [
                "github", "filesystem", "postgres", "playwright", "sqlite",
                "http://", "https://", "npx ", "uvx "
            ]
            let hasConcreteServer = concreteMarkers.contains(where: text.contains)

            if !hasConcreteServer {
                return "Могу подключить MCP, но нужны конкретные серверы или их команды/URL. Назови, какие именно MCP-серверы подключить."
            }
        }

        return nil
    }
}

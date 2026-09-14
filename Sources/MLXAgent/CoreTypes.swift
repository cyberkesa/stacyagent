import Foundation
import SLTACore

// CLIError теперь из SLTACore (enum SLTAError + typealias CLIError).
// Локальный struct удалён во избежание конфликта имён.

enum ApprovalMode: String, Sendable {
    case readOnly = "read-only"
    case workspace
    case full
}

struct AgentOptions: Sendable {
    var modelID = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
    var projectURL: URL
    var maxRounds = 12
    var chatMaxTokens: Int? = nil
    var agentMaxTokens: Int? = nil
    var generationTimeoutSeconds = 0
    var controllerTimeoutSeconds = 4
    var draftModelID: String? = nil
    var shellTimeoutSeconds = 120
    var approvalMode: ApprovalMode = .workspace
    var allowMCP = true

    static func parse(_ arguments: [String]) throws -> AgentOptions {
        let args = Array(arguments.dropFirst())
        var model = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
        var project: String?
        var maxRounds = 12
        var chatMaxTokens: Int?
        var agentMaxTokens: Int?
        var generationTimeout = 0
        var controllerTimeout = 4
        var draftModelID: String?
        var shellTimeout = 120
        var approvalMode: ApprovalMode = .workspace
        var allowMCP = true

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model":
                guard i + 1 < args.count else { throw CLIError("--model requires a value") }
                model = args[i + 1]
                i += 2
            case "--max-rounds":
                guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
                    throw CLIError("--max-rounds requires a positive integer")
                }
                maxRounds = value
                i += 2
            case "--max-tokens", "--agent-max-tokens":
                guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
                    throw CLIError("--agent-max-tokens requires a positive integer")
                }
                agentMaxTokens = value
                i += 2
            case "--chat-max-tokens":
                guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
                    throw CLIError("--chat-max-tokens requires a positive integer")
                }
                chatMaxTokens = value
                i += 2
            case "--controller-timeout":
                guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
                    throw CLIError("--controller-timeout requires seconds")
                }
                controllerTimeout = value
                i += 2
            case "--draft-model":
                guard i + 1 < args.count else {
                    throw CLIError("--draft-model requires a Hugging Face model id")
                }
                draftModelID = args[i + 1]
                i += 2
            case "--generation-timeout":
                guard i + 1 < args.count, let value = Int(args[i + 1]), value >= 0 else {
                    throw CLIError("--generation-timeout requires zero or a positive number of seconds")
                }
                generationTimeout = value
                i += 2
            case "--shell-timeout":
                guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
                    throw CLIError("--shell-timeout requires seconds")
                }
                shellTimeout = value
                i += 2
            case "--approval-mode":
                guard i + 1 < args.count, let value = ApprovalMode(rawValue: args[i + 1]) else {
                    throw CLIError("--approval-mode must be read-only, workspace, or full")
                }
                approvalMode = value
                i += 2
            case "--no-mcp":
                allowMCP = false
                i += 1
            case "--help", "-h":
                printHelp()
                exit(0)
            case "--cli":
                i += 1
            default:
                if args[i].hasPrefix("-") {
                    throw CLIError("Unknown option: \(args[i])")
                }
                if project != nil {
                    throw CLIError("Only one project path may be supplied")
                }
                project = args[i]
                i += 1
            }
        }

        let path = project ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw CLIError("Project directory does not exist: \(url.path)")
        }
        return AgentOptions(
            modelID: model,
            projectURL: url,
            maxRounds: maxRounds,
            chatMaxTokens: chatMaxTokens,
            agentMaxTokens: agentMaxTokens,
            generationTimeoutSeconds: generationTimeout,
            controllerTimeoutSeconds: controllerTimeout,
            draftModelID: draftModelID,
            shellTimeoutSeconds: shellTimeout,
            approvalMode: approvalMode,
            allowMCP: allowMCP
        )
    }

    static func printHelp() {
        print("""
        mlxagent [project-path] [options]

          --model <hf-id>               MLX model id
          --max-rounds <n>              Tool/recovery round backstop (default: 12)
          --agent-max-tokens <n>        Optional agent token ceiling (default: unlimited)
          --chat-max-tokens <n>         Optional chat token ceiling (default: unlimited)
          --generation-timeout <sec>    Optional stall watchdog; 0 disables (default: 0)
          --controller-timeout <sec>    Turn router watchdog (default: 4)
          --draft-model <hf-id>         Optional speculative-decoding draft model
          --shell-timeout <sec>         Shell timeout (default: 120)
          --approval-mode <mode>        read-only | workspace | full
          --no-mcp                      Disable MCP bridge
          --selftest                    Run runtime tests without loading the model
          -h, --help                    Show help
        """)
    }
}

enum RouteSource: String, Sendable {
    case direct
    case fast
    case model
}

struct GenerationStats: Sendable {
    var started = ContinuousClock.now
    var passes = 0
    var tools = 0
    var promptTokens = 0
    var outputTokens = 0
    var firstTokenSeconds: Double?
    var modelSeconds: Double = 0
    var toolSeconds: Double = 0
    var routerSeconds: Double = 0
    var promptTokensPerSecond: Double?
    var generationTokensPerSecond: Double?
    var routeSource: RouteSource?
    var taskStatus: String?
    private var finishedElapsed: Duration?

    var elapsed: Duration {
        finishedElapsed ?? (ContinuousClock.now - started)
    }

    mutating func finish() {
        if finishedElapsed == nil {
            finishedElapsed = ContinuousClock.now - started
        }
    }
}

struct ModelPassTelemetry: Sendable {
    var promptTokens: Int?
    var outputTokens: Int?
    var promptTokensPerSecond: Double?
    var generationTokensPerSecond: Double?
    var firstTokenSeconds: Double?
    var wallSeconds: Double
}

struct ValidationState: Sendable {
    var needsValidation = false
    var lastToolFailed = false
    var consecutiveToolFailures = 0
    var lastFailure: String?
    var lastMutation: String?
    var lastValidation: String?
}

enum TurnMode: String, Sendable, Codable {
    case chat = "CHAT"
    case inspect = "INSPECT"
    case agent = "AGENT"
    case mcpRead = "MCP_READ"
    case mcpAgent = "MCP_AGENT"
}

enum ToolCapability: String, Hashable, Sendable {
    case projectRead
    case projectWrite
    case shell
    case gitRead
    case mcpDiscover
    case mcpCall
    /// v0.30 structural semantic operations (rename). Granted with
    /// projectWrite for agent modes; gated by turn capabilities like the rest.
    case semantic
}

struct TurnDecision: Sendable {
    let mode: TurnMode
    let capabilities: Set<ToolCapability>
    let source: RouteSource

    static func forMode(_ mode: TurnMode, source: RouteSource = .model) -> TurnDecision {
        switch mode {
        case .chat:
            .init(mode: mode, capabilities: [], source: source)
        case .inspect:
            .init(mode: mode, capabilities: [.projectRead, .gitRead], source: source)
        case .agent, .mcpAgent:
            // Полный набор возможностей для кодинга и веб-поиска
            .init(mode: mode, capabilities: [.projectRead, .projectWrite, .shell, .gitRead, .mcpDiscover, .mcpCall, .semantic], source: source)
        case .mcpRead:
            .init(mode: mode, capabilities: [.mcpDiscover], source: source)
        }
    }
}

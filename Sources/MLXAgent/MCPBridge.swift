import Foundation
import MLXLMCommon

public struct MCPToolDescriptor: Sendable {
    public let server: String
    public let name: String
    public let description: String
    public let schema: MLXLMCommon.ToolSpec

    public init(server: String, name: String, description: String, schema: MLXLMCommon.ToolSpec) {
        self.server = server
        self.name = name
        self.description = description
        self.schema = schema
    }
}

struct MCPConfig: Codable, Sendable {
    struct Server: Codable, Sendable {
        let command: String
        var args: [String] = []
        var env: [String: String]? = nil
        var protocolVersion: String? = nil
    }

    var servers: [String: Server] = [:]

    enum CodingKeys: String, CodingKey {
        case servers
        case mcpServers
    }

    init(servers: [String: Server] = [:]) {
        self.servers = servers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let mcpServers = try container.decodeIfPresent([String: Server].self, forKey: .mcpServers) {
            self.servers = mcpServers
        } else if let servers = try container.decodeIfPresent([String: Server].self, forKey: .servers) {
            self.servers = servers
        } else {
            self.servers = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(servers, forKey: .mcpServers)
    }

    mutating func merge(with other: MCPConfig) {
        for (name, server) in other.servers where self.servers[name] == nil {
            self.servers[name] = server
        }
    }
}

struct MCPCallResult: Sendable {
    let rendered: String
    let urls: [String]
}

private final class MCPConnection: @unchecked Sendable {
    private let server: MCPConfig.Server
    private let lock = NSLock()
    private let errorLock = NSLock()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var readBuffer = Data()
    private var stderrTail = Data()
    private var nextID = 1

    init(server: MCPConfig.Server) { self.server = server }
    deinit { stop() }

    func request(method: String, params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning != true { try start() }
        return try sendRequest(method: method, params: params)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopUnlocked()
    }

    private func start() throws {
        stopUnlocked()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [server.command] + server.args

        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")

        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = "\(existing):\(commonPaths)"
        } else {
            environment["PATH"] = commonPaths
        }

        for (key, value) in server.env ?? [:] { environment[key] = value }
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.errorLock.withLock {
                self.stderrTail.append(data)
                if self.stderrTail.count > 16_384 {
                    self.stderrTail.removeFirst(self.stderrTail.count - 16_384)
                }
            }
        }

        try process.run()
        self.process = process
        self.input = input
        self.output = output
        self.errors = errors
        readBuffer.removeAll(keepingCapacity: true)
        stderrTail.removeAll(keepingCapacity: true)
        nextID = 1

        try performHandshake()
    }

    private func performHandshake() throws {
        let requestedVersion = server.protocolVersion ?? "2025-11-25"
        let fallbackVersion = "2024-11-05"

        do {
            _ = try sendRequest(method: "initialize", params: [
                "protocolVersion": requestedVersion,
                "capabilities": [:],
                "clientInfo": ["name": "SLTA", "version": "0.27"]
            ])
        } catch {
            if requestedVersion != fallbackVersion {
                _ = try sendRequest(method: "initialize", params: [
                    "protocolVersion": fallbackVersion,
                    "capabilities": [:],
                    "clientInfo": ["name": "SLTA", "version": "0.27"]
                ])
            } else {
                throw error
            }
        }

        try sendNotification(method: "notifications/initialized", params: nil)
    }

    private func sendRequest(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try writeMessage(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            let message = try readMessage()
            if Self.integerID(message["id"]) == id {
                if let error = message["error"] { throw CLIError("MCP error: \(error)") }
                return message
            }
            if message["method"] != nil, let serverID = message["id"] {
                try writeMessage([
                    "jsonrpc": "2.0", "id": serverID,
                    "error": ["code": -32601, "message": "Client method is not supported by SLTA"]
                ])
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        try writeMessage(message)
    }

    private func writeMessage(_ message: [String: Any]) throws {
        guard let input else { throw CLIError("MCP process is not running") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage() throws -> [String: Any] {
        guard let output else { throw CLIError("MCP process is not running") }
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CLIError("invalid MCP JSON-RPC response")
                }
                return object
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                let detail = errorLock.withLock {
                    String(decoding: stderrTail.suffix(2_000), as: UTF8.self)
                }
                stopUnlocked()
                throw CLIError("MCP response EOF \(detail.isEmpty ? "" : "stderr: " + detail)")
            }
            readBuffer.append(chunk)
        }
    }

    private func stopUnlocked() {
        errors?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        try? errors?.fileHandleForReading.close()

        if let proc = process, proc.isRunning {
            proc.terminate()
            let deadline = DispatchTime.now() + 1.0
            while proc.isRunning && DispatchTime.now() < deadline {
                usleep(50_000)
            }
        }
        process = nil
        input = nil
        output = nil
        errors = nil
        readBuffer.removeAll(keepingCapacity: false)
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

final class MCPBridge: @unchecked Sendable {
    private struct CachedTools { let value: String; let expiresAt: Date }
    private let config: MCPConfig
    private let policy: PolicyEngine
    private let fm = FileManager.default
    private let cacheLock = NSLock()
    private let connectionLock = NSLock()
    private var toolsCache: [String: CachedTools] = [:]
    private var connections: [String: MCPConnection] = [:]

    init(policy: PolicyEngine) {
        self.policy = policy
        let candidateURLs = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".slta/mcp.json"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".slta").appendingPathComponent("mcp.json"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".cursor").appendingPathComponent("mcp.json"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".mlxagent").appendingPathComponent("mcp.json")
        ]

        var mergedConfig = MCPConfig()
        for url in candidateURLs where fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONDecoder().decode(MCPConfig.self, from: data) {
                mergedConfig.merge(with: parsed)
            }
        }
        self.config = mergedConfig
    }

    init(policy: PolicyEngine, config: MCPConfig) {
        self.policy = policy
        self.config = config
    }

    deinit {
        let active = connectionLock.withLock { Array(connections.values) }
        for connection in active { connection.stop() }
    }

    var serverNames: [String] { config.servers.keys.sorted() }
    func listServers() -> String { serverNames.isEmpty ? "no MCP servers configured" : serverNames.joined(separator: "\n") }

    func discoverAllTools() -> [MCPToolDescriptor] {
        var descriptors: [MCPToolDescriptor] = []
        for server in serverNames {
            guard let response = try? request(server: server, method: "tools/list", params: [:]),
                  let result = response["result"] as? [String: Any],
                  let tools = result["tools"] as? [[String: Any]] else {
                continue
            }

            for tool in tools {
                guard let name = tool["name"] as? String else { continue }
                let desc = (tool["description"] as? String) ?? "MCP tool from \(server)"
                let rawSchema = (tool["inputSchema"] as? [String: Any]) ?? [
                    "type": "object",
                    "properties": [String: Any]()
                ]

                let sendableParams = rawSchema.mapValues { Self.toSendable($0) }

                let functionDict: [String: any Sendable] = [
                    "name": name,
                    "description": desc,
                    "parameters": sendableParams
                ]

                let spec: MLXLMCommon.ToolSpec = [
                    "type": "function",
                    "function": functionDict
                ]

                descriptors.append(MCPToolDescriptor(
                    server: server,
                    name: name,
                    description: desc,
                    schema: spec
                ))
            }
        }
        return descriptors
    }

    func callDirect(server: String, tool: String, arguments: [String: Any]) throws -> MCPCallResult {
        try policy.authorize(tool: tool, risk: .external)
        
        let resolvedTool = try resolveToolName(tool, on: server)
        var resolvedArguments = resolveArguments(arguments)

        if server.lowercased().contains("tavily") {
            resolvedArguments["include_images"] = true
        }

        var response = try request(server: server, method: "tools/call", params: [
            "name": resolvedTool,
            "arguments": resolvedArguments
        ])

        var result = response["result"] as? [String: Any] ?? [:]
        var isError = result["isError"] as? Bool == true
        var rendered = try Self.extractOrRender(result)

        if isError,
           let retry = try recoverPlaywrightTarget(
               server: server,
               tool: resolvedTool,
               arguments: resolvedArguments,
               failure: rendered
           ) {
            response = retry
            result = response["result"] as? [String: Any] ?? [:]
            isError = result["isError"] as? Bool == true
            rendered = try Self.extractOrRender(result)
        }

        if isError {
            throw CLIError("MCP tool '\(resolvedTool)' failure: \(rendered)")
        }

        return MCPCallResult(rendered: rendered, urls: Self.extractURLs(from: result))
    }

    private func recoverPlaywrightTarget(
        server: String,
        tool: String,
        arguments: [String: Any],
        failure: String
    ) throws -> [String: Any]? {
        let lowerFailure = failure.lowercased()
        guard server.lowercased().contains("playwright"),
              arguments["target"] != nil,
              lowerFailure.contains("does not match any elements") ||
                lowerFailure.contains("element not found") else {
            return nil
        }

        let snapshotResponse = try request(
            server: server,
            method: "tools/call",
            params: ["name": "browser_snapshot", "arguments": [:]]
        )
        let snapshotResult = snapshotResponse["result"] as? [String: Any] ?? [:]
        guard snapshotResult["isError"] as? Bool != true else { return nil }
        let snapshot = try Self.extractOrRender(snapshotResult)
        let pattern = #"\[ref=([A-Za-z0-9_-]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: snapshot,
                  range: NSRange(snapshot.startIndex..., in: snapshot)
              ),
              let refRange = Range(match.range(at: 1), in: snapshot) else {
            return nil
        }

        var retryArguments = arguments
        let ref = String(snapshot[refRange])
        retryArguments["target"] = ref
        retryArguments["ref"] = ref
        return try request(server: server, method: "tools/call", params: [
            "name": tool,
            "arguments": retryArguments
        ])
    }

    func listTools(server: String) throws -> String {
        try policy.authorize(tool: "mcp_list_tools", risk: .external)
        if let cached = cacheLock.withLock({ toolsCache[server] }), cached.expiresAt > Date() { return cached.value }

        let response = try request(server: server, method: "tools/list", params: [:])
        let result = response["result"] as? [String: Any] ?? [:]
        let rawTools = result["tools"] as? [[String: Any]] ?? []

        var lines: [String] = ["Available tools on server '\(server)':"]
        for t in rawTools {
            guard let name = t["name"] as? String else { continue }
            let desc = (t["description"] as? String)?.prefix(120) ?? "no description"
            lines.append("- TOOL NAME: \"\(name)\" — \(desc)")
        }
        lines.append("\nNote: When calling mcp_call, use the EXACT TOOL NAME from quotes.")
        let formatted = lines.joined(separator: "\n")

        cacheLock.withLock { toolsCache[server] = CachedTools(value: formatted, expiresAt: Date().addingTimeInterval(60)) }
        return formatted
    }

    func call(server: String, tool: String, argumentsJSON: String) throws -> MCPCallResult {
        try policy.authorize(tool: "mcp_call", risk: .external)
        let toolName = try Self.normalizedToolName(tool)
        let raw = argumentsJSON.data(using: .utf8) ?? Data()
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw CLIError("mcp_call arguments_json must be a JSON object")
        }
        return try callDirect(server: server, tool: toolName, arguments: object)
    }

    private func resolveToolName(_ requested: String, on server: String) throws -> String {
        if server.lowercased().contains("tavily") && (requested == "search" || requested == "web_search") {
            return "tavily_search"
        }

        guard let response = try? request(server: server, method: "tools/list", params: [:]),
              let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return requested
        }

        let availableNames = tools.compactMap { $0["name"] as? String }
        if availableNames.contains(requested) { return requested }

        let lower = requested.lowercased()
        if let match = availableNames.first(where: {
            $0.lowercased().hasSuffix("_\(lower)") || $0.lowercased().contains(lower)
        }) {
            return match
        }

        return requested
    }

    private func resolveArguments(_ args: [String: Any]) -> [String: Any] {
        var clean = args
        if clean["query"] == nil {
            if let alt = clean["q"] ?? clean["text"] ?? clean["search"] ?? clean["prompt"] {
                clean["query"] = alt
            }
        }
        if clean["url"] == nil {
            if let alt = clean["link"] ?? clean["uri"] ?? clean["href"] {
                clean["url"] = alt
            }
        }
        return clean
    }

    private static func toSendable(_ value: Any) -> any Sendable {
        if let dict = value as? [String: Any] {
            return dict.mapValues { toSendable($0) }
        }
        if let array = value as? [Any] {
            return array.map { toSendable($0) }
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number }
        if let bool = value as? Bool { return bool }
        return String(describing: value)
    }

    private func request(server name: String, method: String, params: [String: Any]) throws -> [String: Any] {
        guard let server = config.servers[name] else {
            throw CLIError("unknown MCP server: \(name)")
        }
        let connection = connectionLock.withLock { () -> MCPConnection in
            if let existing = connections[name] { return existing }
            let created = MCPConnection(server: server)
            connections[name] = created
            return created
        }
        return try connection.request(method: method, params: params)
    }

    private static func normalizedToolName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        let scalars = trimmed.unicodeScalars.prefix { allowed.contains($0) }
        let name = String(String.UnicodeScalarView(scalars))
        guard !name.isEmpty else {
            throw CLIError("mcp_call tool must start with a valid MCP tool name")
        }
        return name
    }

    private static func extractOrRender(_ result: [String: Any]) throws -> String {
        if let contentArray = result["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { item -> String? in
                let type = item["type"] as? String
                if type == "text", let text = item["text"] as? String {
                    return text
                } else if type == "image" {
                    return "[Image content]"
                } else if type == "resource", let res = item["resource"] as? [String: Any] {
                    return "[Resource: \(res["uri"] ?? "")]"
                }
                return nil
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n\n")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractURLs(from value: Any) -> [String] {
        var strings: [String] = []
        func collect(_ value: Any) {
            if let string = value as? String { strings.append(string); return }
            if let array = value as? [Any] { array.forEach(collect); return }
            if let object = value as? [String: Any] { object.values.forEach(collect) }
        }
        collect(value)
        let pattern = #"https?://[^\s\"'<>\)\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [String] = []
        for string in strings {
            let range = NSRange(string.startIndex..., in: string)
            for match in regex.matches(in: string, range: range) {
                guard let swiftRange = Range(match.range, in: string) else { continue }
                let url = String(string[swiftRange])
                if !found.contains(url) { found.append(url) }
            }
        }
        return found
    }
}

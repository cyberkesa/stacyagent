import Foundation
import SLTACore
import MLXLMCommon

final class ToolRegistry: @unchecked Sendable {
    let state = RuntimeState()

    private let workspace: Workspace
    private let mcp: MCPBridge
    private let events: EventBus
    private let runtime: RuntimeEnvironment

    private let listDirTool: Tool<PathInput, TextOutput>
    private let readFileTool: Tool<PathInput, TextOutput>
    private let readFileRangeTool: Tool<ReadFileRangeInput, TextOutput>
    private let writeFileTool: Tool<WriteFileInput, TextOutput>
    private let editFileTool: Tool<EditFileInput, TextOutput>
    private let editFileRangeTool: Tool<EditFileRangeInput, TextOutput>
    private let searchTool: Tool<SearchInput, TextOutput>
    private let shellTool: Tool<ShellInput, TextOutput>
    private let validateFileTool: Tool<PathInput, TextOutput>
    private let openFileTool: Tool<OpenFileInput, TextOutput>
    private let openURLTool: Tool<URLInput, TextOutput>
    private let gitStatusTool: Tool<EmptyInput, TextOutput>
    private let gitDiffTool: Tool<EmptyInput, TextOutput>
    private let mcpServersTool: Tool<EmptyInput, TextOutput>
    private let mcpListToolsTool: Tool<MCPServerInput, TextOutput>
    private let tavilySearchTool: Tool<TavilySearchInput, TextOutput>
    private let mcpCallTool: Tool<MCPCallInput, TextOutput>

    init(workspace: Workspace, mcp: MCPBridge, events: EventBus, runtime: RuntimeEnvironment) {
        self.workspace = workspace
        self.mcp = mcp
        self.events = events
        self.runtime = runtime

        listDirTool = Tool(
            name: "list_dir",
            description: "List entries in a directory inside the current project.",
            parameters: [
                .required("path", type: .string, description: "Project-relative directory path, usually .")
            ]
        ) { input in TextOutput(result: try workspace.listDir(input.path)) }

        readFileTool = Tool(
            name: "read_file",
            description: "Read a UTF-8 text file inside the current project.",
            parameters: [
                .required("path", type: .string, description: "Project-relative file path")
            ]
        ) { input in
            let content = try workspace.readFile(input.path)
            return TextOutput(
                result: NativeToolEnvelope.encodeRead(
                    path: input.path,
                    content: content
                )
            )
        }

        readFileRangeTool = Tool(
            name: "read_file_range",
            description: "Read only a 1-based inclusive line range from a UTF-8 project file. Prefer for localized work on larger files.",
            parameters: [
                .required("path", type: .string, description: "Project-relative file path"),
                .required("start_line", type: .double, description: "First line, 1-based inclusive"),
                .required("end_line", type: .double, description: "Last line, 1-based inclusive")
            ]
        ) { input in
            guard let startLine = Self.integralLine(input.start_line),
                  let endLine = Self.integralLine(input.end_line) else {
                throw CLIError("read_file_range requires whole-number line values")
            }
            let content = try workspace.readFileRange(
                input.path,
                startLine: startLine,
                endLine: endLine
            )
            return TextOutput(
                result: NativeToolEnvelope.encodeObservation(
                    path: input.path,
                    content: content
                )
            )
        }

        writeFileTool = Tool(
            name: "write_file",
            description: "Create or fully rewrite a text file. Content may be any programming language or text format.",
            parameters: [
                .required("path", type: .string, description: "Project-relative file path"),
                .required("content", type: .string, description: "Complete file contents, preserved exactly")
            ]
        ) { input in TextOutput(result: try workspace.writeFile(input.path, content: input.content)) }

        editFileTool = Tool(
            name: "edit_file",
            description: "Replace one unique text block in a project file. Formatting-only whitespace differences are accepted; ambiguous matches are rejected.",
            parameters: [
                .required("path", type: .string, description: "Project-relative file path"),
                .required("old", type: .string, description: "Unique exact text to replace"),
                .required("new", type: .string, description: "Replacement text")
            ]
        ) { input in TextOutput(result: try workspace.editFile(input.path, old: input.old, new: input.new)) }

        editFileRangeTool = Tool(
            name: "edit_file_range",
            description: "Replace a 1-based inclusive line range in a previously observed project file. Prefer when the exact line window is known.",
            parameters: [
                .required("path", type: .string, description: "Project-relative file path"),
                .required("start_line", type: .double, description: "First line, 1-based inclusive"),
                .required("end_line", type: .double, description: "Last line, 1-based inclusive"),
                .required("replacement", type: .string, description: "Replacement text for the selected lines")
            ]
        ) { input in
            guard let startLine = Self.integralLine(input.start_line),
                  let endLine = Self.integralLine(input.end_line) else {
                throw CLIError("edit_file_range requires whole-number line values")
            }
            return TextOutput(
                result: try workspace.editFileRange(
                    input.path,
                    startLine: startLine,
                    endLine: endLine,
                    replacement: input.replacement
                )
            )
        }

        searchTool = Tool(
            name: "search",
            description: "Search text recursively inside project files.",
            parameters: [
                .required("query", type: .string, description: "Text to search for"),
                .optional("path", type: .string, description: "Project-relative directory, default .")
            ]
        ) { input in TextOutput(result: try workspace.search(input.query, path: input.path ?? ".")) }

        shellTool = Tool(
            name: "shell",
            description: "Run a shell command in the project directory. Use for builds, tests, linters and project tooling.",
            parameters: [
                .required("command", type: .string, description: "Shell command")
            ]
        ) { input in TextOutput(result: try workspace.shell(input.command)) }

        validateFileTool = Tool(
            name: "validate_file",
            description: "Run deterministic validation for one supported source/data/web file without inventing a shell command. Use before generic shell when it fits.",
            parameters: [
                .required("path", type: .string, description: "Project-relative file path")
            ]
        ) { input in TextOutput(result: try workspace.validateFile(input.path)) }

        openFileTool = Tool(
            name: "open_file",
            description: "Open one existing project file on macOS, optionally in a user-requested installed application. Prefer this over shell for launching an artifact.",
            parameters: [
                .required("path", type: .string, description: "Project-relative file path"),
                .optional("application", type: .string, description: "Application name requested by the user, such as Visual Studio Code or TextEdit")
            ]
        ) { input in
            TextOutput(
                result: try workspace.openFile(
                    input.path,
                    application: input.application
                )
            )
        }

        openURLTool = Tool(
            name: "open_url",
            description: "Open one verified absolute http(s) URL in the macOS default browser.",
            parameters: [
                .required("url", type: .string, description: "Absolute http(s) URL previously obtained from trusted tool evidence")
            ]
        ) { input in TextOutput(result: try workspace.openURL(input.url)) }

        gitStatusTool = Tool(
            name: "git_status",
            description: "Show git status for the current project.",
            parameters: []
        ) { _ in TextOutput(result: try workspace.gitStatus()) }

        gitDiffTool = Tool(
            name: "git_diff",
            description: "Show the current project git diff.",
            parameters: []
        ) { _ in TextOutput(result: try workspace.gitDiff()) }

        let configuredServers = mcp.serverNames.joined(separator: ", ")

        mcpServersTool = Tool(
            name: "mcp_servers",
            description: "List configured MCP servers. Currently configured: [\(configuredServers)].",
            parameters: []
        ) { _ in TextOutput(result: mcp.listServers()) }

        mcpListToolsTool = Tool(
            name: "mcp_list_tools",
            description: "Discover tools exposed by an MCP server. Must choose from: [\(configuredServers)].",
            parameters: [
                .required("server", type: .string, description: "Configured MCP server name. One of: [\(configuredServers)]")
            ]
        ) { input in
            let resolvedServer = Self.resolveServer(input.server, in: mcp.serverNames)
            return TextOutput(result: try mcp.listTools(server: resolvedServer))
        }

        tavilySearchTool = Tool(
            name: "tavily_search",
            description: "Search the web and return real image URLs. Use for a requested photo or image before embedding it in a project file.",
            parameters: [
                .required("query", type: .string, description: "Specific image search query")
            ]
        ) { input in
            let call = try mcp.callDirect(
                server: "tavily",
                tool: "tavily_search",
                arguments: [
                    "query": input.query,
                    "include_images": true
                ]
            )
            return TextOutput(
                result: MCPToolEnvelope.encode(
                    server: "tavily",
                    tool: "tavily_search",
                    urls: call.urls,
                    content: call.rendered
                )
            )
        }

        mcpCallTool = Tool(
            name: "mcp_call",
            description: "Call a tool on an MCP server. Available servers: [\(configuredServers)]. Discover tool names with mcp_list_tools first.",
            parameters: [
                .required("server", type: .string, description: "Server name. Must be one of: [\(configuredServers)]"),
                .required("tool", type: .string, description: "Exact tool name discovered via mcp_list_tools"),
                .required("arguments_json", type: .string, description: "JSON object matching tool schema")
            ]
        ) { input in
            let resolvedServer = Self.resolveServer(input.server, in: mcp.serverNames)
            let call = try mcp.call(
                server: resolvedServer,
                tool: input.tool,
                argumentsJSON: input.arguments_json
            )
            return TextOutput(
                result: MCPToolEnvelope.encode(
                    server: resolvedServer,
                    tool: input.tool,
                    urls: call.urls,
                    content: call.rendered
                )
            )
        }
    }

    var schemas: [MLXLMCommon.ToolSpec] {
        [
            listDirTool.schema, readFileTool.schema, readFileRangeTool.schema,
            writeFileTool.schema, editFileTool.schema, editFileRangeTool.schema,
            searchTool.schema, shellTool.schema, validateFileTool.schema,
            openFileTool.schema, openURLTool.schema, gitStatusTool.schema, gitDiffTool.schema,
            mcpServersTool.schema, mcpListToolsTool.schema, tavilySearchTool.schema,
            mcpCallTool.schema
        ]
    }

    func allowedToolNames(for capabilities: Set<ToolCapability>) -> Set<String> {
        var names: Set<String> = []
        if capabilities.contains(.projectRead) {
            names.formUnion(["list_dir", "read_file", "read_file_range", "search"])
        }
        if capabilities.contains(.projectWrite) {
            names.formUnion(["write_file", "edit_file", "edit_file_range"])
        }
        if capabilities.contains(.shell) {
            names.formUnion(["shell", "validate_file", "open_file"])
        }
        if capabilities.contains(.gitRead) {
            names.formUnion(["git_status", "git_diff"])
        }
        if capabilities.contains(.mcpDiscover) {
            names.formUnion(["mcp_servers", "mcp_list_tools"])
        }
        if capabilities.contains(.mcpCall) {
            names.formUnion(["mcp_servers", "mcp_list_tools", "mcp_call", "tavily_search", "open_url"])
        }
        return names
    }

    func schemas(for capabilities: Set<ToolCapability>) -> [MLXLMCommon.ToolSpec] {
        schemas(named: allowedToolNames(for: capabilities))
    }

    func schemas(named allowed: Set<String>) -> [MLXLMCommon.ToolSpec] {
        allSchemas.compactMap { allowed.contains($0.0) ? $0.1 : nil }
    }

    /// All owned tool schemas in one place (shared by MLX-native and
    /// provider-independent boundaries).
    private var allSchemas: [(String, MLXLMCommon.ToolSpec)] {
        [
            (listDirTool.name, listDirTool.schema),
            (readFileTool.name, readFileTool.schema),
            (readFileRangeTool.name, readFileRangeTool.schema),
            (writeFileTool.name, writeFileTool.schema),
            (editFileTool.name, editFileTool.schema),
            (editFileRangeTool.name, editFileRangeTool.schema),
            (searchTool.name, searchTool.schema),
            (shellTool.name, shellTool.schema),
            (validateFileTool.name, validateFileTool.schema),
            (openFileTool.name, openFileTool.schema),
            (openURLTool.name, openURLTool.schema),
            (gitStatusTool.name, gitStatusTool.schema),
            (gitDiffTool.name, gitDiffTool.schema),
            (mcpServersTool.name, mcpServersTool.schema),
            (mcpListToolsTool.name, mcpListToolsTool.schema),
            (tavilySearchTool.name, tavilySearchTool.schema),
            (mcpCallTool.name, mcpCallTool.schema)
        ]
    }

    /// Model-independent tool schemas for the Runtime -> ModelProvider
    /// boundary. The MLX-native ToolSpec dicts are converted to plain
    /// JSON-Schema strings here (runtime side); providers convert back to
    /// their native format. No MLX types leak into ModelRequest.
    func providerToolSpecs(named allowed: Set<String>) -> [ProviderToolSpec] {
        allSchemas.compactMap { name, schema -> ProviderToolSpec? in
            guard allowed.contains(name) else { return nil }
            let function = schema["function"] as? [String: any Sendable]
            let description = function?["description"] as? String ?? ""
            var parametersJSON = #"{"type":"object","properties":{}}"#
            if let params = function?["parameters"] {
                let anyParams = Self.jsonCompatible(params)
                if JSONSerialization.isValidJSONObject(anyParams),
                   let data = try? JSONSerialization.data(withJSONObject: anyParams),
                   let text = String(data: data, encoding: .utf8) {
                    parametersJSON = text
                }
            }
            return ProviderToolSpec(name: name, description: description, parametersJSON: parametersJSON)
        }
    }

    private static func jsonCompatible(_ value: any Sendable) -> Any {
        if let dict = value as? [String: any Sendable] {
            return dict.mapValues { jsonCompatible($0) }
        }
        if let array = value as? [any Sendable] {
            return array.map { jsonCompatible($0) }
        }
        if let value = value as? String {
            return value
        }
        if let value = value as? Bool {
            return value
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value
        }
        return String(describing: value)
    }

    func execute(_ toolCall: MLXLMCommon.ToolCall, allowed: Set<String>) async -> String {
        let name = toolCall.function.name

        if (await state.taskSnapshot()).isComplete {
            return #"{"ok":true,"status":"task_already_complete","instruction":"Do not call more tools."}"#
        }

        guard allowed.contains(name) else {
            return #"{"ok":false,"error":"tool not granted for this turn"}"#
        }

        let protocolSnapshot = await state.taskSnapshot()
        if let reason = ProtocolEngine.blockReason(
            forTool: name,
            snapshot: protocolSnapshot
        ) {
            return #"{"ok":true,"status":"protocol_blocked","reason":"\#(escapeJSON(reason))","instruction":"Follow the runtime task order instead of repeating this tool."}"#
        }

        if SemanticToolCatalog.isMutating(name),
           let expected = protocolSnapshot.resolvedTargetPath,
           case .string(let supplied)? = toolCall.function.arguments["path"],
           supplied != expected {
            return #"{"ok":false,"error":"mutation target does not match the active task","expected":"\#(escapeJSON(expected))","supplied":"\#(escapeJSON(supplied))"}"#
        }

        let signature = name + ":" + String(describing: toolCall.function.arguments)
        let mutating = SemanticToolCatalog.isMutating(name)
        guard await state.mayExecute(signature: signature, mutating: mutating) else {
            return #"{"ok":true,"status":"already_satisfied_or_repeated","instruction":"Do not repeat this action. Finish the current user request."}"#
        }
        await state.toolStarted()
        await events.emit(.toolStarted(name: name))
        let start = ContinuousClock.now

        do {
            let result: String
            switch name {
            case listDirTool.name:
                result = try await toolCall.execute(with: listDirTool).toolResult
                await state.observation(name)

            case readFileTool.name:
                let raw = try await toolCall.execute(with: readFileTool).toolResult
                if let decoded = NativeToolEnvelope.decodeRead(raw) {
                    result = decoded.content
                    await state.readBack(
                        path: decoded.path,
                        content: decoded.content,
                        revisionID: graphRevisionID(for: decoded.path)
                    )
                } else {
                    result = raw
                    await state.observation(name)
                }

            case readFileRangeTool.name:
                let encoded = try await toolCall.execute(with: readFileRangeTool).toolResult
                if let decoded = NativeToolEnvelope.decodeObservation(encoded) {
                    result = decoded.content
                    await state.observation(
                        name,
                        path: decoded.path,
                        revisionID: graphRevisionID(for: decoded.path)
                    )
                } else {
                    result = encoded
                    await state.observation(name)
                }

            case writeFileTool.name:
                result = try await toolCall.execute(with: writeFileTool).toolResult
                let path = RuntimeState.pathFromMutationResult(result)
                await state.nativeMutation(
                    name,
                    result: result,
                    changed: !result.contains("unchanged "),
                    transaction: path.flatMap { workspace.latestEditReceipt(path: $0) },
                    revisionID: graphRevisionID(for: path)
                )

            case editFileTool.name:
                result = try await toolCall.execute(with: editFileTool).toolResult
                let path = RuntimeState.pathFromMutationResult(result)
                await state.nativeMutation(
                    name,
                    result: result,
                    changed: !result.contains("unchanged "),
                    transaction: path.flatMap { workspace.latestEditReceipt(path: $0) },
                    revisionID: graphRevisionID(for: path)
                )

            case editFileRangeTool.name:
                result = try await toolCall.execute(with: editFileRangeTool).toolResult
                let path = RuntimeState.pathFromMutationResult(result)
                await state.nativeMutation(
                    name,
                    result: result,
                    changed: !result.contains("unchanged "),
                    transaction: path.flatMap { workspace.latestEditReceipt(path: $0) },
                    revisionID: graphRevisionID(for: path)
                )

            case searchTool.name:
                result = try await toolCall.execute(with: searchTool).toolResult
                await state.observation(name)

            case shellTool.name:
                result = try await toolCall.execute(with: shellTool).toolResult
                await state.validationSuccess(name, isRealValidation: true)

            case validateFileTool.name:
                result = try await toolCall.execute(with: validateFileTool).toolResult
                await state.validationSuccess(name, isRealValidation: true)

            case openFileTool.name:
                result = try await toolCall.execute(with: openFileTool).toolResult
                await state.nativeLaunchSuccess(name, result: result)

            case openURLTool.name:
                result = try await toolCall.execute(with: openURLTool).toolResult
                let url = result.hasPrefix("opened URL ")
                    ? String(result.dropFirst("opened URL ".count))
                    : ""
                await state.externalSuccess(
                    name,
                    operation: "open_url",
                    urls: url.isEmpty ? [] : [url]
                )

            case gitStatusTool.name:
                result = try await toolCall.execute(with: gitStatusTool).toolResult
                await state.observation(name)

            case gitDiffTool.name:
                result = try await toolCall.execute(with: gitDiffTool).toolResult
                await state.observation(name)

            case mcpServersTool.name:
                result = try await toolCall.execute(with: mcpServersTool).toolResult
                await state.observation(name)

            case mcpListToolsTool.name:
                result = try await toolCall.execute(with: mcpListToolsTool).toolResult
                await state.observation(name)

            case tavilySearchTool.name:
                let encoded = try await toolCall.execute(with: tavilySearchTool).toolResult
                if let decoded = MCPToolEnvelope.decode(encoded) {
                    result = decoded.content
                    await state.externalSuccess(
                        name,
                        server: decoded.server,
                        operation: decoded.tool,
                        urls: decoded.urls
                    )
                } else {
                    result = encoded
                    await state.externalSuccess(name, server: "tavily", operation: "tavily_search")
                }

            case mcpCallTool.name:
                let encoded = try await toolCall.execute(with: mcpCallTool).toolResult
                if let decoded = MCPToolEnvelope.decode(encoded) {
                    result = decoded.content
                    await state.externalSuccess(
                        name,
                        server: decoded.server,
                        operation: decoded.tool,
                        urls: decoded.urls
                    )
                } else {
                    result = encoded
                    await state.externalSuccess(name)
                }

            default:
                throw CLIError("unknown tool: \(name)")
            }

            let elapsed = ContinuousClock.now - start
            await state.toolFinished(seconds: Self.seconds(elapsed))
            await state.setCurrentRevisions(workspace.graph.currentMap())
            await events.emit(.toolFinished(
                name: name,
                ok: true,
                detail: compact(result),
                duration: elapsed
            ))
            return result
        } catch {
            let message = String(describing: error)
            let recoverable = isRecoverableError(tool: name, message: message)

            if recoverable {
                await state.recoverableFailure(name, message: message)
            } else {
                await state.failure(name, message: message)
            }

            let elapsed = ContinuousClock.now - start
            await state.toolFinished(seconds: Self.seconds(elapsed))
            await state.setCurrentRevisions(workspace.graph.currentMap())
            await events.emit(.toolFinished(
                name: name,
                ok: false,
                detail: compact(message),
                duration: elapsed
            ))

            if recoverable {
                return #"{"error":"\#(escapeJSON(message))","ok":false,"retry":true}"#
            }

            return #"{"error":"\#(escapeJSON(message))","ok":false}"#
        }
    }

    func executeModelInvocations(
        _ invocations: [Qwen3CoderInvocation],
        allowed: Set<String>
    ) async -> [(name: String, result: String)] {
        var output: [(name: String, result: String)] = []
        output.reserveCapacity(invocations.count)

        for invocation in invocations {
            let before = await state.taskSnapshot()
            if before.isComplete || before.validation.lastToolFailed {
                break
            }

            let result = await executeModelInvocation(invocation, allowed: allowed)
            output.append((name: invocation.name, result: result))

            let after = await state.taskSnapshot()
            if after.isComplete || after.validation.lastToolFailed {
                break
            }

            let mutating = SemanticToolCatalog.isMutating(invocation.name)
            if mutating && ProtocolEngine.shouldYieldAfterMutation(after) {
                break
            }
        }
        return output
    }

    func executeModelInvocation(
        _ invocation: Qwen3CoderInvocation,
        allowed: Set<String>
    ) async -> String {
        await executeNormalized(
            NormalizedToolInvocation(
                name: invocation.name,
                arguments: invocation.arguments,
                source: .modelText
            ),
            allowed: allowed
        )
    }

    /// Runtime-boundary batch execution for provider-normalized invocations.
    /// Same stop semantics as the textual path: stop on completion/failure
    /// and yield after a mutation that requires re-observation.
    func executeInvocations(
        _ invocations: [NormalizedToolInvocation],
        allowed: Set<String>
    ) async -> [(name: String, result: String)] {
        var output: [(name: String, result: String)] = []
        output.reserveCapacity(invocations.count)

        for invocation in invocations {
            let before = await state.taskSnapshot()
            if before.isComplete || before.validation.lastToolFailed {
                break
            }

            let result = await executeNormalized(invocation, allowed: allowed)
            output.append((name: invocation.name, result: result))

            let after = await state.taskSnapshot()
            if after.isComplete || after.validation.lastToolFailed {
                break
            }

            let mutating = SemanticToolCatalog.isMutating(invocation.name)
            if mutating && ProtocolEngine.shouldYieldAfterMutation(after) {
                break
            }
        }
        return output
    }

    func executeNormalized(
        _ invocation: NormalizedToolInvocation,
        allowed: Set<String>
    ) async -> String {
        let name = invocation.name
        let args = invocation.arguments

        let before = await state.taskSnapshot()
        let taskID = before.spec.map { "\($0.id)" } ?? "no-task"
        if before.isComplete {
            return #"{"ok":true,"status":"task_already_complete","instruction":"Do not call more tools."}"#
        }

        guard allowed.contains(name) else {
            return #"{"ok":false,"error":"tool not granted for this turn"}"#
        }

        if let reason = ProtocolEngine.blockReason(forTool: name, snapshot: before) {
            return #"{"ok":true,"status":"protocol_blocked","reason":"\#(escapeJSON(reason))","instruction":"Follow runtime task order."}"#
        }


        if SemanticToolCatalog.isMutating(name),
           let expected = before.resolvedTargetPath,
           let supplied = args["path"],
           supplied != expected {
            return #"{"ok":false,"error":"mutation target does not match the active task","expected":"\#(escapeJSON(expected))","supplied":"\#(escapeJSON(supplied))"}"#
        }

        do {
            try validateInvocation(name: name, args: args)
        } catch {
            let message = String(describing: error)
            await state.toolStarted()
            await events.emit(.toolStarted(name: name))
            await state.failure(name, message: message)
            await events.emit(.toolFinished(name: name, ok: false, detail: compact(message), duration: .zero))
            return #"{"ok":false,"error":"\#(escapeJSON(message))","kind":"schema"}"#
        }

        let signature = invocation.signature
        let mutating = SemanticToolCatalog.isMutating(name)
        guard await state.mayExecute(signature: signature, mutating: mutating) else {
            return #"{"ok":true,"status":"already_satisfied_or_repeated","instruction":"Do not repeat this action."}"#
        }

        await state.toolStarted()
        await events.emit(.toolStarted(name: name))
        let start = ContinuousClock.now

        do {
            let result: String

            switch name {
            case "list_dir":
                result = try workspace.listDir(args["path"] ?? ".")
                await state.observation(name)

            case "read_file":
                guard let path = args["path"] else { throw CLIError("read_file requires path") }
                let readKey = workspace.canonicalKey(path)
                let readBefore = workspace.graph.currentRevisionID(path: readKey)
                result = try workspace.readFile(path)
                let readRev = workspace.graph.currentRevisionID(path: readKey)
                await state.readBack(path: path, content: result, revisionID: readRev)
                await emitExternalIfMoved(key: readKey, before: readBefore, taskID: taskID)
                await events.emit(.evidenceRecorded(taskID: taskID, kind: "observed", path: path))

            case "read_file_range":
                guard let path = args["path"],
                      let start = Self.integralLine(args["start_line"]),
                      let end = Self.integralLine(args["end_line"]) else {
                    throw CLIError("read_file_range requires path, start_line, end_line")
                }
                let rangeKey = workspace.canonicalKey(path)
                let rangeBefore = workspace.graph.currentRevisionID(path: rangeKey)
                result = try workspace.readFileRange(path, startLine: start, endLine: end)
                await state.observation(
                    name,
                    path: path,
                    revisionID: workspace.graph.currentRevisionID(path: rangeKey)
                )
                await emitExternalIfMoved(key: rangeKey, before: rangeBefore, taskID: taskID)
                await events.emit(.evidenceRecorded(taskID: taskID, kind: "observed", path: path))

            case "write_file":
                guard let path = args["path"], let content = args["content"] else {
                    throw CLIError("write_file requires path and content")
                }
                let writeKey = workspace.canonicalKey(path)
                let writeBefore = workspace.graph.currentRevisionID(path: writeKey)
                result = try workspace.writeFile(path, content: content)
                await state.mutation(
                    name,
                    path: path,
                    content: content,
                    changed: !result.contains("unchanged "),
                    transaction: workspace.latestEditReceipt(path: path),
                    revisionID: workspace.graph.currentRevisionID(path: writeKey)
                )
                await emitRevisionEvents(key: writeKey, before: writeBefore, taskID: taskID, kind: "mutation")

            case "edit_file":
                guard let path = args["path"],
                      let old = args["old"] ?? args["oldText"],
                      let new = args["new"] ?? args["newText"] else {
                    throw CLIError("edit_file requires path, old, new")
                }
                let editKey = workspace.canonicalKey(path)
                let editBefore = workspace.graph.currentRevisionID(path: editKey)
                result = try workspace.editFile(path, old: old, new: new)
                await state.mutation(
                    name,
                    path: path,
                    content: nil,
                    changed: !result.contains("unchanged "),
                    transaction: workspace.latestEditReceipt(path: path),
                    revisionID: workspace.graph.currentRevisionID(path: editKey)
                )
                await emitRevisionEvents(key: editKey, before: editBefore, taskID: taskID, kind: "mutation")

            case "edit_file_range":
                guard let path = args["path"],
                      let start = Self.integralLine(args["start_line"]),
                      let end = Self.integralLine(args["end_line"]),
                      let replacement = args["replacement"] else {
                    throw CLIError("edit_file_range requires path, start_line, end_line, replacement")
                }
                let rangeEditKey = workspace.canonicalKey(path)
                let rangeEditBefore = workspace.graph.currentRevisionID(path: rangeEditKey)
                result = try workspace.editFileRange(path, startLine: start, endLine: end, replacement: replacement)
                await state.mutation(
                    name,
                    path: path,
                    content: nil,
                    changed: !result.contains("unchanged "),
                    transaction: workspace.latestEditReceipt(path: path),
                    revisionID: workspace.graph.currentRevisionID(path: rangeEditKey)
                )
                await emitRevisionEvents(key: rangeEditKey, before: rangeEditBefore, taskID: taskID, kind: "mutation")

            case "search":
                guard let query = args["query"] else { throw CLIError("search requires query") }
                result = try workspace.search(query, path: args["path"] ?? ".")
                await state.observation(name)

            case "shell":
                guard let command = args["command"] else { throw CLIError("shell requires command") }
                result = try workspace.shell(command)
                await state.validationSuccess(name, isRealValidation: isValidationCommand(command))

            case "validate_file":
                guard let path = args["path"] else { throw CLIError("validate_file requires path") }
                let validateKey = workspace.canonicalKey(path)
                let validateBefore = workspace.graph.currentRevisionID(path: validateKey)
                result = try workspace.validateFile(path)
                await state.validationSuccess(
                    name,
                    isRealValidation: true,
                    path: path,
                    revisionID: workspace.graph.currentRevisionID(path: validateKey)
                )
                await emitExternalIfMoved(key: validateKey, before: validateBefore, taskID: taskID)
                await events.emit(.evidenceRecorded(taskID: taskID, kind: "validation", path: path))

            case "open_file":
                guard let path = args["path"] else { throw CLIError("open_file requires path") }
                result = try workspace.openFile(
                    path,
                    application: args["application"]
                )
                await state.launchSuccess(
                    name,
                    path: path,
                    revisionID: workspace.graph.currentRevisionID(path: workspace.canonicalKey(path))
                )
                await events.emit(.evidenceRecorded(taskID: taskID, kind: "launch", path: path))

            case "open_url":
                guard let url = args["url"] else { throw CLIError("open_url requires url") }
                result = try workspace.openURL(url)
                await state.externalSuccess(name, operation: "open_url", urls: [url])

            case "git_status":
                result = try workspace.gitStatus()
                await state.observation(name)

            case "git_diff":
                result = try workspace.gitDiff()
                await state.observation(name)

            case "mcp_servers":
                result = mcp.listServers()
                await state.observation(name)

            case "mcp_list_tools":
                guard let rawServer = args["server"] else { throw CLIError("mcp_list_tools requires server") }
                let server = Self.resolveServer(rawServer, in: mcp.serverNames)
                result = try mcp.listTools(server: server)
                await state.observation(name)

            case "tavily_search":
                let q = args["query"] ?? args["q"] ?? ""
                let call = try mcp.call(
                    server: "tavily",
                    tool: "tavily_search",
                    argumentsJSON: "{\"query\": \"\(escapeJSON(q))\", \"include_images\": true}"
                )
                result = call.rendered
                await state.externalSuccess(name, server: "tavily", operation: "tavily_search", urls: call.urls)

            case "mcp_call":
                guard let rawServer = args["server"], let tool = args["tool"] else {
                    throw CLIError("mcp_call requires server and tool")
                }
                let server = Self.resolveServer(rawServer, in: mcp.serverNames)
                let argumentsJSON = args["arguments_json"] ?? args["arguments"] ?? "{}"
                let call = try mcp.call(server: server, tool: tool, argumentsJSON: argumentsJSON)
                result = call.rendered
                await state.externalSuccess(name, server: server, operation: tool, urls: call.urls)

            default:
                throw CLIError("unknown tool: \(name)")
            }

            let elapsed = ContinuousClock.now - start
            await state.toolFinished(seconds: Self.seconds(elapsed))
            await state.setCurrentRevisions(workspace.graph.currentMap())
            await events.emit(.toolFinished(name: name, ok: true, detail: compact(result), duration: elapsed))
            // v0.28 runtime stream: mutation and validation evidence as
            // structured events (additive; existing UI ignores unknown cases
            // except TerminalUI's one-line arms).
            let doneTaskID = before.spec.map { "\($0.id)" } ?? "no-task"
            if SemanticToolCatalog.isMutating(name), let path = args["path"] {
                let tx = workspace.latestEditReceipt(path: path).map { "\($0)" } ?? compact(result)
                await events.emit(.proposalCreated(taskID: doneTaskID, path: path))
                await events.emit(.transactionApplied(taskID: doneTaskID, path: path, transaction: tx))
            } else if name == "validate_file", let path = args["path"] {
                await events.emit(.validationFinished(path: path, ok: true))
            }
            return result
        } catch {
            let message = String(describing: error)
            let recoverable = isRecoverableError(tool: name, message: message)

            if recoverable {
                await state.recoverableFailure(name, message: message)
            } else {
                await state.failure(name, message: message)
            }

            let elapsed = ContinuousClock.now - start
            await state.toolFinished(seconds: Self.seconds(elapsed))
            await state.setCurrentRevisions(workspace.graph.currentMap())
            await events.emit(.toolFinished(name: name, ok: false, detail: compact(message), duration: elapsed))
            if name == "validate_file" {
                await events.emit(.validationFinished(path: args["path"] ?? name, ok: false))
            }

            if recoverable {
                return #"{"ok":false,"error":"\#(escapeJSON(message))","retry":true}"#
            }
            return #"{"ok":false,"error":"\#(escapeJSON(message))"}"#
        }
    }

    /// RuntimeToolExecutor conformance: single-step deterministic drain.
    func advanceProtocol(allowed: Set<String>) async -> [(name: String, result: String)] {
        await advanceProtocol(allowed: allowed, maxActions: 8)
    }

    func advanceProtocol(
        allowed: Set<String>,
        maxActions: Int = 8
    ) async -> [(name: String, result: String)] {
        var output: [(name: String, result: String)] = []

        for _ in 0..<maxActions {
            let before = await state.taskSnapshot()
            let decision = ProtocolEngine.decision(for: before, allowed: allowed)

            guard case .deterministic(let action) = decision else { break }

            let invocation = action.normalizedInvocation
            let result = await executeNormalized(invocation, allowed: allowed)
            output.append((name: invocation.name, result: result))

            let after = await state.taskSnapshot()
            if after.isComplete || after.validation.lastToolFailed {
                break
            }
        }
        return output
    }

    func beginTask(_ text: String, decision: TurnDecision, continuity: TaskContinuity? = nil) async {
        let spec = TaskCompiler.compile(userText: text, decision: decision, continuity: continuity)
        workspace.beginTask(taskID: spec.id, constraints: spec.constraints)
        await state.beginTask(spec)
    }

    func taskSnapshot() async -> TaskRuntimeSnapshot {
        await state.taskSnapshot()
    }

    func editHistoryText(limit: Int = 20) -> String {
        workspace.editHistoryText(limit: limit)
    }

    func editDiffText(transactionPrefix: String? = nil) throws -> String {
        try workspace.editDiffText(transactionPrefix: transactionPrefix)
    }

    func revisionHistoryText(path: String, limit: Int = 30) -> String {
        workspace.revisionHistoryText(path: path, limit: limit)
    }

    func checkpointHistoryText(path: String? = nil, limit: Int = 30) -> String {
        workspace.checkpointHistoryText(path: path, limit: limit)
    }

    func createCheckpoint(path: String, label: String = "manual") throws -> String {
        try workspace.createCheckpoint(path, label: label)
    }

    func rollbackLastEdit(path: String) throws -> String {
        try workspace.rollbackLastEdit(path)
    }

    func restoreCheckpoint(prefix: String) throws -> String {
        try workspace.restoreCheckpoint(prefix)
    }

    func directAnswer(for text: String) -> String? {
        DirectRuntimeRouter.answer(text, runtime: runtime, mcpServers: mcp.listServers())
    }
    var runtimeContext: String { runtime.modelContext }
    var projectPath: String { runtime.projectPath }

    private static func resolveServer(_ raw: String, in available: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if available.contains(trimmed) { return trimmed }

        let lower = trimmed.lowercased()
        if let match = available.first(where: { $0.lowercased() == lower }) {
            return match
        }
        if let match = available.first(where: { $0.lowercased().contains(lower) || lower.contains($0.lowercased()) }) {
            return match
        }
        if lower.contains("search") || lower.contains("web") {
            if let s = available.first(where: { $0.contains("search") || $0.contains("tavily") }) { return s }
        }
        if lower.contains("browser") || lower.contains("page") || lower.contains("playwright") {
            if let s = available.first(where: { $0.contains("playwright") || $0.contains("browser") }) { return s }
        }
        return trimmed
    }

    private func isRecoverableError(tool: String, message: String) -> Bool {
        if tool == "mcp_call" || tool == "mcp_list_tools" || tool == "mcp_servers" || tool == "tavily_search" {
            return true
        }

        let lower = message.lowercased()
        if SemanticToolCatalog.isMutating(tool), lower.contains("artifact invariant violated") {
            return true
        }

        // v0.29.1 TOCTOU: base moved under us — retry on fresh observation.
        if SemanticToolCatalog.isMutating(tool), lower.contains("revision conflict") {
            return true
        }

        guard tool == "edit_file" || tool == "edit_file_range" else { return false }

        let markers = [
            "old text not found", "unique edit target not found", "old text is not unique", "file must be read before",
            "line range", "exceeds file line count", "invalid line range"
        ]
        return markers.contains(where: lower.contains)
    }

    private static func integralLine(_ value: Double) -> Int? {
        guard value.isFinite, value.rounded() == value, value >= 1, value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func integralLine(_ value: String?) -> Int? {
        guard let value, let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return integralLine(number)
    }

    private static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private func compact(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return String(one.prefix(160))
    }

    private func escapeJSON(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func isValidationCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        let markers = [
            "swift build", "swift test", "swiftc ", "xcodebuild",
            "python3 -m py_compile", "python -m py_compile", "pytest", "python3 -m pytest", "python -m pytest",
            "node --check", "npm test", "npm run test", "npm run build", "npm run lint",
            "npx tsc", "npx eslint", "cargo check", "cargo test", "go test", "go vet",
            "ruby -c", "php -l", "shellcheck "
        ]
        return markers.contains(where: lower.contains)
    }

    private func validateInvocation(name: String, args: [String: String]) throws {
        func require(_ key: String) throws {
            guard let value = args[key], !value.isEmpty else {
                throw CLIError("\(name) requires non-empty \(key)")
            }
        }

        switch name {
        case "list_dir":
            break
        case "read_file", "validate_file", "open_file":
            try require("path")
        case "open_url":
            try require("url")
        case "read_file_range":
            try require("path")
            try require("start_line")
            try require("end_line")
            guard Self.integralLine(args["start_line"]) != nil,
                  Self.integralLine(args["end_line"]) != nil else {
                throw CLIError("read_file_range requires integer start_line and end_line")
            }
        case "write_file":
            try require("path")
            guard args["content"] != nil else { throw CLIError("write_file requires content") }
        case "edit_file":
            try require("path")
            guard (args["old"] ?? args["oldText"]) != nil, (args["new"] ?? args["newText"]) != nil else {
                throw CLIError("edit_file requires path, old, new")
            }
        case "edit_file_range":
            try require("path")
            try require("start_line")
            try require("end_line")
            guard Self.integralLine(args["start_line"]) != nil,
                  Self.integralLine(args["end_line"]) != nil,
                  args["replacement"] != nil else {
                throw CLIError("edit_file_range requires integer start_line/end_line and replacement")
            }
        case "search":
            try require("query")
        case "shell":
            try require("command")
        case "git_status", "git_diff", "mcp_servers":
            break
        case "mcp_list_tools":
            try require("server")
        case "mcp_call":
            try require("server")
            try require("tool")
        case "tavily_search":
            break
        default:
            throw CLIError("unknown tool: \(name)")
        }
    }
}

// MARK: - v0.28 RuntimeToolExecutor conformance
//
// ToolRegistry IS the runtime-owned ToolExecutor. The coordinator talks to
// it only through this narrow protocol — never the reverse.

extension ToolRegistry: RuntimeToolExecutor {}

// MARK: - v0.29 revision threading + persistence

extension ToolRegistry {
    /// Current graph revision for a tool path argument (canonical key).
    private func graphRevisionID(for path: String?) -> ArtifactRevisionID? {
        guard let path else { return nil }
        return workspace.graph.currentRevisionID(path: workspace.canonicalKey(path))
    }

    /// External-change stream: read-only tools that observe a moved current
    /// revision caused by disk edits outside SLTA.
    fileprivate func emitExternalIfMoved(
        key: String,
        before: ArtifactRevisionID?,
        taskID: String
    ) async {
        let after = workspace.graph.currentRevisionID(path: key)
        if before != nil, before != after,
           workspace.graph.isExternalCurrent(path: key),
           let rev = after {
            await events.emit(.artifactExternalChangeDetected(path: key, revision: "\(rev)"))
            await events.emit(.evidenceBecameStale(taskID: taskID, path: key))
        }
    }

    /// Mutation stream: the graph pointer moved because of our own commit.
    fileprivate func emitRevisionEvents(
        key: String,
        before: ArtifactRevisionID?,
        taskID: String,
        kind: String
    ) async {
        let after = workspace.graph.currentRevisionID(path: key)
        await events.emit(.evidenceRecorded(taskID: taskID, kind: kind, path: key))
        if before != after, let rev = after {
            await events.emit(.artifactRevisionCreated(taskID: taskID, path: key, revision: "\(rev)"))
        }
    }

    /// Persist versioned runtime truth (graph + journal + task) for restart.
    func persistRuntime() async {
        await state.setCurrentRevisions(workspace.graph.currentMap())
        let snap = await state.taskSnapshot()
        let records = await state.journalRecords()
        let store = RuntimePersistence(projectPath: runtime.projectPath)
        // v0.29.1 retention: pin journal+transaction+checkpoint revisions
        // BEFORE the graph snapshot, so referenced metadata is always carried.
        workspace.graph.retain(pinned: workspace.pinnedRevisionIDs(
            journal: records,
            current: snap.artifactRevisions
        ))
        let graphSnap = workspace.graph.snapshot(revisionProvider: { [workspace] id in
            workspace.revisionRecord(id)
        })
        let persisted = PersistedRuntimeState(
            schemaVersion: RuntimePersistence.schemaVersion,
            projectID: store.directory.lastPathComponent,
            projectPath: runtime.projectPath,
            savedAt: Date(),
            spec: snap.spec,
            requirements: snap.requirements,
            records: records,
            itemRevisions: records.map { $0.revisionID },
            current: snap.artifactRevisions.mapValues { $0.rawValue },
            lastFailure: snap.validation.lastFailure,
            artifacts: graphSnap
        )
        store.save(persisted)
        await events.emit(.runtimeStatePersisted(projectID: persisted.projectID))
    }

    /// Restore persisted truth after restart. Returns false when no usable
    /// snapshot exists (fresh start). Validation freshness is recomputed
    /// from the restored graph — never claimed for non-current revisions.
    @discardableResult
    func restoreRuntime() async -> Bool {
        let store = RuntimePersistence(projectPath: runtime.projectPath)
        guard let persisted = store.load() else { return false }
        workspace.graph.restore(persisted.artifacts)
        var items: [TaskEvidence] = []
        items.reserveCapacity(persisted.records.count)
        for record in persisted.records {
            let tx: EditTransactionRef? = record.kind == .mutation
                ? record.path.flatMap { workspace.latestEditReceipt(path: $0) }
                : nil
            items.append(record.legacyEvidence(transaction: tx))
        }
        let revs = persisted.itemRevisions.map { $0.map(ArtifactRevisionID.init) }
        let current = persisted.current.mapValues { ArtifactRevisionID($0) }
        await state.restore(
            spec: persisted.spec,
            requirements: persisted.requirements,
            items: items,
            itemRevisions: revs,
            records: persisted.records,
            current: current,
            lastFailure: persisted.lastFailure
        )
        await events.emit(.runtimeStateRestored(projectID: persisted.projectID))
        return true
    }
}

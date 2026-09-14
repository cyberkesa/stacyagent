import Foundation

enum SemanticToolRole: String, Hashable, Sendable {
    case observe
    case mutate
    case validate
    case launch
    case external
    /// v0.30 structural operations (rename): runtime-gated, index-resolved,
    /// never blocked by observation ordering (no observation needed).
    case semantic
}

enum SemanticCachePolicy: String, Sendable {
    case taskLocal
    case none
}

struct SemanticToolDescriptor: Sendable {
    let name: String
    let role: SemanticToolRole
    let deterministic: Bool
    let cachePolicy: SemanticCachePolicy
    let parallelizable: Bool
    let requiresObservedTargetBeforeMutation: Bool
}

enum ToolInvocationSource: String, Sendable {
    case modelText
    case protocolEngine
    /// Normalized invocation produced by a ModelProvider (any backend).
    /// Provider-specific formats must be converted before crossing the boundary.
    case provider
}

struct NormalizedToolInvocation: Sendable {
    let name: String
    let arguments: [String: String]
    let source: ToolInvocationSource

    var signature: String {
        name + ":" + arguments.keys.sorted().map {
            $0 + "=" + (arguments[$0] ?? "")
        }.joined(separator: "|")
    }
}


/// Small private transport envelope used only between MLX's typed Tool closure and
/// ToolRegistry. It preserves the concrete path of a native `read_file` call without
/// reflecting over MLXLMCommon.ToolCall argument internals. The envelope is stripped
/// before the tool result is returned to the model.
enum NativeToolEnvelope {
    private static let readPrefix = "__SLTA_NATIVE_READ_V1__"
    private static let observationPrefix = "__SLTA_NATIVE_OBSERVE_V1__"

    static func encodeRead(path: String, content: String) -> String {
        encode(prefix: readPrefix, path: path, content: content)
    }

    static func encodeObservation(path: String, content: String) -> String {
        encode(prefix: observationPrefix, path: path, content: content)
    }

    static func decodeRead(_ value: String) -> (path: String, content: String)? {
        decode(prefix: readPrefix, value: value)
    }

    static func decodeObservation(_ value: String) -> (path: String, content: String)? {
        decode(prefix: observationPrefix, value: value)
    }

    private static func encode(
        prefix: String,
        path: String,
        content: String
    ) -> String {
        let encodedPath = Data(path.utf8).base64EncodedString()
        return prefix + encodedPath + "\n" + content
    }

    private static func decode(
        prefix: String,
        value: String
    ) -> (path: String, content: String)? {
        guard value.hasPrefix(prefix),
              let newline = value.firstIndex(of: "\n") else {
            return nil
        }

        let pathStart = value.index(value.startIndex, offsetBy: prefix.count)
        let encodedPath = String(value[pathStart..<newline])
        guard let data = Data(base64Encoded: encodedPath),
              let path = String(data: data, encoding: .utf8) else {
            return nil
        }

        let contentStart = value.index(after: newline)
        return (path, String(value[contentStart...]))
    }
}

enum MCPToolEnvelope {
    private static let prefix = "__SLTA_MCP_RESULT_V1__"

    static func encode(
        server: String,
        tool: String,
        urls: [String],
        content: String
    ) -> String {
        let metadata: [String: Any] = [
            "server": server,
            "tool": tool,
            "urls": urls
        ]
        let data = (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data("{}".utf8)
        return prefix + data.base64EncodedString() + "\n" + content
    }

    static func decode(
        _ value: String
    ) -> (server: String, tool: String, urls: [String], content: String)? {
        guard value.hasPrefix(prefix),
              let newline = value.firstIndex(of: "\n") else { return nil }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        guard let data = Data(base64Encoded: String(value[start..<newline])),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = metadata["server"] as? String,
              let tool = metadata["tool"] as? String else { return nil }
        let contentStart = value.index(after: newline)
        return (
            server,
            tool,
            metadata["urls"] as? [String] ?? [],
            String(value[contentStart...])
        )
    }
}

enum SemanticToolCatalog {
    static let deterministicFileValidationExtensions: Set<String> = [
        "html", "htm",
        "json",
        "py",
        "js", "mjs", "cjs",
        "swift",
        "rb",
        "php",
        "sh", "bash", "zsh"
    ]

    private static let descriptors: [String: SemanticToolDescriptor] = {
        let values: [SemanticToolDescriptor] = [
            .init(
                name: "list_dir",
                role: .observe,
                deterministic: true,
                cachePolicy: .taskLocal,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "read_file",
                role: .observe,
                deterministic: true,
                cachePolicy: .taskLocal,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "read_file_range",
                role: .observe,
                deterministic: true,
                cachePolicy: .taskLocal,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "search",
                role: .observe,
                deterministic: true,
                cachePolicy: .taskLocal,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "write_file",
                role: .mutate,
                deterministic: true,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "edit_file",
                role: .mutate,
                deterministic: true,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: true
            ),
            .init(
                name: "edit_file_range",
                role: .mutate,
                deterministic: true,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: true
            ),
            .init(
                name: "validate_file",
                role: .validate,
                deterministic: true,
                cachePolicy: .none,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "shell",
                role: .validate,
                deterministic: false,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "open_file",
                role: .launch,
                deterministic: true,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "git_status",
                role: .observe,
                deterministic: true,
                cachePolicy: .taskLocal,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "git_diff",
                role: .observe,
                deterministic: true,
                cachePolicy: .taskLocal,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "mcp_servers",
                role: .external,
                deterministic: true,
                cachePolicy: .taskLocal,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "mcp_list_tools",
                role: .external,
                deterministic: true,
                cachePolicy: .taskLocal,
                parallelizable: true,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "mcp_call",
                role: .external,
                deterministic: false,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "tavily_search",
                role: .external,
                deterministic: false,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "open_url",
                role: .external,
                deterministic: true,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: false
            ),
            .init(
                name: "semantic_rename",
                role: .semantic,
                deterministic: true,
                cachePolicy: .none,
                parallelizable: false,
                requiresObservedTargetBeforeMutation: false
            )
        ]

        return Dictionary(
            uniqueKeysWithValues: values.map { ($0.name, $0) }
        )
    }()

    static func descriptor(_ name: String) -> SemanticToolDescriptor? {
        descriptors[name]
    }

    static func names(
        withRole role: SemanticToolRole,
        allowed: Set<String>
    ) -> Set<String> {
        Set(
            allowed.filter {
                descriptors[$0]?.role == role
            }
        )
    }

    static func supportsDeterministicFileValidation(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path)
            .pathExtension
            .lowercased()
        return deterministicFileValidationExtensions.contains(ext)
    }

    static func isMutating(_ name: String) -> Bool {
        descriptors[name]?.role == .mutate
    }

    static func isValidation(_ name: String) -> Bool {
        descriptors[name]?.role == .validate
    }

    static func isLaunch(_ name: String) -> Bool {
        descriptors[name]?.role == .launch
    }
}

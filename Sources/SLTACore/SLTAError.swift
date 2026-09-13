import Foundation

/// Типизированные ошибки SLTA. Замена строковым `CLIError("...")`.
public enum SLTAError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case invalidOption(String)
    case projectNotFound(String)
    case fileNotFound(String)
    case isDirectory(String)
    case fileTooLarge(path: String, limit: Int)
    case invalidRange(String)
    case policyDenied(tool: String, reason: String)
    case toolFailed(tool: String, underlying: String)
    case shellFailed(status: Int32, output: String)
    case executableMissing(String)
    case revisionConflict(String)
    case mcp(String)
    case model(String)
    case persistence(String)
    case io(String)

    public var description: String {
        switch self {
        case .invalidOption(let s): return s
        case .projectNotFound(let s): return "Project directory does not exist: \(s)"
        case .fileNotFound(let s): return "file not found: \(s)"
        case .isDirectory(let s): return "path is a directory: \(s)"
        case .fileTooLarge(let p, let l): return "file too large (>\(l) B): \(p)"
        case .invalidRange(let s): return "invalid line range: \(s)"
        case .policyDenied(let t, let r): return "policy denied \(t): \(r)"
        case .toolFailed(let t, let u): return "\(t) failed: \(u)"
        case .shellFailed(let st, let o): return "shell exit=\(st)\n\(o)"
        case .executableMissing(let s): return "\(s) is not available"
        case .revisionConflict(let s): return "revision conflict (recoverable): \(s)"
        case .mcp(let s): return "MCP: \(s)"
        case .model(let s): return "model: \(s)"
        case .persistence(let s): return "persistence: \(s)"
        case .io(let s): return s
        }
    }

    public var errorDescription: String? { description }
}

/// Совместимость: старый строковый тип остаётся алиасом новых кейсов.
public typealias CLIError = SLTAError

public extension SLTAError {
    /// Совместимость со старым `CLIError("текст")`.
    init(_ message: String) { self = .io(message) }
    static func cli(_ message: String) -> SLTAError { .io(message) }
}

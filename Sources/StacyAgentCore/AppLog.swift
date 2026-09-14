import Foundation
import os

/// Единый логгер вместо разрозненных print/fputs/try?.
public enum AppLog {
    private static let subsystem = "ai.stacyagent.mlxagent"
    private static let persistence = Logger(subsystem: subsystem, category: "persistence")
    private static let workspace = Logger(subsystem: subsystem, category: "workspace")
    private static let mcp = Logger(subsystem: subsystem, category: "mcp")
    private static let model = Logger(subsystem: subsystem, category: "model")

    public static func persistenceError(_ message: String) {
        persistence.error("\(message, privacy: .public)")
        fputs("Stacy Agent persistence: \(message)\n", stderr)
    }

    public static func workspaceError(_ message: String) {
        workspace.error("\(message, privacy: .public)")
    }

    public static func mcpError(_ message: String) {
        mcp.error("\(message, privacy: .public)")
    }

    public static func modelError(_ message: String) {
        model.error("\(message, privacy: .public)")
    }

    public static func info(_ message: String) {
        workspace.info("\(message, privacy: .public)")
    }
}

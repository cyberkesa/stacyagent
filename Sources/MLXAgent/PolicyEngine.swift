import Foundation
import SLTACore

enum ToolRisk: Sendable {
    case read
    case write
    case shell
    case external
}

struct PolicyEngine: Sendable {
    let mode: ApprovalMode
    let allowMCP: Bool

    func authorize(tool: String, risk: ToolRisk) throws {
        switch (mode, risk) {
        case (_, .read):
            return
        case (.readOnly, _):
            throw CLIError("policy denied \(tool) in read-only mode")
        case (.workspace, .write), (.workspace, .shell):
            return
        case (.workspace, .external):
            if allowMCP { return }
            throw CLIError("MCP is disabled")
        case (.full, _):
            return
        }
    }

    func validateShell(_ command: String) throws {
        let lower = command.lowercased()
        let blocked = [
            "sudo ", "rm -rf /", "rm -rf ~", "git reset --hard", "git clean -fd",
            "mkfs", "diskutil erase", "shutdown", "reboot", ":(){", "dd if="
        ]
        if blocked.contains(where: lower.contains) {
            throw CLIError("blocked dangerous shell command")
        }
        if mode != .full && command.contains("../") {
            throw CLIError("shell command contains ../ and is outside workspace policy")
        }
    }
}

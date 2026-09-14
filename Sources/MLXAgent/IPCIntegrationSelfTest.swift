import Foundation
import SLTAIPC

struct IPCCheckResult {
    var passed: Bool
    var name: String
}

enum IPCIntegrationSelfTest {
    static func runAll() async -> [IPCCheckResult] {
        var output: [IPCCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            output.append(IPCCheckResult(passed: passed, name: name))
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("slta-runtime-integration-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data("struct UserManager {}\nlet marker = \"TODO\"\n".utf8)
                .write(to: workspace.appendingPathComponent("A.swift"))
            try Data("let manager = UserManager()\n".utf8)
                .write(to: workspace.appendingPathComponent("B.swift"))
        } catch {
            return [IPCCheckResult(passed: false, name: "ipc fixture setup")]
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        if let fake = RuntimeServiceHost.configureFakeCodeIntelligence(workspaceURL: workspace),
           let result = try? await fake.query(.workspaceSymbols("UserManager")),
           case .workspaceSymbols(let symbols) = result {
            record(symbols.count == 1, "ipc-H0 fake semantic fixture has one symbol")
        } else {
            record(false, "ipc-H0 fake semantic fixture setup")
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let launcher = executable.deletingLastPathComponent().appendingPathComponent("slta-runtime")
        let process = Process()
        process.executableURL = launcher
        process.arguments = [workspace.path, "--fake-runtime", "--no-mcp"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let client = RuntimeClient(workspaceURL: workspace)
            var connected = false
            for _ in 0..<100 {
                if (try? await client.connect(clientName: "ipc-selftest")) != nil {
                    connected = true
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            record(connected, "ipc-F process handshake")
            guard connected else {
                process.terminate()
                return output
            }

            let opened = try await client.openWorkspace()
            record(
                opened?.workspaceID == WorkspaceIdentity.stableID(for: workspace),
                "ipc-F handshake then snapshot"
            )

            let literal = try await client.submit("Find exact string \"TODO\" in project files.")
            record(
                literal?.taskOutcome == "completed" &&
                literal?.telemetry.modelCalls == 0,
                "ipc-G literal task uses zero model calls"
            )

            let rename = try await client.submit("rename UserManager to AccountManager in A.swift")
            let renamedA = try String(
                contentsOf: workspace.appendingPathComponent("A.swift"), encoding: .utf8
            )
            let renamedB = try String(
                contentsOf: workspace.appendingPathComponent("B.swift"), encoding: .utf8
            )
            record(rename?.taskOutcome == "completed", "ipc-H1 semantic rename completes")
            record(rename?.telemetry.modelCalls == 0, "ipc-H2 semantic rename uses zero model calls")
            record(
                rename?.lastFailure == nil,
                "ipc-H3 semantic rename has no runtime failure"
            )
            record(
                !renamedA.contains("UserManager") && !renamedB.contains("UserManager"),
                "ipc-H4 semantic rename changes all references"
            )

            let reasoning = try await client.submit("Explain the architecture of this project.")
            record(reasoning?.taskOutcome == "completed", "ipc-I1 intelligence completes")
            record(
                reasoning?.telemetry.modelCalls == 1,
                "ipc-I2 intelligence uses exactly one model call"
            )
            record(
                (reasoning?.telemetry.contextTokens ?? 0) > 0,
                "ipc-I3 intelligence receives ContextEngine bundle"
            )

            client.close()
            let reconnected = RuntimeClient(workspaceURL: workspace)
            try await reconnected.connect(clientName: "ipc-reconnect")
            let restored = try await reconnected.snapshot()
            record(
                restored.recentTaskSummary?.contains("Explain") == true,
                "ipc-J1 reconnect restores recent task"
            )
            record(
                restored.telemetry.modelCalls == 1,
                "ipc-J2 reconnect restores telemetry"
            )

            let blockedSubmit = Task { try await reconnected.submit("__ipc_test_block__") }
            var activeID: String?
            for _ in 0..<40 where activeID == nil {
                try await Task.sleep(for: .milliseconds(25))
                let observer = RuntimeClient(workspaceURL: workspace)
                if (try? await observer.connect(clientName: "cancel-observer")) != nil {
                    activeID = try? await observer.snapshot().activeTaskID
                    observer.close()
                }
            }
            let cancelStart = ContinuousClock.now
            if let activeID {
                try await reconnected.cancel(taskID: activeID)
            }
            _ = try? await blockedSubmit.value
            let cancelElapsed = ContinuousClock.now - cancelStart
            try await reconnected.ping()
            record(
                activeID != nil && cancelElapsed < .seconds(2),
                "ipc-M cancellation is bounded and runtime remains usable"
            )

            try await reconnected.shutdown()
            reconnected.close()
            process.waitUntilExit()
            record(process.terminationStatus == 0, "ipc integration clean shutdown")
        } catch {
            if process.isRunning { process.terminate() }
            record(false, "ipc integration: \(error)")
        }
        return output
    }
}

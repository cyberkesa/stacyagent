import Foundation
import AppKit
import SwiftUI
import SLTAIPC

@main
@MainActor
struct MLXAgentMain {
    static func main() {
        if CommandLine.arguments.contains("--ipc-integration") {
            let completion = DispatchSemaphore(value: 0)
            Task.detached {
                let results = await IPCIntegrationSelfTest.runAll()
                let failed = results.filter { !$0.passed }
                if failed.isEmpty {
                    print("SLTA IPC integration: PASS \(results.count)/\(results.count)")
                } else {
                    print("SLTA IPC integration: FAIL \(results.count - failed.count)/\(results.count) · " + failed.map(\.name).joined(separator: "; "))
                }
                completion.signal()
            }
            completion.wait()
            return
        }
        if CommandLine.arguments.contains("--runtime-service") {
            runRuntimeServiceMode()
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            let completion = DispatchSemaphore(value: 0)
            Task.detached {
                print(await SLTASelfTest.run())
                completion.signal()
            }
            completion.wait()
            return
        }

        if CommandLine.arguments.contains("--cli") {
            runCLIMode()
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let vm = AgentUIViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = SLTAMainWindowView(vm: vm)
        let hostingView = NSHostingView(rootView: view)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.center()
        win.title = "Stacy Agent"
        win.titlebarAppearsTransparent = true
        win.contentView = hostingView
        win.makeKeyAndOrderFront(nil)
        self.window = win

        NSApp.activate(ignoringOtherApps: true)

        // GUI is an IPC client. Model, LSP and project truth stay in slta-runtime.
        Task.detached {
            do {
                let options = try AgentOptions.parse(CommandLine.arguments)
                await self.vm.emit(.modelLoading)
                try await RuntimeProcess.ensureRunning(options: options)
                let client = RuntimeClient(workspaceURL: options.projectURL) { [weak vm = self.vm] event in
                    Task { await vm?.consume(event) }
                }
                try await client.connect(clientName: "slta-gui")
                let snapshot = try await client.openWorkspace()
                await self.vm.bind(client: client, snapshot: snapshot)
            } catch {
                await MainActor.run {
                    self.vm.loadingStatus = "Ошибка загрузки: \(error.localizedDescription)"
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

func runCLIMode() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let options = try AgentOptions.parse(CommandLine.arguments)
            let renderer = TerminalRenderer()
            try await RuntimeProcess.ensureRunning(options: options)
            let client = RuntimeClient(workspaceURL: options.projectURL) { event in
                if let translated = IPCEventAdapter.agentEvent(event) {
                    Task { await renderer.emit(translated) }
                }
            }
            try await client.connect(clientName: "slta-cli")
            _ = try await client.openWorkspace()

            TerminalRenderer.banner(
                model: options.modelID,
                project: options.projectURL.path,
                approval: options.approvalMode
            )

            while true {
                TerminalRenderer.prompt()
                guard let line = readLine() else { break }
                let text = InputNormalizer.sanitize(line)
                if text.isEmpty { continue }

                switch text {
                case "/exit", "/quit":
                    client.close()
                    semaphore.signal()
                    return
                case "/clear":
                    print("  " + TerminalStyle.green("✓") + TerminalStyle.dim(" local display cleared; runtime state preserved\n"))
                case "/mcp":
                    print("  " + TerminalStyle.dim("MCP is owned by slta-runtime\n"))
                default:
                    _ = try await client.submit(text)
                    print("")
                }
            }
        } catch {
            fputs(TerminalStyle.red("SLTA: \(error)") + "\n", stderr)
        }
        semaphore.signal()
    }
    semaphore.wait()
}

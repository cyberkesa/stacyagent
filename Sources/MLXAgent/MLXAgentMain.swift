import Foundation
import AppKit
import SwiftUI

@main
@MainActor
struct MLXAgentMain {
    static func main() {
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

        // Запуск модели и MCP в фоне — окно открывается мгновенно, без подвисаний!
        Task.detached {
            do {
                let options = try AgentOptions.parse(CommandLine.arguments)
                let policy = PolicyEngine(mode: options.approvalMode, allowMCP: options.allowMCP)
                let runtime = RuntimeEnvironment.probe(projectURL: options.projectURL)
                let workspace = Workspace(root: options.projectURL, shellTimeoutSeconds: options.shellTimeoutSeconds, policy: policy, runtime: runtime)
                let mcp = MCPBridge(policy: policy)

                await self.vm.emit(.modelLoading)

                let events = EventBus(sink: self.vm)
                let registry = ToolRegistry(workspace: workspace, mcp: mcp, events: events, runtime: runtime)
                let model = try await MLXModelAdapter(
                    modelID: options.modelID,
                    projectURL: options.projectURL,
                    registry: registry,
                    events: events,
                    chatMaxTokens: options.chatMaxTokens,
                    agentMaxTokens: options.agentMaxTokens,
                    timeoutSeconds: options.generationTimeoutSeconds,
                    controllerTimeoutSeconds: options.controllerTimeoutSeconds,
                    draftModelID: options.draftModelID
                )
                let agent = AgentLoop(
                    model: model,
                    registry: registry,
                    events: events,
                    maxRounds: options.maxRounds
                )

                await MainActor.run {
                    self.vm.bind(agent: agent, mcp: mcp)
                }
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
            let events = EventBus(sink: renderer)
            let policy = PolicyEngine(mode: options.approvalMode, allowMCP: options.allowMCP)
            let runtime = RuntimeEnvironment.probe(projectURL: options.projectURL)
            let workspace = Workspace(root: options.projectURL, shellTimeoutSeconds: options.shellTimeoutSeconds, policy: policy, runtime: runtime)
            let mcp = MCPBridge(policy: policy)
            let registry = ToolRegistry(workspace: workspace, mcp: mcp, events: events, runtime: runtime)
            let model = try await MLXModelAdapter(
                modelID: options.modelID,
                projectURL: options.projectURL,
                registry: registry,
                events: events,
                chatMaxTokens: options.chatMaxTokens,
                agentMaxTokens: options.agentMaxTokens,
                timeoutSeconds: options.generationTimeoutSeconds,
                controllerTimeoutSeconds: options.controllerTimeoutSeconds,
                draftModelID: options.draftModelID
            )
            let agent = AgentLoop(
                model: model,
                registry: registry,
                events: events,
                maxRounds: options.maxRounds
            )

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
                    semaphore.signal()
                    return
                case "/clear":
                    await agent.clear()
                    print("  " + TerminalStyle.green("✓") + TerminalStyle.dim(" context cleared\n"))
                case "/mcp":
                    print("  " + TerminalStyle.dim(mcp.listServers() + "\n"))
                default:
                    try await agent.run(text)
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

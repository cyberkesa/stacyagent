import Foundation

enum TerminalStyle {
    private static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["NO_COLOR"] == nil && env["TERM"] != "dumb"
    }()

    private static let reset = "\u{001B}[0m"
    private static let pinkCode = "\u{001B}[38;2;255;173;200m"
    private static let greenCode = "\u{001B}[38;2;134;239;172m"
    private static let yellowCode = "\u{001B}[38;2;250;204;21m"
    private static let redCode = "\u{001B}[38;2;248;113;113m"
    private static let cyanCode = "\u{001B}[38;2;165;214;255m"
    private static let dimCode = "\u{001B}[38;2;132;132;142m"
    private static let boldCode = "\u{001B}[1m"

    static func pink(_ s: String) -> String { wrap(s, pinkCode) }
    static func green(_ s: String) -> String { wrap(s, greenCode) }
    static func yellow(_ s: String) -> String { wrap(s, yellowCode) }
    static func red(_ s: String) -> String { wrap(s, redCode) }
    static func cyan(_ s: String) -> String { wrap(s, cyanCode) }
    static func dim(_ s: String) -> String { wrap(s, dimCode) }
    static func bold(_ s: String) -> String { wrap(s, boldCode) }

    static func clearLine() {
        print("\r\u{001B}[2K", terminator: "")
        try? FileHandle.standardOutput.synchronize()
    }

    private static func wrap(_ text: String, _ code: String) -> String {
        enabled ? code + text + reset : text
    }
}

actor TerminalRenderer: AgentEventSink {
    private let frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    private var frame = 0
    private var liveLine = false

    nonisolated static func banner(model: String, project: String, approval: ApprovalMode) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = project.hasPrefix(home) ? "~" + project.dropFirst(home.count) : Substring(project)
        print("")
        print("  " + TerminalStyle.pink(TerminalStyle.bold("SLTA")) + TerminalStyle.dim("  v0.27 · control plane"))
        print("  " + TerminalStyle.dim((model.split(separator: "/").last.map(String.init) ?? model)))
        print("  " + TerminalStyle.dim(String(p) + "  ·  " + approval.rawValue))
        print("")
        print("  " + TerminalStyle.dim("/status  /stats  /context  /task  /edits  /diff  /revisions  /checkpoints  /selftest  /tools  /mcp  /debug  /clear  /exit"))
        print("")
    }

    nonisolated static func prompt() {
        print(TerminalStyle.pink("SLTA") + TerminalStyle.dim(" › "), terminator: "")
        try? FileHandle.standardOutput.synchronize()
    }

    func emit(_ event: AgentEvent) async {
        switch event {
        case .modelLoading:
            live("loading model", seconds: 0, chunks: 0)
        case .modelReady:
            clearLive()
            print("  " + TerminalStyle.green("✓") + TerminalStyle.dim(" model ready"))
        case .taskStarted(let task):
            clearLive()
            let clean = task.replacingOccurrences(of: "\n", with: " ")
            let shown = clean.count > 92 ? String(clean.prefix(89)) + "…" : clean
            print("")
            print("  " + TerminalStyle.pink("◆") + " " + TerminalStyle.bold(shown))
            print("")
        case .generationStarted(let label):
            live(label, seconds: 0, chunks: 0)
        case .generationProgress(let label, let seconds, let chunks):
            live(label, seconds: seconds, chunks: chunks)
        case .generationFinished:
            clearLive()
        case .toolStarted(let name):
            clearLive()
            print("  " + TerminalStyle.pink("│") + " " + TerminalStyle.cyan(name))
        case .toolFinished(_, let ok, let detail, let duration):
            let mark = ok ? TerminalStyle.green("✓") : TerminalStyle.red("×")
            let clipped = detail.count > 140 ? String(detail.prefix(137)) + "…" : detail
            print("  " + TerminalStyle.pink("│") + "   " + mark + " " + TerminalStyle.dim(clipped + " · " + Self.format(duration)))
        case .notice(let text):
            clearLive()
            print("  " + TerminalStyle.dim("· " + text))
        case .warning(let text):
            clearLive()
            print("  " + TerminalStyle.yellow("! ") + TerminalStyle.dim(text))
        case .assistant(let text):
            clearLive()
            if !text.isEmpty {
                print("")
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    print("  " + line)
                }
            }
        case .completed(let stats):
            clearLive()
            var pieces=[Self.format(stats.elapsed)]
            if stats.outputTokens > 0 { pieces.append("\(stats.outputTokens) tok") }
            if let x=stats.generationTokensPerSecond { pieces.append(String(format:"%.1f tok/s",x)) }
            if stats.passes > 0 { pieces.append("\(stats.passes) pass" + (stats.passes == 1 ? "" : "es")) }
            if stats.tools > 0 {
                pieces.append("\(stats.tools) " + (stats.tools == 1 ? "tool" : "tools"))
            }
            if let x=stats.firstTokenSeconds { pieces.append(String(format:"ttft %.2fs",x)) }
            print("")
            print("  "+TerminalStyle.green("✓")+" "+TerminalStyle.pink("done")+TerminalStyle.dim("  "+pieces.joined(separator:" · ")))
            print("  "+TerminalStyle.dim(String(format:"model %.2fs · tools %.2fs · route %.2fs %@",stats.modelSeconds,stats.toolSeconds,stats.routerSeconds,stats.routeSource?.rawValue ?? "")))
        }
    }

    private func live(_ label: String, seconds: Double, chunks: Int) {
        let glyph = frames[frame % frames.count]
        frame += 1
        var text = "  \(glyph) \(label)"
        if seconds > 0 { text += String(format: "   %.1fs", seconds) }
        if chunks > 0 { text += "   stream \(chunks)" }
        print("\r\u{001B}[2K" + TerminalStyle.pink(text), terminator: "")
        try? FileHandle.standardOutput.synchronize()
        liveLine = true
    }

    private func clearLive() {
        if liveLine {
            TerminalStyle.clearLine()
            liveLine = false
        }
    }

    nonisolated static func format(_ duration: Duration) -> String {
        let c = duration.components
        let s = Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
        return s < 1 ? String(format: "%.0fms", s * 1000) : String(format: "%.1fs", s)
    }
}

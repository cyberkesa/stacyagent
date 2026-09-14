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
        case .taskCompiled(let taskID):
            print("  " + TerminalStyle.dim("· task compiled \(taskID)"))
        case .taskStateChanged(let taskID, let phase):
            print("  " + TerminalStyle.dim("· task \(taskID) → \(phase)"))
        case .protocolDecision(_, let decision):
            print("  " + TerminalStyle.dim("· \(decision)"))
        case .intelligenceStarted(_, let kind):
            live("thinking \(kind)", seconds: 0, chunks: 0)
        case .intelligenceFinished(_, let provider, let seconds):
            clearLive()
            print("  " + TerminalStyle.dim(String(format: "· %@ %.1fs", provider, seconds)))
        case .proposalCreated(_, let path):
            print("  " + TerminalStyle.dim("· proposal \(path)"))
        case .transactionApplied(_, let path, let transaction):
            print("  " + TerminalStyle.dim("· applied \(path) \(transaction)"))
        case .validationFinished(let path, let ok):
            print("  " + TerminalStyle.dim("· validate \(path) \(ok ? "ok" : "failed")"))
        case .taskCompleted(let taskID):
            print("  " + TerminalStyle.dim("· task completed \(taskID)"))
        case .taskBlocked(let taskID, let reason):
            print("  " + TerminalStyle.yellow("! ") + TerminalStyle.dim("task \(taskID) blocked: \(reason)"))
        case .artifactRevisionCreated(_, let path, let revision):
            print("  " + TerminalStyle.dim("· revision \(path) → \(revision)"))
        case .artifactExternalChangeDetected(let path, let revision):
            print("  " + TerminalStyle.yellow("! ") + TerminalStyle.dim("external change \(path) → \(revision)"))
        case .evidenceRecorded(_, let kind, let path):
            print("  " + TerminalStyle.dim("· evidence \(kind)" + (path.map { " \($0)" } ?? "")))
        case .evidenceBecameStale(_, let path):
            print("  " + TerminalStyle.dim("· stale evidence \(path)"))
        case .runtimeStatePersisted(let projectID):
            print("  " + TerminalStyle.dim("· runtime persisted \(projectID)"))
        case .runtimeStateRestored(let projectID):
            print("  " + TerminalStyle.dim("· runtime restored \(projectID)"))
        case .codeIntelligenceStarted(let provider, let operation):
            print("  " + TerminalStyle.dim("· \(provider) \(operation)…"))
        case .codeIntelligenceFinished(let provider, let operation, let ms, let hit, let count):
            print("  " + TerminalStyle.dim(String(format: "· %@ %@ %.0fms %@ %d", provider, operation, ms, hit ? "cached" : "fresh", count)))
        case .semanticFactRecorded(let kind, let path, _):
            print("  " + TerminalStyle.dim("· fact \(kind) \(path)"))
        case .semanticFactBecameStale(let kind, let path):
            print("  " + TerminalStyle.dim("· stale \(kind) \(path)"))
        case .semanticEditPlanned(_, let files, let edits):
            print("  " + TerminalStyle.dim("· semantic plan \(edits) edits in \(files.count) files"))
        case .semanticEditApplied(_, let files):
            print("  " + TerminalStyle.dim("· semantic applied \(files.joined(separator: ", "))"))
        case .semanticAmbiguityDetected(let symbol, let candidates):
            print("  " + TerminalStyle.yellow("! ") + TerminalStyle.dim("ambiguous \(symbol): \(candidates.joined(separator: ", "))"))
        case .contextCompilationStarted(let taskID, let purpose):
            print("  " + TerminalStyle.dim("· context \(taskID) \(purpose)…"))
        case .contextCompilationFinished(_, let ms, let count, let tokens, let hit, _):
            print("  " + TerminalStyle.dim(String(format: "· context %d items ~%dtok %.0fms %@", count, tokens, ms, hit ? "cached" : "fresh")))
        case .contextItemAdded(_, let itemID, let kind):
            print("  " + TerminalStyle.dim("· +\(kind) \(itemID)"))
        case .contextItemDropped(_, let itemID, let reason):
            print("  " + TerminalStyle.dim("· -\(itemID) \(reason)"))
        case .contextBundleInvalidated(let path):
            print("  " + TerminalStyle.dim("· context invalidated \(path)"))
        case .computationRequested(_, let intent):
            print("  " + TerminalStyle.dim("· computation requested \(intent)"))
        case .computationRouted(_, let strategy, let latency, let calls, let hit):
            print("  " + TerminalStyle.dim("· computation → \(strategy) \(latency) model=\(calls) \(hit ? "cached" : "fresh")"))
        case .computationFinished(_, let strategy, let ms, let count, let hit, let avoided):
            print("  " + TerminalStyle.dim(String(format: "· computation %@ %.0fms candidates=%d %@ model-avoided=%@", strategy, ms, count, hit ? "cached" : "fresh", avoided ? "true" : "false")))
        case .computationEscalated(_, let from, let to, let reason):
            print("  " + TerminalStyle.dim("· computation \(from) → \(to): \(reason)"))
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

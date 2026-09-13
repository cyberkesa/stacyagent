import Foundation
import SwiftUI
import AppKit
import Textual

// MARK: - Color Palette
enum StacyTheme {
    static let bg = Color(red: 0.988, green: 0.976, blue: 0.982)
    static let sidebarBg = Color(red: 0.996, green: 0.988, blue: 0.992)
    static let cardBg = Color.white
    static let cardBorder = Color(red: 0.93, green: 0.85, blue: 0.89)
    static let cardBorderHover = Color(red: 0.98, green: 0.60, blue: 0.72)
    static let primaryPink = Color(red: 0.98, green: 0.38, blue: 0.58)
    static let softPink = Color(red: 1.0, green: 0.93, blue: 0.96)
    static let userBubbleBg = Color(red: 1.0, green: 0.945, blue: 0.965)
    static let textMain = Color(red: 0.20, green: 0.16, blue: 0.19)
    static let textMuted = Color(red: 0.56, green: 0.49, blue: 0.53)
    static let badgeSuccess = Color(red: 0.20, green: 0.78, blue: 0.45)
}

// MARK: - Mascot View
struct StacyMascotView: View {
    var size: CGFloat = 36
    var isThinking: Bool = false
    @State private var bounce = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(StacyTheme.cardBorder, lineWidth: 1.5))
                .shadow(color: StacyTheme.primaryPink.opacity(0.08), radius: 3, y: 1)

            HStack(spacing: size * 0.42) {
                EarView(size: size * 0.32)
                EarView(size: size * 0.32).scaleEffect(x: -1, y: 1)
            }
            .offset(y: -size * 0.42)

            VStack(spacing: size * 0.04) {
                HStack(spacing: size * 0.30) {
                    if isThinking {
                        Image(systemName: "sparkle")
                            .font(.system(size: size * 0.24, weight: .bold))
                            .foregroundStyle(StacyTheme.primaryPink)
                            .rotationEffect(.degrees(bounce ? 45 : 0))
                        Image(systemName: "sparkle")
                            .font(.system(size: size * 0.24, weight: .bold))
                            .foregroundStyle(StacyTheme.primaryPink)
                            .rotationEffect(.degrees(bounce ? -45 : 0))
                    } else {
                        Circle().fill(StacyTheme.textMain).frame(width: size * 0.14, height: size * 0.14)
                        Circle().fill(StacyTheme.textMain).frame(width: size * 0.14, height: size * 0.14)
                    }
                }
                .offset(y: size * 0.04)

                HStack(spacing: size * 0.08) {
                    Circle().fill(Color.pink.opacity(0.35)).frame(width: size * 0.16, height: size * 0.09)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 0))
                        p.addLine(to: CGPoint(x: 4, y: 0))
                        p.addLine(to: CGPoint(x: 2, y: 3))
                        p.closeSubpath()
                    }
                    .fill(StacyTheme.primaryPink)
                    .frame(width: 4, height: 3)
                    Circle().fill(Color.pink.opacity(0.35)).frame(width: size * 0.16, height: size * 0.09)
                }
            }

            Text("🎀")
                .font(.system(size: size * 0.36))
                .offset(x: size * 0.32, y: -size * 0.36)
        }
        .offset(y: bounce ? -3 : 0)
        .onAppear {
            if isThinking {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { bounce = true }
            }
        }
        .onChange(of: isThinking) { _, thinking in
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { bounce = thinking }
        }
    }
}

struct EarView: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Triangle()
                .fill(Color.white)
                .frame(width: size, height: size)
                .overlay(Triangle().stroke(StacyTheme.cardBorder, lineWidth: 1.5))
            Triangle()
                .fill(StacyTheme.primaryPink.opacity(0.35))
                .frame(width: size * 0.6, height: size * 0.6)
                .offset(y: size * 0.1)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Models
public struct UIMessage: Identifiable {
    public let id = UUID()
    public let role: Role
    public var text: String
    public var toolCalls: [UIToolCall] = []
    public var imageURLs: [URL] = []
    public var tokenStats: String? = nil
    public let timestamp = Date()

    public enum Role {
        case user
        case assistant
    }
}

public struct UIToolCall: Identifiable {
    public let id = UUID()
    public let name: String
    public var detail: String
    public var isRunning: Bool
    public var isSuccess: Bool?
    public var duration: String?
}

// MARK: - ViewModel
@MainActor
final class AgentUIViewModel: ObservableObject, AgentEventSink {
    @Published var messages: [UIMessage] = []
    @Published var inputText: String = ""
    @Published var isRunning: Bool = false
    @Published var isModelLoading: Bool = true
    @Published var loadingStatus: String = "Инициализация окружения..."
    @Published var activeTask: String? = nil
    @Published var activeToolName: String? = nil
    @Published var serverNames: [String] = []
    @Published var isSidebarVisible: Bool = true

    // Live Thinking & Token Telemetry
    @Published var liveThinkingLabel: String? = nil
    @Published var liveThinkingSeconds: Double = 0
    @Published var liveThinkingTokens: Int = 0

    private var agent: AgentLoop?
    private var taskHandle: Task<Void, Never>?

    func bind(agent: AgentLoop, mcp: MCPBridge) {
        self.agent = agent
        self.serverNames = mcp.serverNames
        self.isModelLoading = false
        self.loadingStatus = "Готова к магии ✨"
    }

    nonisolated func emit(_ event: AgentEvent) async {
        await MainActor.run { self.handleEvent(event) }
    }

    private func handleEvent(_ event: AgentEvent) {
        switch event {
        case .modelLoading:
            self.loadingStatus = "Загрузка весов Qwen3-Coder (30B)..."
            self.isModelLoading = true

        case .modelReady:
            self.isModelLoading = false
            self.loadingStatus = "Готова к магии ✨"

        case .taskStarted(let task):
            self.activeTask = task
            self.ensureAssistantBubble()

        case .generationStarted(let label):
            self.ensureAssistantBubble()
            self.liveThinkingLabel = label
            self.liveThinkingSeconds = 0
            self.liveThinkingTokens = 0

        case .generationProgress(let label, let seconds, let chunks):
            self.ensureAssistantBubble()
            self.liveThinkingLabel = label
            self.liveThinkingSeconds = seconds
            self.liveThinkingTokens = chunks

        case .generationFinished:
            self.liveThinkingLabel = nil

        case .toolStarted(let name):
            self.activeToolName = name
            self.liveThinkingLabel = nil
            self.ensureAssistantBubble()
            if var last = self.messages.last, last.role == .assistant {
                last.toolCalls.append(UIToolCall(name: name, detail: "", isRunning: true))
                self.messages[self.messages.count - 1] = last
            }

        case .toolFinished(let name, let ok, let detail, let duration):
            self.activeToolName = nil
            guard var last = self.messages.last, last.role == .assistant else { return }
            if let idx = last.toolCalls.firstIndex(where: { $0.name == name && $0.isRunning }) {
                last.toolCalls[idx].isRunning = false
                last.toolCalls[idx].isSuccess = ok
                last.toolCalls[idx].detail = detail
                last.toolCalls[idx].duration = TerminalRenderer.format(duration)
            }

            let urls = self.extractImageURLs(from: detail)
            for u in urls where !last.imageURLs.contains(u) {
                last.imageURLs.append(u)
            }
            self.messages[self.messages.count - 1] = last

        case .assistant(let chunk):
            self.liveThinkingLabel = nil
            self.ensureAssistantBubble()
            guard var last = self.messages.last, last.role == .assistant else { return }
            if last.text.isEmpty {
                last.text = chunk
            } else {
                last.text += "\n" + chunk
            }
            let urls = self.extractImageURLs(from: chunk)
            for u in urls where !last.imageURLs.contains(u) {
                last.imageURLs.append(u)
            }
            self.messages[self.messages.count - 1] = last

        case .completed(let stats):
            self.isRunning = false
            self.activeTask = nil
            self.activeToolName = nil
            self.liveThinkingLabel = nil

            guard var last = self.messages.last, last.role == .assistant else { return }
            var parts: [String] = []
            if stats.outputTokens > 0 { parts.append("\(stats.outputTokens) tok") }
            if let tps = stats.generationTokensPerSecond { parts.append(String(format: "%.1f tok/s", tps)) }
            parts.append(TerminalRenderer.format(stats.elapsed))
            if let ttft = stats.firstTokenSeconds { parts.append(String(format: "ttft %.2fs", ttft)) }
            last.tokenStats = parts.joined(separator: " • ")
            self.messages[self.messages.count - 1] = last

        case .warning(let text):
            self.ensureAssistantBubble()
            guard var last = self.messages.last, last.role == .assistant else { return }
            last.text += "\n⚠️ " + text
            self.messages[self.messages.count - 1] = last

        default:
            break
        }
    }

    private func ensureAssistantBubble() {
        if self.messages.last?.role != .assistant {
            self.messages.append(UIMessage(role: .assistant, text: ""))
        }
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let currentAgent = agent, !isRunning else { return }
        inputText = ""

        messages.append(UIMessage(role: .user, text: text))
        isRunning = true
        ensureAssistantBubble()

        taskHandle = Task.detached {
            do {
                try await currentAgent.run(text)
            } catch {
                await MainActor.run {
                    self.ensureAssistantBubble()
                    if var last = self.messages.last, last.role == .assistant {
                        let hasSuccessfulTools = last.toolCalls.contains { $0.isSuccess == true }
                        if !hasSuccessfulTools {
                            last.text += "\n❌ Ошибка: \(error.localizedDescription)"
                        }
                        self.messages[self.messages.count - 1] = last
                    }
                    self.isRunning = false
                    self.activeTask = nil
                    self.liveThinkingLabel = nil
                }
            }
        }
    }

    func stop() {
        taskHandle?.cancel()
        isRunning = false
        activeTask = nil
        activeToolName = nil
        liveThinkingLabel = nil
    }

    func clearHistory() {
        messages.removeAll()
        Task { await agent?.clear() }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) {
            inputText += text
        }
    }

    private func extractImageURLs(from text: String) -> [URL] {
        let pattern = #"https?://[^\s\"'<>\)\]]+\.(?:jpg|jpeg|png|webp|gif)(?:\?[^\s\"'<>\)\]]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            guard let r = Range($0.range, in: text) else { return nil }
            return URL(string: String(text[r]))
        }
    }
}

// MARK: - Main View
struct SLTAMainWindowView: View {
    @ObservedObject var vm: AgentUIViewModel
    @FocusState private var isInputFocused: Bool

    private var inputHeight: CGFloat {
        let lines = vm.inputText.components(separatedBy: "\n").count
        let charLines = vm.inputText.count / 75
        let total = max(1, lines + charLines)
        return min(160, max(38, CGFloat(total * 22 + 16)))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { vm.isSidebarVisible ? .all : .detailOnly },
            set: { vm.isSidebarVisible = ($0 == .all) }
        )) {
            SidebarView(vm: vm)
        } detail: {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Button(action: { withAnimation(.spring(response: 0.3)) { vm.isSidebarVisible.toggle() } }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13))
                            .foregroundStyle(StacyTheme.textMuted)
                            .padding(6)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StacyTheme.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Скрыть/показать сайдбар (⌘B)")
                    .keyboardShortcut("b", modifiers: [.command])

                    if vm.isModelLoading {
                        ProgressView().controlSize(.mini).tint(StacyTheme.primaryPink)
                        Text(vm.loadingStatus).font(.system(size: 12)).foregroundStyle(StacyTheme.textMuted)
                    } else if let task = vm.activeTask {
                        ProgressView().controlSize(.mini).tint(StacyTheme.primaryPink)
                        Text(task).font(.system(size: 12, weight: .semibold)).foregroundStyle(StacyTheme.primaryPink).lineLimit(1)
                    } else {
                        HStack(spacing: 6) {
                            Circle().fill(StacyTheme.badgeSuccess).frame(width: 7, height: 7)
                            Text("Готова к магии ✨").font(.system(size: 12, weight: .medium)).foregroundStyle(StacyTheme.textMuted)
                        }
                    }

                    Spacer()

                    Button(action: vm.clearHistory) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Очистить")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StacyTheme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(StacyTheme.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Очистить контекст (⌘K)")
                    .keyboardShortcut("k", modifiers: [.command])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white)

                Divider().overlay(StacyTheme.cardBorder)

                // Message Stream
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if vm.messages.isEmpty {
                                WelcomeEmptyView()
                            } else {
                                LazyVStack(spacing: 16) {
                                    ForEach(vm.messages) { msg in
                                        ChatBubbleView(
                                            msg: msg,
                                            isLastAndRunning: vm.isRunning && msg.id == vm.messages.last?.id,
                                            thinkingLabel: vm.liveThinkingLabel,
                                            thinkingSeconds: vm.liveThinkingSeconds,
                                            thinkingTokens: vm.liveThinkingTokens,
                                            onCopy: { text in vm.copyToClipboard(text) }
                                        )
                                    }
                                }
                                .padding(.vertical, 20)
                            }
                        }
                        .frame(maxWidth: 880)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                    }
                    .onChange(of: vm.messages.count) { _, _ in
                        if let lastID = vm.messages.last?.id {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }

                Divider().overlay(StacyTheme.cardBorder)

                // Input Box
                VStack(spacing: 6) {
                    HStack(alignment: .bottom, spacing: 8) {
                        Button(action: vm.pasteFromClipboard) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 13))
                                .foregroundStyle(StacyTheme.primaryPink)
                                .frame(width: 34, height: 34)
                                .background(StacyTheme.softPink)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Вставить из буфера обмена (⌘V)")

                        TextEditor(text: $vm.inputText)
                            .font(.system(size: 14))
                            .focused($isInputFocused)
                            .scrollContentBackground(.hidden)
                            .frame(height: inputHeight)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isInputFocused ? StacyTheme.primaryPink.opacity(0.8) : StacyTheme.cardBorder, lineWidth: 1.5)
                            )
                            .animation(.easeInOut(duration: 0.15), value: inputHeight)
                            .onKeyPress(.return) {
                                if NSEvent.modifierFlags.contains(.shift) {
                                    return .ignored
                                } else {
                                    vm.send()
                                    return .handled
                                }
                            }

                        if vm.isRunning {
                            Button(action: vm.stop) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.red.opacity(0.88))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(".", modifiers: [.command])
                            .keyboardShortcut(.escape, modifiers: [])
                        } else {
                            Button(action: vm.send) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isModelLoading ? StacyTheme.primaryPink.opacity(0.3) : StacyTheme.primaryPink)
                                    .clipShape(Circle())
                                    .shadow(color: StacyTheme.primaryPink.opacity(vm.inputText.isEmpty ? 0 : 0.25), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isModelLoading)
                        }
                    }

                    HStack {
                        Text("⏎ Отправить  •  ⇧⏎ Новая строка  •  ⌘K Очистить  •  ⌘B Сайдбар")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StacyTheme.textMuted.opacity(0.75))
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white)
            }
            .background(StacyTheme.bg)
        }
        .preferredColorScheme(.light)
        .frame(minWidth: 800, minHeight: 560)
        .onAppear { isInputFocused = true }
    }
}

// MARK: - Sidebar View
struct SidebarView: View {
    @ObservedObject var vm: AgentUIViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                StacyMascotView(size: 40, isThinking: vm.isRunning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stacy Agent")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(StacyTheme.textMain)
                    Text("Qwen3-Coder · MLX")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StacyTheme.primaryPink)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Divider().overlay(StacyTheme.cardBorder)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "cube.box.fill")
                        .foregroundStyle(StacyTheme.primaryPink)
                        .font(.caption2)
                    Text("MCP СЕРВЕРЫ")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StacyTheme.textMuted)
                }
                .padding(.horizontal, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(vm.serverNames, id: \.self) { server in
                            HStack(spacing: 7) {
                                Circle().fill(StacyTheme.badgeSuccess).frame(width: 6, height: 6)
                                Text(server).font(.system(size: 11, design: .monospaced)).foregroundStyle(StacyTheme.textMain)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StacyTheme.cardBorder, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            Spacer()

            Button(action: vm.clearHistory) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Очистить чат")
                    Spacer()
                    Text("⌘K").font(.system(size: 10)).foregroundStyle(StacyTheme.textMuted.opacity(0.6))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StacyTheme.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(StacyTheme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .frame(minWidth: 200, maxWidth: 240)
        .background(StacyTheme.sidebarBg)
    }
}

// MARK: - Welcome View
struct WelcomeEmptyView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 60)
            StacyMascotView(size: 90, isThinking: false)
            Text("Привет, Стейси! 🌸")
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(StacyTheme.textMain)
            Text("Я твой нативный помощник. Ищу фото, правлю код, запускаю тесты и управляю MCP.")
                .font(.system(size: 13))
                .foregroundStyle(StacyTheme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Chat Bubble View with Live Thinking Stream
struct ChatBubbleView: View {
    let msg: UIMessage
    var isLastAndRunning: Bool = false
    var thinkingLabel: String? = nil
    var thinkingSeconds: Double = 0
    var thinkingTokens: Int = 0
    var onCopy: (String) -> Void

    @State private var isHovered = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if msg.role == .assistant {
                StacyMascotView(size: 32, isThinking: isLastAndRunning)
            } else {
                Spacer(minLength: 50)
            }

            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 6) {
                // Header
                HStack(spacing: 6) {
                    if msg.role == .assistant {
                        Text("Stacy Agent")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(StacyTheme.primaryPink)
                    }

                    if isHovered && !msg.text.isEmpty {
                        Button(action: {
                            onCopy(msg.text)
                            justCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                                Text(justCopied ? "Скопировано!" : "Копировать")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(justCopied ? Color.green : StacyTheme.primaryPink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(StacyTheme.softPink)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(msg.timestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(StacyTheme.textMuted.opacity(0.6))

                    if msg.role == .user {
                        Text("Вы")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(StacyTheme.textMuted)
                    }
                }

                // Tool Calls
                if !msg.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(msg.toolCalls) { tool in
                            CollapsibleToolView(tool: tool)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // ЖИВОЙ ИНСПЕКТОР РАССУЖДЕНИЙ (Live Thinking Inspector)
                if isLastAndRunning && msg.role == .assistant {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini).tint(StacyTheme.primaryPink)
                        
                        let phaseText = (thinkingLabel?.contains("working") == true)
                            ? "Пишу код в файл..."
                            : "Анализирую задачу и планирую код..."
                        
                        Text(phaseText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(StacyTheme.textMain)

                        Spacer()

                        HStack(spacing: 5) {
                            Image(systemName: "stopwatch")
                                .font(.system(size: 9.5))
                            Text(String(format: "%.1fs", thinkingSeconds))
                            if thinkingTokens > 0 {
                                Text("• \(thinkingTokens) tok")
                            }
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(StacyTheme.textMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(StacyTheme.softPink)
                        .clipShape(Capsule())
                    }
                    .padding(9)
                    .background(Color(red: 0.995, green: 0.965, blue: 0.985))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StacyTheme.cardBorder, lineWidth: 1))
                }

                // Text
                if !msg.text.isEmpty {
                    Text(msg.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(StacyTheme.textMain)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .padding(msg.role == .user ? 10 : 0)
                        .background(msg.role == .user ? StacyTheme.userBubbleBg : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(msg.role == .user ? StacyTheme.primaryPink.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                }

                // Images
                if !msg.imageURLs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(msg.imageURLs, id: \.self) { url in
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .empty:
                                        ProgressView()
                                            .tint(StacyTheme.primaryPink)
                                            .frame(width: 180, height: 135)
                                            .background(StacyTheme.softPink)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 230, height: 165)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StacyTheme.cardBorder, lineWidth: 1.2))
                                            .shadow(color: StacyTheme.primaryPink.opacity(0.1), radius: 5, y: 2)
                                            .onTapGesture { NSWorkspace.shared.open(url) }
                                    case .failure:
                                        HStack {
                                            Image(systemName: "photo")
                                            Text("Не загрузилось").font(.caption2)
                                        }
                                        .frame(width: 180, height: 135)
                                        .background(StacyTheme.softPink)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Stats
                if let stats = msg.tokenStats {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(StacyTheme.primaryPink)
                        Text(stats)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(StacyTheme.textMuted.opacity(0.85))
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(msg.role == .user ? Color.clear : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(msg.role == .user ? Color.clear : StacyTheme.cardBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(msg.role == .user ? 0 : 0.015), radius: 3, y: 1)
            .onHover { isHovered = $0 }

            if msg.role == .user {
                Circle()
                    .fill(StacyTheme.softPink)
                    .frame(width: 32, height: 32)
                    .overlay(Text("🌸").font(.caption2))
                    .overlay(Circle().stroke(StacyTheme.cardBorder, lineWidth: 1))
            } else {
                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Collapsible Tool Card
struct CollapsibleToolView: View {
    let tool: UIToolCall
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() } }) {
                HStack(spacing: 7) {
                    if tool.isRunning {
                        ProgressView().controlSize(.mini).tint(StacyTheme.primaryPink)
                    } else {
                        Image(systemName: tool.isSuccess == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(tool.isSuccess == true ? StacyTheme.badgeSuccess : Color.red)
                            .font(.system(size: 11))
                    }

                    Text(tool.name)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(StacyTheme.textMain)

                    Spacer()

                    if let dur = tool.duration {
                        Text(dur).font(.system(size: 10)).foregroundStyle(StacyTheme.textMuted)
                    }

                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(StacyTheme.textMuted)
                }
            }
            .buttonStyle(.plain)

            if isOpen && !tool.detail.isEmpty {
                Text(tool.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StacyTheme.textMuted)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(StacyTheme.softPink.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(StacyTheme.cardBorder, lineWidth: 0.8))
    }
}

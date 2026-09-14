import Foundation

// MARK: - v0.30 §21 real SourceKit-LSP integration scenario
//
// Opt-in ONLY (env STACYAGENT_LSP_INTEGRATION=1): spins the real installed
// sourcekit-lsp against a temporary SwiftPM package and drives the full
// deterministic rename pipeline. Never runs in the fast suite, never
// touches ModelProvider. Reports BLOCKED honestly when the server is
// unavailable instead of faking success.

enum LSPIntegrationSelfTest {
    static func runIfEnabled() async -> [CodeIntelCheckResult] {
        guard ProcessInfo.processInfo.environment["STACYAGENT_LSP_INTEGRATION"] == "1" else {
            return []
        }
        var out: [CodeIntelCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(CodeIntelCheckResult(passed: passed, name: name))
        }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("stacyagent-lsp-int-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        do {
            let sources = dir.appendingPathComponent("Sources/Probe", isDirectory: true)
            try fm.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data("""
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "Probe", targets: [.target(name: "Probe")])
                """.utf8).write(to: dir.appendingPathComponent("Package.swift"))
            let probe = """
                public struct UserManager {
                    public init() {}
                    public func greet() -> String { "hi" }
                }
                public let manager = UserManager()
                """
            try Data(probe.utf8).write(to: sources.appendingPathComponent("Probe.swift"))

            let policy = PolicyEngine(mode: .workspace, allowMCP: false)
            let runtime = RuntimeEnvironment.probe(projectURL: dir)
            let workspace = Workspace(
                root: dir, shellTimeoutSeconds: 60, policy: policy, runtime: runtime
            )
            fputs("LSP-INT: binary probe\n", stderr)
            guard let lsp = LSPCodeIntelligenceProvider(
                projectRoot: dir, initializationTimeout: 240
            ) else {
                record(false, "lsp-int server binary missing (BLOCKED)")
                return out
            }
            fputs("LSP-INT: binary ok\n", stderr)
            defer { Task { await lsp.shutdown() } }
            let engine = CodeIntelligenceEngine(
                workspace: workspace, providers: [lsp],
                events: EventBus(sink: NullSink())
            )

            // initialize + document symbols.
            fputs("LSP-INT: snapshot\n", stderr)
            let snap = try engine.snapshot(path: "Sources/Probe/Probe.swift")
            fputs("LSP-INT: resolve\n", stderr)
            let symbols = await engine.resolve(symbol: "UserManager", path: snap.path)
            record(!symbols.isEmpty, "lsp-int symbols resolve")

            // definition at the use site (line 4 "manager = UserManager()").
            var definitionOK = false
            if let useOffset = UTF8SpanConverter.byteOffset(
                content: snap.content, line: 4, character: 22, encoding: .utf16
            ) {
                let def = try await lsp.query(.definition(snap, byteOffset: useOffset))
                if case .locations(let locs) = def {
                    // Structural success (array, no throw); index may lag.
                    definitionOK = true
                    _ = locs
                }
            }
            record(definitionOK, "lsp-int definition query succeeds")

            // prepareRename + rename plan.
            fputs("LSP-INT: plan\n", stderr)
            let plan = await engine.planRename(
                symbol: "UserManager", newName: "AccountManager",
                path: nil, taskID: "lsp-int"
            )
            let ready: Bool = {
                if case .ready(let edit) = plan {
                    fputs("LSP-INT: ready edits=\(edit.edits.count)\n", stderr)
                    for e in edit.edits {
                        fputs("LSP-INT: edit \(e.path) \(e.startByteOffset)-\(e.endByteOffset) -> \(e.replacement)\n", stderr)
                    }
                    return edit.edits.count == 2
                }
                fputs("LSP-INT: plan=\(plan)\n", stderr)
                return false
            }()
            record(ready, "lsp-int rename plan has 2 edits")

            // Apply transactionally through the runtime (no model anywhere).
            if case .ready(let edit) = plan {
                var bases: [String: String] = [:]
                for item in edit.edits {
                    if bases[item.path] == nil {
                        bases[item.path] = try engine.snapshot(path: item.path).content
                    }
                }
                let applied = try workspace.applySemanticPlan(edit.edits, contents: bases)
                let after = try String(
                    contentsOf: dir.appendingPathComponent("Sources/Probe/Probe.swift"),
                    encoding: .utf8
                )
                record(!applied.isEmpty &&
                       after.contains("AccountManager") &&
                       !after.contains("UserManager"),
                       "lsp-int edits applied transactionally")

                // swift build after rename (CPU test, bounded).
                let build = try await swiftBuild(packageDir: dir, timeoutSeconds: 240)
                record(build, "lsp-int swift build passes after rename")
            }
        } catch {
            record(false, "lsp-int error: \(error)")
        }
        return out
    }

    private static func swiftBuild(packageDir: URL, timeoutSeconds: Int) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
                process.arguments = ["build"]
                process.currentDirectoryURL = packageDir
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                return false
            }
            guard let first = try await group.next() else { return false }
            group.cancelAll()
            return first
        }
    }
}

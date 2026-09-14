import Foundation

// MARK: - v0.31 Context Engine deterministic tests (A-O) + perf (§24)

struct ContextCheckResult {
    var passed: Bool
    var name: String
}

enum ContextSelfTest {
    static let widgetSwift = "struct Widget {\n    func render() -> String { \"w\" }\n}\nlet widget = Widget()\n"

    static func makeWorld(files: [String: String]) throws
        -> (URL, Workspace, FakeCodeIntelligenceProvider, CodeIntelligenceEngine, ContextEngine)
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacyagent-ctx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url)
        }
        let policy = PolicyEngine(mode: .workspace, allowMCP: false)
        let runtime = RuntimeEnvironment.probe(projectURL: dir)
        let workspace = Workspace(
            root: dir, shellTimeoutSeconds: 30, policy: policy, runtime: runtime
        )
        let fake = FakeCodeIntelligenceProvider()
        fake.define(contents: files)
        let codeIntel = CodeIntelligenceEngine(
            workspace: workspace, providers: [fake],
            events: EventBus(sink: NullSink())
        )
        let ctx = ContextEngine(
            workspace: workspace, codeIntel: codeIntel,
            events: EventBus(sink: NullSink())
        )
        // Prime the graph so file existence/content is known truth.
        for name in files.keys {
            _ = try workspace.readSnapshot(path: name)
        }
        return (dir, workspace, fake, codeIntel, ctx)
    }

    static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    static func widgetSymbols() -> [FakeSymbolDef] {
        [FakeSymbolDef(
            name: "Widget", kind: .struct, path: "Widget.swift",
            line: 0, utf16Start: 7, utf16End: 13, container: nil
        )]
    }

    static func baseRequest(
        task: String = "task-1",
        targetPath: String? = "Widget.swift",
        targetSymbol: String? = "Widget",
        budget: ContextBudget = .default,
        maxLevel: ContextLevel = .l2
    ) -> ContextRequest {
        ContextRequest(
            taskID: task, userText: "do it", specSummary: "test spec",
            requirement: "mutate Widget.swift", purpose: .editArtifact,
            targetPath: targetPath, targetSymbol: targetSymbol,
            budget: budget, pinned: nil, recentFailure: nil,
            maxLevel: maxLevel, recentEvidence: [],
            conversation: "", projectInstructions: "", maxTokensHint: nil
        )
    }

    static func runAll() async -> [ContextCheckResult] {
        var out: [ContextCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(ContextCheckResult(passed: passed, name: name))
        }

        // A. target r1 in bundle; edit r1->r2; old bundle stale.
        do {
            let (dir, ws, fake, codeIntel, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            fake.define(symbols: widgetSymbols())
            let snap = try codeIntel.snapshot(path: "Widget.swift")
            let rev = ws.graph.currentRevisionID(path: "Widget.swift")
            let (bundle, _) = await ctx.compile(baseRequest())
            let hasTarget = bundle.items.contains {
                $0.kind == .targetSymbol && $0.revision == rev
            }
            _ = try ws.editFile("Widget.swift", old: "render", new: "draw")
            let stale = !ctx.isFresh(bundle)
            let (bundle2, _) = await ctx.compile(baseRequest())
            record(hasTarget && stale && ctx.isFresh(bundle2) &&
                   bundle2.revisions["Widget.swift"] == ws.graph.currentRevisionID(path: "Widget.swift") &&
                   snap.revision == rev,
                   "ctx-A revision-bound bundle goes stale on edit")
        } catch {
            record(false, "ctx-A revision-bound bundle goes stale on edit")
        }

        // B. symbol span preferred over whole file.
        do {
            let (dir, ws, fake, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            _ = ws
            fake.define(symbols: widgetSymbols())
            let (bundle, _) = await ctx.compile(baseRequest())
            let symbolItems = bundle.items.filter { $0.kind == .targetSymbol }
            let wholeFile = bundle.items.contains {
                $0.kind == .targetRange && $0.content.contains("let widget = Widget()")
            }
            record(symbolItems.count == 1 && !wholeFile,
                   "ctx-B symbol span beats whole file")
        } catch {
            record(false, "ctx-B symbol span beats whole file")
        }

        // C. definition included, 20 unrelated files excluded.
        do {
            var files = ["Widget.swift": widgetSwift,
                         "Main.swift": "let m = Widget()\n"]
            for i in 0..<20 {
                files["Unrelated\(i).swift"] = "struct Junk\(i) {}\n"
            }
            let (dir, ws, fake, _, ctx) = try makeWorld(files: files)
            defer { cleanup(dir) }
            _ = ws
            fake.define(symbols: widgetSymbols())
            fake.defineReferences(symbol: "Widget", refs: [FakeRefDef(
                path: "Main.swift", line: 0, utf16Start: 8, utf16End: 14
            )])
            let (bundle, _) = await ctx.compile(baseRequest(maxLevel: .l2))
            let paths = Set(bundle.items.compactMap(\.path))
            let reference = bundle.items.first {
                $0.kind == .reference && $0.path == "Main.swift"
            }
            record(paths.contains("Main.swift") &&
                   !paths.contains { $0.hasPrefix("Unrelated") } &&
                   reference?.content.contains("bytes 8..<14") == true &&
                   reference?.content.hasSuffix("\nWidget") == true,
                   "ctx-C neighborhood only, no unrelated files")
        } catch {
            record(false, "ctx-C neighborhood only, no unrelated files")
        }

        // D. fresh diagnostic on target: included, high priority.
        do {
            let (dir, ws, fake, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            let rev = ws.graph.currentRevisionID(path: "Widget.swift")
            fake.define(symbols: widgetSymbols())
            fake.defineDiagnostics([DiagnosticFact(
                path: "Widget.swift", revision: rev ?? ArtifactRevisionID(),
                message: "type mismatch here", severity: "error"
            )])
            let (bundle, _) = await ctx.compile(baseRequest(maxLevel: .l3))
            let diag = bundle.items.first { $0.kind == .diagnostic }
            record(diag != nil && (diag?.priority ?? 99) <= 10 &&
                   diag?.revision == rev,
                   "ctx-D fresh diagnostic prioritized with revision")
        } catch {
            record(false, "ctx-D fresh diagnostic prioritized with revision")
        }

        // E. stale-revision diagnostic is not current truth.
        do {
            let (dir, _, fake, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            fake.define(symbols: widgetSymbols())
            fake.defineDiagnostics([DiagnosticFact(
                path: "Widget.swift", revision: ArtifactRevisionID(),
                message: "old news", severity: "error"
            )])
            let (bundle, _) = await ctx.compile(baseRequest(maxLevel: .l3))
            record(!bundle.items.contains {
                $0.kind == .diagnostic && $0.content.contains("old news")
            }, "ctx-E stale diagnostic excluded")
        } catch {
            record(false, "ctx-E stale diagnostic excluded")
        }

        // F. tiny budget keeps target/task, drops low-priority references.
        do {
            var files = ["Widget.swift": widgetSwift]
            for i in 0..<5 {
                files["Use\(i).swift"] = "let u\(i) = Widget()\n"
            }
            let (dir, ws, fake, _, ctx) = try makeWorld(files: files)
            defer { cleanup(dir) }
            _ = ws
            fake.define(symbols: widgetSymbols())
            fake.defineReferences(symbol: "Widget", refs: (0..<5).map { i in
                FakeRefDef(path: "Use\(i).swift", line: 0, utf16Start: 9, utf16End: 15)
            })
            let tiny = ContextBudget(
                maxEstimatedTokens: 60, maxFiles: 8, maxSymbols: 10, maxDepth: 2
            )
            let (bundle, _) = await ctx.compile(baseRequest(budget: tiny))
            let hasTarget = bundle.items.contains { $0.kind == .targetSymbol }
            let hasTask = bundle.items.contains { $0.kind == .task }
            let droppedRefs = bundle.dropped.contains { $0.id.hasPrefix("reference:") }
            record(hasTarget && hasTask && droppedRefs &&
                   bundle.estimatedTokens <= 120,
                   "ctx-F budget drops by priority, keeps target")
        } catch {
            record(false, "ctx-F budget drops by priority, keeps target")
        }

        // G. identical state => deterministic identical ordering.
        do {
            let (dir, _, _, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            let (first, _) = await ctx.compile(baseRequest())
            ctx.clearCache()
            let (second, _) = await ctx.compile(baseRequest())
            record(first.serialize() == second.serialize(),
                   "ctx-G deterministic bundle ordering")
        } catch {
            record(false, "ctx-G deterministic bundle ordering")
        }

        // G2. Request-derived content participates in cache identity.
        do {
            let (dir, _, _, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            var firstRequest = baseRequest()
            firstRequest.userText = "first user intent"
            firstRequest.projectInstructions = "first rule"
            let (first, _) = await ctx.compile(firstRequest)
            var secondRequest = firstRequest
            secondRequest.userText = "second user intent"
            secondRequest.specSummary = "changed spec"
            secondRequest.projectInstructions = "second rule"
            secondRequest.pinned = UserPinnedContext(
                path: nil, symbol: "Widget", selection: "selected declaration"
            )
            let (second, telemetry) = await ctx.compile(secondRequest)
            record(
                !telemetry.cacheHit && !second.fromCache &&
                first.serialize() != second.serialize() &&
                second.items.contains {
                    $0.kind == .task && $0.content.contains("second user intent")
                } && second.items.contains {
                    $0.kind == .projectInstruction && $0.content == "second rule"
                },
                "ctx-G2 cache identity includes original intent and instructions"
            )
        } catch {
            record(false, "ctx-G2 cache identity includes original intent and instructions")
        }

        // H. validation failure names FooProtocol -> next bundle expands it.
        do {
            let files = [
                "Widget.swift": widgetSwift,
                "Protocols.swift": "protocol FooProtocol {}\n"
            ]
            let (dir, _, _, _, ctx) = try makeWorld(files: files)
            defer { cleanup(dir) }
            var req = baseRequest()
            req.recentFailure = "validation failed: type 'Widget' does not conform to protocol 'FooProtocol'"
            let (bundle, _) = await ctx.compile(req)
            let mentionsFoo = bundle.items.contains {
                $0.content.contains("FooProtocol")
            }
            let reasoned = bundle.items.contains {
                $0.reason == .recoveryFromFailure && $0.content.contains("FooProtocol")
            }
            record(mentionsFoo && reasoned, "ctx-H failure expands context with reason")
        } catch {
            record(false, "ctx-H failure expands context with reason")
        }

        // I. user-pinned fresh artifact included.
        do {
            let (dir, _, _, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            var req = baseRequest(targetPath: nil, targetSymbol: nil)
            req.pinned = UserPinnedContext(
                path: "Widget.swift", symbol: nil, selection: nil
            )
            let (bundle, _) = await ctx.compile(req)
            record(bundle.items.contains {
                $0.kind == .userPinned && $0.path == "Widget.swift" &&
                $0.freshness == .current
            }, "ctx-I pinned fresh artifact included")
        } catch {
            record(false, "ctx-I pinned fresh artifact included")
        }

        // J. pinned artifact externally changed -> rebuilt on new revision.
        do {
            let (dir, ws, _, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            var req = baseRequest(targetPath: nil, targetSymbol: nil)
            req.pinned = UserPinnedContext(
                path: "Widget.swift", symbol: nil, selection: nil
            )
            let (first, _) = await ctx.compile(req)
            try Data("externally changed".utf8).write(
                to: dir.appendingPathComponent("Widget.swift"), options: .atomic)
            _ = try ws.readFile("Widget.swift")
            let (second, _) = await ctx.compile(req)
            let firstRev = first.items.first { $0.kind == .userPinned }?.revision
            let secondRev = second.items.first { $0.kind == .userPinned }?.revision
            record(firstRev != secondRev && second.items.contains {
                $0.kind == .userPinned && $0.freshness == .current
            }, "ctx-J pinned rebuilt on new revision")
        } catch {
            record(false, "ctx-J pinned rebuilt on new revision")
        }

        // M. stale bundle before send -> recompile, never sent stale.
        do {
            let (dir, ws, _, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            let (bundle, _) = await ctx.compile(baseRequest())
            _ = try ws.editFile("Widget.swift", old: "render", new: "draw")
            let detectedStale = !ctx.isFresh(bundle)
            let (fresh, _) = await ctx.compile(baseRequest())
            record(detectedStale && ctx.isFresh(fresh),
                   "ctx-M stale detected, recompiled fresh")
        } catch {
            record(false, "ctx-M stale detected, recompiled fresh")
        }

        // N. cache wipe keeps truth/evidence intact (rebuild identical).
        do {
            let (dir, _, _, _, ctx) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            let (bundle, _) = await ctx.compile(baseRequest())
            let hadCached = ctx.cachedCount() > 0
            ctx.clearCache()
            let (again, _) = await ctx.compile(baseRequest())
            record(hadCached && ctx.cachedCount() > 0 &&
                   again.serialize() == bundle.serialize(),
                   "ctx-N cache wipe rebuilds identical truth")
        } catch {
            record(false, "ctx-N cache wipe rebuilds identical truth")
        }

        // O (+§24 perf shape). 150 unrelated files stay out; bounded.
        do {
            var files = ["Widget.swift": widgetSwift]
            for i in 0..<150 {
                files["Lib\(i).swift"] = "struct Lib\(i) { let x = \(i) }\n"
            }
            let (dir, ws, fake, _, ctx) = try makeWorld(files: files)
            defer { cleanup(dir) }
            _ = ws
            fake.define(symbols: widgetSymbols())
            let before = Date()
            let (bundle, telemetry) = await ctx.compile(baseRequest())
            let ms = Date().timeIntervalSince(before) * 1000
            let paths = Set(bundle.items.compactMap(\.path))
            let leaked = paths.contains { $0.hasPrefix("Lib") }
            record(!leaked && bundle.estimatedTokens <= ContextBudget.default.maxEstimatedTokens &&
                   telemetry.itemCount == bundle.items.count && ms < 30_000,
                   "ctx-O bounded bundle in large project")
        } catch {
            record(false, "ctx-O bounded bundle in large project")
        }

        return out
    }
}

extension ContextSelfTest {
    /// Rename fixture world: real registry + Fake-backed code intelligence.
    static func makeRenameWorld(newText: [String: String]? = nil) throws -> (
        URL, Workspace, ToolRegistry, RuntimeCoordinator, FakeModelProvider,
        CodeIntelligenceEngine, ContextEngine
    ) {
        let files = ["A.swift": CodeIntelSelfTest.aSwift,
                     "B.swift": CodeIntelSelfTest.bSwift]
        let (dir, ws, _, runtime, policy) = try CodeIntelSelfTest.makeProject(files: files)
        let fake = FakeCodeIntelligenceProvider()
        fake.define(contents: files)
        fake.define(symbols: [FakeSymbolDef(
            name: "UserManager", kind: .struct, path: "A.swift",
            line: 0, utf16Start: 7, utf16End: 18, container: nil
        )])
        fake.defineReferences(symbol: "UserManager", refs: [FakeRefDef(
            path: "B.swift", line: 2, utf16Start: 12, utf16End: 23
        )])
        let aEdit = newText?["A.swift"] ?? "AccountManager"
        let bEdit = newText?["B.swift"] ?? "AccountManager"
        fake.defineRename(symbol: "UserManager", newName: "AccountManager", edits: [
            FakeEditDef(path: "A.swift", startLine: 0, startChar: 7,
                        endLine: 0, endChar: 18, newText: aEdit),
            FakeEditDef(path: "A.swift", startLine: 3, startChar: 14,
                        endLine: 3, endChar: 25, newText: aEdit),
            FakeEditDef(path: "B.swift", startLine: 2, startChar: 12,
                        endLine: 2, endChar: 23, newText: bEdit)
        ])
        let codeIntel = CodeIntelligenceEngine(
            workspace: ws, providers: [fake],
            events: EventBus(sink: NullSink())
        )
        let computationRouter = ComputationRouter(events: EventBus(sink: NullSink()))
        let registry = ToolRegistry(
            workspace: ws, mcp: MCPBridge(policy: policy),
            events: EventBus(sink: NullSink()), runtime: runtime,
            codeIntelligence: codeIntel,
            computationRouter: computationRouter
        )
        let ctx = ContextEngine(
            workspace: ws, codeIntel: codeIntel,
            events: EventBus(sink: NullSink())
        )
        let coordinator = RuntimeCoordinator(
            executor: registry, events: EventBus(sink: NullSink()),
            projectInstructions: "test", contextEngine: ctx,
            computationRouter: computationRouter
        )
        return (dir, ws, registry, coordinator, FakeModelProvider(), codeIntel, ctx)
    }

    static func renameInput() -> RuntimeTaskInput {
        RuntimeTaskInput(
            userText: "rename UserManager to AccountManager",
            decision: .forMode(.agent, source: .fast),
            maxRounds: 4, sessionExcerpt: "", projectInstructions: "test",
            runtimeContext: "",
            allowedTools: CoordinatorSelfTest.allTools.union(["semantic_rename"]),
            agentMaxTokens: nil
        )
    }

    static func runWithCoordinator() async -> [ContextCheckResult] {
        var out: [ContextCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(ContextCheckResult(passed: passed, name: name))
        }

        func makeIntelligenceExecutor() async -> (ScriptExecutor, TurnDecision) {
            let executor = ScriptExecutor()
            let agent = TurnDecision.forMode(.agent, source: .fast)
            let create = TaskCompiler.compile(
                userText: "Создай budget_lab.html, проверь файл и запусти его.",
                decision: agent
            )
            let continuity = TaskContinuity(
                isContinuation: true, priorTaskID: create.id,
                priorGoal: "create", rootGoal: nil,
                artifactMinimumLineCount: nil, lastArtifact: "budget_lab.html",
                previousRequiredLaunch: true, failureFeedback: false,
                failureKind: .none, bareAction: false,
                revisionRequest: false, requestsNewArtifact: false
            )
            let modify = TaskCompiler.compile(
                userText: "Теперь измени его: добавь редактирование суммы.",
                decision: agent, continuity: continuity
            )
            await executor.begin(modify)
            return (executor, agent)
        }

        // K. deterministic rename: 0 context compiles, 0 model calls, DONE.
        do {
            let (dir, _, registry, coordinator, model, _, ctx) = try makeRenameWorld()
            defer { CodeIntelSelfTest.cleanup(dir) }
            await registry.beginTask(
                "rename UserManager to AccountManager",
                decision: .forMode(.agent, source: .fast)
            )
            let before = ctx.compileCount
            let result = try await coordinator.run(renameInput(), provider: model)
            let done: Bool = {
                if case .completedDeterministic = result.outcome { return true }
                return false
            }()
            record(model.callCount == 0 && ctx.compileCount == before &&
                   done && result.snapshot.isComplete,
                   "ctx-K rename needs no context or model")
        } catch {
            record(false, "ctx-K rename needs no context or model")
        }

        // L. intelligence-required task: 1 compile + 1 model call.
        do {
            let (dir, ws, _, _, _) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            let (executor, agent) = await makeIntelligenceExecutor()
            let ctx = ContextEngine(
                workspace: ws, codeIntel: nil,
                events: EventBus(sink: NullSink())
            )
            let coordinator = RuntimeCoordinator(
                executor: executor, events: EventBus(sink: NullSink()),
                projectInstructions: "test", contextEngine: ctx
            )
            let model = FakeModelProvider()
            model.script([.doneProse])
            let input = RuntimeTaskInput(
                userText: "test", decision: agent, maxRounds: 1,
                sessionExcerpt: "", projectInstructions: "test",
                runtimeContext: "",
                allowedTools: CoordinatorSelfTest.allTools,
                agentMaxTokens: nil
            )
            _ = try await coordinator.run(input, provider: model)
            let prompt = model.requests.first?.prompt ?? ""
            record(model.callCount == 1 && ctx.compileCount == 1 &&
                   prompt.contains("Do only this intelligence step") &&
                   prompt.contains("prose, markdown, or a fenced code proposal does NOT satisfy") &&
                   prompt.contains("CONTEXT BUNDLE") &&
                   prompt.contains("ORIGINAL USER REQUEST:\ntest"),
                   "ctx-L one intelligence round, one compile")
        } catch {
            record(false, "ctx-L one intelligence round, one compile")
        }

        // L2. Recoverable tool guidance remains control text beside context.
        do {
            let (dir, ws, _, _, _) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            let (executor, agent) = await makeIntelligenceExecutor()
            executor.failOnce = ["edit_file"]
            let ctx = ContextEngine(
                workspace: ws, codeIntel: nil,
                events: EventBus(sink: NullSink())
            )
            let coordinator = RuntimeCoordinator(
                executor: executor, events: EventBus(sink: NullSink()),
                projectInstructions: "test", contextEngine: ctx
            )
            let model = FakeModelProvider()
            model.script([
                ScriptedResponse(
                    toolCalls: [NormalizedToolInvocation(
                        name: "edit_file",
                        arguments: [
                            "path": "budget_lab.html", "old": "a", "new": "b"
                        ],
                        source: .provider
                    )],
                    format: .native
                ),
                .doneProse
            ])
            let input = RuntimeTaskInput(
                userText: "recover this edit", decision: agent, maxRounds: 2,
                sessionExcerpt: "", projectInstructions: "test",
                runtimeContext: "", allowedTools: CoordinatorSelfTest.allTools,
                agentMaxTokens: nil
            )
            _ = try await coordinator.run(input, provider: model)
            let recovery = model.requests.dropFirst().first?.prompt ?? ""
            record(
                model.callCount == 2 &&
                recovery.contains("RECOVERABLE TOOL ERROR") &&
                recovery.contains("Correct only the unresolved failed tool call") &&
                recovery.contains("CONTEXT BUNDLE"),
                "ctx-L2 recoverable control prompt survives context composition"
            )
        } catch {
            record(false, "ctx-L2 recoverable control prompt survives context composition")
        }

        // L3. Incomplete textual-call retry guidance also remains control text.
        do {
            let (dir, ws, _, _, _) = try makeWorld(files: ["Widget.swift": widgetSwift])
            defer { cleanup(dir) }
            let (executor, agent) = await makeIntelligenceExecutor()
            let ctx = ContextEngine(
                workspace: ws, codeIntel: nil,
                events: EventBus(sink: NullSink())
            )
            let coordinator = RuntimeCoordinator(
                executor: executor, events: EventBus(sink: NullSink()),
                projectInstructions: "test", contextEngine: ctx
            )
            let model = FakeModelProvider()
            model.script([
                ScriptedResponse(
                    text: "<tool_call>", toolCalls: [], format: .textFallback
                ),
                .doneProse
            ])
            let input = RuntimeTaskInput(
                userText: "finish this edit", decision: agent, maxRounds: 2,
                sessionExcerpt: "", projectInstructions: "test",
                runtimeContext: "", allowedTools: CoordinatorSelfTest.allTools,
                agentMaxTokens: nil
            )
            _ = try await coordinator.run(input, provider: model)
            let retry = model.requests.dropFirst().first?.prompt ?? ""
            record(
                model.callCount == 2 &&
                retry.contains("previous textual tool call was incomplete") &&
                retry.contains("Retry that same required action exactly once") &&
                retry.contains("CONTEXT BUNDLE"),
                "ctx-L3 incomplete-call control prompt survives context composition"
            )
        } catch {
            record(false, "ctx-L3 incomplete-call control prompt survives context composition")
        }

        // L4. A deterministic action that changes no state is attempted once.
        do {
            let executor = ScriptExecutor()
            executor.noProgress = ["semantic_rename"]
            let agent = TurnDecision.forMode(.agent, source: .fast)
            let spec = TaskCompiler.compile(
                userText: "rename UserManager to AccountManager",
                decision: agent
            )
            await executor.begin(spec)
            let model = FakeModelProvider()
            let coordinator = RuntimeCoordinator(
                executor: executor, events: EventBus(sink: NullSink())
            )
            let input = RuntimeTaskInput(
                userText: spec.originalRequest, decision: agent, maxRounds: 4,
                sessionExcerpt: "", projectInstructions: "",
                runtimeContext: "",
                allowedTools: CoordinatorSelfTest.allTools.union(["semantic_rename"]),
                agentMaxTokens: nil
            )
            let result = try await coordinator.run(input, provider: model)
            let incomplete: Bool = {
                if case .incomplete = result.outcome { return true }
                return false
            }()
            record(
                incomplete && !result.snapshot.isComplete &&
                result.deterministicActions == 1 && model.callCount == 0,
                "ctx-L4 unchanged deterministic action is attempted once"
            )
        } catch {
            record(false, "ctx-L4 unchanged deterministic action is attempted once")
        }

        return out
    }
}

extension ContextSelfTest {
    /// v0.29/§25 SwiftPM fixture: rename flows through project-level
    /// `swift build` (ProjectProfile-suggested, never invented).
    static func makePackageWorld(partial: Bool = false) throws -> (
        URL, Workspace, ToolRegistry, RuntimeCoordinator, FakeModelProvider,
        FakeCodeIntelligenceProvider, CodeIntelligenceEngine
    ) {
        let aDefinitionLine = "public struct UserManager {"
        let aUsageLine = "public let manager = UserManager()"
        let bUsageLine = "    let m = UserManager()"
        let aSwift = [
            aDefinitionLine,
            "    public init() {}",
            "    public func greet() -> String { \"hi\" }",
            "}",
            aUsageLine,
            ""
        ].joined(separator: "\n")
        let bSwift = [
            "public func useIt() -> String {",
            bUsageLine,
            "    return m.greet()",
            "}",
            ""
        ].joined(separator: "\n")
        let files = [
            "Package.swift": [
                "// swift-tools-version: 5.9",
                "import PackageDescription",
                "let package = Package(name: \"Pkg\", targets: [.target(name: \"Pkg\")])",
                ""
            ].joined(separator: "\n"),
            "Sources/Pkg/A.swift": aSwift,
            "Sources/Pkg/B.swift": bSwift
        ]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacyagent-pkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url)
        }
        let policy = PolicyEngine(mode: .workspace, allowMCP: false)
        let runtime = RuntimeEnvironment.probe(projectURL: dir)
        let ws = Workspace(
            root: dir, shellTimeoutSeconds: 120, policy: policy, runtime: runtime
        )
        let fake = FakeCodeIntelligenceProvider()
        fake.define(contents: ["Sources/Pkg/A.swift": aSwift,
                               "Sources/Pkg/B.swift": bSwift])
        let definitionRange = (aDefinitionLine as NSString).range(of: "UserManager")
        let aUsageRange = (aUsageLine as NSString).range(of: "UserManager")
        let bUsageRange = (bUsageLine as NSString).range(of: "UserManager")
        fake.define(symbols: [FakeSymbolDef(
            name: "UserManager", kind: .struct, path: "Sources/Pkg/A.swift",
            line: 0, utf16Start: definitionRange.location,
            utf16End: NSMaxRange(definitionRange), container: nil
        )])
        fake.defineReferences(symbol: "UserManager", refs: [
            FakeRefDef(
                path: "Sources/Pkg/A.swift", line: 4,
                utf16Start: aUsageRange.location, utf16End: NSMaxRange(aUsageRange)
            ),
            FakeRefDef(
                path: "Sources/Pkg/B.swift", line: 1,
                utf16Start: bUsageRange.location, utf16End: NSMaxRange(bUsageRange)
            )
        ])
        // Full rename (success) or definition-only (usages break the
        // project build while every file still parses: valid identifier,
        // incomplete application).
        func edit(_ path: String, _ l0: Int, _ c0: Int, _ l1: Int, _ c1: Int) -> FakeEditDef {
            FakeEditDef(path: path, startLine: l0, startChar: c0,
                        endLine: l1, endChar: c1, newText: "AccountManager")
        }
        var table = [edit(
            "Sources/Pkg/A.swift", 0, definitionRange.location,
            0, NSMaxRange(definitionRange)
        )]
        if !partial {
            table.append(edit(
                "Sources/Pkg/A.swift", 4, aUsageRange.location,
                4, NSMaxRange(aUsageRange)
            ))
            table.append(edit(
                "Sources/Pkg/B.swift", 1, bUsageRange.location,
                1, NSMaxRange(bUsageRange)
            ))
        }
        fake.defineRename(symbol: "UserManager", newName: "AccountManager", edits: table)
        let codeIntel = CodeIntelligenceEngine(
            workspace: ws, providers: [fake],
            events: EventBus(sink: NullSink())
        )
        let registry = ToolRegistry(
            workspace: ws, mcp: MCPBridge(policy: policy),
            events: EventBus(sink: NullSink()), runtime: runtime,
            codeIntelligence: codeIntel
        )
        let coordinator = RuntimeCoordinator(
            executor: registry, events: EventBus(sink: NullSink()),
            projectInstructions: "test"
        )
        return (dir, ws, registry, coordinator, FakeModelProvider(), fake, codeIntel)
    }

    static func packageInput() -> RuntimeTaskInput {
        RuntimeTaskInput(
            userText: "rename UserManager to AccountManager",
            decision: .forMode(.agent, source: .fast),
            maxRounds: 4, sessionExcerpt: "", projectInstructions: "test",
            runtimeContext: "",
            allowedTools: CoordinatorSelfTest.allTools.union(["semantic_rename"]),
            agentMaxTokens: nil
        )
    }

    static func runPackageValidation() async -> [ContextCheckResult] {
        var out: [ContextCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(ContextCheckResult(passed: passed, name: name))
        }

        // §25a. rename + project build succeeds -> DONE, 0 model calls.
        do {
            let (dir, _, registry, coordinator, model, fake, _) = try makePackageWorld()
            defer { CodeIntelSelfTest.cleanup(dir) }
            await registry.beginTask(
                "rename UserManager to AccountManager",
                decision: .forMode(.agent, source: .fast)
            )
            let result = try await coordinator.run(packageInput(), provider: model)
            let done: Bool = {
                if case .completedDeterministic = result.outcome { return true }
                return false
            }()
            record(done && result.snapshot.isComplete && model.callCount == 0 &&
                   fake.renameQueryCount == 1,
                   "ctx-PKG project build gates rename DONE")
        } catch {
            record(false, "ctx-PKG project build gates rename DONE")
        }

        // §25b. rename applies but project build fails -> reverted, NOT DONE.
        do {
            let (dir, ws, registry, coordinator, model, fake, _) = try makePackageWorld(
                partial: true
            )
            defer { CodeIntelSelfTest.cleanup(dir) }
            await registry.beginTask(
                "rename UserManager to AccountManager",
                decision: .forMode(.agent, source: .fast)
            )
            let result = try await coordinator.run(packageInput(), provider: model)
            let done: Bool = {
                if case .completedDeterministic = result.outcome { return true }
                if case .completedSynthesis = result.outcome { return true }
                return false
            }()
            let diskA = try String(
                contentsOf: dir.appendingPathComponent("Sources/Pkg/A.swift"),
                encoding: .utf8
            )
            let journal = await registry.state.journalRecords()
            _ = ws
            record(!done && !result.snapshot.isComplete &&
                   !diskA.contains("Account") &&
                   !journal.contains { $0.kind == .mutation } &&
                   model.callCount == 0 &&
                   fake.renameQueryCount == 1 &&
                   result.deterministicActions == 1 &&
                   result.snapshot.validation.consecutiveToolFailures == 1,
                   "ctx-PKG failed build reverts once, stays active")
        } catch {
            record(false, "ctx-PKG failed build reverts once, stays active")
        }

        return out
    }
}

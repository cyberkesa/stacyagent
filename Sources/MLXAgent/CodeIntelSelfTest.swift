import Foundation

// MARK: - v0.30 Code Intelligence deterministic tests (A-L)
//
// Fake-backed engine + real Workspace/RuntimeState/EditEngine/ProtocolEngine.
// No ModelProvider calls where zero-model behavior is asserted.

struct CodeIntelCheckResult {
    var passed: Bool
    var name: String
}

enum CodeIntelSelfTest {
    static let aSwift = "struct UserManager {\n    func greet() -> String { \"hi\" }\n}\nlet manager = UserManager()\n"
    static let bSwift = "import Foundation\nfunc useIt() {\n    let m = UserManager()\n    print(m)\n}\n"
    static let uSwift = "struct \u{41C}\u{435}\u{43D}\u{435}\u{434}\u{436}\u{435}\u{440} {\n    let \u{438}\u{43C}\u{44F} = \"\u{442}\u{435}\u{441}\u{442} \u{1F389}\"\n}\n"

    static func makeProject(files: [String: String]) throws
        -> (URL, Workspace, RuntimeState, RuntimeEnvironment, PolicyEngine)
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slta-ci-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: dir.appendingPathComponent(name))
        }
        let policy = PolicyEngine(mode: .workspace, allowMCP: false)
        let runtime = RuntimeEnvironment.probe(projectURL: dir)
        let workspace = Workspace(
            root: dir, shellTimeoutSeconds: 30, policy: policy, runtime: runtime
        )
        return (dir, workspace, RuntimeState(), runtime, policy)
    }

    static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Engine with a scripted Fake over exact disk contents.
    static func makeEngine(
        workspace: Workspace,
        symbols: [FakeSymbolDef],
        contents: [String: String],
        renames: [(String, String, [FakeEditDef])] = [],
        refs: [(String, [FakeRefDef])] = [],
        store: SemanticFactStore = SemanticFactStore()
    ) -> (CodeIntelligenceEngine, FakeCodeIntelligenceProvider) {
        let fake = FakeCodeIntelligenceProvider()
        fake.define(contents: contents)
        fake.define(symbols: symbols)
        for (symbol, newName, edits) in renames {
            fake.defineRename(symbol: symbol, newName: newName, edits: edits)
        }
        for (symbol, references) in refs {
            fake.defineReferences(symbol: symbol, refs: references)
        }
        let engine = CodeIntelligenceEngine(
            workspace: workspace, providers: [fake],
            events: EventBus(sink: NullSink()), store: store
        )
        return (engine, fake)
    }

    static func runAll() async -> [CodeIntelCheckResult] {
        var out: [CodeIntelCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(CodeIntelCheckResult(passed: passed, name: name))
        }

        // A. document fact r1 fresh; edit -> r2; fact(r1) stale.
        do {
            let (dir, ws, _, _, _) = try makeProject(files: ["A.swift": aSwift])
            defer { cleanup(dir) }
            let (engine, fake) = makeEngine(
                workspace: ws,
                symbols: [FakeSymbolDef(
                    name: "UserManager", kind: .struct, path: "A.swift",
                    line: 0, utf16Start: 7, utf16End: 18, container: nil
                )],
                contents: ["A.swift": aSwift]
            )
            let first = await engine.resolve(symbol: "UserManager", path: "A.swift")
            let r1 = ws.graph.currentRevisionID(path: "A.swift")
            let key = SemanticFactKey(
                kind: .documentSymbols, path: "A.swift",
                subject: "doc", provider: "\(fake.providerID)"
            )
            let cachedBefore = engine.factStore.lookup(key)
            _ = try ws.editFile("A.swift", old: "greet", new: "welcome")
            let r2 = ws.graph.currentRevisionID(path: "A.swift")
            let second = await engine.resolve(symbol: "UserManager", path: "A.swift")
            let stale: Bool = {
                guard let fact = cachedBefore else { return false }
                if case .stale = engine.factStore.freshness(
                    of: fact, currentRevisions: ws.graph.currentMap()
                ) { return true }
                return false
            }()
            let r2bound = second.first?.symbol.nameSpan.revision == r2
            record(first.count == 1 && r1 != nil && r1 != r2 &&
                   fake.queryCount == 2 && stale && r2bound,
                   "ci-A document fact goes stale on edit")
        } catch {
            record(false, "ci-A document fact goes stale on edit")
        }

        // B. workspace refs @ E1; any edit -> E2; refs(E1) stale.
        do {
            let (dir, ws, _, _, _) = try makeProject(files: ["A.swift": aSwift])
            defer { cleanup(dir) }
            let (engine, _) = makeEngine(
                workspace: ws,
                symbols: [FakeSymbolDef(
                    name: "UserManager", kind: .struct, path: "A.swift",
                    line: 0, utf16Start: 7, utf16End: 18, container: nil
                )],
                contents: ["A.swift": aSwift]
            )
            _ = await engine.resolve(symbol: "UserManager", path: nil)
            let e1 = ws.graph.semanticGeneration()
            let key = SemanticFactKey(
                kind: .workspaceSymbols, path: nil,
                subject: "UserManager", provider: "fake-codeintel"
            )
            let fact = engine.factStore.lookup(key)
            _ = try ws.editFile("A.swift", old: "greet", new: "welcome")
            let e2 = ws.graph.semanticGeneration()
            let stale: Bool = {
                guard let fact else { return false }
                if case .stale = engine.factStore.workspaceFreshness(of: fact, epoch: e2) {
                    return true
                }
                return false
            }()
            record(fact != nil && e2 == e1 + 1 && stale,
                   "ci-B workspace facts invalidate on epoch bump")
        } catch {
            record(false, "ci-B workspace facts invalidate on epoch bump")
        }

        // C. UTF-16 -> UTF-8 conversion (ASCII, Cyrillic, emoji, combined).
        do {
            var ok = true
            func check(_ content: String, _ line: Int, _ char: Int, _ expected: Int?) {
                let got = UTF8SpanConverter.byteOffset(
                    content: content, line: line, character: char, encoding: .utf16
                )
                if got != expected { ok = false }
            }
            // ASCII baseline.
            check("struct UserManager {", 0, 7, 7)
            check("struct UserManager {", 0, 18, 18)
            // Cyrillic: "Менеджер" = 8 units, 16 bytes.
            let cyr = "struct Менеджер {"
            check(cyr, 0, 7, 7)
            check(cyr, 0, 15, 23)
            // Emoji: "🎉" = 2 units, 4 bytes.
            let emo = "let x = \"🎉\""
            check(emo, 0, 9, 9)
            check(emo, 0, 11, 13)
            // Combined e + acute (2 units, 3 bytes) then emoji.
            // Explicit scalars: U+0065 U+0301 U+1F389 (precomposed é differs!).
            let comb = "e\u{301}\u{1F389}"
            check(comb, 0, 0, 0)
            check(comb, 0, 1, 1)
            check(comb, 0, 2, 3)
            check(comb, 0, 4, 7)
            // ZWJ family: 8 units, 18 bytes total.
            let zwj = "👨‍👩‍👧!"
            check(zwj, 0, 0, 0)
            check(zwj, 0, 3, 7)
            check(zwj, 0, 8, 18)
            // Multi-line.
            check("ab\nвгд\n", 1, 2, 7)
            // Out of bounds -> nil.
            check("ab", 0, 5, nil)
            check("ab", 3, 0, nil)
            check("ab", 0, -1, nil)
            record(ok, "ci-C unicode coordinate conversion")
        }

        // D. overlapping edits are rejected; no mutation evidence.
        do {
            let (dir, ws, state, _, _) = try makeProject(files: ["A.swift": aSwift])
            defer { cleanup(dir) }
            await state.beginTask(ArtifactSelfTest.specFor("A.swift"))
            let (engine, _) = makeEngine(
                workspace: ws,
                symbols: [FakeSymbolDef(
                    name: "UserManager", kind: .struct, path: "A.swift",
                    line: 0, utf16Start: 7, utf16End: 18, container: nil
                )],
                contents: ["A.swift": aSwift],
                renames: [("UserManager", "AccountManager", [
                    FakeEditDef(path: "A.swift", startLine: 0, startChar: 7,
                                endLine: 0, endChar: 18, newText: "AccountManager"),
                    FakeEditDef(path: "A.swift", startLine: 0, startChar: 10,
                                endLine: 0, endChar: 20, newText: "X")
                ])]
            )
            _ = try engine.snapshot(path: "A.swift")
            let before = ws.graph.currentMap()
            let result = await engine.planRename(
                symbol: "UserManager", newName: "AccountManager",
                path: nil, taskID: "t"
            )
            let invalid: Bool = {
                if case .invalid = result { return true }
                return false
            }()
            let journal = await state.journalRecords()
            record(invalid && ws.graph.currentMap() == before &&
                   !journal.contains { $0.kind == .mutation },
                   "ci-D overlapping edits rejected without mutation")
        } catch {
            record(false, "ci-D overlapping edits rejected without mutation")
        }

        // E. edit outside the workspace is rejected.
        do {
            let (dir, ws, _, _, _) = try makeProject(files: ["A.swift": aSwift])
            defer { cleanup(dir) }
            let (engine, _) = makeEngine(
                workspace: ws,
                symbols: [FakeSymbolDef(
                    name: "UserManager", kind: .struct, path: "A.swift",
                    line: 0, utf16Start: 7, utf16End: 18, container: nil
                )],
                contents: ["A.swift": aSwift,
                           "../evil.swift": "struct UserManager {}"],
                renames: [("UserManager", "AccountManager", [
                    FakeEditDef(path: "../evil.swift", startLine: 0, startChar: 7,
                                endLine: 0, endChar: 18, newText: "AccountManager")
                ])]
            )
            let result = await engine.planRename(
                symbol: "UserManager", newName: "AccountManager",
                path: nil, taskID: "t"
            )
            let invalid: Bool = {
                if case .invalid = result { return true }
                return false
            }()
            record(invalid, "ci-E outside-workspace edit rejected")
        } catch {
            record(false, "ci-E outside-workspace edit rejected")
        }

        // F. multi-file rename via the real tool path.
        do {
            let (dir, ws, state, runtime, policy) = try makeProject(
                files: ["A.swift": aSwift, "B.swift": bSwift]
            )
            defer { cleanup(dir) }
            let (engine, _) = makeEngine(
                workspace: ws,
                symbols: [
                    FakeSymbolDef(name: "UserManager", kind: .struct,
                                  path: "A.swift", line: 0,
                                  utf16Start: 7, utf16End: 18, container: nil)
                ],
                contents: ["A.swift": aSwift, "B.swift": bSwift],
                renames: [("UserManager", "AccountManager", [
                    FakeEditDef(path: "A.swift", startLine: 0, startChar: 7,
                                endLine: 0, endChar: 18, newText: "AccountManager"),
                    FakeEditDef(path: "A.swift", startLine: 3, startChar: 14,
                                endLine: 3, endChar: 25, newText: "AccountManager"),
                    FakeEditDef(path: "B.swift", startLine: 2, startChar: 12,
                                endLine: 2, endChar: 23, newText: "AccountManager")
                ])],
                refs: [("UserManager", [FakeRefDef(
                    path: "B.swift", line: 2, utf16Start: 12, utf16End: 23
                )])]
            )
            let registry = ToolRegistry(
                workspace: ws, mcp: MCPBridge(policy: policy),
                events: EventBus(sink: NullSink()), runtime: runtime,
                codeIntelligence: engine
            )
            let revA1 = ws.graph.currentRevisionID(path: "A.swift")
            let revB1 = ws.graph.currentRevisionID(path: "B.swift")
            let result = await registry.executeNormalized(
                NormalizedToolInvocation(
                    name: "semantic_rename",
                    arguments: ["symbol": "UserManager", "new_name": "AccountManager"],
                    source: .protocolEngine
                ),
                allowed: ["semantic_rename"]
            )
            await state.beginTask(ArtifactSelfTest.specFor("A.swift"))
            _ = state
            let revA2 = ws.graph.currentRevisionID(path: "A.swift")
            let revB2 = ws.graph.currentRevisionID(path: "B.swift")
            let snapshot = await registry.state.taskSnapshot()
            let mutated = { (path: String) in
                snapshot.evidence.contains { item in
                    if case .mutated(_, let p, let changed, _) = item {
                        return p == path && changed
                    }
                    return false
                }
            }
            let diskA = try String(contentsOf: dir.appendingPathComponent("A.swift"),
                                   encoding: .utf8)
            let diskB = try String(contentsOf: dir.appendingPathComponent("B.swift"),
                                   encoding: .utf8)
            let journal = await registry.state.journalRecords()
            record(result.contains("renamed UserManager to AccountManager") &&
                   revA1 != revA2 && revB1 != revB2 &&
                   mutated("A.swift") && mutated("B.swift") &&
                   diskA.contains("AccountManager") && !diskA.contains("UserManager") &&
                   diskB.contains("AccountManager") && !diskB.contains("UserManager") &&
                   journal.contains {
                       $0.kind == .semantic && $0.symbol == "UserManager"
                   },
                   "ci-F multi-file rename with evidence per revision")
        } catch {
            record(false, "ci-F multi-file rename with evidence per revision")
        }

        // G. external change between plan and commit -> conflict, no overwrite.
        do {
            let (dir, ws, _, _, _) = try makeProject(files: ["B.swift": bSwift])
            defer { cleanup(dir) }
            let (engine, _) = makeEngine(
                workspace: ws,
                symbols: [FakeSymbolDef(
                    name: "UserManager", kind: .struct, path: "A.swift",
                    line: 0, utf16Start: 7, utf16End: 18, container: nil
                )],
                contents: ["B.swift": bSwift]
            )
            // Plan against r1...
            let snap = try engine.snapshot(path: "B.swift")
            let r1 = snap.revision
            let planEdits = [SemanticTextEdit(
                path: "B.swift", baseRevision: r1,
                startByteOffset: 0, endByteOffset: 0, replacement: "// "
            )]
            let contents = ["B.swift": snap.content]
            // ...then the world moves (external r2)...
            try Data("externally rewritten".utf8).write(
                to: dir.appendingPathComponent("B.swift"), options: .atomic)
            _ = try ws.readFile("B.swift")
            let r2 = ws.graph.currentRevisionID(path: "B.swift")
            // ...commit of the stale plan must conflict, never overwrite.
            var conflicted = false
            do {
                _ = try ws.applySemanticPlan(planEdits, contents: contents)
            } catch {
                conflicted = "\(error)".contains("revision conflict")
            }
            let disk = try String(contentsOf: dir.appendingPathComponent("B.swift"),
                                  encoding: .utf8)
            record(conflicted && r1 != r2 && disk == "externally rewritten" &&
                   ws.graph.currentRevisionID(path: "B.swift") == r2,
                   "ci-G stale plan conflicts instead of overwriting")
        } catch {
            record(false, "ci-G stale plan conflicts instead of overwriting")
        }

        // H. two identical candidates -> no mutation, ambiguity surfaced.
        do {
            let (dir, ws, state, _, _) = try makeProject(
                files: ["A.swift": aSwift, "B.swift": "struct UserManager {}\n"]
            )
            defer { cleanup(dir) }
            await state.beginTask(ArtifactSelfTest.specFor("A.swift"))
            let dupB = "struct UserManager {}\n"
            let (engine, _) = makeEngine(
                workspace: ws,
                symbols: [
                    FakeSymbolDef(name: "UserManager", kind: .struct,
                                  path: "A.swift", line: 0,
                                  utf16Start: 7, utf16End: 18, container: nil),
                    FakeSymbolDef(name: "UserManager", kind: .struct,
                                  path: "B.swift", line: 0,
                                  utf16Start: 7, utf16End: 18, container: nil)
                ],
                contents: ["A.swift": aSwift, "B.swift": dupB]
            )
            _ = try engine.snapshot(path: "A.swift")
            _ = try engine.snapshot(path: "B.swift")
            let before = ws.graph.currentMap()
            let result = await engine.planRename(
                symbol: "UserManager", newName: "AccountManager",
                path: nil, taskID: "t"
            )
            let ambiguous: Bool = {
                if case .ambiguous(let cands) = result { return cands.count == 2 }
                return false
            }()
            let journal = await state.journalRecords()
            record(ambiguous && ws.graph.currentMap() == before &&
                   !journal.contains { $0.kind == .mutation },
                   "ci-H ambiguity never auto-selected")
        } catch {
            record(false, "ci-H ambiguity never auto-selected")
        }

        return out
    }
}

extension CodeIntelSelfTest {
    /// Shared rename fixture: real registry + Fake-backed engine + coordinator.
    static func makeRenameWorld(newText: [String: String]? = nil) throws -> (
        URL, Workspace, ToolRegistry, RuntimeCoordinator, FakeModelProvider,
        FakeCodeIntelligenceProvider, CodeIntelligenceEngine
    ) {
        let files = ["A.swift": aSwift, "B.swift": bSwift]
        let (dir, ws, _, runtime, policy) = try makeProject(files: files)
        let fake = FakeCodeIntelligenceProvider()
        fake.define(contents: files)
        fake.define(symbols: [FakeSymbolDef(
            name: "UserManager", kind: .struct, path: "A.swift",
            line: 0, utf16Start: 7, utf16End: 18, container: nil
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
        fake.defineReferences(symbol: "UserManager", refs: [FakeRefDef(
            path: "B.swift", line: 2, utf16Start: 12, utf16End: 23
        )])
        let engine = CodeIntelligenceEngine(
            workspace: ws, providers: [fake],
            events: EventBus(sink: NullSink())
        )
        let registry = ToolRegistry(
            workspace: ws, mcp: MCPBridge(policy: policy),
            events: EventBus(sink: NullSink()), runtime: runtime,
            codeIntelligence: engine
        )
        let coordinator = RuntimeCoordinator(
            executor: registry, events: EventBus(sink: NullSink()),
            projectInstructions: "test"
        )
        let model = FakeModelProvider()
        return (dir, ws, registry, coordinator, model, fake, engine)
    }

    static func renameInput() -> RuntimeTaskInput {
        let decision = TurnDecision.forMode(.agent, source: .fast)
        let spec = TaskCompiler.compile(
            userText: "rename UserManager to AccountManager", decision: decision
        )
        _ = spec
        return RuntimeTaskInput(
            userText: "rename UserManager to AccountManager",
            decision: decision,
            maxRounds: 4,
            sessionExcerpt: "",
            projectInstructions: "test",
            runtimeContext: "",
            allowedTools: CoordinatorSelfTest.allTools.union(["semantic_rename"]),
            agentMaxTokens: nil
        )
    }

    static func runRename() async -> [CodeIntelCheckResult] {
        var out: [CodeIntelCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(CodeIntelCheckResult(passed: passed, name: name))
        }

        // I. explicit unambiguous rename: 0 ModelProvider calls.
        do {
            let (dir, ws, registry, coordinator, model, _, _) = try makeRenameWorld()
            defer { cleanup(dir) }
            await registry.beginTask(
                "rename UserManager to AccountManager",
                decision: .forMode(.agent, source: .fast)
            )
            let result = try await coordinator.run(renameInput(), provider: model)
            record(model.callCount == 0 &&
                   result.physicalGenerations == 0 &&
                   result.snapshot.isComplete,
                   "ci-I zero-model rename")
            _ = ws
        } catch {
            record(false, "ci-I zero-model rename")
        }

        // J. rename applies, but validation fails -> task != DONE, reverted.
        do {
            let (dir, ws, registry, coordinator, model, _, _) = try makeRenameWorld(
                newText: ["A.swift": "Account Manager", "B.swift": "Account Manager"]
            )
            defer { cleanup(dir) }
            await registry.beginTask(
                "rename UserManager to AccountManager",
                decision: .forMode(.agent, source: .fast)
            )
            let result = try await coordinator.run(renameInput(), provider: model)
            let done: Bool = {
                if case .completedDeterministic = result.outcome { return true }
                if case .completedSynthesis = result.outcome { return true }
                return false
            }()
            let diskA = try String(contentsOf: dir.appendingPathComponent("A.swift"),
                                   encoding: .utf8)
            let diskB = try String(contentsOf: dir.appendingPathComponent("B.swift"),
                                   encoding: .utf8)
            let journal = await registry.state.journalRecords()
            record(!done && !result.snapshot.isComplete &&
                   diskA == aSwift && diskB == bSwift &&
                   !journal.contains { $0.kind == .mutation } &&
                   model.callCount == 0,
                   "ci-J failed validation is not done")
            _ = ws
        } catch {
            record(false, "ci-J failed validation is not done")
        }

        // K. rename + fresh validation -> DONE, 0 model calls.
        do {
            let (dir, ws, registry, coordinator, model, _, _) = try makeRenameWorld()
            defer { cleanup(dir) }
            await registry.beginTask(
                "rename UserManager to AccountManager",
                decision: .forMode(.agent, source: .fast)
            )
            let result = try await coordinator.run(renameInput(), provider: model)
            let done: Bool = {
                if case .completedDeterministic = result.outcome { return true }
                return false
            }()
            let snapshot = result.snapshot
            let validationFresh = !snapshot.missingRequirements.contains {
                if case .validate = $0 { return true }
                return false
            }
            _ = ws
            _ = dir
            record(done && model.callCount == 0 && validationFresh &&
                   !result.displayText.isEmpty,
                   "ci-K validated rename completes model-free")
        } catch {
            record(false, "ci-K validated rename completes model-free")
        }

        // L. wiping the fact cache keeps graph/evidence truth intact.
        do {
            let (dir, ws, registry, coordinator, model, _, engine) = try makeRenameWorld()
            defer { cleanup(dir) }
            await registry.beginTask(
                "rename UserManager to AccountManager",
                decision: .forMode(.agent, source: .fast)
            )
            let result = try await coordinator.run(renameInput(), provider: model)
            let hadFacts = engine.factStore.count() > 0
            engine.factStore.clear()
            let snapshot = await registry.state.taskSnapshot()
            _ = ws
            _ = dir
            record(hadFacts && engine.factStore.count() == 0 &&
                   result.snapshot.isComplete && snapshot.isComplete,
                   "ci-L cache wipe preserves truth")
        } catch {
            record(false, "ci-L cache wipe preserves truth")
        }

        return out
    }
}

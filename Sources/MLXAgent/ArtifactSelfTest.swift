import Foundation

// MARK: - v0.29 ArtifactGraph / Evidence / Persistence tests (A-J)
//
// Real Workspace (tmp project) + real RuntimeState + real EditEngine +
// real ProtocolEngine evidence evaluation. No model. Mirrors the production
// ToolRegistry threading explicitly (revision passer + current-map push).

struct ArtifactCheckResult {
    var passed: Bool
    var name: String
}

enum ArtifactSelfTest {
    static func runAll() async -> [ArtifactCheckResult] {
        var out: [ArtifactCheckResult] = []
        func record(_ passed: Bool, _ name: String) {
            out.append(ArtifactCheckResult(passed: passed, name: name))
        }

        let v1 = "<html><body>v1</body></html>"
        let v2 = "<html><body>v2 extended</body></html>"

        func makeProject() throws -> (URL, Workspace, RuntimeState) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("slta-art-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let runtime = RuntimeEnvironment.probe(projectURL: dir)
            let workspace = Workspace(
                root: dir,
                shellTimeoutSeconds: 20,
                policy: PolicyEngine(mode: .workspace, allowMCP: false),
                runtime: runtime
            )
            return (dir, workspace, RuntimeState())
        }

        func specFor(_ path: String) -> TaskSpec {
            TaskSpec(
                id: TaskID(),
                parentID: nil,
                mode: .agent,
                kinds: [.modify],
                originalRequest: "test",
                targets: [ArtifactRef(path: path)],
                launchApplication: nil,
                desiredState: [],
                requirements: [
                    .observe(.path(path)),
                    .mutate(.path(path)),
                    .validate(.path(path))
                ],
                constraints: [],
                outputPolicy: .deterministicAck,
                compileConfidence: 1.0,
                compilerNotes: []
            )
        }

        func cleanup(_ dir: URL) {
            try? FileManager.default.removeItem(at: dir)
            let store = RuntimePersistence(projectPath: dir.path)
            try? FileManager.default.removeItem(at: store.directory)
        }

        // A. read r1 -> observed(r1), fresh.
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            await state.beginTask(specFor("a.html"))
            _ = try ws.writeFile("a.html", content: v1)
            await state.mutation("write_file", path: "a.html", content: v1, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let content = try ws.readFile("a.html")
            let rev = ws.graph.currentRevisionID(path: "a.html")
            await state.readBack(path: "a.html", content: content, revisionID: rev)
            await state.setCurrentRevisions(ws.graph.currentMap())
            let snapshot = await state.taskSnapshot()
            let freshObserved = !snapshot.missingRequirements.contains(.observe(.path("a.html")))
            let revMatch = snapshot.evidenceRevisions.compactMap { $0 }.contains(rev)
            record(freshObserved && rev != nil && revMatch, "art-A read binds current revision")
        } catch {
            record(false, "art-A read binds current revision")
        }

        // B. validate r1 -> validated(r1).
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            await state.beginTask(specFor("a.html"))
            _ = try ws.writeFile("a.html", content: v1)
            await state.mutation("write_file", path: "a.html", content: v1, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.readFile("a.html")
            await state.readBack(path: "a.html", content: v1,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.validateFile("a.html")
            await state.validationSuccess("validate_file", isRealValidation: true, path: "a.html",
                                          revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let snapshot = await state.taskSnapshot()
            record(!snapshot.missingRequirements.contains(.validate(.path("a.html"))),
                   "art-B validation binds current revision")
        } catch {
            record(false, "art-B validation binds current revision")
        }

        // C. edit r1 -> r2; validation(r1) no longer satisfies r2.
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            await state.beginTask(specFor("a.html"))
            _ = try ws.writeFile("a.html", content: v1)
            await state.mutation("write_file", path: "a.html", content: v1, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.validateFile("a.html")
            await state.validationSuccess("validate_file", isRealValidation: true, path: "a.html",
                                          revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let beforeEdit = await state.taskSnapshot()
            let wasSatisfied = !beforeEdit.missingRequirements.contains(.validate(.path("a.html")))
            _ = try ws.editFile("a.html", old: "v1", new: "v2 extended")
            await state.mutation("edit_file", path: "a.html", content: nil, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let afterEdit = await state.taskSnapshot()
            let nowMissing = afterEdit.missingRequirements.contains(.validate(.path("a.html")))
            record(wasSatisfied && nowMissing, "art-C edit stales prior validation")
        } catch {
            record(false, "art-C edit stales prior validation")
        }

        // D. own atomic edit -> r2 known without readback (hash from memory).
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            await state.beginTask(specFor("a.html"))
            _ = try ws.writeFile("a.html", content: v1)
            await state.mutation("write_file", path: "a.html", content: v1, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.editFile("a.html", old: "v1", new: "v2 extended")
            await state.mutation("edit_file", path: "a.html", content: nil, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let hashOK = ws.graph.currentHash(path: "a.html") == ArtifactHash.sha256(v2)
            let snapshot = await state.taskSnapshot()
            // Writer-knows: fresh mutation observes the revision, no readBack item needed.
            let observedFresh = !snapshot.missingRequirements.contains(.observe(.path("a.html")))
            let hasReadBack = snapshot.evidence.contains { item in
                if case .readBack = item { return true }
                return false
            }
            record(hashOK && observedFresh && !hasReadBack, "art-D own edit needs no readback")
        } catch {
            record(false, "art-D own edit needs no readback")
        }

        // E. external disk modification -> external r3, previous evidence stale.
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            await state.beginTask(specFor("a.html"))
            _ = try ws.writeFile("a.html", content: v1)
            await state.mutation("write_file", path: "a.html", content: v1, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.validateFile("a.html")
            await state.validationSuccess("validate_file", isRealValidation: true, path: "a.html",
                                          revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let rBefore = ws.graph.currentRevisionID(path: "a.html")
            try Data(v2.utf8).write(to: dir.appendingPathComponent("a.html"), options: .atomic)
            _ = try ws.readFile("a.html")
            await state.setCurrentRevisions(ws.graph.currentMap())
            let rAfter = ws.graph.currentRevisionID(path: "a.html")
            let snapshot = await state.taskSnapshot()
            record(rBefore != rAfter && ws.graph.isExternalCurrent(path: "a.html") &&
                   snapshot.missingRequirements.contains(.validate(.path("a.html"))),
                   "art-E external change stales evidence")
        } catch {
            record(false, "art-E external change stales evidence")
        }

        // F. restart restores graph + evidence correctly.
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            let spec = specFor("a.html")
            await state.beginTask(spec)
            _ = try ws.writeFile("a.html", content: v1)
            await state.mutation("write_file", path: "a.html", content: v1, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.validateFile("a.html")
            await state.validationSuccess("validate_file", isRealValidation: true, path: "a.html",
                                          revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let before = await state.taskSnapshot()
            let journal = await state.journalRecords()
            let store = RuntimePersistence(projectPath: dir.path)
            store.save(PersistedRuntimeState(
                schemaVersion: RuntimePersistence.schemaVersion,
                projectID: store.directory.lastPathComponent,
                projectPath: dir.path,
                savedAt: Date(),
                spec: before.spec,
                requirements: before.requirements,
                records: journal,
                itemRevisions: journal.map { $0.revisionID },
                current: before.artifactRevisions.mapValues { $0.rawValue },
                lastFailure: nil,
                artifacts: ws.graph.snapshot(revisionProvider: { ws.revisionRecord($0) })
            ))
            // Fresh process: new graph + new state.
            let restored = store.load()
            let graph2 = ArtifactGraph()
            let state2 = RuntimeState()
            var ok = false
            if let persisted = restored {
                graph2.restore(persisted.artifacts)
                var items: [TaskEvidence] = []
                for record in persisted.records {
                    items.append(record.legacyEvidence(transaction: nil))
                }
                await state2.restore(
                    spec: persisted.spec,
                    requirements: persisted.requirements,
                    items: items,
                    itemRevisions: persisted.itemRevisions.map { $0.map { ArtifactRevisionID($0) } },
                    records: persisted.records,
                    current: persisted.current.mapValues { ArtifactRevisionID($0) },
                    lastFailure: nil
                )
                let after = await state2.taskSnapshot()
                ok = graph2.currentRevisionID(path: "a.html") ==
                    ws.graph.currentRevisionID(path: "a.html") &&
                    after.evidence.count == before.evidence.count &&
                    !after.missingRequirements.contains(.validate(.path("a.html"))) &&
                    after.requirements == before.requirements
            }
            record(ok, "art-F restart restores graph and evidence")
        } catch {
            record(false, "art-F restart restores graph and evidence")
        }

        // G. restart after edit keeps current r2 (and r1 validation stays stale).
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            await state.beginTask(specFor("a.html"))
            _ = try ws.writeFile("a.html", content: v1)
            await state.mutation("write_file", path: "a.html", content: v1, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.validateFile("a.html")
            await state.validationSuccess("validate_file", isRealValidation: true, path: "a.html",
                                          revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.editFile("a.html", old: "v1", new: "v2 extended")
            await state.mutation("edit_file", path: "a.html", content: nil, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let r2 = ws.graph.currentRevisionID(path: "a.html")
            let journal = await state.journalRecords()
            let before = await state.taskSnapshot()
            let store = RuntimePersistence(projectPath: dir.path)
            store.save(PersistedRuntimeState(
                schemaVersion: RuntimePersistence.schemaVersion,
                projectID: store.directory.lastPathComponent,
                projectPath: dir.path,
                savedAt: Date(),
                spec: before.spec,
                requirements: before.requirements,
                records: journal,
                itemRevisions: journal.map { $0.revisionID },
                current: before.artifactRevisions.mapValues { $0.rawValue },
                lastFailure: nil,
                artifacts: ws.graph.snapshot(revisionProvider: { ws.revisionRecord($0) })
            ))
            let graph2 = ArtifactGraph()
            let state2 = RuntimeState()
            var ok = false
            if let persisted = store.load() {
                graph2.restore(persisted.artifacts)
                var items: [TaskEvidence] = []
                for record in persisted.records {
                    items.append(record.legacyEvidence(transaction: nil))
                }
                await state2.restore(
                    spec: persisted.spec,
                    requirements: persisted.requirements,
                    items: items,
                    itemRevisions: persisted.itemRevisions.map { $0.map { ArtifactRevisionID($0) } },
                    records: persisted.records,
                    current: persisted.current.mapValues { ArtifactRevisionID($0) },
                    lastFailure: nil
                )
                let after = await state2.taskSnapshot()
                ok = graph2.currentRevisionID(path: "a.html") == r2 &&
                    graph2.currentHash(path: "a.html") == ArtifactHash.sha256(v2) &&
                    after.missingRequirements.contains(.validate(.path("a.html")))
            }
            record(ok, "art-G restart keeps current r2 with stale validation")
        } catch {
            record(false, "art-G restart keeps current r2 with stale validation")
        }

        // H. model prose "validated" creates no ValidationEvidence.
        do {
            let executor = ScriptExecutor()
            let agent = TurnDecision.forMode(.agent, source: .fast)
            let createText = "Создай budget_lab.html, проверь файл и запусти его."
            let create = TaskCompiler.compile(userText: createText, decision: agent)
            let continuity = TaskContinuity(
                isContinuation: true, priorTaskID: create.id, priorGoal: createText,
                rootGoal: nil, artifactMinimumLineCount: nil, lastArtifact: "budget_lab.html",
                previousRequiredLaunch: true, failureFeedback: false, failureKind: .none,
                bareAction: false, revisionRequest: false, requestsNewArtifact: false
            )
            let modify = TaskCompiler.compile(
                userText: "Теперь измени его: добавь редактирование суммы. Проверь и снова запусти.",
                decision: agent, continuity: continuity
            )
            await executor.begin(modify)
            let provider = FakeModelProvider()
            provider.script([ScriptedResponse(text: "validated, all good, done", toolCalls: [], format: .none)])
            let coordinator = RuntimeCoordinator(
                executor: executor,
                events: EventBus(sink: NullSink()),
                projectInstructions: "test"
            )
            _ = try await coordinator.run(
                RuntimeTaskInput(
                    userText: "test", decision: agent, maxRounds: 1, sessionExcerpt: "",
                    projectInstructions: "test", runtimeContext: "",
                    allowedTools: CoordinatorSelfTest.allTools, agentMaxTokens: nil
                ),
                provider: provider
            )
            let journal = await executor.state.journalRecords()
            record(!journal.contains { $0.kind == .validation },
                   "art-H prose validated creates no evidence")
        } catch {
            record(false, "art-H prose validated creates no evidence")
        }

        // I. undo restores content; freshness recomputed (validation stale again).
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            await state.beginTask(specFor("a.html"))
            _ = try ws.writeFile("a.html", content: v1)
            await state.mutation("write_file", path: "a.html", content: v1, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.readFile("a.html")
            await state.readBack(path: "a.html", content: v1,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.validateFile("a.html")
            await state.validationSuccess("validate_file", isRealValidation: true, path: "a.html",
                                          revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.editFile("a.html", old: "v1", new: "v2 extended")
            await state.mutation("edit_file", path: "a.html", content: nil, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            _ = try ws.rollbackLastEdit("a.html")
            await state.mutation("rollback", path: "a.html", content: nil, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let snapshot = await state.taskSnapshot()
            let diskContent = try String(contentsOf: dir.appendingPathComponent("a.html"), encoding: .utf8)
            record(diskContent == v1 &&
                   ws.graph.currentHash(path: "a.html") == ArtifactHash.sha256(v1) &&
                   snapshot.missingRequirements.contains(.validate(.path("a.html"))),
                   "art-I undo restores content and recomputes freshness")
        } catch {
            record(false, "art-I undo restores content and recomputes freshness")
        }

        // J. two artifacts keep independent revision/evidence chains.
        do {
            let (dir, ws, state) = try makeProject()
            defer { cleanup(dir) }
            let spec = TaskSpec(
                id: TaskID(), parentID: nil, mode: .agent, kinds: [.modify],
                originalRequest: "test", targets: [ArtifactRef(path: "a.html")],
                launchApplication: nil, desiredState: [],
                requirements: [.validate(.path("a.html")), .validate(.path("b.html"))],
                constraints: [], outputPolicy: .deterministicAck,
                compileConfidence: 1.0, compilerNotes: []
            )
            await state.beginTask(spec)
            for (file, content) in [("a.html", v1), ("b.html", v1)] {
                _ = try ws.writeFile(file, content: content)
                await state.mutation("write_file", path: file, content: content, changed: true,
                                     revisionID: ws.graph.currentRevisionID(path: file))
                _ = try ws.validateFile(file)
                await state.validationSuccess("validate_file", isRealValidation: true, path: file,
                                              revisionID: ws.graph.currentRevisionID(path: file))
            }
            await state.setCurrentRevisions(ws.graph.currentMap())
            _ = try ws.editFile("a.html", old: "v1", new: "v2 extended")
            await state.mutation("edit_file", path: "a.html", content: nil, changed: true,
                                 revisionID: ws.graph.currentRevisionID(path: "a.html"))
            await state.setCurrentRevisions(ws.graph.currentMap())
            let snapshot = await state.taskSnapshot()
            record(snapshot.missingRequirements.contains(.validate(.path("a.html"))) &&
                   !snapshot.missingRequirements.contains(.validate(.path("b.html"))) &&
                   ws.graph.currentRevisionID(path: "a.html") != ws.graph.currentRevisionID(path: "b.html"),
                   "art-J independent chains per artifact")
        } catch {
            record(false, "art-J independent chains per artifact")
        }

        return out
    }
}


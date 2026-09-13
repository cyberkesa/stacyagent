import Foundation

enum SLTASelfTest {
    static func run() async -> String {
        var passed = 0
        var failures: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
                passed += 1
            } else {
                failures.append(name)
            }
        }

        let agent = TurnDecision.forMode(.agent, source: .fast)
        let createText = "Создай budget_lab.html, проверь файл и запусти его."
        let create = TaskCompiler.compile(
            userText: createText,
            decision: agent
        )

        check(
            create.kinds.contains(.create) &&
            create.kinds.contains(.run) &&
            create.kinds.contains(.verify) &&
            create.targets.first?.path == "budget_lab.html" &&
            create.requirements.contains(.validate(.path("budget_lab.html"))),
            "compiler create+run+verify"
        )

        let state = RuntimeState()
        await state.beginTask(create)
        await state.mutation(
            "write_file",
            path: "budget_lab.html",
            content: "<html><body></body></html>",
            changed: true
        )

        var snapshot = await state.taskSnapshot()
        let allTools: Set<String> = [
            "list_dir", "read_file", "search", "write_file", "edit_file",
            "validate_file", "shell", "open_file"
        ]

        if case .deterministic(.validateFile("budget_lab.html")) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("protocol validate after create")
        }

        await state.validationSuccess(
            "validate_file",
            isRealValidation: true,
            path: "budget_lab.html"
        )
        snapshot = await state.taskSnapshot()

        if case .deterministic(.openFile("budget_lab.html")) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("protocol launch after validation")
        }

        await state.launchSuccess("open_file", path: "budget_lab.html")
        snapshot = await state.taskSnapshot()
        check(snapshot.isComplete, "create completion")

        let continuity = TaskContinuity(
            isContinuation: true,
            priorTaskID: create.id,
            priorGoal: createText,
            rootGoal: nil,
            artifactMinimumLineCount: nil,
            lastArtifact: "budget_lab.html",
            previousRequiredLaunch: true,
            failureFeedback: false,
            failureKind: .none,
            bareAction: false,
            revisionRequest: false,
            requestsNewArtifact: false
        )

        let modify = TaskCompiler.compile(
            userText: "Теперь измени его: добавь редактирование суммы. Проверь и снова запусти.",
            decision: agent,
            continuity: continuity
        )
        await state.beginTask(modify)
        snapshot = await state.taskSnapshot()

        if case .deterministic(.readFile("budget_lab.html")) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("modify deterministic pre-read")
        }

        await state.readBack(
            path: "budget_lab.html",
            content: "<html>old</html>"
        )
        snapshot = await state.taskSnapshot()

        if case .intelligence(let request) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ), request.kind == .editArtifact,
           request.allowedTools == Set(["write_file", "edit_file"]) {
            passed += 1
        } else {
            failures.append("modify intelligence boundary")
        }

        // A no-op mutation must not satisfy MODIFY's changed-revision requirement.
        await state.mutation(
            "edit_file",
            path: "budget_lab.html",
            content: nil,
            changed: false
        )
        snapshot = await state.taskSnapshot()
        check(
            snapshot.missingRequirements.contains(
                .mutateCount(.path("budget_lab.html"), 1)
            ),
            "no-op does not satisfy modify"
        )

        let staged = TaskCompiler.compile(
            userText: "Сломай расчёт, затем найди ошибку, исправь её, проверь и запусти.",
            decision: agent,
            continuity: continuity
        )
        check(
            staged.kinds.contains(.debug) &&
            staged.requirements.contains(
                .mutateCount(.path("budget_lab.html"), 2)
            ) &&
            staged.requirements.contains(
                .observeAfterMutation(.path("budget_lab.html"))
            ),
            "staged debug compilation"
        )

        await state.beginTask(staged)
        snapshot = await state.taskSnapshot()
        if case .deterministic(.readFile("budget_lab.html")) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("staged initial read")
        }

        await state.readBack(
            path: "budget_lab.html",
            content: "ORIGINAL"
        )
        await state.mutation(
            "edit_file",
            path: "budget_lab.html",
            content: nil,
            changed: true
        )
        snapshot = await state.taskSnapshot()

        if case .deterministic(.readFile("budget_lab.html")) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("staged refresh barrier")
        }

        await state.readBack(
            path: "budget_lab.html",
            content: "BROKEN"
        )
        snapshot = await state.taskSnapshot()
        if case .intelligence(let request) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ), request.kind == .diagnoseAndEdit {
            passed += 1
        } else {
            failures.append("staged repair intelligence")
        }

        await state.mutation(
            "edit_file",
            path: "budget_lab.html",
            content: nil,
            changed: true
        )
        await state.validationSuccess(
            "validate_file",
            isRealValidation: true,
            path: "budget_lab.html"
        )
        await state.launchSuccess(
            "open_file",
            path: "budget_lab.html"
        )
        snapshot = await state.taskSnapshot()
        check(snapshot.isComplete, "staged completion")

        let inspectDecision = TurnDecision.forMode(.inspect, source: .fast)
        let verifyOnly = TaskCompiler.compile(
            userText: "Проверь main.py.",
            decision: inspectDecision
        )
        check(
            verifyOnly.requirements.contains(.observe(.path("main.py"))) &&
            verifyOnly.requirements.contains(.validate(.path("main.py"))),
            "verify-only compiles observation + validation"
        )
        await state.beginTask(verifyOnly)
        snapshot = await state.taskSnapshot()
        if case .deterministic(.readFile("main.py")) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("verify-only read before validate")
        }

        let mcpDecision = TurnDecision.forMode(.mcpAgent, source: .fast)
        let mcpSpec = TaskCompiler.compile(
            userText: "Выполни действие через MCP.",
            decision: mcpDecision
        )
        await state.beginTask(mcpSpec)
        snapshot = await state.taskSnapshot()
        let mcpAllowed: Set<String> = [
            "mcp_servers", "mcp_list_tools", "mcp_call"
        ]
        if case .intelligence(let request) = ProtocolEngine.decision(
            for: snapshot,
            allowed: mcpAllowed
        ) {
            check(
                request.kind == .externalAction &&
                request.allowedTools.contains("mcp_call") &&
                snapshot.missingRequirements.contains(.externalEffect),
                "MCP external-effect requirement"
            )
        } else {
            failures.append("MCP external-effect requirement")
        }
        await state.externalSuccess("mcp_call")
        snapshot = await state.taskSnapshot()
        check(snapshot.isComplete, "MCP completion requires real call evidence")

        let imageSearchSpec = TaskCompiler.compile(
            userText: "Через MCP найди фотографию ночной Москвы",
            decision: mcpDecision
        )
        await state.beginTask(imageSearchSpec)
        await state.externalSuccess(
            "mcp_call",
            server: "playwright",
            operation: "browser_navigate",
            urls: ["https://www.google.com/search?q=moscow"]
        )
        snapshot = await state.taskSnapshot()
        check(
            !snapshot.isComplete &&
            snapshot.missingRequirements.contains(.externalArtifact(.image)),
            "image search is not complete after navigation alone"
        )
        await state.externalSuccess(
            "mcp_call",
            server: "playwright",
            operation: "browser_evaluate",
            urls: ["https://images.example/moscow-night.jpg"]
        )
        snapshot = await state.taskSnapshot()
        check(
            snapshot.isComplete && imageSearchSpec.requiresSynthesis,
            "image search requires and accepts concrete image URL evidence"
        )

        let externalSession = SessionSnapshot(
            projectPath: "/tmp/slta-external",
            persistencePath: "/tmp/slta-external-state",
            turns: [],
            ledgerEventCount: 3,
            lastProjectRequest: "Через MCP найди фотографию ночной Москвы",
            lastOperationalRequest: "Через MCP найди фотографию ночной Москвы",
            lastProjectMode: .mcpAgent,
            lastTaskID: imageSearchSpec.id,
            lastTaskKinds: [.externalAction],
            artifacts: [],
            lastArtifact: nil,
            lastOpenedArtifact: nil,
            lastExternalURL: "https://images.example/moscow-night.jpg",
            previousRequiredLaunch: false,
            previousTaskComplete: true,
            lastTaskMutationCount: 0,
            lastFailure: nil
        )
        check(
            externalSession.directAnswer(for: "и где эта картинка?")?.contains("moscow-night.jpg") == true,
            "external image location is answered from runtime evidence"
        )
        check(
            externalSession.continuationDecision(for: "покажи её")?.mode == .mcpAgent,
            "external image follow-up stays in MCP mode"
        )
        check(
            DiscourseResolver.analyze("там всё ещё знак вопроса вместо фото").failureKind == .functional,
            "broken image feedback is classified as functional failure"
        )

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            let mockServer = #"""
import json,sys
counter=0
for line in sys.stdin:
    message=json.loads(line)
    method=message.get("method")
    ident=message.get("id")
    if ident is None:
        continue
    if method == "initialize":
        result={"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"mock","version":"1"}}
    elif method == "tools/list":
        result={"tools":[{"name":"increment","description":"increments process-local state","inputSchema":{"type":"object","properties":{}}}]}
    elif method == "tools/call":
        name=message.get("params",{}).get("name")
        if name == "browser_type" and message.get("params",{}).get("arguments",{}).get("target") != "e7":
            result={"content":[{"type":"text","text":"Error: input[name='q'] does not match any elements."}],"isError":True}
        elif name == "browser_type":
            result={"content":[{"type":"text","text":"typed with ref=e7"}],"isError":False}
        elif name == "browser_snapshot":
            result={"content":[{"type":"text","text":"- textbox Search [ref=e7]"}],"isError":False}
        else:
            counter += 1
            result={"content":[{"type":"text","text":"counter=%d" % counter}],"isError":False}
    else:
        print(json.dumps({"jsonrpc":"2.0","id":ident,"error":{"code":-32601,"message":"unknown"}}),flush=True)
        continue
    print(json.dumps({"jsonrpc":"2.0","id":ident,"result":result}),flush=True)
"""#
            let mockConfig = MCPConfig(servers: [
                "playwright": .init(
                    command: "/usr/bin/python3",
                    args: ["-u", "-c", mockServer]
                )
            ])
            let bridge = MCPBridge(
                policy: PolicyEngine(mode: .workspace, allowMCP: true),
                config: mockConfig
            )
            do {
                _ = try bridge.listTools(server: "playwright")
                let first = try bridge.call(server: "playwright", tool: "increment", argumentsJSON: "{}")
                let second = try bridge.call(server: "playwright", tool: "increment", argumentsJSON: "{}")
                let recovered = try bridge.call(
                    server: "playwright",
                    tool: "increment\n</Parameter><parameter=arguments_json>",
                    argumentsJSON: "{}"
                )
                check(
                    first.rendered.contains("counter=1") &&
                    second.rendered.contains("counter=2") &&
                    recovered.rendered.contains("counter=3"),
                    "MCP process persists across tool calls"
                )
                let targetRecovered = try bridge.call(
                    server: "playwright",
                    tool: "browser_type",
                    argumentsJSON: #"{"target":"input[name='q']","text":"night Moscow"}"#
                )
                check(
                    targetRecovered.rendered.contains("typed with ref=e7"),
                    "Playwright missing-target automatic retry"
                )
            } catch {
                failures.append("MCP process persists across tool calls: \(error)")
            }
        }

        let parserText = """
        <tool_call>
        <function=edit_file>
        <parameter=path>
        budget_lab.html
        </parameter>
        <parameter=old>
        a
        </parameter>
        <parameter=new>
        b
        </parameter>
        </function>
        """

        switch Qwen3CoderProtocol.analyze(parserText) {
        case .complete(let calls):
            check(
                calls.count == 1 &&
                calls[0].name == "edit_file" &&
                calls[0].arguments["new"] == "b",
                "Qwen wrapper recovery"
            )
        default:
            failures.append("Qwen wrapper recovery")
        }

        let mixedCaseParameterClose = """
        <tool_call>
        <function=mcp_call>
        <parameter=server>playwright</Parameter>
        <parameter=tool>browser_type</Parameter>
        <parameter=arguments_json>{"ref":"e12","text":"ночная Москва"}</Parameter>
        </function>
        </tool_call>
        """
        switch Qwen3CoderProtocol.analyze(mixedCaseParameterClose) {
        case .complete(let calls):
            check(
                calls.count == 1 &&
                calls[0].arguments["server"] == "playwright" &&
                calls[0].arguments["tool"] == "browser_type" &&
                calls[0].arguments["arguments_json"] ==
                    "{\"ref\":\"e12\",\"text\":\"ночная Москва\"}",
                "mixed-case Qwen parameter closing tags"
            )
        default:
            failures.append("mixed-case Qwen parameter closing tags")
        }

        let truncated = """
        <tool_call><function=edit_file><parameter=path>budget_lab.html</parameter><parameter=new>const x =
        """
        if case .incomplete = Qwen3CoderProtocol.analyze(truncated) {
            passed += 1
        } else {
            failures.append("truncated tool call rejected")
        }

        let unresolved = TaskCompiler.compile(
            userText: "Исправь код и запусти.",
            decision: agent
        )
        await state.beginTask(unresolved)
        snapshot = await state.taskSnapshot()

        if case .intelligence(let request) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            check(
                request.kind == .resolveTarget &&
                request.allowedTools.contains("read_file") &&
                request.allowedTools.contains("edit_file"),
                "unresolved target intelligence"
            )
        } else {
            failures.append("unresolved target intelligence")
        }


        // --- v0.25 conversational/discourse regression suite ---

        check(
            InputNormalizer.sanitize("чувств\u{FFFD}а") == "чувства",
            "input UTF-8 replacement cleanup"
        )

        let tempProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("slta-selftest-project", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempProject,
            withIntermediateDirectories: true
        )
        let runtime = RuntimeEnvironment.probe(projectURL: tempProject)

        check(
            DirectRuntimeRouter.answer(
                "ты где сейчас",
                runtime: runtime,
                mcpServers: "no MCP servers configured"
            )?.contains(tempProject.path) == true,
            "direct cwd colloquial query"
        )

        check(
            DirectRuntimeRouter.answer(
                "а в какой ты папке находишься",
                runtime: runtime,
                mcpServers: "no MCP servers configured"
            )?.contains(tempProject.path) == true,
            "direct cwd folder query"
        )

        let explicitTimeMCP = "Через MCP time покажи текущее время в Москве."
        check(
            DirectRuntimeRouter.answer(
                explicitTimeMCP,
                runtime: runtime,
                mcpServers: "playwright\ntime"
            ) == nil,
            "explicit named MCP action bypasses server-list direct answer"
        )
        check(
            FastTurnRouter.decide(explicitTimeMCP)?.mode == .mcpAgent,
            "explicit named MCP action routes to MCP agent"
        )
        let implicitWebImage = "найди в интернете картинку"
        check(
            FastTurnRouter.decide(implicitWebImage)?.mode == .mcpAgent,
            "implicit internet image search routes to MCP agent"
        )
        let implicitWebImageSpec = TaskCompiler.compile(
            userText: implicitWebImage,
            decision: .forMode(.mcpAgent, source: .fast)
        )
        check(
            implicitWebImageSpec.requirements.contains(.externalEffect) &&
            implicitWebImageSpec.requirements.contains(.externalArtifact(.image)) &&
            !implicitWebImageSpec.requirements.contains(.observe(.any)),
            "implicit internet image search has external-only evidence"
        )
        check(
            DirectRuntimeRouter.answer(
                "покажи какие MCP серверы подключены",
                runtime: runtime,
                mcpServers: "playwright\ntime"
            )?.contains("playwright") == true,
            "explicit MCP server-list query remains direct"
        )

        let loveTaskID = TaskID()
        let loveArtifact = ArtifactProjection(
            ref: ArtifactRef(
                path: "love.html",
                originTask: loveTaskID,
                revision: 1
            ),
            wasRead: false,
            wasMutated: true,
            wasValidated: false,
            wasOpened: true
        )

        let loveSession = SessionSnapshot(
            projectPath: tempProject.path,
            persistencePath: "/tmp/slta-selftest",
            turns: [
                SessionTurn(
                    user: "создай html страничку про любовь",
                    assistant: "Готово.",
                    mode: .agent,
                    status: "done"
                )
            ],
            ledgerEventCount: 4,
            lastProjectRequest: "создай html страничку про любовь",
            lastOperationalRequest: "создай html страничку про любовь",
            lastProjectMode: .agent,
            lastTaskID: loveTaskID,
            lastTaskKinds: [.create],
            artifacts: [loveArtifact],
            lastArtifact: "love.html",
            lastOpenedArtifact: "love.html",
            lastExternalURL: nil,
            previousRequiredLaunch: true,
            previousTaskComplete: true,
            lastTaskMutationCount: 1,
            lastFailure: nil
        )

        let softer = "как-то не мило. я хочу чтобы ты вложил чувства"
        let softerDiscourse = DiscourseResolver.analyze(softer)
        check(
            softerDiscourse.revisionRequest,
            "implicit qualitative revision detected"
        )

        let softerContinuity = loveSession.taskContinuity(for: softer)
        check(
            softerContinuity.isContinuation &&
            softerContinuity.revisionRequest &&
            softerContinuity.lastArtifact == "love.html" &&
            loveSession.continuationDecision(for: softer)?.mode == .agent,
            "qualitative revision resolves focused artifact"
        )

        let softerSpec = TaskCompiler.compile(
            userText: softer,
            decision: .forMode(.agent, source: .fast),
            continuity: softerContinuity
        )
        check(
            softerSpec.kinds.contains(.modify) &&
            softerSpec.targets.first?.path == "love.html" &&
            softerSpec.requirements.contains(.observe(.path("love.html"))) &&
            softerSpec.requirements.contains(.mutateCount(.path("love.html"), 1)),
            "qualitative revision compiles to real MODIFY"
        )

        let acceptText = "да норм добавь в этот html и открой его мне"
        let acceptContinuity = loveSession.taskContinuity(for: acceptText)
        let acceptSpec = TaskCompiler.compile(
            userText: acceptText,
            decision: .forMode(.agent, source: .fast),
            continuity: acceptContinuity
        )
        check(
            acceptContinuity.isContinuation &&
            acceptSpec.kinds.contains(.modify) &&
            acceptSpec.kinds.contains(.run) &&
            acceptSpec.targets.first?.path == "love.html",
            "accept prior proposal becomes modify+run"
        )

        let noChange = loveSession.taskContinuity(
            for: "там ничего не поменялось"
        )
        check(
            noChange.failureKind == .notChanged &&
            noChange.isContinuation &&
            loveSession.continuationDecision(
                for: "там ничего не поменялось"
            )?.mode == .agent,
            "not-changed feedback reopens task"
        )

        let noChangeSpec = TaskCompiler.compile(
            userText: "там ничего не поменялось",
            decision: .forMode(.agent, source: .fast),
            continuity: noChange
        )
        check(
            noChangeSpec.kinds.contains(.debug) &&
            noChangeSpec.kinds.contains(.modify) &&
            noChangeSpec.kinds.contains(.run) &&
            noChangeSpec.requirements.contains(.mutateCount(.path("love.html"), 1)) &&
            noChangeSpec.requirements.contains(.validate(.path("love.html"))) &&
            noChangeSpec.requirements.contains(.launch(.path("love.html"))),
            "not-changed feedback requires repair+validate+launch"
        )

        let punctuatedOpen = loveSession.taskContinuity(for: "открой[")
        check(
            punctuatedOpen.isContinuation &&
            punctuatedOpen.bareAction &&
            punctuatedOpen.lastArtifact == "love.html",
            "punctuated bare launch resolves artifact"
        )

        let retryEdit = loveSession.taskContinuity(for: "да внеси еще раз")
        let retrySpec = TaskCompiler.compile(
            userText: "да внеси еще раз",
            decision: .forMode(.agent, source: .fast),
            continuity: retryEdit
        )
        check(
            retryEdit.isContinuation &&
            retrySpec.kinds.contains(.modify) &&
            retrySpec.targets.first?.path == "love.html",
            "retry edit imperative is real mutation"
        )

        let newRequest = loveSession.taskContinuity(
            for: "бро ну хорошо создай новый"
        )
        check(
            newRequest.isContinuation &&
            newRequest.requestsNewArtifact &&
            newRequest.lastArtifact == "love_2.html",
            "new sibling artifact allocated without project scan"
        )

        let newSpec = TaskCompiler.compile(
            userText: "бро ну хорошо создай новый",
            decision: .forMode(.agent, source: .fast),
            continuity: newRequest
        )
        check(
            newSpec.kinds.contains(.create) &&
            newSpec.targets.first?.path == "love_2.html" &&
            !newSpec.requirements.contains(.observe(.path("love_2.html"))),
            "new sibling compiles directly to CREATE target"
        )

        let newArtifact = ArtifactProjection(
            ref: ArtifactRef(
                path: "love_2.html",
                originTask: newSpec.id,
                revision: 1
            ),
            wasRead: false,
            wasMutated: true,
            wasValidated: false,
            wasOpened: false
        )
        let afterNewSession = SessionSnapshot(
            projectPath: tempProject.path,
            persistencePath: "/tmp/slta-selftest",
            turns: loveSession.turns,
            ledgerEventCount: 8,
            lastProjectRequest: loveSession.lastProjectRequest,
            lastOperationalRequest: "бро ну хорошо создай новый",
            lastProjectMode: .agent,
            lastTaskID: newSpec.id,
            lastTaskKinds: [.create],
            artifacts: [loveArtifact, newArtifact],
            lastArtifact: "love_2.html",
            lastOpenedArtifact: "love.html",
            lastExternalURL: nil,
            previousRequiredLaunch: false,
            previousTaskComplete: true,
            lastTaskMutationCount: 1,
            lastFailure: nil
        )

        let openNew = afterNewSession.taskContinuity(for: "открой новую")
        let openNewSpec = TaskCompiler.compile(
            userText: "открой новую",
            decision: .forMode(.agent, source: .fast),
            continuity: openNew
        )
        check(
            openNew.isContinuation &&
            openNew.lastArtifact == "love_2.html" &&
            openNewSpec.kinds.contains(.run) &&
            openNewSpec.requirements.contains(.launch(.path("love_2.html"))),
            "open new resolves most recent created artifact"
        )

        let noEvidenceSession = SessionSnapshot(
            projectPath: tempProject.path,
            persistencePath: "/tmp/slta-selftest",
            turns: loveSession.turns,
            ledgerEventCount: 9,
            lastProjectRequest: loveSession.lastProjectRequest,
            lastOperationalRequest: "как-то не мило. я хочу чтобы ты вложил чувства",
            lastProjectMode: .agent,
            lastTaskID: TaskID(),
            lastTaskKinds: [.modify],
            artifacts: [loveArtifact],
            lastArtifact: "love.html",
            lastOpenedArtifact: "love.html",
            lastExternalURL: nil,
            previousRequiredLaunch: false,
            previousTaskComplete: false,
            lastTaskMutationCount: 0,
            lastFailure: "missing evidence: mutate love.html"
        )

        check(
            noEvidenceSession.directAnswer(
                for: "ты точно внес изменения?"
            )?.contains("не внесла ни одного изменения") == true,
            "project mutation truth comes from evidence"
        )

        check(
            noEvidenceSession.directAnswer(for: "эээээ")?.contains(
                "Предыдущая проектная задача не завершена"
            ) == true,
            "frustration after incomplete task returns runtime status"
        )

        check(
            DiscourseResolver.analyze("там белый экран").failureKind == .functional,
            "functional failure classification"
        )

        check(
            DiscourseResolver.analyze("ничего не открылось").failureKind == .notLaunched,
            "launch failure classification"
        )

        // A MODIFY+RUN on HTML must validate the latest revision even when the
        // user did not explicitly say "проверь".
        let modifyRun = TaskCompiler.compile(
            userText: "измени его и открой",
            decision: .forMode(.agent, source: .fast),
            continuity: loveSession.taskContinuity(for: "измени его и открой")
        )
        await state.beginTask(modifyRun)
        await state.readBack(path: "love.html", content: "<html>old</html>")
        await state.mutation(
            "edit_file",
            path: "love.html",
            content: nil,
            changed: true
        )
        snapshot = await state.taskSnapshot()
        check(
            snapshot.missingRequirements.contains(.validate(.path("love.html"))) &&
            snapshot.missingRequirements.contains(.launch(.path("love.html"))),
            "launch of changed HTML requires fresh validation"
        )


        // Runtime target binding: a task may start without a concrete filename, but
        // once the model creates/observes one artifact the rest of the protocol must
        // bind to that path and become deterministic.
        let unresolvedCreate = TaskCompiler.compile(
            userText: "Создай HTML страницу и открой её.",
            decision: agent
        )
        await state.beginTask(unresolvedCreate)
        snapshot = await state.taskSnapshot()
        check(
            snapshot.resolvedTargetPath == nil &&
            snapshot.missingRequirements.contains(.mutate(.any)) &&
            snapshot.missingRequirements.contains(.launch(.any)),
            "unresolved create starts target-free"
        )

        await state.mutation(
            "write_file",
            path: "page.html",
            content: "<html><body>ok</body></html>",
            changed: true
        )
        snapshot = await state.taskSnapshot()
        check(
            snapshot.resolvedTargetPath == "page.html" &&
            snapshot.requirements.contains(.launch(.path("page.html"))) &&
            snapshot.requirements.contains(.validate(.path("page.html"))) &&
            !snapshot.requirements.contains(.launch(.any)),
            "concrete mutation binds generic target requirements"
        )

        if case .deterministic(.validateFile("page.html")) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("bound target validates deterministically")
        }

        await state.validationSuccess(
            "validate_file",
            isRealValidation: true,
            path: "page.html"
        )
        await state.nativeLaunchSuccess(
            "open_file",
            result: "opened fresh page.html"
        )
        snapshot = await state.taskSnapshot()
        check(
            snapshot.isComplete &&
            snapshot.openedPaths.contains("page.html") &&
            !snapshot.openedPaths.contains("fresh page.html"),
            "fresh HTML native launch records real artifact path"
        )

        let unresolvedModify = TaskCompiler.compile(
            userText: "Исправь код и запусти.",
            decision: agent
        )
        await state.beginTask(unresolvedModify)
        await state.readBack(
            path: "main.py",
            content: "print('old')"
        )
        snapshot = await state.taskSnapshot()

        if case .intelligence(let request) = ProtocolEngine.decision(
            for: snapshot,
            allowed: allTools
        ) {
            check(
                snapshot.resolvedTargetPath == "main.py" &&
                request.kind == .editArtifact &&
                request.target == "main.py" &&
                snapshot.requirements.contains(.mutateCount(.path("main.py"), 1)) &&
                snapshot.requirements.contains(.launch(.path("main.py"))),
                "observation binds unresolved MODIFY target"
            )
        } else {
            failures.append("observation binds unresolved MODIFY target")
        }


        // Persistence keeps the stable root goal AND the latest operational intent.
        // Failure feedback after restart must resume the latest concrete revision,
        // not fall all the way back to the original create request.
        let persistenceProject = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "slta-persist-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: persistenceProject,
            withIntermediateDirectories: true
        )

        let persistedContext = SessionContext(
            projectPath: persistenceProject.path
        )
        await persistedContext.clear()

        let persistedCreate = TaskCompiler.compile(
            userText: "Создай persist.html минимум 500 строк",
            decision: agent
        )
        await state.beginTask(persistedCreate)
        await state.mutation(
            "write_file",
            path: "persist.html",
            content: "<html><body>v1</body></html>",
            changed: true
        )
        var persistedTask = await state.taskSnapshot()
        await persistedContext.recordProject(
            user: "Создай persist.html минимум 500 строк",
            assistant: "Готово.",
            decision: agent,
            task: persistedTask
        )

        let persistedBeforeModify = await persistedContext.snapshot()
        let persistedContinuity = persistedBeforeModify.taskContinuity(
            for: "Сделай его теплее"
        )
        let persistedModify = TaskCompiler.compile(
            userText: "Сделай его теплее",
            decision: agent,
            continuity: persistedContinuity
        )
        await state.beginTask(persistedModify)
        await state.readBack(
            path: "persist.html",
            content: "<html><body>v1</body></html>"
        )
        await state.mutation(
            "edit_file",
            path: "persist.html",
            content: nil,
            changed: true
        )
        persistedTask = await state.taskSnapshot()
        await persistedContext.recordProject(
            user: "Сделай его теплее",
            assistant: "Готово.",
            decision: agent,
            task: persistedTask,
            continuity: persistedContinuity
        )

        let beforeFailure = await persistedContext.snapshot()
        let pureFailureContinuity = beforeFailure.taskContinuity(
            for: "там ничего не поменялось"
        )
        let pureFailureSpec = TaskCompiler.compile(
            userText: "там ничего не поменялось",
            decision: agent,
            continuity: pureFailureContinuity
        )
        await state.beginTask(pureFailureSpec)
        let pureFailureTask = await state.taskSnapshot()
        await persistedContext.recordProject(
            user: "там ничего не поменялось",
            assistant: "",
            decision: agent,
            task: pureFailureTask,
            continuity: pureFailureContinuity
        )

        let afterFailureProjection = await persistedContext.snapshot()
        check(
            afterFailureProjection.lastOperationalRequest == "Сделай его теплее",
            "pure failure feedback preserves pending operational intent"
        )

        let restoredContext = SessionContext(
            projectPath: persistenceProject.path
        )
        let restored = await restoredContext.snapshot()
        check(
            restored.lastProjectRequest == "Создай persist.html минимум 500 строк" &&
            restored.lastOperationalRequest == "Сделай его теплее" &&
            restored.lastArtifact == "persist.html",
            "persistent root goal + latest operational intent"
        )

        let restoredFailure = restored.taskContinuity(
            for: "там ничего не поменялось"
        )
        check(
            restoredFailure.isContinuation &&
            restoredFailure.failureKind == .notChanged &&
            restoredFailure.priorGoal == "Сделай его теплее" &&
            restoredFailure.lastArtifact == "persist.html" &&
            restoredFailure.artifactMinimumLineCount == 500,
            "restart failure resumes latest operational intent + artifact contract"
        )

        await restoredContext.clear()
        try? FileManager.default.removeItem(at: persistenceProject)


        var boundedLedger = SessionLedger()
        for index in 0..<300 {
            boundedLedger.append(.userMessage("event-\(index)"))
        }
        check(
            boundedLedger.events.count == 256 &&
            boundedLedger.totalAppended == 300,
            "in-memory ledger is bounded while preserving total count"
        )


        let nativeReadEnvelope = NativeToolEnvelope.encodeRead(
            path: "nested/main.py",
            content: "print('ok')\n"
        )
        let decodedNativeRead = NativeToolEnvelope.decodeRead(nativeReadEnvelope)
        check(
            decodedNativeRead?.path == "nested/main.py" &&
            decodedNativeRead?.content == "print('ok')\n",
            "native read envelope preserves concrete path + exact content"
        )


        let readOnlySession = SessionSnapshot(
            projectPath: tempProject.path,
            persistencePath: "/tmp/slta-selftest",
            turns: [],
            ledgerEventCount: 1,
            lastProjectRequest: "Проверь main.py",
            lastOperationalRequest: "Проверь main.py",
            lastProjectMode: .inspect,
            lastTaskID: TaskID(),
            lastTaskKinds: [.inspect, .verify],
            artifacts: [],
            lastArtifact: "main.py",
            lastOpenedArtifact: nil,
            lastExternalURL: nil,
            previousRequiredLaunch: false,
            previousTaskComplete: true,
            lastTaskMutationCount: 0,
            lastFailure: nil
        )
        check(
            readOnlySession.taskContinuity(for: "там нет ошибок").failureKind == .none,
            "negative read-only observation is not misclassified as action failure"
        )


        // v0.26 — Edit Engine / revision / checkpoint / ranged I/O regression suite.
        let editProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("slta-edit-selftest-\(UUID().uuidString)", isDirectory: true)
        let editHistory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slta-edit-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: editProject,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: editProject)
            try? FileManager.default.removeItem(at: editHistory)
        }

        do {
            let editEngine = EditEngine(
                projectRoot: editProject,
                historyRoot: editHistory.appendingPathComponent("direct", isDirectory: true)
            )
            editEngine.beginTask(TaskID())

            let proposed = try editEngine.prepare(
                path: "demo.txt",
                before: nil,
                after: "one\ntwo\nthree",
                operation: .create
            )
            check(
                proposed.transaction.status == .proposed &&
                proposed.transaction.proposal.hunks.count == 1 &&
                proposed.transaction.proposal.hunks[0].addedLines == ["one", "two", "three"],
                "edit proposal + hunk"
            )

            let directReceipt = try editEngine.commit(proposed)
            check(
                directReceipt.path == "demo.txt" &&
                directReceipt.baseRevision == 0 &&
                directReceipt.newRevision == 1,
                "edit transaction commit receipt"
            )

            let directDiff = try editEngine.diffText(prefix: directReceipt.id.description)
            check(
                directDiff.contains("+++ b/demo.txt") &&
                directDiff.contains("+two"),
                "edit transaction unified diff"
            )

            let rejected = try editEngine.prepare(
                path: "demo.txt",
                before: "one\ntwo\nthree",
                after: "one\nTWO\nthree",
                operation: .exactReplace
            )
            editEngine.reject(rejected)
            check(
                editEngine.transaction(prefix: rejected.transaction.id.description)?.status == .rejected &&
                editEngine.latestReceipt(path: "demo.txt")?.id == directReceipt.id,
                "rejected proposal does not advance applied revision"
            )

            let disjoint = try editEngine.prepare(
                path: "multi.txt",
                before: "a\nb\nc\nd\ne",
                after: "A\nb\nc\nd\nE",
                operation: .fullReplace
            )
            check(
                disjoint.transaction.proposal.hunks.count == 2 &&
                disjoint.transaction.proposal.hunks[0].removedLines == ["a"] &&
                disjoint.transaction.proposal.hunks[1].removedLines == ["e"],
                "disjoint full-file changes produce separate review hunks"
            )
            editEngine.reject(disjoint)

            let reopenedEngine = EditEngine(
                projectRoot: editProject,
                historyRoot: editHistory.appendingPathComponent("direct", isDirectory: true)
            )
            check(
                reopenedEngine.transaction(prefix: directReceipt.id.description)?.status == .applied,
                "edit transaction persistence"
            )
        } catch {
            failures.append("direct edit engine regression: \(error)")
        }

        do {
            let policy = PolicyEngine(mode: .workspace, allowMCP: false)
            let editRuntime = RuntimeEnvironment.probe(projectURL: editProject)
            let workspace = Workspace(
                root: editProject,
                shellTimeoutSeconds: 5,
                policy: policy,
                runtime: editRuntime,
                editHistoryRoot: editHistory.appendingPathComponent("workspace", isDirectory: true)
            )

            let editTaskID = TaskID()
            workspace.beginTask(taskID: editTaskID)
            let writeResult = try workspace.writeFile(
                "tracked.txt",
                content: "one\ntwo\nthree"
            )
            check(
                writeResult.contains("tx=") &&
                workspace.latestEditReceipt(path: "tracked.txt") != nil,
                "workspace write creates edit transaction"
            )

            _ = try workspace.readFile("tracked.txt")
            let exactResult = try workspace.editFile(
                "tracked.txt",
                old: "two",
                new: "TWO"
            )
            let exactReceipt = workspace.latestEditReceipt(path: "tracked.txt")
            check(
                exactResult.contains("r1→r2") &&
                exactReceipt?.newRevision == 2,
                "exact edit advances artifact revision"
            )

            check(
                workspace.checkpointHistoryText(path: "tracked.txt")
                    .contains("automatic · before task"),
                "first task mutation creates automatic checkpoint"
            )

            let range = try workspace.readFileRange(
                "tracked.txt",
                startLine: 2,
                endLine: 3
            )
            check(
                range.contains("2│TWO") &&
                range.contains("3│three") &&
                !range.contains("1│one"),
                "ranged read returns bounded line window"
            )

            let rangedResult = try workspace.editFileRange(
                "tracked.txt",
                startLine: 3,
                endLine: 3,
                replacement: "THREE"
            )
            let rangedContent = try String(
                contentsOf: editProject.appendingPathComponent("tracked.txt"),
                encoding: .utf8
            )
            check(
                rangedResult.contains("updated range tracked.txt") &&
                rangedContent == "one\nTWO\nTHREE",
                "ranged edit applies exact line replacement"
            )

            let rangedDiff = try workspace.editDiffText()
            check(
                rangedDiff.contains("-three") &&
                rangedDiff.contains("+THREE"),
                "latest ranged transaction diff"
            )

            let checkpointText = try workspace.createCheckpoint(
                "tracked.txt",
                label: "before-four"
            )
            let checkpointID = checkpointText
                .split(separator: " ")
                .dropFirst()
                .first
                .map(String.init) ?? ""
            check(
                !checkpointID.isEmpty && checkpointText.contains("before-four"),
                "checkpoint creation"
            )

            _ = try workspace.editFile(
                "tracked.txt",
                old: "THREE",
                new: "FOUR"
            )
            let rollbackResult = try workspace.rollbackLastEdit("tracked.txt")
            let afterRollback = try String(
                contentsOf: editProject.appendingPathComponent("tracked.txt"),
                encoding: .utf8
            )
            check(
                rollbackResult.contains("rolled back tracked.txt") &&
                afterRollback == "one\nTWO\nTHREE",
                "rollback restores base revision"
            )

            _ = try workspace.editFile(
                "tracked.txt",
                old: "THREE",
                new: "FIVE"
            )
            let restoreResult = try workspace.restoreCheckpoint(checkpointID)
            let afterRestore = try String(
                contentsOf: editProject.appendingPathComponent("tracked.txt"),
                encoding: .utf8
            )
            check(
                restoreResult.contains("restored checkpoint") &&
                afterRestore == "one\nTWO\nTHREE",
                "checkpoint restore"
            )

            _ = try workspace.rollbackLastEdit("tracked.txt")
            let afterUndoRestore = try String(
                contentsOf: editProject.appendingPathComponent("tracked.txt"),
                encoding: .utf8
            )
            _ = try workspace.rollbackLastEdit("tracked.txt")
            let afterUndoFive = try String(
                contentsOf: editProject.appendingPathComponent("tracked.txt"),
                encoding: .utf8
            )
            check(
                afterUndoRestore == "one\nTWO\nFIVE" &&
                afterUndoFive == "one\nTWO\nTHREE",
                "undo can reverse checkpoint restore then continue backward"
            )

            let revisions = workspace.revisionHistoryText(path: "tracked.txt")
            check(
                revisions.contains("r0") &&
                revisions.contains("applied") &&
                revisions.contains("tracked.txt"),
                "revision history projection"
            )

            workspace.beginTask(taskID: TaskID())
            _ = try workspace.writeFile(
                "undo-chain.txt",
                content: "A"
            )
            _ = try workspace.readFile("undo-chain.txt")
            _ = try workspace.editFile(
                "undo-chain.txt",
                old: "A",
                new: "B"
            )
            _ = try workspace.readFile("undo-chain.txt")
            _ = try workspace.editFile(
                "undo-chain.txt",
                old: "B",
                new: "C"
            )

            _ = try workspace.rollbackLastEdit("undo-chain.txt")
            let afterFirstUndo = try String(
                contentsOf: editProject.appendingPathComponent("undo-chain.txt"),
                encoding: .utf8
            )
            _ = try workspace.rollbackLastEdit("undo-chain.txt")
            let afterSecondUndo = try String(
                contentsOf: editProject.appendingPathComponent("undo-chain.txt"),
                encoding: .utf8
            )
            check(
                afterFirstUndo == "B" &&
                afterSecondUndo == "A",
                "sequential undo walks backward instead of toggling redo"
            )

            let persistedWorkspace = Workspace(
                root: editProject,
                shellTimeoutSeconds: 5,
                policy: policy,
                runtime: editRuntime,
                editHistoryRoot: editHistory.appendingPathComponent("workspace", isDirectory: true)
            )
            check(
                persistedWorkspace.editHistoryText().contains("tracked.txt") &&
                persistedWorkspace.revisionHistoryText(path: "tracked.txt").contains("r"),
                "workspace edit history survives engine restart"
            )
        } catch {
            failures.append("workspace edit engine regression: \(error)")
        }

        let rangeTools: Set<String> = [
            "read_file_range", "edit_file_range"
        ]
        check(
            rangeTools.allSatisfy { SemanticToolCatalog.descriptor($0) != nil } &&
            SemanticToolCatalog.descriptor("read_file_range")?.role == .observe &&
            SemanticToolCatalog.descriptor("edit_file_range")?.role == .mutate,
            "semantic ranged tool descriptors"
        )


        // v0.26.1 — recovery/continuation regressions from live conversational use.
        var recoveryArtifact = ArtifactProjection(
            ref: ArtifactRef(
                path: "card.html",
                originTask: TaskID()
            )
        )
        recoveryArtifact.wasRead = true
        recoveryArtifact.wasMutated = true
        recoveryArtifact.wasOpened = true

        let recoverySession = SessionSnapshot(
            projectPath: "/tmp/slta-recovery",
            persistencePath: "/tmp/slta-recovery-state",
            turns: [],
            ledgerEventCount: 4,
            lastProjectRequest: "Создай открытку",
            lastOperationalRequest: "Добавь больше стиля",
            lastProjectMode: .agent,
            lastTaskID: TaskID(),
            lastTaskKinds: [.modify],
            artifacts: [recoveryArtifact],
            lastArtifact: "card.html",
            lastOpenedArtifact: "card.html",
            lastExternalURL: nil,
            previousRequiredLaunch: false,
            previousTaskComplete: false,
            lastTaskMutationCount: 0,
            lastFailure: "old text not found in card.html"
        )

        let resumeEdit = recoverySession.taskContinuity(
            for: "тогда редактируй"
        )
        check(
            resumeEdit.isContinuation &&
            resumeEdit.lastArtifact == "card.html" &&
            resumeEdit.priorGoal == "Добавь больше стиля" &&
            resumeEdit.revisionRequest,
            "short edit imperative resumes unresolved artifact task"
        )

        let openAny = recoverySession.taskContinuity(
            for: "открой любой файл"
        )
        check(
            openAny.isContinuation &&
            openAny.lastArtifact == "card.html",
            "generic artifact launch resolves current focus"
        )

        let diagnostic = recoverySession.directAnswer(
            for: "что случилось?"
        )
        check(
            diagnostic?.contains("old text not found") == true &&
            diagnostic?.contains("card.html") == true,
            "what happened is answered from runtime failure evidence"
        )

        let contextDiagnostic = recoverySession.directAnswer(
            for: "тебе не хватает этого файла в контексте?"
        )
        check(
            contextDiagnostic?.contains("уже был прочитан runtime") == true &&
            contextDiagnostic?.contains("не в отсутствии файла") == true,
            "file-context question distinguishes read state from edit conflict"
        )

        let editDiagnostic = recoverySession.directAnswer(
            for: "ты же только что его создал и не можешь редактировать?"
        )
        check(
            editDiagnostic?.contains("может читать и редактировать") == true &&
            editDiagnostic?.contains("card.html") == true,
            "created artifact remains editable capability truth"
        )

        let capabilityRuntime = RuntimeEnvironment.probe(
            projectURL: URL(fileURLWithPath: "/tmp/slta-recovery", isDirectory: true)
        )
        check(
            DirectRuntimeRouter.answer(
                "можешь редактировать файлы?",
                runtime: capabilityRuntime,
                mcpServers: "no MCP servers configured"
            )?.contains("может читать, создавать и изменять файлы") == true,
            "file capability question is deterministic"
        )

        let recoveryState = RuntimeState()
        let recoverySpec = TaskCompiler.compile(
            userText: "Измени card.html",
            decision: agent
        )
        await recoveryState.beginTask(recoverySpec)
        await recoveryState.observation(
            "read_file",
            path: "card.html"
        )
        await recoveryState.recoverableFailure(
            "edit_file",
            message: "old text not found in card.html"
        )
        let recoverySnapshot = await recoveryState.taskSnapshot()
        check(
            !recoverySnapshot.validation.lastToolFailed &&
            !recoverySnapshot.isComplete &&
            recoverySnapshot.validation.lastFailure == "old text not found in card.html" &&
            recoverySnapshot.missingRequirements.contains(
                .mutateCount(.path("card.html"), 1)
            ),
            "stale exact edit remains recoverable task state"
        )


        // v0.27 — control-plane regressions from the live HTML failure log.
        check(
            DiscourseResolver.analyze(
                "там ошибки, маленький какой-то квадратик"
            ).failureKind == .functional,
            "negative artifact feedback recognizes inflected error wording"
        )

        var liveArtifact = ArtifactProjection(
            ref: ArtifactRef(
                path: "live.html",
                originTask: TaskID()
            )
        )
        liveArtifact.wasRead = true
        liveArtifact.wasMutated = true
        liveArtifact.wasValidated = true
        liveArtifact.wasOpened = true

        let liveSession = SessionSnapshot(
            projectPath: "/tmp/slta-live",
            persistencePath: "/tmp/slta-live-state",
            turns: [],
            ledgerEventCount: 8,
            lastProjectRequest: "Создай live.html минимум 500 строк и открой его",
            lastOperationalRequest: "Добавь стилистических элементов и снова открой",
            lastProjectMode: .agent,
            lastTaskID: TaskID(),
            lastTaskKinds: [.modify, .run, .verify],
            artifacts: [liveArtifact],
            lastArtifact: "live.html",
            lastOpenedArtifact: "live.html",
            lastExternalURL: nil,
            previousRequiredLaunch: true,
            previousTaskComplete: true,
            lastTaskMutationCount: 3,
            lastFailure: nil
        )

        let visualFeedback = liveSession.taskContinuity(
            for: "там ошибки, маленький какой-то квадратик"
        )
        check(
            visualFeedback.isContinuation &&
            visualFeedback.failureKind == .functional &&
            visualFeedback.lastArtifact == "live.html" &&
            visualFeedback.rootGoal?.contains("минимум 500 строк") == true,
            "visual failure feedback reopens focused launched artifact"
        )

        check(
            liveSession.continuationDecision(
                for: "там ошибки, маленький какой-то квадратик"
            )?.mode == .agent,
            "negative artifact feedback routes directly to AGENT"
        )

        let visualRepairSpec = TaskCompiler.compile(
            userText: "там ошибки, маленький какой-то квадратик",
            decision: agent,
            continuity: visualFeedback
        )
        check(
            visualRepairSpec.kinds.contains(.debug) &&
            visualRepairSpec.kinds.contains(.modify) &&
            visualRepairSpec.kinds.contains(.run) &&
            visualRepairSpec.targets.first?.path == "live.html" &&
            visualRepairSpec.requirements.contains(.mutateCount(.path("live.html"), 1)) &&
            visualRepairSpec.requirements.contains(.validate(.path("live.html"))) &&
            visualRepairSpec.requirements.contains(.launch(.path("live.html"))) &&
            visualRepairSpec.constraints.contains(.minimumLineCount(500)),
            "visual feedback compiles repair+validate+relaunch with inherited hard invariant"
        )

        let minimumCreate = TaskCompiler.compile(
            userText: "Создай page.html минимум 500 строк",
            decision: agent
        )
        check(
            minimumCreate.constraints.contains(.minimumLineCount(500)),
            "minimum line count compiles as hard artifact invariant"
        )

        let inheritedMinimum = TaskCompiler.compile(
            userText: "исправь повторы",
            decision: agent,
            continuity: TaskContinuity(
                isContinuation: true,
                priorTaskID: minimumCreate.id,
                priorGoal: "исправь повторы",
                rootGoal: "Создай page.html минимум 500 строк",
                artifactMinimumLineCount: nil,
                lastArtifact: "page.html",
                previousRequiredLaunch: false,
                failureFeedback: false,
                failureKind: .none,
                bareAction: false,
                revisionRequest: true,
                requestsNewArtifact: false
            )
        )
        check(
            inheritedMinimum.constraints.contains(.minimumLineCount(500)),
            "hard artifact invariant survives follow-up edit"
        )

        let invariantProject = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "slta-invariant-selftest-\(UUID().uuidString)",
                isDirectory: true
            )
        let invariantHistory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "slta-invariant-history-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: invariantProject,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: invariantProject)
            try? FileManager.default.removeItem(at: invariantHistory)
        }

        do {
            let invariantRuntime = RuntimeEnvironment.probe(
                projectURL: invariantProject
            )
            let invariantPolicy = PolicyEngine(
                mode: .workspace,
                allowMCP: false
            )
            let invariantWorkspace = Workspace(
                root: invariantProject,
                shellTimeoutSeconds: 5,
                policy: invariantPolicy,
                runtime: invariantRuntime,
                editHistoryRoot: invariantHistory
            )

            invariantWorkspace.beginTask(
                taskID: TaskID(),
                constraints: [.minimumLineCount(5)]
            )

            var rejectedShort = false
            do {
                _ = try invariantWorkspace.writeFile(
                    "guarded.txt",
                    content: "1\n2\n3"
                )
            } catch {
                rejectedShort = String(describing: error)
                    .contains("artifact invariant violated")
            }
            check(
                rejectedShort &&
                !FileManager.default.fileExists(
                    atPath: invariantProject
                        .appendingPathComponent("guarded.txt")
                        .path
                ),
                "hard invariant rejects destructive short rewrite before disk mutation"
            )

            let accepted = try invariantWorkspace.writeFile(
                "guarded.txt",
                content: "1\n2\n3\n4\n5"
            )
            check(
                accepted.contains("tx="),
                "hard invariant accepts compliant revision"
            )
        } catch {
            failures.append("artifact invariant regression: \(error)")
        }

        let relaunchContinuity = TaskContinuity(
            isContinuation: true,
            priorTaskID: TaskID(),
            priorGoal: "открой live.html",
            rootGoal: "создай live.html",
            artifactMinimumLineCount: nil,
            lastArtifact: "live.html",
            previousRequiredLaunch: true,
            failureFeedback: true,
            failureKind: .notLaunched,
            bareAction: false,
            revisionRequest: false,
            requestsNewArtifact: false
        )
        let relaunchSpec = TaskCompiler.compile(
            userText: "ты не открыл файл",
            decision: agent,
            continuity: relaunchContinuity
        )
        let relaunchState = RuntimeState()
        await relaunchState.beginTask(relaunchSpec)
        var relaunchSnapshot = await relaunchState.taskSnapshot()

        if case .deterministic(.readFile("live.html")) = ProtocolEngine.decision(
            for: relaunchSnapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("not-launched recovery deterministic inspect")
        }

        await relaunchState.readBack(
            path: "live.html",
            content: "<html></html>"
        )
        relaunchSnapshot = await relaunchState.taskSnapshot()

        if case .deterministic(.openFile("live.html")) = ProtocolEngine.decision(
            for: relaunchSnapshot,
            allowed: allTools
        ) {
            passed += 1
        } else {
            failures.append("not-launched recovery deterministic relaunch")
        }

        let total = passed + failures.count
        if failures.isEmpty {
            return "SLTA self-test: PASS \(passed)/\(total)"
        }

        return "SLTA self-test: FAIL \(passed)/\(total) · " + failures.joined(separator: "; ")
    }
}

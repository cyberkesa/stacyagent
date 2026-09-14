# Stacy Agent v0.33 — Code Review

## Critical Bugs

### 1. `workbench/bench/v1/bench.mjs:75` — `pkill` regex never matches

```js
spawnSync('pkill', ['-9', '-f', `stacyagent-runtime|mlxagent.*${WORKSPACE}`]);
```

macOS `pkill` uses POSIX **basic** regex by default. In BRE, `|` is literal, not alternation. The pattern matches the verbatim string `stacyagent-runtime|mlxagent.*<path>` which no process contains. `killStrayDaemons` is a no-op.

**Fix:** split into two calls or use `-E`:
```js
spawnSync('pkill', ['-9', '-f', 'stacyagent-runtime']);
spawnSync('pkill', ['-9', '-f', `mlxagent.*${WORKSPACE}`]);
```

### 2. `workbench/bench/v1/bench.mjs:179` — rename task lacks file target

```js
'rename UserManager to AccountManager'
```

The `SemanticRenameIntent.parse` pattern makes `path` optional. Without a file path the rename engine must discover all references, but the `EditEngine` / `SemanticRenameIntent` pathless flow was never verified in acceptance tests (they use `in A.swift`). Task B likely reports `outcome: incomplete` and `clean && renamed` fails because only A.swift was renamed or nothing was renamed.

**Fix:** match acceptance.mjs: `'rename UserManager to AccountManager in A.swift B.swift C.swift'` or add a dedicated multi-file rename intent path.

### 3. `src/vs/workbench/contrib/stacyagent/browser/stacyagent.contribution.ts:217` — hard dependency on chat module

```ts
import { ChatViewId } from '../../chat/browser/chat.js';
```

This import binds the Stacy Agent contribution to the chat module's existence. If the chat module is ever split out, renamed, or tree-shaken, the entire workbench compilation fails. The `closeView(ChatViewId)` call also assumes the view is registered at `LifecyclePhase.Restored` — if chat loads later, the view might not exist yet (the `try/catch` handles this, but the import doesn't).

**Fix:** use the string ID `'workbench.panel.chat'` instead of the symbol, or move the close-logic to a `setTimeout`/`when` observer on the view registry.

## High Issues

### 4. `stacyagent.contribution.ts:197` — `chat.disableAIFeatures` at USER level may not override workspace

```ts
this.configurationService.updateValue('chat.disableAIFeatures', true, ConfigurationTarget.USER)
```

If a workspace has `"chat.disableAIFeatures": false` in its `.vscode/settings.json`, the user-level setting doesn't override it — workspace wins. The Chat view could still appear.

**Fix:** also inspect the workspace value and notify, or use `ConfigurationTarget.MERGED` / `default` override.

### 5. `stacyagentView.ts:273` — `attachActiveFile` breaks on paths with spaces

```ts
const path = this.editorContextText.split(' ')[0];
```

`editorContextText` is `${relative} (lines X-Y)`. Splitting on space and taking `[0]` works for paths without spaces. macOS paths commonly contain spaces (e.g. `My Project/UserManager.swift`). The match regex `/^active: ([^ ]+)/` in `attachActiveFile` has the same problem.

**Fix:** parse the lines prefix with a regex: `/^active: (.+?) \(lines/`.

### 6. `AgentLoop.swift:86` — redundant `GenerationStats` in direct path

```swift
if let direct = ConversationDirectRouter.match(task) {
    var stats = GenerationStats()   // created, finished, assigned to lastStats
    ...
}
```

This is functionally correct but creates a `GenerationStats` that shadows the outer one. Not a bug, but confusing — the outer `stats` at line 111 is never reached for direct matches. Consider reusing or removing the local one.

### 7. `RuntimeService.swift:309` — double `ConversationDirectRouter.match`

The match is checked in `submitTurn` (line 309) AND inside `runTurn` for the fake-model path (where `AgentLoop.run` also checks it for the MLX path). The `submitTurn` check gates `recentTaskSummary`, but `runTurn` for the fake model also checks it for the direct answer. Redundant but not harmful.

## Medium Issues

### 8. `stacyagentView.ts:344` — `completed` event silently dropped

```ts
if (caseName === 'completed' && !this.timelineTaskOpen) { return; }
```

A `completed` event without a matching `taskStarted` is dropped. This is correct for greeting direct-answers (no task), but if a task completes and the view opened *after* `taskStarted` (so `timelineTaskOpen` was never set to `true`), the `completed` event is also dropped. The timeline would show `taskStarted` but not `✓ done`.

**Fix:** track task state from snapshots rather than relying solely on event order.

### 9. `stacyagentView.ts:353` — dedup on `summary` text, not event identity

Two different events with the same summary text (e.g., two `toolFinished` events for the same tool with the same detail) collapse into one. This is acceptable for UI but loses information.

### 10. `extensions/stacyagent-theme/themes/stacyagent-light.json` — `tokenColors: []`

Empty token color array means no syntax highlighting customization. The theme inherits default token colors which may not look good on the light pink background. Consider adding at least a few token colors.

### 11. `workbench/harness/cdp-proof.mjs` — hardcoded CDP port

The proof script uses `--cdp-port 9335` but the launcher also uses `--remote-debugging-port=${CDP_PORT}`. If multiple instances run, port conflicts occur. The `cdp-proof.mjs` should use a random available port or accept it as an argument consistently.

### 12. `stacyagentWorkbenchService.ts:91` — hardcoded fallback args

```ts
extraArgs: config.runtimeArgs ?? ['--fake-runtime', '--no-mcp']
```

The default `--fake-runtime --no-mcp` is hardcoded in the workbench service AND in the benchmark `ensureRuntime` call. If the user changes `stacyagent.runtimeArgs` in settings, the fallback is still `--fake-runtime --no-mcp`. This is intentional for the fake model but inconsistent with `stacyagent.runtimePath` which is configurable.

## Low / Style

### 13. `stacyagent.contribution.ts` — `ICommandService` imported but also used via `accessor.get` in the same file

The `ICommandService` import at line 18 is used in `stacyagent.openLastChange`. It's imported from the same module as `CommandsRegistry` — fine, but the duplicate import path (`../../../../platform/commands/common/commands.js` for both) is correct.

### 14. `acceptance.mjs:149` — `__ipc_test_block__` is a test-only payload

The string `__ipc_test_block__` is checked in `RuntimeService.swift:473` with a 30-second sleep. This is a test hook that leaks into production code. Acceptable for a benchmark but should be gated behind a feature flag in production builds.

### 15. `stacyagentRuntimeClient.ts:157` — 10-minute request timeout

```ts
const REQUEST_TIMEOUT_MS = 10 * 60 * 1000;
```

A 10-minute timeout for `submitTurn` means a hung runtime blocks the UI for 10 minutes before the user sees an error. Consider a shorter default (e.g., 60s) with a configurable override.

### 16. `extensions/stacyagent-theme/package.json` — missing `enabledApiProposals` and `capabilities`

For VS Code 1.137, the theme extension should declare `capabilities: { virtualWorkspaces: false, untrustedWorkspaces: { supported: true } }` to avoid security warnings.

## Architecture Notes (no changes requested, just observed)

- **RuntimeService.swift `recentTaskSummary` gating** (line 309): The conversational check `ConversationDirectRouter.match(value.text) == nil` correctly avoids polluting `recentTaskSummary` with greetings. But `recentTaskSummary` is set from the raw user text, not the routed intent. For "rename UserManager to AccountManager", it stores the full user prompt, not "rename UserManager → AccountManager". Minor UX issue.

- **IPC envelope `requestID`**: The TS client generates uppercase UUIDs (`crypto.randomUUID().toUpperCase()`), matching the Swift side. The protocol is consistent.

- **EventBus is an actor**: All events flow through `EventBus.emit()` which is `async`. The `RuntimeService` translates events to IPC envelopes synchronously in `translate()`, then broadcasts. The actor isolation ensures ordering. Good.

- **`ComputationRouter.cost()` for `semanticQuery` returns `modelCalls: 0`**: This means semantic queries (definition, references, rename intent detection) are zero-model. The benchmark task C ("Where is AccountManager defined?") uses `semanticQuery` strategy with 0 model calls — correct.

- **`contextAndModel` strategy returns `modelCalls: 1`**: Reasoning tasks route here. The fake model generates a response. Benchmark tasks D and E expect `modelCalls >= 1` — correct.

## Summary Table

| # | Severity | File | Issue |
|---|----------|------|-------|
| 1 | Critical | bench.mjs:75 | `pkill` regex never matches on macOS |
| 2 | Critical | bench.mjs:179 | Rename task lacks file target |
| 3 | Critical | stacyagent.contribution.ts:217 | Hard import on chat module |
| 4 | High | stacyagent.contribution.ts:197 | `chat.disableAIFeatures` may not override workspace |
| 5 | High | stacyagentView.ts:273 | Path-with-spaces breaks attachActiveFile |
| 6 | Medium | AgentLoop.swift:86 | Redundant `GenerationStats` in direct path |
| 7 | Medium | RuntimeService.swift:309 | Double `ConversationDirectRouter.match` |
| 8 | Medium | stacyagentView.ts:344 | `completed` dropped when task not tracked |
| 9 | Low | cdp-proof.mjs | Hardcoded CDP port conflicts |
| 10 | Low | stacyagent-theme | Empty `tokenColors` |

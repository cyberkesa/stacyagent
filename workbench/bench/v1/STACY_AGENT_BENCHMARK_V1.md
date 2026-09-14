# Stacy Agent Benchmark v1 — Protocol Level, Fake-Model Runtime

## Purpose
Protocol-level benchmark that exercises the IPC contract, routing logic, and telemetry
using the fake-model runtime (deterministic, no MLX). All tasks run against a fixed
workspace (`workbench/bench/v1/workspace`) reset before every run.

## Workspace
- `A.swift` — `struct UserManager { ... }` + `TODO` marker
- `B.swift` — `userCount()` returning `-1`
- `C.swift` — `describe(_ m: UserManager)` helper

## Tasks

| Task | Query | Intent | Strategy | Model Calls | Expected |
|------|-------|--------|----------|-------------|----------|
| A-exact-search | `Find exact string "TODO" in project files.` | literalSearch | literalSearch | 0 | completed, cites marker |
| B-semantic-rename | `rename UserManager to AccountManager in A.swift` | semanticRename | semanticQuery | 0 | completed, A.swift renamed |
| C-deterministic-navigation | `Find "AccountManager" in project files.` | literalSearch | literalSearch | 0 | completed, mentions AccountManager |
| D-reasoning-bugfix | `Fix the userCount bug in B.swift` | implicitFocusedMutation → modify | contextAndModel | ≥1 | incomplete (fake model can't edit) |
| E-multifile-reasoning | `Trace AccountManager usage across A,B,C.swift` | inspection → reason | contextAndModel | ≥1 | incomplete (fake model can't reason) |

## Running
```bash
node workbench/bench/v1/bench.mjs --binary .build/debug/stacyagent-runtime
node workbench/bench/v1/bench.mjs --binary .build/debug/stacyagent-runtime --json
```

## Current Results (2026-09-14)
```
PASS A-exact-search :: outcome=completed wall=8ms calls=0 strategy=literalSearch
PASS B-semantic-rename :: outcome=completed wall=287ms calls=0 strategy=semanticQuery
PASS C-deterministic-navigation :: outcome=completed wall=7ms calls=0 strategy=literalSearch
PASS D-reasoning-bugfix :: outcome=incomplete wall=5ms calls=2 strategy=contextAndModel
PASS E-multifile-reasoning :: outcome=incomplete wall=5ms calls=2 strategy=contextAndModel
```

## Notes
- A, B, C are deterministic (0 model calls) — verify routing + file effects
- D, E are model-routed (≥1 model calls) — verify routing metrics; fake model can't edit/reason
- `strategy=literalSearch` on D/E is from `computationFinished` fallback; `routerCalls=0` confirms no routed event
- `generations` counts `intelligenceFinished` events (not `generationStarted`, which is never emitted)

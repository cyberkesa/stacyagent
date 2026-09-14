# Stacy Agent performance rules

1. LLM passes are a budget, not a convenience.
2. Deterministic runtime work never goes through the model.
3. Send only turn-relevant tool schemas.
4. Reuse one resident ModelContainer.
5. Reuse KV cache within a task session.
6. New task = new project tool session; chat alone keeps conversational history.
7. Read-only actions may be parallelized in a future release; mutations stay serialized.
8. Avoid shell when the runtime can validate directly.
9. Cap and compact tool output before it enters model context.
10. Never rescan ignored/generated dependency trees.
11. MCP discovery must be cached and eventually honor server TTL/cacheScope.
12. Optimize measured TTFT/model passes/tool count before adding features.

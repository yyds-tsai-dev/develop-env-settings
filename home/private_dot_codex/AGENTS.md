<!-- caveman-default:start -->
# Default response style

- Enable the caveman skill by default at the start of every session, with intensity `full`. Read and follow `~/.codex/skills/caveman/SKILL.md`.
- Keep the user's language and preserve technical accuracy. Apply the skill's normal-prose exceptions for persisted artifacts.
- Honor explicit style changes. `/caveman off`, `stop caveman`, or `normal mode` disables this default for the rest of the session unless the user enables it again.
<!-- caveman-default:end -->

<!-- codebase-memory-mcp:start -->
# Codebase Memory

## Codebase Knowledge Graph (codebase-memory-mcp)

This project uses codebase-memory-mcp to maintain a knowledge graph of the codebase.
ALWAYS prefer MCP graph tools over grep/glob/file-search for code discovery.

### Priority Order
1. `search_graph` — find functions, classes, routes, variables by pattern
2. `trace_path` — trace who calls a function or what it calls
3. `get_code_snippet` — read specific function/class source code
4. `check_index_coverage` — validate candidate paths and missed ranges before claims
5. `query_graph` — run Cypher queries for complex patterns
6. `get_architecture` — high-level project summary

### Evidence tiers
- **Scout (Tier 1):** quick positive lookup with few calls and targeted source checks. Mark it provisional; do not make negative or exhaustive claims.
- **Verify (Tier 2, default):** task-directed graph evidence, relevant trace directions, exact snippets for material claims, and relevant pagination.
- **Auditor (Tier 3):** bounded-scope full verification with current generation, complete relevant pagination, both call directions and broader relationships when material, and every limitation disclosed.
- After candidate paths are known in any tier, call `check_index_coverage` once with every evidence path. Add relevant scopes for negative or exhaustive claims. A clean result means no recorded gap, not proof of completeness. For partial, skipped, excluded, stale, pending, or unknown coverage, read/grep the reported ranges or scope before relying on graph results.

### When to fall back to grep/glob
- Searching for string literals, error messages, config values
- Searching non-code files (Dockerfiles, shell scripts, configs)
- When MCP tools return insufficient results

### Examples
- Find a handler: `search_graph(name_pattern=".*OrderHandler.*")`
- Who calls it: `trace_path(function_name="OrderHandler", direction="inbound")`
- Read source: `get_code_snippet(qualified_name="pkg/orders.OrderHandler")`

### Session resets and subagents
- At session start or after compaction, confirm the nearest graph project and generation with `list_projects` or `index_status`, then choose Scout, Verify, or Auditor.
- Before spawning a subagent, query the graph and coverage in the parent. Pass the tier, project, generation/freshness, bounded scope, queries and pagination state, qualified symbols, paths, call-chain findings, coverage evidence with ranges/reasons, source fallback already performed, and unresolved questions in the delegated task context.
- Do not assume subagents inherit MCP access or the parent conversation. If a child lacks MCP tools, it must not call or claim MCP access. It should use the supplied evidence and read/grep exact source, especially every reported missed-coverage range.
<!-- codebase-memory-mcp:end -->


<!-- codex-efficient-waiting:start -->
# Completion-driven background work

- Before starting expected asynchronous commands, long tests/builds, CI watchers, or authorized executors, read and follow `~/.codex/skills/codex-queue-workflow/SKILL.md`. Keep known-short commands direct.
- Establish native completion or a one-shot `codex queue` callback to the exact current parent UUID before launch. Save job identity, PID, logs and terminal results; do useful independent work, then yield without model-driven polling. Never duplicate running work to repair notification.
- Verify saved results after completion; preserve newer stop/pause instructions and the active task scope. CLI queue support alone does not prove wake-up. If unavailable, disclose the specific limitation once and leave a durable resumable handoff.
- Delegate only when the user or applicable instructions request it, for a concrete independent task. Use bounded ownership and acceptance checks; review completed checkpoints and batch corrections.
<!-- codex-efficient-waiting:end -->

# ContextOS

Local, AI-free **context manager for Claude Code**.

ContextOS does not replace Claude Code and does not call any LLM. It runs
entirely on your machine (AST/heuristics, Git, filesystem, static analysis) to
help Claude Code work with **less context, more accurately**, by feeding it only
the files that matter.

> No OpenAI / Claude / Gemini API. No LLM calls. No external servers. Everything
> is local.

## Architecture

All logic lives in `ContextOSCore`. Every other surface is a thin adapter:

```
Claude Code  ──stdio(JSON-RPC)──▶  contextos-mcp  ──▶  ContextOSCore  ──▶  SQLite
Menu Bar App ───────────────────────────────────────────┘
CLI (dev/debug) ─────────────────────────────────────────┘
```

- **ContextOSCore** — indexing, filtering, ranking, token estimation (pure logic)
- **contextos** (CLI) — development + verification surface
- **contextos-mcp** — MCP server exposing `get_relevant_context` etc. (M3)
- **App** — SwiftUI Menu Bar dashboard (M4)

## Status — M1 + M2

**M1 — indexing foundation**

- [x] SwiftPM workspace (`ContextOSCore` + `contextos` CLI)
- [x] Smart file filter (default deny-list: `node_modules`, `.git`, `build`, …)
- [x] Project scanner with directory pruning
- [x] Heuristic symbol/import extractor (`LanguageParser` seam for Tree-sitter)
- [x] SQLite index store (system SQLite3, no external deps)
- [x] `contextos index` / `contextos stats`

**M2 — token estimation + context optimization**

- [x] Local token estimator (calibrated char-density, shown as `~11K`)
- [x] Context optimizer: lexical scoring + import-graph expansion + budget fill
- [x] Context Score (0–100) and excluded-file surfacing
- [x] `contextos context "<query>" --budget N`

**M3 — MCP server** (`contextos-mcp`)

- [x] stdio JSON-RPC 2.0 server (stdout = protocol only, logs → stderr)
- [x] Tools: `get_relevant_context`, `read_optimized`, `index_project`,
      `project_stats`, `get_project_rules`, `dependency_map`, `restore_session`
- [x] Auto-indexes on first query (zero config)
- [x] `ContextService` facade shared by CLI + MCP

**M4 — Prompt Linter + Menu Bar dashboard**

- [x] Rule-based prompt linter (vague / no-target / over-broad; EN + KO)
- [x] `contextos lint "<prompt>"`
- [x] SwiftUI `MenuBarExtra` dashboard (`ContextOSApp`): project picker, query,
      live Context Score, tokens saved vs. whole project, file list, lint warnings

**M5–M10 — full feature set**

- [x] **Git Analyzer** — branch/commits/changed files → ranking boost (Smart
      Context Builder: files you're editing surface automatically). `contextos git`
- [x] **Project Rules** — persistent conventions, auto-inferred language, injected
      into `read_optimized` + `get_project_rules`. `contextos rules`
- [x] **Dependency Explorer** — import graph as tree / Graphviz DOT. `contextos deps`
- [x] **Usage Analytics** — local DB of tokens saved (today / total / per project).
      `contextos usage`
- [x] **Context Advisor** — warns on over-broad queries or budget-cut files
- [x] **Session Snapshot** — save/restore working state for a new session.
      `contextos snapshot`

The full ContextOS feature set from the spec is implemented, all local, no AI.
Remaining polish: swap the heuristic parser for Tree-sitter (already behind the
`LanguageParser` seam).

## Run the dashboard

```sh
swift run ContextOSApp   # menu-bar app (no Dock icon)
```

## Connect to Claude Code

Build a release binary, then register the MCP server:

```sh
swift build -c release
# absolute path to the built server:
echo "$(pwd)/.build/release/contextos-mcp"

# register it with Claude Code (stdio):
claude mcp add contextos -- "$(pwd)/.build/release/contextos-mcp"
```

Or drop a `.mcp.json` in your project root (see `.mcp.json.example`):

```json
{
  "mcpServers": {
    "contextos": { "command": "/abs/path/.build/release/contextos-mcp", "args": [] }
  }
}
```

Then in Claude Code, before reading files, ask ContextOS what matters:

> use get_relevant_context for "fix login"

The server auto-indexes the working directory on first call. Each tool also
accepts an explicit `path` and `token_budget`.

## How the optimizer works (no AI)

```
contextos context "fix login"
  → terms: [login]
  → login.py     score 5.0   ‘login’ → symbol login
  → auth.py      score 2.0   linked via login.py     (import graph, 1 hop)
  → jwt.py       score 0.8   linked via login.py     (2 hops, decayed)
  → database.py  score 0.8   linked via login.py
  ✗ billing.py, dashboard.py — no link to login, excluded
```

Three rule-based signals: **(1)** query terms vs symbol/file/path/import names,
**(2)** import-graph expansion with per-hop decay, **(3)** greedy selection under
a token budget (relevant-but-over-budget files are surfaced, never silently
dropped).

## Develop

Open in Xcode:

```sh
open Package.swift
```

Or from the CLI:

```sh
swift build
swift test
swift run contextos index /path/to/project
swift run contextos stats /path/to/project
```

The index is written to `<project>/.contextos/index.sqlite`.

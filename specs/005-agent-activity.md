---
id: 005
title: Agent activity window
status: draft
owner: "@alfredoagrar"
created: 2026-11-12
depends-on: [001]
---

# 005 · Agent activity window

## Problem
Headroom shows how much quota is left, but not *what is consuming it*. With several Claude Code sessions (desktop app, VS Code, CLI) and Codex running at the same time, there's no single place to see which agents are alive, which are working right now, and how many tokens and how much CPU/memory each one uses. Activity Monitor only shows a dozen anonymous `claude` processes.

## Goals
- A separate **Agent activity** window, opened from the popover, listing every running Claude Code and Codex agent on this Mac.
- Per agent: host app, project, session title, status (working / idle), CPU %, memory, uptime, model, session token usage (including subagents).
- Inspector with token breakdown (input / output / cache read / cache write / thinking), per-model split, subagents, PID and full working directory.
- Zero cost while the window is closed.

## Non-goals
- Controlling agents (kill, pause, send messages). Headroom stays read-only.
- Cost in USD (product non-goal, see 000 §1), historical token reports, network or disk I/O.
- Agents other than Claude Code and Codex (Gemini CLI, Cursor agent, Copilot) → follow-up spec.
- An "N agents working" line in the popover (needs background polling) → follow-up.

## Data sources (verified 2026-11-12, Claude Code 2.1.319–2.1.321, Codex CLI 0.157.0)

### Claude Code
- **Live registry:** `$CLAUDE_CONFIG_DIR` or `~/.claude` → `sessions/<pid>.json`, one file per running session, written for every entry point (desktop app, VS Code, CLI). Fields used: `pid`, `sessionId`, `cwd`, `startedAt` (epoch ms), `procStart` (UTC string, e.g. `Fri Nov 13 03:57:20 2026`), `version`, `kind`, `entrypoint` (`claude-desktop`, `claude-vscode`, `cli`, …), `name` (session title), `status` (`busy` / `idle`), `statusUpdatedAt`.
  - The same folder holds `<pid>.<hash>.key` files: secrets for each session's messaging socket. **Never opened.** `messagingSocketPath` is never used.
  - Files can outlive their process → an entry is valid only if the pid is alive **and** the process start time matches `procStart` (±2 s, guards against PID reuse).
- **Transcript:** `projects/*/<sessionId>.jsonl`. Locate it by `sessionId` across project folders; don't re-derive the folder-name encoding. Files up to 31 MB observed.
  - Each API response is written as **one line per content block**, and every one of those lines repeats the full `message.usage`. Totals must be de-duplicated by `message.id` (last line wins). Observed: 253 assistant lines → 93 responses; a naive sum overcounts ~2.7×.
  - Fields used: `type == "assistant"`, `message.id`, `message.model` (skip `<synthetic>`), `message.usage.{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens_details.thinking_tokens}`, `timestamp`.
  - The `cost-state` line is a stale snapshot (written once per process start) → not used.
- **Subagents:** `projects/*/<sessionId>/subagents/agent-<id>.jsonl` (same line format, `isSidechain: true`, may use other models) + `agent-<id>.meta.json` → `agentType`, `description`. Their tokens are added to the parent session's total and listed separately in the inspector.

### Codex
- **No live registry.** Running agents are processes whose executable is named `codex` (npm, Homebrew, IDE extension `app-server`, Codex app). The `node` wrapper of the npm install is not matched, so nothing is counted twice.
- **Rollouts:** `$CODEX_HOME` or `~/.codex` → `sessions/YYYY/MM/DD/rollout-*.jsonl`.
  - `session_meta.payload.{id, timestamp, cwd, originator, source, cli_version}`. **Never decoded:** `creator_user_id`, `creator_account_id`, `base_instructions`.
  - `turn_context.payload.model` → current model.
  - `event_msg` with `payload.type == "token_count"` → `payload.info.total_token_usage.{input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens}` (cumulative: last event wins) and `payload.info.model_context_window`.
  - Status: a `task_started` event after the last `task_complete` → working.
- **Process → rollout mapping:** rollout files the process holds open (libproc fd list). Fallback: newest rollout whose `session_meta.cwd` equals the process cwd and that was modified after the process started. One process can host several sessions (IDE `app-server`). ⚠️ Not verified against a live Codex process yet (none was running) → AC10.

### Processes (both)
libproc only — no `ps`, no argv or environment reads:
- `proc_listallpids`, `proc_pidpath` (executable), `proc_pidinfo(PROC_PIDTBSDINFO)` (ppid, start time), `proc_pidinfo(PROC_PIDVNODEPATHINFO)` (cwd).
- `proc_pid_rusage(RUSAGE_INFO_V4)`: `ri_user_time + ri_system_time` (two samples → CPU %), `ri_phys_footprint` → memory (the value Activity Monitor shows).
- CPU and memory include the agent's **descendant processes** (tool runs, MCP servers, shells). The inspector shows the agent-only vs children split.

## User experience

**Entry point.** The popover header gets a glass button (`waveform.path.ecg`, tooltip "Agent activity") next to refresh, and the `⋯` menu gets **Agent activity…**. It opens the window, or focuses it if already open, and activates the app so the window comes to the front.

**Window** — standard resizable window (default 920×540, min 680×380), summary tiles with `.glassEffect`, a sortable `Table`, and an `.inspector` for the selected row:

```
┌ Agent activity ─────────────────────────────────────────── [◻ Working only] ┐
│ ╭ 11 agents ╮ ╭ 1 working ╮ ╭ CPU 23% ╮ ╭ Memory 1.6 GB ╮ ╭ Tokens 24.1M ╮   │
│                                                                             │
│  Agent              Project        Status     CPU   Memory  Uptime  Tokens  │
│  ● Claude Code      ailimits       Working  19.7%   310 MB  2m       3.4M   │
│    Desktop · "Headroom agent activity spec" · Opus 5.5                      │
│  ○ Claude Code      TMNA86         Idle 12m  0.1%   115 MB  2h 22m   812K   │
│    VS Code · "Fix login redirect" · Opus 5.5                                │
│  ○ Codex            sketch_nov9a   Idle      0.0%    41 MB  4d 2h     14K   │
│    Exec · gpt-6-luna                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Inspector** (selected row):
```
Claude Code · Desktop                     ● Working
Headroom agent activity spec
~/Documents/apps/ailimits
PID 4742 · v2.1.321 · started today, 20:57

Tokens (session)               3.4M
  Input                        2.1K
  Output                       120K
  Cache read                   3.1M
  Cache write                  198K
  Thinking                     8.2K
By model
  claude-opus-5-5              3.4M
Subagents (2)
  Explore · "Find usages of…"  412K   active 5s ago
  general-purpose               88K   3h ago
Resources
  CPU     19.7%  (agent 12.1% · 3 children 7.6%)
  Memory  310 MB (agent 280 MB · children 30 MB)
```

- **One row per agent process.** Claude Code is one session per process. A Codex `app-server` with several sessions shows the most recently active session's project with a "+N" badge, and lists all its sessions in the inspector.
- **Sorting:** working first, then CPU descending. Every column is sortable. The **Working only** toggle hides idle agents.
- **Refresh while open:** processes every 2 s, registry and transcripts every 5 s (only files whose size or mtime changed). Everything stops when the window closes.
- **States:**
  - Empty: "No agents running. Start Claude Code or Codex and they'll show up here."
  - Loading: the Tokens cell shows a spinner while a transcript's first scan runs.
  - Partial: process found but no session data → "—" with a tooltip ("Session data not found").
  - Read error on one agent → "—" plus tooltip; other rows unaffected.

## Design

| File | Contents |
|------|----------|
| `Core/Agents/AgentModels.swift` | `AgentKind`, `AgentHost`, `AgentStatus`, `TokenUsage`, `AgentSession`, `AgentSubagent`, `AgentRow` |
| `Core/Agents/ProcessSampler.swift` | libproc wrapper → `ProcessSample`; pure `cpuPercent(previous:current:)` and descendant aggregation |
| `Core/Agents/JSONLTail.swift` | Incremental reader: byte offset + partial-line buffer, reset if the file shrinks or its inode changes; skips lines that don't contain a cheap marker substring before JSON decoding |
| `Core/Store/AgentMonitor.swift` | `@MainActor @Observable`; `start()` / `stop()`; publishes `[AgentRow]` and summary totals |
| `Providers/Claude/ClaudeSessionRegistry.swift` | Pure `parse(_ data: Data)` + loader that lists only `*.json`, with an injectable file reader |
| `Providers/Claude/ClaudeTranscriptUsage.swift` | Accumulator: `[messageID: (model, TokenUsage)]`, last line wins; subagent meta |
| `Providers/Codex/CodexRolloutUsage.swift` | Accumulator for `session_meta`, `turn_context`, `token_count` and task events |
| `UI/Agents/AgentActivityWindow.swift`, `UI/Agents/AgentInspector.swift` | `Table` + `.inspector`, summary tiles |
| `App/HeadroomApp.swift` | `Window(…, id: "agents")` scene |
| `UI/Popover/PopoverView.swift` | Entry button and menu item (`openWindow(id: "agents")` + `NSApp.activate()`) |

```swift
enum AgentKind: String, Sendable { case claudeCode, codex }
enum AgentHost: String, Sendable { case desktop, vscode, cursor, jetbrains, cli, exec, appServer, sdk, unknown }
enum AgentStatus: Sendable, Equatable { case working, idle(since: Date?), unknown }

struct TokenUsage: Sendable, Equatable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, thinking = 0
    var total: Int { input + output + cacheRead + cacheWrite }
}

struct AgentSession: Sendable, Identifiable {
    let id: String                 // provider session id: used for lookups, never displayed
    let kind: AgentKind, host: AgentHost
    let cwd: String, title: String?, version: String?
    let startedAt: Date?, lastActivity: Date?, status: AgentStatus
    let model: String?, tokens: TokenUsage, tokensByModel: [String: TokenUsage]
    let subagents: [AgentSubagent]
}

struct AgentRow: Sendable, Identifiable {   // one per agent process
    let pid: Int32, kind: AgentKind, startedAt: Date
    let cpuPercent: Double, ownCPUPercent: Double
    let memoryBytes: UInt64, ownMemoryBytes: UInt64, childCount: Int
    let sessions: [AgentSession]   // Claude: 1; Codex app-server: 0…n
    var id: Int32 { pid }
}
```

- **Host mapping:** Claude `entrypoint` (`claude-desktop` → Desktop, `claude-vscode` → VS Code, `cli` → CLI, `sdk-*` → SDK), refined by executable path (`/.cursor/extensions/` → Cursor). Codex `originator` / `source` (`codex_exec` → Exec, `app-server` → App server, …). Unknown values are shown verbatim.
- **Concurrency:** libproc sampling and file parsing run in an `AgentCollector` actor off the main thread. `AgentMonitor` only receives value snapshots. Per-file accumulator state lives in memory only.
- **Rule from AGENTS.md holds:** `Core/` and `Providers/` don't import SwiftUI or AppKit (libproc is in `Darwin`).

### Security & privacy
- Transcripts and rollouts contain prompts, code and tool output. Decoders declare **only** the fields listed in *Data sources*. Raw lines are never stored, logged or written anywhere. Nothing from this feature is persisted to disk.
- Never open `~/.claude/sessions/*.key`. Never connect to `messagingSocketPath` or `~/.codex/ipc/ipc.sock`. Never decode Codex `creator_user_id` / `creator_account_id`.
- Never read other processes' argv or environment (they can contain prompts or keys). Only executable path, ppid, start time, cwd and resource usage via libproc.
- No network requests. No signals sent to any process.
- Session titles, working directories and subagent descriptions are displayed locally only.

## Acceptance criteria
- [ ] AC1 — "Agent activity" opens from the popover header button and from the `⋯` menu, appears in front; reopening focuses the existing window.
- [ ] AC2 — `ClaudeSessionRegistryTests`: fixture registry parses; an entry whose pid is dead or whose start time differs from `procStart` by > 2 s is dropped.
- [ ] AC3 — The registry loader never opens `*.key` files: with an injected file reader over a temp dir containing `123.json` and `123.<hash>.key`, the recorded paths contain no `.key`.
- [ ] AC4 — `ClaudeTranscriptUsageTests`: one response split over 3 block lines counts once; a later line with the same `message.id` replaces the earlier one; `<synthetic>` is skipped; subagent tokens are added to the session; per-model split is correct.
- [ ] AC5 — Incremental parsing: appending lines (including a partial last line completed by a later append) gives the same totals as a full parse.
- [ ] AC6 — `CodexRolloutUsageTests`: last `token_count` wins; model comes from the latest `turn_context`; status is working iff a `task_started` follows the last `task_complete`.
- [ ] AC7 — Privacy canary: fixture lines with `SECRET-CANARY` in prompt, tool output and Codex `creator_*` fields → the canary is absent from `String(reflecting:)` of every produced value.
- [ ] AC8 — `ProcessSamplerTests`: `cpuPercent` from two synthetic samples; descendant aggregation over a synthetic ppid table (including a cycle-free deep tree and orphaned children).
- [ ] AC9 — On the maintainer's Mac: every running Claude Code session (desktop + VS Code) is listed; CPU and memory are within ±10 % of Activity Monitor; token totals match a de-duplicated `jq` count of the same transcripts (command included in the PR).
- [ ] AC10 — With a live `codex` process (CLI, and IDE `app-server` if available), its session(s), model and tokens appear. The PR states whether the fd-based mapping or the cwd fallback was used.
- [ ] AC11 — Closing the window stops all sampling: no libproc calls or file reads afterwards (debug-build counter).
- [ ] AC12 — First scan of a 30 MB transcript finishes in < 1 s off the main thread with the UI responsive; incremental refreshes take < 20 ms.

## Test plan
- Unit: synthetic, anonymized fixtures `claude_session_registry.json`, `claude_transcript.jsonl`, `claude_subagent.meta.json`, `codex_rollout.jsonl` covering AC2–AC8.
- Manual: AC1 and AC9–AC12, comparing against Activity Monitor and `jq`.
- Security: run the `security-reviewer` subagent (touches `Providers/` and local credential-adjacent folders).

## Open questions
1. **UI language.** The popover copy is Spanish; repo docs are English. Should this window be English (and the popover translated in a follow-up), Spanish to match, or localized (en + es)?
2. **Other agents in v1?** Gemini CLI, Cursor agent and Copilot could be listed with process metrics only (no tokens) by matching executables. Default: no, follow-up spec.
3. **API-equivalent cost.** Claude Code computes a USD cost internally; showing an estimate needs a price table to maintain. Default: no (product non-goal).

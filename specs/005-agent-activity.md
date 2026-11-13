---
id: 005
title: Agent activity window
status: approved
owner: "@alfredoagrar"
created: 2026-11-12
depends-on: [001]
---

# 005 · Agent activity window

## Problem
Headroom shows how much quota is left, but not *what is consuming it*. With several Claude Code sessions (desktop app, VS Code, CLI) and Codex running at the same time, there's no single place to see which agents are alive, which are working right now, and how many tokens and how much CPU/memory each one uses. Activity Monitor only shows a dozen anonymous `claude` processes.

## Goals
- A separate **Agent activity** window, opened from the popover, listing every running Claude Code and Codex agent on this Mac.
- Per agent: host app, project, session title, status (working / idle), CPU %, memory, uptime, model, session token usage (including subagents) and an **estimated API cost**.
- Inspector with token breakdown (input / output / cache read / cache write / thinking), per-model split, subagents, PID and full working directory.
- Zero cost while the window is closed.

## Non-goals
- Controlling agents (kill, pause, send messages). Headroom stays read-only.
- Billing-accurate cost. The estimate uses public API list prices; subscription plans aren't billed per token.
- Historical token reports, network or disk I/O.
- Agents other than Claude Code and Codex (Gemini CLI, Cursor agent, Copilot) → follow-up spec.
- An "N agents working" line in the popover (needs background polling) → follow-up.

## Decisions (2026-11-12)
| Topic | Decision |
|-------|----------|
| UI language | **English everywhere.** This window ships in English; the existing Spanish popover copy is translated in a separate follow-up PR. |
| Agents in v1 | Claude Code + Codex only. |
| Cost | Show an **estimated API-equivalent cost** (USD) per agent and in the summary, from a dated price table (§ Cost estimate). |

## Data sources (verified 2026-11-12, Claude Code 2.1.319–2.1.321, Codex CLI 0.157.0)

### Claude Code
- **Live registry:** `$CLAUDE_CONFIG_DIR` or `~/.claude` → `sessions/<pid>.json`, one file per running session, written for every entry point (desktop app, VS Code, CLI). Fields used: `pid`, `sessionId`, `cwd`, `startedAt` (epoch ms), `procStart` (process start, e.g. `Fri Nov 13 03:57:20 2026`), `version`, `kind`, `entrypoint` (`claude-desktop`, `claude-vscode`, `cli`, …), `name` (session title), `status` (`busy` / `idle`), `statusUpdatedAt`.
  - The same folder holds `<pid>.<hash>.key` files: secrets for each session's messaging socket. **Never opened.** `messagingSocketPath` is never used.
  - Files can outlive their process → an entry is valid only if the pid is alive **and** the process start time matches `procStart` (±2 s, read as UTC or local time) — this guards against PID reuse. Without a parseable `procStart`, `startedAt` must not precede the process start by more than 2 s.
- **Transcript:** `projects/*/<sessionId>.jsonl`. Locate it by `sessionId` across project folders; don't re-derive the folder-name encoding. Files up to 31 MB observed.
  - Each API response is written as **one line per content block**, and every one of those lines repeats the full `message.usage`. Totals must be de-duplicated by `message.id` (last line wins). Observed: 253 assistant lines → 93 responses; a naive sum overcounts ~2.7×.
  - Fields used: `type == "assistant"`, `message.id`, `message.model` (skip `<synthetic>`), `timestamp`, and `message.usage.{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}, output_tokens_details.thinking_tokens, server_tool_use.web_search_requests, speed, inference_geo}`.
  - `thinking_tokens` is a subset of `output_tokens` (display only, never added).
  - The `cost-state` line is a stale snapshot (written once per process start) → not used.
- **Subagents:** `projects/*/<sessionId>/subagents/agent-<id>.jsonl` (same line format, `isSidechain: true`, may use other models) + `agent-<id>.meta.json` → `agentType`, `description`. Their tokens and cost are added to the parent session and listed separately in the inspector.

### Codex
- **No live registry.** Running agents are processes whose executable is named `codex` (npm, Homebrew, IDE extension `app-server`, Codex app). The `node` wrapper of the npm install is not matched, so nothing is counted twice.
- **Rollouts:** `$CODEX_HOME` or `~/.codex` → `sessions/YYYY/MM/DD/rollout-*.jsonl` (folders use the local date).
  - `session_meta.payload.{id, timestamp, cwd, originator, source, cli_version}`. **Never decoded:** `creator_user_id`, `creator_account_id`, `base_instructions`.
  - `turn_context.payload.model` → current model.
  - `event_msg` with `payload.type == "token_count"` → `payload.info.total_token_usage.{input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens}` (cumulative: last non-null `info` wins) and `payload.info.model_context_window`. Observed `total_tokens == input_tokens + output_tokens`, so cached / cache-write tokens are subsets of input and reasoning is a subset of output.
  - Status: a `task_started` event after the last `task_complete` → working.
- **Process → rollout mapping:** rollout files the process holds open (libproc fd list). Fallback: rollouts modified after the process started whose `session_meta.cwd` equals the process cwd (scan the local-date folders from process start to today, at most 7 days). One process can host several sessions (IDE `app-server`). ⚠️ Not verified against a live Codex process yet (none was running) → AC10.

### Processes (both)
libproc only — no `ps`, no argv or environment reads:
- `proc_listallpids`, `proc_pidpath` (executable), `proc_pidinfo(PROC_PIDTBSDINFO)` (ppid, start time), `proc_pidinfo(PROC_PIDVNODEPATHINFO)` (cwd), `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` (open files, Codex only).
- `proc_pid_rusage(RUSAGE_INFO_V4)`: `ri_user_time + ri_system_time` (mach time units → ns via `mach_timebase_info`; two samples → CPU %), `ri_phys_footprint` → memory (the value Activity Monitor shows).
- CPU and memory include the agent's **descendant processes** (tool runs, MCP servers, shells). Aggregation stops at nested agents: a `codex` started by Claude Code is its own row and isn't counted twice. The inspector shows the agent-only vs children split.

## Cost estimate
Prices as of **2026-11-12**, USD per million tokens, from [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing) and [OpenAI pricing](https://developers.openai.com/api/docs/pricing). They live in one file (`Core/Agents/ModelPricing.swift`) with that date; updating them is a normal PR.

**Claude** (input · 5 m cache write · 1 h cache write · cache read · output):

| Model id | Input | 5m write | 1h write | Read | Output | Fast in / out |
|----------|------:|---------:|---------:|-----:|-------:|--------------:|
| `claude-fable-5-2`, `claude-mythos-5-2` | 8 | 10 | 16 | 0.20 | 40 | 16 / 80 |
| `claude-fable-5-1`, `claude-mythos-5-1` | 10 | 12.50 | 20 | 0.25 | 50 | — |
| `claude-fable-5` | 10 | 12.50 | 20 | 1.00 | 50 | — |
| `claude-opus-5-5` | 4 | 5 | 8 | 0.20 | 20 | 8 / 40 |
| `claude-opus-5`, `claude-opus-4-8` | 5 | 6.25 | 10 | 0.50 | 25 | 10 / 50 |
| `claude-opus-4-7`, `-4-6`, `-4-5` | 5 | 6.25 | 10 | 0.50 | 25 | — |
| `claude-opus-4-1`, `claude-opus-4` | 15 | 18.75 | 30 | 1.50 | 75 | — |
| `claude-sonnet-5-5` | 2 | 2.50 | 4 | 0.10 | 10 | — |
| `claude-sonnet-5` | 2 | 2.50 | 4 | 0.20 | 10 | — |
| `claude-sonnet-4-6`, `-4-5`, `claude-sonnet-4` | 3 | 3.75 | 6 | 0.30 | 15 | — |
| `claude-haiku-5-5` (prompt ≤ 100K) | 0.10 | 0.125 | 0.20 | 0.01 | 0.50 | — |
| `claude-haiku-5-5` (prompt > 100K) | 0.50 | 0.625 | 1 | 0.05 | 2.50 | — |
| `claude-haiku-4-5` | 1 | 1.25 | 2 | 0.10 | 5 | — |

Rules, applied **per API response** (de-duplicated message):
- Model ids are matched after stripping a date suffix (`-20251001`) and bracketed suffixes (`[1m]`).
- `speed == "fast"` → fast input/output prices; cache prices keep the model's multipliers on top of the fast input price (5 m write 1.25×, 1 h write 2×, read = model's read ratio).
- `inference_geo == "us"` on Claude 4.6+ models → ×1.1 on all token categories.
- Haiku 5.5: prompt = input + cache read + cache write tokens of that response; > 100,000 → the higher row for the whole response.
- Cache writes use the 5 m / 1 h split when present; otherwise all writes are priced as 5 m.
- Web search: $10 per 1,000 `web_search_requests`. Web fetch has no extra charge.

**OpenAI / Codex** (standard tier, input · cached input · output): `gpt-6-luna` 0.10 · 0.01 · 0.50 · `gpt-5.6-terra` 2.00 · 0.20 · 12.00 · `gpt-5.6-luna` 0.20 · 0.02 · 1.20 · `gpt-5.3-codex` 1.75 · 0.175 · 14.00. Cost = (input − cached) × input price + cached × cached price + output × output price, from the cumulative totals. Long-context rates (> 272K input per request) are not applied; observed Codex context windows (258,400) are below that threshold.

**Unknown models** (e.g. `gpt-reserve`, `codex-auto-review`) get no estimate. A session with some unpriced usage shows the known part with a `+` suffix ("$4.12+"); fully unpriced shows "—". The UI always labels the value **Est. cost** with a tooltip: "What these tokens would cost at API list prices (as of 2026-11-12). Subscriptions aren't billed per token."

## User experience

**Entry point.** The popover header gets a glass button (`waveform.path.ecg`, tooltip "Agent activity") next to refresh, and the `⋯` menu gets **Agent activity…**. It opens the window, or focuses it if already open, and activates the app so the window comes to the front. The window does not open at launch and is not restored on relaunch.

**Window** — standard resizable window (default 980×560, min 720×400), summary tiles with `.glassEffect`, a sortable `Table`, and an `.inspector` for the selected row:

```
┌ Agent activity ──────────────────────────────────────────── [◻ Working only] ┐
│ ╭ 11 agents ╮ ╭ 1 working ╮ ╭ CPU 23% ╮ ╭ Memory 1.6 GB ╮ ╭ Tokens 24.1M ╮ ╭ Est. $31.40 ╮ │
│                                                                               │
│  Agent            Project       Status     CPU   Memory  Uptime  Tokens  Est. │
│  ● Claude Code    ailimits      Working  19.7%   310 MB  2m       3.4M  $4.62 │
│    Desktop · Headroom agent activity spec · Opus 5.5                          │
│  ○ Claude Code    TMNA86        Idle 12m  0.1%   115 MB  2h 22m   812K  $1.10 │
│    VS Code · Fix login redirect · Opus 5.5                                    │
│  ○ Codex          sketch_nov9a  Idle      0.0%    41 MB  4d 2h     14K <$0.01 │
│    Exec · gpt-6-luna                                                          │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Inspector** (selected row):
```
Claude Code · Desktop                     ● Working
Headroom agent activity spec
~/Documents/apps/ailimits
PID 4742 · v2.1.321 · started today, 20:57

Tokens (session)               3.4M
  Input                        2.1K
  Output                       120K   (thinking 8.2K)
  Cache read                   3.1M
  Cache write                  198K
Est. cost                     $4.62   ⓘ
By model
  Opus 5.5                3.4M  $4.62
Subagents (2)
  Explore · Find usages of…   412K  $0.31  active 5s ago
  general-purpose              88K  $0.05  3h ago
Resources
  CPU     19.7%  (agent 12.1% · 3 children 7.6%)
  Memory  310 MB (agent 280 MB · children 30 MB)
```

- **One row per agent process.** Claude Code is one session per process. A Codex `app-server` with several sessions shows the most recently active session's project with a "+N" badge, and lists all its sessions in the inspector.
- **Sorting:** working first, then CPU descending. Every column is sortable. The **Working only** toggle hides idle agents.
- **Refresh while open:** processes every 2 s, registry and transcripts every 6 s (only files whose size or mtime changed). Everything stops when the window closes; parsed totals stay in memory so reopening is instant.
- **States:**
  - Empty: "No agents running. Start Claude Code or Codex and they'll show up here."
  - Loading: the Tokens and Est. cells show a spinner while a transcript's first scan runs.
  - Partial: process found but no session data → "—" with a tooltip ("Session data not found").
  - Read error on one agent → "—" plus tooltip; other rows unaffected.

## Design

| File | Contents |
|------|----------|
| `Core/Agents/AgentModels.swift` | `AgentKind`, `AgentHost`, `AgentStatus`, `TokenUsage`, `CostEstimate`, `AgentSession`, `AgentSubagent`, `AgentRow`, `AgentSummary` |
| `Core/Agents/AgentFormat.swift` | English formatters: compact tokens, uptime, cost, day/time, model display names |
| `Core/Agents/ModelPricing.swift` | Dated price table + `ClaudeCost` / `CodexCost` calculators |
| `Core/Agents/ProcessSampler.swift` | libproc wrapper → `ProcessSample`; pure `cpuPercent(previous:current:)` and subtree aggregation |
| `Core/Agents/JSONLTail.swift` | Incremental reader: byte offset + partial-line buffer, reset if the file shrinks or its inode changes; skips lines without a cheap marker substring before JSON decoding |
| `Core/Agents/AgentCollector.swift` | Actor: samples processes, maps them to sessions, keeps per-file accumulators |
| `Core/Store/AgentMonitor.swift` | `@MainActor @Observable`; `start()` / `stop()`; publishes `[AgentRow]` and `AgentSummary` |
| `Providers/Claude/ClaudeSessionRegistry.swift` | Pure `parse(_ data: Data)` + loader that lists only `*.json`, with an injectable file reader |
| `Providers/Claude/ClaudeTranscriptUsage.swift` | Accumulator: `[messageID: MessageUsage]`, last line wins; subagent meta |
| `Providers/Codex/CodexRolloutUsage.swift` | Accumulator for `session_meta`, `turn_context`, `token_count` and task events |
| `UI/Agents/AgentActivityWindow.swift`, `UI/Agents/AgentInspector.swift` | `Table` + `.inspector`, summary tiles |
| `App/HeadroomApp.swift` | `Window(…, id: "agents")` scene (`.defaultLaunchBehavior(.suppressed)`, `.restorationBehavior(.disabled)`); owns the `AgentMonitor` so caches survive closing the window |
| `UI/Popover/PopoverView.swift` | Entry button and menu item (`openWindow(id: "agents")` + `NSApp.activate()`) |

```swift
enum AgentKind: String, Sendable { case claudeCode, codex }
enum AgentHost: Sendable, Equatable { case desktop, vscode, cursor, jetbrains, cli, exec, appServer, sdk, other(String) }
enum AgentStatus: Sendable, Equatable { case working, idle(since: Date?), other(String), unknown }

struct TokenUsage: Sendable, Equatable {        // disjoint categories
    var input = 0, cacheRead = 0, cacheWrite = 0, output = 0
    var thinking = 0                            // subset of output, display only
    var total: Int { input + cacheRead + cacheWrite + output }
}

struct CostEstimate: Sendable, Equatable {
    var usd = 0.0
    var hasUnpricedUsage = false
}

struct AgentSession: Sendable, Identifiable {
    let id: String                 // provider session id: used for lookups, never displayed
    let kind: AgentKind, host: AgentHost
    let cwd: String, title: String?, version: String?
    let startedAt: Date?, lastActivity: Date?, status: AgentStatus
    let model: String?
    let tokens: TokenUsage, cost: CostEstimate
    let byModel: [String: ModelUsage]          // ModelUsage = (tokens, cost)
    let subagents: [AgentSubagent]
}

struct AgentRow: Sendable, Identifiable {     // one per agent process
    let pid: Int32, kind: AgentKind, startedAt: Date, executablePath: String
    let cpuPercent: Double, ownCPUPercent: Double
    let memoryBytes: UInt64, ownMemoryBytes: UInt64, childCount: Int
    let sessions: [AgentSession]               // Claude: 1; Codex app-server: 0…n
    var id: Int32 { pid }
}
```

- **Host mapping:** Claude `entrypoint` (`claude-desktop` → Desktop, `claude-vscode` → VS Code, `cli` → CLI, `sdk-*` → SDK), refined by executable path (`/.cursor/extensions/` → Cursor). Codex `originator` / `source` (`codex_exec` / `exec` → Exec, `codex_cli_rs` / `cli` → CLI, `vscode` → VS Code), refined by executable path. Unknown values are shown verbatim.
- **Concurrency:** libproc sampling and file parsing run in the `AgentCollector` actor off the main thread. `AgentMonitor` only receives value snapshots. The collector is behind a protocol so tests can inject a fake.
- **Rule from AGENTS.md holds:** `Core/` and `Providers/` don't import SwiftUI or AppKit (libproc is in `Darwin`).

### Security & privacy
- Transcripts and rollouts contain prompts, code and tool output. Decoders declare **only** the fields listed in *Data sources*. Raw lines are never stored, logged or written anywhere. Nothing from this feature is persisted to disk.
- Never open `~/.claude/sessions/*.key`. Never connect to `messagingSocketPath` or `~/.codex/ipc/ipc.sock`. Never decode Codex `creator_user_id` / `creator_account_id`.
- Never read other processes' argv or environment (they can contain prompts or keys). Only executable path, ppid, start time, cwd, open file paths (Codex agents only) and resource usage via libproc.
- No network requests (prices are a bundled table). No signals sent to any process.
- Session titles, working directories and subagent descriptions are displayed locally only.

## Acceptance criteria
- [ ] AC1 — "Agent activity" opens from the popover header button and from the `⋯` menu and appears in front; reopening focuses the existing window; it doesn't open at launch.
- [ ] AC2 — `ClaudeSessionRegistryTests`: fixture registry parses; an entry whose pid is dead or whose start time differs from `procStart` by > 2 s is dropped.
- [ ] AC3 — The registry loader never opens `*.key` files: with an injected file reader over a temp dir containing `123.json` and `123.<hash>.key`, the recorded paths contain no `.key`.
- [ ] AC4 — `ClaudeTranscriptUsageTests`: one response split over 3 block lines counts once; a later line with the same `message.id` replaces the earlier one; `<synthetic>` is skipped; subagent tokens are added to the session; per-model split is correct.
- [ ] AC5 — Incremental parsing: appending lines (including a partial last line completed by a later append) gives the same totals as a full parse; a truncated/replaced file resets the totals.
- [ ] AC6 — `CodexRolloutUsageTests`: last non-null `token_count` wins; model comes from the latest `turn_context`; status is working iff a `task_started` follows the last `task_complete`.
- [ ] AC7 — Privacy canary: fixture lines with `SECRET-CANARY` in prompt, tool output, Codex `base_instructions` and `creator_*` fields → the canary is absent from `String(reflecting:)` of every produced value.
- [ ] AC8 — `ProcessSamplerTests`: `cpuPercent` from two synthetic samples; subtree aggregation over a synthetic ppid table (deep tree, orphaned children, nested agent excluded).
- [ ] AC9 — `ModelPricingTests`: Opus 5.5 standard, fast, `inference_geo: "us"`, 1 h cache writes, Haiku 5.5 above/below 100K, web search, Codex cached subset, unknown model → `hasUnpricedUsage`.
- [ ] AC10 — With a live `codex` process (CLI, and IDE `app-server` if available), its session(s), model and tokens appear. The PR states whether the fd-based mapping or the cwd fallback was used.
- [ ] AC11 — Closing the window stops all sampling: `AgentMonitorTests` with a fake collector shows no collect calls after `stop()`.
- [ ] AC12 — On the maintainer's Mac (env-gated live test): every running Claude Code session (desktop + VS Code) is listed; token totals match a de-duplicated `jq` count of the same transcripts (command in the PR); CPU and memory are within ±10 % of Activity Monitor.
- [ ] AC13 — First scan of a 30 MB transcript finishes in < 1 s (Release build) off the main thread; incremental refreshes take < 20 ms.

## Test plan
- Unit: synthetic, anonymized fixtures `claude_session_registry.json`, `claude_transcript.jsonl`, `claude_subagent.jsonl`, `claude_subagent.meta.json`, `codex_rollout.jsonl` covering AC2–AC9 and AC11.
- Live (opt-in, `TEST_RUNNER_HEADROOM_LIVE_TESTS=1`): AC12, AC13 against the real `~/.claude` / `~/.codex`; prints a summary without session ids or content.
- Manual: AC1, AC10, and a visual check of the window by the maintainer.
- Security: run the `security-reviewer` subagent (touches `Providers/` and credential-adjacent folders).

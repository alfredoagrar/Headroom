---
id: 004
title: Codex session-log fallback
status: draft
owner: "@alfredoagrar"
created: 2026-09-25
depends-on: [001]
---

# 004 · Codex session-log fallback

## Problem
When `wham/usage` fails (expired token, network, endpoint change) the Codex card only shows an error, even though Codex CLI already wrote recent rate-limit data to disk.

## Goals
- On any Codex fetch failure except `.notConfigured`, read the latest `rate_limits` event from the session logs and show it, marked as coming from logs.

## Non-goals
- Replacing the live endpoint as the primary source.
- Parsing anything from logs other than `rate_limits`.

## User experience
Card shows the log-derived windows plus a caption: *"From Codex logs · 14 min ago"*. If the log data's reset time has already passed, that window is hidden (it's no longer meaningful).

## Design
- `CodexSessionLogReader` in `Providers/Codex/`: find newest `*.jsonl` under `$CODEX_HOME/sessions` (or `~/.codex/sessions`) by modification date; scan **from the end** for the last line containing `"rate_limits"`; decode `payload.rate_limits.{primary, secondary}` → `used_percent`, `window_minutes`, `resets_at` (epoch s), `plan_type`.
- Pure parser `CodexSessionLogParser.parse(line:now:)` for tests; file I/O kept separate.
- Read at most the last 256 KB of the file.
- `UsageSnapshot` gains `source: SnapshotSource` (`.live` | `.localLogs(Date)`), default `.live` when decoding old caches.

Log line shape observed in Phase 0:
```json
{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":13.0,"window_minutes":300,"resets_at":1777159561},"secondary":{"used_percent":8.0,"window_minutes":10080,"resets_at":1777706470},"plan_type":"plus"}}}
```

### Security & privacy
Reads local files under `~/.codex/sessions` only; nothing but the `rate_limits` object is decoded or retained. Session logs may contain prompts — the reader must never log or cache raw lines.

## Acceptance criteria
- [ ] AC1 — Parser test with the line above → Session (5h) 13 %, Weekly 8 %, plan "Plus".
- [ ] AC2 — Windows whose `resets_at` is in the past are dropped.
- [ ] AC3 — Live 401 + valid logs → card shows log data with the "From Codex logs" caption.
- [ ] AC4 — Old `snapshots.json` without `source` still decodes (`.live`).
- [ ] AC5 — A 50 MB log file is handled in < 50 ms (tail read).

## Test plan
- Unit: parser, stale-window filtering, cache backward compatibility.
- Manual: rename `~/.codex/auth.json` temporarily → card falls back to logs.

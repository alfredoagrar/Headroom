---
id: 001
title: MVP menu bar app
status: implemented
owner: "@alfredoagrar"
created: 2026-09-25
depends-on: []
---

# 001 · MVP menu bar app

## Problem
Checking Claude and Codex usage means opening two different websites/apps. I want one click in the menu bar.

## Goals
- Menu bar icon that reflects the most critical limit.
- Glass popover with one card per provider, one bar per limit window, countdown to reset.
- Auto-detect existing Claude Code and Codex CLI sessions.

## Non-goals
- Settings UI, notifications, launch at login (→ 003).
- Refreshing other apps' tokens.

## Design
See [000 §3 and §5](000-product.md). Key types: `UsageProvider`, `UsageSnapshot`, `LimitWindow`, `UsageStore`.

### Security & privacy
Reads Claude Code's Keychain item via `/usr/bin/security` and `~/.codex/auth.json`, read-only. Tokens sent only to `api.anthropic.com` / `chatgpt.com`. Snapshots (no tokens) cached in `~/Library/Application Support/Headroom/snapshots.json`.

## Acceptance criteria
- [x] AC1 — App runs without a Dock icon; icon appears in the menu bar.
- [x] AC2 — Claude windows parsed from `limits[]`, with legacy fallback (`ClaudeParsingTests`).
- [x] AC3 — Codex window labels derived from `limit_window_seconds` (`CodexParsingTests`).
- [x] AC4 — Empty Keychain token → "not configured" hint, not a crash (`ignoresEmptyKeychainTokens`).
- [x] AC5 — Failed refresh keeps last good snapshot and shows the error as stale.
- [x] AC6 — Popover shows live data for both providers on the maintainer's Mac.

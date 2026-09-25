---
id: 000
title: Headroom — product & architecture
status: living
updated: 2026-09-25
---

# Headroom — Product & Architecture

> *How much room you have left before you hit the limit.*

Native macOS menu bar app that shows, in a **Liquid Glass** popover, how much is left of your AI subscription usage limits (Claude, Codex/ChatGPT, …): the short window (session) and the long ones (weekly / monthly), with countdowns and exact reset dates.

This is the **living** top-level spec. Feature work is specified in `specs/NNN-*.md` (see [specs/README.md](README.md)); when a feature changes something described here, update this file in the same PR.

---

## 1. Goals

| # | Goal | Success metric |
|---|------|----------------|
| G1 | See all my limits with **one click** | Popover opens in < 150 ms from cached data |
| G2 | Connect several subscriptions without copying tokens | Auto-detect Claude Code and Codex CLI sessions |
| G3 | Know **when** each limit resets | Countdown **and** absolute date per window |
| G4 | Unobtrusive | < 30 MB RAM, no Dock icon, cheap background refresh |
| G5 | Secure | Tokens never leave the Mac except to the provider; no own servers, no telemetry |

### Non-goals (v1)
- API cost tracking in USD per token.
- Sync between Macs.
- iOS / Windows.

---

## 2. Key concept: limit windows

Providers don't really use "daily" limits. What they expose:

| Provider | Short window | Long window | Extra |
|----------|--------------|-------------|-------|
| Claude (Pro/Max) | **5 hours** (rolling session) | **7 days** (all models) | 7-day per-model (Opus/Sonnet) on some plans, extra-usage credits |
| Codex (ChatGPT Plus/Pro) | **5 hours** (`primary_window`) | **weekly** (`secondary_window`) | Credits |
| Codex (ChatGPT Free) | — | **30 days** (`primary_window`) | — |
| Gemini / Cursor / Copilot | Varies (requests/day, requests/month) | — | Phase 3 |

So the model is generic: **a provider exposes N limit windows**, each with `usedPercent` + `resetsAt`. Window kind and label are **derived from the window duration**, never assumed per provider (Codex Free proved plans change durations).

---

## 3. Data sources per provider

> ⚠️ These endpoints are **internal / undocumented** (used by the official apps and community tools such as CodexBar). They can change without notice → every provider must fail gracefully, keep the last good snapshot, and be covered by fixture tests.

### 3.1 Claude
- **Credential:** Keychain item `Claude Code-credentials` (read via `/usr/bin/security`, which is already in the item's ACL → no prompt per ad-hoc build) → `claudeAiOauth.{accessToken, expiresAt (ms), subscriptionType, rateLimitTier}`. Fallback file `~/.claude/.credentials.json`.
  - Empty tokens are treated as "not configured" (seen when Claude Code only runs inside the desktop app).
  - Access token lives **~1 h**; Claude Code refreshes it. Headroom does **not** refresh (refresh tokens rotate; refreshing would log Claude Code out) → shows "Session expired. Open Claude Code to renew it."
- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer …`, `anthropic-beta: oauth-2025-04-20`.
- **Response:** prefer normalized `limits[]` (`kind`, `group`, `percent`, `resets_at`, `severity`); fall back to `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet`. Details: `extra_usage` (credits, minor units) and `seven_day_breakdown.rows[]`.

### 3.2 Codex
- **Credential:** `$CODEX_HOME/auth.json` or `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id`. Expiry read from the JWT `exp`.
- **Endpoint:** `GET https://chatgpt.com/backend-api/wham/usage`, headers `Authorization: Bearer …`, `ChatGPT-Account-Id`.
- **Response:** `plan_type`, `rate_limit.{primary_window, secondary_window}` → `used_percent`, `limit_window_seconds`, `reset_at` (epoch s) / `reset_after_seconds`; `code_review_rate_limit`; `credits`.
- **Offline fallback (planned, spec 004):** last `rate_limits` event in `~/.codex/sessions/**/*.jsonl`.

### 3.3 Future providers (Phase 3)
| Provider | Likely source |
|----------|---------------|
| Gemini CLI | `~/.gemini/oauth_creds.json` + Google quota API |
| Cursor | Session cookie → `cursor.com/api/usage` |
| GitHub Copilot | `gh auth token` → `api.github.com/copilot_internal/user` |

Use the `add-provider` skill (`.claude/skills/add-provider`) to add one.

---

## 4. User experience

### 4.1 Menu bar icon
- **Icon only** (decision). SF Symbol `gauge.with.dots.needle.{0,33,50,67,100}percent`; the needle follows the most critical window.
- Optional "show % in menu bar" setting, off by default (spec 003).

### 4.2 Popover (Liquid Glass)
```
╭──────────────────────────────────────────╮
│  Headroom                        ⟳  ⋯    │
│  ┌ ✦ Claude  Pro ─────────────────── › ┐ │
│  │ Session (5h)          17%   1h 18m  │ │
│  │ ███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │ │
│  │ 📅 Resets today, 12:29              │ │
│  │ Weekly                 3%   6d 0h   │ │
│  │ █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │ │
│  │ 📅 Resets Thu Oct 1, 12:59          │ │
│  └─────────────────────────────────────┘ │
│  ┌ </> Codex  Free ────────────────────┐ │
│  │ Monthly                0%  30d 0h   │ │
│  └─────────────────────────────────────┘ │
│  Updated 1 min ago                       │
╰──────────────────────────────────────────╯
```
- `GlassEffectContainer` + cards with `.glassEffect(.regular.tint(providerTint), in: .rect(cornerRadius: 16))`.
- Bars use the provider tint; yellow ≥ 75 %, red ≥ 90 %.
- Every window shows countdown + absolute reset date ("today, 12:29" / "tomorrow, 09:05" / "Thu Oct 1, 12:59", year added if different). Hover shows the full timestamp.
- Tap a card → expands details (extra credits, weekly breakdown).
- States: loading (redacted placeholder row), error (message; last good data kept and marked stale), not configured (hint with the CLI login command).
- ⚠️ UI copy is currently **Spanish** (predates the English-only decision). Localization is tracked as an open question (§9).

### 4.3 Settings (spec 003, planned)
- **Accounts:** provider list, status, enable/disable, reorder.
- **General:** launch at login, refresh interval (1 / 2 / 5 / 15 min), show % in menu bar.
- **Notifications:** crossing 75 % / 90 %, window reset after being > 90 %.

---

## 5. Architecture

### 5.1 Stack
| Decision | Choice | Why |
|----------|--------|-----|
| Language / UI | Swift 6 (strict concurrency) + SwiftUI | Native, first-class Liquid Glass |
| Target | **macOS 26+** | `glassEffect` is 26-only |
| Menu bar | `MenuBarExtra` + `.menuBarExtraStyle(.window)` | Pure SwiftUI popover |
| No Dock icon | `LSUIElement = YES` | Lives in the menu bar only |
| Networking | `URLSession` async/await, 10 s timeout | No dependencies |
| Persistence | JSON snapshot cache in Application Support; `UserDefaults` for settings | Simple |
| Project | **XcodeGen** (`project.yml`); `.xcodeproj` is generated and git-ignored | Diff-friendly |
| Tests | Swift Testing, fixture-based, hostless (test target compiles `Core` + `Providers`) | Fast, no app launch |
| Dependencies | **Zero** | — |

### 5.2 Layers
```
UI (SwiftUI)         MenuBarLabel · PopoverView · ProviderCard · LimitRow · LimitBar
        │ @Observable
UsageStore           entries per provider · refresh loop · snapshot cache
        │ protocol UsageProvider
Providers            ClaudeProvider · CodexProvider · (Gemini, Cursor, Copilot)
        │
Core                 HTTPClient · KeychainCLI · JWT · ISODate · ResetFormatter · models
```
Rule: `Core` and `Providers` must not import SwiftUI (they are compiled into the test target).

### 5.3 Data model (as built)
```swift
enum ProviderID: String, Codable, CaseIterable, Sendable { case claude, codex }
enum WindowKind: String, Codable, Sendable { case session, daily, weekly, monthly, other }  // init(seconds:)

struct LimitWindow: Codable, Identifiable, Hashable, Sendable {
    let id: String; let kind: WindowKind; let label: String
    let usedPercent: Double; let resetsAt: Date?
}
struct DetailRow: Codable, Hashable, Sendable { let label: String; let value: String }
struct UsageSnapshot: Codable, Sendable {
    let provider: ProviderID; let planName: String?
    let windows: [LimitWindow]; let details: [DetailRow]; let fetchedAt: Date
}
enum ProviderError: Error, Equatable, Sendable {
    case notConfigured(hint: String), expired(hint: String), unauthorized, rateLimited
    case http(Int), network(String), decoding(String)
}
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetchUsage() async throws(ProviderError) -> UsageSnapshot
}
```
Parsers are pure (`XUsageParser.parse(_ data:, now:)`) so they can be tested against fixtures.

### 5.4 Refresh
- Loop every 2 min + refresh on popover open if data is > 60 s old.
- Providers fetched in parallel (`TaskGroup`).
- On failure keep the last good snapshot and show the error as "stale".
- Planned (spec 003): exponential backoff on 429/5xx (max 15 min), pause on sleep.

### 5.5 Security & privacy
- Credentials of other apps are **read-only**; never written or refreshed.
- Tokens are only sent to the provider's own domain; never logged, never cached to disk (only snapshots are).
- Not sandboxed (needs `~/.codex` and another app's Keychain item). Direct distribution; ad-hoc signed until an Apple Developer account exists, then Developer ID + notarization.
- Fixtures must be anonymized (no emails, account/user ids, tokens).

---

## 6. Repository layout
```
├── AGENTS.md / CLAUDE.md        # AI agent instructions
├── specs/                       # spec-driven development (this file + NNN-*.md)
├── .claude/skills, agents       # AI workflows (write-spec, implement-spec, add-provider, release)
├── .github/                     # CI, CodeQL, release, dependabot, CODEOWNERS
├── project.yml                  # XcodeGen
├── Headroom/
│   ├── App/                     # HeadroomApp (@main), Info.plist
│   ├── Core/{Models,Store,Networking,Credentials}
│   ├── Providers/{Claude,Codex}
│   └── UI/{MenuBar,Popover,Theme}
├── HeadroomTests/               # Swift Testing + Fixtures/*.json
└── Scripts/probe_*.sh           # manual endpoint probes (Phase 0)
```

---

## 7. Roadmap

| Phase | Deliverable | Status | Spec |
|-------|-------------|--------|------|
| 0 · Validation | Probe scripts + anonymized fixtures | ✅ Done | — |
| 1 · MVP | Menu bar + glass popover + Claude & Codex + refresh | ✅ Done | [001](001-mvp-menu-bar.md) |
| 1.1 | Absolute reset dates | ✅ Done | [002](002-reset-dates.md) |
| 2 · Polish | Settings, notifications, login item, backoff, Codex log fallback | 📝 Draft | [003](003-settings-and-alerts.md), [004](004-codex-log-fallback.md) |
| 3 · Providers | Gemini → Cursor → Copilot | ⏳ | via `add-provider` |
| 4 · Distribution | Developer ID, notarization, DMG, Sparkle | ⏳ Blocked (no Apple Developer account) | — |

---

## 8. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Internal endpoints change | Provider breaks | Tolerant parsing, fixture tests, fallbacks, clear UI error |
| Claude token expires while Claude Code is closed | Stale data | "Session expired" hint; last good data kept |
| Terms of service | Undocumented API use | Read only your own data, low frequency (≥ 1 min) |
| Liquid Glass is macOS 26-only | Smaller audience | Accepted for v1 |

---

## 9. Decisions & open questions

| Topic | Decision |
|-------|----------|
| Menu bar | Icon only |
| Extra providers | Gemini, Cursor, Copilot |
| Name | **Headroom** — `com.alfredo.headroom` |
| Signing | Ad-hoc until an Apple Developer account exists |
| Token refresh | Never refresh other apps' tokens |
| Language | Code, docs, commits in English (from 2026-09-25) |

**Open:** in-app UI copy language (currently Spanish) — translate to English, or localize (en + es)?

### Phase 0 findings (2026-09-25)
- Claude: `Claude Code-credentials*` items had **empty** tokens until `claude auth login`; then HTTP 200 with `limits[]`, `extra_usage`, `seven_day_breakdown`. Token TTL ~1 h.
- Codex: expired token → 401 "Could not parse your authentication token"; after `codex login` HTTP 200. Free plan = single 30-day `primary_window`, `secondary_window: null`.
- Codex session logs contain `rate_limits` (`window_minutes` 300 / 10080) — usable as offline fallback.

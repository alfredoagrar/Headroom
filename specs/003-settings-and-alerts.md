---
id: 003
title: Settings, notifications & resilience
status: draft
owner: "@alfredoagrar"
created: 2026-09-25
depends-on: [001]
---

# 003 · Settings, notifications & resilience

## Problem
The MVP has no way to change behavior, doesn't warn before hitting a limit, doesn't start at login, and retries a rate-limited provider every 2 minutes.

## Goals
- Settings window (General, Accounts, Notifications).
- Local notifications when a window crosses 75 % / 90 %, and when a window that was ≥ 90 % resets.
- Launch at login.
- Exponential backoff for 429/5xx; pause refresh while the Mac sleeps.

## Non-goals
- New providers (Phase 3).
- Custom thresholds per provider (single global pair for now).

## User experience
- Popover `⋯` menu gains **Settings…** (`⌘,`) above **Quit**.
- **General:** Launch at login (toggle) · Refresh every [1 | 2 | 5 | 15] min · Show % in menu bar (off by default; text of most critical window next to icon).
- **Accounts:** one row per provider: status (✅ connected / ⚠️ expired / ➕ not configured with the login command), enable toggle. Disabled providers are neither fetched nor shown.
- **Notifications:** toggles for "Warning at 75 %", "Critical at 90 %", "Limit reset". First enable triggers the system permission prompt.
- Notification copy example: *"Claude · Session (5h) at 91 % — resets today, 12:29"*.

## Design
- `AppSettings` (`@Observable`, backed by `UserDefaults`) in `Core/Store/`, injected into `UsageStore`.
- `ThresholdNotifier` in `Core/Notifications/`: pure function `events(previous:current:thresholds:) -> [ThresholdEvent]` + thin `UNUserNotificationCenter` wrapper. Fires once per (provider, window id, threshold, reset cycle); state persisted with the snapshot cache so relaunches don't re-notify.
- Launch at login via `SMAppService.mainApp`.
- Backoff: per provider, on `.rateLimited` / `.http(5xx)` delay = min(interval × 2ⁿ, 15 min); reset on success. Observe `NSWorkspace.willSleepNotification` / `didWakeNotification`; refresh on wake.
- `Settings` scene in `HeadroomApp`; open from the popover via `openSettings` environment action and `NSApp.activate()`.

### Security & privacy
No new credentials or network destinations. Notification text contains only provider name, window label, percent and reset time.

## Acceptance criteria
- [ ] AC1 — Changing refresh interval takes effect without relaunch.
- [ ] AC2 — Disabling a provider hides its card and stops its requests.
- [ ] AC3 — `ThresholdNotifier.events` unit tests: crossing 75 → one warning; 75→80 → none; 89→91 → one critical; reset after ≥ 90 → one "reset" event; same state twice → none.
- [ ] AC4 — Backoff unit tests: consecutive 429s double the delay up to 15 min; success resets it.
- [ ] AC5 — Launch-at-login toggle reflects `SMAppService.mainApp.status` after relaunch.
- [ ] AC6 — "Show % in menu bar" renders e.g. `72%` next to the icon when on; icon only when off.
- [ ] AC7 — Settings opens from the popover and via `⌘,` while the popover is focused.

## Test plan
- Unit: `ThresholdNotifierTests`, `BackoffTests`, `AppSettingsTests` (UserDefaults suite).
- Manual: toggle each setting; force a notification by temporarily lowering thresholds in a debug build.

## Open questions
- Should the "show %" text be colored by severity (menu bar text is usually monochrome)?

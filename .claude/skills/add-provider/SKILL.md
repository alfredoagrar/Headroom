---
name: add-provider
description: Add a new usage-limit provider to Headroom (e.g. Gemini, Cursor, GitHub Copilot) — probe the endpoint, capture an anonymized fixture, write the spec, parser, provider, tests and theme. Use when the user asks to support a new AI subscription.
---

# Add a provider

Providers are the riskiest part of Headroom: undocumented endpoints and other apps' credentials. Validate against reality before writing UI.

## 1. Research (no code yet)
- Where does the official CLI/app store its session? (file path, Keychain service name, cookie). Prefer an existing local login over asking the user for tokens.
- Which endpoint returns limits, and which headers does it need?
- Record findings in a new spec via `write-spec` (`specs/NNN-<provider>-provider.md`), including the credential source, endpoint, response shape and security notes.

## 2. Probe (Phase 0 style)
Create `Scripts/probe_<provider>.sh` modeled on `Scripts/probe_codex.sh`:
- `set -euo pipefail`, never `echo` tokens.
- Save the response to `HeadroomTests/Fixtures/<provider>_usage.json`, anonymizing with the `jq walk(...)` filter (emails, user/account/org ids → `"REDACTED"`).
- Must pass `shellcheck`.
Ask the user to run it (it touches their credentials) and review the fixture for personal data before committing.

## 3. Implement
Branch `feature/NNN-<provider>-provider` from `dev`.

| File | What |
|------|------|
| `Core/Models/Usage.swift` | add `case <provider>` to `ProviderID` + `displayName` |
| `Providers/<Name>/<Name>Provider.swift` | `<Name>Credentials` (read-only loader), `<Name>Provider: UsageProvider`, `<Name>UsageParser.parse(_:now:)` |
| `UI/Theme/ProviderTheme.swift` | `tint` + SF Symbol |
| `Core/Store/UsageStore.swift` | register in `UsageStore.live()` |
| `HeadroomTests/<Name>ParsingTests.swift` | fixture test + edge cases (missing windows, nulls, expired token) |

Rules:
- Throw `.notConfigured(hint:)` with the exact CLI login command when no credential exists; map 401/403 to `.expired(hint:)`.
- Derive window kind/label with `WindowKind(seconds:)` / `WindowKind.label(seconds:)`; per-request quotas (e.g. "300 requests/month") → compute `usedPercent`, put raw counts in `details`.
- Tolerant decoding: every field optional unless the feature can't work without it.
- Never refresh or write the other app's credentials.

## 4. Verify & ship
Follow steps 4–6 of the `implement-spec` skill, and always run the `security-reviewer` subagent.

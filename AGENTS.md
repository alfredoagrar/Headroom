# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Copilot, Cursor, …) working on **Headroom**, a macOS 26+ menu bar app that shows AI subscription usage limits.

## Read first
1. [specs/000-product.md](specs/000-product.md) — product, architecture, data model, security rules.
2. The spec you are implementing in `specs/NNN-*.md`. **No spec, no feature**: if the task is non-trivial and has no spec, write one first (template: `specs/_template.md`).

## Language
Everything in **English**: code, comments, docs, commit messages, PR descriptions. Exception: in-app UI copy is currently Spanish — don't translate it unless a spec says so.

## Workflow (gitflow)
- Never commit to `main` or `dev` directly (rulesets block it anyway).
- Branch from `dev`: `feature/NNN-short-name`, `fix/…`, `docs/…`, `chore/…`, `refactor/…`, `test/…`, `ci/…`.
- Only `release/x.y.z` and `hotfix/x.y.z` target `main`.
- One spec (or one fix) per PR. PR body links the spec and ticks its acceptance criteria.
- Conventional-ish commit subjects: `feat: …`, `fix: …`, `docs: …`, `test: …`, `ci: …`, `chore: …`.

## Commands
```bash
xcodegen generate                                           # after adding/removing files or editing project.yml
xcodebuild -project Headroom.xcodeproj -scheme Headroom -destination 'platform=macOS' test
xcodebuild -project Headroom.xcodeproj -scheme Headroom build
open ~/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app   # pkill -x Headroom first
shellcheck Scripts/*.sh && actionlint
```
- Never pass `-derivedDataPath` inside the repo: `~/Documents` is iCloud-synced and `codesign` fails on extended attributes.
- The `.xcodeproj` is generated and git-ignored — edit `project.yml`, not the project.

## Code conventions
- Swift 6 strict concurrency; no warnings allowed. UI state is `@MainActor @Observable`.
- `Core/` and `Providers/` **must not import SwiftUI/AppKit** — they are compiled into the hostless test target.
- Providers throw typed `ProviderError`; parsers are pure `static func parse(_ data: Data, now: Date = .now)` so they're testable with fixtures.
- Window kind/label come from the window duration (`WindowKind(seconds:)`), never hard-coded per plan.
- Zero third-party dependencies unless a spec justifies one.
- Match existing comment density: comment *why*, not *what*.

## Tests
- Swift Testing (`@Test`, `#expect`) in `HeadroomTests/`.
- Every parser change needs a fixture test. Fixtures live in `HeadroomTests/Fixtures/*.json`.

## Security rules (non-negotiable)
- Other apps' credentials are **read-only**. Never write, refresh or rotate Claude Code / Codex tokens.
- Never print, log, cache or commit tokens, cookies, emails or account ids. Anonymize fixtures (`REDACTED`).
- Don't read credential files (`~/.codex/auth.json`, Keychain items) yourself during development — use `Scripts/probe_*.sh`, which never print secrets.
- Network requests only to the provider's own domain.
- Workflows: keep `permissions:` least-privilege, pin actions to full commit SHAs, pass untrusted inputs (`github.head_ref`, PR titles, …) via `env:` — never interpolate them into `run:`. Never use `pull_request_target`.

## Definition of done
- [ ] Acceptance criteria of the spec are met and ticked in the PR.
- [ ] `xcodebuild … test` passes locally with zero warnings.
- [ ] Spec `status` updated; `specs/000-product.md` updated if architecture/UX changed; `specs/README.md` index updated.
- [ ] No secrets or personal data in the diff.

---
name: implement-spec
description: Implement an approved Headroom spec end to end — branch, code, tests, build, docs, PR into dev. Use when the user says "implement spec NNN", "build 003", or asks to develop a feature that already has a spec.
---

# Implement a spec

## 0. Preconditions
- Read `AGENTS.md`, `specs/000-product.md` and `specs/NNN-*.md`.
- If the spec is `draft` with blocking open questions, ask the user before coding. If the spec doesn't exist, use the `write-spec` skill first.

## 1. Branch
```bash
git switch dev && git pull --ff-only
git switch -c feature/NNN-short-name
```

## 2. Plan
List the acceptance criteria and map each to a test or check. Implement in small commits (`feat:`, `test:`, `refactor:`).

## 3. Code
- Tests first for pure logic (parsers, formatters, state machines) using Swift Testing.
- New files → run `xcodegen generate`.
- Keep `Core/` and `Providers/` free of SwiftUI/AppKit.
- Zero warnings under Swift 6 strict concurrency.

## 4. Verify
```bash
xcodebuild -project Headroom.xcodeproj -scheme Headroom -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning: |✘|Test run with|TEST (SUCCEEDED|FAILED)"
xcodebuild -project Headroom.xcodeproj -scheme Headroom build 2>&1 | grep -E "error:|warning: |BUILD"
pkill -x Headroom; open ~/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app
```
For UI changes, ask the user to check the popover (screenshots usually aren't available). If the diff touches credentials, networking, providers, scripts or workflows, run the `security-reviewer` subagent and address its findings.

## 5. Docs
- Tick acceptance criteria in the spec, set `status: implemented`.
- Update `specs/README.md` index and `specs/000-product.md` if architecture, data model or UX changed.

## 6. PR
Push and open a PR into `dev`:
- Title: `feat: <spec title> (spec NNN)`
- Body: link to the spec, checklist of acceptance criteria with how each was verified, anything left for follow-up.

Never merge the PR yourself unless the user asks.

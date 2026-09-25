# Specs

Headroom uses **spec-driven development**: every non-trivial change starts as a spec, gets reviewed, and is then implemented (by a human or an AI agent) against its acceptance criteria.

| File | Purpose |
|------|---------|
| [000-product.md](000-product.md) | Living product & architecture spec. Always reflects `main`/`dev`. |
| `NNN-short-name.md` | One feature / change. Numbered sequentially. |
| [_template.md](_template.md) | Copy this to start a new spec. |

## Lifecycle

```
draft ──review──▶ approved ──implement──▶ implemented
   └──────────────▶ rejected / superseded
```

1. **Draft** — `write-spec` skill (or by hand) on a `docs/NNN-name` branch → PR into `dev`.
2. **Approved** — maintainer merges the spec PR (or sets `status: approved` in the implementation PR when the change is small).
3. **Implement** — `implement-spec` skill on `feature/NNN-name`; the PR links the spec and ticks every acceptance criterion.
4. **Implemented** — same PR sets `status: implemented` and updates `000-product.md` if architecture/UX changed.

## Rules
- Acceptance criteria must be **testable** (a unit test, a command, or a concrete manual check).
- Specs describe *what* and *why*; keep *how* to the parts that constrain design (data model, APIs, security).
- One spec per PR. Don't edit an `implemented` spec — write a new one that supersedes it.

## Index

| # | Title | Status |
|---|-------|--------|
| 001 | [MVP menu bar app](001-mvp-menu-bar.md) | implemented |
| 002 | [Absolute reset dates](002-reset-dates.md) | implemented |
| 003 | [Settings, notifications & resilience](003-settings-and-alerts.md) | draft |
| 004 | [Codex session-log fallback](004-codex-log-fallback.md) | draft |

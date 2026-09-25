---
name: write-spec
description: Draft a new Headroom feature spec (specs/NNN-name.md) from an idea, bug or request. Use when the user describes a feature, change or provider to add and no approved spec exists yet.
---

# Write a spec

1. **Context.** Read `specs/000-product.md`, `specs/README.md` (index + lifecycle) and any spec this one depends on. Skim the code the change touches so the Design section is grounded in real types and files.
2. **Number.** Next free `NNN` from the index in `specs/README.md`.
3. **Branch.** `git switch dev && git pull && git switch -c docs/NNN-short-name`.
4. **Draft.** Copy `specs/_template.md` → `specs/NNN-short-name.md`. Fill every section:
   - *Problem / Goals / Non-goals*: short and concrete.
   - *User experience*: include empty, loading, error states; ASCII mockup if UI changes.
   - *Design*: only constraints (types, files, endpoints, persistence, concurrency). Respect the rules in `AGENTS.md` (Core has no SwiftUI, pure parsers, typed `ProviderError`).
   - *Security & privacy*: never delete; write "None" if nothing applies.
   - *Acceptance criteria*: each one testable (unit test name, command, or concrete manual check).
5. **Ask, don't guess.** Put unresolved product decisions under *Open questions* and ask the user about the ones that block design.
6. **Index.** Add the row to `specs/README.md` (status `draft`).
7. **PR.** Commit `docs: spec NNN short name`, push, open PR into `dev` titled `docs: spec NNN – <title>`. Body: summary + open questions.

Don't write implementation code in this skill.

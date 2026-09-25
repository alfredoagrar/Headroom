# Contributing

## Branching (gitflow)

| Branch | Purpose | Branches from | Merges into |
|--------|---------|---------------|-------------|
| `main` | Released code. Every commit is a release. | — | — |
| `dev` | Integration branch; default target for PRs. | `main` | `release/*` |
| `feature/*`, `fix/*`, `chore/*`, `docs/*`, `refactor/*`, `test/*`, `ci/*` | Day-to-day work | `dev` | `dev` (squash) |
| `release/x.y.z` | Stabilize a release | `dev` | `main` (merge) + back into `dev` |
| `hotfix/x.y.z` | Urgent fix on a release | `main` | `main` (merge) + back into `dev` |

`main` and `dev` are protected: no direct pushes, no force pushes, no deletion. Every change lands through a PR that passes **Branch policy**, **Lint** and **Build & Test**. The *Branch policy* check rejects PRs whose source/target combination breaks the table above.

## Releasing
1. `git switch dev && git switch -c release/0.2.0`, bump what's needed, open PR → `main`.
2. After merge: `git tag v0.2.0 origin/main && git push origin v0.2.0` (admins only).
3. The **Release** workflow tests, builds and publishes `Headroom-0.2.0.zip` to GitHub Releases.
4. Open a PR `main` → `dev` to back-merge.

## Local setup
```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Headroom test
```

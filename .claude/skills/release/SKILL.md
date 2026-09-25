---
name: release
description: Cut a Headroom release following gitflow — release branch from dev, PR into main, tag vX.Y.Z to trigger the Release workflow, back-merge into dev. Use when the user asks to release, ship a version, or publish a build. Also covers hotfixes.
---

# Release

Only the maintainer (repo admin) can push `v*` tags. Confirm the version number with the user first (semver: features → minor, fixes → patch).

## Release
```bash
git switch dev && git pull --ff-only
git switch -c release/X.Y.Z
```
1. Set `MARKETING_VERSION: "X.Y.Z"` in `project.yml`.
2. Make sure every spec merged since the last release is `implemented` and `specs/000-product.md` roadmap is current.
3. Commit `chore: release X.Y.Z`, push, open PR `release/X.Y.Z` → `main` titled `Release X.Y.Z`. Body: list of merged PRs/specs since the last tag (`git log --oneline vPREV..HEAD`).
4. After the user merges it:
   ```bash
   git switch main && git pull --ff-only
   git tag -a vX.Y.Z -m "Headroom X.Y.Z" && git push origin vX.Y.Z
   ```
5. Watch the **Release** workflow (`gh run watch`); confirm the GitHub release has `Headroom-X.Y.Z.zip` + `.sha256`.
6. Back-merge: PR `main` → `dev` titled `chore: back-merge X.Y.Z`.

## Hotfix
Same flow but branch `hotfix/X.Y.Z` from `main`, bump the patch version, PR into `main`, tag, then back-merge into `dev`.

## Notes
- Builds are ad-hoc signed (no Apple Developer account yet): users must right-click → Open the first time. Mention it in release notes.
- Never force-push or delete tags; if a release is broken, ship a new patch.

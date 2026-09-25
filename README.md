# Headroom

[![CI](https://github.com/alfredoagrar/Headroom/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/alfredoagrar/Headroom/actions/workflows/ci.yml)
[![CodeQL](https://github.com/alfredoagrar/Headroom/actions/workflows/codeql.yml/badge.svg?branch=dev)](https://github.com/alfredoagrar/Headroom/actions/workflows/codeql.yml)

macOS 26+ menu bar app that shows your AI usage limits (Claude, Codex, …) in a Liquid Glass popover: session (5h), weekly and monthly windows, with countdowns and exact reset dates. Specs: [specs/](specs/README.md) · AI agent guide: [AGENTS.md](AGENTS.md).

## Requirements
- macOS 26, Xcode 26+, `brew install xcodegen`
- Signed in to the CLIs: `claude auth login`, `codex login`

## Development
```bash
xcodegen generate                      # regenerates Headroom.xcodeproj from project.yml
xcodebuild -scheme Headroom test       # tests (real, anonymized fixtures in HeadroomTests/Fixtures)
xcodebuild -scheme Headroom build && open ~/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app
```
> Don't use `-derivedDataPath` inside `~/Documents`: iCloud adds extended attributes and `codesign` fails.

Branching, protections and releases: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## Probing endpoints manually
```bash
./Scripts/probe_claude.sh
./Scripts/probe_codex.sh
```

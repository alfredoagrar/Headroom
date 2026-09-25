@AGENTS.md

## Claude Code specifics
- Skills in `.claude/skills/`: `write-spec`, `implement-spec`, `add-provider`, `release`. Use them for those tasks instead of improvising.
- Subagent `security-reviewer` (`.claude/agents/`): run it on any diff that touches `Core/Credentials`, `Core/Networking`, `Providers/`, `Scripts/` or `.github/`.
- The popover can't be screenshotted from this environment unless Accessibility/Screen Recording is granted — ask the user to verify visual changes.

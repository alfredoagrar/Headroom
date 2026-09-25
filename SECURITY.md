# Security Policy

Headroom reads local credentials of AI tools (Claude Code Keychain item, `~/.codex/auth.json`) to query your own usage limits. It never writes to those credentials and only talks to the providers' own domains.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting instead:
**Security → Report a vulnerability** on this repository.

You can expect an initial response within 7 days.

## Scope
- Credential handling and storage
- Network requests (destinations, headers, token exposure)
- GitHub Actions workflows (injection, privilege escalation)

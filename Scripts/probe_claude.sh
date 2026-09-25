#!/bin/bash
# Phase 0: query Claude limits using the Claude Code session (Keychain).
# Never prints the token. Saves the response as a fixture in HeadroomTests/Fixtures/.
set -euo pipefail
cd "$(dirname "$0")/.."

creds=$(security find-generic-password -s "Claude Code-credentials" -w)
token=$(jq -r '.claudeAiOauth.accessToken' <<<"$creds")
expires=$(jq -r '.claudeAiOauth.expiresAt // empty' <<<"$creds")
echo "plan: $(jq -r '.claudeAiOauth.subscriptionType // "?"' <<<"$creds")"
[ -n "$expires" ] && echo "token expires: $(date -r $((expires/1000)))"

out=HeadroomTests/Fixtures/claude_usage.json
code=$(curl -sS -o "$out" -w '%{http_code}' https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Accept: application/json")
echo "HTTP $code"
jq . "$out"

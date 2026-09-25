#!/bin/bash
# Fase 0: consulta los límites de Claude con la sesión de Claude Code (Keychain).
# No imprime el token. Guarda la respuesta como fixture en HeadroomTests/Fixtures/.
set -euo pipefail
cd "$(dirname "$0")/.."

creds=$(security find-generic-password -s "Claude Code-credentials" -w)
token=$(jq -r '.claudeAiOauth.accessToken' <<<"$creds")
expires=$(jq -r '.claudeAiOauth.expiresAt // empty' <<<"$creds")
echo "plan: $(jq -r '.claudeAiOauth.subscriptionType // "?"' <<<"$creds")"
[ -n "$expires" ] && echo "token expira: $(date -r $((expires/1000)))"

out=HeadroomTests/Fixtures/claude_usage.json
code=$(curl -sS -o "$out" -w '%{http_code}' https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Accept: application/json")
echo "HTTP $code"
jq . "$out"

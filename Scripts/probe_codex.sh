#!/bin/bash
# Fase 0: consulta los límites de Codex con la sesión de Codex CLI (~/.codex/auth.json).
# No imprime el token. Guarda la respuesta (anonimizada) como fixture.
set -euo pipefail
cd "$(dirname "$0")/.."

auth=~/.codex/auth.json
token=$(jq -r '.tokens.access_token' "$auth")
account=$(jq -r '.tokens.account_id' "$auth")

out=HeadroomTests/Fixtures/codex_usage.json
code=$(curl -sS -o "$out.raw" -w '%{http_code}' https://chatgpt.com/backend-api/wham/usage \
  -H "Authorization: Bearer $token" \
  -H "ChatGPT-Account-Id: $account" \
  -H "User-Agent: codex_cli_rs" \
  -H "Accept: application/json")
echo "HTTP $code"
# Anonimiza ids/emails antes de guardar
jq 'walk(if type=="object" then with_entries(if (.key|test("email|user_id|account_id";"i")) then .value="REDACTED" else . end) else . end)' "$out.raw" > "$out" 2>/dev/null || cp "$out.raw" "$out"
rm -f "$out.raw"
jq . "$out"

echo "--- fallback: último rate_limits en logs de sesión ---"
latest=$(ls -t $(find ~/.codex/sessions -name '*.jsonl' 2>/dev/null) 2>/dev/null | head -1 || true)
[ -n "$latest" ] && grep '"rate_limits"' "$latest" | tail -1 | jq '.payload.rate_limits // .' 2>/dev/null || echo "(sin datos)"

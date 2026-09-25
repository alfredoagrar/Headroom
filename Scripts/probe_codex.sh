#!/bin/bash
# Phase 0: query Codex limits using the Codex CLI session (~/.codex/auth.json).
# Never prints the token. Saves the (anonymized) response as a fixture.
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
# Anonymize ids/emails before saving
jq 'walk(if type=="object" then with_entries(if (.key|test("email|user_id|account_id";"i")) then .value="REDACTED" else . end) else . end)' "$out.raw" > "$out" 2>/dev/null || cp "$out.raw" "$out"
rm -f "$out.raw"
jq . "$out"

echo "--- fallback: latest rate_limits in session logs ---"
latest=$(find ~/.codex/sessions -name "*.jsonl" -type f -exec stat -f "%m %N" {} + 2>/dev/null | sort -rn | head -1 | cut -d" " -f2- || true)
[ -n "$latest" ] && grep '"rate_limits"' "$latest" | tail -1 | jq '.payload.rate_limits // .' 2>/dev/null || echo "(no data)"

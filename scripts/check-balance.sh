#!/usr/bin/env bash
# check-balance.sh — query the Custos mall balance for the configured agent.
#
# Requires: CUSTOS_BASE_URL, CUSTOS_API_KEY, CUSTOS_SECRET_KEY
#
# Auth flow:
#   1. HMAC-sign "v1:<timestamp>:<apiKey>" with CUSTOS_SECRET_KEY
#   2. POST /api/v1/auth/token  →  { accessToken }
#   3. Decode agentId from token payload (base64url JSON)
#   4. GET  /api/mall/balance?agentId=<agentId>  →  { balance, currency }
#
# Exit codes:
#   0 — success; prints "balance: <value> credits"
#   1 — API error
#   2 — missing env vars

set -u

: "${CUSTOS_BASE_URL:?CUSTOS_BASE_URL is required (e.g. https://aicard.credit)}"
: "${CUSTOS_API_KEY:?CUSTOS_API_KEY is required}"
: "${CUSTOS_SECRET_KEY:?CUSTOS_SECRET_KEY is required}"

base="${CUSTOS_BASE_URL%/}"

# b64decode — portable base64 decode (GNU: -d, BSD/macOS: -D)
b64decode() {
  printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
}

# ── Step 1: HMAC sign ────────────────────────────────────────────────────────
ts=$(date +%s)
msg="v1:${ts}:${CUSTOS_API_KEY}"
sig=$(printf '%s' "$msg" | openssl dgst -sha256 -hmac "$CUSTOS_SECRET_KEY" 2>/dev/null | awk '{print $NF}')

if [ -z "$sig" ]; then
  echo "openssl not found — cannot sign request" >&2
  exit 1
fi

# ── Step 2: Exchange for Bearer token ────────────────────────────────────────
# Build JSON body safely — values are injected via python env vars, not argv
auth_json="$(APIKEY="$CUSTOS_API_KEY" SIG="$sig" python3 -c "
import json, os
print(json.dumps({'apiKey': os.environ['APIKEY'], 'timestamp': $ts, 'signature': os.environ['SIG']}))
")"

auth_resp=$(
  curl -sS -w '\n__STATUS__%{http_code}' \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$auth_json" \
    "${base}/api/v1/auth/token" 2>&1
)
auth_body=$(echo "$auth_resp" | sed '$d')
auth_status=$(echo "$auth_resp" | tail -n1 | sed 's/__STATUS__//')

if ! echo "$auth_status" | grep -q '^2'; then
  echo "Auth failed (HTTP ${auth_status}): ${auth_body}" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  access_token=$(echo "$auth_body" | jq -r '.accessToken // empty')
else
  access_token=$(echo "$auth_body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('accessToken',''))" 2>/dev/null)
fi

if [ -z "$access_token" ]; then
  echo "Auth response missing accessToken: ${auth_body}" >&2
  exit 1
fi

# ── Step 3: Decode agentId from token payload ─────────────────────────────────
# Token format: base64url(payload_json).base64url(hmac_sig)
payload_b64="${access_token%%.*}"
# Convert base64url → base64 (replace - with +, _ with /)
b64="${payload_b64//-/+}"
b64="${b64//_//}"
# Add padding
case $(( ${#b64} % 4 )) in
  2) b64="${b64}==" ;;
  3) b64="${b64}=" ;;
esac

if command -v jq >/dev/null 2>&1; then
  agent_id=$(b64decode "$b64" | jq -r '.agentId // empty')
else
  agent_id=$(b64decode "$b64" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agentId',''))" 2>/dev/null)
fi

if [ -z "$agent_id" ]; then
  echo "Could not decode agentId from token" >&2
  exit 1
fi

# ── Step 4: Fetch balance ─────────────────────────────────────────────────────
response=$(
  curl -sS -w '\n__HTTP_STATUS__%{http_code}' \
    "${base}/api/mall/balance?agentId=${agent_id}" 2>&1
)

body=$(echo "$response" | sed '$d')
status=$(echo "$response" | tail -n1 | sed 's/__HTTP_STATUS__//')

if [ "$status" = "000" ]; then
  echo "Connection error — check CUSTOS_BASE_URL (${CUSTOS_BASE_URL})" >&2
  exit 1
fi

if ! echo "$status" | grep -q '^2'; then
  echo "API error ${status}: ${body}" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  balance=$(echo "$body" | jq -r '.balance // "unknown"')
  currency=$(echo "$body" | jq -r '.currency // "credits"')
else
  balance=$(echo "$body" | grep -oE '"balance"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' || echo "unknown")
  currency="credits"
fi

echo "balance: ${balance} ${currency}"
echo "agent:   ${agent_id}"
echo "url:     ${base}"

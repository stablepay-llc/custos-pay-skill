#!/usr/bin/env bash
# check-balance.sh — query the Custos mall balance for the configured agent.
# Requires: CUSTOS_URL, CUSTOS_API_KEY, CUSTOS_AGENT_ID, MALL_AUTH_TOKEN (or OPENAI_API_KEY/ANTHROPIC_AUTH_TOKEN)
#
# Exit codes:
#   0 — success; prints "balance: <value> credits"
#   1 — API error (prints message to stderr)
#   2 — missing env vars

set -u

: "${CUSTOS_URL:?CUSTOS_URL is required (e.g. https://aicard.credit)}"
: "${CUSTOS_API_KEY:?CUSTOS_API_KEY is required}"
: "${CUSTOS_AGENT_ID:?CUSTOS_AGENT_ID is required}"

base="${CUSTOS_URL%/}"

# Prefer MALL_AUTH_TOKEN; fall back to platform-specific token env vars
mall_token="${MALL_AUTH_TOKEN:-${OPENAI_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-${GEMINI_API_KEY:-}}}}}"

if [ -z "$mall_token" ]; then
  echo "No MALL_AUTH_TOKEN found. Set it or one of OPENAI_API_KEY / ANTHROPIC_AUTH_TOKEN." >&2
  exit 2
fi

response="$(
  curl -sS -w '\n__HTTP_STATUS__%{http_code}' \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${CUSTOS_API_KEY}" \
    "${base}/api/mall/balance?agentId=${CUSTOS_AGENT_ID}" 2>&1
)"

body="$(echo "$response" | sed '$d')"
status="$(echo "$response" | tail -n1 | sed 's/__HTTP_STATUS__//')"

if [ "$status" = "000" ]; then
  echo "Connection error — check CUSTOS_URL (${CUSTOS_URL})" >&2
  exit 1
fi

if echo "$status" | grep -qv '^2'; then
  echo "API error ${status}: ${body}" >&2
  exit 1
fi

# Extract balance from JSON — works with or without jq
if command -v jq >/dev/null 2>&1; then
  balance="$(echo "$body" | jq -r '.balance // "unknown"')"
  currency="$(echo "$body" | jq -r '.currency // "credits"')"
else
  balance="$(echo "$body" | grep -oE '"balance"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' || echo "unknown")"
  currency="credits"
fi

echo "balance: ${balance} ${currency}"
echo "agent:   ${CUSTOS_AGENT_ID}"
echo "url:     ${base}"

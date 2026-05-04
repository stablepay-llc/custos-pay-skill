#!/usr/bin/env bash
# auto-recharge.sh — monitor mall balance and auto-recharge when below threshold.
#
# Usage:
#   bash scripts/auto-recharge.sh [threshold] [interval_seconds]
#
# Defaults:
#   threshold        = 0.5   (top up when balance < this many credits)
#   interval_seconds = 300   (check every 5 minutes)
#
# Requires: CUSTOS_BASE_URL, CUSTOS_API_KEY, CUSTOS_SECRET_KEY
#
# Auth flow (refreshed every hour):
#   1. HMAC-sign "v1:<timestamp>:<apiKey>" with CUSTOS_SECRET_KEY
#   2. POST /api/v1/auth/token  →  { accessToken, expiresIn }
#   3. GET  /api/mall/balance?agentId=<agentId>  to check balance
#   4. POST /api/v1/recharge with Bearer token when below threshold
#
# To run in the background:
#   bash scripts/auto-recharge.sh 0.5 300 &
#
# To stop: kill %1  (or kill the PID printed on startup)

set -u

THRESHOLD="${1:-0.5}"
INTERVAL="${2:-300}"

: "${CUSTOS_BASE_URL:?CUSTOS_BASE_URL is required}"
: "${CUSTOS_API_KEY:?CUSTOS_API_KEY is required}"
: "${CUSTOS_SECRET_KEY:?CUSTOS_SECRET_KEY is required}"

base="${CUSTOS_BASE_URL%/}"

echo "[auto-recharge] started  PID=$$"
echo "[auto-recharge] threshold=${THRESHOLD} credits | interval=${INTERVAL}s"
echo "[auto-recharge] gateway=${base}"
echo

# ── Auth helpers ──────────────────────────────────────────────────────────────

ACCESS_TOKEN=""
TOKEN_EXPIRES=0
AGENT_ID=""

refresh_token() {
  local ts sig auth_resp auth_body auth_status
  ts=$(date +%s)
  sig=$(printf '%s' "v1:${ts}:${CUSTOS_API_KEY}" | openssl dgst -sha256 -hmac "$CUSTOS_SECRET_KEY" 2>/dev/null | awk '{print $NF}')
  if [ -z "$sig" ]; then
    echo "[auto-recharge] openssl not found — cannot sign" >&2
    return 1
  fi

  auth_resp=$(
    curl -sS -w '\n__STATUS__%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -d "{\"apiKey\":\"${CUSTOS_API_KEY}\",\"timestamp\":${ts},\"signature\":\"${sig}\"}" \
      "${base}/api/v1/auth/token" 2>/dev/null
  )
  auth_body=$(echo "$auth_resp" | sed '$d')
  auth_status=$(echo "$auth_resp" | tail -n1 | sed 's/__STATUS__//')

  if ! echo "$auth_status" | grep -q '^2'; then
    echo "[auto-recharge] auth failed (HTTP ${auth_status})" >&2
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    ACCESS_TOKEN=$(echo "$auth_body" | jq -r '.accessToken // empty')
    local expires_in
    expires_in=$(echo "$auth_body" | jq -r '.expiresIn // 3600')
  else
    ACCESS_TOKEN=$(echo "$auth_body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('accessToken',''))" 2>/dev/null)
    local expires_in=3600
  fi

  TOKEN_EXPIRES=$(( $(date +%s) + expires_in - 60 ))

  # Decode agentId from token payload (base64url JSON)
  local payload_b64 b64
  payload_b64="${ACCESS_TOKEN%%.*}"
  b64="${payload_b64//-/+}"
  b64="${b64//_//}"
  case $(( ${#b64} % 4 )) in
    2) b64="${b64}==" ;;
    3) b64="${b64}=" ;;
  esac

  if command -v jq >/dev/null 2>&1; then
    AGENT_ID=$(printf '%s' "$b64" | base64 -d 2>/dev/null | jq -r '.agentId // empty')
  else
    AGENT_ID=$(printf '%s' "$b64" | base64 -d 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agentId',''))" 2>/dev/null)
  fi

  echo "[auto-recharge] token refreshed, agent=${AGENT_ID}, expires in ${expires_in}s"
}

ensure_token() {
  if [ -z "$ACCESS_TOKEN" ] || [ "$(date +%s)" -ge "$TOKEN_EXPIRES" ]; then
    refresh_token || return 1
  fi
}

get_balance() {
  ensure_token || { echo "ERR"; return; }
  local resp body status
  resp=$(
    curl -sS -w '\n__STATUS__%{http_code}' \
      "${base}/api/mall/balance?agentId=${AGENT_ID}" 2>/dev/null
  )
  body=$(echo "$resp" | sed '$d')
  status=$(echo "$resp" | tail -n1 | sed 's/__STATUS__//')
  if ! echo "$status" | grep -q '^2'; then
    echo "ERR"
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    echo "$body" | jq -r '.balance // "ERR"'
  else
    echo "$body" | grep -oE '"balance"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' || echo "ERR"
  fi
}

do_recharge() {
  ensure_token || return 1
  local resp body status
  resp=$(
    curl -sS -w '\n__STATUS__%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${base}/api/v1/recharge" 2>/dev/null
  )
  body=$(echo "$resp" | sed '$d')
  status=$(echo "$resp" | tail -n1 | sed 's/__STATUS__//')
  if echo "$status" | grep -q '^2'; then
    echo "[auto-recharge] recharge ok — ${body}"
    return 0
  else
    echo "[auto-recharge] recharge failed (HTTP ${status}): ${body}" >&2
    # Force token refresh on next iteration in case it expired mid-run
    ACCESS_TOKEN=""
    return 1
  fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────

trap 'echo "[auto-recharge] stopped (PID=$$)"; exit 0' INT TERM

while true; do
  balance="$(get_balance)"

  if [ "$balance" = "ERR" ]; then
    echo "[auto-recharge] $(date -u +%H:%M:%SZ) — balance check failed, will retry"
  else
    ts="$(date -u +%H:%M:%SZ)"
    needs_recharge="$(awk -v b="$balance" -v t="$THRESHOLD" 'BEGIN { print (b+0 < t+0) ? "yes" : "no" }')"
    echo "[auto-recharge] ${ts} — balance: ${balance} credits (threshold: ${THRESHOLD})"
    if [ "$needs_recharge" = "yes" ]; then
      echo "[auto-recharge] balance below threshold — triggering recharge..."
      do_recharge || true
    fi
  fi

  sleep "$INTERVAL"
done

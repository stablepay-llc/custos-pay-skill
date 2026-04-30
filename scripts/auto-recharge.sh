#!/usr/bin/env bash
# auto-recharge.sh — monitor mall balance and auto-recharge when below threshold.
#
# Usage:
#   bash scripts/auto-recharge.sh [threshold] [recharge_amount] [interval_seconds]
#
# Defaults:
#   threshold        = 0.5   (top up when balance < this many credits)
#   recharge_amount  = 1.0   (USDC to recharge each time)
#   interval_seconds = 300   (check every 5 minutes)
#
# Requires: CUSTOS_URL, CUSTOS_API_KEY, CUSTOS_AGENT_ID
# The first agent in the account that has a Spend Permission will be used for recharging.
#
# To run in the background:
#   bash scripts/auto-recharge.sh 0.5 1.0 300 &
#
# To stop: kill %1  (or kill the PID printed on startup)

set -u

THRESHOLD="${1:-0.5}"
RECHARGE_AMOUNT="${2:-1.0}"
INTERVAL="${3:-300}"

: "${CUSTOS_URL:?CUSTOS_URL is required}"
: "${CUSTOS_API_KEY:?CUSTOS_API_KEY is required}"
: "${CUSTOS_AGENT_ID:?CUSTOS_AGENT_ID is required}"

base="${CUSTOS_URL%/}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[auto-recharge] started  PID=$$"
echo "[auto-recharge] threshold=${THRESHOLD} credits | recharge=${RECHARGE_AMOUNT} USDC | interval=${INTERVAL}s"
echo "[auto-recharge] agent=${CUSTOS_AGENT_ID} | gateway=${base}"
echo

get_balance() {
  resp="$(
    curl -sS -w '\n__STATUS__%{http_code}' \
      -H "x-api-key: ${CUSTOS_API_KEY}" \
      "${base}/api/mall/balance?agentId=${CUSTOS_AGENT_ID}" 2>/dev/null
  )"
  body="$(echo "$resp" | sed '$d')"
  status="$(echo "$resp" | tail -n1 | sed 's/__STATUS__//')"
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
  local amount="$1"
  resp="$(
    curl -sS -w '\n__STATUS__%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -H "x-api-key: ${CUSTOS_API_KEY}" \
      -d "{\"agentId\":\"${CUSTOS_AGENT_ID}\",\"amount\":${amount}}" \
      "${base}/api/mall/recharge" 2>/dev/null
  )"
  body="$(echo "$resp" | sed '$d')"
  status="$(echo "$resp" | tail -n1 | sed 's/__STATUS__//')"
  if echo "$status" | grep -q '^2'; then
    echo "[auto-recharge] recharge ok — ${body}"
    return 0
  else
    echo "[auto-recharge] recharge failed (HTTP ${status}): ${body}" >&2
    return 1
  fi
}

# Graceful shutdown
trap 'echo "[auto-recharge] stopped (PID=$$)"; exit 0' INT TERM

while true; do
  balance="$(get_balance)"

  if [ "$balance" = "ERR" ]; then
    echo "[auto-recharge] $(date -u +%H:%M:%SZ) — balance check failed, will retry"
  else
    ts="$(date -u +%H:%M:%SZ)"
    # Compare floats using awk
    needs_recharge="$(awk -v b="$balance" -v t="$THRESHOLD" 'BEGIN { print (b+0 < t+0) ? "yes" : "no" }')"
    echo "[auto-recharge] ${ts} — balance: ${balance} credits (threshold: ${THRESHOLD})"
    if [ "$needs_recharge" = "yes" ]; then
      echo "[auto-recharge] balance below threshold — recharging ${RECHARGE_AMOUNT} USDC..."
      do_recharge "$RECHARGE_AMOUNT" || true
    fi
  fi

  sleep "$INTERVAL"
done

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

# b64decode — portable base64 decode (GNU: -d, BSD/macOS: -D)
b64decode() {
  printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
}

# ── Shared balance cache ─────────────────────────────────────────────────────
# The Stop hook (scripts/balance-guard.sh) reads from this same file so the
# hook can usually run without a network round-trip. Atomic write avoids a
# torn read when the hook fires while we are mid-update.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/custos-pay"
CACHE_FILE="$CACHE_DIR/balance.json"

write_balance_cache() {
  local value="$1" tmp
  [ -z "$value" ] && return 0
  case "$value" in ERR|err|"") return 0 ;; esac
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  tmp="$(mktemp "$CACHE_DIR/.balance.XXXXXX" 2>/dev/null)" || return 0
  printf '{"balance":%s,"checkedAt":%s}\n' "$value" "$(date +%s)" > "$tmp"
  mv -f "$tmp" "$CACHE_FILE" 2>/dev/null || rm -f "$tmp"
}

# ── Notification helpers ──────────────────────────────────────────────────────

# notify <title> <body>
# Desktop notification (macOS / Linux) + terminal banner + bell.
# Silent if neither osascript nor notify-send is available.
notify() {
  local title="$1" body="$2"
  # macOS
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${body}\" with title \"${title}\"" 2>/dev/null || true
  # Linux (libnotify)
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send --urgency=critical "$title" "$body" 2>/dev/null || true
  fi
  # Terminal banner — always shown
  local line
  line="$(printf '─%.0s' $(seq 1 60))"
  printf '\a' >&2
  echo >&2
  echo "┌${line}┐" >&2
  printf "│  %-58s│\n" "⚠  ${title}" >&2
  printf "│  %-58s│\n" "${body}" >&2
  echo "└${line}┘" >&2
  echo >&2
}

# parse_recharge_error <http_status> <body>
# Prints a single human-readable sentence describing why the recharge failed.
parse_recharge_error() {
  local status="$1" body="$2"
  case "$status" in
    402)
      if echo "$body" | grep -qi "SpendPermission"; then
        echo "SpendPermission not set up — grant one in the AiCard Dashboard → Developer tab."
      elif echo "$body" | grep -qi "limit\|remaining"; then
        echo "Recharge quota reached — top up your limit in the AiCard Dashboard → Admin → Mall."
      else
        echo "Payment required (HTTP 402) — check your Custos account configuration."
      fi ;;
    403)
      echo "Access denied (HTTP 403) — check CUSTOS_API_KEY and account permissions." ;;
    429)
      echo "Rate limit hit (HTTP 429) — too many recharge attempts. Will retry next interval." ;;
    5*)
      if echo "$body" | grep -qi "limit\|remaining\|quota\|exceeded"; then
        echo "Recharge quota fence hit — only partial credit remaining. Check AiCard Dashboard → Admin → Mall."
      elif echo "$body" | grep -qi "balance\|insufficient\|funds"; then
        echo "Insufficient on-chain USDC — top up the smart account wallet on Base."
      else
        echo "Gateway error (HTTP ${status}) — relay or CDP may be temporarily unavailable."
      fi ;;
    *)
      echo "Recharge failed (HTTP ${status}) — check logs above for details." ;;
  esac
}

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

  local auth_json
  auth_json="$(APIKEY="$CUSTOS_API_KEY" SIG="$sig" python3 -c "
import json, os
print(json.dumps({'apiKey': os.environ['APIKEY'], 'timestamp': $ts, 'signature': os.environ['SIG']}))
")"
  auth_resp=$(
    curl -sS -w '\n__STATUS__%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -d "$auth_json" \
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
    AGENT_ID=$(b64decode "$b64" | jq -r '.agentId // empty')
  else
    AGENT_ID=$(b64decode "$b64" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agentId',''))" 2>/dev/null)
  fi

  echo "[auto-recharge] token refreshed, agent=${AGENT_ID}, expires in ${expires_in}s" >&2
}

ensure_token() {
  if [ -z "$ACCESS_TOKEN" ] || [ "$(date +%s)" -ge "$TOKEN_EXPIRES" ]; then
    refresh_token || return 1
  fi
}

get_balance() {
  ensure_token || { echo "ERR"; return; }
  local resp body status value
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
    value=$(echo "$body" | jq -r '.balance // "ERR"')
  else
    value=$(echo "$body" | grep -oE '"balance"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' || echo "ERR")
  fi
  # Populate the shared cache so the Stop hook does not need to re-query.
  write_balance_cache "$value"
  printf '%s\n' "$value"
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
    RECHARGE_FAIL_COUNT=0
    return 0
  else
    echo "[auto-recharge] recharge failed (HTTP ${status}): ${body}" >&2
    RECHARGE_FAIL_COUNT=$(( RECHARGE_FAIL_COUNT + 1 ))
    LAST_FAIL_STATUS="$status"
    LAST_FAIL_BODY="$body"
    # Force token refresh on next iteration in case it expired mid-run
    ACCESS_TOKEN=""
    return 1
  fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────

trap 'echo "[auto-recharge] stopped (PID=$$)"; exit 0' INT TERM

# Failure tracking — notify on first failure, then every NOTIFY_EVERY_N failures.
RECHARGE_FAIL_COUNT=0
LAST_FAIL_STATUS=""
LAST_FAIL_BODY=""
NOTIFY_EVERY_N=3   # re-notify every N consecutive failures after the first

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
      prev_fail="$RECHARGE_FAIL_COUNT"
      do_recharge || true

      # Notify on first failure and every NOTIFY_EVERY_N after that.
      if [ "$RECHARGE_FAIL_COUNT" -gt "$prev_fail" ]; then
        should_notify="no"
        if [ "$RECHARGE_FAIL_COUNT" -eq 1 ]; then
          should_notify="yes"
        elif [ $(( RECHARGE_FAIL_COUNT % NOTIFY_EVERY_N )) -eq 0 ]; then
          should_notify="yes"
        fi

        if [ "$should_notify" = "yes" ]; then
          reason="$(parse_recharge_error "$LAST_FAIL_STATUS" "$LAST_FAIL_BODY")"
          notify \
            "Custos Pay — auto-recharge failed (attempt #${RECHARGE_FAIL_COUNT})" \
            "Mall balance: ${balance} credits | ${reason}"
        fi
      fi
    else
      # Balance is healthy — reset failure counter silently.
      RECHARGE_FAIL_COUNT=0
    fi
  fi

  sleep "$INTERVAL"
done

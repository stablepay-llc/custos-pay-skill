#!/usr/bin/env bash
# recharge-once.sh — single-shot auto-recharge call. Used by the Stop-hook
# (scripts/balance-guard.sh) to top up the mall balance immediately when it
# drops below RECHARGE_THRESHOLD, without waiting for the 5-minute daemon
# poll. Also runnable standalone for ad-hoc recharges.
#
# Auth flow (identical to check-balance.sh / auto-recharge.sh):
#   1. HMAC-sign  "v1:<timestamp>:<apiKey>"  with CUSTOS_SECRET_KEY
#   2. POST       /api/v1/auth/token   →  { accessToken }
#   3. POST       /api/v1/recharge     (Bearer token)
#   4. GET        /api/mall/balance    → refresh ~/.cache/custos-pay/balance.json
#
# Concurrency / debounce:
#   * Lock: mkdir <cache>/recharge.lock — atomic; prevents concurrent runs.
#   * Debounce: <cache>/last-recharge.ts — refuse if last attempt was within
#     RECHARGE_DEBOUNCE_SECONDS (default 60s).
#
# Exit codes:
#   0 — recharge succeeded, new balance written to cache and printed
#   1 — recharge failed (auth / API / network error)
#   2 — required CUSTOS_* env vars missing
#   3 — debounced (last attempt too recent)
#   4 — another recharge is already in flight
#
# Stdout on success:
#   balance: <new_balance> credits
#
# Stderr (always non-secret) carries diagnostics. Tokens are never echoed.

set -u

# ── Required env ─────────────────────────────────────────────────────────────
[ -n "${CUSTOS_BASE_URL:-}" ]   || { echo "CUSTOS_BASE_URL missing" >&2; exit 2; }
[ -n "${CUSTOS_API_KEY:-}" ]    || { echo "CUSTOS_API_KEY missing" >&2; exit 2; }
[ -n "${CUSTOS_SECRET_KEY:-}" ] || { echo "CUSTOS_SECRET_KEY missing" >&2; exit 2; }

base="${CUSTOS_BASE_URL%/}"
debounce_seconds="${RECHARGE_DEBOUNCE_SECONDS:-60}"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/custos-pay"
mkdir -p "$cache_dir"
lock_dir="$cache_dir/recharge.lock"
ts_file="$cache_dir/last-recharge.ts"
balance_cache="$cache_dir/balance.json"

# ── Debounce ─────────────────────────────────────────────────────────────────
if [ -f "$ts_file" ]; then
  last=$(cat "$ts_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$(( now - last ))
  if [ "$age" -lt "$debounce_seconds" ]; then
    echo "[recharge-once] debounced: last attempt ${age}s ago (window ${debounce_seconds}s)" >&2
    exit 3
  fi
fi

# ── Lock (atomic mkdir) ──────────────────────────────────────────────────────
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "[recharge-once] another recharge is already in flight (${lock_dir})" >&2
  exit 4
fi
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT INT TERM

# Mark the attempt as soon as we hold the lock so concurrent hook firings
# (within the debounce window) refuse without doing the network round-trip.
date +%s > "$ts_file"

# ── Helpers ──────────────────────────────────────────────────────────────────
b64decode() {
  printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
}

write_balance_cache() {
  local value="$1" tmp
  [ -z "$value" ] && return 0
  case "$value" in ERR|err) return 0 ;; esac
  tmp="$(mktemp "$cache_dir/.balance.XXXXXX" 2>/dev/null)" || return 0
  printf '{"balance":%s,"checkedAt":%s}\n' "$value" "$(date +%s)" > "$tmp"
  mv -f "$tmp" "$balance_cache" 2>/dev/null || rm -f "$tmp"
}

# ── 1. HMAC sign ─────────────────────────────────────────────────────────────
ts=$(date +%s)
sig=$(printf '%s' "v1:${ts}:${CUSTOS_API_KEY}" \
        | openssl dgst -sha256 -hmac "$CUSTOS_SECRET_KEY" 2>/dev/null \
        | awk '{print $NF}')

if [ -z "$sig" ]; then
  echo "[recharge-once] openssl unavailable — cannot sign request" >&2
  exit 1
fi

# ── 2. Exchange for Bearer token ─────────────────────────────────────────────
auth_body=$(APIKEY="$CUSTOS_API_KEY" SIG="$sig" python3 -c "
import json, os
print(json.dumps({'apiKey': os.environ['APIKEY'], 'timestamp': $ts, 'signature': os.environ['SIG']}))
")

auth_resp=$(
  curl -sS -w '\n__STATUS__%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    -d "$auth_body" \
    "${base}/api/v1/auth/token" 2>/dev/null
)
auth_payload=$(echo "$auth_resp" | sed '$d')
auth_status=$(echo "$auth_resp" | tail -n1 | sed 's/__STATUS__//')

if ! echo "$auth_status" | grep -q '^2'; then
  echo "[recharge-once] auth failed (HTTP ${auth_status})" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  access_token=$(echo "$auth_payload" | jq -r '.accessToken // empty')
else
  access_token=$(echo "$auth_payload" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('accessToken',''))" 2>/dev/null)
fi

if [ -z "$access_token" ]; then
  echo "[recharge-once] auth response missing accessToken" >&2
  exit 1
fi

# Decode agentId from token payload (used for the balance refresh below).
payload_b64="${access_token%%.*}"
b64="${payload_b64//-/+}"
b64="${b64//_//}"
case $(( ${#b64} % 4 )) in
  2) b64="${b64}==" ;;
  3) b64="${b64}=" ;;
esac
if command -v jq >/dev/null 2>&1; then
  agent_id=$(b64decode "$b64" | jq -r '.agentId // empty')
else
  agent_id=$(b64decode "$b64" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agentId',''))" 2>/dev/null)
fi

# ── 3. POST /api/v1/recharge ─────────────────────────────────────────────────
rcg_resp=$(
  curl -sS -w '\n__STATUS__%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${access_token}" \
    "${base}/api/v1/recharge" 2>/dev/null
)
rcg_body=$(echo "$rcg_resp" | sed '$d')
rcg_status=$(echo "$rcg_resp" | tail -n1 | sed 's/__STATUS__//')

if ! echo "$rcg_status" | grep -q '^2'; then
  echo "[recharge-once] recharge failed (HTTP ${rcg_status}): ${rcg_body}" >&2
  exit 1
fi

echo "[recharge-once] recharge ok — ${rcg_body}" >&2

# ── 4. Refresh balance cache so the next Stop hook sees recovery ─────────────
new_balance=""
if [ -n "$agent_id" ]; then
  bal_resp=$(
    curl -sS -w '\n__STATUS__%{http_code}' \
      "${base}/api/mall/balance?agentId=${agent_id}" 2>/dev/null
  )
  bal_body=$(echo "$bal_resp" | sed '$d')
  bal_status=$(echo "$bal_resp" | tail -n1 | sed 's/__STATUS__//')
  if echo "$bal_status" | grep -q '^2'; then
    if command -v jq >/dev/null 2>&1; then
      new_balance=$(echo "$bal_body" | jq -r '.balance // empty')
    else
      new_balance=$(echo "$bal_body" \
        | grep -oE '"balance"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' \
        | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)
    fi
  fi
fi

if [ -n "$new_balance" ]; then
  write_balance_cache "$new_balance"
  echo "balance: ${new_balance} credits"
else
  echo "[recharge-once] recharge ok but balance refresh failed — cache stale" >&2
fi

exit 0

#!/usr/bin/env bash
# balance-guard.sh — Claude Code Stop hook that runs after every assistant
# response, queries the Custos mall balance, and warns the user when it dips
# below RECHARGE_THRESHOLD.
#
# Designed to be wired into ~/.claude/settings.json:
#
#   {
#     "hooks": {
#       "Stop": [{
#         "matcher": "",
#         "hooks": [{
#           "type": "command",
#           "command": "bash $HOME/.claude/skills/custos-pay-skill/scripts/balance-guard.sh"
#         }]
#       }]
#     }
#   }
#
# Behaviour contract:
#   * Always exits 0 — never blocks Claude, never produces stderr noise that
#     could be mistaken for a hook failure.
#   * Skips silently when CUSTOS_* env vars are missing (skill not configured
#     in this session, or user explicitly disabled the integration).
#   * Honours a small file cache (default 30s TTL) so back-to-back responses
#     do not hammer the Custos API. The auto-recharge daemon shares the same
#     cache, so most reads cost nothing.
#   * When the balance is below RECHARGE_THRESHOLD, writes a single boxed
#     banner directly to the controlling TTY (so the user sees it even though
#     Claude Code captures stdout/stderr) and fires a desktop notification.

set -u

# ── Soft-skip when the skill isn't configured ────────────────────────────────
[ -n "${CUSTOS_BASE_URL:-}" ]   || exit 0
[ -n "${CUSTOS_API_KEY:-}" ]    || exit 0
[ -n "${CUSTOS_SECRET_KEY:-}" ] || exit 0

threshold="${RECHARGE_THRESHOLD:-0.5}"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/custos-pay"
cache_file="$cache_dir/balance.json"
cache_ttl=30  # seconds

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_script="$here/check-balance.sh"
recharge_script="$here/recharge-once.sh"
ts_file="$cache_dir/last-recharge.ts"
recharge_debounce="${RECHARGE_DEBOUNCE_SECONDS:-60}"

# ── Cache helpers ────────────────────────────────────────────────────────────
mtime_of() {
  # Portable mtime in epoch seconds (BSD `-f %m`, GNU `-c %Y`).
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

read_cached_balance() {
  [ -f "$cache_file" ] || return 1
  local mt now age
  mt=$(mtime_of "$cache_file") || return 1
  now=$(date +%s)
  age=$(( now - mt ))
  [ "$age" -lt "$cache_ttl" ] || return 1
  # Extract the numeric balance from {"balance": X.YZ, "checkedAt": …}
  awk 'match($0, /"balance"[[:space:]]*:[[:space:]]*[0-9.]+/) {
         s = substr($0, RSTART, RLENGTH);
         sub(/.*:[[:space:]]*/, "", s);
         print s;
         exit
       }' "$cache_file"
}

write_cache() {
  local value="$1" tmp
  mkdir -p "$cache_dir" 2>/dev/null || return 0
  tmp="$(mktemp "$cache_dir/.balance.XXXXXX")" || return 0
  printf '{"balance":%s,"checkedAt":%s}\n' "$value" "$(date +%s)" > "$tmp"
  mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp"
}

# ── 1. Read cache, fall back to live API call ────────────────────────────────
balance=""
if balance=$(read_cached_balance); then
  : # cache hit
else
  balance=""
  if [ -x "$check_script" ] || [ -f "$check_script" ]; then
    if out=$(bash "$check_script" 2>/dev/null); then
      balance=$(printf '%s\n' "$out" | awk -F': *' '/^balance:/ { print $2; exit }' | awk '{print $1}')
      [ -n "$balance" ] && write_cache "$balance"
    fi
  fi
fi

# Nothing to compare against — give up quietly.
[ -n "$balance" ] || exit 0

# ── 2. Compare against RECHARGE_THRESHOLD ────────────────────────────────────
needs_warn=$(awk -v b="$balance" -v t="$threshold" \
  'BEGIN { print (b+0 < t+0) ? "yes" : "no" }')
[ "$needs_warn" = "yes" ] || exit 0

# ── 3. Decide whether we will fire an auto-recharge right now ────────────────
# Mirror recharge-once.sh's debounce check so the banner reflects what the
# subprocess is actually about to do (fire vs. wait for the daemon).
recharge_action="trigger"  # one of: trigger | debounced | unavailable
if [ ! -f "$recharge_script" ]; then
  recharge_action="unavailable"
elif [ -f "$ts_file" ]; then
  last=$(cat "$ts_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $(( now - last )) -lt "$recharge_debounce" ]; then
    recharge_action="debounced"
  fi
fi

# ── 4. Emit a friendly banner + desktop notification ─────────────────────────
emit_banner() {
  local out_target="$1" status_line
  # Keep status_line ≤ 57 chars so it fits the 62-col inner box width.
  case "$recharge_action" in
    trigger)
      status_line="Auto-recharge fired in background - settling now." ;;
    debounced)
      status_line="Auto-recharge already in flight - waiting it out." ;;
    unavailable)
      status_line="Run scripts/auto-recharge.sh to top up manually." ;;
  esac
  {
    echo
    echo "┌──────────────────────────────────────────────────────────────┐"
    printf "│  ⚠  Custos Pay balance is low                                │\n"
    printf "│     balance:   %-46s│\n" "${balance} credits"
    printf "│     threshold: %-46s│\n" "${threshold} credits"
    printf "│     %-57s│\n" "$status_line"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo
  } > "$out_target" 2>/dev/null
}

# Prefer writing directly to the controlling TTY so Claude Code's stdio
# capture doesn't swallow the banner. `[ -w /dev/tty ]` returns true when
# the file exists, but the actual open() can still fail in headless
# contexts (e.g. CI, API-only runs) — probe with a real write before
# committing.
if ( : > /dev/tty ) 2>/dev/null; then
  emit_banner /dev/tty
else
  emit_banner /dev/stderr
fi

# Desktop notification — best-effort, never fatal.
if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"balance: ${balance} credits (threshold ${threshold})\" with title \"Custos Pay — balance low\"" >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "Custos Pay — balance low" "balance: ${balance} credits (threshold ${threshold})" >/dev/null 2>&1 || true
fi

# ── 5. Fire the async recharge (only when not debounced) ─────────────────────
# Spawn fully detached so the Stop hook returns instantly. The recharge log
# lands in ~/.cache/custos-pay/recharge.log for post-hoc inspection.
if [ "$recharge_action" = "trigger" ]; then
  log_file="$cache_dir/recharge.log"
  (
    nohup bash "$recharge_script" >> "$log_file" 2>&1 &
  ) >/dev/null 2>&1
fi

exit 0

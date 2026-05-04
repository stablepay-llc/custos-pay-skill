#!/usr/bin/env bash
# rollback.sh — restore the LLM provider to the state before configure.sh ran.
#
# Usage:
#   bash scripts/rollback.sh                 # reads ~/.custos-prev-provider.json
#   bash scripts/rollback.sh <agent> <prev_base> <prev_token>
#   bash scripts/rollback.sh <agent> "" ""   # clear — removes keys entirely
#
# Handles two cases correctly:
#   prev_base non-empty → restore those credentials
#   prev_base empty     → remove the keys from rc file and settings.json entirely
#
# Exit codes:
#   0 — done (restored or cleared)
#   2 — cannot determine what to roll back to

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

agent="${1:-}"
prev_base="${2:-__unset__}"   # sentinel so we can distinguish "empty" from "not provided"
prev_token="${3:-}"

# ── Load saved state if no args supplied ──────────────────────────────────────
_prev_state_file="$HOME/.custos-prev-provider.json"
if [ -z "$agent" ]; then
  if [ -f "$_prev_state_file" ]; then
    agent="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('agent', ''))
" "$_prev_state_file" 2>/dev/null || true)"
    prev_base="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('prev_base', ''))
" "$_prev_state_file" 2>/dev/null || true)"
    prev_token="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('prev_token', ''))
" "$_prev_state_file" 2>/dev/null || true)"
  else
    echo "No saved state found at $HOME/.custos-prev-provider.json" >&2
    echo >&2
    echo "Options:" >&2
    echo "  1. Run: bash scripts/rollback.sh claude \"\" \"\"" >&2
    echo "     (clears ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN entirely)" >&2
    echo "  2. Run: bash scripts/rollback.sh <agent> <old_base_url> <old_token>" >&2
    echo "     (restores specific credentials)" >&2
    exit 2
  fi
else
  # Args were provided — use them as-is (sentinel → truly empty)
  [ "$prev_base" = "__unset__" ] && prev_base=""
fi

if [ -z "$agent" ]; then
  echo "Could not determine agent from saved state." >&2
  exit 2
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

pick_rc() {
  case "${SHELL:-}" in
    *zsh*)  echo "$HOME/.zshrc" ;;
    *bash*) echo "$HOME/.bashrc" ;;
    *fish*) echo "$HOME/.config/fish/config.fish" ;;
    *)      echo "$HOME/.profile" ;;
  esac
}

bash_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
fish_quote()  { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/\\\\'/g")"; }

# Remove the custos-pay-skill marker block from rc (writes nothing back).
strip_env_block() {
  local rc="$1"
  [ -f "$rc" ] || return 0
  local marker_begin="# >>> custos-pay-skill >>>"
  local marker_end="# <<< custos-pay-skill <<<"
  local tmp; tmp="$(mktemp)"
  awk -v b="$marker_begin" -v e="$marker_end" \
    '$0==b{skip=1;next} $0==e{skip=0;next} !skip{print}' "$rc" > "$tmp"
  mv "$tmp" "$rc"
}

# Strip raw (un-marked) export/set lines for the given key names.
# Handles bash `export KEY=...` and fish `set -gx KEY ...`.
strip_raw_keys() {
  local rc="$1"; shift
  [ -f "$rc" ] || return 0
  local tmp; tmp="$(mktemp)"
  local pattern=""
  for k in "$@"; do
    # bash: ^export KEY= or ^export KEY =
    # fish: ^set -gx KEY  (with optional flags)
    pattern="${pattern}|^[[:space:]]*(export[[:space:]]+${k}[[:space:]=]|set[[:space:]].*[[:space:]]${k}[[:space:]])"
  done
  pattern="${pattern#|}"   # trim leading |
  grep -Ev "$pattern" "$rc" > "$tmp" || true
  mv "$tmp" "$rc"
}

# Write marker block with key=value pairs.
write_env_block() {
  local rc="$1"; shift
  mkdir -p "$(dirname "$rc")"
  local marker_begin="# >>> custos-pay-skill >>>"
  local marker_end="# <<< custos-pay-skill <<<"
  local is_fish=0
  case "$rc" in *fish*) is_fish=1 ;; esac
  local tmp; tmp="$(mktemp)"
  if [ -f "$rc" ]; then
    awk -v b="$marker_begin" -v e="$marker_end" \
      '$0==b{skip=1;next} $0==e{skip=0;next} !skip{print}' "$rc" > "$tmp"
  fi
  {
    echo "$marker_begin"
    while [ "$#" -gt 0 ]; do
      local k="$1" v="$2"; shift 2
      if [ "$is_fish" -eq 1 ]; then
        printf 'set -gx %s %s\n' "$k" "$(fish_quote "$v")"
      else
        printf 'export %s=%s\n' "$k" "$(bash_quote "$v")"
      fi
    done
    echo "$marker_end"
  } >> "$tmp"
  mv "$tmp" "$rc"
}

# Remove specific keys from settings.json "env" block.
remove_json_env_keys() {
  local target="$1"; shift
  [ -f "$target" ] || return 0
  python3 - "$target" "$@" <<'PY'
import json, os, sys, tempfile
target = sys.argv[1]
keys_to_remove = sys.argv[2:]
with open(target, 'r', encoding='utf-8') as f:
    try: data = json.load(f)
    except json.JSONDecodeError: data = {}
env = data.get('env') or {}
for k in keys_to_remove:
    env.pop(k, None)
if env:
    data['env'] = env
else:
    data.pop('env', None)
fd, tmp = tempfile.mkstemp(prefix='.custos-', dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.replace(tmp, target)
print(f'updated {target}', file=sys.stderr)
PY
}

# Merge key=value pairs into settings.json "env" block (for non-empty restore).
_secret_tmpfile() {
  local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
  while [ "$#" -gt 0 ]; do
    printf '%s\000%s\000' "$1" "$2" >> "$tmp"; shift 2
  done
  echo "$tmp"
}

merge_json_env() {
  local target="$1"; shift
  mkdir -p "$(dirname "$target")"
  local tmp_pairs; tmp_pairs="$(_secret_tmpfile "$@")"
  python3 - "$target" "$tmp_pairs" <<'PY'
import json, os, sys, tempfile
target, pf = sys.argv[1], sys.argv[2]
with open(pf, 'rb') as f: raw = f.read()
os.unlink(pf)
parts = [p.decode('utf-8') for p in raw.rstrip(b'\x00').split(b'\x00')]
pairs = dict(zip(parts[0::2], parts[1::2]))
data = {}
if os.path.exists(target):
    with open(target, 'r', encoding='utf-8') as f:
        try: data = json.load(f)
        except: pass
data['env'] = {**(data.get('env') or {}), **pairs}
fd, tmp = tempfile.mkstemp(prefix='.custos-', dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False); f.write('\n')
os.replace(tmp, target)
print(f'merged env into {target}', file=sys.stderr)
PY
}

# ── Main ──────────────────────────────────────────────────────────────────────

rc="$(pick_rc)"

echo "Rolling back agent=$agent ..." >&2

if [ -z "$prev_base" ]; then
  # ── Clear mode: no previous provider — remove the keys entirely ──────────────
  echo "No previous provider detected — removing Custos gateway config." >&2

  case "$agent" in
    claude)
      strip_env_block "$rc"
      strip_raw_keys  "$rc" ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
      remove_json_env_keys "$HOME/.claude/settings.json" \
        ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
      ;;
    gemini)
      strip_env_block "$rc"
      strip_raw_keys  "$rc" GOOGLE_GEMINI_BASE_URL GEMINI_API_KEY
      ;;
    openai|cursor|windsurf)
      strip_env_block "$rc"
      strip_raw_keys  "$rc" OPENAI_BASE_URL OPENAI_API_KEY
      ;;
    *)
      echo "Unknown agent: $agent" >&2; exit 2 ;;
  esac

  echo >&2
  echo "Custos gateway config removed." >&2
  echo "Claude Code will now use the default Anthropic API directly." >&2

else
  # ── Restore mode: write back the previous credentials ───────────────────────
  echo "Restoring previous provider: $prev_base" >&2

  case "$agent" in
    claude)
      strip_raw_keys "$rc" ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
      write_env_block "$rc" \
        "ANTHROPIC_BASE_URL"   "$prev_base" \
        "ANTHROPIC_AUTH_TOKEN" "$prev_token"
      merge_json_env "$HOME/.claude/settings.json" \
        "ANTHROPIC_BASE_URL"   "$prev_base" \
        "ANTHROPIC_AUTH_TOKEN" "$prev_token"
      ;;
    gemini)
      strip_raw_keys "$rc" GOOGLE_GEMINI_BASE_URL GEMINI_API_KEY
      write_env_block "$rc" \
        "GOOGLE_GEMINI_BASE_URL" "$prev_base" \
        "GEMINI_API_KEY"         "$prev_token"
      ;;
    openai|cursor|windsurf)
      strip_raw_keys "$rc" OPENAI_BASE_URL OPENAI_API_KEY
      write_env_block "$rc" \
        "OPENAI_BASE_URL" "$prev_base" \
        "OPENAI_API_KEY"  "$prev_token"
      ;;
    *)
      echo "Unknown agent: $agent" >&2; exit 2 ;;
  esac

  echo >&2
  echo "Restored to: $prev_base" >&2
fi

echo "Run: source $rc   (to apply in the current shell)" >&2
echo >&2
echo "To top up your Custos balance: AiCard Dashboard → Mall tab → Recharge" >&2

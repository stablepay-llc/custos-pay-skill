#!/usr/bin/env bash
# rollback.sh — restore the previous LLM provider credentials.
#
# Usage:
#   bash scripts/rollback.sh <agent> <prev_base_url> <prev_token>
#
# Called automatically by configure.sh on verify exit 3 (insufficient balance).
# Can also be called manually by an AI agent after a failed verify.
#
# Exit codes:
#   0 — restored successfully
#   2 — missing arguments

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

agent="${1:-}"
prev_base="${2:-}"
prev_token="${3:-}"

if [ -z "$agent" ] || [ -z "$prev_base" ] || [ -z "$prev_token" ]; then
  echo "Usage: bash scripts/rollback.sh <agent> <prev_base_url> <prev_token>" >&2
  echo "  agent      : claude | gemini | openai | cursor | windsurf" >&2
  echo "  prev_base  : previous MALL_BASE_URL value" >&2
  echo "  prev_token : previous MALL_AUTH_TOKEN value" >&2
  exit 2
fi

# Source the write helpers from configure.sh
# shellcheck source=scripts/configure.sh
. "$here/scripts/configure.sh" --source-only 2>/dev/null || true

# Inline the helpers we need (in case --source-only isn't supported)
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
  { echo "$marker_begin"
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
    with open(target, 'r') as f:
        try: data = json.load(f)
        except: pass
data['env'] = {**(data.get('env') or {}), **pairs}
fd, tmp = tempfile.mkstemp(prefix='.custos-', dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False); f.write('\n')
os.replace(tmp, target)
PY
}

rc="$(pick_rc)"

echo "Rolling back to previous provider..." >&2

case "$agent" in
  claude)
    write_env_block "$rc" \
      "ANTHROPIC_BASE_URL"   "$prev_base" \
      "ANTHROPIC_AUTH_TOKEN" "$prev_token"
    merge_json_env "$HOME/.claude/settings.json" \
      "ANTHROPIC_BASE_URL"   "$prev_base" \
      "ANTHROPIC_AUTH_TOKEN" "$prev_token"
    ;;
  gemini)
    write_env_block "$rc" \
      "GOOGLE_GEMINI_BASE_URL" "$prev_base" \
      "GEMINI_API_KEY"         "$prev_token"
    ;;
  openai|cursor|windsurf)
    write_env_block "$rc" \
      "OPENAI_BASE_URL" "$prev_base" \
      "OPENAI_API_KEY"  "$prev_token"
    ;;
  *)
    echo "Unknown agent: $agent" >&2; exit 2 ;;
esac

echo "Rolled back to: ${prev_base}" >&2
echo "Run: source ${rc}   (to apply in current shell)" >&2
echo "Top up your Custos balance at: AiCard Dashboard → Mall tab → Recharge" >&2

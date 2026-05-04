#!/usr/bin/env bash
# configure.sh — interactively prompt for credentials, then write the right
# env vars / settings file for the chosen agent platform.
#
# Per SKILL.md Steps 1–5:
#   1. Platform picker (auto-detects default)
#   2. Prompt for MALL_BASE_URL + MALL_AUTH_TOKEN
#   3. Write env block + platform settings file
#   4. Verify with verify.sh
#   5. (Optional) Custos credentials + balance check + auto-recharge
#
# Security:
#   - Secrets never appear in process argv; passed via chmod-600 temp files
#   - Values are single-quote-escaped before writing into shell rc files
#   - Fish rc files use `set -gx` instead of `export`
#
# Never echoes tokens. Always shows a write preview and asks for confirmation.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
detect="$here/scripts/detect-agent.sh"

# ── Utility ───────────────────────────────────────────────────────────────────

mask() {
  local s="${1:-}" n=${#s}
  [ "$n" -le 4 ] && printf '****' || printf '****%s' "${s: -4}"
}

# prompt_value LABEL [hidden]
# Prints the label to stderr, reads the value, prints it to stdout.
# If second arg is "yes", disables terminal echo for password entry.
prompt_value() {
  local label="$1" hidden="${2:-no}" v=""
  printf '%s: ' "$label" >&2
  if [ "$hidden" = "yes" ]; then
    local _stty_restore
    _stty_restore="$(stty -g 2>/dev/null || true)"
    # Restore echo on Ctrl-C or any exit
    trap 'stty "$_stty_restore" 2>/dev/null || stty echo 2>/dev/null || true' EXIT INT TERM HUP
    stty -echo 2>/dev/null || true
    read -r v || true
    stty "$_stty_restore" 2>/dev/null || stty echo 2>/dev/null || true
    trap - EXIT INT TERM HUP
    printf '\n' >&2
  else
    read -r v
  fi
  printf '%s' "$v"
}

confirm() {
  local p="${1:-Proceed?} [y/N] " a=""
  printf '%s' "$p" >&2
  read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

pick_rc() {
  case "${SHELL:-}" in
    *zsh*)  echo "$HOME/.zshrc" ;;
    *bash*) echo "$HOME/.bashrc" ;;
    *fish*) echo "$HOME/.config/fish/config.fish" ;;
    *)      echo "$HOME/.profile" ;;
  esac
}

# ── Shell-safe value escaping ─────────────────────────────────────────────────

# bash_quote VALUE → 'value' with embedded ' escaped as '\''
bash_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# fish_quote VALUE → 'value' with embedded ' escaped as \'
fish_quote()  { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/\\\\'/g")"; }

# ── Env-block writer ──────────────────────────────────────────────────────────
# write_env_block RC KEY1 VAL1 [KEY2 VAL2 ...]
# Idempotent: strips the previous custos-pay-skill block, then appends a new one.
# Detects fish rc files and emits `set -gx` instead of `export`.
write_env_block() {
  local rc="$1"; shift
  mkdir -p "$(dirname "$rc")"
  local marker_begin="# >>> custos-pay-skill >>>"
  local marker_end="# <<< custos-pay-skill <<<"
  local is_fish=0
  case "$rc" in *fish*) is_fish=1 ;; esac

  local tmp
  tmp="$(mktemp)"
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

# ── Secret-safe temp file helper ──────────────────────────────────────────────
# _secret_tmpfile KEY1 VAL1 [KEY2 VAL2 ...]
# Writes NUL-delimited key\0value\0... pairs to a chmod-600 temp file.
# Prints the temp file path. Caller must delete it (Python scripts do this).
_secret_tmpfile() {
  local tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  while [ "$#" -gt 0 ]; do
    printf '%s\000%s\000' "$1" "$2" >> "$tmp"
    shift 2
  done
  echo "$tmp"
}

# ── JSON / config helpers (secrets via temp file, never in argv) ──────────────

# merge_json_env TARGET KEY1 VAL1 [KEY2 VAL2 ...]
# Merges key/value pairs into TARGET's top-level "env" object.
merge_json_env() {
  local target="$1"; shift
  mkdir -p "$(dirname "$target")"
  local tmp_pairs
  tmp_pairs="$(_secret_tmpfile "$@")"
  python3 - "$target" "$tmp_pairs" <<'PY'
import json, os, sys, tempfile
target, pf = sys.argv[1], sys.argv[2]
with open(pf, 'rb') as f:
    raw = f.read()
os.unlink(pf)
parts = [p.decode('utf-8') for p in raw.rstrip(b'\x00').split(b'\x00')]
pairs = dict(zip(parts[0::2], parts[1::2]))

data = {}
if os.path.exists(target):
    with open(target, 'r', encoding='utf-8') as f:
        try: data = json.load(f)
        except json.JSONDecodeError: pass

data['env'] = {**(data.get('env') or {}), **pairs}

fd, tmp = tempfile.mkstemp(prefix='.custos-', dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.replace(tmp, target)
print(f'merged env into {target}', file=sys.stderr)
PY
}

# merge_gemini_settings TARGET ENDPOINT APIKEY
merge_gemini_settings() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  local tmp_pairs
  tmp_pairs="$(_secret_tmpfile "endpoint" "$2" "apiKey" "$3")"
  python3 - "$target" "$tmp_pairs" <<'PY'
import json, os, sys, tempfile
target, pf = sys.argv[1], sys.argv[2]
with open(pf, 'rb') as f:
    raw = f.read()
os.unlink(pf)
parts = [p.decode('utf-8') for p in raw.rstrip(b'\x00').split(b'\x00')]
kv = dict(zip(parts[0::2], parts[1::2]))

data = {}
if os.path.exists(target):
    with open(target, 'r', encoding='utf-8') as f:
        try: data = json.load(f)
        except json.JSONDecodeError: pass

data['model'] = {**(data.get('model') or {}), **kv}

fd, tmp = tempfile.mkstemp(prefix='.custos-', dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.replace(tmp, target)
print(f'merged into {target}', file=sys.stderr)
PY
}

# upsert_codex_provider TARGET BASE_URL
upsert_codex_provider() {
  local target="$1" base="$2"
  local marker_begin="# >>> custos-pay-skill >>>"
  local marker_end="# <<< custos-pay-skill <<<"
  mkdir -p "$(dirname "$target")"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$target" ]; then
    awk -v b="$marker_begin" -v e="$marker_end" \
      '$0==b{skip=1;next} $0==e{skip=0;next} !skip{print}' "$target" > "$tmp"
  fi
  # Minimal TOML string escape: backslash and double-quote
  local escaped_base
  escaped_base="$(printf '%s' "$base" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  {
    echo "$marker_begin"
    echo '[model_providers.custos]'
    echo 'name = "Custos Pay"'
    printf 'base_url = "%s"\n' "$escaped_base"
    echo 'env_key = "OPENAI_API_KEY"'
    echo "$marker_end"
  } >> "$tmp"
  mv "$tmp" "$target"
  echo "wrote provider block to $target" >&2
}

# write_cursor_mcp BASE TOKEN
write_cursor_mcp() {
  local target="$HOME/.cursor/mcp.json"
  mkdir -p "$(dirname "$target")"
  local tmp_pairs
  tmp_pairs="$(_secret_tmpfile "base" "$1" "token" "$2")"
  python3 - "$target" "$tmp_pairs" <<'PY'
import json, os, sys, tempfile
target, pf = sys.argv[1], sys.argv[2]
with open(pf, 'rb') as f:
    raw = f.read()
os.unlink(pf)
parts = [p.decode('utf-8') for p in raw.rstrip(b'\x00').split(b'\x00')]
kv = dict(zip(parts[0::2], parts[1::2]))

data = {}
if os.path.exists(target):
    with open(target, 'r', encoding='utf-8') as f:
        try: data = json.load(f)
        except json.JSONDecodeError: pass

providers = data.get('providers') or {}
providers['custos-pay'] = {
    'type': 'openai-compatible',
    'baseUrl': kv['base'],
    'apiKey': kv['token'],
    'models': []
}
data['providers'] = providers

fd, tmp = tempfile.mkstemp(prefix='.custos-', dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.replace(tmp, target)
print(f'wrote {target}', file=sys.stderr)
PY
}

# write_windsurf_provider BASE TOKEN
write_windsurf_provider() {
  local target="$HOME/.codeium/windsurf/custos-pay-provider.json"
  mkdir -p "$(dirname "$target")"
  local tmp_pairs
  tmp_pairs="$(_secret_tmpfile "base" "$1" "token" "$2")"
  python3 - "$target" "$tmp_pairs" <<'PY'
import json, os, sys, tempfile
target, pf = sys.argv[1], sys.argv[2]
with open(pf, 'rb') as f:
    raw = f.read()
os.unlink(pf)
parts = [p.decode('utf-8') for p in raw.rstrip(b'\x00').split(b'\x00')]
kv = dict(zip(parts[0::2], parts[1::2]))

data = {
    'provider': {
        'id': 'custos-pay',
        'displayName': 'Custos Pay',
        'kind': 'openai-compatible',
        'baseUrl': kv['base'],
        'apiKey': kv['token'],
        'models': []
    }
}

fd, tmp = tempfile.mkstemp(prefix='.custos-', dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.replace(tmp, target)
print(f'wrote {target}', file=sys.stderr)
PY
}

# ── Platform picker ───────────────────────────────────────────────────────────
# pick_platform DETECTED_TOKEN → prints one of: claude|gemini|openai|cursor|windsurf
pick_platform() {
  local detected="${1:-unknown}"
  local default_num=""
  case "$detected" in
    claude)          default_num=1 ;;
    gemini)          default_num=2 ;;
    openai)          default_num=3 ;;
    cursor|windsurf) default_num=4 ;;
  esac

  echo "Which platform do you want to connect to your Custos Pay gateway?" >&2
  echo >&2

  local rec
  rec=""; [ "$detected" = "claude" ]  && rec="  ← (Recommended — detected)"
  printf '  1) Claude            — Claude Code / Claude Desktop%s\n'       "$rec" >&2
  rec=""; [ "$detected" = "gemini" ]  && rec="  ← (Recommended — detected)"
  printf '  2) Gemini            — Gemini CLI / Gemini Code Assist%s\n'    "$rec" >&2
  rec=""; [ "$detected" = "openai" ]  && rec="  ← (Recommended — detected)"
  printf '  3) OpenAI / Codex    — OpenAI Codex / any OpenAI-compatible%s\n' "$rec" >&2
  rec=""
  { [ "$detected" = "cursor" ] || [ "$detected" = "windsurf" ]; } && rec="  ← (Recommended — detected)"
  printf '  4) Cursor / Windsurf — auto-resolved to whichever IDE is installed%s\n' "$rec" >&2
  echo >&2

  local prompt="Choice"
  [ -n "$default_num" ] && prompt="Choice [$default_num]"
  local choice
  printf '%s: ' "$prompt" >&2
  read -r choice
  [ -z "$choice" ] && choice="${default_num:-1}"

  case "$choice" in
    1) echo "claude" ;;
    2) echo "gemini" ;;
    3) echo "openai" ;;
    4)
      if [ -d "$HOME/.cursor" ] && [ -d "$HOME/.codeium/windsurf" ]; then
        printf '\nBoth Cursor and Windsurf detected. Which IDE?  1) Cursor  2) Windsurf [1]: ' >&2
        local ide; read -r ide
        if [ -z "$ide" ] || [ "$ide" = "1" ]; then echo "cursor"; else echo "windsurf"; fi
      elif [ -d "$HOME/.codeium/windsurf" ]; then
        echo "windsurf"
      else
        echo "cursor"
      fi ;;
    *) echo "claude" ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────

agent="${1:-}"
if [ -z "$agent" ]; then
  detected="$(bash "$detect" 2>/dev/null || echo unknown)"
  agent="$(pick_platform "$detected")"
fi

case "$agent" in
  claude|gemini|openai|cursor|windsurf) ;;
  *)
    echo "unknown agent: '$agent'. Expected one of: claude|gemini|openai|cursor|windsurf" >&2
    exit 2 ;;
esac

echo >&2
echo "Target platform: $agent" >&2
echo >&2

base="$(prompt_value "MALL_BASE_URL (e.g. https://api.credo.aicard.credit)")"
token="$(prompt_value "MALL_AUTH_TOKEN" "yes")"

if [ -z "$base" ] || [ -z "$token" ]; then
  echo "MALL_BASE_URL and MALL_AUTH_TOKEN are both required." >&2
  exit 2
fi

masked="$(mask "$token")"
rc="$(pick_rc)"

echo >&2
echo "About to configure:" >&2
printf '  %-18s: %s\n' "agent"           "$agent"   >&2
printf '  %-18s: %s\n' "MALL_BASE_URL"   "$base"    >&2
printf '  %-18s: %s\n' "MALL_AUTH_TOKEN" "$masked"  >&2
case "$agent" in
  claude)   printf '  %-18s: %s  +  %s\n' "writes" "$rc" "$HOME/.claude/settings.json" >&2 ;;
  gemini)   printf '  %-18s: %s  +  %s\n' "writes" "$rc" "$HOME/.gemini/settings.json" >&2 ;;
  openai)   printf '  %-18s: %s  +  %s\n' "writes" "$rc" "$HOME/.codex/config.toml"   >&2 ;;
  cursor)   printf '  %-18s: %s\n' "writes" "$HOME/.cursor/mcp.json"                  >&2 ;;
  windsurf) printf '  %-18s: %s\n' "writes" "$HOME/.codeium/windsurf/custos-pay-provider.json" >&2 ;;
esac
echo >&2
confirm "Write?" || { echo "aborted"; exit 1; }

case "$agent" in
  claude)
    write_env_block "$rc" \
      "ANTHROPIC_BASE_URL"   "$base" \
      "ANTHROPIC_AUTH_TOKEN" "$token"
    merge_json_env "$HOME/.claude/settings.json" \
      "ANTHROPIC_BASE_URL"   "$base" \
      "ANTHROPIC_AUTH_TOKEN" "$token"
    ;;
  gemini)
    write_env_block "$rc" \
      "GOOGLE_GEMINI_BASE_URL" "$base" \
      "GEMINI_API_KEY"         "$token"
    merge_gemini_settings "$HOME/.gemini/settings.json" "$base" "$token"
    ;;
  openai)
    write_env_block "$rc" \
      "OPENAI_BASE_URL" "$base" \
      "OPENAI_API_KEY"  "$token"
    upsert_codex_provider "$HOME/.codex/config.toml" "$base"
    ;;
  cursor)
    write_cursor_mcp "$base" "$token"
    cat >&2 <<'EOF'

Cursor written. To activate:
  Cursor → Settings → Models → enable the "custos-pay" provider.
  (Base URL / API Key are already populated from ~/.cursor/mcp.json.)
EOF
    ;;
  windsurf)
    write_windsurf_provider "$base" "$token"
    cat >&2 <<'EOF'

Windsurf written. To activate:
  Windsurf → Settings → Cascade → Manage models → Import provider
  Pick ~/.codeium/windsurf/custos-pay-provider.json (or paste Base URL /
  API Key directly into the GUI fields).
EOF
    ;;
esac

# ── Step 4: Verify ────────────────────────────────────────────────────────────
echo >&2
echo "Verifying LLM routing..." >&2
if bash "$here/scripts/verify.sh" "$agent" 2>&1; then
  echo >&2
else
  echo >&2
  echo "⚠  Verify returned a non-2xx status — check MALL_BASE_URL and MALL_AUTH_TOKEN." >&2
  echo "   (Config was written; you can re-run verify.sh after fixing the values.)" >&2
  echo >&2
fi

# ── Step 5: Custos credentials + balance monitor ──────────────────────────────
echo "──────────────────────────────────────────────────────────────────────" >&2
echo "Step 5 — Balance monitoring + auto-recharge (optional but recommended)" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2
echo >&2
echo "All five values are available via the \"Copy All\" button in the Skill" >&2
echo "Setup modal: AiCard dashboard → Mall tab → Skill button → Skill includes." >&2
echo >&2

custos_base="$(prompt_value 'CUSTOS_BASE_URL (e.g. https://aicard.credit, or press Enter to skip)')"

if [ -z "$custos_base" ]; then
  echo >&2
  echo "Skipped Custos setup. Run this script again to add it later." >&2
  echo "(Verify LLM routing anytime with: bash $here/scripts/verify.sh $agent)" >&2
  exit 0
fi

custos_api_key="$(prompt_value 'CUSTOS_API_KEY')"
custos_secret_key="$(prompt_value 'CUSTOS_SECRET_KEY' "yes")"

if [ -z "$custos_api_key" ] || [ -z "$custos_secret_key" ]; then
  echo "CUSTOS_API_KEY and CUSTOS_SECRET_KEY are both required for balance monitoring." >&2
  exit 2
fi

threshold="$(prompt_value 'Auto-recharge threshold in credits (default 0.5)')"
threshold="${threshold:-0.5}"

masked_api="$(mask "$custos_api_key")"
masked_secret="$(mask "$custos_secret_key")"

echo >&2
echo "About to add Custos credentials:" >&2
printf '  %-18s: %s\n' "CUSTOS_BASE_URL"   "$custos_base"    >&2
printf '  %-18s: %s\n' "CUSTOS_API_KEY"    "$masked_api"     >&2
printf '  %-18s: %s\n' "CUSTOS_SECRET_KEY" "$masked_secret"  >&2
printf '  %-18s: %s credits\n' "threshold" "$threshold"      >&2
printf '  %-18s: %s\n' "writes"            "$rc"             >&2
echo >&2
confirm "Write?" || { echo "aborted"; exit 1; }

# Re-write env block with all vars — idempotent (replaces previous block).
case "$agent" in
  claude)
    write_env_block "$rc" \
      "ANTHROPIC_BASE_URL"   "$base"               \
      "ANTHROPIC_AUTH_TOKEN" "$token"              \
      "CUSTOS_BASE_URL"      "$custos_base"        \
      "CUSTOS_API_KEY"       "$custos_api_key"     \
      "CUSTOS_SECRET_KEY"    "$custos_secret_key"
    merge_json_env "$HOME/.claude/settings.json" \
      "ANTHROPIC_BASE_URL"   "$base"               \
      "ANTHROPIC_AUTH_TOKEN" "$token"              \
      "CUSTOS_BASE_URL"      "$custos_base"        \
      "CUSTOS_API_KEY"       "$custos_api_key"     \
      "CUSTOS_SECRET_KEY"    "$custos_secret_key"
    ;;
  gemini)
    write_env_block "$rc" \
      "GOOGLE_GEMINI_BASE_URL" "$base"               \
      "GEMINI_API_KEY"         "$token"              \
      "CUSTOS_BASE_URL"        "$custos_base"        \
      "CUSTOS_API_KEY"         "$custos_api_key"     \
      "CUSTOS_SECRET_KEY"      "$custos_secret_key"
    ;;
  openai|cursor|windsurf)
    write_env_block "$rc" \
      "OPENAI_BASE_URL"  "$base"               \
      "OPENAI_API_KEY"   "$token"              \
      "CUSTOS_BASE_URL"  "$custos_base"        \
      "CUSTOS_API_KEY"   "$custos_api_key"     \
      "CUSTOS_SECRET_KEY" "$custos_secret_key"
    ;;
esac

echo >&2
echo "Checking balance..." >&2
if CUSTOS_BASE_URL="$custos_base" CUSTOS_API_KEY="$custos_api_key" \
   CUSTOS_SECRET_KEY="$custos_secret_key" bash "$here/scripts/check-balance.sh" 2>&1; then
  echo >&2
  echo "Starting auto-recharge monitor in the background..." >&2
  CUSTOS_BASE_URL="$custos_base" CUSTOS_API_KEY="$custos_api_key" \
  CUSTOS_SECRET_KEY="$custos_secret_key" \
    bash "$here/scripts/auto-recharge.sh" "$threshold" 300 &
  recharge_pid=$!
  echo "Auto-recharge active (PID=${recharge_pid}) — tops up when balance < ${threshold} credits." >&2
  echo "Stop with: kill ${recharge_pid}" >&2
else
  echo >&2
  echo "Balance check failed. Verify CUSTOS_BASE_URL, CUSTOS_API_KEY, CUSTOS_SECRET_KEY." >&2
  echo "Run manually: bash $here/scripts/check-balance.sh" >&2
fi

echo >&2
echo "✅ All done — LLM routing + balance monitoring configured. Happy hacking!" >&2
echo "(Verify LLM routing anytime with: bash $here/scripts/verify.sh $agent)" >&2

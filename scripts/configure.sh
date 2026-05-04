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
  local s="${1:-}"
  local n=${#s}
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

# merge_claude_stop_hook TARGET HOOK_COMMAND
# Idempotently registers a Stop hook in TARGET (~/.claude/settings.json).
# Replaces any prior custos-pay-skill hook entry, leaves all other hooks
# alone. The hook is identified by a stable id ("custos-pay-skill") so the
# update is safe to run repeatedly.
merge_claude_stop_hook() {
  local target="$1" cmd="$2"
  mkdir -p "$(dirname "$target")"
  HOOK_CMD="$cmd" python3 - "$target" <<'PY'
import json, os, sys, tempfile
target = sys.argv[1]
cmd = os.environ['HOOK_CMD']
hook_id = 'custos-pay-skill'

data = {}
if os.path.exists(target):
    with open(target, 'r', encoding='utf-8') as f:
        try: data = json.load(f)
        except json.JSONDecodeError: pass

hooks = data.get('hooks') or {}
stop_groups = hooks.get('Stop') or []

# Drop any prior group that holds our hook id, keep everything else.
def is_ours(group):
    inner = (group or {}).get('hooks') or []
    for h in inner:
        if (h or {}).get('id') == hook_id:
            return True
    return False
filtered = [g for g in stop_groups if not is_ours(g)]

filtered.append({
    'matcher': '',
    'hooks': [{
        'id': hook_id,
        'type': 'command',
        'command': cmd,
    }],
})

hooks['Stop'] = filtered
data['hooks'] = hooks

fd, tmp = tempfile.mkstemp(prefix='.custos-', dir=os.path.dirname(target) or '.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.replace(tmp, target)
print(f'registered Stop hook in {target}', file=sys.stderr)
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

# ── Config block parser ──────────────────────────────────────────────────────
# read_config_block — prompt for a multi-line KEY=VALUE block from stdin
# (terminated by a blank line) and populate these globals:
#   _cfg_mall_base, _cfg_mall_token,
#   _cfg_custos_base, _cfg_custos_api, _cfg_custos_secret,
#   _cfg_threshold
# Tolerates: surrounding whitespace, `# comments`, leading `export `,
# values wrapped in single or double quotes. Unknown keys are ignored
# silently. The raw paste is captured into a chmod-600 temp file so secrets
# never appear in argv; the file is deleted as soon as parsing finishes.
read_config_block() {
  local raw_tmp line key value
  raw_tmp="$(mktemp)"; chmod 600 "$raw_tmp"

  cat >&2 <<'EOF'
Paste your full config block below — KEY=VALUE per line.
Recognized keys:
  MALL_BASE_URL, MALL_AUTH_TOKEN
  CUSTOS_BASE_URL, CUSTOS_API_KEY, CUSTOS_SECRET_KEY  (optional, enables balance + auto-recharge)

End the paste with a blank line (just press Enter once on an empty line).

EOF

  while IFS= read -r line || [ -n "$line" ]; do
    # blank line ends input
    [ -z "$line" ] && break
    printf '%s\n' "$line" >> "$raw_tmp"
  done

  _cfg_mall_base=""; _cfg_mall_token=""
  _cfg_custos_base=""; _cfg_custos_api=""; _cfg_custos_secret=""
  _cfg_threshold=""

  while IFS= read -r line; do
    # trim leading/trailing whitespace
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; esac
    line="${line#export }"
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    # strip wrapping quotes
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    case "$key" in
      MALL_BASE_URL)      _cfg_mall_base="$value" ;;
      MALL_AUTH_TOKEN)    _cfg_mall_token="$value" ;;
      CUSTOS_BASE_URL)    _cfg_custos_base="$value" ;;
      CUSTOS_API_KEY)     _cfg_custos_api="$value" ;;
      CUSTOS_SECRET_KEY)  _cfg_custos_secret="$value" ;;
      RECHARGE_THRESHOLD) _cfg_threshold="$value" ;;
    esac
  done < "$raw_tmp"
  rm -f "$raw_tmp"
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

read_config_block

base="$_cfg_mall_base"
token="$_cfg_mall_token"
custos_base="$_cfg_custos_base"
custos_api_key="$_cfg_custos_api"
custos_secret_key="$_cfg_custos_secret"
threshold="${_cfg_threshold:-0.5}"

if [ -z "$base" ] || [ -z "$token" ]; then
  echo "MALL_BASE_URL and MALL_AUTH_TOKEN are both required in the paste." >&2
  exit 2
fi

# CUSTOS_* values are all-or-nothing — partial config is rejected.
custos_set=0
if [ -n "$custos_base" ] || [ -n "$custos_api_key" ] || [ -n "$custos_secret_key" ]; then
  if [ -z "$custos_base" ] || [ -z "$custos_api_key" ] || [ -z "$custos_secret_key" ]; then
    echo "Partial Custos credentials detected." >&2
    echo "Provide all three (CUSTOS_BASE_URL, CUSTOS_API_KEY, CUSTOS_SECRET_KEY) or none." >&2
    exit 2
  fi
  custos_set=1
fi

masked="$(mask "$token")"
rc="$(pick_rc)"

echo >&2
echo "About to configure:" >&2
printf '  %-20s: %s\n' "agent"           "$agent"   >&2
printf '  %-20s: %s\n' "MALL_BASE_URL"   "$base"    >&2
printf '  %-20s: %s\n' "MALL_AUTH_TOKEN" "$masked"  >&2
if [ "$custos_set" -eq 1 ]; then
  printf '  %-20s: %s\n' "CUSTOS_BASE_URL"   "$custos_base"                  >&2
  printf '  %-20s: %s\n' "CUSTOS_API_KEY"    "$(mask "$custos_api_key")"     >&2
  printf '  %-20s: %s\n' "CUSTOS_SECRET_KEY" "$(mask "$custos_secret_key")"  >&2
  printf '  %-20s: %s credits\n' "RECHARGE_THRESHOLD" "$threshold"           >&2
fi
case "$agent" in
  claude)   printf '  %-20s: %s  +  %s\n' "writes" "$rc" "$HOME/.claude/settings.json" >&2 ;;
  gemini)   printf '  %-20s: %s  +  %s\n' "writes" "$rc" "$HOME/.gemini/settings.json" >&2 ;;
  openai)   printf '  %-20s: %s  +  %s\n' "writes" "$rc" "$HOME/.codex/config.toml"   >&2 ;;
  cursor)   printf '  %-20s: %s\n' "writes" "$HOME/.cursor/mcp.json"                  >&2 ;;
  windsurf) printf '  %-20s: %s\n' "writes" "$HOME/.codeium/windsurf/custos-pay-provider.json" >&2 ;;
esac
if [ "$agent" = "claude" ] && [ "$custos_set" -eq 1 ]; then
  printf '  %-20s: %s\n' "Stop hook" "balance-guard.sh (warns when balance < threshold)" >&2
fi
echo >&2
confirm "Write?" || { echo "aborted"; exit 1; }

# ── Backup existing credentials before overwriting ────────────────────────────
_prev_base="" _prev_token=""
case "$agent" in
  claude)
    _prev_base="${ANTHROPIC_BASE_URL:-}"
    _prev_token="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
    ;;
  gemini)
    _prev_base="${GOOGLE_GEMINI_BASE_URL:-}"
    _prev_token="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"
    ;;
  openai|cursor|windsurf)
    _prev_base="${OPENAI_BASE_URL:-}"
    _prev_token="${OPENAI_API_KEY:-}"
    ;;
esac

# ── Rollback helper ───────────────────────────────────────────────────────────
_rollback() {
  [ -z "$_prev_base" ] && { echo "No previous provider to restore." >&2; return; }
  echo >&2
  echo "Rolling back to previous provider..." >&2
  case "$agent" in
    claude)
      write_env_block "$rc" \
        "ANTHROPIC_BASE_URL"   "$_prev_base" \
        "ANTHROPIC_AUTH_TOKEN" "$_prev_token"
      merge_json_env "$HOME/.claude/settings.json" \
        "ANTHROPIC_BASE_URL"   "$_prev_base" \
        "ANTHROPIC_AUTH_TOKEN" "$_prev_token"
      ;;
    gemini)
      write_env_block "$rc" \
        "GOOGLE_GEMINI_BASE_URL" "$_prev_base" \
        "GEMINI_API_KEY"         "$_prev_token"
      ;;
    openai|cursor|windsurf)
      write_env_block "$rc" \
        "OPENAI_BASE_URL" "$_prev_base" \
        "OPENAI_API_KEY"  "$_prev_token"
      ;;
  esac
  echo "Restored previous provider: $(mask "$_prev_base")" >&2
  echo "Run: source $rc   (to apply in current shell)" >&2
}

case "$agent" in
  claude)
    if [ "$custos_set" -eq 1 ]; then
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
      # Register the per-response balance-guard hook. The skill is installed
      # at ~/.claude/skills/custos-pay-skill/ by self-install.sh; reference
      # the absolute path so the hook works regardless of cwd.
      merge_claude_stop_hook "$HOME/.claude/settings.json" \
        "bash $HOME/.claude/skills/custos-pay-skill/scripts/balance-guard.sh"
    else
      write_env_block "$rc" \
        "ANTHROPIC_BASE_URL"   "$base" \
        "ANTHROPIC_AUTH_TOKEN" "$token"
      merge_json_env "$HOME/.claude/settings.json" \
        "ANTHROPIC_BASE_URL"   "$base" \
        "ANTHROPIC_AUTH_TOKEN" "$token"
    fi
    ;;
  gemini)
    if [ "$custos_set" -eq 1 ]; then
      write_env_block "$rc" \
        "GOOGLE_GEMINI_BASE_URL" "$base"               \
        "GEMINI_API_KEY"         "$token"              \
        "CUSTOS_BASE_URL"        "$custos_base"        \
        "CUSTOS_API_KEY"         "$custos_api_key"     \
        "CUSTOS_SECRET_KEY"      "$custos_secret_key"
    else
      write_env_block "$rc" \
        "GOOGLE_GEMINI_BASE_URL" "$base" \
        "GEMINI_API_KEY"         "$token"
    fi
    merge_gemini_settings "$HOME/.gemini/settings.json" "$base" "$token"
    ;;
  openai)
    if [ "$custos_set" -eq 1 ]; then
      write_env_block "$rc" \
        "OPENAI_BASE_URL"   "$base"               \
        "OPENAI_API_KEY"    "$token"              \
        "CUSTOS_BASE_URL"   "$custos_base"        \
        "CUSTOS_API_KEY"    "$custos_api_key"     \
        "CUSTOS_SECRET_KEY" "$custos_secret_key"
    else
      write_env_block "$rc" \
        "OPENAI_BASE_URL" "$base" \
        "OPENAI_API_KEY"  "$token"
    fi
    upsert_codex_provider "$HOME/.codex/config.toml" "$base"
    ;;
  cursor)
    write_cursor_mcp "$base" "$token"
    if [ "$custos_set" -eq 1 ]; then
      write_env_block "$rc" \
        "CUSTOS_BASE_URL"   "$custos_base"        \
        "CUSTOS_API_KEY"    "$custos_api_key"     \
        "CUSTOS_SECRET_KEY" "$custos_secret_key"
    fi
    cat >&2 <<'EOF'

Cursor written. To activate:
  Cursor → Settings → Models → enable the "custos-pay" provider.
  (Base URL / API Key are already populated from ~/.cursor/mcp.json.)
EOF
    ;;
  windsurf)
    write_windsurf_provider "$base" "$token"
    if [ "$custos_set" -eq 1 ]; then
      write_env_block "$rc" \
        "CUSTOS_BASE_URL"   "$custos_base"        \
        "CUSTOS_API_KEY"    "$custos_api_key"     \
        "CUSTOS_SECRET_KEY" "$custos_secret_key"
    fi
    cat >&2 <<'EOF'

Windsurf written. To activate:
  Windsurf → Settings → Cascade → Manage models → Import provider
  Pick ~/.codeium/windsurf/custos-pay-provider.json (or paste Base URL /
  API Key directly into the GUI fields).
EOF
    ;;
esac

# ── Verification: LLM routing + balance (single combined block) ──────────────
echo >&2
echo "──────────────────────────────────────────────────────────────────────" >&2
echo " Verification" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2
echo >&2

# 1) LLM routing — output flows directly into this block.
verify_exit=0
bash "$here/scripts/verify.sh" "$agent" 2>&1 || verify_exit=$?

# 2) Custos balance — runs immediately after, results land in the same block.
balance_ok=0
balance_value=""
balance_failed_output=""
if [ "$custos_set" -eq 1 ]; then
  echo >&2
  if balance_output=$(
    CUSTOS_BASE_URL="$custos_base" \
    CUSTOS_API_KEY="$custos_api_key" \
    CUSTOS_SECRET_KEY="$custos_secret_key" \
    bash "$here/scripts/check-balance.sh" 2>&1
  ); then
    printf '%s\n' "$balance_output" >&2
    balance_value=$(printf '%s' "$balance_output" | awk -F': *' '/^balance:/ { print $2; exit }')
    balance_ok=1
  else
    balance_failed_output="$balance_output"
    printf '%s\n' "$balance_output" >&2
  fi
fi
echo >&2

# 3) After-the-fact handlers for verify failures (rollback / hint), printed
#    below the combined verification block so the user sees results first.
if [ "$verify_exit" -eq 3 ]; then
  cat >&2 <<'MSG'
┌──────────────────────────────────────────────────────────────┐
│  ⚠  Insufficient balance on the new gateway                  │
│                                                              │
│  Your Custos mall credit is too low to serve requests.       │
│                                                              │
│  Top up at:  AiCard Dashboard → Mall tab → Recharge          │
│  Or run:     bash scripts/check-balance.sh                   │
│              bash scripts/auto-recharge.sh                   │
└──────────────────────────────────────────────────────────────┘
MSG
  if [ -n "$_prev_base" ]; then
    echo >&2
    printf 'Roll back to previous provider (%s)? [Y/n] ' "$(mask "$_prev_base")" >&2
    rb=""
    read -r rb || true
    case "${rb:-Y}" in
      n|N|no|NO) echo "Keeping new provider. Top up and re-verify with: bash scripts/verify.sh $agent" >&2 ;;
      *)         _rollback ;;
    esac
  else
    echo "Top up your balance then re-verify: bash scripts/verify.sh $agent" >&2
  fi
  echo >&2
elif [ "$verify_exit" -ne 0 ]; then
  echo "⚠  Verify returned a non-2xx status — check MALL_BASE_URL and MALL_AUTH_TOKEN." >&2
  echo "   (Config was written; you can re-run verify.sh after fixing the values.)" >&2
  echo >&2
fi

if [ "$custos_set" -eq 1 ] && [ "$balance_ok" -eq 0 ]; then
  echo "⚠  Balance check failed. Verify CUSTOS_BASE_URL / CUSTOS_API_KEY / CUSTOS_SECRET_KEY." >&2
  echo "   Run manually: bash $here/scripts/check-balance.sh" >&2
  echo >&2
fi

# Auto-recharge daemon — only when both Custos credentials and balance check are healthy.
if [ "$custos_set" -eq 1 ] && [ "$balance_ok" -eq 1 ]; then
  echo "Starting auto-recharge monitor in the background..." >&2
  CUSTOS_BASE_URL="$custos_base" CUSTOS_API_KEY="$custos_api_key" \
  CUSTOS_SECRET_KEY="$custos_secret_key" \
    bash "$here/scripts/auto-recharge.sh" "$threshold" 300 &
  recharge_pid=$!
  echo "Auto-recharge active (PID=${recharge_pid}) — tops up when balance < ${threshold} credits." >&2
  echo "Stop with: kill ${recharge_pid}" >&2
  echo >&2
fi

# ── Final summary ────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────" >&2
echo " Summary" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2
printf '  %-22s: %s\n' "agent"           "$agent" >&2
case "$verify_exit" in
  0) printf '  %-22s: %s\n' "LLM routing"     "ok" >&2 ;;
  3) printf '  %-22s: %s\n' "LLM routing"     "insufficient balance" >&2 ;;
  *) printf '  %-22s: %s (HTTP not 2xx)\n' "LLM routing" "fail" >&2 ;;
esac
if [ "$custos_set" -eq 1 ]; then
  if [ "$balance_ok" -eq 1 ]; then
    # balance_value already carries its unit (e.g. "12.345 credits"); avoid duplication.
    printf '  %-22s: %s\n' "Custos balance" "${balance_value:-?}" >&2
    printf '  %-22s: active (threshold=%s credits)\n' "Auto-recharge" "$threshold" >&2
  else
    printf '  %-22s: %s\n' "Custos balance" "check failed" >&2
    printf '  %-22s: %s\n' "Auto-recharge" "not started (balance check failed)" >&2
  fi
else
  printf '  %-22s: %s\n' "Custos balance" "not configured" >&2
  printf '  %-22s: %s\n' "Auto-recharge" "not configured" >&2
fi
echo >&2
echo "✅ Done. Re-verify anytime with: bash $here/scripts/verify.sh $agent" >&2
[ "$custos_set" -eq 1 ] && echo "   Re-check balance:        bash $here/scripts/check-balance.sh" >&2
exit 0

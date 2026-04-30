#!/usr/bin/env bash
# configure.sh — interactively prompt the user for MALL_BASE_URL and
# MALL_AUTH_TOKEN, then write the right env vars / settings file for the
# detected agent.
#
# Per SKILL.md Step 3:
#   claude   → append env block to shell rc  AND  merge into ~/.claude/settings.json
#   gemini   → append env block to shell rc  AND  merge into ~/.gemini/settings.json
#   openai   → append env block to shell rc  AND  upsert provider block in ~/.codex/config.toml
#   cursor   → write ~/.cursor/mcp.json (custos-pay provider) + GUI hint
#   windsurf → write ~/.codeium/windsurf/custos-pay-provider.json + GUI hint
#
# Never echoes the token. Always shows what will be touched and asks for
# confirmation before writing.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
detect="$here/scripts/detect-agent.sh"

mask() {
  local s="${1:-}"
  local n=${#s}
  if [ "$n" -le 4 ]; then
    printf '****'
  else
    printf '****%s' "${s: -4}"
  fi
}

prompt_base() {
  local v=""
  printf 'MALL_BASE_URL (e.g. https://api.credo.aicard.credit): ' >&2
  read -r v
  printf '%s' "$v"
}

prompt_token() {
  local v=""
  printf 'MALL_AUTH_TOKEN (input hidden): ' >&2
  stty -echo
  read -r v
  stty echo
  printf '\n' >&2
  printf '%s' "$v"
}

confirm() {
  local p="${1:-Proceed?} [y/N] "
  local a=""
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

write_env_block() {
  local rc="$1"; shift
  local marker_begin="# >>> custos-pay-skill >>>"
  local marker_end="# <<< custos-pay-skill <<<"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$rc" ]; then
    awk -v b="$marker_begin" -v e="$marker_end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$rc" > "$tmp"
  fi
  {
    echo "$marker_begin"
    for line in "$@"; do echo "$line"; done
    echo "$marker_end"
  } >> "$tmp"
  mv "$tmp" "$rc"
}

# merge_json_env <file> <key1> <val1> [<key2> <val2> ...]
# Reads existing JSON (or {}), merges values into the top-level "env" object,
# preserves all other keys, writes back atomically. Requires python3.
merge_json_env() {
  local target="$1"; shift
  mkdir -p "$(dirname "$target")"
  local args=("$target")
  while [ "$#" -gt 0 ]; do
    args+=("$1" "$2"); shift 2
  done
  python3 - "${args[@]}" <<'PY'
import json, os, sys, tempfile

target = sys.argv[1]
pairs  = sys.argv[2:]
assert len(pairs) % 2 == 0, "expected key/value pairs"

if os.path.exists(target):
    with open(target, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            data = {}
else:
    data = {}

env = data.get("env") or {}
for i in range(0, len(pairs), 2):
    env[pairs[i]] = pairs[i+1]
data["env"] = env

fd, tmp = tempfile.mkstemp(prefix=".custos-", dir=os.path.dirname(target) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, target)
print(f"merged env into {target}", file=sys.stderr)
PY
}

# merge_gemini_settings <file> <endpoint> <apiKey>
# Sets data["model"]["endpoint"] and data["model"]["apiKey"], preserving
# everything else.
merge_gemini_settings() {
  local target="$1" endpoint="$2" apikey="$3"
  mkdir -p "$(dirname "$target")"
  python3 - "$target" "$endpoint" "$apikey" <<'PY'
import json, os, sys, tempfile
target, endpoint, apikey = sys.argv[1], sys.argv[2], sys.argv[3]

if os.path.exists(target):
    with open(target, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            data = {}
else:
    data = {}

model = data.get("model") or {}
model["endpoint"] = endpoint
model["apiKey"]   = apikey
data["model"] = model

fd, tmp = tempfile.mkstemp(prefix=".custos-", dir=os.path.dirname(target) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, target)
print(f"merged into {target}", file=sys.stderr)
PY
}

# upsert_codex_provider <file> <base_url>
# Writes a `[model_providers.custos]` block bracketed by markers; replaces
# the previous block if present. Idempotent.
upsert_codex_provider() {
  local target="$1" base="$2"
  local marker_begin="# >>> custos-pay-skill >>>"
  local marker_end="# <<< custos-pay-skill <<<"
  mkdir -p "$(dirname "$target")"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$target" ]; then
    awk -v b="$marker_begin" -v e="$marker_end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$target" > "$tmp"
  fi
  {
    echo "$marker_begin"
    echo '[model_providers.custos]'
    echo 'name = "Custos Pay"'
    printf 'base_url = "%s"\n' "$base"
    echo 'env_key = "OPENAI_API_KEY"'
    echo "$marker_end"
  } >> "$tmp"
  mv "$tmp" "$target"
  echo "wrote provider block to $target" >&2
}

# write_cursor_mcp <base> <token>
# Atomically writes ~/.cursor/mcp.json with the custos-pay provider entry
# while preserving any existing provider keys.
write_cursor_mcp() {
  local target="$HOME/.cursor/mcp.json"
  mkdir -p "$(dirname "$target")"
  python3 - "$target" "$1" "$2" <<'PY'
import json, os, sys, tempfile
target, base, token = sys.argv[1], sys.argv[2], sys.argv[3]

if os.path.exists(target):
    with open(target, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            data = {}
else:
    data = {}

providers = data.get("providers") or {}
providers["custos-pay"] = {
    "type":    "openai-compatible",
    "baseUrl": base,
    "apiKey":  token,
    "models":  []
}
data["providers"] = providers

fd, tmp = tempfile.mkstemp(prefix=".custos-", dir=os.path.dirname(target) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, target)
print(f"wrote {target}", file=sys.stderr)
PY
}

write_windsurf_provider() {
  local target="$HOME/.codeium/windsurf/custos-pay-provider.json"
  mkdir -p "$(dirname "$target")"
  python3 - "$target" "$1" "$2" <<'PY'
import json, os, sys, tempfile
target, base, token = sys.argv[1], sys.argv[2], sys.argv[3]

data = {
    "provider": {
        "id": "custos-pay",
        "displayName": "Custos Pay",
        "kind": "openai-compatible",
        "baseUrl": base,
        "apiKey": token,
        "models": []
    }
}

fd, tmp = tempfile.mkstemp(prefix=".custos-", dir=os.path.dirname(target) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, target)
print(f"wrote {target}", file=sys.stderr)
PY
}

# ----- main -----

agent="${1:-}"
[ -z "$agent" ] && agent="$(bash "$detect")"

case "$agent" in
  claude|gemini|openai|cursor|windsurf) ;;
  *)
    echo "unknown agent. Pass one of: claude|gemini|openai|cursor|windsurf" >&2
    exit 2 ;;
esac

echo "Target platform: $agent" >&2
echo

base="$(prompt_base)"
token="$(prompt_token)"

if [ -z "$base" ] || [ -z "$token" ]; then
  echo "MALL_BASE_URL and MALL_AUTH_TOKEN are both required." >&2
  exit 2
fi

masked="$(mask "$token")"
rc="$(pick_rc)"

echo
echo "About to configure:"
echo "  agent      : $agent"
echo "  MALL_BASE_URL   : $base"
echo "  MALL_AUTH_TOKEN : $masked"
case "$agent" in
  claude)   echo "  writes     : $rc  +  $HOME/.claude/settings.json" ;;
  gemini)   echo "  writes     : $rc  +  $HOME/.gemini/settings.json" ;;
  openai)   echo "  writes     : $rc  +  $HOME/.codex/config.toml" ;;
  cursor)   echo "  writes     : $HOME/.cursor/mcp.json" ;;
  windsurf) echo "  writes     : $HOME/.codeium/windsurf/custos-pay-provider.json" ;;
esac
echo
confirm "Write?" || { echo "aborted"; exit 1; }

case "$agent" in
  claude)
    write_env_block "$rc" \
      "export ANTHROPIC_BASE_URL=\"$base\"" \
      "export ANTHROPIC_AUTH_TOKEN=\"$token\""
    merge_json_env "$HOME/.claude/settings.json" \
      "ANTHROPIC_BASE_URL"   "$base" \
      "ANTHROPIC_AUTH_TOKEN" "$token"
    ;;

  gemini)
    write_env_block "$rc" \
      "export GOOGLE_GEMINI_BASE_URL=\"$base\"" \
      "export GEMINI_API_KEY=\"$token\""
    merge_gemini_settings "$HOME/.gemini/settings.json" "$base" "$token"
    ;;

  openai)
    write_env_block "$rc" \
      "export OPENAI_BASE_URL=\"$base\"" \
      "export OPENAI_API_KEY=\"$token\""
    upsert_codex_provider "$HOME/.codex/config.toml" "$base"
    ;;

  cursor)
    write_cursor_mcp "$base" "$token"
    cat <<EOF

Cursor written. To activate:
  Cursor → Settings → Models → enable the "custos-pay" provider.
  (Base URL / API Key are already populated from ~/.cursor/mcp.json.)
EOF
    ;;

  windsurf)
    write_windsurf_provider "$base" "$token"
    cat <<EOF

Windsurf written to ~/.codeium/windsurf/custos-pay-provider.json. To
activate:
  Windsurf → Settings → Cascade → Manage models → Import provider
  Pick the file above (or paste MALL_BASE_URL / MALL_AUTH_TOKEN into the GUI's
  "Base URL" / "API Key" fields).
EOF
    ;;
esac

echo
echo "✅ Done — your agent is now connected to Custos Pay. Happy hacking!"
echo "(Verify anytime with: bash $here/scripts/verify.sh $agent)"

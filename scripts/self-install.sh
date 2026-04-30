#!/usr/bin/env bash
# self-install.sh — copy this skill folder into the host agent's skill directory.
# Idempotent: if the destination exists, the script reports and exits 0.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="custos-pay-skill"
detect="$here/scripts/detect-agent.sh"

agent="${1:-}"
if [ -z "$agent" ]; then
  agent="$(bash "$detect")"
fi

case "$agent" in
  claude)   dest="$HOME/.claude/skills/$name" ;;
  gemini)   dest="$HOME/.gemini/skills/$name" ;;
  cursor)   dest="$HOME/.cursor/skills/$name" ;;
  windsurf) dest="$HOME/.codeium/windsurf/skills/$name" ;;
  openai)   dest="$HOME/.config/agent-skills/$name" ;;
  unknown|"")
    cat >&2 <<EOF
Could not detect the host agent automatically.

Re-run with one of:
  bash scripts/self-install.sh claude
  bash scripts/self-install.sh gemini
  bash scripts/self-install.sh openai
  bash scripts/self-install.sh cursor
  bash scripts/self-install.sh windsurf
EOF
    exit 2
    ;;
  *)
    echo "unknown agent: $agent" >&2
    exit 2
    ;;
esac

if [ -d "$dest" ]; then
  echo "skill already installed at: $dest"
  echo "(no changes made)"
  exit 0
fi

mkdir -p "$(dirname "$dest")"
cp -R "$here" "$dest"
echo "installed: $dest"
echo
echo "Next: run  bash $dest/scripts/configure.sh  to wire up MALL_BASE_URL + MALL_AUTH_TOKEN."

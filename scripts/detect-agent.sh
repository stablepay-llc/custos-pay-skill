#!/usr/bin/env bash
# detect-agent.sh — print a single token identifying the host agent.
# Output: claude | gemini | openai | cursor | windsurf | unknown
#
# Detection order:
#   1. Already-set env vars
#   2. Config files on disk
#   3. CLI on $PATH
#
# Stdout is the single token. All diagnostics go to stderr.

set -u

log() { printf '%s\n' "$*" >&2; }

home="${HOME:-/}"

# 1. Env-var hints (most specific first)
if [ -n "${ANTHROPIC_BASE_URL:-}${ANTHROPIC_AUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ]; then
  echo claude; exit 0
fi
if [ -n "${GEMINI_API_KEY:-}${GOOGLE_GEMINI_BASE_URL:-}" ]; then
  echo gemini; exit 0
fi
if [ -n "${CURSOR_TRACE_ID:-}${CURSOR_AGENT:-}" ]; then
  echo cursor; exit 0
fi
if [ -n "${WINDSURF_SESSION:-}${CODEIUM_API_KEY:-}" ]; then
  echo windsurf; exit 0
fi
if [ -n "${OPENAI_API_KEY:-}${OPENAI_BASE_URL:-}" ]; then
  echo openai; exit 0
fi

# 2. Config files
[ -f "$home/.claude/settings.json" ]   && { echo claude;   exit 0; }
[ -d "$home/Library/Application Support/Claude" ] && { echo claude; exit 0; }
[ -f "$home/.gemini/settings.json" ]   && { echo gemini;   exit 0; }
[ -f "$home/.codex/config.toml" ]      && { echo openai;   exit 0; }
[ -d "$home/.cursor" ]                 && { echo cursor;   exit 0; }
[ -d "$home/.codeium/windsurf" ]       && { echo windsurf; exit 0; }

# 3. CLI on PATH
if command -v claude   >/dev/null 2>&1; then echo claude;   exit 0; fi
if command -v gemini   >/dev/null 2>&1; then echo gemini;   exit 0; fi
if command -v codex    >/dev/null 2>&1; then echo openai;   exit 0; fi
if command -v cursor   >/dev/null 2>&1; then echo cursor;   exit 0; fi
if command -v windsurf >/dev/null 2>&1; then echo windsurf; exit 0; fi

log "could not detect host agent"
echo unknown
exit 0

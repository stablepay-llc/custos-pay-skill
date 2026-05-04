#!/usr/bin/env bash
# verify.sh — single round-trip against the configured gateway.
# Reports HTTP status only. Token is never written to stdout/stderr.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
detect="$here/scripts/detect-agent.sh"

agent="${1:-}"
[ -z "$agent" ] && agent="$(bash "$detect")"

case "$agent" in
  claude)
    base="${ANTHROPIC_BASE_URL:-}"
    token="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
    auth_header="x-api-key: $token"
    path="/v1/models"
    ;;
  gemini)
    base="${GOOGLE_GEMINI_BASE_URL:-}"
    token="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"
    auth_header="x-goog-api-key: $token"
    path="/v1beta/models"
    ;;
  openai|cursor|windsurf)
    base="${OPENAI_BASE_URL:-}"
    token="${OPENAI_API_KEY:-}"
    auth_header="Authorization: Bearer $token"
    path="/models"
    ;;
  *)
    echo "unknown agent: $agent" >&2
    exit 2 ;;
esac

if [ -z "$base" ] || [ -z "$token" ]; then
  echo "MALL_BASE_URL or MALL_AUTH_TOKEN is empty in the current environment." >&2
  echo "Run: source ~/.zshrc  (or your rc file) before verify." >&2
  exit 2
fi

trimmed_base="${base%/}"
url="${trimmed_base}${path}"

echo "agent: $agent"
echo "GET   : $url"
echo

http_out=""
http_out="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "$auth_header" \
  -H 'content-type: application/json' \
  "$url" 2>/dev/null)" || true
# If curl failed to connect, http_out may be empty or "000"
status="${http_out:-000}"

echo "HTTP status: $status"

case "$status" in
  2*) echo "ok"; exit 0 ;;
  401|403) echo "auth rejected — token likely wrong"; exit 1 ;;
  404) echo "endpoint not found — check MALL_BASE_URL path"; exit 1 ;;
  000) echo "no response — DNS or TLS error"; exit 1 ;;
  *)  echo "unexpected status"; exit 1 ;;
esac

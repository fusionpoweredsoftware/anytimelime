#!/usr/bin/env bash
#
# p42-pull.sh — fetch the keyless tier assignments from a Project 42 server
# and merge with your local OpenRouter key into a launchable config.
#
# Usage:
#   P42_HOST=https://your-server:8042 ./p42-pull.sh
#   OR_CONFIG=./openrouter-free.config.json ./or.sh   # then launch as usual

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P42_HOST="${P42_HOST:-http://localhost:8042}"
OUT="${P42_OUT:-$SCRIPT_DIR/openrouter-free.config.json}"
KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN' "$SCRIPT_DIR/openrouter.config.json")"

REMOTE="$(curl -sf -m 20 "$P42_HOST/config.json")" || {
  echo "p42: failed to fetch $P42_HOST/config.json — is the server up?" >&2
  exit 1
}

jq -n --arg key "$KEY" --argjson r "$REMOTE" \
  '$r + {ANTHROPIC_AUTH_TOKEN: $key}' > "$OUT"

echo "p42: wrote $OUT"
jq '{OPUS: .ANTHROPIC_DEFAULT_OPUS_MODEL, SONNET: .ANTHROPIC_DEFAULT_SONNET_MODEL, HAIKU: .ANTHROPIC_DEFAULT_HAIKU_MODEL}' "$OUT"

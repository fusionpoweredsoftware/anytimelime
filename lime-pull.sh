#!/usr/bin/env bash
#
# lime-pull.sh — fetch the keyless tier assignments from an anytimelime server
# and merge with your local OpenRouter key into a launchable config.
#
# Usage:
#   LIME_HOST=https://your-server:8042 ./lime-pull.sh
#   OR_CONFIG=./openrouter-free.config.json ./or.sh   # then launch as usual

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIME_HOST="${LIME_HOST:-http://localhost:8042}"
OUT="${LIME_OUT:-$SCRIPT_DIR/openrouter-free.config.json}"
KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN' "$SCRIPT_DIR/openrouter.config.json")"

REMOTE="$(curl -sf -m 20 "$LIME_HOST/config.json")" || {
  echo "lime-pull: failed to fetch $LIME_HOST/config.json — is the server up?" >&2
  exit 1
}

jq -n --arg key "$KEY" --argjson r "$REMOTE" \
  '$r + {ANTHROPIC_AUTH_TOKEN: $key}' > "$OUT"

echo "lime-pull: wrote $OUT"
jq '{OPUS: .ANTHROPIC_DEFAULT_OPUS_MODEL, SONNET: .ANTHROPIC_DEFAULT_SONNET_MODEL, HAIKU: .ANTHROPIC_DEFAULT_HAIKU_MODEL}' "$OUT"

#!/usr/bin/env bash
#
# lime.sh — the smart launcher. Unlike or.sh (which loads a frozen config
# file), lime.sh asks the AnytimeLime blog endpoint what's free TODAY,
# merges in your own OpenRouter key, and launches Claude Code on it.
#
# The blog at anytimelime.com/blog publishes latest.json every morning
# (probe results + tier assignments). This script is dumb about nothing:
# it always runs the freshest verified-free roster.
#
# Usage:
#   ./lime.sh                     # launch on today's blog roster
#   ./lime.sh -p "query"          # normal claude flags pass through
#   LIME_ENDPOINT=http://host:8042/config.json ./lime.sh   # alt endpoint
#
# Key resolution: LIME_KEY env var, else ANTHROPIC_AUTH_TOKEN from
# openrouter.config.json next to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENDPOINT="${LIME_ENDPOINT:-https://anytimelime.com/blog/latest.json}"
KEY="${LIME_KEY:-$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$SCRIPT_DIR/openrouter.config.json" 2>/dev/null || true)}"

if [ -z "$KEY" ]; then
  echo "lime: no key — set LIME_KEY or put ANTHROPIC_AUTH_TOKEN in openrouter.config.json" >&2
  exit 1
fi

# Fetch the endpoint's findings; fall back to the last local config if
# the network (or the endpoint) is down.
if ! ROSTER="$(curl -sf -m 20 "$ENDPOINT")"; then
  echo "lime: endpoint unreachable ($ENDPOINT)" >&2
  if [ -f "$SCRIPT_DIR/openrouter-free.config.json" ]; then
    echo "lime: falling back to last local squeeze" >&2
    ROSTER="$(jq -c '{tiers: {opus: .ANTHROPIC_DEFAULT_OPUS_MODEL,
                              sonnet: .ANTHROPIC_DEFAULT_SONNET_MODEL,
                              haiku: .ANTHROPIC_DEFAULT_HAIKU_MODEL}}' \
      "$SCRIPT_DIR/openrouter-free.config.json")"
  else
    echo "lime: no local fallback either. Nothing to launch on." >&2
    exit 1
  fi
fi

export ANTHROPIC_AUTH_TOKEN="$KEY"
export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
export API_TIMEOUT_MS="3000000"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"

# --- Rotation -----------------------------------------------------------------
# Dumb round-robin over the roster's `order`: next, next, next. Every launch
# uses the next model in the sequence, wrapping around. Optional weights in
# rotation.weights.json ({"model-id": n}) repeat a model n times per cycle;
# absent file or missing entry = weight 1. LIME_ROTATE=0 disables rotation
# and uses the endpoint's tier assignments instead.
if [ "${LIME_ROTATE:-1}" = "1" ]; then
  ORDER="$(printf '%s' "$ROSTER" | jq -r '.order // [] | .[]' 2>/dev/null || true)"
  if [ -n "$ORDER" ]; then
    WEIGHTS_FILE="${LIME_WEIGHTS:-$SCRIPT_DIR/rotation.weights.json}"
    SEQ="$(printf '%s\n' "$ORDER" | while IFS= read -r m; do
      [ -z "$m" ] && continue
      w=1
      if [ -f "$WEIGHTS_FILE" ]; then
        w="$(jq -r --arg m "$m" '.[$m] // 1' "$WEIGHTS_FILE" 2>/dev/null || echo 1)"
      fi
      case "$w" in ''|*[!0-9]*) w=1;; esac
      [ "$w" -lt 1 ] && w=1
      for _ in $(seq 1 "$w"); do printf '%s\n' "$m"; done
    done)"
    TOTAL="$(printf '%s\n' "$SEQ" | grep -c . || true)"
    CURSOR_FILE="${LIME_CURSOR:-$SCRIPT_DIR/.lime-cursor}"
    CURSOR="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"
    case "$CURSOR" in ''|*[!0-9]*) CURSOR=0;; esac
    PICK="$(printf '%s\n' "$SEQ" | sed -n "$((CURSOR % TOTAL + 1))p")"
    echo $((CURSOR + 1)) > "$CURSOR_FILE"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$PICK"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$PICK"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$PICK"
    echo "lime 🍋  roster: $(printf '%s' "$ROSTER" | jq -r '.updated // "cached"')  rotation: $((CURSOR % TOTAL + 1))/$TOTAL  model=$PICK"
  fi
fi
if [ -z "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ]; then
  export ANTHROPIC_DEFAULT_OPUS_MODEL="$(printf '%s' "$ROSTER" | jq -r '.tiers.opus // "openrouter/free"')"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="$(printf '%s' "$ROSTER" | jq -r '.tiers.sonnet // "openrouter/free"')"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="$(printf '%s' "$ROSTER" | jq -r '.tiers.haiku // "openrouter/free"')"
  echo "lime 🍋  roster: $(printf '%s' "$ROSTER" | jq -r '.updated // "cached"')  opus=$(printf '%s' "$ROSTER" | jq -r .tiers.opus)  sonnet=$(printf '%s' "$ROSTER" | jq -r .tiers.sonnet)  haiku=$(printf '%s' "$ROSTER" | jq -r .tiers.haiku)"
fi

exec claude "$@"

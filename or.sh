#!/usr/bin/env bash
#
# or.sh — launch Claude Code pointed at OpenRouter's Anthropic-compatible API.
#
# The API key lives in openrouter.config.json next to this script (credentials
# only — see openrouter.config.json.example). The vars are exported ONLY for
# the claude process launched here, so your normal shell / default Claude
# settings are left untouched.
#
# Usage:
#   ./or.sh              # start interactive Claude Code on OpenRouter
#   ./or.sh -p "query"   # any normal `claude` flags pass through
#   OR_CONFIG=/path/to/other.json ./or.sh   # use a different config
#
# Models: tiers come from the latest openrouter-free.config.json roster when
#   present, else paid defaults. Override per-run: OR_OPUS, OR_SONNET, OR_HAIKU
#   (OpenRouter model IDs, e.g. "anthropic/claude-sonnet-4.5").

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${OR_CONFIG:-$SCRIPT_DIR/openrouter.config.json}"

if [ ! -f "$CONFIG" ]; then
  echo "or: config file not found: $CONFIG" >&2
  exit 1
fi

# The config is credentials only (ANTHROPIC_AUTH_TOKEN). Models, base URL,
# and timeouts live here so the config stays a one-line file.
KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$CONFIG")"
case "$KEY" in
  ""|"YOUR_OPENROUTER_API_KEY_HERE"|*[Pp][Ll][Aa][Cc][Ee][Hh][Oo][Ll][Dd][Ee][Rr]*|*[Pp][Aa][Ss][Tt][Ee]*|*[Yy][Oo][Uu][Rr]*[Kk][Ee][Yy]*)
    echo "or: ANTHROPIC_AUTH_TOKEN is still the placeholder." >&2
    echo "     Put your real OpenRouter key (sk-or-...) in $CONFIG, then re-run." >&2
    exit 1
    ;;
esac
export ANTHROPIC_AUTH_TOKEN="$KEY"
export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
export API_TIMEOUT_MS="3000000"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"

# Model tiers: prefer the latest free roster from synthesize.sh if it exists,
# else sensible paid defaults. Override per-run with OR_OPUS/OR_SONNET/OR_HAIKU.
if [ -f "$SCRIPT_DIR/openrouter-free.config.json" ]; then
  FREE_MODELS="$(jq -r '[.ANTHROPIC_DEFAULT_OPUS_MODEL, .ANTHROPIC_DEFAULT_SONNET_MODEL, .ANTHROPIC_DEFAULT_HAIKU_MODEL] | @tsv' "$SCRIPT_DIR/openrouter-free.config.json")"
  OR_OPUS="$(printf '%s' "$FREE_MODELS"   | sed -n 1p)"; [ "$OR_OPUS" = "null" ] && OR_OPUS=""
  OR_SONNET="$(printf '%s' "$FREE_MODELS" | sed -n 2p)"; [ "$OR_SONNET" = "null" ] && OR_SONNET=""
  OR_HAIKU="$(printf '%s' "$FREE_MODELS"  | sed -n 3p)"; [ "$OR_HAIKU" = "null" ] && OR_HAIKU=""
fi
export ANTHROPIC_DEFAULT_OPUS_MODEL="${OR_OPUS:-anthropic/claude-opus-4.6}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${OR_SONNET:-anthropic/claude-sonnet-4.5}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${OR_HAIKU:-anthropic/claude-haiku-4.5}"

exec claude "$@"

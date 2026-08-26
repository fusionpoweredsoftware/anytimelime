#!/usr/bin/env bash
#
# or.sh — launch Claude Code pointed at OpenRouter's Anthropic-compatible API.
#
# Everything (API key, models) lives in openrouter.config.json next to this
# script. The vars are exported ONLY for the claude process launched here, so
# your normal shell / default Claude settings are left untouched.
#
# Usage:
#   ./or.sh              # start interactive Claude Code on OpenRouter
#   ./or.sh -p "query"   # any normal `claude` flags pass through
#   OR_CONFIG=/path/to/other.json ./or.sh   # use a different config
#
# Models: edit ANTHROPIC_DEFAULT_*_MODEL in openrouter.config.json.
#   Use OpenRouter model IDs, e.g. "anthropic/claude-sonnet-4.5",
#   "openai/gpt-5.2", "google/gemini-2.5-pro". Pick a cheap/fast model
#   for HAIKU (background tasks).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${OR_CONFIG:-$SCRIPT_DIR/openrouter.config.json}"

if [ ! -f "$CONFIG" ]; then
  echo "or: config file not found: $CONFIG" >&2
  exit 1
fi

# Read each key/value from the config and export it for this process only.
# Values may contain "=" (read splits only on the first "=").
if ! json_env="$(jq -r 'to_entries[] | "\(.key)=\(.value|tostring)"' "$CONFIG")"; then
  echo "or: failed to parse $CONFIG — is it valid JSON?" >&2
  exit 1
fi

while IFS='=' read -r key val; do
  [ -n "$key" ] && export "$key=$val"
done <<< "$json_env"

# Refuse to launch if the key or models are still placeholders.
case "${ANTHROPIC_AUTH_TOKEN:-}" in
  ""|"YOUR_OPENROUTER_API_KEY_HERE"|*[Pp][Ll][Aa][Cc][Ee][Hh][Oo][Ll][Dd][Ee][Rr]*)
    echo "or: ANTHROPIC_AUTH_TOKEN is still the placeholder." >&2
    echo "     Put your real OpenRouter key (sk-or-...) in $CONFIG, then re-run." >&2
    exit 1
    ;;
esac
case "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" in
  *"YOUR_OPENROUTER_MODEL_HERE"*)
    echo "or: ANTHROPIC_DEFAULT_SONNET_MODEL is still the placeholder." >&2
    echo "     Set OpenRouter model IDs (e.g. anthropic/claude-sonnet-4.5) in $CONFIG." >&2
    exit 1
    ;;
esac

exec claude "$@"

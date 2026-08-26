#!/usr/bin/env bash
#
# or-key.sh — resolve the OpenRouter key for the pipeline scripts.
#
# Order: OPENROUTER_API_KEY env → ANTHROPIC_AUTH_TOKEN in the config file.
# If all that exists is the placeholder (or nothing) and a human is at the
# terminal, ASK for the key once and write it into the config file — so the
# placeholder only ever bites once per machine. Under cron (no terminal) it
# exits 1 with instructions instead of hanging.
#
# Prints the key on stdout; human messages go to stderr.
#   KEY="$(./or-key.sh)" || exit 1
#
# Env: OR_PROBE_CONFIG — config path (default: openrouter.config.json here).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${OR_PROBE_CONFIG:-$SCRIPT_DIR/openrouter.config.json}"
PLACEHOLDER="YOUR_OPENROUTER_API_KEY_HERE"

is_placeholder() {
  case "${1:-}" in
    ""|"null"|$PLACEHOLDER|*PLACEHOLDER*|*PASTE*|*YOUR*KEY*) return 0 ;;
    *) return 1 ;;
  esac
}

# 1. env var
if [ -n "${OPENROUTER_API_KEY:-}" ] && ! is_placeholder "$OPENROUTER_API_KEY"; then
  printf '%s' "$OPENROUTER_API_KEY"
  exit 0
fi

# 2. config file
TOK=""
if [ ! -f "$CONFIG" ]; then
  # Seed from the committed openrouter.config.json.example so the file
  # starts with its full documented shape; minimal stub as fallback.
  umask 077
  if [ -f "$SCRIPT_DIR/openrouter.config.json.example" ]; then
    cp "$SCRIPT_DIR/openrouter.config.json.example" "$CONFIG"
  else
    printf '{\n  "ANTHROPIC_AUTH_TOKEN": "%s"\n}\n' "$PLACEHOLDER" > "$CONFIG"
  fi
elif [ -s "$CONFIG" ]; then
  TOK="$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$CONFIG" 2>/dev/null || true)"
fi
if ! is_placeholder "$TOK"; then
  printf '%s' "$TOK"
  exit 0
fi

# 3. Placeholder in play. Ask — but only if someone can answer.
if [ ! -t 0 ]; then
  echo "or-key: $CONFIG still holds the placeholder, and no terminal to ask on." >&2
  echo "        Put your key in it (\"ANTHROPIC_AUTH_TOKEN\": \"sk-or-...\")," >&2
  echo "        or export OPENROUTER_API_KEY, then re-run." >&2
  exit 1
fi

ATTEMPTS=3
while [ "$ATTEMPTS" -gt 0 ]; do
  ATTEMPTS=$((ATTEMPTS - 1))
  printf 'OpenRouter API key (sk-or-..., saved to %s): ' "$CONFIG" >&2
  IFS= read -r K
  if is_placeholder "$K"; then
    echo "or-key: that still looks like the placeholder." >&2
    continue
  fi
  case "$K" in
    sk-or-*) ;;
    *) echo "or-key: OpenRouter keys start with sk-or- ." >&2; continue ;;
  esac
  # Write it back so this is never asked twice. Preserve any other fields.
  TMP="$CONFIG.tmp.$$"
  if [ -s "$CONFIG" ] && jq -e . "$CONFIG" >/dev/null 2>&1; then
    jq --arg k "$K" '.ANTHROPIC_AUTH_TOKEN = $k' "$CONFIG" > "$TMP" && mv -f "$TMP" "$CONFIG"
  else
    umask 077
    printf '{\n  "ANTHROPIC_AUTH_TOKEN": "%s"\n}\n' "$K" > "$CONFIG"
  fi
  chmod 600 "$CONFIG"
  echo "or-key: key saved to $CONFIG (gitignored — never committed)." >&2
  printf '%s' "$K"
  exit 0
done

echo "or-key: no key given — aborting." >&2
exit 1

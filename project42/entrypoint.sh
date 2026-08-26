#!/usr/bin/env bash
#
# entrypoint.sh — Project 42 container loop.
#
# 1. Materializes the OpenRouter key from env into openrouter.config.json
#    (so the key never gets baked into the image).
# 2. Runs synthesize.sh immediately, then every SYNTH_INTERVAL seconds.
# 3. After each run, publishes a KEY-LESS copy of the config over HTTP
#    so other machines can fetch the tier assignments without ever
#    exposing the token.

set -euo pipefail

: "${OPENROUTER_API_KEY:?Set OPENROUTER_API_KEY (docker-compose or -e)}"
INTERVAL="${SYNTH_INTERVAL:-86400}"   # default: daily
PORT="${PORT:-8042}"

cd /app
mkdir -p /app/public

# Key file from env — not in the image, not in the served output.
jq -n --arg key "$OPENROUTER_API_KEY" \
  '{ANTHROPIC_AUTH_TOKEN: $key, ANTHROPIC_BASE_URL: "https://openrouter.ai/api"}' \
  > /app/openrouter.config.json

run_scan() {
  if /app/synthesize.sh; then
    # Publish keyless config: assignments only.
    jq 'del(.ANTHROPIC_AUTH_TOKEN)' /app/openrouter-free.config.json > /app/public/config.json
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] published keyless config"
  else
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] scan failed; keeping last good config"
  fi
}

# The scan loop. This used to be a bare `run_scan &` — one scan at boot and
# never again, so SYNTH_INTERVAL was documented, configured, and ignored, and
# a long-running container served a roster that quietly rotted.
(
  while true; do
    run_scan
    sleep "$INTERVAL"
  done
) &

# Smart access proxy: Anthropic-compatible /v1/messages with failover.
python3 /app/proxy.py &

# Tiny HTTP server for /app/public (config.json + models.json + logs).
cd /app/public && exec python3 -m http.server "$PORT"

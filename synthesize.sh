#!/usr/bin/env bash
#
# synthesize.sh — the self-hosting loop: probe free OpenRouter models, then
# ask a free model to synthesize the results and pick the tier assignments
# for Claude Code. Writes openrouter-free.config.json on success; falls
# back to the order-of-appearance heuristic if synthesis fails.
#
# Intended to run daily/hourly from cron or launchd:
#   ./synthesize.sh            # probe + synthesize + write config
#
# Logs to synthesize.log next to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_CONFIG="${FREE_SCAN_OUT:-$SCRIPT_DIR/openrouter-free.config.json}"
LOG="$SCRIPT_DIR/synthesize.log"
CONFIG_IN="${OR_PROBE_CONFIG:-$SCRIPT_DIR/openrouter.config.json}"
SYNTH_MODEL="${SYNTH_MODEL:-openrouter/free}"

KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$CONFIG_IN" ]; then
  KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$CONFIG_IN" 2>/dev/null || true)"
fi
if [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
  echo "synthesize: no OpenRouter key — set OPENROUTER_API_KEY or put" >&2
  echo "            ANTHROPIC_AUTH_TOKEN in $CONFIG_IN" >&2
  exit 1
fi

exec >> "$LOG" 2>&1
echo "=== synthesize run — $(date '+%Y-%m-%d %H:%M:%S') ==="

# --- 1. Discover + probe (reuses free-scan.sh) -----------------------------
PROBE_OUT="$SCRIPT_DIR/.probe-results.txt"
"$SCRIPT_DIR/free-scan.sh" | tee "$PROBE_OUT"

PASSING=$(awk '/^=== Passing/{f=1;next} f{if($0=="")exit; sub(/^  /,""); print}' "$PROBE_OUT" || true)
if [ -z "$PASSING" ]; then
  echo "synthesize: nothing passed; keeping existing config." >&2
  exit 1
fi
PASS_ARR=$(echo "$PASSING" | jq -R . | jq -s .)

# --- 2. Synthesize: a free model picks the tiers ---------------------------
# Give it the full probe evidence (latency, pass/fail, errors) plus the
# passing list, and ask for a tiering decision as strict JSON.
EVIDENCE=$(grep -v '^===' "$PROBE_OUT" | head -60 | jq -R . | jq -s .)

# Build the evidence blob once, then post it. (This used to pipe one jq into
# curl while a process substitution silently overrode curl's stdin — the
# piped copy went nowhere. One payload, one path.)
CTX=$(jq -n --argjson passing "$PASS_ARR" --argjson evidence "$EVIDENCE" \
  '{passing: $passing, probe_evidence: $evidence}')

TIER_JSON=$(jq -n --arg m "$SYNTH_MODEL" --arg ctx "$CTX" \
  '{model: $m, max_tokens: 1000,
    messages: [
      {role: "system", content: "You assign models to tiers for an agentic coding assistant. OPUS and SONNET need the strongest general coding + tool-use ability (they do the real work). HAIKU handles cheap background tasks and should be fast. Respond with ONLY a JSON object: {\"opus\": \"model-id\", \"sonnet\": \"model-id\", \"haiku\": \"model-id\"} using ids from the passing list. Prefer low latency for haiku. Prefer strongest capability for opus/sonnet."},
      {role: "user", content: $ctx}
    ]}' \
  | curl -s -m 120 https://openrouter.ai/api/v1/chat/completions \
      -H "Authorization: Bearer $KEY" \
      -H "content-type: application/json" \
      -d @- || true)

ASSIGNMENT=$(echo "$TIER_JSON" | jq -r '.choices[0].message.content // empty' \
  | sed 's/^```json//;s/^```//;s/```$//' | jq -c 'try {opus, sonnet, haiku} catch empty' 2>/dev/null || true)

if ! echo "$ASSIGNMENT" | jq -e '.opus and .sonnet and .haiku' >/dev/null 2>&1 \
   || ! jq -n --argjson a "$ASSIGNMENT" --argjson p "$PASS_ARR" \
        '$a | [.opus,.sonnet,.haiku] | all(. as $m | $p | index($m))' >/dev/null 2>&1; then
  echo "synthesize: model output invalid or off-list; falling back to heuristic."
  P=()
  while IFS= read -r _l; do [ -n "$_l" ] && P+=("$_l"); done <<< "$PASSING"
  ASSIGNMENT=$(jq -n --arg o "${P[0]}" --arg s "${P[0]}" --arg h "${P[${#P[@]}-1]}" \
    '{opus: $o, sonnet: $s, haiku: $h}')
fi

echo "Assignment: $ASSIGNMENT"

# Publish the passing order (failover list) for the smart proxy — keyless.
mkdir -p "$SCRIPT_DIR/public"
jq -n --argjson p "$PASS_ARR" '{order: $p, updated: (now | todateiso8601)}' \
  > "$SCRIPT_DIR/public/models.json"

jq -n --arg key "$KEY" --argjson a "$ASSIGNMENT" '{
  ANTHROPIC_AUTH_TOKEN: $key,
  ANTHROPIC_BASE_URL: "https://openrouter.ai/api",
  ANTHROPIC_DEFAULT_OPUS_MODEL: $a.opus,
  ANTHROPIC_DEFAULT_SONNET_MODEL: $a.sonnet,
  ANTHROPIC_DEFAULT_HAIKU_MODEL: $a.haiku,
  API_TIMEOUT_MS: "3000000",
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
}' > "$OUT_CONFIG"

echo "Wrote $OUT_CONFIG:"
jq '{OPUS: .ANTHROPIC_DEFAULT_OPUS_MODEL, SONNET: .ANTHROPIC_DEFAULT_SONNET_MODEL, HAIKU: .ANTHROPIC_DEFAULT_HAIKU_MODEL}' "$OUT_CONFIG"
echo "Launch with:  OR_CONFIG=$OUT_CONFIG ./or.sh"

#!/usr/bin/env bash
#
# synthesize.sh — the self-hosting loop: probe free models across the
# internet, then ask a free model to synthesize the results and pick the
# tier assignments for Claude Code. Writes openrouter-free.config.json on
# success; falls back to the order-of-appearance heuristic if synthesis fails.
#
# The probe (free-scan.sh) now sweeps the whole internet (research.sh's
# candidates.json), but the CONFIG is still OpenRouter-shaped — or.sh / lime.sh
# hardcode ANTHROPIC_BASE_URL=openrouter. So tiers are assigned from the
# OPENROUTER-passing subset only. The full multi-vendor roster lives in the
# results JSON and is published to latest.json by blog-gen. Cross-vendor
# serving is Phase E.
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

# Key resolution: env → config file → ask on the terminal and save
# (or-key.sh exits 1 under cron with instructions if only the placeholder
# is present — it never hangs waiting for input).
KEY="$("$SCRIPT_DIR/or-key.sh")" || exit 1

exec >> "$LOG" 2>&1
echo "=== synthesize run — $(date '+%Y-%m-%d %H:%M:%S') ==="

# --- 1. Discover + probe (reuses free-scan.sh) -----------------------------
# free-scan writes a full multi-vendor results JSON; we read that instead of
# parsing stdout so we know each passing model's base_url (to filter to the
# OpenRouter subset the config can actually launch).
PROBE_OUT="$SCRIPT_DIR/.probe-results.txt"
RESULTS_JSON="$SCRIPT_DIR/.probe-results.json"
# `|| true`: free-scan exits 1 on a zero-passing day (or zero candidates). We
# handle those below by reading the results JSON / keeping the existing config,
# so don't let set -e abort us mid-run.
FREE_SCAN_RESULTS_JSON="$RESULTS_JSON" "$SCRIPT_DIR/free-scan.sh" | tee "$PROBE_OUT" || true

if [ ! -s "$RESULTS_JSON" ]; then
  echo "synthesize: free-scan produced no results JSON — aborting." >&2
  exit 1
fi

# OpenRouter-passing subset: PASS verdict + openrouter base_url.
PASS_ARR=$(jq -c '[.results[]
                  | select((.verdict//"")|startswith("PASS"))
                  | select((.base_url//"")|contains("openrouter.ai"))
                  | .id]' "$RESULTS_JSON")

if [ "$(jq 'length' <<<"$PASS_ARR")" -eq 0 ]; then
  echo "synthesize: no OpenRouter model passed; keeping existing config." >&2
  echo "            (Multi-vendor passing models, if any, are in $RESULTS_JSON.)" >&2
  exit 1
fi
PASSING=$(jq -r '.[]' <<<"$PASS_ARR")

# --- 2. Synthesize: a free model picks the tiers ---------------------------
# Give it the full probe evidence (latency, pass/fail, errors) plus the
# OpenRouter passing list, and ask for a tiering decision as strict JSON.
EVIDENCE=$(grep -v '^===' "$PROBE_OUT" | head -60 | jq -R . | jq -s .)

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
  # Distinct tiers where the roster allows it. Sonnet used to duplicate opus
  # unconditionally, which silently dropped a working model from the config.
  H_O="${P[0]}"
  H_S="${P[1]:-${P[0]}}"
  H_H=""
  for _m in "${P[@]}"; do
    [ "$_m" != "$H_O" ] && [ "$_m" != "$H_S" ] && H_H="$_m"
  done
  [ -z "$H_H" ] && H_H="${P[${#P[@]}-1]}"
  ASSIGNMENT=$(jq -n --arg o "$H_O" --arg s "$H_S" --arg h "$H_H" \
    '{opus: $o, sonnet: $s, haiku: $h}')
fi

echo "Assignment: $ASSIGNMENT"

# Publish the OpenRouter passing order (failover list) for the smart proxy.
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
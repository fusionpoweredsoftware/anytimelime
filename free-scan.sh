#!/usr/bin/env bash
#
# free-scan.sh — discover free OpenRouter models that actually work with
# Claude Code, and emit an or.sh-compatible config.
#
# The dream: the free models are there, but finding/synthesizing/accessing
# them is the work nobody does by hand. This script does the slow head
# movement: sweep the catalog, probe each candidate, keep only what responds
# sanely, and write openrouter-free.config.json for OR_CONFIG=./or.sh use.
#
# The candidate list is DISCOVERED, not hardcoded: every $0/$0 model in the
# live catalog is a candidate, biggest context first. A hardcoded fallback
# exists only for when the catalog fetch itself fails.
#
# Verdicts are three-valued, because "it answered" and "it can do the job"
# are different claims:
#   PASS (tool)  — returned a real tool call. Claude Code can drive it.
#   WEAK (text)  — answered, but ignored the tool schema. Prose only.
#   FAIL: ...    — errored, timed out, or returned nothing.
# Only PASS models are eligible for the tier config. WEAK models are
# recorded (the blog reports them) and used only if nothing passes at all.
#
# Usage:
#   ./free-scan.sh              # discover, probe, write config
#   ./free-scan.sh --list-only  # just list free models, no probing
#
# Env:
#   FREE_SCAN_LIMIT=24   max models to probe (0 = no cap)
#   FREE_SCAN_JOBS=6     parallel probes
#   FREE_SCAN_TIMEOUT=60 per-probe curl timeout, seconds
#   FREE_SCAN_OUT=path   output config path
#
# Probe key comes from openrouter.config.json (ANTHROPIC_AUTH_TOKEN).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_CONFIG="${FREE_SCAN_OUT:-$SCRIPT_DIR/openrouter-free.config.json}"
CONFIG_IN="${OR_PROBE_CONFIG:-$SCRIPT_DIR/openrouter.config.json}"
LIMIT="${FREE_SCAN_LIMIT:-24}"
JOBS="${FREE_SCAN_JOBS:-6}"
PROBE_TIMEOUT="${FREE_SCAN_TIMEOUT:-60}"

CATALOG_URL="https://openrouter.ai/api/v1/models"

# Last-resort candidates, used only if the catalog fetch fails outright.
FALLBACK_CANDIDATES=(
  "stealth/ox-alpha"
  "z-ai/glm-5.2:free"
  "nvidia/nemotron-3-ultra-550b-a55b"
  "minimax/minimax-m3"
  "thinkingmachines/inkling:free"
  "cohere/north-mini-code:free"
  "google/gemma-4-31b-it:free"
  "openrouter/free"
)

echo "=== OpenRouter free model scan — $(date '+%Y-%m-%d %H:%M') ==="

# The catalog is public, so a catalog peek needs no key. This check used to sit
# above, which meant --list-only demanded a key it never used.
if [ "${1:-}" = "--list-only" ]; then
  curl -s -m 20 "$CATALOG_URL" \
    | jq -r '.data[] | select(.pricing.prompt == "0" and .pricing.completion == "0")
             | "\(.id)  ctx=\(.context_length)"'
  exit 0
fi

# Probing does need a key: env var wins (cron/CI/containers), then the
# gitignored config file.
KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$CONFIG_IN" ]; then
  KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$CONFIG_IN" 2>/dev/null || true)"
fi
if [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
  echo "free-scan: no OpenRouter key — set OPENROUTER_API_KEY or put" >&2
  echo "           ANTHROPIC_AUTH_TOKEN in $CONFIG_IN" >&2
  exit 1
fi

# --- 1. Discover ------------------------------------------------------------
# Every $0/$0 model in the catalog, ordered by context length descending.
# Scan order IS preference order downstream, so big context sorts first.
CANDIDATES=()
CATALOG="$(curl -s -m 20 "$CATALOG_URL" || true)"
if [ -n "$CATALOG" ] && printf '%s' "$CATALOG" | jq -e '.data' >/dev/null 2>&1; then
  while IFS= read -r m; do
    [ -n "$m" ] && CANDIDATES+=("$m")
  done < <(printf '%s' "$CATALOG" | jq -r '
    [.data[] | select(.pricing.prompt == "0" and .pricing.completion == "0")]
    | sort_by(-(.context_length // 0)) | .[].id')
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "free-scan: catalog fetch failed — falling back to built-in list." >&2
  CANDIDATES=("${FALLBACK_CANDIDATES[@]}")
fi

DISCOVERED="${#CANDIDATES[@]}"
if [ "$LIMIT" -gt 0 ] && [ "$DISCOVERED" -gt "$LIMIT" ]; then
  CANDIDATES=("${CANDIDATES[@]:0:$LIMIT}")
  echo "Discovered $DISCOVERED free models; probing top $LIMIT by context."
else
  echo "Discovered $DISCOVERED free models; probing all."
fi
echo

# --- 2. Probe ---------------------------------------------------------------
# A probe asks the model to CALL a tool. Text-only replies are recorded as
# WEAK, not PASS: Claude Code needs tool calls, and a model that can't make
# one is not a working endpoint no matter how eloquent it is.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

probe_one() {
  local model="$1" slot="$2"
  local start duration resp verdict
  start=$(python3 -c 'import time; print(time.time())')
  resp=$(curl -s -m "$PROBE_TIMEOUT" https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $KEY" \
    -H "content-type: application/json" \
    -d "$(jq -n --arg m "$model" '{
          model: $m,
          max_tokens: 2000,
          messages: [{role: "user", content: "Call the ping tool with x set to the word alive."}],
          tool_choice: "auto",
          tools: [{type: "function", function: {
            name: "ping", description: "Reply to a liveness check.",
            parameters: {type: "object",
                         properties: {x: {type: "string", description: "The word to echo back."}},
                         required: ["x"]}}}]
        }')" || true)
  duration=$(python3 -c "import time; print(f'{time.time() - $start:.1f}s')")

  verdict=$(printf '%s' "$resp" | jq -r '
    if (. == null) or (. == {}) then "FAIL: no response"
    elif .error then "FAIL: \(.error.message // .error.code // "error" | tostring | .[0:80])"
    elif ((.choices[0].message.tool_calls // []) | length) > 0 then "PASS (tool)"
    elif ((.choices[0].message.content // "" | length) > 0) then "WEAK (text, no tool)"
    else "FAIL: empty response"
    end' 2>/dev/null || echo "FAIL: unparseable")

  # One record per model: stdout block for humans, TSV for machines.
  {
    printf '%s  %s\n' "$duration" "$model"
    printf '    %s\n' "$verdict"
  } > "$WORK_DIR/out.$slot"
  printf '%s\t%s\t%s\n' "${duration%s}" "$model" "$verdict" > "$WORK_DIR/tsv.$slot"
}

slot=0
for m in "${CANDIDATES[@]}"; do
  probe_one "$m" "$(printf '%04d' "$slot")" &
  slot=$((slot + 1))
  # Bound concurrency: free tiers rate-limit hard if you stampede them.
  # Batch barrier rather than `wait -n` — macOS still ships bash 3.2, where
  # `wait -n` does not exist and a silent fallthrough means a stampede.
  if [ $((slot % JOBS)) -eq 0 ]; then wait; fi
done
wait

# Emit in discovery order, not completion order — preference order matters.
for f in "$WORK_DIR"/out.*; do [ -f "$f" ] && cat "$f"; done
RESULTS_TSV="$WORK_DIR/all.tsv"
: > "$RESULTS_TSV"
for f in "$WORK_DIR"/tsv.*; do [ -f "$f" ] && cat "$f" >> "$RESULTS_TSV"; done

# --- 3. Rank ----------------------------------------------------------------
# PASS models only, still in preference (context-descending) order.
PASSING=()
while IFS= read -r m; do
  [ -n "$m" ] && PASSING+=("$m")
done < <(awk -F'\t' '$3 ~ /^PASS/ {print $2}' "$RESULTS_TSV")

WEAK=()
while IFS= read -r m; do
  [ -n "$m" ] && WEAK+=("$m")
done < <(awk -F'\t' '$3 ~ /^WEAK/ {print $2}' "$RESULTS_TSV")

TIER_SOURCE="tool-capable"
if [ "${#PASSING[@]}" -eq 0 ] && [ "${#WEAK[@]}" -gt 0 ]; then
  echo >&2
  echo "free-scan: WARNING — no model made a tool call today." >&2
  echo "           Falling back to text-only models; expect Claude Code to" >&2
  echo "           struggle with agentic work on this roster." >&2
  PASSING=("${WEAK[@]}")
  TIER_SOURCE="text-only (degraded)"
fi

echo
echo "=== Passing: ${#PASSING[@]} ==="
if [ "${#PASSING[@]}" -gt 0 ]; then
  printf '  %s\n' "${PASSING[@]}"
else
  printf '  %s\n' "<none>"
fi

if [ "${#PASSING[@]}" -eq 0 ]; then
  echo
  echo "No models passed — not writing config." >&2
  exit 1
fi

# Tiering heuristic (synthesize.sh replaces this with a model's judgment):
#   OPUS/SONNET = first passing model — biggest context, does the real work.
#   HAIKU       = fastest passing model, measured. Background duty is a
#                 latency job, so pick on the number we actually recorded.
OPUS="${PASSING[0]}"
SONNET="${PASSING[0]}"
HAIKU="$(awk -F'\t' '$3 ~ /^PASS/ {print $1"\t"$2}' "$RESULTS_TSV" \
         | sort -n | head -1 | cut -f2)"
[ -z "$HAIKU" ] && HAIKU="${PASSING[${#PASSING[@]}-1]}"

jq -n \
  --arg key "$KEY" \
  --arg opus "$OPUS" --arg sonnet "$SONNET" --arg haiku "$HAIKU" \
  '{
    ANTHROPIC_AUTH_TOKEN: $key,
    ANTHROPIC_BASE_URL: "https://openrouter.ai/api",
    ANTHROPIC_DEFAULT_OPUS_MODEL: $opus,
    ANTHROPIC_DEFAULT_SONNET_MODEL: $sonnet,
    ANTHROPIC_DEFAULT_HAIKU_MODEL: $haiku,
    API_TIMEOUT_MS: "3000000",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
  }' > "$OUT_CONFIG"

echo
echo "Wrote $OUT_CONFIG (tiers from $TIER_SOURCE models):"
jq '{ANTHROPIC_BASE_URL, ANTHROPIC_DEFAULT_OPUS_MODEL, ANTHROPIC_DEFAULT_SONNET_MODEL, ANTHROPIC_DEFAULT_HAIKU_MODEL}' "$OUT_CONFIG"
echo
echo "Launch with:  OR_CONFIG=$OUT_CONFIG ./or.sh"

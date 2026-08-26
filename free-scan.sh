#!/usr/bin/env bash
#
# free-scan.sh — probe free AI endpoints across the INTERNET and emit an
# or.sh-compatible config.
#
# The candidate list comes from research.sh (candidates.json): a web-search
# sweep of free OpenAI-compatible endpoints, plus a deterministic keyless
# catalog floor. Each record names a model, its base_url, and whether it
# needs a key. This script probes each one with a real tool call and keeps
# only what responds sanely.
#
# It is still OpenRouter-shaped where it has to be: openrouter-free.config.json
# (consumed by or.sh / lime.sh) is written from the OPENROUTER-passing subset
# only, because those launchers hardcode ANTHROPIC_BASE_URL=openrouter. The
# full multi-vendor roster goes into the results JSON (FREE_SCAN_RESULTS_JSON)
# for blog-gen to publish in latest.json. Cross-vendor serving is Phase E.
#
# Verdicts are three-valued, because "it answered" and "it can do the job"
# are different claims:
#   PASS (tool)      — returned a real tool call. Claude Code can drive it.
#   WEAK (text)      — answered, but ignored the tool schema. Prose only.
#   FAIL: ...        — errored, timed out, or returned nothing.
#   FAIL: needs key  — vendor requires a key we don't have on file; not probed.
# Only PASS models are eligible for the tier config. WEAK models are recorded
# (the blog reports them) and used only if nothing passes at all.
#
# Usage:
#   ./free-scan.sh              # discover, probe, write config + results JSON
#   ./free-scan.sh --list-only  # just list candidates, no probing
#
# Env:
#   CANDIDATES_FILE=path   input candidates.json (default $SCRIPT_DIR/candidates.json)
#   KEYS_CONFIG=path       gitignored JSON mapping key_env -> key (default
#                          $SCRIPT_DIR/keys.config.json)
#   FREE_SCAN_LIMIT=24     max models to probe (0 = no cap)
#   FREE_SCAN_JOBS=6       parallel probes
#   FREE_SCAN_TIMEOUT=60   per-probe curl timeout, seconds
#   FREE_SCAN_OUT=path     output OpenRouter-subset config path
#   FREE_SCAN_RESULTS_JSON=path   write full multi-vendor results JSON here
#   OPENROUTER_API_KEY     OpenRouter key (or ANTHROPIC_AUTH_TOKEN in
#                          openrouter.config.json). <VENDOR>_API_KEY for others.
#
# If candidates.json is absent, falls back to the OpenRouter catalog discovery
# (the original single-vendor path), so this still works before research.sh
# has ever run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_CONFIG="${FREE_SCAN_OUT:-$SCRIPT_DIR/openrouter-free.config.json}"
CONFIG_IN="${OR_PROBE_CONFIG:-$SCRIPT_DIR/openrouter.config.json}"
CANDIDATES_FILE="${CANDIDATES_FILE:-$SCRIPT_DIR/candidates.json}"
KEYS_CONFIG="${KEYS_CONFIG:-$SCRIPT_DIR/keys.config.json}"
LIMIT="${FREE_SCAN_LIMIT:-24}"
JOBS="${FREE_SCAN_JOBS:-6}"
PROBE_TIMEOUT="${FREE_SCAN_TIMEOUT:-60}"
RESULTS_JSON="${FREE_SCAN_RESULTS_JSON:-}"

CATALOG_URL="https://openrouter.ai/api/v1"
OR_CHAT="https://openrouter.ai/api/v1/chat/completions"

# Last-resort candidates, used only if candidates.json is absent AND the
# catalog fetch fails outright.
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

# OpenRouter key — needed to probe OpenRouter candidates and to write the
# OpenRouter-subset config. Env var wins (cron/CI/containers), then the
# gitignored config file. May be empty: keyless candidates still get probed.
OR_KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$OR_KEY" ] && [ -f "$CONFIG_IN" ]; then
  OR_KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$CONFIG_IN" 2>/dev/null || true)"
fi
[ "$OR_KEY" = "null" ] && OR_KEY=""

# Resolve a key for a candidate by key_env: env var first, then keys.config.json,
# then (for OpenRouter) the OR key from openrouter.config.json. Echoes the key
# or empty. Runs in the main shell so it can see OR_KEY; the result is passed
# into probe_one as an argument so background subshells don't need exports.
resolve_key() { # resolve_key <key_env>
  local envname="$1" v
  [ -z "$envname" ] || [ "$envname" = "null" ] && return 0
  v="$(printenv "$envname" 2>/dev/null || true)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  if [ -f "$KEYS_CONFIG" ]; then
    v="$(jq -r --arg k "$envname" '.[$k] // empty' "$KEYS_CONFIG" 2>/dev/null || true)"
    [ -n "$v" ] && [ "$v" != "null" ] && { printf '%s' "$v"; return 0; }
  fi
  if [ "$envname" = "OPENROUTER_API_KEY" ] && [ -n "$OR_KEY" ]; then
    printf '%s' "$OR_KEY"; return 0
  fi
}

echo "=== free model scan — $(date '+%Y-%m-%d %H:%M') ==="

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- 1. Discover ------------------------------------------------------------
# Build a candidate table: id \t vendor \t base_url \t needs_key \t key_env \t source
CAND_TSV="$WORK_DIR/candidates.tsv"
: > "$CAND_TSV"

add_cand() { # add_cand <id> <vendor> <base_url> <needs_key> <key_env> <source>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$CAND_TSV"
}

if [ -f "$CANDIDATES_FILE" ] && jq -e 'type == "array" and length > 0' "$CANDIDATES_FILE" >/dev/null 2>&1; then
  # Multi-vendor candidates from research.sh. needs_key may be bool or absent;
  # key_env may be null.
  while IFS=$'\t' read -r id vendor base needs keyenv src; do
    [ -n "$id" ] && add_cand "$id" "$vendor" "$base" "$needs" "$keyenv" "$src"
  done < <(jq -r '.[] | [.id, .vendor, .base_url, (.needs_key|tostring), (.key_env|tostring), (.source//"catalog")] | @tsv' "$CANDIDATES_FILE")
  echo "Discovered $(wc -l < "$CAND_TSV" | tr -d ' ') candidates from $CANDIDATES_FILE."
else
  # Fallback: the original OpenRouter-catalog discovery path. Synthesize
  # OpenRouter records (probing OpenRouter needs the OR key).
  echo "free-scan: no candidates.json — discovering from the OpenRouter catalog." >&2
  CATALOG="$(curl -s -m 20 "$CATALOG_URL" || true)"
  if [ -n "$CATALOG" ] && printf '%s' "$CATALOG" | jq -e '.data' >/dev/null 2>&1; then
    while IFS= read -r m; do
      [ -n "$m" ] && add_cand "$m" openrouter "https://openrouter.ai/api/v1" true OPENROUTER_API_KEY catalog
    done < <(printf '%s' "$CATALOG" | jq -r '
      [.data[] | select(.pricing.prompt == "0" and .pricing.completion == "0")]
      | sort_by(-(.context_length // 0)) | .[].id')
  else
    echo "free-scan: catalog fetch failed — falling back to built-in list." >&2
    for m in "${FALLBACK_CANDIDATES[@]}"; do
      add_cand "$m" openrouter "https://openrouter.ai/api/v1" true OPENROUTER_API_KEY fallback
    done
  fi
fi

if [ "${1:-}" = "--list-only" ]; then
  awk -F'\t' '{ printf "%-42s  %-14s  %s  key=%s\n", $1, $2, $3, $4 }' "$CAND_TSV"
  exit 0
fi

DISCOVERED="$(wc -l < "$CAND_TSV" | tr -d ' ')"
if [ "$DISCOVERED" -eq 0 ]; then
  echo "free-scan: no candidates found anywhere — nothing to probe." >&2
  exit 1
fi
if [ "$LIMIT" -gt 0 ] && [ "$DISCOVERED" -gt "$LIMIT" ]; then
  head -n "$LIMIT" "$CAND_TSV" > "$CAND_TSV.tmp" && mv "$CAND_TSV.tmp" "$CAND_TSV"
  echo "Probing top $LIMIT of $DISCOVERED candidates."
else
  echo "Probing all $DISCOVERED candidates."
fi
echo

# --- 2. Probe ---------------------------------------------------------------
# A probe asks the model to CALL a tool. Text-only replies are recorded as
# WEAK, not PASS: Claude Code needs tool calls, and a model that can't make
# one is not a working endpoint no matter how eloquent it is.
probe_one() { # probe_one <id> <base_url> <key> <slot> <vendor>
  local model="$1" base="$2" key="$3" slot="$4" vendor="$5"
  local url start duration resp verdict
  printf '  → probing %s [%s]\n' "$model" "$vendor" >&2
  # Normalize base_url -> .../chat/completions
  base="${base%/}"
  case "$base" in
    */chat/completions) url="$base" ;;
    *) url="$base/chat/completions" ;;
  esac
  start=$(python3 -c 'import time; print(time.time())')
  if [ -n "$key" ]; then
    resp=$(curl -s -m "$PROBE_TIMEOUT" "$url" \
      -H "Authorization: Bearer $key" \
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
  else
    resp=$(curl -s -m "$PROBE_TIMEOUT" "$url" \
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
  fi
  duration=$(python3 -c "import time; print(f'{time.time() - $start:.1f}s')")

  verdict=$(printf '%s' "$resp" | jq -r '
    if (. == null) or (. == {}) then "FAIL: no response"
    elif .error then "FAIL: \(.error.message // .error.code // "error" | tostring | .[0:80])"
    elif ((.choices[0].message.tool_calls // []) | length) > 0 then "PASS (tool)"
    elif ((.choices[0].message.content // "" | length) > 0) then "WEAK (text, no tool)"
    else "FAIL: empty response"
    end' 2>/dev/null || echo "FAIL: unparseable")
  printf '  ← %s: %s (%s)\n' "$model" "$verdict" "$duration" >&2

  {
    printf '%s  %s\n' "$duration" "$model"
    printf '    %s\n' "$verdict"
  } > "$WORK_DIR/out.$slot"
  printf '%s\t%s\t%s\n' "${duration%s}" "$model" "$verdict" > "$WORK_DIR/tsv.$slot"
}

# Resolve keys up front (main shell), then launch probes. Candidates that
# need a key we don't have are recorded as FAIL: needs key — not probed.
slot=0
NEEDS_KEY_TSV="$WORK_DIR/needskey.tsv"
: > "$NEEDS_KEY_TSV"
while IFS=$'\t' read -r id vendor base needs keyenv src; do
  [ -z "$id" ] && continue
  sl="$(printf '%04d' "$slot")"
  slot=$((slot + 1))
  if [ "$needs" = "true" ]; then
    k="$(resolve_key "$keyenv" || true)"
    if [ -z "$k" ]; then
      printf '%s\t%s\tFAIL: needs key\n' "—" "$id" >> "$NEEDS_KEY_TSV"
      { printf '%s  %s\n' "—" "$id"; printf '    FAIL: needs key (%s)\n' "$vendor"; } > "$WORK_DIR/out.$sl"
      printf '  − %s: FAIL: needs key (%s)\n' "$id" "$vendor" >&2
      continue
    fi
  else
    k=""
  fi
  probe_one "$id" "$base" "$k" "$sl" "$vendor" &
  if [ $((slot % JOBS)) -eq 0 ]; then wait; fi
done < "$CAND_TSV"
wait

# Emit in discovery order, not completion order — preference order matters.
for f in "$WORK_DIR"/out.*; do [ -f "$f" ] && cat "$f"; done
RESULTS_TSV="$WORK_DIR/all.tsv"
: > "$RESULTS_TSV"
for f in "$WORK_DIR"/tsv.*; do [ -f "$f" ] && cat "$f" >> "$RESULTS_TSV"; done
[ -f "$NEEDS_KEY_TSV" ] && cat "$NEEDS_KEY_TSV" >> "$RESULTS_TSV"

# --- 3. Rank ----------------------------------------------------------------
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

# --- 4. Results JSON (full multi-vendor roster) -----------------------------
# blog-gen reads this to publish latest.json. Built by joining the candidate
# table with the probe TSV so every record carries vendor/base_url/source.
if [ -n "$RESULTS_JSON" ]; then
  PASS_F="$WORK_DIR/passing.json"; WEAK_F="$WORK_DIR/weak.json"
  if [ "${#PASSING[@]}" -eq 0 ]; then echo '[]' > "$PASS_F"
  else printf '%s\n' "${PASSING[@]}" | jq -R . | jq -s . > "$PASS_F"; fi
  if [ "${#WEAK[@]}" -eq 0 ]; then echo '[]' > "$WEAK_F"
  else printf '%s\n' "${WEAK[@]}" | jq -R . | jq -s . > "$WEAK_F"; fi
  python3 - "$CAND_TSV" "$RESULTS_TSV" "$PASS_F" "$WEAK_F" <<'PYEOF' > "$RESULTS_JSON.tmp"
import json, sys
cands, res = {}, {}
order = []
for line in open(sys.argv[1]):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 6 and p[0]:
        cands[p[0]] = {"id":p[0],"vendor":p[1],"base_url":p[2],
                       "needs_key":p[3]=="true",
                       "key_env":None if p[4]=="null" else p[4],
                       "source":p[5]}
        order.append(p[0])
for line in open(sys.argv[2]):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 3 and p[1]:
        res[p[1]] = {"latency":p[0], "verdict":p[2]}
out = []
for cid in order:
    c = cands[cid]
    r = res.get(cid, {})
    out.append({**c, "latency": r.get("latency",""), "verdict": r.get("verdict","FAIL: not probed")})
print(json.dumps({"updated": None, "probed": len(out),
                  "passing": json.load(open(sys.argv[3])),
                  "weak": json.load(open(sys.argv[4])),
                  "results": out}))
PYEOF
  mv -f "$RESULTS_JSON.tmp" "$RESULTS_JSON"
  echo "Wrote results JSON: $RESULTS_JSON ($(jq '.results|length' "$RESULTS_JSON") records)"
fi

# --- 5. OpenRouter-subset tier config (or.sh / lime.sh backward compat) -----
# The config is OpenRouter-only (launchers hardcode ANTHROPIC_BASE_URL).
# Tier from the OpenRouter-passing subset; if none passed, skip the config so
# synthesize/blog-gen can decide what to do (keep existing / degraded report).
# Re-derive OpenRouter passing by joining base_url from the candidate table.
OR_PASSING=()
while IFS= read -r m; do
  [ -n "$m" ] && OR_PASSING+=("$m")
done < <(awk -F'\t' 'NR==FNR{ if($3 ~ /openrouter\.ai/) or[$1]=1; next } ($3 ~ /^PASS/){ if(or[$2]) print $2 }' "$CAND_TSV" "$RESULTS_TSV")

if [ "${#OR_PASSING[@]}" -eq 0 ]; then
  echo
  echo "No OpenRouter model passed — not writing OpenRouter config." >&2
  echo "(Multi-vendor passing models, if any, are in the results JSON.)" >&2
  [ "${#PASSING[@]}" -eq 0 ] && exit 1
  exit 0
fi

if [ -z "$OR_KEY" ]; then
  echo "free-scan: OpenRouter models passed but no OR key on file to write config." >&2
  exit 0
fi

# Tiering heuristic (synthesize.sh replaces this with a model's judgment):
#   OPUS   = first OpenRouter passing model (biggest context — scan order).
#   SONNET = the NEXT OpenRouter passing model, so work tiers differ.
#   HAIKU  = fastest OpenRouter passing model, preferring one not already used.
OPUS="${OR_PASSING[0]}"
SONNET="${OR_PASSING[1]:-${OR_PASSING[0]}}"

# Fastest OpenRouter passing model, by measured latency (background duty is a
# latency job). Built from the OpenRouter-passing subset only.
OR_LAT="$WORK_DIR/or-lat.tsv"; : > "$OR_LAT"
for m in "${OR_PASSING[@]}"; do
  awk -F'\t' -v want="$m" '$2==want && $3 ~ /^PASS/ {print $1"\t"$2}' "$RESULTS_TSV" >> "$OR_LAT"
done
FASTEST_FIRST="$(sort -n "$OR_LAT" | cut -f2)"
HAIKU=""
while IFS= read -r m; do
  [ -z "$m" ] && continue
  if [ "$m" != "$OPUS" ] && [ "$m" != "$SONNET" ]; then HAIKU="$m"; break; fi
done <<< "$FASTEST_FIRST"
[ -z "$HAIKU" ] && HAIKU="$(printf '%s\n' "$FASTEST_FIRST" | head -1)"
[ -z "$HAIKU" ] && HAIKU="${OR_PASSING[${#OR_PASSING[@]}-1]}"

jq -n \
  --arg key "$OR_KEY" \
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
echo "Wrote $OUT_CONFIG (OpenRouter tiers from $TIER_SOURCE models):"
jq '{ANTHROPIC_BASE_URL, ANTHROPIC_DEFAULT_OPUS_MODEL, ANTHROPIC_DEFAULT_SONNET_MODEL, ANTHROPIC_DEFAULT_HAIKU_MODEL}' "$OUT_CONFIG"
echo
echo "Launch with:  OR_CONFIG=$OUT_CONFIG ./or.sh"
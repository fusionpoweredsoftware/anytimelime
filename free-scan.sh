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

# Call meter (see research.sh's log_call): when ANYTIMELIME_CALL_LOG is set,
# every probe appends one JSONL line — vendor, model, key NAME + fingerprint
# (never the value), duration, verdict. Off unless the caller opts in.
log_call() { # log_call <kind> <vendor> <model> <key_env|-> <key_fp|-> <duration_s> <note>
  [ -n "${ANYTIMELIME_CALL_LOG:-}" ] || return 0
  printf '{"t":"%s","kind":%s,"vendor":%s,"model":%s,"key_env":%s,"key_fp":%s,"dur_s":"%s","note":%s}\n' \
    "$(date -u +%FT%TZ)" "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" \
    "$(printf '%s' "$3" | jq -Rs .)" "$(printf '%s' "$4" | jq -Rs .)" "$(printf '%s' "$5" | jq -Rs .)" \
    "$6" "$(printf '%s' "$7" | jq -Rs .)" >> "$ANYTIMELIME_CALL_LOG" 2>/dev/null || true
}
key_fp() { # key_fp <key-value> — first 8 hex of sha256, or "-" for empty
  [ -n "${1:-}" ] || { echo "-"; return; }
  printf '%s' "$1" | shasum -a 256 | cut -c1-8
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- 1. Discover ------------------------------------------------------------
# Build a candidate table: id \t vendor \t base_url \t needs_key \t key_env \t source \t docs
CAND_TSV="$WORK_DIR/candidates.tsv"
: > "$CAND_TSV"

add_cand() { # add_cand <id> <vendor> <base_url> <needs_key> <key_env> <source> <docs>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}" >> "$CAND_TSV"
}

if [ -f "$CANDIDATES_FILE" ] && jq -e 'type == "array" and length > 0' "$CANDIDATES_FILE" >/dev/null 2>&1; then
  # Multi-vendor candidates from research.sh. needs_key may be bool or absent;
  # key_env may be null.
  while IFS=$'\t' read -r id vendor base needs keyenv src docs; do
    [ -n "$id" ] && add_cand "$id" "$vendor" "$base" "$needs" "$keyenv" "$src" "${docs:-}"
  done < <(jq -r '.[] | [.id, .vendor, .base_url, (.needs_key|tostring), (.key_env|tostring), (.source//"catalog"), (.docs // "")] | @tsv' "$CANDIDATES_FILE")
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
# Fair-share before the LIMIT cut: candidates arrive grouped by vendor (the
# floor fetches one catalog at a time), so a naive head -N gives the whole
# probe budget to whichever vendor sorts first. Round-robin by vendor instead
# — every vendor alternates, and a 60-model catalog can't starve the rest.
# (POSIX awk: 2-D via SUBSEP, no arrays-of-arrays — macOS awk lacks them.)
awk -F'\t' -v d=99999 \
  '{ if (!seen[$2]++) order[++nv]=$2; n[$2]++; rows[$2, n[$2]]=$0 }
   END { for (i=1;i<=d;i++) for (v=1;v<=nv;v++) { k=order[v] SUBSEP i
           if (k in rows) print rows[k] } }' \
  "$CAND_TSV" > "$CAND_TSV.tmp" && mv "$CAND_TSV.tmp" "$CAND_TSV"
if [ "$LIMIT" -gt 0 ] && [ "$DISCOVERED" -gt "$LIMIT" ]; then
  head -n "$LIMIT" "$CAND_TSV" > "$CAND_TSV.tmp" && mv "$CAND_TSV.tmp" "$CAND_TSV"
  echo "Probing top $LIMIT of $DISCOVERED candidates."
else
  echo "Probing all $DISCOVERED candidates."
fi
echo

# --- 1b. Ask for missing vendor keys (interactive runs only) -----------------
# Keyless candidates always proceed regardless. For candidates that need a key
# we can't resolve, ask ONCE per distinct key_env at a terminal; Enter skips
# that vendor's route and the run continues with everything else. Accepted keys
# go into keys.config.json (gitignored) so this ask happens once, ever. Non-tty
# runs (cron) never prompt — they just note what was skipped.
#
# signup_url: where a human gets the key this prompt asks for. These vendors'
# free tiers need an account; the URL is printed with the prompt so "wtf does
# this mean" is answered in place.
signup_url() { # signup_url <key_env>
  case "$1" in
    GROQ_API_KEY)      echo "https://console.groq.com/keys" ;;
    CEREBRAS_API_KEY)  echo "https://cloud.cerebras.ai" ;;
    CLOUDFLARE_API_KEY) echo "https://dash.cloudflare.com/profile/api-tokens" ;;
    TOGETHER_API_KEY)  echo "https://api.together.ai/settings/api-keys" ;;
    NVIDIA_API_KEY)    echo "https://build.nvidia.com" ;;
    SAMBANOVA_API_KEY) echo "https://cloud.sambanova.ai/apis" ;;
    HF_TOKEN)          echo "https://huggingface.co/settings/tokens" ;;
    POLLINATIONS_API_KEY) echo "https://enter.pollinations.ai/key" ;;
    OPENROUTER_API_KEY) echo "https://openrouter.ai/keys" ;;
    *) echo "" ;;
  esac
}
MISSING_ENVS=""
while IFS= read -r _e; do
  [ -z "$(resolve_key "$_e" || true)" ] && MISSING_ENVS="$_e
$MISSING_ENVS"
done < <(awk -F'\t' '$4=="true" && $5!="" && $5!="null" {print $5}' "$CAND_TSV" | sort -u)

# A controlling terminal is enough — prompts read AND write /dev/tty directly,
# so this still asks when run under blog-gen (which pipes stdout/stderr). Cron
# has no controlling tty: the /dev/tty open fails and we take the note-and-
# continue path instead.
ASK_TTY=0
if [ -n "$MISSING_ENVS" ] && exec 3<>/dev/tty 2>/dev/null; then
  ASK_TTY=1
fi
if [ "$ASK_TTY" = 1 ]; then
  TOTAL_MISSING="$(printf '%s' "$MISSING_ENVS" | grep -c . || true)"
  NTH=0
  while IFS= read -r envname; do
    [ -z "$envname" ] && continue
    NTH=$((NTH + 1))
    vendor="$(awk -F'\t' -v e="$envname" '$5==e {print $2; exit}' "$CAND_TSV")"
    n_models="$(awk -F'\t' -v e="$envname" '$5==e' "$CAND_TSV" | wc -l | tr -d ' ')"
    url="$(signup_url "$envname")"
    echo >&3
    echo "free-scan: [$NTH/$TOTAL_MISSING] research found $n_models '$vendor' model(s)." >&3
    echo "  Their free tier requires an API key (a free account's key — not paid credit)." >&3
    if [ -n "$url" ]; then
      echo "  Get one at: $url" >&3
    fi
    echo "  Paste a $envname to probe $vendor's models, or press Enter to skip them" >&3
    echo "  (skipped models are reported as 'needs key'; everything else still runs)." >&3
    while :; do
      printf '  %s: ' "$envname" >&3
      # Read char-by-char with '*' feedback: a fully silent prompt (-rs) makes
      # a paste look like it didn't land. Backspace erases, Enter submits.
      ans=""
      _ok=1
      while IFS= read -r -n 1 -s _c <&3; do
        if [ -z "$_c" ]; then break; fi               # Enter pressed
        if [ "$_c" = $'\177' ] || [ "$_c" = $'\b' ]; then
          [ -n "$ans" ] && { ans="${ans%?}"; printf '\b \b' >&3; }
          continue
        fi
        ans="$ans$_c"
        printf '*' >&3
      done || _ok=0
      # _c holds the Enter; if the read loop died with no terminator (EOF /
      # no input at all), treat as skip.
      if [ "$_ok" = 0 ] && [ -z "$ans" ]; then
        echo >&3; echo "  no input available — skipping $vendor." >&3
        break
      fi
      echo >&3
      if [ -z "$ans" ]; then
        echo "  skipped — $vendor candidates will be recorded as FAIL: needs key." >&3
        break
      fi
      case "$ans" in *PLACEHOLDER*|*YOUR*KEY*|*PASTE*|*sk-or-PLACEHOLDER*)
        echo "  that's a placeholder, not a real key — try again." >&3; continue ;; esac
      if [ "${#ans}" -lt 8 ]; then
        echo "  too short to be a key — try again." >&3; continue
      fi
      umask 077
      if [ -f "$KEYS_CONFIG" ]; then
        jq --arg k "$envname" --arg v "$ans" '.[$k]=$v' "$KEYS_CONFIG" \
          > "$KEYS_CONFIG.tmp" && mv "$KEYS_CONFIG.tmp" "$KEYS_CONFIG"
      else
        jq -n --arg k "$envname" --arg v "$ans" '{($k):$v}' > "$KEYS_CONFIG"
      fi
      chmod 600 "$KEYS_CONFIG"
      echo "  saved to $KEYS_CONFIG (gitignored) — won't ask for this one again." >&3
      break
    done
  done <<< "$MISSING_ENVS"
elif [ -n "$MISSING_ENVS" ]; then
  echo "free-scan: non-interactive — no key on file for: $(printf '%s' "$MISSING_ENVS" | tr '\n' ' ')(those routes are skipped; keyless candidates proceed)."
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
  log_call probe "$vendor" "$model" "$KEY_ENV_LABEL" "$(key_fp "$key")" "$duration" "$verdict"

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
while IFS=$'\t' read -r id vendor base needs keyenv src docs; do
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
  case "$keyenv" in ""|null) KEY_ENV_LABEL="-" ;; *) KEY_ENV_LABEL="$keyenv" ;; esac
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
                       "source":p[5],
                       "docs":(p[6] if len(p)>6 and p[6] else None)}
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

  # --- 4.5 FE meter integration (1 FE gauge for PASSING models) ---
  # Run the independent-research FE meter on each PASSING model to add fe_reading.
  # This is a lightweight scan: 1 run, 2k length only. Full calibration is separate.
  if [ "${#PASSING[@]}" -gt 0 ]; then
    echo
    echo "[FE meter] gauging PASSING models for 1 FE (Fidelity-Enough)..."
    python3 "$SCRIPT_DIR/fe-postprocess.py" "$RESULTS_JSON"
    echo "[FE meter] added fe_reading to PASSING models in $RESULTS_JSON"
  fi
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
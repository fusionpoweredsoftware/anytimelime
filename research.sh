#!/usr/bin/env bash
#
# research.sh — discover free AI endpoints across the internet.
#
# The purpose of anytimelime is to probe the INTERNET for free AI, not just
# OpenRouter. This step finds candidates; the probe (free-scan.sh) verifies
# them. The cloud model with web search (glm-5.2:cloud via the razzle-dazzle
# gateway) powers the research, and a deterministic keyless-catalog fetch is the
# reproducible floor that catches what the model misses — and ships when the
# model is unreachable. AI finds candidates; the probe decides what's real.
#
# Output: candidates.json — a flat per-model list. Each record:
#   {id, vendor, base_url, needs_key, key_env, source}
# id        model id to send in the `model` field
# base_url  OpenAI-compatible root (e.g. https://api.groq.com/openai/v1)
# needs_key false = probe with no auth; true = probe needs the vendor's key
# key_env   env var name for that key (never the value), or null
# docs      URL of the endpoint's documentation, or null (community members)
# source    "catalog" (deterministic fetch) | "research" (model found it)
#
# Env:
#   RESEARCH_BASE_URL  default http://localhost:8020  (razzle-dazzle gateway)
#   RESEARCH_MODEL     default glm-5.2:cloud
#   RESEARCH_KEY       default "" (gateway may not require auth)
#   CANDIDATES_FILE    default $SCRIPT_DIR/candidates.json
#
# Usage:
#   ./research.sh              # floor + model research
#   ./research.sh --floor-only # deterministic catalogs only, no model call

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${RESEARCH_BASE_URL:-http://localhost:8020}"
MODEL="${RESEARCH_MODEL:-glm-5.2:cloud}"
KEY="${RESEARCH_KEY:-}"
OUT="${CANDIDATES_FILE:-$SCRIPT_DIR/candidates.json}"
FLOOR_ONLY=0
FORCE=0
for _a in "$@"; do
  case "$_a" in
    --floor-only) FLOOR_ONLY=1 ;;
    --force)      FORCE=1 ;;
    *) echo "research: unknown flag '$_a'" >&2; exit 2 ;;
  esac
done

# Reuse window: if candidates.json was written less than RESEARCH_TTL seconds
# ago, skip everything and hand the fresh list back as-is. Re-running blog-gen
# (or setup, or a manual retry) within the hour must not re-pay the research
# cost in time or tokens. --force ignores the window.
TTL="${RESEARCH_TTL:-3600}"
if [ "$FORCE" = 0 ] && [ "$FLOOR_ONLY" = 0 ] && [ -f "$OUT" ] \
   && jq -e 'type == "array" and length > 0' "$OUT" >/dev/null 2>&1; then
  AGE=$(( $(date +%s) - $(stat -f %m "$OUT" 2>/dev/null || stat -c %Y "$OUT") ))
  if [ "$AGE" -lt "$TTL" ]; then
    echo "research: candidates.json is ${AGE}s old (< ${TTL}s) — reusing it, no re-research. Use --force to override."
    exit 0
  fi
  echo "research: candidates.json is ${AGE}s old (>= ${TTL}s) — refreshing."
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"
  [ -n "${DASH_PID:-}" ] && kill "$DASH_PID" 2>/dev/null
  [ -n "${FREE_GATEWAY_PID:-}" ] && kill "$FREE_GATEWAY_PID" 2>/dev/null
  [ -n "${ORPROXY_PID:-}" ] && kill "$ORPROXY_PID" 2>/dev/null
  true' EXIT

atomic_mv() { local dest="$1" tmp="${1}.tmp.$$"; cat > "$tmp" && mv -f "$tmp" "$dest"; }

# --- 1. Deterministic floor: keyless public catalogs ------------------------
# OpenRouter's catalog is public (no key); local Ollama is keyless. These are
# the reproducible candidates the model research layers on top of, and the
# safety net when the model is down.
floor="$WORK/floor.json"; echo '[]' > "$floor"

add_floor() { # add_floor <vendor> <base_url> <needs_key> <key_env> <ids...>
  local vendor="$1" base="$2" needs="$3" keyenv="$4"; shift 4
  for id in "$@"; do
    [ -z "$id" ] && continue
    jq -c --arg id "$id" --arg v "$vendor" --arg b "$base" \
          --argjson n "$needs" --argjson ke "$keyenv" \
      '. + [{id:$id, vendor:$v, base_url:$b, needs_key:$n, key_env:$ke, source:"catalog"}]' \
      "$floor" > "$floor.tmp" && mv "$floor.tmp" "$floor"
  done
}

# OpenRouter free catalog. The catalog LIST is public (no key), but probing
# /chat/completions requires a Bearer key — so these candidates are
# needs_key=true with key_env=OPENROUTER_API_KEY. Listing keyless ≠ calling
# keyless.
OR_CATALOG="$(curl -s -m 20 https://openrouter.ai/api/v1/models || true)"
if printf '%s' "$OR_CATALOG" | jq -e '.data' >/dev/null 2>&1; then
  while IFS= read -r m; do
    [ -n "$m" ] && add_floor openrouter "https://openrouter.ai/api/v1" true '"OPENROUTER_API_KEY"' "$m"
  done < <(printf '%s' "$OR_CATALOG" | jq -r \
    '.data[] | select(.pricing.prompt == "0" and .pricing.completion == "0") | .id')
fi

# Local Ollama (keyless). OFF by default: these are models on the operator's
# own machine, not "the internet", and probing them loads + runs them locally
# (heavy). Set INCLUDE_LOCAL_OLLAMA=1 to add them as candidates — e.g. when
# you deliberately want to verify a local model works with the probe. Skip
# remote/cloud-pulled models (remote_host set) — those are paid, not free.
if [ "${INCLUDE_LOCAL_OLLAMA:-0}" = "1" ]; then
  OL_TAGS="$(curl -s -m 10 http://localhost:11434/api/tags || true)"
  if printf '%s' "$OL_TAGS" | jq -e '.models' >/dev/null 2>&1; then
    while IFS= read -r m; do
      [ -n "$m" ] && add_floor ollama-local "http://localhost:11434/v1" false null "$m"
    done < <(printf '%s' "$OL_TAGS" | jq -r \
      '.models[] | select((.remote_model // "") == "") | .name')
  fi
fi
echo "research: deterministic floor: $(jq 'length' "$floor") candidates"

# --- 2. Model research: FREE models first; paid cloud only if they fail -----
# A model suggests candidate endpoints beyond the floor; the probe verifies
# every suggestion for real, so a wrong guess just fails a probe. Policy: try
# FREE models for this call first; the paid cloud model (glm-5.2:cloud via the
# razzle-dazzle gateway, which adds web search) runs ONLY when every free
# route fails. Failure is non-fatal — the floor still ships.
research="$WORK/research.json"; echo '[]' > "$research"
if [ "$FLOOR_ONLY" = 0 ]; then

  # --- 2a. Live progress feed + local dashboard ------------------------------
  # Every step — and every streamed token of the model's answer — is appended
  # to .research-live/events.jsonl and served on a local port. Open the URL
  # printed below to watch the model work in real time instead of staring at
  # a ticker. The server serves ONLY the progress dir (never the repo, which
  # holds gitignored key files) and dies with this script.
  LIVE_DIR="$SCRIPT_DIR/.research-live"; mkdir -p "$LIVE_DIR"
  : > "$LIVE_DIR/events.jsonl"
  cp "$SCRIPT_DIR/dashboard.html" "$LIVE_DIR/index.html" 2>/dev/null || true
  DASH_PORT="${RESEARCH_DASH_PORT:-8070}"
  DASH_PID=""
  if lsof -iTCP:"$DASH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "research: live progress → http://127.0.0.1:$DASH_PORT/ (server already up)" >&2
  else
    ( cd "$LIVE_DIR" && exec python3 -m http.server "$DASH_PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
    DASH_PID=$!
    echo "research: live progress → http://127.0.0.1:$DASH_PORT/" >&2
  fi
  emit() { # emit <kind> <text> [model-chip]
    printf '{"t":"%s","kind":"%s","text":%s,"model":%s}\n' \
      "$(date '+%H:%M:%S')" "$1" "$(printf '%s' "$2" | jq -Rs .)" \
      "$(printf '%s' "${3:-}" | jq -Rs .)" >> "$LIVE_DIR/events.jsonl"
  }
  emit status "floor done — calling research models (free first, paid only as fallback)"
  # One small question at a time. A single "survey every free endpoint on the
  # internet" prompt reads as mass enumeration and free models refuse it; the
  # same work split into narrow, answerable questions does not. Every question
  # demands a JSON array (possibly empty) and forbids invention — the probe
  # verifies everything anyway. The paid sweep prompt stays whole: that model
  # has web search and handles the big ask.
  FMT='Reply with ONLY a JSON array, no prose, no markdown fences. Each element: {"id":"<model id>","vendor":"<name>","base_url":"<OpenAI-compatible root>","needs_key":true,"key_env":"<env var name for the key>","docs":"<documentation URL or null>"}. Reply [] if unsure — never invent ids or URLs.'
  FREE_QUESTIONS=(
    "Groq has a free tier. What is the OpenAI-compatible base URL of the Groq API, and which chat models are free there right now? $FMT (use vendor groq, key_env GROQ_API_KEY)"
    "Cerebras has a free tier. What is its OpenAI-compatible base URL and which chat models are free right now? $FMT (use vendor cerebras, key_env CEREBRAS_API_KEY)"
    "Cloudflare Workers AI has a free tier. What is its OpenAI-compatible base URL and which models are free right now? $FMT (use vendor cloudflare, key_env CLOUDFLARE_API_TOKEN)"
    "Together AI has a free tier. What is its OpenAI-compatible base URL and which models are free right now? $FMT (use vendor together, key_env TOGETHER_API_KEY)"
    "NVIDIA NIM (build.nvidia.com) has a free tier. What is its OpenAI-compatible base URL and which models are free right now? $FMT (use vendor nvidia, key_env NVIDIA_API_KEY)"
    "SambaNova has a free tier. What is its OpenAI-compatible base URL and which models are free right now? $FMT (use vendor sambanova, key_env SAMBANOVA_API_KEY)"
    "Hugging Face Inference Providers have a free monthly allowance. What is the OpenAI-compatible base URL and which chat models are free right now? $FMT (use vendor huggingface, key_env HF_TOKEN)"
    "Some websites publish a section titled AnytimeLime Endpoint that lists a free AI model id and a base URL. Search the web for that exact phrase and report every endpoint those pages list, with the site as the vendor. $FMT (needs_key only if the page says a key is required)"
  )
  SWEEP_PROMPT='Search the web for currently free AI chat model endpoints that speak the OpenAI-compatible /v1/chat/completions API, available today. Include both keyless free tiers AND free-tier-with-key vendors (Groq, Together, NVIDIA NIM, Cerebras, Cloudflare Workers AI, Hugging Face inference, SambaNova, etc.). ALSO look for anytimelime community-network members: pages whose source contains the anytimelime tag and access details labeled AnytimeLime Endpoint (<!-- anytimelime --> followed by a list where each entry reads AnytimeLime Endpoint and gives a model id and base URL) — include every endpoint they list, with the site as the vendor. Respond with ONLY a JSON array — no prose, no markdown fences. Each element is one probeable model: {"id":"<model id to send in the model field>","vendor":"<name>","base_url":"<OpenAI-compatible root, e.g. https://api.groq.com/openai/v1>","needs_key":<true|false>,"key_env":"<env var name for the key, or null>","docs":"<URL of the endpoint documentation page, or null>"}. Use only real, current model ids you verified by search; do not invent endpoints.'

  # extract_candidates <content> <outfile> — the model may wrap JSON in fences
  # or pad it with prose; pull the outermost JSON array out and normalize to
  # {id, vendor, base_url, needs_key, key_env, source:"research"} records.
  # Echoes the record count (0 on refusal/garbage). python3 is already a
  # dependency (blog-gen's CANDIDATES rewrite).
  extract_candidates() { # extract_candidates <content> <outfile>
    python3 - "$1" <<'PYEOF' > "$2" 2>/dev/null || echo '[]' > "$2"
import json, re, sys
src = sys.argv[1]
m = re.search(r'\[.*\]', src, re.S)
if not m:
    print('[]'); sys.exit(0)
try:
    arr = json.loads(m.group(0))
except Exception:
    print('[]'); sys.exit(0)
out = []
for o in arr:
    if not isinstance(o, dict): continue
    ids = o.get("model_ids") or []
    if isinstance(ids, list):
        ids = [i for i in ids if isinstance(i, str) and i]
    else:
        ids = []
    if isinstance(o.get("id"), str) and o["id"]:
        ids.append(o["id"])
    base = o.get("base_url")
    docs = o.get("docs") if isinstance(o.get("docs"), str) and o.get("docs","").startswith("http") else None
    for i in ids:
        if not base: continue
        out.append({
            "id": i,
            "vendor": o.get("vendor", "unknown"),
            "base_url": base,
            "needs_key": bool(o.get("needs_key", True)),
            "key_env": o.get("key_env") if isinstance(o.get("key_env"), str) else None,
            "docs": docs,
            "source": "research",
        })
print(json.dumps(out))
PYEOF
    jq 'length' "$2" 2>/dev/null || echo 0
  }

  # stream_curl <label> <timeout_s> <url> [bearer] — POSTs stdin as the
  # request with stream:true and parses the SSE live: every content delta is
  # pushed to the dashboard as it arrives and appended to the assembled
  # answer; raw SSE is kept in $WORK/raw.$$ for diagnostics. A heartbeat
  # reports long silent stretches (thinking / web sweep). Echoes the assembled
  # content on stdout — callers treat it exactly like the non-streamed
  # .choices[0].message.content they used to get.
  stream_curl() { # stream_curl <label> <timeout_s> <url> [bearer]
    local label="$1" tmo="$2" url="$3" bearer="${4:-}"
    local rawf="$WORK/raw.$$" cf="$WORK/content.$$"
    : > "$cf"; : > "$rawf"
    emit status "calling $label — streaming, cap ${tmo}s" "$label"
    ( if [ -n "$bearer" ]; then
        curl -sN -m "$tmo" "$url" -H "Authorization: Bearer $bearer" \
          -H "content-type: application/json" -d @- 2>/dev/null || true
      else
        curl -sN -m "$tmo" "$url" -H "content-type: application/json" \
          -d @- 2>/dev/null || true
      fi | while IFS= read -r _l; do
        printf '%s\n' "$_l" >> "$rawf"
        case "$_l" in data:*)
          _d="$(printf '%s' "${_l#data:}" | jq -r '.choices[0].delta.content // empty' 2>/dev/null || true)"
          if [ -n "$_d" ]; then
            printf '%s' "$_d" >> "$cf"
            emit delta "$_d" "$label"
            echo "research:   ▸ $label: ${_d}" | head -c 200 >&2
          fi ;;
        esac
      done ) &
    local pid=$!
    ( local _last=-1 _sz
      while kill -0 "$pid" 2>/dev/null; do
        sleep 20
        _sz="$(wc -c < "$cf" | tr -d ' ')"
        if [ "$_sz" = "$_last" ]; then
          echo "research:   …$label quiet for 20s (thinking / web sweep)" >&2
          emit status "$label — quiet for 20s (thinking / web sweep)" "$label"
        fi
        _last="$_sz"
      done ) &
    local hb=$!
    wait "$pid" 2>/dev/null || true
    kill "$hb" 2>/dev/null || true
    cat "$cf" 2>/dev/null || true
  }

  # followup_rounds <model> <url> <bearer> <timeout> <prompt-prefix> — a model
  # that contributed anything is asked whether there is MORE it did not list
  # yet, until it answers [] (done) or 3 extra rounds pass. Models hold back
  # on the first ask; the nudge finds the tail. Echoes the extra count.
  followup_rounds() { # followup_rounds <model> <url> <bearer> <timeout> <prefix>
    local m="$1" url="$2" bearer="$3" tmo="$4" prefix="$5" round=1 extra_n=0
    while [ "$round" -le 3 ]; do
      local sofar tmpf N C
      sofar="$(jq -r '[.[].id] | .[-30:] | join(", ")' "$research")"
      echo "research: $m — follow-up round $round (anything not listed yet?)…" >&2
      emit status "$m — follow-up round $round: any endpoints not listed yet?" "$m"
      C="$(jq -n --arg m "$m" --arg p "$prefix So far these are already found: $sofar. Are there more free OpenAI-compatible model endpoints NOT in that list? $FMT" \
        '{model: $m, max_tokens: 1200, stream: true, messages: [{role:"user", content: $p}]}' \
        | stream_curl "$m" "$tmo" "$url" "$bearer")"
      [ -z "$C" ] && break
      tmpf="$WORK/fu.$$.json"
      N="$(extract_candidates "$C" "$tmpf")"
      if [ "$N" -gt 0 ] 2>/dev/null; then
        jq -s '.[0] + .[1]' "$research" "$tmpf" > "$research.tmp" && mv "$research.tmp" "$research"
        extra_n=$((extra_n + N)); round=$((round + 1))
      else
        break
      fi
    done
    echo "$extra_n"
  }

  # Route 1: FREE models via OpenRouter — as many as we have. The pool is
  # normally today's probe passers (blog-gen injects them via
  # RESEARCH_FREE_MODELS); until a first roster exists, the defaults run.
  # EVERY free model gets the full set of small questions and whatever each
  # finds is accumulated — fairer coverage, and one refusal cannot burn the
  # route. Only a combined harvest of zero falls through to paid.
  OR_KEY="${OPENROUTER_API_KEY:-}"
  if [ -z "$OR_KEY" ] && [ -f "$SCRIPT_DIR/openrouter.config.json" ]; then
    OR_KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$SCRIPT_DIR/openrouter.config.json" 2>/dev/null || true)"
  fi
  case "$OR_KEY" in ""|null|*PLACEHOLDER*|*YOUR*KEY*) OR_KEY="" ;; esac
  FREE_MODELS="${RESEARCH_FREE_MODELS:-openrouter/free minimax/minimax-m3:free}"
  MODEL_USED=""

  # Free models THROUGH the harness. The claude harness (razzle-dazzle) gives
  # any tool-call-capable model real web search — and the passers are
  # tool-capable by definition. We stand up a translating proxy (or-proxy)
  # plus a second gateway born pointed at it, and the free pool browses.
  # If the stack cannot start, free models still answer from memory via
  # direct OpenRouter calls — free either way.
  FREE_GATEWAY_PORT="${FREE_GATEWAY_PORT:-8022}"
  ORPROXY_PORT="${ORPROXY_PORT:-8099}"
  GATEWAY_DIR="${RAZZLE_GATEWAY_DIR:-$HOME/Projects/ClaudeCodeProjects/computatron/devenv-service/claude-code-api}"
  UVICORN_BIN="${UVICORN_BIN:-$(command -v uvicorn || echo /Library/Frameworks/Python.framework/Versions/3.11/bin/uvicorn)}"
  FREE_ENDPOINT=""
  start_free_stack() {
    [ -d "$GATEWAY_DIR" ] || { echo "research: no gateway dir at $GATEWAY_DIR" >&2; return 1; }
    if ! lsof -iTCP:"$ORPROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      OR_KEY="$OR_KEY" nohup python3 "$SCRIPT_DIR/server/or-proxy.py" "$ORPROXY_PORT" >/dev/null 2>&1 &
      ORPROXY_PID=$!
    fi
    mkdir -p "$SCRIPT_DIR/.free-gateway"
    printf '%s\n' $FREE_MODELS | jq -R -s 'split("\n") | map(select(length>0)) | {default_model:.[0], aliases:{}, models:[.[]|{id:.,name:.,description:("free passer, scored 3+ for agentic work"),max_tokens:65536,input_cost_per_1k:0,output_cost_per_1k:0,supports_streaming:true,supports_tools:true}]}' > "$SCRIPT_DIR/.free-gateway/models.json"
    if ! lsof -iTCP:"$FREE_GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      ( cd "$GATEWAY_DIR" && exec env -u ANTHROPIC_API_KEY -u ZAI_API_KEY -u ZAI_CODE_MODEL -u ZAI_ANTHROPIC_BASE_URL -u HYBRID_WEIGHT \
          ANTHROPIC_BASE_URL="http://127.0.0.1:$ORPROXY_PORT" ANTHROPIC_AUTH_TOKEN=local-free-stack \
          CLAUDE_CODE_API_MODELS_PATH="$SCRIPT_DIR/.free-gateway/models.json" \
          "$UVICORN_BIN" claude_code_api.main:app --host 127.0.0.1 --port "$FREE_GATEWAY_PORT" ) >/dev/null 2>&1 &
      FREE_GATEWAY_PID=$!
    fi
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if curl -s -m 2 "http://127.0.0.1:$FREE_GATEWAY_PORT/health" 2>/dev/null | grep -q healthy; then
        FREE_ENDPOINT="http://127.0.0.1:$FREE_GATEWAY_PORT"; return 0
      fi
      sleep 1
    done
    return 1
  }
  if start_free_stack; then
    echo "research: free pool rides the harness — web search ON (gateway :$FREE_GATEWAY_PORT)" >&2
    emit status "free models have web search via the razzle-dazzle harness" ""
  else
    echo "research: free stack unavailable — free models answer from memory (no browsing)." >&2
  fi
  if [ -n "$FREE_ENDPOINT" ]; then
    FQ_URL="$FREE_ENDPOINT/v1/chat/completions"; FQ_KEY=""; FQ_TMO=180
  else
    FQ_URL="https://openrouter.ai/api/v1/chat/completions"; FQ_KEY="$OR_KEY"; FQ_TMO=90
  fi
  if [ -n "$OR_KEY" ]; then
    echo "research: free pool — $(printf '%s' "$FREE_MODELS" | wc -w | tr -d ' ') model(s), ${#FREE_QUESTIONS[@]} small questions each" >&2
    emit status "free pool: $(printf '%s' "$FREE_MODELS" | wc -w | tr -d ' ') models × ${#FREE_QUESTIONS[@]} questions"
    TOTAL_FREE=0
    for fm in $FREE_MODELS; do
      _t0=$(python3 -c 'import time; print(time.time())')
      fm_n=0
      for qi in "${!FREE_QUESTIONS[@]}"; do
        q="${FREE_QUESTIONS[$qi]}"
        echo "research: FREE $fm — question $((qi + 1))/${#FREE_QUESTIONS[@]}…" >&2
        emit status "$fm — question $((qi + 1))/${#FREE_QUESTIONS[@]}: $(printf '%s' "$q" | head -c 60)…" "$fm"
        C="$(jq -n --arg m "$fm" --arg p "$q" \
          '{model: $m, max_tokens: 1200, stream: true, messages: [{role:"user", content: $p}]}' \
          | stream_curl "$fm" "$FQ_TMO" "$FQ_URL" "$FQ_KEY")"
        if [ -n "$C" ]; then
          tmpf="$WORK/q.$$.json"
          N="$(extract_candidates "$C" "$tmpf")"
          if [ "$N" -gt 0 ] 2>/dev/null; then
            jq -s '.[0] + .[1]' "$research" "$tmpf" > "$research.tmp" && mv "$research.tmp" "$research"
            fm_n=$((fm_n + N)); TOTAL_FREE=$((TOTAL_FREE + N))
          fi
        else
          echo "research: $fm gave no answer to question $((qi + 1)) — moving on." >&2
        fi
      done
      echo "research: $fm done in $(python3 -c "import time; print(f'{time.time() - $_t0:.0f}s')") — contributed $fm_n candidate(s)" >&2
      if [ "$fm_n" -gt 0 ]; then
        _extra="$(followup_rounds "$fm" "$FQ_URL" "$FQ_KEY" "$FQ_TMO" "You helped find free AI model endpoints.")"
        if [ "$_extra" -gt 0 ] 2>/dev/null; then
          fm_n=$((fm_n + _extra)); TOTAL_FREE=$((TOTAL_FREE + _extra))
          echo "research: $fm follow-ups added $_extra more" >&2
        fi
      fi
      emit status "$fm finished — contributed $fm_n candidates (free harvest so far: $TOTAL_FREE)" "$fm"
      [ "$fm_n" -gt 0 ] && MODEL_USED="${MODEL_USED:+$MODEL_USED, }$fm (free)"
    done
    if [ "$TOTAL_FREE" -gt 0 ]; then
      echo "research: free harvest: $TOTAL_FREE candidates from the free pool" >&2
      emit status "free harvest complete — $TOTAL_FREE candidates, no paid call needed" ""
    fi
  else
    echo "research: no OpenRouter key — free research route unavailable, will try the paid route." >&2
  fi

  # Route 2: paid cloud via the gateway, ONLY when every free route failed.
  if [ -z "$MODEL_USED" ]; then
    echo "research: free routes failed — falling back to PAID $MODEL via $BASE_URL (web sweep, cap 180s)…" >&2
    emit status "free routes failed — falling back to PAID $MODEL (web sweep, cap 180s)" "$MODEL"
    _t0=$(python3 -c 'import time; print(time.time())')
    REQ="$(jq -n --arg m "$MODEL" --arg p "$SWEEP_PROMPT" \
      '{model: $m, max_tokens: 3000, stream: true, messages: [{role:"user", content: $p}]}')"
    if [ -n "$KEY" ]; then
      C="$(printf '%s' "$REQ" | stream_curl "$MODEL" 180 "$BASE_URL/v1/chat/completions" "$KEY")"
    else
      C="$(printf '%s' "$REQ" | stream_curl "$MODEL" 180 "$BASE_URL/v1/chat/completions")"
    fi
    echo "research: paid fallback returned in $(python3 -c "import time; print(f'{time.time() - $_t0:.0f}s')")" >&2
    if [ -n "$C" ]; then
      N="$(extract_candidates "$C" "$research")"
      if [ "$N" -gt 0 ] 2>/dev/null; then
        MODEL_USED="$MODEL (paid fallback)"
        echo "research: $MODEL (paid fallback) returned $N candidates"
        emit status "$MODEL (paid fallback) returned $N candidates — keeping them" "$MODEL"
      else
        echo "research: $MODEL replied but with no usable candidate list — relying on floor." >&2
        emit status "$MODEL replied but with no usable candidate list — relying on floor" "$MODEL"
        echo '[]' > "$research"
      fi
    else
      echo '[]' > "$research"
      echo "research: $MODEL returned no content — $(head -c 70 "$WORK/raw.$$" | tr -d '\n')" >&2
      echo "research: relying on the deterministic floor." >&2
      emit status "$MODEL returned no content — relying on the deterministic floor" "$MODEL"
    fi
  fi
fi

# --- 3. Merge, dedup, write -------------------------------------------------
# Dedup by (vendor, id). Catalog wins over research on conflict (catalog is
# verified-fetchable); needs_key/key_env from the winning record.
jq -n --slurpfile f "$floor" --slurpfile r "$research" '
  ($r[0] + $f[0])
  | group_by(.vendor + "" + .id)
  | map(reduce .[] as $x ({}; . * $x))
  | sort_by([.needs_key, .vendor, .id])
' | atomic_mv "$OUT"

echo "research: wrote $OUT — $(jq 'length' "$OUT") candidates across $(jq '[.[].vendor] | unique | length' "$OUT") vendors"
[ "${FLOOR_ONLY:-0}" = 0 ] && emit done "done — $(jq 'length' "$OUT") candidates written to candidates.json" "" || true
jq '[.[].vendor] | unique' "$OUT" 2>/dev/null || true
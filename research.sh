#!/usr/bin/env bash
#
# research.sh — discover free AI endpoints across the internet.
#
# The purpose of anytimelime is to probe the INTERNET for free AI, not just
# OpenRouter. This step finds candidates; the probe (free-scan.sh) verifies
# them. A paid cloud model with web search (glm-5.2:cloud via the razzle-dazzle
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
# source    "catalog" (deterministic fetch) | "research" (model found it)
#
# Env:
#   RESEARCH_BASE_URL  default http://localhost:8000  (razzle-dazzle gateway)
#   RESEARCH_MODEL     default glm-5.2:cloud
#   RESEARCH_KEY       default "" (gateway may not require auth)
#   CANDIDATES_FILE    default $SCRIPT_DIR/candidates.json
#
# Usage:
#   ./research.sh              # floor + model research
#   ./research.sh --floor-only # deterministic catalogs only, no model call

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${RESEARCH_BASE_URL:-http://localhost:8000}"
MODEL="${RESEARCH_MODEL:-glm-5.2:cloud}"
KEY="${RESEARCH_KEY:-}"
OUT="${CANDIDATES_FILE:-$SCRIPT_DIR/candidates.json}"
FLOOR_ONLY=0
for _a in "$@"; do
  case "$_a" in
    --floor-only) FLOOR_ONLY=1 ;;
    *) echo "research: unknown flag '$_a'" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# --- 2. Model research: FREE first; paid cloud only when free fails ----------
# A model suggests candidate endpoints beyond the floor; the probe verifies
# every suggestion for real, so a wrong guess just fails a probe. Policy: try
# FREE models for this call first (no web search, but free); only if every
# free route fails do we spend the paid cloud model (glm-5.2:cloud via the
# gateway, which adds web search). Failure is non-fatal — the floor still ships.
research="$WORK/research.json"; echo '[]' > "$research"
if [ "$FLOOR_ONLY" = 0 ]; then
  PROMPT='Search the web for currently free AI chat model endpoints that speak the OpenAI-compatible /v1/chat/completions API, available today. Include both keyless free tiers AND free-tier-with-key vendors (Groq, Together, NVIDIA NIM, Cerebras, Cloudflare Workers AI, Hugging Face inference, SambaNova, etc.). Respond with ONLY a JSON array — no prose, no markdown fences. Each element is one probeable model: {"id":"<model id to send in the model field>","vendor":"<name>","base_url":"<OpenAI-compatible root, e.g. https://api.groq.com/openai/v1>","needs_key":<true|false>,"key_env":"<env var name for the key, or null>"}. Use only real, current model ids you verified by search; do not invent endpoints.'
  CONTENT=""
  MODEL_USED=""

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
    for i in ids:
        if not base: continue
        out.append({
            "id": i,
            "vendor": o.get("vendor", "unknown"),
            "base_url": base,
            "needs_key": bool(o.get("needs_key", True)),
            "key_env": o.get("key_env") if isinstance(o.get("key_env"), str) else None,
            "source": "research",
        })
print(json.dumps(out))
PYEOF
    jq 'length' "$2" 2>/dev/null || echo 0
  }

  # timed_curl <label> <timeout_s> <url> [auth_header] — curl in the
  # background with a live ticker, so a slow model never looks like a hang.
  # Raw body lands in $WORK/raw.$$, echoed on stdout.
  timed_curl() { # timed_curl <label> <timeout_s> <url> [bearer]
    local label="$1" tmo="$2" url="$3" bearer="${4:-}" rawf="$WORK/raw.$$" el=0
    if [ -n "$bearer" ]; then
      ( curl -s -m "$tmo" "$url" -H "Authorization: Bearer $bearer" \
          -H "content-type: application/json" -d @- > "$rawf" 2>/dev/null || true ) &
    else
      ( curl -s -m "$tmo" "$url" -H "content-type: application/json" \
          -d @- > "$rawf" 2>/dev/null || true ) &
    fi
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      sleep 15; el=$((el + 15))
      [ $el -ge "$tmo" ] || echo "research:   …still waiting on $label — ${el}s elapsed (cap ${tmo}s)" >&2
    done
    wait "$pid" 2>/dev/null || true
    cat "$rawf" 2>/dev/null || true
  }

  # Route 1: free models via OpenRouter. A reply only counts if it parses to
  # at least one candidate — free models sometimes refuse ("I can't browse")
  # and that must NOT block the next route.
  OR_KEY="${OPENROUTER_API_KEY:-}"
  if [ -z "$OR_KEY" ] && [ -f "$SCRIPT_DIR/openrouter.config.json" ]; then
    OR_KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$SCRIPT_DIR/openrouter.config.json" 2>/dev/null || true)"
  fi
  case "$OR_KEY" in ""|null|*PLACEHOLDER*|*YOUR*KEY*) OR_KEY="" ;; esac
  FREE_MODELS="${RESEARCH_FREE_MODELS:-openrouter/free minimax/minimax-m3:free}"
  if [ -n "$OR_KEY" ]; then
    for fm in $FREE_MODELS; do
      echo "research: trying FREE $fm (openrouter) — cap 120s…" >&2
      _t0=$(python3 -c 'import time; print(time.time())')
      RAW="$(jq -n --arg m "$fm" --arg p "$PROMPT" \
        '{model: $m, max_tokens: 3000, messages: [{role:"user", content: $p}]}' \
        | timed_curl "$fm" 120 https://openrouter.ai/api/v1/chat/completions "$OR_KEY")"
      C="$(printf '%s' "$RAW" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)"
      echo "research: $fm answered in $(python3 -c "import time; print(f'{time.time() - $_t0:.0f}s')")" >&2
      if [ -n "$C" ]; then
        N="$(extract_candidates "$C" "$research")"
        if [ "$N" -gt 0 ] 2>/dev/null; then
          MODEL_USED="$fm (free)"; break
        fi
        echo "research: $fm replied but with no usable candidate list — next route." >&2
      else
        echo "research: $fm unusable — $(printf '%s' "$RAW" | jq -r '.error.message // "no content"' 2>/dev/null | head -c 70)" >&2
      fi
      echo '[]' > "$research"
    done
  else
    echo "research: no OpenRouter key — free research route unavailable." >&2
  fi

  # Route 2: paid cloud fallback, ONLY when every free route failed.
  if [ -z "$MODEL_USED" ]; then
    echo "research: free routes failed — falling back to PAID $MODEL via $BASE_URL (web sweep, cap 180s)…" >&2
    _t0=$(python3 -c 'import time; print(time.time())')
    REQ="$(jq -n --arg m "$MODEL" --arg p "$PROMPT" \
      '{model: $m, max_tokens: 3000, messages: [{role:"user", content: $p}]}')"
    if [ -n "$KEY" ]; then
      RAW="$(printf '%s' "$REQ" | timed_curl "$MODEL" 180 "$BASE_URL/v1/chat/completions" "$KEY")"
    else
      RAW="$(printf '%s' "$REQ" | timed_curl "$MODEL" 180 "$BASE_URL/v1/chat/completions")"
    fi
    echo "research: paid fallback returned in $(python3 -c "import time; print(f'{time.time() - $_t0:.0f}s')")" >&2
    C="$(printf '%s' "$RAW" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)"
    if [ -n "$C" ]; then
      N="$(extract_candidates "$C" "$research")"
      [ "$N" -gt 0 ] 2>/dev/null && MODEL_USED="$MODEL (paid fallback)"
    fi
    [ -z "$MODEL_USED" ] && echo '[]' > "$research"
  fi

  if [ -n "$MODEL_USED" ]; then
    echo "research: $MODEL_USED returned $(jq 'length' "$research") candidates"
  else
    echo "research: no usable model reply — relying on floor." >&2
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
jq '[.[].vendor] | unique' "$OUT" 2>/dev/null || true
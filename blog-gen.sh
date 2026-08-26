#!/usr/bin/env bash
#
# blog-gen.sh — the automated AnytimeLime blog.
#
# Runs the probe, then asks a free model to write the prose around the
# (deterministic, hand-built) results table. Posts land in
# anytimelime-web/blog/posts/<date>.html, are mirrored to the archive repo,
# and the blog index is rebuilt.
#
# The division of labor is deliberate: the DATA is measured, not written —
# latency and pass/fail come from real probes. The model only writes the
# words around it. If the model fails, the post still ships with fallback
# prose and a correct table.
#
# Usage: ./blog-gen.sh          (run manually, or from cron)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="${ANYTIMELIME_WEB:-$SCRIPT_DIR/../anytimelime-web}"
ARCHIVE_DIR="${ANYTIMELIME_BLOG:-$SCRIPT_DIR/../anytimelime-blog}"
BLOG_DIR="$WEB_DIR/blog"
POSTS_DIR="$BLOG_DIR/posts"
CONFIG_IN="${OR_PROBE_CONFIG:-$SCRIPT_DIR/openrouter.config.json}"
TODAY="$(date +%F)"

KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$CONFIG_IN" ]; then
  KEY="$(jq -r '.ANTHROPIC_AUTH_TOKEN // empty' "$CONFIG_IN" 2>/dev/null || true)"
fi
if [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
  echo "blog-gen: no OpenRouter key — set OPENROUTER_API_KEY or put" >&2
  echo "          ANTHROPIC_AUTH_TOKEN in $CONFIG_IN" >&2
  exit 1
fi

mkdir -p "$POSTS_DIR"

# --- 1. Probe ---------------------------------------------------------------
# FREE_SCAN_OUT is redirected to a scratch path on purpose: synthesize.sh
# ran earlier this morning and wrote the AI-assigned tiers into
# openrouter-free.config.json. Letting free-scan.sh write its own heuristic
# tiers here would silently overwrite that judgment every single day.
PROBE_OUT="$SCRIPT_DIR/.blog-probe.txt"
FREE_SCAN_OUT="$SCRIPT_DIR/.blog-probe.config.json" \
  "$SCRIPT_DIR/free-scan.sh" | tee "$PROBE_OUT"

# --- 2. Parse results into TSV: latency \t model \t verdict -----------------
TSV="$SCRIPT_DIR/.blog-probe.tsv"
awk '
  /^[0-9.]+s +[^\ ]/          { lat=$1; model=$2; for(i=3;i<=NF;i++) model=model" "$i; pending=lat"\t"model }
  /^ +(PASS|WEAK|FAIL)/       { verdict=$0; sub(/^ +/,"",verdict);
                                if (pending != "") print pending"\t"verdict; pending="" }
' "$PROBE_OUT" > "$TSV"

if [ ! -s "$TSV" ]; then
  echo "blog-gen: probe produced no parseable results — aborting." >&2
  exit 1
fi

DATA_JSON=$(jq -Rn 'reduce inputs as $l ([]; . + [$l | split("\t") | {latency: .[0], model: .[1], verdict: .[2]}])' "$TSV")
PASSING=$(awk -F'\t' '$3 ~ /^PASS/ {print $2}' "$TSV" | jq -R . | jq -s .)
WEAK_LIST=$(awk -F'\t' '$3 ~ /^WEAK/ {print $2}' "$TSV" | jq -R . | jq -s .)
PASS_COUNT=$(echo "$PASSING" | jq length)
WEAK_COUNT=$(echo "$WEAK_LIST" | jq length)
PROBED_COUNT=$(wc -l < "$TSV" | tr -d ' ')

# --- 3. Ask a free model for the prose --------------------------------------
USER_PROMPT="Write the body of a blog post titled \"What's free in AI right now — $TODAY\". Sections, in order: (1) an intro of about 2 paragraphs on the state of free models, grounded in the data; (2) a section titled \"How to use them without AnytimeLime\": sign up at openrouter.ai, create an API key, use model IDs like the ones in the data directly, include a curl example hitting https://openrouter.ai/api/v1/chat/completions; (3) a section titled \"How to use them with AnytimeLime\": paste your key at anytimelime.com, click Squeeze, download the generated config, launch with OR_CONFIG pointing at it; (4) a closing section titled \"The churn\" on why free rosters change weekly and re-checking matters. A verdict of PASS means the model made a real tool call; WEAK means it answered in text but ignored the tool schema; FAIL means it errored or returned nothing. Data: $DATA_JSON"

REQ=$(jq -n --arg prompt "$USER_PROMPT" '{
  max_tokens: 2500,
  messages: [
    {role: "system", content: "You write short, punchy blog posts for developers. Your ENTIRE response is HTML fragments and MUST begin immediately with an <h2> tag — no preamble, no thinking out loud, no introduction line, no markdown. Allowed tags only: h2, p, ul, li, code, a. Voice: dry, technical, a little playful. Never invent models, numbers, or latencies — use only the JSON data provided in the user message."},
    {role: "user", content: $prompt}
  ]
}')

# Prose candidates come from TODAY'S passing roster, not a hardcoded list —
# a hardcoded one rots exactly the way the project exists to prevent.
# BLOG_MODEL, if set, is tried first regardless.
PROSE_MODELS=()
[ -n "${BLOG_MODEL:-}" ] && PROSE_MODELS+=("$BLOG_MODEL")
while IFS= read -r m; do
  [ -n "$m" ] && PROSE_MODELS+=("$m")
done < <(printf '%s' "$PASSING" | jq -r '.[]' | head -4)
# Text-only models are perfectly good at prose even though they failed the
# tool-call bar, so they are fine as a last resort here.
while IFS= read -r m; do
  [ -n "$m" ] && PROSE_MODELS+=("$m")
done < <(printf '%s' "$WEAK_LIST" | jq -r '.[]' | head -2)

PROSE=""
for M in "${PROSE_MODELS[@]}"; do
  RAW=$(printf '%s' "$REQ" | jq -c --arg m "$M" '. + {model: $m}' \
    | curl -s -m 180 https://openrouter.ai/api/v1/chat/completions \
        -H "Authorization: Bearer $KEY" \
        -H "content-type: application/json" -d @- \
    | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
  # Strip anything before the first real <h2> line (leaked reasoning).
  CAND=$(printf '%s' "$RAW" | awk '!f && $0 !~ /^[[:space:]]*<h2/ {next} {f=1} 1')
  # Reject chain-of-thought contamination.
  if [ -n "$CAND" ] && [ ${#CAND} -ge 200 ] && \
     ! printf '%s' "$CAND" | grep -qiE "I'll use|I will use|Let's structure|thinking process|Here is the"; then
    PROSE="$CAND"
    PROSE_BY="$M"
    echo "blog-gen: prose by $M"
    break
  fi
  echo "blog-gen: $M unusable, trying next…" >&2
done

if [ -z "$PROSE" ]; then
  echo "blog-gen: all prose models unusable — using fallback." >&2
  PROSE_BY="fallback (no model produced usable prose)"
  PROSE="<h2>What's free right now</h2>
<p>${PASS_COUNT} free models made a real tool call today, out of ${PROBED_COUNT} probed. The table below is measured, not marketed: each model got a real request with a real tool schema, timed from request to response.</p>
<h2>How to use them without AnytimeLime</h2>
<p>Create an account at <a href=\"https://openrouter.ai\">openrouter.ai</a>, generate an API key, and call any model ID below directly:</p>
<p><code>curl https://openrouter.ai/api/v1/chat/completions -H \"Authorization: Bearer YOUR_KEY\" -H \"Content-Type: application/json\" -d '{\"model\":\"MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'</code></p>
<h2>How to use them with AnytimeLime</h2>
<p>Go to <a href=\"https://anytimelime.com\">anytimelime.com</a>, paste your key, click Squeeze. You get a config mapping the day's best passing models to opus/sonnet/haiku tiers — download it and launch with <code>OR_CONFIG=./anytimelime.config.json ./or.sh</code>.</p>
<h2>The churn</h2>
<p>Free rosters change weekly — models die, rate-limit, or resurrect without notice. Last week's config is this week's outage. Re-squeeze before you depend on it.</p>"
fi

# --- 4. Build the table (deterministic) -------------------------------------
TABLE_rows=$(awk -F'\t' '{
  cls = ($3 ~ /^PASS/) ? "pass" : ($3 ~ /^WEAK/) ? "weak" : "fail";
  printf "<tr><td>%s</td><td><code>%s</code></td><td class=\"%s\">%s</td></tr>\n", $1, $2, cls, $3
}' "$TSV")

# --- 5. Assemble the post ---------------------------------------------------
POST="$POSTS_DIR/$TODAY.html"
cat > "$POST" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>What's free in AI — $TODAY · anytimelime</title>
<style>
  :root { --bg:#0e1208; --panel:#171d10; --line:#2a331d; --lime:#b8e62e;
          --lime-dim:#7fa321; --text:#e8edda; --dim:#9aa685;
          --bad:#e66454; --warn:#e0b93c; --good:#7fd15c; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font:16px/1.6 ui-monospace,"SF Mono",Menlo,monospace;
         display:flex; justify-content:center; }
  main { width:min(720px,92vw); padding:40px 0 80px; }
  a { color:var(--lime-dim); }
  h1 { font-size:24px; } h2 { font-size:17px; color:var(--lime); margin-top:32px; }
  .meta { color:var(--dim); font-size:13px; margin-bottom:28px; }
  table { width:100%; border-collapse:collapse; font-size:13.5px; margin:12px 0; }
  th { text-align:left; color:var(--dim); font-weight:400; padding:4px 8px;
       border-bottom:1px solid var(--line); }
  td { padding:5px 8px; border-bottom:1px solid var(--line); }
  .pass { color:var(--good); } .weak { color:var(--warn); } .fail { color:var(--bad); }
  code { background:var(--panel); border:1px solid var(--line);
         border-radius:4px; padding:1px 5px; font-size:13px; }
  pre { background:var(--panel); border:1px solid var(--line); border-radius:6px;
        padding:12px; overflow-x:auto; font-size:12.5px; }
  .lime { color:var(--lime); }
</style>
</head>
<body>
<main>
<h1>anytime<span class="lime">lime</span> — the free AI field report</h1>
<div class="meta">$TODAY · generated by a free model interviewing free models · <a href="../../index.html">squeeze your own →</a></div>
$PROSE
<h2>The measured table</h2>
<table><thead><tr><th>latency</th><th>model</th><th>verdict</th></tr></thead>
<tbody>
$TABLE_rows
</tbody></table>
<p class="meta">$PASS_COUNT made a tool call, $WEAK_COUNT answered in text only, of $PROBED_COUNT probed.
Numbers are single-run measurements from one location — your mileage will vary.
Prose by <code>$PROSE_BY</code>; the table is measured, never model-written.
Reproduce with <code>./free-scan.sh</code>.</p>
</main>
</body>
</html>
HTML

# --- 6. Publish machine-readable endpoint data ------------------------------
# latest.json is the blog's API: today's verified-free roster + tier
# assignments. Smart launchers (lime.sh) fetch this and are always current.
TIERS="{\"opus\":null,\"sonnet\":null,\"haiku\":null}"
if [ -f "$SCRIPT_DIR/openrouter-free.config.json" ]; then
  TIERS=$(jq -c '{opus: .ANTHROPIC_DEFAULT_OPUS_MODEL,
                  sonnet: .ANTHROPIC_DEFAULT_SONNET_MODEL,
                  haiku: .ANTHROPIC_DEFAULT_HAIKU_MODEL}' \
    "$SCRIPT_DIR/openrouter-free.config.json")
fi
jq -n --arg date "$TODAY" --argjson tiers "$TIERS" --argjson order "$PASSING" \
  --argjson weak "$WEAK_LIST" --argjson results "$DATA_JSON" \
  '{updated: $date, tiers: $tiers, order: $order, weak: $weak, results: $results,
    usage: "fetch this, merge your own ANTHROPIC_AUTH_TOKEN, point a launcher at it"}' \
  > "$BLOG_DIR/latest.json"
echo "blog-gen: wrote $BLOG_DIR/latest.json"

# --- 7. Refresh the main site's candidate list ------------------------------
# Keep the squeeze list exhaustive: every currently-free catalog model,
# baked into index.html (CANDIDATES-AUTO line). The blog keeps the main
# site current; the site update ships via git push → Netlify.
SITE_INDEX="$WEB_DIR/index.html"
if [ -f "$SITE_INDEX" ]; then
  FREE_LIST="$(curl -s -m 20 "https://openrouter.ai/api/v1/models" \
    | jq -r '.data[] | select(.pricing.prompt == "0" and .pricing.completion == "0") | .id' \
    | jq -R . | jq -sc . )"
  if [ -n "$FREE_LIST" ] && [ "$FREE_LIST" != "[]" ]; then
    python3 - "$SITE_INDEX" "$FREE_LIST" <<'PYEOF'
import re, sys
path, free = sys.argv[1], sys.argv[2]
src = open(path).read()
new_line = "const CANDIDATES = %s;" % free
out, n = re.subn(r'const CANDIDATES = \[.*?\];', new_line, src, count=1, flags=re.S)
if n:
    open(path, "w").write(out)
    print("blog-gen: refreshed CANDIDATES with %d free models" % (free.count(",") + 1))
else:
    print("blog-gen: CANDIDATES-AUTO marker not found — site list NOT refreshed", file=sys.stderr)
PYEOF
  fi
fi

# --- 8. Rebuild the blog index ----------------------------------------------
# Must happen BEFORE the mirror + push below: this used to run last, which
# meant every index was pushed one run stale, and the very first run died
# copying an index.html that did not exist yet.
{
  echo '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>the free AI field report · anytimelime</title>'
  echo '<style>body{margin:0;background:#0e1208;color:#e8edda;font:16px/1.6 ui-monospace,Menlo,monospace;display:flex;justify-content:center}main{width:min(720px,92vw);padding:40px 0 80px}a{color:#7fa321;text-decoration:none}h1{font-size:24px}.lime{color:#b8e62e}.meta{color:#9aa685;font-size:13px}ul{list-style:none;padding:0}li{padding:10px 0;border-bottom:1px solid #2a331d}li a{font-size:17px}li .meta{display:block}</style>'
  echo '</head><body><main><h1>anytime<span class="lime">lime</span> field reports</h1>'
  echo '<div class="meta">What'"'"'s free in AI, probed and written automatically. <a href="../index.html">Squeeze your own config →</a></div><ul>'
  for f in $(ls -1 "$POSTS_DIR" | grep '\.html$' | sort -r); do
    d="${f%.html}"
    echo "<li><a href=\"posts/$f\">What's free in AI — $d</a><span class=\"meta\">auto-generated field report</span></li>"
  done
  echo '</ul></main></body></html>'
} > "$BLOG_DIR/index.html"

# --- 9. Mirror to blog archive repo, then commit + push both ----------------
# Web repo (anytimelime-web) is what Netlify deploys; the archive repo
# (anytimelime-blog) is the canonical private record. blog-gen writes both.
if [ -d "$ARCHIVE_DIR" ]; then
  mkdir -p "$ARCHIVE_DIR/posts"
  cp "$BLOG_DIR/latest.json"     "$ARCHIVE_DIR/latest.json"
  cp "$BLOG_DIR/index.html"      "$ARCHIVE_DIR/index.html"
  cp "$POSTS_DIR/$TODAY.html"    "$ARCHIVE_DIR/posts/$TODAY.html"
fi

push_repo() {
  local dir="$1" label="$2"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "blog-gen: $label is not a git repo — skipping push" >&2; return 0; }
  git -C "$dir" add -A >/dev/null 2>&1 || true
  if git -C "$dir" status --porcelain | grep -q .; then
    git -C "$dir" commit -m "field report $TODAY — roster refresh" --quiet \
      && echo "blog-gen: committed $label"
    git -C "$dir" push --quiet 2>/dev/null \
      && echo "blog-gen: pushed $label" \
      || echo "blog-gen: $label push failed (retry next run)" >&2
  fi
}
[ -d "$ARCHIVE_DIR" ] && push_repo "$ARCHIVE_DIR" "blog archive"
push_repo "$WEB_DIR" "web (Netlify deploys)"

echo
echo "blog-gen: wrote $POST"
echo "blog-gen: index rebuilt with $(ls -1 "$POSTS_DIR" | grep -c '\.html$') post(s)"
rm -f "$PROBE_OUT" "$TSV" "$SCRIPT_DIR/.blog-probe.config.json"

# anytimelime 🍋

> *Free AI, found fresh every morning — by a free model, interviewing free models.*

**[anytimelime.com](https://anytimelime.com)**

## The problem

Free AI exists right now. Good free AI. Models with million-token context,
competent coding ability, healthy tool-use — sitting in public catalogs,
costing $0. Nobody uses them, because:

1. **They're hard to find.** The free roster is buried in a long model list.
2. **They're hard to trust.** Free listings die without notice, rate-limit
   into uselessness, or can't handle the tool-call schemas that agentic
   workflows require.
3. **They're hard to synthesize.** Knowing which free model should be your
   main thread, which should handle background tasks, and which died last
   Tuesday is a maintenance job nobody wants.

So everyone pays $20/month without checking. The anomaly goes unexamined.

## What free models can't do

Be fast. That's the honest limit, and it's structural — free capacity is
leftover capacity. What free models *can* do is everything that doesn't need
an answer this second: overnight refactors, batch summarization, the long
tail of agentic work that's happy to take its time.

anytimelime is for that work. It tells you, today, which free models are
actually alive and actually able to hold a tool call — so "it can wait"
becomes a real option instead of a gamble.

## How it works

- **Discover** every $0/$0 model in the OpenRouter catalog (public, no key
  needed). The candidate list is fetched, never hardcoded — a hardcoded list
  rots into exactly the problem this project exists to solve.
- **Probe** each one with a real request carrying a real tool schema, and
  measure what comes back:
  - `PASS (tool)` — returned an actual tool call. Claude Code can drive it.
  - `WEAK (text)` — answered, but ignored the tool schema. Prose only.
  - `FAIL` — errored, timed out, or returned nothing.
  Only `PASS` models are eligible for your config. Answering is not the same
  as working, and we don't pretend otherwise.
- **Synthesize** by handing the evidence to a free model and letting it
  assign OPUS / SONNET / HAIKU tiers. A heuristic takes over if it returns
  nonsense.
- **Publish** a ready-to-launch config plus a machine-readable roster at
  `anytimelime.com/blog/latest.json`, refreshed daily.

It runs on $0 of inference. The loop closes on itself.

The daily publisher that writes anytimelime.com/blog is **not** in this
repo — it pushes to two private repos and is useless without them, so it
lives beside the archive it maintains. This repo is the part you can
actually download and run.

## The scripts

| Script | What it does |
|---|---|
| `free-scan.sh` | Discover the free catalog, probe candidates in parallel, report who passed and how fast. `--list-only` for a no-probe catalog peek. |
| `synthesize.sh` | Probe, then hand the evidence to a free model and let it assign the tiers. Falls back to a heuristic if the model talks nonsense. Logs to `synthesize.log`. |
| `lime.sh` | The smart launcher. Fetches today's roster from the live endpoint, merges your key, rotates across the passing models, launches Claude Code. Falls back to your last local scan if the endpoint is down. |
| `or.sh` | The dumb launcher — export one frozen config's vars for a single `claude` process, leaving your shell untouched. |
| `server/lime-pull.sh` | Fetch keyless tier assignments from a self-hosted server and merge in your local key. |
| `server/` | Docker packaging: the scan loop plus an Anthropic-compatible `/v1/messages` proxy with streaming and failover, for serving a userbase without per-user keys. |

## Usage

**Just launch on today's roster** (the normal path):

```bash
LIME_KEY=sk-or-... ./lime.sh
```

**Scan it yourself:**

```bash
export OPENROUTER_API_KEY=sk-or-...
./free-scan.sh                                    # what's alive right now
OR_CONFIG=./openrouter-free.config.json ./or.sh   # launch on it
```

**On a server:**

```bash
OPENROUTER_API_KEY=sk-or-... docker compose -f server/docker-compose.yml up -d --build
```

`:8042` serves keyless configs; `:8043` is the Anthropic-compatible proxy.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `OPENROUTER_API_KEY` | — | Your key. Preferred over the config file. |
| `FREE_SCAN_LIMIT` | `24` | Max models to probe (`0` = no cap). |
| `FREE_SCAN_JOBS` | `6` | Parallel probes. Free tiers rate-limit if you stampede them. |
| `FREE_SCAN_TIMEOUT` | `60` | Per-probe timeout, seconds. |
| `LIME_ENDPOINT` | `https://anytimelime.com/blog/latest.json` | Roster source. |
| `LIME_ROTATE` | `1` | Round-robin across the roster. `0` uses the published tiers. |
| `LIME_HOST` | `http://localhost:8042` | Self-hosted server `server/lime-pull.sh` fetches from. |
| `SYNTH_MODEL` | `openrouter/free` | Model that assigns the tiers. |

## Keys

Your key never leaves the machine that owns it.

- Pass it via `OPENROUTER_API_KEY`, or put it in `openrouter.config.json`,
  which is **gitignored** and must stay that way.
- The website is bring-your-own-key: it stores your key in `localStorage`
  and probes straight from your browser. It never reaches our servers,
  because there are no servers.
- The self-hosted server publishes **tier assignments only** —
  `ANTHROPIC_AUTH_TOKEN` is stripped from anything served over HTTP.

Nothing in this repository should ever contain a live key. If you're adding
a file that holds one, add it to `.gitignore` in the same commit.

## Design principles

- **Probe before believing** — the config only contains models that answered
  *today*.
- **Free tiers lie** — everything has failover.
- **The model writes prose, never data** — every number in a field report is
  measured.
- **Keys never leave the machine that owns them.**
- **Nothing runs anywhere that doesn't have to.**

## The road: bidderdone

Free is slow because free is subsidized by nobody. **bidderdone** is the
proposed fix: businesses bid to have a task carried in the model's context,
and the winning bid mints speedup credit for the user who takes it.

- **The free tier stays honest.** No ads in the output, no bias in the pipe.
- **The speedup is earned, not bought.** You go faster by engaging with the
  sponsor, and you're told that's the trade.
- **Advertisers bid per genuine inquiry** — the only ad unit where the user
  asks for the ad.

That produces a new kind of free endpoint: slightly sponsor-biased, notably
faster. And because it lives on the open internet, anytimelime finds it the
same way it finds everything else — by probing it and writing down what
happened.

## Status

- [x] Catalog discovery + parallel tool-call probing
- [x] AI-synthesized tiering with heuristic fallback
- [x] Daily field report + machine-readable roster endpoint
- [x] Smart launcher with rotation and offline fallback
- [x] Docker packaging, HTTP publishing, keyless configs
- [ ] Latency trending — turn the roster from a list into a forecast
- [ ] Credit ledger + inquiry minting
- [ ] Advertiser station

---

*Built on a conversation about captchas, superposition, closing doors, and
Costco samples. Don't panic.* 🍋

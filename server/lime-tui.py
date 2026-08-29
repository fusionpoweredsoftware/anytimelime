#!/usr/bin/env python3
"""lime-tui — a Claude Code-style terminal UI for testing the razzle-dazzle stack.

The claude CLI is the real harness but a heavy one; this is the light one you
can read in a sitting. It speaks the Anthropic protocol (/v1/messages) to any
endpoint — point it at qwen-proxy.py to drive a LOCAL Ollama model, or at any
Anthropic-compatible base URL — and implements the agent loop itself:

  model emits tool_use  ->  you approve (y/n, like Claude Code permissions)
                        ->  lime-tui executes the tool CLIENT-side
                        ->  tool_result goes back into the transcript
                        ->  model synthesizes, visibly

Tools are ours, not the model's: WebSearch is real (DuckDuckGo HTML, no key),
executed by this program — the model only asks. That is the TCOS shape: the
capability is the harness's; the model's job is fidelity.

Usage:
  python3 lime-tui.py                          # interactive, http://localhost:8098
  python3 lime-tui.py --base-url URL [--model NAME]
  python3 lime-tui.py -p "question"            # one-shot (test mode, like claude -p)
  BASE_URL / LIME_MODEL env vars also honored.

Slash commands: /new /model /tools /raw /quit
"""
from __future__ import annotations

import argparse
import html as htmllib
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import uuid

# --- colors --------------------------------------------------------------------

DIM = "\033[2m"
BOLD = "\033[1m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
MAGENTA = "\033[35m"
RESET = "\033[0m"


def c(s: str, *codes: str) -> str:
    return "".join(codes) + s + RESET


# --- tools (client-side, ours) ---------------------------------------------------

TOOLS = [
    {
        "name": "WebSearch",
        "description": ("Search the web for current information. Returns a list of "
                        "results (title, url, snippet)."),
        "input_schema": {
            "type": "object",
            "properties": {"query": {"type": "string",
                                     "description": "the search query"}},
            "required": ["query"],
        },
    },
    {
        "name": "WebFetch",
        "description": ("Fetch a web page by URL and return its readable text "
                        "(HTML stripped). Use for reading a specific page the "
                        "user gave you or a search result you want to open."),
        "input_schema": {
            "type": "object",
            "properties": {"url": {"type": "string",
                                   "description": "the full URL to fetch"}},
            "required": ["url"],
        },
    },
]


UA = ("Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0")


def _strip(s: str) -> str:
    return htmllib.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", s))).strip()


def _bing(query: str, n: int) -> list[str]:
    url = "https://www.bing.com/search?q=" + urllib.parse.quote(query)
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept-Language": "en-US,en;q=0.9"})
    with urllib.request.urlopen(req, timeout=20) as r:
        page = r.read().decode("utf-8", "replace")
    out = []
    for chunk in page.split('<li class="b_algo"')[1:]:
        m = re.search(r'<h2[^>]*><a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', chunk)
        if not m:
            continue
        href, title = _unwrap_bing(htmllib.unescape(m.group(1))), _strip(m.group(2))
        sm = re.search(r'<p[^>]*>(.*?)</p>', chunk, re.S)
        snip = _strip(sm.group(1)) if sm else ""
        out.append(f"{title}\n  {href}\n  {snip}")
        if len(out) >= n:
            break
    return out


def _ddg(query: str, n: int) -> list[str]:
    url = "https://html.duckduckgo.com/html/?q=" + urllib.parse.quote(query)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as r:
        page = r.read().decode("utf-8", "replace")
    out = []
    for m in re.finditer(
            r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>.*?'
            r'class="result__snippet"[^>]*>(.*?)</a>', page, re.S):
        href, title, snip = m.groups()
        qm = re.search(r"uddg=([^&]+)", href)
        if qm:
            href = urllib.parse.unquote(qm.group(1))
        out.append(f"{_strip(title)}\n  {href}\n  {_strip(snip)}")
        if len(out) >= n:
            break
    return out


def _unwrap_bing(href: str) -> str:
    """Bing wraps result urls in /ck/a redirects; the real url is the base64
    `u=a1<...>` param (URL-encoded, urlsafe-b64, sometimes padded)."""
    m = re.search(r"[?&]u=a1([A-Za-z0-9_\-=]+)", href)
    if not m:
        return href
    b64 = urllib.parse.unquote(m.group(1))
    b64 += "=" * (-len(b64) % 4)
    import base64
    try:
        return base64.urlsafe_b64decode(b64).decode("utf-8", "replace")
    except Exception:
        return href


def web_search(query: str, n: int = 6) -> str:
    """Keyless web search: Bing HTML first (ddg bot-walls often), ddg fallback."""
    for engine in (_bing, _ddg):
        try:
            results = engine(query, n)
        except Exception as e:
            print(c(f"  ⎿ {engine.__name__} failed: {type(e).__name__}", DIM))
            continue
        if results:
            return "\n\n".join(f"[{i+1}] {r}" for i, r in enumerate(results))
    return "NO RESULTS (both engines failed or blocked — try again)"


def web_fetch(url: str, max_chars: int = 12000) -> str:
    """Fetch a page and return readable text: HTML→text, scripts/styles dropped,
    whitespace squeezed, truncated so a 4b context can hold it."""
    if not re.match(r"^https?://", url):
        url = "https://" + url
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept-Language": "en-US,en;q=0.9",
                                               "Accept-Encoding": "gzip, deflate"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read(2_000_000)
        enc = (r.headers.get("Content-Encoding") or "").lower()
        if "gzip" in enc:
            import gzip
            raw = gzip.decompress(raw)
        elif "deflate" in enc:
            import zlib
            raw = zlib.decompress(raw)
        page = raw.decode(r.headers.get_content_charset() or "utf-8", "replace")
    title = ""
    tm = re.search(r"<title[^>]*>(.*?)</title>", page, re.S | re.I)
    if tm:
        title = _strip(tm.group(1))
    # drop the non-content regions, then tags
    page = re.sub(r"(?is)<(script|style|noscript|svg|head)[^>]*>.*?</\1>", " ", page)
    page = re.sub(r"(?s)<[^>]+>", " ", page)
    text = re.sub(r"[ \t]+", " ", htmllib.unescape(page))
    text = re.sub(r"\n\s*\n+", "\n\n", text).strip()
    head = f"TITLE: {title}\nURL: {url}\n\n" if title else f"URL: {url}\n\n"
    if len(text) > max_chars:
        text = text[:max_chars] + f"\n\n[TRUNCATED at {max_chars} chars]"
    return head + text


def run_tool(name: str, inp: dict) -> str:
    if name == "WebSearch":
        return web_search(str(inp.get("query", "")))
    if name == "WebFetch":
        try:
            return web_fetch(str(inp.get("url", "")))
        except Exception as e:
            return f"FETCH ERROR: {type(e).__name__}: {e}"
    return f"ERROR: unknown tool {name}"


# --- Anthropic client -------------------------------------------------------------


def call_model(base_url: str, model: str, system: str, messages: list[dict],
               tools: list[dict] | None = None) -> dict:
    payload = {"model": model, "max_tokens": 2048, "system": system,
               "messages": messages, "stream": False}
    if tools:
        payload["tools"] = tools
    req = urllib.request.Request(
        base_url.rstrip("/") + "/v1/messages",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "x-api-key": os.environ.get("ANTHROPIC_API_KEY", "dummy"),
                 "anthropic-version": "2023-06-01"},
    )
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(r.read())


# --- agent loop --------------------------------------------------------------------

SYSTEM = ("You are a careful web research assistant running in a terminal. "
          "You have two tools: WebSearch(query) to search the web, and "
          "WebFetch(url) to read a specific page. If the user gives you a URL, "
          "WebFetch it. For anything current, factual, or outside your training "
          "data, search first. Answer strictly from what the tools returned, "
          "cite the urls you used, and say plainly when they do not contain "
          "the answer.")


def agent_turn(base_url: str, model: str, messages: list[dict],
               show_raw: bool = False, auto_approve: bool = False) -> str:
    """One full agent turn: model -> (tool_use -> execute -> feed) loop -> text."""
    for _hop in range(6):  # bounded, like any sane harness
        resp = call_model(base_url, model, SYSTEM, messages, TOOLS)
        if show_raw:
            print(c(json.dumps(resp, indent=2)[:2000], DIM))
        blocks = resp.get("content", [])
        text = "\n".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        calls = [b for b in blocks if b.get("type") == "tool_use"]
        if text.strip():
            print(text.strip())
        if resp.get("stop_reason") != "tool_use" or not calls:
            return text
        messages.append({"role": "assistant", "content": blocks})
        results = []
        for tc in calls:
            name, inp = tc.get("name", ""), tc.get("input", {})
            arg = inp.get("query") or inp.get("url") or json.dumps(inp)
            print(c(f"  ⏺ {name}({arg})", CYAN, BOLD), flush=True)
            if not auto_approve:
                ok = input(c("  allow? [y/N/a(lways)] ", YELLOW)).strip().lower()
                if ok == "a":
                    auto_approve = True
                elif ok != "y":
                    out = "Permission denied by user."
                    print(c(f"  ⎿ denied {name}", RED))
                    results.append({"type": "tool_result",
                                    "tool_use_id": tc.get("id", ""),
                                    "content": out})
                    continue
            out = run_tool(name, inp)
            head = out.splitlines()[0][:100] if out else "(empty)"
            print(c(f"  ⎿ {head}{'…' if len(out) > 100 else ''}", GREEN))
            results.append({"type": "tool_result",
                            "tool_use_id": tc.get("id", ""), "content": out})
        messages.append({"role": "user", "content": results})
    print(c("  (tool-hop limit reached)", DIM))
    return ""


# --- interactive UI -----------------------------------------------------------------

BANNER = f"""
{c('lime-tui', MAGENTA, BOLD)} — test client for the razzle-dazzle stack
  endpoint  {c('{}', CYAN)}
  model     {c('{}', CYAN)}
  tools     {c(', '.join(t['name'] for t in TOOLS), CYAN)}
  commands  {c('/new /model /tools /raw /quit', DIM)}
"""


def repl(base_url: str, model: str) -> None:
    print(BANNER.format(base_url, model))
    messages: list[dict] = []
    show_raw = False
    while True:
        try:
            prompt = input(c("\n❯ ", MAGENTA, BOLD)).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not prompt:
            continue
        if prompt == "/quit":
            break
        if prompt == "/new":
            messages = []
            print(c("  (new session)", DIM))
            continue
        if prompt == "/raw":
            show_raw = not show_raw
            print(c(f"  (raw responses: {'on' if show_raw else 'off'})", DIM))
            continue
        if prompt == "/tools":
            for t in TOOLS:
                print(c(f"  ⏺ {t['name']}", CYAN) + f" — {t['description']}")
            continue
        if prompt.startswith("/model"):
            parts = prompt.split(maxsplit=1)
            if len(parts) == 2:
                model = parts[1]
            print(c(f"  model = {model}", DIM))
            continue
        if prompt.startswith("/"):
            print(c(f"  unknown command {prompt}", RED))
            continue
        messages.append({"role": "user", "content": prompt})
        try:
            agent_turn(base_url, model, messages, show_raw=show_raw)
        except KeyboardInterrupt:
            print(c("\n  (interrupted)", DIM))
        except Exception as e:
            print(c(f"  ERROR {type(e).__name__}: {e}", RED))


def main() -> int:
    ap = argparse.ArgumentParser(description="Claude Code-style test client")
    ap.add_argument("--base-url", default=os.environ.get(
        "BASE_URL", "http://localhost:8098"))
    ap.add_argument("--model", default=os.environ.get("LIME_MODEL", "qwen3.5:4b"))
    ap.add_argument("-p", "--print", dest="one_shot", default=None,
                    help="one-shot mode (like claude -p); auto-approves tools")
    args = ap.parse_args()

    if args.one_shot is not None:
        messages = [{"role": "user", "content": args.one_shot}]
        agent_turn(args.base_url, args.model, messages, auto_approve=True)
        return 0
    repl(args.base_url, args.model)
    return 0


if __name__ == "__main__":
    sys.exit(main())

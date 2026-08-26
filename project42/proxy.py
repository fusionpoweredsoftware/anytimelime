#!/usr/bin/env python3
"""
proxy.py — Project 42 smart access proxy.

Exposes an Anthropic-compatible /v1/messages endpoint that routes to
whichever free OpenRouter model currently holds each tier (per
openrouter-free.config.json, refreshed by synthesize.sh), with automatic
failover down the passing-model list (public/models.json) when a model
errors out before producing output.

Stdlib only. Threaded. Streams SSE.

Endpoints:
  POST /v1/messages   (streaming and non-streaming)
  GET  /healthz
"""

import json
import os
import re
import sys
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_DIR = os.environ.get("P42_APP_DIR", "/app")
CONFIG_PATH = os.path.join(APP_DIR, "openrouter-free.config.json")
MODELS_PATH = os.path.join(APP_DIR, "public", "models.json")
OPENROUTER_KEY = os.environ.get("OPENROUTER_API_KEY", "")
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
UPSTREAM_TIMEOUT = float(os.environ.get("PROXY_UPSTREAM_TIMEOUT", "600"))

_lock = threading.Lock()
_cache = {"config": None, "models": None, "mtime": 0}


def load_routing():
    """Reload tier assignments + failover order if files changed."""
    try:
        cfg_m = os.path.getmtime(CONFIG_PATH)
        mod_m = os.path.getmtime(MODELS_PATH) if os.path.exists(MODELS_PATH) else 0
        with _lock:
            if max(cfg_m, mod_m) == _cache["mtime"]:
                return _cache["config"], _cache["models"]
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
        models = []
        if os.path.exists(MODELS_PATH):
            with open(MODELS_PATH) as f:
                models = json.load(f).get("order", [])
        with _lock:
            _cache.update(config=cfg, models=models, mtime=max(cfg_m, mod_m))
        return cfg, models
    except Exception as e:
        sys.stderr.write(f"routing load error: {e}\n")
        return _cache["config"], _cache["models"]


def anthropic_model_to_tier(model):
    m = (model or "").lower()
    if "haiku" in m:
        return "HAIKU"
    if "opus" in m:
        return "OPUS"
    return "SONNET"


def tier_model(cfg, tier):
    return (cfg or {}).get(f"ANTHROPIC_DEFAULT_{tier}_MODEL")


def candidate_models(model):
    """Ordered failover list: assigned tier model first, then the rest."""
    cfg, order = load_routing()
    tier = anthropic_model_to_tier(model)
    primary = tier_model(cfg, tier)
    out = []
    if primary:
        out.append(primary)
    for m in order:
        if m not in out:
            out.append(m)
    if not out:
        out = ["openrouter/free"]
    return out


# ---------- Anthropic -> OpenRouter request translation ----------

def translate_messages(body):
    system = body.get("system")
    messages = []
    if system:
        if isinstance(system, list):
            system = "\n".join(b.get("text", "") for b in system)
        messages.append({"role": "system", "content": system})

    for msg in body.get("messages", []):
        role = msg["role"]
        content = msg.get("content")
        if isinstance(content, str):
            messages.append({"role": role, "content": content})
            continue
        if not isinstance(content, list):
            continue
        if role == "assistant":
            text_parts, tool_calls = [], []
            for b in content:
                t = b.get("type")
                if t == "text":
                    text_parts.append(b.get("text", ""))
                elif t == "tool_use":
                    tool_calls.append({
                        "id": b.get("id", "call_%d" % len(tool_calls)),
                        "type": "function",
                        "function": {
                            "name": b.get("name", ""),
                            "arguments": json.dumps(b.get("input", {})),
                        },
                    })
            m = {"role": "assistant",
                 "content": "\n".join(text_parts) or None}
            if tool_calls:
                m["tool_calls"] = tool_calls
            messages.append(m)
        else:  # user
            parts = []
            for b in content:
                t = b.get("type")
                if t == "text":
                    parts.append(b.get("text", ""))
                elif t == "tool_result":
                    inner = b.get("content")
                    if isinstance(inner, list):
                        inner = "\n".join(x.get("text", "") for x in inner
                                         if isinstance(x, dict))
                    parts.append(inner if isinstance(inner, str) else json.dumps(inner))
            messages.append({"role": role, "content": "\n".join(parts) or ""})
    return messages


def translate_tools(body):
    tools = body.get("tools")
    if not tools:
        return None
    return [{"type": "function",
             "function": {"name": t["name"],
                          "description": t.get("description", ""),
                          "parameters": t.get("input_schema", {"type": "object"})}}
            for t in tools]


def build_upstream_body(body, model):
    out = {
        "model": model,
        "messages": translate_messages(body),
        "max_tokens": body.get("max_tokens", 4096),
        "stream": bool(body.get("stream")),
    }
    if body.get("temperature") is not None:
        out["temperature"] = body["temperature"]
    if body.get("top_p") is not None:
        out["top_p"] = body["top_p"]
    if body.get("stop_sequences"):
        out["stop"] = body["stop_sequences"]
    tools = translate_tools(body)
    if tools:
        out["tools"] = tools
    return out


# ---------- OpenRouter -> Anthropic response translation ----------

def sse_event(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()


class ToolCallAssembler:
    """Accumulates streamed OpenRouter tool_call deltas into complete blocks."""

    def __init__(self):
        self.calls = {}  # index -> {id, name, args}

    def add(self, delta):
        idx = delta.get("index", 0)
        slot = self.calls.setdefault(idx, {"id": None, "name": "", "args": ""})
        if delta.get("id"):
            slot["id"] = delta["id"]
        fn = delta.get("function", {})
        if fn.get("name"):
            slot["name"] += fn["name"]
        if fn.get("arguments"):
            slot["args"] += fn["arguments"]

    def blocks(self):
        out = []
        for idx in sorted(self.calls):
            c = self.calls[idx]
            cid = c["id"] or f"toolu_{idx:04d}"
            try:
                args = json.loads(c["args"] or "{}")
            except json.JSONDecodeError:
                args = {"_raw": c["args"]}
            out.append({"id": cid, "name": c["name"], "input": args})
        return out


def stream_upstream(handler, body, model):
    """Stream one upstream request, translating SSE as it arrives.
    Returns True if the response started successfully (failover no longer
    possible once the client has received bytes)."""
    req = urllib.request.Request(
        OPENROUTER_URL,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {OPENROUTER_KEY}",
                 "Content-Type": "application/json",
                 "Accept": "text/event-stream"},
        method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        sys.stderr.write(f"upstream {e.code} on {model}: {detail}\n")
        return False, e.code
    except Exception as e:
        sys.stderr.write(f"upstream conn error on {model}: {e}\n")
        return False, 502

    if resp.status != 200:
        resp.close()
        return False, resp.status

    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.end_headers()

    msg_id = f"msg_p42_{int(time.time()*1000)}"
    handler.wfile.write(sse_event("message_start", {
        "type": "message_start",
        "message": {"id": msg_id, "type": "message", "role": "assistant",
                    "model": model, "content": [],
                    "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": 0, "output_tokens": 0}},
    }))
    handler.wfile.write(sse_event("ping", {"type": "ping"}))

    text_open = False
    think_open = False
    block_index = 0
    tools = ToolCallAssembler()
    stop_reason = "end_turn"
    out_chars = 0

    def close_think():
        nonlocal think_open, block_index
        if think_open:
            handler.wfile.write(sse_event("content_block_delta", {
                "type": "content_block_delta", "index": block_index,
                "delta": {"type": "signature_delta",
                          "signature": "EqQBCkgIARABGAIiQg==..p42"}}))
            handler.wfile.write(sse_event("content_block_stop", {
                "type": "content_block_stop", "index": block_index}))
            block_index += 1
            think_open = False

    def open_text():
        nonlocal text_open, block_index
        if not text_open:
            handler.wfile.write(sse_event("content_block_start", {
                "type": "content_block_start", "index": block_index,
                "content_block": {"type": "text", "text": ""}}))
            text_open = True

    def close_text():
        nonlocal text_open, block_index
        if text_open:
            handler.wfile.write(sse_event("content_block_stop", {
                "type": "content_block_stop", "index": block_index}))
            block_index += 1
            text_open = False

    buf = b""
    try:
        for chunk in resp:
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.decode(errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    ev = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                choice = (ev.get("choices") or [{}])[0]
                delta = choice.get("delta", {}) or {}
                if delta.get("reasoning") and not think_open:
                    close_text()
                    handler.wfile.write(sse_event("content_block_start", {
                        "type": "content_block_start", "index": block_index,
                        "content_block": {"type": "thinking", "thinking": ""}}))
                    think_open = True
                if delta.get("reasoning"):
                    handler.wfile.write(sse_event("content_block_delta", {
                        "type": "content_block_delta", "index": block_index,
                        "delta": {"type": "thinking_delta",
                                  "thinking": delta["reasoning"]}}))
                if delta.get("content"):
                    close_think()
                    open_text()
                    open_text()
                    out_chars += len(delta["content"])
                    handler.wfile.write(sse_event("content_block_delta", {
                        "type": "content_block_delta", "index": block_index,
                        "delta": {"type": "text_delta", "text": delta["content"]}}))
                for tc in delta.get("tool_calls") or []:
                    close_text()
                    tools.add(tc)
                if choice.get("finish_reason"):
                    fr = choice["finish_reason"]
                    stop_reason = "tool_use" if fr == "tool_calls" else \
                                  "max_tokens" if fr == "length" else "end_turn"
    except Exception as e:
        sys.stderr.write(f"stream error on {model}: {e}\n")

    close_think()
    close_text()
    for call in tools.blocks():
        handler.wfile.write(sse_event("content_block_start", {
            "type": "content_block_start", "index": block_index,
            "content_block": {"type": "tool_use", "id": call["id"],
                              "name": call["name"], "input": {}}}))
        handler.wfile.write(sse_event("content_block_delta", {
            "type": "content_block_delta", "index": block_index,
            "delta": {"type": "input_json_delta",
                      "partial_json": json.dumps(call["input"])}}))
        handler.wfile.write(sse_event("content_block_stop", {
            "type": "content_block_stop", "index": block_index}))
        block_index += 1

    handler.wfile.write(sse_event("message_delta", {
        "type": "message_delta",
        "delta": {"stop_reason": stop_reason, "stop_sequence": None},
        "usage": {"output_tokens": max(1, out_chars // 4)}}))
    handler.wfile.write(sse_event("message_stop", {"type": "message_stop"}))
    resp.close()
    return True, 200


def nonstream_upstream(body, model):
    """Blocking request; returns (anthropic_response_dict, http_code)."""
    req = urllib.request.Request(
        OPENROUTER_URL,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {OPENROUTER_KEY}",
                 "Content-Type": "application/json"},
        method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
        data = json.load(resp)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        sys.stderr.write(f"upstream {e.code} on {model}: {detail}\n")
        return None, e.code
    except Exception as e:
        sys.stderr.write(f"upstream conn error on {model}: {e}\n")
        return None, 502

    msg = (data.get("choices") or [{}])[0].get("message", {})
    content = []
    if msg.get("content"):
        content.append({"type": "text", "text": msg["content"]})
    for tc in msg.get("tool_calls") or []:
        try:
            args = json.loads(tc["function"].get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        content.append({"type": "tool_use", "id": tc.get("id", "toolu_0"),
                        "name": tc["function"]["name"], "input": args})
    fr = (data.get("choices") or [{}])[0].get("finish_reason", "stop")
    usage = data.get("usage", {})
    return {
        "id": f"msg_p42_{int(time.time()*1000)}",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content or [{"type": "text", "text": ""}],
        "stop_reason": "tool_use" if fr == "tool_calls" else
                       "max_tokens" if fr == "length" else "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": usage.get("prompt_tokens", 0),
                  "output_tokens": usage.get("completion_tokens", 0)},
    }, 200


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        if self.path == "/healthz":
            cfg, models = load_routing()
            body = json.dumps({
                "ok": True,
                "opus": tier_model(cfg, "OPUS"),
                "sonnet": tier_model(cfg, "SONNET"),
                "haiku": tier_model(cfg, "HAIKU"),
                "failover_order": models,
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.split("?")[0] != "/v1/messages":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_error(400, "invalid JSON")
            return

        want_stream = bool(body.get("stream"))
        candidates = candidate_models(body.get("model"))
        body.pop("anthropic_version", None)

        for model in candidates:
            upstream = build_upstream_body(body, model)
            if want_stream:
                ok, code = stream_upstream(self, upstream, model)
                if ok:
                    return
            else:
                translated, code = nonstream_upstream(upstream, model)
                if translated is not None:
                    payload = json.dumps(translated).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
            sys.stderr.write(f"failing over from {model}\n")

        err = json.dumps({"type": "error",
                          "error": {"type": "api_error",
                                    "message": f"all {len(candidates)} candidate "
                                               f"models failed"}}).encode()
        self.send_response(502)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(err)))
        self.end_headers()
        self.wfile.write(err)


if __name__ == "__main__":
    port = int(os.environ.get("PROXY_PORT", "8043"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    sys.stderr.write(f"project42 proxy listening on :{port}\n")
    server.serve_forever()

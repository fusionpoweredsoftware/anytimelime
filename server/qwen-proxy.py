#!/usr/bin/env python3
"""qwen-proxy — Anthropic-protocol translating proxy for a LOCAL Ollama model.

Same trick as or-proxy.py, pointed the other direction: the claude CLI (and
therefore the razzle-dazzle gateway) speaks the Anthropic protocol to
ANTHROPIC_BASE_URL. Point it here and any tool-call-capable LOCAL model rides
the full claude harness — tools, web search, everything — at zero API cost.

This is the TCOS demo: qwen3.5:4b was not born with web search. The harness
grants the capability; the model only has to emit a well-formed tool_use and
stay faithful to the tool_result that comes back (the fidelity the FE meter
measures).

Translation (Anthropic /v1/messages  ->  Ollama /api/chat):
  - system: string | [{text}]        -> system string
  - content blocks: text             -> {content}
                    tool_use         -> assistant tool_calls
                    tool_result      -> user role=tool message
  - tools: [{name, description,
     input_schema}]                  -> Ollama function parameters
  - response: text + tool_calls      -> content blocks + stop_reason
  - stream: true                     -> Anthropic SSE event stream

Run:  python3 server/qwen-proxy.py [port]        (default 8098)
Env:  QWEN_PROXY_MODEL   ollama tag (default qwen3.5:4b)
      QWEN_PROXY_HOST    ollama host (default http://localhost:11434)
"""
import json
import os
import sys
import time
import urllib.request
import uuid
import http.server

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8098
MODEL = os.environ.get("QWEN_PROXY_MODEL", "qwen3.5:4b")
HOST = os.environ.get("QWEN_PROXY_HOST", "http://localhost:11434")


# --- Anthropic request -> Ollama request --------------------------------------


def _text_of(content) -> str:
    """Flatten an Anthropic content field (string or block list) to text."""
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text", ""))
    return "\n".join(out)


def _to_ollama_messages(req: dict) -> list[dict]:
    """Anthropic messages -> Ollama messages.

    tool_result blocks arrive as user-turn content; Ollama wants them as a
    separate {role: tool} message naming the tool call they answer.
    """
    out = []
    # Anthropic tool_result blocks carry only tool_use_id, not the tool name;
    # Ollama wants the name to bind the result to its call. Walk the transcript
    # in order and remember id -> name from the assistant tool_use blocks.
    id2name: dict[str, str] = {}
    for m in req.get("messages", []):
        role = m.get("role", "user")
        content = m.get("content")
        if isinstance(content, str) or (
            isinstance(content, list) and all(
                isinstance(b, dict) and b.get("type") == "text" for b in content
            )
        ):
            out.append({"role": role, "content": _text_of(content)})
            continue
        tool_calls, tool_results, texts = [], [], []
        for b in content or []:
            t = b.get("type")
            if t == "text":
                texts.append(b.get("text", ""))
            elif t == "tool_use":
                id2name[b.get("id", "")] = b.get("name", "")
                tool_calls.append({
                    "function": {
                        "name": b.get("name", ""),
                        "arguments": b.get("input", {}),
                    }
                })
            elif t == "tool_result":
                tool_results.append({
                    "role": "tool",
                    "content": _text_of(b.get("content")) or "(no content)",
                    "tool_name": id2name.get(b.get("tool_use_id", ""), "unknown"),
                })
        if texts:
            out.append({"role": role, "content": "\n".join(texts)})
        if tool_calls:
            msg = {"role": "assistant", "content": texts and "\n".join(texts) or ""}
            msg["tool_calls"] = tool_calls
            out.append(msg)
        out.extend(tool_results)
    return out


def _to_ollama_tools(req: dict) -> list[dict]:
    tools = []
    for t in req.get("tools") or []:
        if t.get("type") and t.get("type") not in ("custom", "function", "auto"):
            continue  # server-side tool types (web_search_20250305 etc.): skip —
            # the CLI runs WebSearch itself as a client tool, so these never
            # appear in practice; ignoring them keeps the schema Ollama accepts.
        schema = t.get("input_schema") or {}
        tools.append({
            "type": "function",
            "function": {
                "name": t.get("name", ""),
                "description": t.get("description", ""),
                "parameters": schema,
            },
        })
    return tools


def _ollama_payload(req: dict) -> dict:
    payload = {
        "model": MODEL,
        "messages": _to_ollama_messages(req),
        "stream": False,
        "think": False,
        "options": {
            "temperature": req.get("temperature", 0.3),
            # the claude CLI system prompt + tool schemas + search results are
            # large; the §11o lesson applies — size the window to the request,
            # never assume 4k. Generous over-estimate (chars ~ 1 token each
            # after the /4 is skipped on purpose), capped at the model's sane
            # single-3090 window.
            "num_ctx": min(65536, 4096 + len(json.dumps(req.get("messages", [])))),
        },
    }
    tools = _to_ollama_tools(req)
    if tools:
        payload["tools"] = tools
    sysmsg = req.get("system")
    if sysmsg:
        payload["messages"] = [{"role": "system",
                                "content": _text_of(sysmsg)}] + payload["messages"]
    return payload


# --- Ollama response -> Anthropic response ------------------------------------


def _to_anthropic(oll: dict) -> dict:
    msg = oll.get("message", {})
    blocks, stop_reason = [], "end_turn"
    text = (msg.get("content") or "").strip()
    if text:
        blocks.append({"type": "text", "text": text})
    for i, tc in enumerate(msg.get("tool_calls") or []):
        fn = tc.get("function", {})
        stop_reason = "tool_use"
        blocks.append({
            "type": "tool_use",
            "id": f"toolu_{uuid.uuid4().hex[:20]}",
            "name": fn.get("name", ""),
            "input": fn.get("arguments") or {},
        })
    if not blocks:
        blocks.append({"type": "text", "text": ""})
    return {
        "id": f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message",
        "role": "assistant",
        "model": oll.get("model", MODEL),
        "content": blocks,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": oll.get("prompt_eval_count", 0),
            "output_tokens": oll.get("eval_count", 0),
        },
    }


# --- SSE -----------------------------------------------------------------------

SSE_EVENTS = ("message_start", "ping", "content_block_start", "content_block_delta",
              "content_block_stop", "message_delta", "message_stop")


def _sse(resp: dict) -> bytes:
    """Emit a complete Anthropic SSE stream from a finished response."""
    out = [
        f"event: message_start\ndata: {json.dumps({'type':'message_start','message':resp})}\n\n",
        "event: ping\ndata: {\"type\":\"ping\"}\n\n",
    ]
    for i, b in enumerate(resp["content"]):
        out.append(f"event: content_block_start\ndata: "
                   f"{json.dumps({'type':'content_block_start','index':i,'content_block':b})}\n\n")
        if b["type"] == "text":
            delta = {"type": "content_block_delta", "index": i,
                     "delta": {"type": "text_delta", "text": b["text"]}}
        else:
            delta = {"type": "content_block_delta", "index": i,
                     "delta": {"type": "input_json_delta",
                               "partial_json": json.dumps(b["input"])}}
        out.append(f"event: content_block_delta\ndata: {json.dumps(delta)}\n\n")
        out.append(f"event: content_block_stop\ndata: "
                   f"{json.dumps({'type':'content_block_stop','index':i})}\n\n")
    out.append(f"event: message_delta\ndata: {json.dumps({'type':'message_delta','delta':{'stop_reason':resp['stop_reason'],'stop_sequence':None},'usage':{'output_tokens':resp['usage']['output_tokens']}})}\n\n")
    out.append("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
    return "".join(out).encode()


# --- HTTP server ---------------------------------------------------------------


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write(f"[qwen-proxy] {fmt % a}\n")

    def _json(self, code: int, obj: dict):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] in ("/v1/models", "/models"):
            self._json(200, {"data": [{"id": MODEL, "type": "model",
                                       "display_name": MODEL}]})
        else:
            self._json(404, {"error": {"type": "not_found_error"}})

    def do_POST(self):
        if not self.path.split("?")[0].endswith("/messages"):
            self._json(404, {"error": {"type": "not_found_error"}})
            return
        n = int(self.headers.get("content-length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"error": {"type": "invalid_request_error",
                                       "message": "bad json"}})
            return
        payload = _ollama_payload(req)
        r = urllib.request.Request(f"{HOST}/api/chat",
                                   data=json.dumps(payload).encode(),
                                   headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=600) as resp:
                oll = json.loads(resp.read())
        except Exception as e:
            self._json(502, {"error": {"type": "api_error",
                                       "message": f"qwen-proxy ollama: {e}"}})
            return
        anth = _to_anthropic(oll)
        # one line per turn: what came back from the model (debug harness loop)
        kinds = [(b["type"], b.get("name", "")) for b in anth["content"]]
        sys.stderr.write(f"[qwen-proxy] turn: stop={anth['stop_reason']} "
                         f"blocks={kinds}\n")
        if req.get("stream"):
            body = _sse(anth)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self._json(200, anth)


if __name__ == "__main__":
    print(f"[qwen-proxy] {HOST} model={MODEL} on 127.0.0.1:{PORT} "
          f"(Anthropic /v1/messages -> Ollama /api/chat)", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

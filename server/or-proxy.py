#!/usr/bin/env python3
"""or-proxy — Anthropic-protocol translating proxy for OpenRouter.

The claude CLI (and therefore the razzle-dazzle gateway) speaks the Anthropic
protocol to ANTHROPIC_BASE_URL. OpenRouter serves that protocol at
/api/v1/messages, but the CLI appends query params (`?beta=true`) and a path
shape OpenRouter 404s on — which the CLI then misreports as "unrecognized
model". This proxy sits between the CLI and OpenRouter and fixes the wire
details, nothing else: any tool-call-capable model behind OpenRouter can then
ride the full claude harness — tools, web search, everything.

Run:  OR_KEY=sk-or-... python3 server/or-proxy.py [port]   (default 8099)
The key lives only in the proxy's environment; callers use a dummy token.
"""
import http.server
import os
import sys
import urllib.error
import urllib.request

UP = "https://openrouter.ai/api"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
KEY = os.environ.get("OR_KEY", "")


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _fwd(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else b""
        # strip query strings (?beta=true) — OpenRouter 404s on them
        req = urllib.request.Request(
            UP + self.path.split("?")[0], data=body or None, method=self.command
        )
        req.add_header("User-Agent", "claude-cli/2.1.247")
        for h in ("content-type", "anthropic-version", "accept"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        if KEY:
            req.add_header("Authorization", "Bearer " + KEY)
        try:
            r = urllib.request.urlopen(req, timeout=300)
            code, rb, rh = r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            code, rb, rh = e.code, e.read(), e.headers
        except Exception as e:  # network down, etc.
            code, rb = 502, b'{"error":"or-proxy: ' + str(e).encode() + b'"}'
            rh = {}
        self.send_response(code)
        for h in ("content-type",):
            if rh.get(h):
                self.send_header(h, rh[h])
        self.end_headers()
        self.wfile.write(rb)

    do_GET = do_POST = _fwd


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

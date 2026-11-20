"""Serves a fixture site from crates/sd-check/tests/fixtures/sites/<name> on 127.0.0.1 (the same
rules as the Rust tests' server: / -> index.html, /a -> a.html, {{origin}} substituted, _server.json
challenge list). Prints the origin on the first line of stdout, then serves until killed.

    python3 serve_fixture.py <site dir>
"""
import http.server
import json
import os
import sys

root = os.path.abspath(sys.argv[1])
try:
    with open(os.path.join(root, "_server.json")) as f:
        challenge = json.load(f).get("challenge", [])
except OSError:
    challenge = []


def file_for(path):
    rel = path.split("?")[0].lstrip("/")
    if any(p == ".." or p.startswith("_") for p in rel.split("/")):
        return None
    if not rel:
        cands = ["index.html"]
    elif rel.endswith("/"):
        cands = [rel + "index.html"]
    else:
        cands = [rel, rel + ".html", rel + "/index.html"]
    for c in cands:
        full = os.path.join(root, c)
        if os.path.isfile(full):
            return full
    return None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, head_only):
        ua = self.headers.get("User-Agent", "")
        extra = {}
        if any(t in ua for t in challenge):
            status, ctype = 403, "text/html"
            body = b"<!doctype html><title>Just a moment...</title><script>window._cf_chl_opt={}</script>"
            extra["cf-mitigated"] = "challenge"
        else:
            f = file_for(self.path)
            if f is None:
                status, ctype, body = 404, "text/plain", b"not found"
            else:
                ext = os.path.splitext(f)[1]
                ctype = {".html": "text/html; charset=utf-8", ".xml": "application/xml"}.get(ext, "text/plain; charset=utf-8")
                with open(f, encoding="utf-8") as fh:
                    body = fh.read().replace("{{origin}}", ORIGIN).encode()
                status = 200
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def do_GET(self):
        self._send(False)

    def do_HEAD(self):
        self._send(True)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
ORIGIN = "http://127.0.0.1:%d" % server.server_address[1]
print(ORIGIN, flush=True)
server.serve_forever()

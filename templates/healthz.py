#!/usr/bin/env python3
"""healthz.py — localhost-only HTTP health endpoint for the autobox.

Exposes:
  /healthz       — 200 OK if ralph.service is active, else 503
  /last-iter     — when did the bot last finish an iteration
  /spend-today   — running token-spend total (Plan 5 populates spend.log)

Binds to 127.0.0.1 only — never externally reachable.
"""
import http.server
import json
import subprocess
import time
from pathlib import Path

PORT = 9090
SPEND_LOG = Path("/var/lib/ralph/spend.log")
LAST_ITER_FILE = Path("/var/lib/ralph/last-iter.timestamp")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            r = subprocess.run(
                ["systemctl", "is-active", "ralph"],
                capture_output=True, text=True
            )
            if r.stdout.strip() == "active":
                self._send(200, "ok\n")
            else:
                self._send(503, f"ralph.service={r.stdout.strip()}\n")

        elif self.path == "/last-iter":
            if LAST_ITER_FILE.exists():
                ts = float(LAST_ITER_FILE.read_text().strip())
                self._send(200, json.dumps({
                    "last_iter_unix": ts,
                    "last_iter_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts)),
                    "age_seconds": int(time.time() - ts),
                }) + "\n", ctype="application/json")
            else:
                self._send(404, "no last-iter recorded yet\n")

        elif self.path == "/spend-today":
            today = time.strftime("%Y-%m-%d")
            total = 0
            if SPEND_LOG.exists():
                for line in SPEND_LOG.read_text().splitlines():
                    if line.startswith(today):
                        for tok in line.split():
                            if tok.startswith("total="):
                                try:
                                    total += int(tok.split("=", 1)[1])
                                except ValueError:
                                    pass
            self._send(200, json.dumps({"date": today, "tokens": total}) + "\n",
                       ctype="application/json")

        else:
            self._send(404, "not found\n")

    def _send(self, status, body, ctype="text/plain"):
        body_bytes = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def log_message(self, fmt, *args):
        pass


def main():
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()

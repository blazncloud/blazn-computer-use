#!/usr/bin/env python3
"""Dependency-free browser fixture with an independent JSON oracle."""

from __future__ import annotations

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent
STATE: dict[str, object] = {"submissions": 0, "last": None}
LOCK = threading.Lock()
EXPECTED_FIELDS = {"name", "email", "plan", "updates", "challenge"}


class Handler(BaseHTTPRequestHandler):
    def send_text(self, status: int, body: str, content_type: str) -> None:
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/state":
            with LOCK:
                body = json.dumps(STATE, sort_keys=True)
            self.send_text(200, body, "application/json")
            return
        if path == "/api/reset":
            with LOCK:
                STATE.update({"submissions": 0, "last": None})
            self.send_text(200, '{"ok":true}', "application/json")
            return
        if path in ("/", "/index.html"):
            self.send_text(
                200, (ROOT / "index.html").read_text(encoding="utf-8"),
                "text/html; charset=utf-8")
            return
        self.send_text(404, "not found", "text/plain")

    def do_POST(self) -> None:
        if urlparse(self.path).path != "/api/submit":
            self.send_text(404, "not found", "text/plain")
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.send_text(400, '{"ok":false,"error":"invalid-json"}', "application/json")
            return
        if not isinstance(payload, dict) or set(payload) != EXPECTED_FIELDS:
            self.send_text(422, '{"ok":false,"error":"shape"}', "application/json")
            return
        with LOCK:
            STATE["submissions"] = int(STATE["submissions"]) + 1
            STATE["last"] = payload
        self.send_text(200, '{"ok":true}', "application/json")

    def log_message(self, _format: str, *_args: object) -> None:
        return


def make_server(host: str, port: int) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), Handler)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = make_server(args.host, args.port)
    print(json.dumps({"url": f"http://{args.host}:{server.server_address[1]}"}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

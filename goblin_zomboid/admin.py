"""Loopback admin API with an explicit public-data boundary."""

from __future__ import annotations

import hmac
import json
from collections.abc import Callable, Mapping
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from typing import Any

from .state import public_view


class AdminApp:
    def __init__(
        self,
        *,
        public_supplier: Callable[[], Mapping[str, Any]],
        admin_supplier: Callable[[], Mapping[str, Any]],
        control: Callable[[str], Mapping[str, Any]],
        admin_token: str | None,
    ) -> None:
        self.public_supplier = public_supplier
        self.admin_supplier = admin_supplier
        self.control = control
        self.admin_token = admin_token

    def _authorized(self, headers: Mapping[str, str]) -> bool:
        if not self.admin_token:
            return False
        supplied = headers.get("X-Goblin-Admin-Token", "")
        if not supplied:
            authorization = headers.get("Authorization", "")
            if authorization.startswith("Bearer "):
                supplied = authorization[7:]
        return hmac.compare_digest(supplied, self.admin_token)

    def handle(
        self,
        method: str,
        path: str,
        *,
        headers: Mapping[str, str] | None = None,
        body: bytes = b"",
    ) -> tuple[int, dict[str, str], dict[str, Any]]:
        headers = headers or {}
        route = urlsplit(path).path
        if route == "/healthz" and method == "GET":
            return 200, {}, {"ok": True}
        if route == "/api/public/status" and method == "GET":
            return 200, {"Cache-Control": "no-store"}, public_view(
                dict(self.public_supplier())
            )
        if route.startswith("/admin/"):
            if not self._authorized(headers):
                return 401, {}, {"ok": False, "error": "unauthorized"}
            if route == "/admin/api/state" and method == "GET":
                return 200, {}, dict(self.admin_supplier())
            if route == "/admin/api/control" and method == "POST":
                if len(body) > 4096:
                    return 413, {}, {"ok": False, "error": "request too large"}
                try:
                    request = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return 400, {}, {"ok": False, "error": "invalid JSON"}
                if not isinstance(request, dict) or set(request) != {"action"}:
                    return 400, {}, {"ok": False, "error": "invalid control request"}
                action = request["action"]
                if not isinstance(action, str) or len(action) > 32:
                    return 400, {}, {"ok": False, "error": "invalid action"}
                return 200, {}, dict(self.control(action))
        return 404, {}, {"ok": False, "error": "not found"}

    def server(self, host: str = "127.0.0.1", port: int = 8781) -> ThreadingHTTPServer:
        app = self

        class Handler(BaseHTTPRequestHandler):
            def _respond(self, status: int, payload: Mapping[str, Any]) -> None:
                encoded = json.dumps(
                    dict(payload),
                    ensure_ascii=False,
                    allow_nan=False,
                    separators=(",", ":"),
                ).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self) -> None:
                status, _, payload = app.handle(
                    "GET", self.path, headers=self.headers
                )
                self._respond(status, payload)

            def do_POST(self) -> None:
                content_length = self.headers.get("Content-Length", "0")
                try:
                    length = int(content_length)
                except ValueError:
                    length = -1
                if length < 0 or length > 4096:
                    self._respond(413, {"ok": False, "error": "request too large"})
                    return
                body = self.rfile.read(length)
                status, _, payload = app.handle(
                    "POST", self.path, headers=self.headers, body=body
                )
                self._respond(status, payload)

            def log_message(self, _format: str, *_args: object) -> None:
                return

        server = ThreadingHTTPServer((host, port), Handler)
        server.daemon_threads = True
        return server


def serve(app: AdminApp, *, host: str = "127.0.0.1", port: int = 8781) -> None:
    with app.server(host, port) as server:
        server.serve_forever()

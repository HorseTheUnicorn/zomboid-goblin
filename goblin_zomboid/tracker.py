"""Read-only live-map telemetry store and HTTP surface.

Tracker telemetry is intentionally a separate data path from ``brain_view``.
It may retain exact positions for the private/public map policy, but callers
must explicitly choose the tracker APIs; the Qwen context is always built
from the redacted view.
"""

from __future__ import annotations

from contextlib import closing
import copy
import json
from pathlib import Path
import sqlite3
import threading
import time
from collections.abc import Mapping
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

from .state import brain_view


def _json(value: Any, maximum: int = 64 * 1024) -> str:
    encoded = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > maximum:
        raise ValueError("tracker payload is too large")
    return encoded


class TrackerStore:
    """Bounded SQLite history with an in-memory latest snapshot."""

    def __init__(self, path: str | Path, *, retention: int = 20_000) -> None:
        if retention < 100:
            raise ValueError("tracker retention is too small")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.retention = retention
        self.connection = sqlite3.connect(str(self.path), check_same_thread=False, isolation_level=None)
        self.connection.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self._sequence = 0
        self._latest: dict[str, Any] = {}
        self._events: list[dict[str, Any]] = []
        with self.lock:
            self.connection.execute("PRAGMA journal_mode=WAL")
            self.connection.execute("PRAGMA synchronous=FULL")
            self.connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS tracker_positions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    observed_at INTEGER NOT NULL,
                    payload_json TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS tracker_positions_recent
                    ON tracker_positions(observed_at DESC, id DESC);
                CREATE TABLE IF NOT EXISTS tracker_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    observed_at INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS tracker_events_recent
                    ON tracker_events(observed_at DESC, id DESC);
                """
            )

    def close(self) -> None:
        with self.lock:
            self.connection.close()

    def record_state(self, state: Mapping[str, Any], *, observed_at: int | None = None) -> int:
        if not isinstance(state, Mapping):
            raise ValueError("tracker state must be an object")
        payload = copy.deepcopy(dict(state))
        encoded = _json(payload)
        timestamp = int(observed_at or time.time())
        with self.condition:
            cursor = self.connection.execute(
                "INSERT INTO tracker_positions(observed_at, payload_json) VALUES (?, ?)",
                (timestamp, encoded),
            )
            row_id = int(cursor.lastrowid)
            self.connection.execute(
                "DELETE FROM tracker_positions WHERE id NOT IN "
                "(SELECT id FROM tracker_positions ORDER BY id DESC LIMIT ?)",
                (self.retention,),
            )
            self._latest = payload
            self._sequence += 1
            self.condition.notify_all()
            return row_id

    def record_event(self, kind: str, fields: Mapping[str, Any], *, observed_at: int | None = None) -> int:
        if not isinstance(kind, str) or not kind or len(kind) > 64:
            raise ValueError("invalid tracker event kind")
        payload = copy.deepcopy(dict(fields))
        encoded = _json(payload, 16 * 1024)
        timestamp = int(observed_at or time.time())
        with self.condition:
            cursor = self.connection.execute(
                "INSERT INTO tracker_events(observed_at, kind, payload_json) VALUES (?, ?, ?)",
                (timestamp, kind, encoded),
            )
            row_id = int(cursor.lastrowid)
            self.connection.execute(
                "DELETE FROM tracker_events WHERE id NOT IN "
                "(SELECT id FROM tracker_events ORDER BY id DESC LIMIT ?)",
                (self.retention,),
            )
            event = {"id": row_id, "observed_at": timestamp, "kind": kind, **payload}
            self._events.append(event)
            self._events = self._events[-256:]
            self._sequence += 1
            self.condition.notify_all()
            return row_id

    def state(self) -> dict[str, Any]:
        with self.lock:
            if self._latest:
                return copy.deepcopy(self._latest)
            row = self.connection.execute(
                "SELECT payload_json FROM tracker_positions ORDER BY id DESC LIMIT 1"
            ).fetchone()
            self._latest = json.loads(row["payload_json"]) if row else {}
            return copy.deepcopy(self._latest)

    def brain_state(self) -> dict[str, Any]:
        return brain_view(self.state())

    def public_state(self) -> dict[str, Any]:
        """Return only the map schema; raw tracker rows stay internal."""
        return self.public_state_from(self.state())

    @staticmethod
    def public_state_from(source: Mapping[str, Any]) -> dict[str, Any]:
        allowed = {
            "npc_id", "npc_alive", "npc_active", "body_mode", "server_status",
            "player_count", "updated_at", "entities", "npcs", "squads", "base",
        }
        result = {key: copy.deepcopy(source[key]) for key in allowed if key in source}
        for entity_key in ("entities", "npcs"):
            entities = result.get(entity_key)
            if not isinstance(entities, list):
                continue
            result[entity_key] = [
                {
                    key: copy.deepcopy(entity[key])
                    for key in ("npc_id", "entity_id", "id", "kind", "name", "x", "y", "z", "online", "alive", "active")
                    if key in entity
                }
                for entity in entities
                if isinstance(entity, Mapping)
            ]
        return result

    def events(self, *, limit: int = 100) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit), 256))
        with self.lock:
            rows = self.connection.execute(
                "SELECT id, observed_at, kind, payload_json FROM tracker_events "
                "ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
            safe_fields = {"npc_id", "player", "speaker", "role", "job", "squad_id", "leader", "member_count", "text", "reason", "entity_kind", "entity_id"}
            return [
                {
                    "id": row["id"], "observed_at": row["observed_at"], "kind": row["kind"],
                    **{
                        key: value for key, value in json.loads(row["payload_json"]).items()
                        if key in safe_fields
                    },
                }
                for row in reversed(rows)
            ]

    def history(self, subject: str = "goblin.primary", *, limit: int = 100) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit), 256))
        rows_out: list[dict[str, Any]] = []
        with self.lock:
            rows = self.connection.execute(
                "SELECT id, observed_at, payload_json FROM tracker_positions "
                "ORDER BY id DESC LIMIT ?", (limit * 4,)
            ).fetchall()
        for row in reversed(rows):
            payload = json.loads(row["payload_json"])
            entities = []
            if isinstance(payload, Mapping):
                entities = payload.get("entities", payload.get("npcs", []))
            if subject == "goblin.primary" and not entities and "npc_id" in payload:
                entities = [payload]
            if any(isinstance(entity, Mapping) and entity.get("npc_id", entity.get("id")) == subject for entity in entities):
                rows_out.append({"id": row["id"], "observed_at": row["observed_at"], "state": self.public_state_from(payload)})
        return rows_out[-limit:]

    def wait_for_update(self, sequence: int, timeout: float = 15.0) -> tuple[int, dict[str, Any], list[dict[str, Any]]]:
        with self.condition:
            self.condition.wait_for(lambda: self._sequence > sequence, timeout=max(0.0, timeout))
            return self._sequence, self.state(), self.events(limit=16)


class TrackerApp:
    """Read-only tracker API. There are deliberately no control endpoints."""

    def __init__(self, store: TrackerStore) -> None:
        self.store = store

    def handle(self, method: str, path: str) -> tuple[int, dict[str, str], Any]:
        route = urlsplit(path).path
        if method != "GET":
            return 405, {"Allow": "GET"}, {"ok": False, "error": "read-only tracker"}
        if route in {"/api/health", "/healthz"}:
            return 200, {}, {"ok": True, "service": "goblin-tracker"}
        if route == "/api/state":
            return 200, {"Cache-Control": "no-store"}, self.store.public_state()
        if route == "/api/events":
            return 200, {"Cache-Control": "no-store"}, {"events": self.store.events()}
        if route == "/api/history/goblin":
            return 200, {"Cache-Control": "no-store"}, {"subject": "goblin.primary", "history": self.store.history()}
        if route == "/api/stream":
            return 200, {"Content-Type": "text/event-stream", "Cache-Control": "no-cache"}, {"events": self.store.events(limit=16)}
        return 404, {}, {"ok": False, "error": "not found"}

    def server(self, host: str = "127.0.0.1", port: int = 8782) -> ThreadingHTTPServer:
        app = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                status, headers, payload = app.handle("GET", self.path)
                if self.path.split("?", 1)[0] == "/api/stream":
                    encoded = "data: " + json.dumps(payload, separators=(",", ":")) + "\n\n"
                    body = encoded.encode("utf-8")
                    content_type = "text/event-stream"
                else:
                    body = json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
                    content_type = headers.get("Content-Type", "application/json")
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Content-Type-Options", "nosniff")
                for key, value in headers.items():
                    if key.lower() != "content-type":
                        self.send_header(key, value)
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self) -> None:
                status, headers, payload = app.handle("POST", self.path)
                body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format: str, *_args: object) -> None:
                return

        server = ThreadingHTTPServer((host, port), Handler)
        server.daemon_threads = True
        return server

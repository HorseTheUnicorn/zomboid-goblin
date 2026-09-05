"""Read-only live-map telemetry store and HTTP surface.

Tracker telemetry is intentionally a separate data path from ``brain_view``.
It may retain exact positions for the private/public map policy, but callers
must explicitly choose the tracker APIs; the Qwen context is always built
from the redacted view.
"""

from __future__ import annotations

from contextlib import closing
import copy
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sqlite3
import threading
import time
from collections.abc import Mapping
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import unquote, urlsplit
import re

from .config import parse_bool
from .state import brain_view


def _json(value: Any, maximum: int = 64 * 1024) -> str:
    encoded = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > maximum:
        raise ValueError("tracker payload is too large")
    return encoded


@dataclass(frozen=True)
class TrackerPrivacy:
    """Public tracker policy; exact storage and cognition remain separate."""

    enabled: bool = True
    show_players: bool = True
    show_player_names: bool = True
    show_exact_positions: bool = True
    show_npcs: bool = True
    history_enabled: bool = True
    mode: str = "exact"

    def __post_init__(self) -> None:
        if self.mode not in {"exact", "approximate", "hidden"}:
            raise ValueError("tracker privacy mode must be exact, approximate, or hidden")
        if self.mode == "exact" and not self.show_exact_positions:
            raise ValueError("exact tracker mode requires exact positions")
        if self.mode != "exact" and self.show_exact_positions:
            raise ValueError("non-exact tracker mode cannot expose exact positions")

    @classmethod
    def from_env(cls) -> "TrackerPrivacy":
        mode = os.environ.get("GOBLIN_TRACKER_PRIVACY_MODE", "exact").strip().casefold()
        if mode not in {"exact", "approximate", "hidden"}:
            raise ValueError("GOBLIN_TRACKER_PRIVACY_MODE must be exact, approximate, or hidden")
        return cls(
            enabled=parse_bool(os.environ.get("GOBLIN_TRACKER_ENABLED"), default=True),
            show_players=parse_bool(
                os.environ.get("GOBLIN_TRACKER_SHOW_PLAYERS"), default=True
            ),
            show_player_names=parse_bool(
                os.environ.get("GOBLIN_TRACKER_SHOW_PLAYER_NAMES"), default=True
            ),
            show_exact_positions=mode == "exact",
            show_npcs=parse_bool(
                os.environ.get("GOBLIN_TRACKER_SHOW_NPCS"), default=True
            ),
            history_enabled=parse_bool(
                os.environ.get("GOBLIN_TRACKER_HISTORY_ENABLED"), default=True
            ),
            mode=mode,
        )


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
    def public_state_from(
        source: Mapping[str, Any], privacy: TrackerPrivacy | None = None
    ) -> dict[str, Any]:
        privacy = privacy or TrackerPrivacy()
        allowed = {
            "npc_id", "npc_alive", "npc_active", "body_mode", "server_status",
            "player_count", "updated_at", "entities", "npcs", "squads", "base",
            "role", "mode", "task", "target_player", "target_npc_id",
            "friendly", "protected", "spawn_status", "spawn_pending",
            "spawn_attempts",
        }
        result = {key: copy.deepcopy(source[key]) for key in allowed if key in source}
        for entity_key in ("entities", "npcs"):
            entities = result.get(entity_key)
            if not isinstance(entities, list):
                continue
            clean_entities = []
            for entity in entities:
                if not isinstance(entity, Mapping):
                    continue
                kind = str(entity.get("kind", "")).casefold()
                is_player = kind == "player" or entity.get("online") is True
                if is_player and not privacy.show_players:
                    continue
                if not is_player and not privacy.show_npcs:
                    continue
                keys = (
                    "npc_id", "entity_id", "id", "kind", "name", "role",
                    "base_job", "expedition_role", "squad_id", "home_base",
                    "mode", "task", "target_player", "target_npc_id",
                    "friendly", "protected", "body_present", "x", "y", "z",
                    "online", "alive", "active",
                )
                clean = {
                    key: copy.deepcopy(entity[key])
                    for key in keys
                    if key in entity
                }
                if is_player and not privacy.show_player_names:
                    for key in ("name", "entity_id", "id"):
                        clean.pop(key, None)
                if not privacy.show_exact_positions:
                    for key in ("x", "y", "z"):
                        clean.pop(key, None)
                clean_entities.append(clean)
            result[entity_key] = clean_entities
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

    _MAP_TILE = re.compile(r"^/map/biomemap_(\d+)_(\d+)\.png$")
    _STATIC_CONTENT_TYPES = {
        ".css": "text/css; charset=utf-8",
        ".html": "text/html; charset=utf-8",
        ".js": "text/javascript; charset=utf-8",
        ".json": "application/json; charset=utf-8",
        ".svg": "image/svg+xml",
    }

    def __init__(
        self,
        store: TrackerStore,
        *,
        max_streams: int = 8,
        stream_seconds: float = 300.0,
        static_dir: str | Path | None = None,
        map_root: str | Path | None = None,
        privacy: TrackerPrivacy | None = None,
    ) -> None:
        if max_streams < 1:
            raise ValueError("max_streams must be positive")
        if not 30.0 <= stream_seconds <= 3600.0:
            raise ValueError("stream_seconds must be between 30 and 3600")
        self.store = store
        self.stream_seconds = stream_seconds
        self.privacy = privacy or TrackerPrivacy()
        self.stream_slots = threading.BoundedSemaphore(max_streams)
        self.static_dir = Path(static_dir) if static_dir is not None else Path(__file__).resolve().parent.parent / "web"
        self.static_dir = self.static_dir.resolve()
        self.map_root = Path(map_root).resolve() if map_root is not None else None
        self.map_manifest = self._load_map_manifest()

    def _load_map_manifest(self) -> dict[str, Any] | None:
        manifest_path = self.static_dir / "map-manifest.json"
        try:
            with manifest_path.open("r", encoding="utf-8") as handle:
                manifest = json.load(handle)
        except (OSError, ValueError):
            return None
        if not isinstance(manifest, dict):
            return None
        return manifest

    def _static_response(self, route: str) -> tuple[int, dict[str, str], bytes] | None:
        """Return a bounded static/map response without following user paths."""
        tile_match = self._MAP_TILE.fullmatch(route)
        if tile_match is not None:
            if self.map_root is None:
                return 404, {}, b'{"ok":false,"error":"map layer unavailable"}'
            tile_x, tile_y = (int(value) for value in tile_match.groups())
            manifest = self.map_manifest or {}
            try:
                x_min = int(manifest["tiles"]["x_min"])
                x_max = int(manifest["tiles"]["x_max"])
                y_min = int(manifest["tiles"]["y_min"])
                y_max = int(manifest["tiles"]["y_max"])
            except (KeyError, TypeError, ValueError):
                return 404, {}, b'{"ok":false,"error":"map layer unavailable"}'
            if not x_min <= tile_x <= x_max or not y_min <= tile_y <= y_max:
                return 404, {}, b'{"ok":false,"error":"map tile not found"}'
            tile_path = (self.map_root / f"biomemap_{tile_x}_{tile_y}.png").resolve()
            if not tile_path.is_relative_to(self.map_root) or not tile_path.is_file():
                return 404, {}, b'{"ok":false,"error":"map tile not found"}'
            try:
                body = tile_path.read_bytes()
            except OSError:
                return 404, {}, b'{"ok":false,"error":"map tile not found"}'
            return 200, {
                "Content-Type": "image/png",
                "Cache-Control": "public, max-age=3600",
            }, body

        if route == "/":
            relative = Path("index.html")
        elif route.startswith("/assets/"):
            relative = Path("assets") / route.removeprefix("/assets/")
        else:
            return None
        if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            return 404, {}, b'{"ok":false,"error":"not found"}'
        candidate = (self.static_dir / relative).resolve()
        if not candidate.is_relative_to(self.static_dir) or not candidate.is_file():
            return 404, {}, b'{"ok":false,"error":"not found"}'
        try:
            body = candidate.read_bytes()
        except OSError:
            return 404, {}, b'{"ok":false,"error":"not found"}'
        content_type = self._STATIC_CONTENT_TYPES.get(candidate.suffix.lower(), "application/octet-stream")
        return 200, {
            "Content-Type": content_type,
            "Cache-Control": "no-cache" if candidate.name == "index.html" else "public, max-age=300",
        }, body

    def handle(self, method: str, path: str) -> tuple[int, dict[str, str], Any]:
        route = unquote(urlsplit(path).path)
        if method != "GET":
            return 405, {"Allow": "GET"}, {"ok": False, "error": "read-only tracker"}
        if route in {"/api/health", "/healthz"}:
            return 200, {}, {
                "ok": self.privacy.enabled,
                "service": "goblin-tracker",
                "privacy_mode": self.privacy.mode,
            }
        if not self.privacy.enabled:
            return 404, {}, {"ok": False, "error": "tracker disabled"}
        if route == "/api/state":
            return 200, {"Cache-Control": "no-store"}, self.store.public_state_from(
                self.store.state(), self.privacy
            )
        if route == "/api/events":
            return 200, {"Cache-Control": "no-store"}, {"events": self.store.events()}
        if route == "/api/history/goblin":
            if not self.privacy.history_enabled:
                return 200, {"Cache-Control": "no-store"}, {
                    "subject": "goblin.primary", "history": [], "enabled": False
                }
            history = self.store.history()
            return 200, {"Cache-Control": "no-store"}, {
                "subject": "goblin.primary",
                "history": [
                    {
                        **row,
                        "state": TrackerStore.public_state_from(
                            row["state"], self.privacy
                        ),
                    }
                    for row in history
                ],
            }
        if route == "/api/map/manifest":
            if self.map_root is None or self.map_manifest is None:
                return 404, {}, {"ok": False, "error": "map layer unavailable"}
            return 200, {"Cache-Control": "no-store"}, copy.deepcopy(self.map_manifest)
        if route == "/api/stream":
            return 200, {"Content-Type": "text/event-stream", "Cache-Control": "no-cache"}, {"events": self.store.events(limit=16)}
        static = self._static_response(route)
        if static is not None:
            return static
        return 404, {}, {"ok": False, "error": "not found"}

    def server(self, host: str = "127.0.0.1", port: int = 8782) -> ThreadingHTTPServer:
        app = self

        class Handler(BaseHTTPRequestHandler):
            @staticmethod
            def _security_headers() -> dict[str, str]:
                return {
                    "X-Content-Type-Options": "nosniff",
                    "Referrer-Policy": "no-referrer",
                    "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'",
                    "X-Frame-Options": "DENY",
                }

            def _stream(self) -> None:
                if not app.stream_slots.acquire(blocking=False):
                    self.send_response(503)
                    for key, value in self._security_headers().items():
                        self.send_header(key, value)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", "40")
                    self.end_headers()
                    self.wfile.write(b'{"ok":false,"error":"stream capacity"}')
                    return
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache, no-store")
                    self.send_header("Connection", "keep-alive")
                    self.send_header("X-Accel-Buffering", "no")
                    for key, value in self._security_headers().items():
                        self.send_header(key, value)
                    # The stream is deliberately lengthless; the bounded
                    # lifetime below closes it so clients can reconnect.
                    self.end_headers()

                    def send(event: str, payload: Mapping[str, Any]) -> None:
                        encoded = json.dumps(
                            dict(payload), ensure_ascii=False, allow_nan=False,
                            separators=(",", ":"),
                        )
                        body = (
                            f"event: {event}\n"
                            f"data: {encoded}\n\n"
                        ).encode("utf-8")
                        self.wfile.write(body)
                        self.wfile.flush()

                    self.wfile.write(b"retry: 2000\n\n")
                    self.wfile.flush()
                    sequence, state, events = app.store.wait_for_update(-1, 0)
                    send(
                        "snapshot",
                        {
                            "sequence": sequence,
                            "state": app.store.public_state_from(state, app.privacy),
                            "events": events,
                        },
                    )
                    deadline = time.monotonic() + app.stream_seconds
                    while time.monotonic() < deadline:
                        timeout = min(15.0, max(0.1, deadline - time.monotonic()))
                        next_sequence, next_state, next_events = app.store.wait_for_update(
                            sequence, timeout
                        )
                        if next_sequence == sequence:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                            continue
                        sequence = next_sequence
                        send(
                            "update",
                            {
                                "sequence": sequence,
                                "state": app.store.public_state_from(next_state, app.privacy),
                                "events": next_events,
                            },
                        )
                except (BrokenPipeError, ConnectionResetError, OSError):
                    # A browser closing or reconnecting is normal for SSE.
                    return
                finally:
                    app.stream_slots.release()

            def do_GET(self) -> None:
                if self.path.split("?", 1)[0] == "/api/stream":
                    self._stream()
                    return
                status, headers, payload = app.handle("GET", self.path)
                self._send_payload(status, headers, payload, include_body=True)

            def _send_payload(
                self,
                status: int,
                headers: Mapping[str, str],
                payload: Any,
                *,
                include_body: bool,
            ) -> None:
                if isinstance(payload, bytes):
                    body = payload
                else:
                    body = json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
                content_type = headers.get("Content-Type", "application/json")
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                for key, value in self._security_headers().items():
                    self.send_header(key, value)
                for key, value in headers.items():
                    if key.lower() != "content-type":
                        self.send_header(key, value)
                self.end_headers()
                if include_body:
                    self.wfile.write(body)

            def do_HEAD(self) -> None:
                if self.path.split("?", 1)[0] == "/api/stream":
                    self._send_payload(
                        405,
                        {"Allow": "GET"},
                        {"ok": False, "error": "read-only tracker"},
                        include_body=False,
                    )
                    return
                status, headers, payload = app.handle("GET", self.path)
                self._send_payload(status, headers, payload, include_body=False)

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

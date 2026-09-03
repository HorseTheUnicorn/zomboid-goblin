"""Bounded SQLite memory and relationship persistence."""

from __future__ import annotations

from contextlib import closing
import json
from pathlib import Path
import sqlite3
import threading
import time
from collections.abc import Mapping
from typing import Any


def _json(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    if len(encoded.encode("utf-8")) > 8192:
        raise ValueError("metadata is too large")
    return encoded


class MemoryStore:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(
            str(self.path), check_same_thread=False, isolation_level=None
        )
        self.connection.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.connection.execute("PRAGMA journal_mode=WAL")
            self.connection.execute("PRAGMA synchronous=FULL")
            self.connection.execute("PRAGMA foreign_keys=ON")
            self.connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS memories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    subject TEXT NOT NULL DEFAULT '',
                    content TEXT NOT NULL,
                    metadata_json TEXT NOT NULL DEFAULT '{}'
                );
                CREATE INDEX IF NOT EXISTS memories_recent
                    ON memories(created_at DESC, id DESC);
                CREATE TABLE IF NOT EXISTS relationships (
                    subject TEXT PRIMARY KEY,
                    trust REAL NOT NULL DEFAULT 0.5,
                    fear REAL NOT NULL DEFAULT 0.0,
                    affinity REAL NOT NULL DEFAULT 0.0,
                    last_seen INTEGER,
                    tags_json TEXT NOT NULL DEFAULT '[]'
                );
                CREATE TABLE IF NOT EXISTS chatter (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at INTEGER NOT NULL,
                    event_key TEXT NOT NULL,
                    channel TEXT NOT NULL,
                    text TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS chatter_recent
                    ON chatter(created_at DESC, id DESC);
                CREATE TABLE IF NOT EXISTS loot_claims (
                    run_id TEXT NOT NULL,
                    player_id TEXT NOT NULL,
                    claimed_at INTEGER NOT NULL,
                    PRIMARY KEY(run_id, player_id)
                );
                CREATE TABLE IF NOT EXISTS character_state (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    lifecycle TEXT NOT NULL,
                    manifest_json TEXT,
                    updated_at INTEGER NOT NULL
                );
                """
            )

    def close(self) -> None:
        with self.lock:
            self.connection.close()

    def record_memory(
        self,
        kind: str,
        content: str,
        *,
        subject: str = "",
        metadata: dict[str, Any] | None = None,
        created_at: int | None = None,
    ) -> int:
        if not kind or len(kind) > 64:
            raise ValueError("invalid memory kind")
        if not isinstance(content, str) or not content or len(content) > 4000:
            raise ValueError("memory is invalid or too long")
        if len(subject) > 128:
            raise ValueError("subject is too long")
        metadata_json = _json(metadata or {})
        with self.lock:
            cursor = self.connection.execute(
                """
                INSERT INTO memories(created_at, kind, subject, content, metadata_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                (created_at or int(time.time()), kind, subject, content, metadata_json),
            )
            return int(cursor.lastrowid)

    def recent_memories(self, limit: int = 20) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit), 100))
        with self.lock, closing(
            self.connection.execute(
                """
                SELECT id, created_at, kind, subject, content, metadata_json
                FROM memories ORDER BY created_at DESC, id DESC LIMIT ?
                """,
                (limit,),
            )
        ) as rows:
            return [
                {
                    "id": row["id"],
                    "created_at": row["created_at"],
                    "kind": row["kind"],
                    "subject": row["subject"],
                    "content": row["content"],
                    "metadata": json.loads(row["metadata_json"]),
                }
                for row in rows
            ]

    def upsert_relationship(
        self,
        subject: str,
        *,
        trust: float | None = None,
        fear: float | None = None,
        affinity: float | None = None,
        tags: list[str] | None = None,
        last_seen: int | None = None,
    ) -> None:
        if not subject or len(subject) > 128:
            raise ValueError("invalid relationship subject")
        values = {
            "trust": min(1.0, max(0.0, float(trust if trust is not None else 0.5))),
            "fear": min(1.0, max(0.0, float(fear if fear is not None else 0.0))),
            "affinity": min(1.0, max(0.0, float(affinity if affinity is not None else 0.0))),
            "tags_json": _json((tags or [])[:16]),
            "last_seen": last_seen or int(time.time()),
        }
        with self.lock:
            self.connection.execute(
                """
                INSERT INTO relationships(subject, trust, fear, affinity, last_seen, tags_json)
                VALUES (:subject, :trust, :fear, :affinity, :last_seen, :tags_json)
                ON CONFLICT(subject) DO UPDATE SET
                    trust=excluded.trust,
                    fear=excluded.fear,
                    affinity=excluded.affinity,
                    last_seen=excluded.last_seen,
                    tags_json=excluded.tags_json
                """,
                {"subject": subject, **values},
            )

    def relationship(self, subject: str) -> dict[str, Any] | None:
        with self.lock, closing(
            self.connection.execute(
                "SELECT * FROM relationships WHERE subject = ?", (subject,)
            )
        ) as rows:
            row = rows.fetchone()
        if row is None:
            return None
        return {
            "subject": row["subject"],
            "trust": row["trust"],
            "fear": row["fear"],
            "affinity": row["affinity"],
            "last_seen": row["last_seen"],
            "tags": json.loads(row["tags_json"]),
        }

    def record_chatter(
        self,
        event_key: str,
        channel: str,
        text: str,
        *,
        created_at: int | None = None,
    ) -> int:
        if not event_key or len(event_key) > 96:
            raise ValueError("invalid chatter event")
        if channel not in {"discord", "game", "admin"}:
            raise ValueError("invalid chatter channel")
        if not text or len(text) > 240:
            raise ValueError("invalid chatter text")
        with self.lock:
            cursor = self.connection.execute(
                """
                INSERT INTO chatter(created_at, event_key, channel, text)
                VALUES (?, ?, ?, ?)
                """,
                (created_at or int(time.time()), event_key, channel, text),
            )
            return int(cursor.lastrowid)

    def chatter_since(self, since: int) -> list[dict[str, Any]]:
        with self.lock, closing(
            self.connection.execute(
                """
                SELECT id, created_at, event_key, channel, text
                FROM chatter WHERE created_at >= ?
                ORDER BY created_at ASC, id ASC
                """,
                (since,),
            )
        ) as rows:
            return [dict(row) for row in rows]

    def character_record(self) -> dict[str, Any] | None:
        """Return the durable character lifecycle without exposing it publicly."""
        with self.lock, closing(
            self.connection.execute(
                "SELECT lifecycle, manifest_json, updated_at FROM character_state WHERE id = 1"
            )
        ) as rows:
            row = rows.fetchone()
        if row is None:
            return None
        manifest: dict[str, Any] | None = None
        manifest_error = False
        if row["manifest_json"] is not None:
            try:
                parsed = json.loads(row["manifest_json"])
            except (TypeError, json.JSONDecodeError):
                parsed = None
            if isinstance(parsed, dict):
                manifest = parsed
            else:
                manifest_error = True
        return {
            "lifecycle": row["lifecycle"],
            "manifest": manifest,
            "manifest_error": manifest_error,
            "updated_at": row["updated_at"],
        }

    def save_character_state(
        self,
        lifecycle: str,
        manifest: Mapping[str, Any] | None,
        *,
        updated_at: int | None = None,
    ) -> None:
        if not isinstance(lifecycle, str) or not lifecycle or len(lifecycle) > 32:
            raise ValueError("invalid character lifecycle")
        if manifest is not None and not isinstance(manifest, Mapping):
            raise ValueError("character manifest must be an object")
        manifest_json = _json(dict(manifest)) if manifest is not None else None
        timestamp = int(updated_at if updated_at is not None else time.time())
        with self.lock:
            self.connection.execute(
                """
                INSERT INTO character_state(id, lifecycle, manifest_json, updated_at)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    lifecycle=excluded.lifecycle,
                    manifest_json=excluded.manifest_json,
                    updated_at=excluded.updated_at
                """,
                (lifecycle, manifest_json, timestamp),
            )

    def claim_loot(
        self,
        run_id: str,
        player_id: str,
        *,
        claimed_at: int | None = None,
    ) -> bool:
        if not run_id or not player_id or len(run_id) > 128 or len(player_id) > 128:
            raise ValueError("invalid loot claim")
        with self.lock:
            try:
                self.connection.execute(
                    """
                    INSERT INTO loot_claims(run_id, player_id, claimed_at)
                    VALUES (?, ?, ?)
                    """,
                    (run_id, player_id, claimed_at or int(time.time())),
                )
            except sqlite3.IntegrityError:
                return False
            return True

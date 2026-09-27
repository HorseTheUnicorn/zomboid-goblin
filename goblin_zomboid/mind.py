"""Goblin's long-term memory: episodes, places, trust and a daily journal.

Everything is keyed by npc_id and stored in a small SQLite file next to the
agent's other state, so it survives restarts. Inputs are the coarse
situation reports (labels and counts only) and chat; nothing here stores or
emits coordinates. ``digest()`` is the compact view handed to Qwen.
"""
from __future__ import annotations

from contextlib import closing
from pathlib import Path
import sqlite3
import threading
import time
from collections.abc import Mapping
from typing import Any

TRUST_LABELS = ((0.2, "resentful"), (0.4, "wary"), (0.6, "loyal"), (0.8, "devoted"), (1.01, "would die for you"))
SOCIAL_TRUST = {"thanks": 0.03, "praise": 0.04, "apology": 0.02, "insult": -0.05}


def trust_label(score: float) -> str:
    for limit, label in TRUST_LABELS:
        if score < limit:
            return label
    return TRUST_LABELS[-1][1]


class GoblinMind:
    def __init__(self, path: str | Path, *, clock=time.time) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.clock = clock
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(self.path), check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.seen_seq: dict[str, int] = {}
        self.last_room: dict[str, str | None] = {}
        self.last_day: dict[str, int] = {}
        with self.lock:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS episodes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, npc_id TEXT NOT NULL, at INTEGER NOT NULL,
                    kind TEXT NOT NULL, text TEXT NOT NULL, day INTEGER);
                CREATE INDEX IF NOT EXISTS episodes_npc ON episodes(npc_id, id DESC);
                CREATE TABLE IF NOT EXISTS places (
                    npc_id TEXT NOT NULL, name TEXT NOT NULL, visits INTEGER NOT NULL DEFAULT 0,
                    note TEXT, last_at INTEGER, PRIMARY KEY(npc_id, name));
                CREATE TABLE IF NOT EXISTS trust (
                    npc_id TEXT PRIMARY KEY, score REAL NOT NULL, reason TEXT, updated INTEGER);
                CREATE TABLE IF NOT EXISTS journal (
                    npc_id TEXT NOT NULL, day INTEGER NOT NULL, text TEXT NOT NULL,
                    PRIMARY KEY(npc_id, day));
            """)

    def close(self) -> None:
        with self.lock:
            self.db.close()

    # ---------------------------------------------------------------- writes
    def record(self, npc_id: str, kind: str, text: str, day: int | None = None) -> None:
        text = str(text)[:240]
        if not text.strip():
            return
        with self.lock:
            self.db.execute("INSERT INTO episodes(npc_id, at, kind, text, day) VALUES (?,?,?,?,?)",
                            (npc_id, int(self.clock()), str(kind)[:32], text, day))
            self.db.execute("DELETE FROM episodes WHERE npc_id=? AND id NOT IN "
                            "(SELECT id FROM episodes WHERE npc_id=? ORDER BY id DESC LIMIT 400)",
                            (npc_id, npc_id))

    def visit(self, npc_id: str, name: str, note: str | None = None) -> None:
        with self.lock:
            self.db.execute(
                "INSERT INTO places(npc_id, name, visits, note, last_at) VALUES (?,?,1,?,?) "
                "ON CONFLICT(npc_id, name) DO UPDATE SET visits=visits+1, last_at=excluded.last_at, "
                "note=COALESCE(excluded.note, places.note)",
                (npc_id, name[:48], note[:120] if note else None, int(self.clock())))

    def trust(self, npc_id: str) -> float:
        with self.lock:
            row = self.db.execute("SELECT score FROM trust WHERE npc_id=?", (npc_id,)).fetchone()
        return float(row["score"]) if row else 0.6

    def adjust_trust(self, npc_id: str, delta: float, reason: str) -> float:
        score = max(0.0, min(1.0, self.trust(npc_id) + delta))
        with self.lock:
            self.db.execute("INSERT INTO trust(npc_id, score, reason, updated) VALUES (?,?,?,?) "
                            "ON CONFLICT(npc_id) DO UPDATE SET score=excluded.score, reason=excluded.reason, "
                            "updated=excluded.updated", (npc_id, score, reason[:120], int(self.clock())))
        return score

    def write_journal(self, npc_id: str, day: int, text: str) -> None:
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO journal(npc_id, day, text) VALUES (?,?,?)",
                            (npc_id, int(day), str(text)[:400]))

    # ----------------------------------------------------------------- reads
    def episodes(self, npc_id: str, limit: int = 10, day: int | None = None) -> list[dict[str, Any]]:
        with self.lock:
            if day is None:
                rows = self.db.execute("SELECT kind, text, day FROM episodes WHERE npc_id=? "
                                       "ORDER BY id DESC LIMIT ?", (npc_id, limit)).fetchall()
            else:
                rows = self.db.execute("SELECT kind, text, day FROM episodes WHERE npc_id=? AND day=? "
                                       "ORDER BY id DESC LIMIT ?", (npc_id, day, limit)).fetchall()
        return [dict(row) for row in reversed(rows)]

    def places(self, npc_id: str, limit: int = 6) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.db.execute("SELECT name, visits, note FROM places WHERE npc_id=? "
                                   "ORDER BY (note IS NOT NULL) DESC, visits DESC LIMIT ?",
                                   (npc_id, limit)).fetchall()
        return [dict(row) for row in rows]

    def journal(self, npc_id: str, limit: int = 3) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.db.execute("SELECT day, text FROM journal WHERE npc_id=? ORDER BY day DESC LIMIT ?",
                                   (npc_id, limit)).fetchall()
        return [dict(row) for row in reversed(rows)]

    def digest(self, npc_id: str) -> dict[str, Any]:
        score = self.trust(npc_id)
        return {"trust_in_owner": trust_label(score), "trust_score": round(score, 2),
                "remembered_places": self.places(npc_id), "recent_memories": self.episodes(npc_id, 12),
                "journal": self.journal(npc_id)}

    # ------------------------------------------------------------ perception
    def observe(self, companion: Mapping[str, Any]) -> dict[str, Any]:
        """Fold one telemetry snapshot into memory; return what is new."""
        npc_id = companion.get("npc_id")
        situation = companion.get("situation")
        if not isinstance(npc_id, str) or not isinstance(situation, Mapping):
            return {"events": [], "new_day": None}
        time_info = situation.get("time") if isinstance(situation.get("time"), Mapping) else {}
        day = time_info.get("day") if isinstance(time_info.get("day"), int) else None
        new_events = []
        last = self.seen_seq.get(npc_id, 0)
        seqs = [e.get("seq") for e in situation.get("events") or [] if isinstance(e, Mapping)
                and isinstance(e.get("seq"), int)]
        if seqs and max(seqs) < last:  # the game server restarted its event log
            last = 0
            self.seen_seq[npc_id] = 0
        for event in situation.get("events") or []:
            if not isinstance(event, Mapping) or not isinstance(event.get("seq"), int):
                continue
            if event["seq"] <= last:
                continue
            new_events.append(event)
            self.seen_seq[npc_id] = max(self.seen_seq.get(npc_id, 0), event["seq"])
            kind, text = str(event.get("kind", "event")), str(event.get("text", ""))
            self.record(npc_id, kind, text, day)
            if kind == "horde":
                self.adjust_trust(npc_id, -0.03, "dragged into a horde")
            elif kind == "owner_hurt":
                self.adjust_trust(npc_id, -0.01, "owner got hurt")
            elif kind == "job" and "COMPLETE" in text:
                self.adjust_trust(npc_id, 0.005, "work went well")
        place = situation.get("place") if isinstance(situation.get("place"), Mapping) else {}
        room = place.get("room") if isinstance(place.get("room"), str) else None
        if room and room != self.last_room.get(npc_id):
            note = None
            if any(e.get("kind") in ("owner_hurt", "horde") for e in new_events):
                note = "where things went badly: " + "; ".join(str(e.get("text")) for e in new_events)[:100]
            self.visit(npc_id, room, note)
        elif room and any(e.get("kind") in ("owner_hurt", "horde") for e in new_events):
            self.visit(npc_id, room, "nearly died here")
        self.last_room[npc_id] = room
        new_day = None
        if day is not None:
            previous = self.last_day.get(npc_id)
            if previous is not None and day > previous:
                new_day = previous
            self.last_day[npc_id] = day
        return {"events": new_events, "new_day": new_day}

    def social(self, npc_id: str, category: str | None) -> None:
        if category and category.lower() in SOCIAL_TRUST:
            self.adjust_trust(npc_id, SOCIAL_TRUST[category.lower()], f"owner {category.lower()}")

    def fallback_journal(self, npc_id: str, day: int) -> str:
        rows = self.episodes(npc_id, 8, day=day)
        if not rows:
            return "Quiet day. Nobody died. Suspicious."
        return "; ".join(row["text"] for row in rows)[:380]

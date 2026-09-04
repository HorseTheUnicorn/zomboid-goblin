"""Structured meaningful events with duplicate and location-leak guards."""

from __future__ import annotations

from dataclasses import dataclass
import re
import time
from collections.abc import Mapping
from typing import Any

from .protocol import Message, make_message
from .state import brain_view

EVENT_FIELDS = {
    "player_joined": {"player", "party"},
    "player_left": {"player", "party"},
    "goblin_spotted": {"player", "mood"},
    "threat_changed": {"threat_level", "count_bucket"},
    "injury": {"severity", "body_part"},
    "loot_found": {"category", "rarity"},
    "hunt_started": {"prize_tier"},
    "hunt_clue": {"temperature", "clue_number"},
    "death": {"cause"},
    "respawn": {"cooldown_seconds"},
    "chat": {"speaker", "text", "authorized", "authority_token"},
    "base_changed": {"base_id", "name", "changed_by"},
    "npc_ready": {"npc_id", "active"},
    "npc_spawned": {"npc_id", "role"},
    "npc_recovered": {"npc_id", "reason"},
    "squad_changed": {"squad_id", "leader", "member_count"},
    "base_job_changed": {"npc_id", "job"},
    "tracker_update": {"entity_kind", "entity_id"},
}
ALLOWED_VALUES = {
    "threat_level": {"none", "near", "overwhelming"},
    "severity": {"minor", "moderate", "critical"},
    "rarity": {"common", "uncommon", "rare", "legendary"},
    "temperature": {"cold", "warm", "hot"},
    "entity_kind": {"goblin", "player", "npc", "squad", "base"},
}
FORBIDDEN_FIELDS = {
    "x",
    "y",
    "z",
    "coordinates",
    "route",
    "waypoint",
    "cell",
    "chunk",
    "building_id",
    "raw_packet",
    "packet",
    "script",
    "lua",
    "shell",
}
MAX_EVENT_BYTES = 8 * 1024
_TEXT_LOCATION_RE = re.compile(
    r"(?:\bcoordinates?\b|\b(?:x|y|z)\s*[:=]|\bcell\s*[:=]|\bchunk\s*[:=])",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class EventDecision:
    accepted: bool
    reason: str
    message: Message | None = None


class EventGate:
    def __init__(self, *, duplicate_window_seconds: int = 10) -> None:
        self.duplicate_window_seconds = duplicate_window_seconds
        self._recent: dict[str, int] = {}

    def _validate_fields(self, kind: str, fields: Mapping[str, Any]) -> dict[str, Any]:
        if kind not in EVENT_FIELDS:
            raise ValueError("unsupported event")
        if not all(isinstance(key, str) for key in fields):
            raise ValueError("event keys must be strings")
        unknown = set(fields).difference(EVENT_FIELDS[kind])
        if unknown:
            raise ValueError(f"unknown event field: {sorted(unknown)[0]}")
        clean: dict[str, Any] = {}
        for key, value in fields.items():
            if key.casefold() in FORBIDDEN_FIELDS:
                raise ValueError("event contains a forbidden field")
            if key in ALLOWED_VALUES:
                if value not in ALLOWED_VALUES[key]:
                    raise ValueError(f"invalid event value: {key}")
            elif key in {"player", "party", "speaker", "body_part", "cause", "text", "npc_id", "role", "reason", "squad_id", "leader", "job", "entity_id", "base_id", "name", "changed_by", "authority_token"}:
                maximum = 128 if key == "authority_token" else 240
                if not isinstance(value, str) or not value.strip() or len(value) > maximum:
                    raise ValueError(f"invalid event text: {key}")
                if key == "text" and _TEXT_LOCATION_RE.search(value):
                    raise ValueError("event text contains location coordinates")
            elif key == "authorized":
                if not isinstance(value, bool):
                    raise ValueError("invalid authorization flag")
            elif key == "count_bucket":
                if value not in {"none", "few", "many"}:
                    raise ValueError("invalid count bucket")
            elif key == "clue_number":
                if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 32:
                    raise ValueError("invalid clue number")
            elif key == "cooldown_seconds":
                if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 3600:
                    raise ValueError("invalid cooldown")
            elif key == "active":
                if not isinstance(value, bool):
                    raise ValueError("invalid active flag")
            elif key == "member_count":
                if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 16:
                    raise ValueError("invalid member count")
        return clean | dict(fields)

    def make(
        self,
        kind: str,
        fields: Mapping[str, Any],
        *,
        now: int | None = None,
        request_id: str | None = None,
    ) -> EventDecision:
        current = int(now if now is not None else time.time())
        try:
            clean = self._validate_fields(kind, fields)
            message = make_message(
                f"event.{kind}",
                request_id=request_id,
                timestamp_ms=current * 1000,
                **clean,
            )
            if len(str(message.as_dict()).encode("utf-8")) > MAX_EVENT_BYTES:
                raise ValueError("event is too large")
        except (TypeError, ValueError) as exc:
            return EventDecision(False, str(exc))
        fingerprint = repr((kind, sorted(clean.items())))
        last = self._recent.get(fingerprint)
        if last is not None and current - last < self.duplicate_window_seconds:
            return EventDecision(False, "duplicate event cooldown")
        self._recent[fingerprint] = current
        self._recent = {
            key: value
            for key, value in self._recent.items()
            if current - value <= self.duplicate_window_seconds
        }
        return EventDecision(True, "accepted", message)

    @staticmethod
    def coarse_state(raw: Mapping[str, Any]) -> dict[str, Any]:
        return brain_view(raw)

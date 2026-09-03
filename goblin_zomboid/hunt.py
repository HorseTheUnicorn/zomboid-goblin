"""Fair, stateful hunt mechanics with an explicit public redaction boundary."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import re
import secrets
import time
from typing import Any

from .memory import MemoryStore

_UNSAFE_LABEL = re.compile(
    r"(?:\bcoordinates?\b|\b(?:x|y|z)\s*[:=]|\bcell\s*[:=]|\bchunk\s*[:=])",
    re.IGNORECASE,
)


@dataclass
class HuntState:
    run_id: str
    prize_tier: str
    phase: str
    clues_issued: int = 0
    relocations: int = 0
    second_wind_used: bool = False
    winner_id: str | None = None
    death_count: int = 0


@dataclass(frozen=True)
class HuntResult:
    accepted: bool
    status: str
    reason: str
    public: dict[str, Any]


class HuntManager:
    """Stores only a digest for the hidden target in ordinary runtime state."""

    def __init__(
        self,
        memory: MemoryStore,
        *,
        respawn_cooldown_seconds: int = 120,
        max_relocations: int = 4,
    ) -> None:
        self.memory = memory
        self.respawn_cooldown_seconds = respawn_cooldown_seconds
        self.max_relocations = max_relocations
        self.state: HuntState | None = None
        self._target_digest: str | None = None
        self._private_target: dict[str, str] | None = None
        self._dead_until: int | None = None
        self._alive = True

    def start(
        self,
        *,
        target_kind: str,
        target_label: str,
        prize_tier: str = "common",
        now: int | None = None,
    ) -> HuntResult:
        if self.state is not None and self.state.phase in {"ACTIVE", "DEAD"}:
            return HuntResult(False, "already_active", "hunt is already active", self.public_status())
        if target_kind not in {"nearby_building", "area", "named_location"}:
            return HuntResult(False, "invalid_target", "target must be coarse", self.public_status())
        if not self._safe_label(target_label):
            return HuntResult(False, "invalid_target", "target label is invalid", self.public_status())
        if prize_tier not in {"common", "uncommon", "rare", "legendary"}:
            return HuntResult(False, "invalid_prize", "unknown prize tier", self.public_status())
        run_id = "hunt-" + secrets.token_hex(8)
        normalized = f"{target_kind}:{target_label.strip().casefold()}"
        self._private_target = {"kind": target_kind, "label": target_label.strip()}
        self._target_digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
        self.state = HuntState(run_id, prize_tier, "ACTIVE")
        self._dead_until = None
        self._alive = True
        return HuntResult(True, "started", "hunt started", self.public_status())

    def hint(self, temperature: str, *, now: int | None = None) -> HuntResult:
        if self.state is None or self.state.phase not in {"ACTIVE", "DEAD"}:
            return HuntResult(False, "inactive", "no active hunt", self.public_status())
        if temperature not in {"cold", "warm", "hot"}:
            return HuntResult(False, "invalid_temperature", "temperature is invalid", self.public_status())
        self.state.clues_issued += 1
        clue_number = self.state.clues_issued
        clues = {
            "cold": "The trail is old. Search the edges, not the obvious center.",
            "warm": "Something useful passed through nearby. Look for a place people once relied on.",
            "hot": "The goblin is close enough to hear you making poor decisions.",
        }
        return HuntResult(
            True,
            "hint",
            clues[temperature],
            {
                **self.public_status(),
                "temperature": temperature,
                "clue_number": clue_number,
            },
        )

    def relocate(
        self,
        *,
        target_kind: str,
        target_label: str,
        now: int | None = None,
    ) -> HuntResult:
        if self.state is None or self.state.phase not in {"ACTIVE", "DEAD"}:
            return HuntResult(False, "inactive", "no active hunt", self.public_status())
        if self.state.relocations >= self.max_relocations:
            return HuntResult(False, "relocation_limit", "relocation limit reached", self.public_status())
        if target_kind not in {"nearby_building", "area", "named_location"}:
            return HuntResult(False, "invalid_target", "target must be coarse", self.public_status())
        if not self._safe_label(target_label):
            return HuntResult(False, "invalid_target", "target label is invalid", self.public_status())
        normalized = f"{target_kind}:{target_label.strip().casefold()}"
        self._private_target = {"kind": target_kind, "label": target_label.strip()}
        self._target_digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
        self.state.relocations += 1
        self.state.clues_issued = 0
        return HuntResult(True, "relocated", "hunt target changed", self.public_status())

    def claim(
        self,
        player_id: str,
        *,
        near_target: bool,
        now: int | None = None,
    ) -> HuntResult:
        if self.state is None or self.state.phase != "ACTIVE":
            return HuntResult(False, "inactive", "no claimable hunt", self.public_status())
        if not isinstance(player_id, str) or not player_id or len(player_id) > 128:
            return HuntResult(False, "invalid_player", "player identity is invalid", self.public_status())
        if not isinstance(near_target, bool) or not near_target:
            return HuntResult(False, "not_ready", "deterministic proximity gate has not passed", self.public_status())
        if not self.memory.claim_loot(
            self.state.run_id, player_id, claimed_at=now
        ):
            return HuntResult(False, "already_claimed", "loot was already claimed", self.public_status())
        self.state.winner_id = player_id
        self.state.phase = "COMPLETED"
        return HuntResult(True, "claimed", "prize cache claimed", self.public_status())

    def damage(self, *, now: int | None = None) -> HuntResult:
        if self.state is None or self.state.phase not in {"ACTIVE", "DEAD"}:
            return HuntResult(False, "inactive", "hunt is not active", self.public_status())
        if not self._alive:
            return HuntResult(False, "dead", "Goblin is already down", self.public_status())
        current = int(now if now is not None else time.time())
        if self.state.second_wind_used:
            self._alive = False
            self.state.phase = "DEAD"
            self.state.death_count += 1
            self._dead_until = current + self.respawn_cooldown_seconds
            return HuntResult(True, "dead", "second wind was already spent", self.public_status())
        self.state.second_wind_used = True
        return HuntResult(True, "second_wind", "Goblin survives one decisive hit", self.public_status())

    def respawn(self, *, now: int | None = None) -> HuntResult:
        if self.state is None or self.state.phase != "DEAD":
            return HuntResult(False, "not_dead", "Goblin is not waiting to respawn", self.public_status())
        current = int(now if now is not None else time.time())
        if self._dead_until is None or current < self._dead_until:
            return HuntResult(False, "cooldown", "respawn cooldown is active", self.public_status())
        self._alive = True
        self._dead_until = None
        self.state.phase = "ACTIVE"
        return HuntResult(True, "respawned", "Goblin returned after cooldown", self.public_status())

    def public_status(self) -> dict[str, Any]:
        return {
            "alive": self._alive,
            "hunt_active": bool(
                self.state is not None and self.state.phase in {"ACTIVE", "DEAD"}
            ),
            "prize_tier": self.state.prize_tier if self.state is not None else "none",
        }

    def admin_status(self) -> dict[str, Any]:
        result = {
            "public": self.public_status(),
            "target_digest": self._target_digest,
            "private_target": dict(self._private_target) if self._private_target else None,
            "dead_until": self._dead_until,
        }
        if self.state is not None:
            result["state"] = self.state.__dict__.copy()
        return result

    @staticmethod
    def _safe_label(label: str) -> bool:
        return (
            isinstance(label, str)
            and bool(label.strip())
            and len(label) <= 96
            and not _UNSAFE_LABEL.search(label)
        )

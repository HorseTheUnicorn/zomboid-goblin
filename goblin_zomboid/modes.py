"""Deterministic Goblin operating modes and transition rules."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import time


class Mode(str, Enum):
    SAFE = "SAFE"
    ROAM = "ROAM"
    PARTY = "PARTY"
    HUNT = "HUNT"


@dataclass(frozen=True)
class ModeState:
    mode: Mode
    reason: str
    changed_at: int


class ModeController:
    def __init__(self, *, now: int | None = None) -> None:
        self.state = ModeState(
            Mode.SAFE,
            "safe default",
            int(now if now is not None else time.time()),
        )

    def transition(
        self,
        requested: Mode,
        *,
        emergency: bool = False,
        party_member: bool = False,
        hunt_active: bool = False,
        now: int | None = None,
    ) -> ModeState:
        current = int(now if now is not None else time.time())
        if emergency:
            self.state = ModeState(Mode.SAFE, "emergency override", current)
            return self.state
        if requested == Mode.PARTY and not party_member:
            self.state = ModeState(Mode.SAFE, "party membership is not established", current)
            return self.state
        if requested == Mode.HUNT and not hunt_active:
            self.state = ModeState(Mode.SAFE, "hunt is not active", current)
            return self.state
        self.state = ModeState(requested, f"deterministic transition to {requested.value}", current)
        return self.state


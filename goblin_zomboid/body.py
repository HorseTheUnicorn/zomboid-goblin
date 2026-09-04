"""Typed body-driver boundary; no arbitrary Lua or input commands."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Protocol

from .controllers import Action, SafeAction

_TARGET_KINDS = {
    "nearby_threat",
    "escape_route",
    "nearby_building",
    "named_location",
    "area",
    "player",
    "home_base",
    "candidate",
    "current_position",
    "goblin",
    "squad",
    "base",
    "vehicle",
    "job",
}
_COORDINATE_RE = re.compile(
    r"(?:\bcoordinates?\b|\b(?:x|y|z)\s*[:=]|\bcell\s*[:=]|\bchunk\s*[:=])",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class DriverResult:
    accepted: bool
    status: str
    detail: str


class BodyDriver(Protocol):
    @property
    def available(self) -> bool:
        ...

    def execute(self, action: SafeAction) -> DriverResult:
        ...


class DeterministicActionGate:
    """Validates typed controller output before any game adapter sees it."""

    def admit(self, action: SafeAction) -> DriverResult:
        if not isinstance(action, SafeAction):
            return DriverResult(False, "rejected", "action is not typed")
        if action.priority not in {0, 1, 2, 3}:
            return DriverResult(False, "rejected", "invalid action priority")
        if action.target_kind is not None:
            if action.target_kind not in _TARGET_KINDS:
                return DriverResult(False, "rejected", "unknown target kind")
            label = action.target_label or ""
            if not label or len(label) > 96 or _COORDINATE_RE.search(label):
                return DriverResult(False, "rejected", "unsafe target label")
        if action.item_count is not None and not 1 <= action.item_count <= 10:
            return DriverResult(False, "rejected", "unsafe item count")
        if action.action not in set(Action):
            return DriverResult(False, "rejected", "unknown action")
        if action.reason and len(action.reason) > 240:
            return DriverResult(False, "rejected", "action reason is too long")
        return DriverResult(True, "admitted", "typed action passed the gate")


class SensorOnlyBodyDriver:
    """The only installed driver before the multiplayer feasibility gate."""

    available = False

    def __init__(self) -> None:
        self.gate = DeterministicActionGate()

    def execute(self, action: SafeAction) -> DriverResult:
        admitted = self.gate.admit(action)
        if not admitted.accepted:
            return admitted
        return DriverResult(False, "sensor_only", "body feasibility gate is incomplete")

"""Deterministic, typed controller decisions for the Goblin body."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any

from .mods import MOD_PARITY_STATUSES
from .validator import ValidatedIntent


class Action(str, Enum):
    NOOP = "NOOP"
    SAY = "SAY"
    MOVE_TO = "MOVE_TO"
    FOLLOW = "FOLLOW"
    SEARCH = "SEARCH"
    SCAVENGE = "SCAVENGE"
    RETREAT = "RETREAT"
    REST = "REST"
    GO_HOME = "GO_HOME"
    JOIN_PARTY = "JOIN_PARTY"
    LEAVE_PARTY = "LEAVE_PARTY"
    ATTACK = "ATTACK"
    FLEE = "FLEE"
    EAT = "EAT"
    DRINK = "DRINK"
    BANDAGE = "BANDAGE"
    RELOAD = "RELOAD"
    CLAIM_REWARD = "CLAIM_REWARD"


@dataclass(frozen=True)
class BodyState:
    """Coarse state only; exact world coordinates never belong here."""

    alive: bool = True
    body_present: bool = False
    hunger: float = 0.0
    thirst: float = 0.0
    fatigue: float = 0.0
    panic: float = 0.0
    injury: float = 0.0
    threat_level: str = "none"
    weapon_ready: bool = False
    has_food: bool = False
    has_water: bool = False
    has_medical: bool = False
    mode: str = "SAFE"
    client_mod_parity: str = "missing"
    client_control_ready: bool = False

    def __post_init__(self) -> None:
        for name in ("hunger", "thirst", "fatigue", "panic", "injury"):
            value = getattr(self, name)
            if not 0.0 <= value <= 1.0:
                raise ValueError(f"{name} must be between 0 and 1")
        if self.threat_level not in {"none", "near", "overwhelming"}:
            raise ValueError("unknown threat level")
        if self.mode not in {"SAFE", "ROAM", "PARTY", "HUNT"}:
            raise ValueError("unknown body mode")
        if self.client_mod_parity not in MOD_PARITY_STATUSES:
            raise ValueError("unknown client mod parity status")

    @property
    def body_ready(self) -> bool:
        """A body is executable after the server-computed control contract."""

        return self.body_present and self.client_control_ready

    @property
    def creation_ready(self) -> bool:
        """Character creation may start before the first player body exists."""

        return self.client_control_ready


@dataclass(frozen=True)
class SafeAction:
    action: Action
    priority: int
    reason: str
    target_kind: str | None = None
    target_label: str | None = None
    item_name: str | None = None
    item_count: int | None = None

    def as_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "action": self.action.value,
            "priority": self.priority,
            "reason": self.reason,
        }
        if self.target_kind is not None:
            result["target"] = {
                "kind": self.target_kind,
                "label": self.target_label or "",
            }
        if self.item_name is not None:
            result["item"] = {
                "name": self.item_name,
                "count": self.item_count or 1,
            }
        return result


@dataclass(frozen=True)
class ControllerResult:
    accepted: bool
    action: SafeAction | None
    reason: str


class ReflexController:
    """Emergency survival always outranks social, party, and hunt behavior."""

    def decide(self, state: BodyState) -> SafeAction | None:
        if not state.alive:
            return None
        if state.thirst >= 0.85 and state.has_water:
            return SafeAction(Action.DRINK, 3, "critical thirst")
        if state.hunger >= 0.9 and state.has_food:
            return SafeAction(Action.EAT, 3, "critical hunger")
        if state.injury >= 0.8 and state.has_medical:
            return SafeAction(Action.BANDAGE, 3, "critical injury")
        if state.threat_level == "overwhelming":
            return SafeAction(
                Action.FLEE,
                3,
                "overwhelming threat",
                target_kind="escape_route",
                target_label="nearest safe route",
            )
        if state.panic >= 0.9:
            return SafeAction(
                Action.RETREAT,
                3,
                "panic threshold",
                target_kind="escape_route",
                target_label="nearest safe route",
            )
        return None


class CombatController:
    """Chooses bounded combat actions without exposing attack coordinates."""

    def decide(self, state: BodyState) -> SafeAction | None:
        if not state.alive or state.threat_level == "none":
            return None
        if state.threat_level == "overwhelming":
            return SafeAction(
                Action.FLEE,
                3,
                "combat threat exceeds safe threshold",
                target_kind="escape_route",
                target_label="nearest safe route",
            )
        if state.weapon_ready:
            return SafeAction(
                Action.ATTACK,
                2,
                "nearest visible threat within deterministic combat range",
                target_kind="nearby_threat",
                target_label="nearest visible threat",
            )
        return SafeAction(
            Action.FLEE,
            2,
            "no ready weapon",
            target_kind="escape_route",
            target_label="nearest safe route",
        )


class TacticalController:
    """Translates a validated intent to a finite typed action."""

    _mapping = {
        "WAIT": Action.NOOP,
        "SAY": Action.SAY,
        "MOVE_TO": Action.MOVE_TO,
        "FOLLOW": Action.FOLLOW,
        "SEARCH": Action.SEARCH,
        "SCAVENGE": Action.SCAVENGE,
        "RETREAT": Action.RETREAT,
        "REST": Action.REST,
        "GO_HOME": Action.GO_HOME,
        "JOIN_PARTY": Action.JOIN_PARTY,
        "LEAVE_PARTY": Action.LEAVE_PARTY,
        "HUNT_START": Action.NOOP,
        "HUNT_HINT": Action.SAY,
        "HUNT_RELOCATE": Action.MOVE_TO,
        "HUNT_REWARD": Action.CLAIM_REWARD,
        "TRADE": Action.MOVE_TO,
        "HELP": Action.FOLLOW,
    }

    def decide(self, intent: ValidatedIntent, state: BodyState) -> ControllerResult:
        if not state.alive:
            return ControllerResult(False, None, "body is not alive")
        if intent.mode != state.mode and intent.mode not in {"SAFE", state.mode}:
            return ControllerResult(False, None, "intent mode does not match body mode")
        action = self._mapping[intent.intent]
        target = intent.data.get("target")
        candidate = intent.data.get("candidate")
        if intent.intent == "HUNT_RELOCATE":
            target = candidate
        if intent.intent in {
            "MOVE_TO",
            "FOLLOW",
            "SEARCH",
            "SCAVENGE",
            "JOIN_PARTY",
            "TRADE",
            "HELP",
        } and not isinstance(target, dict):
            return ControllerResult(False, None, "intent target is missing")
        target_kind = target.get("kind") if isinstance(target, dict) else None
        target_label = None
        if isinstance(target, dict):
            target_label = target.get("name") or target.get("label") or target.get("player")
        if intent.intent == "SAY":
            target_kind = None
            target_label = None
        item = intent.data.get("item")
        result = SafeAction(
            action=action,
            priority=intent.data.get("priority", 1),
            reason=f"validated intent {intent.intent}",
            target_kind=target_kind,
            target_label=target_label,
            item_name=item.get("name") if isinstance(item, dict) else None,
            item_count=item.get("count") if isinstance(item, dict) else None,
        )
        return ControllerResult(True, result, "accepted by tactical controller")


class SafetyController:
    def __init__(self) -> None:
        self.reflex = ReflexController()
        self.combat = CombatController()
        self.tactical = TacticalController()

    def decide(
        self,
        intent: ValidatedIntent | None,
        state: BodyState,
    ) -> ControllerResult:
        if not state.body_ready:
            if intent is None:
                return ControllerResult(True, None, "body driver or client mod parity is unavailable")
            if self.tactical._mapping[intent.intent] not in {Action.SAY, Action.NOOP}:
                return ControllerResult(False, None, "body driver or client mod parity is unavailable")
            return self.tactical.decide(intent, state)
        reflex = self.reflex.decide(state)
        if reflex is not None:
            return ControllerResult(True, reflex, "reflex controller precedence")
        combat = self.combat.decide(state)
        if combat is not None:
            return ControllerResult(True, combat, "combat controller precedence")
        if intent is None:
            return ControllerResult(True, None, "no social or tactical intent")
        if not state.body_ready and self.tactical._mapping[intent.intent] not in {
            Action.SAY,
            Action.NOOP,
        }:
            return ControllerResult(False, None, "body driver is not available")
        return self.tactical.decide(intent, state)


@dataclass
class InventoryReservation:
    item_name: str
    count: int
    token: str


class InventoryController:
    """Small reservation ledger preventing duplicate loot/item consumption."""

    def __init__(self) -> None:
        self._reservations: dict[str, InventoryReservation] = {}

    def reserve(self, item_name: str, count: int, available: int, token: str) -> bool:
        if not item_name or not 1 <= count <= 10 or available < count:
            return False
        if token in self._reservations:
            return False
        reserved = sum(
            item.count
            for item in self._reservations.values()
            if item.item_name.casefold() == item_name.casefold()
        )
        if reserved + count > available:
            return False
        self._reservations[token] = InventoryReservation(item_name, count, token)
        return True

    def release(self, token: str) -> None:
        self._reservations.pop(token, None)

    def commit(self, token: str) -> InventoryReservation | None:
        return self._reservations.pop(token, None)

    def reserved_count(self, item_name: str) -> int:
        return sum(
            item.count
            for item in self._reservations.values()
            if item.item_name.casefold() == item_name.casefold()
        )

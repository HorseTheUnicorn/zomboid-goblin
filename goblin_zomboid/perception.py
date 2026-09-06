"""Bounded semantic perception for the Qwen commander.

This module is intentionally separate from the exact tracker stream.  The
tracker may retain coordinates for debugging and map display, but this view
contains only logical identities, coarse status, and bounded objectives.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from .capabilities import IMPLEMENTED_CAPABILITIES
from .identities import player_entity_id
from .state import brain_view


def _text(value: Any, maximum: int = 96) -> str | None:
    return value[:maximum] if isinstance(value, str) and value else None


def _bucket_count(value: Any) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return "unknown"
    if value <= 0:
        return "none"
    if value <= 3:
        return "few"
    return "many"


def _semantic_player(value: Any) -> dict[str, Any] | None:
    if isinstance(value, str):
        logical_id = player_entity_id(value)
        return {"id": logical_id, "online": True} if logical_id else None
    if not isinstance(value, Mapping):
        return None
    logical_id = player_entity_id(value)
    if logical_id is None:
        return None
    result: dict[str, Any] = {"id": logical_id, "online": value.get("online") is not False}
    name = _text(value.get("name"), 48)
    if name:
        result["name"] = name
    role = _text(value.get("role"), 32)
    if role:
        result["role"] = role
    return result


def _semantic_survivor(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, Mapping):
        return None
    survivor_id = value.get("npc_id", value.get("id"))
    if not isinstance(survivor_id, str) or not survivor_id:
        return None
    result: dict[str, Any] = {"id": survivor_id[:96]}
    for key, maximum in (
        ("name", 48), ("role", 32), ("job", 32), ("task", 48),
        ("work_status", 64), ("expedition_phase", 32),
        ("join_assist_username", 96),
    ):
        text = _text(value.get(key), maximum)
        if text:
            result[key] = text
    for key in (
        "alive", "active", "body_present", "control_ready", "running",
        "join_assist",
    ):
        if isinstance(value.get(key), bool):
            result[key] = value[key]
    result["available"] = (
        result.get("alive", True) is True
        and result.get("active", True) is True
        and result.get("body_present", True) is True
    )
    return result


def _semantic_squad(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, Mapping):
        return None
    squad_id = value.get("squad_id", value.get("id"))
    if not isinstance(squad_id, str) or not squad_id:
        return None
    result: dict[str, Any] = {"id": squad_id[:96]}
    leader = _text(value.get("leader"), 96)
    if leader:
        result["leader"] = leader
    mission = _text(value.get("mission"), 96)
    if mission:
        result["mission"] = mission
    members = value.get("members")
    if isinstance(members, list):
        result["members"] = [
            member[:96] for member in members
            if isinstance(member, str)
        ][:16]
    return result


def _semantic_base(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        return {"id": "base.primary", "status": "unknown"}
    result: dict[str, Any] = {
        "id": _text(value.get("base_id", value.get("id")), 96) or "base.primary",
        "name": _text(value.get("name"), 64) or "home base",
    }
    for key in ("has_anchor", "anchored"):
        if isinstance(value.get(key), bool):
            result["anchored"] = value[key]
            break
    guard_count = value.get("assigned_guards", value.get("guard_count"))
    result["guard_count"] = _bucket_count(guard_count)
    return result


def build_agent_perception(
    state: Mapping[str, Any], *, event: Mapping[str, Any] | None = None
) -> dict[str, Any]:
    if not isinstance(state, Mapping):
        raise TypeError("state must be an object")
    self_id = state.get("npc_id", "goblin.primary")
    self_id = self_id if isinstance(self_id, str) and self_id else "goblin.primary"
    self_state: dict[str, Any] = {
        "id": self_id[:96],
        "leader_id": "goblin.primary",
        "command_role": "LEADER" if self_id == "goblin.primary" else "COMPANION",
        "alive": state.get("alive", state.get("npc_alive", False)) is True,
        "body_present": state.get("body_present", False) is True,
    }
    for key, maximum in (
        ("mode", 16), ("task", 48), ("job", 32), ("combat_status", 64),
        ("work_status", 64), ("expedition_phase", 32), ("firearm_type", 64),
    ):
        text = _text(state.get(key), maximum)
        if text:
            self_state[key] = text
    for key in ("control_ready", "npc_engine_ready", "weapon_ready", "running"):
        if isinstance(state.get(key), bool):
            self_state[key] = state[key]
    health = state.get("health")
    if isinstance(health, (int, float)) and not isinstance(health, bool):
        self_state["condition"] = "critical" if health < 25 else "hurt" if health < 70 else "good"

    players_raw = state.get("nearby_players", state.get("players", []))
    players: list[dict[str, Any]] = []
    if isinstance(players_raw, (list, tuple)):
        for value in players_raw[:16]:
            item = _semantic_player(value)
            if item is not None:
                players.append(item)

    survivors_raw = state.get("npcs", state.get("managed_npcs", []))
    survivors: list[dict[str, Any]] = []
    if isinstance(survivors_raw, (list, tuple)):
        for value in survivors_raw[:32]:
            item = _semantic_survivor(value)
            if item is not None:
                survivors.append(item)

    squads_raw = state.get("squads", [])
    squads: list[dict[str, Any]] = []
    if isinstance(squads_raw, (list, tuple)):
        for value in squads_raw[:8]:
            item = _semantic_squad(value)
            if item is not None:
                squads.append(item)

    result: dict[str, Any] = {
        "version": 1,
        "self": self_state,
        "players": players,
        "survivors": survivors,
        "squads": squads,
        "base": _semantic_base(state.get("base")),
        "threat": {
            "level": _text(state.get("threat_level"), 24) or "none",
            "count": _bucket_count(state.get("ordinary_zombie_count")),
        },
        "objective": {
            "task": _text(state.get("task"), 48) or "hold",
            "reason": _text(state.get("planning_reason"), 96) or "event",
        },
        "capabilities": list(IMPLEMENTED_CAPABILITIES),
    }
    if isinstance(event, Mapping):
        result["event"] = brain_view(dict(event))
    # The explicit construction above is the primary guard.  Keep a final
    # recursive redaction so a future field addition cannot bypass it.
    return brain_view(result)

"""Deterministic registries for players, NPCs, squads, bases, and jobs."""

from __future__ import annotations

from dataclasses import dataclass, field
import re
from typing import Iterable


_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$")
_FORMATIONS = {"line", "wedge", "column", "ring", "loose"}
ALLOWED_JOBS = {
    "wander", "guard", "patrol", "scout", "haul", "build", "farm", "loot", "medic", "quartermaster",
}


def valid_entity_id(value: object) -> bool:
    return isinstance(value, str) and _ID_RE.fullmatch(value) is not None


@dataclass
class ManagedEntity:
    entity_id: str
    name: str = ""
    role: str = "companion"
    alive: bool = True
    active: bool = True
    incapacitated: bool = False
    critical_worker: bool = False
    tags: set[str] = field(default_factory=set)


@dataclass(frozen=True)
class Squad:
    squad_id: str
    leader: str
    members: tuple[str, ...]
    formation: str = "loose"


class EntityRegistry:
    """Allowlist of server-reported identities used by command validation."""

    def __init__(self, *, npc_ids: Iterable[str] = (), player_ids: Iterable[str] = ()) -> None:
        self.npcs: dict[str, ManagedEntity] = {}
        self.players: set[str] = set()
        for entity_id in npc_ids:
            self.register_npc(entity_id)
        for player_id in player_ids:
            self.register_player(player_id)

    def register_npc(self, entity_id: str, **kwargs: object) -> ManagedEntity:
        if not valid_entity_id(entity_id):
            raise ValueError("invalid NPC id")
        entity = ManagedEntity(entity_id, **kwargs)
        self.npcs[entity_id] = entity
        return entity

    def register_player(self, player_id: str) -> None:
        if not valid_entity_id(player_id):
            raise ValueError("invalid player id")
        self.players.add(player_id)

    def known_npc(self, entity_id: str) -> bool:
        return entity_id in self.npcs

    def known_player(self, player_id: str) -> bool:
        return player_id in self.players


class SquadManager:
    """Pure deterministic squad selection; model output only requests a plan."""

    def __init__(self, registry: EntityRegistry, *, minimum_base_guards: int = 1) -> None:
        if minimum_base_guards < 0:
            raise ValueError("minimum_base_guards must be non-negative")
        self.registry = registry
        self.minimum_base_guards = minimum_base_guards
        self.squads: dict[str, Squad] = {}

    def choose_members(
        self, requested: Iterable[str], *, squad_id: str = "squad.primary", leader: str, max_size: int = 8
    ) -> tuple[str, ...]:
        if not valid_entity_id(leader) or not self.registry.known_npc(leader):
            raise ValueError("unknown squad leader")
        if not 1 <= max_size <= 16:
            raise ValueError("invalid squad size")
        candidates = [leader]
        for entity_id in requested:
            if not valid_entity_id(entity_id) or entity_id in candidates:
                continue
            entity = self.registry.npcs.get(entity_id)
            if entity is None or not entity.alive or not entity.active or entity.incapacitated or entity.critical_worker:
                continue
            candidates.append(entity_id)
            if len(candidates) >= max_size:
                break
        return tuple(candidates)

    def form(
        self, squad_id: str, *, leader: str, requested: Iterable[str], formation: str = "loose", max_size: int = 8
    ) -> Squad:
        if not valid_entity_id(squad_id):
            raise ValueError("invalid squad id")
        formation = formation.casefold()
        if formation not in _FORMATIONS:
            raise ValueError("unsupported formation")
        members = self.choose_members(requested, squad_id=squad_id, leader=leader, max_size=max_size)
        squad = Squad(squad_id, leader, members, formation)
        self.squads[squad_id] = squad
        return squad

    def dismiss(self, squad_id: str) -> bool:
        return self.squads.pop(squad_id, None) is not None

    def formation_offsets(self, formation: str, count: int) -> tuple[tuple[int, int], ...]:
        """Return semantic offsets; exact world positions stay in Lua/tracker."""
        if formation not in _FORMATIONS or not 0 <= count <= 16:
            raise ValueError("invalid formation request")
        offsets: list[tuple[int, int]] = []
        for index in range(count):
            if formation == "line":
                offsets.append((index - count // 2, 0))
            elif formation == "column":
                offsets.append((0, index))
            elif formation == "wedge":
                row = (index + 1) // 2
                side = -1 if index % 2 else 1
                offsets.append((side * row, row))
            elif formation == "ring":
                offsets.append((index, 0))
            else:
                offsets.append((index % 3 - 1, index // 3))
        return tuple(offsets)


@dataclass(frozen=True)
class Base:
    base_id: str
    name: str
    minimum_guards: int = 1


class BaseManager:
    def __init__(self, *, minimum_guards: int = 1) -> None:
        if minimum_guards < 0:
            raise ValueError("minimum_guards must be non-negative")
        self.minimum_guards = minimum_guards
        self.base = Base("base.primary", "home base", minimum_guards)

    def guard_capacity_allows_departure(self, assigned_guards: int, leaving: int = 1) -> bool:
        return assigned_guards - leaving >= self.minimum_guards


class JobManager:
    def __init__(self, registry: EntityRegistry) -> None:
        self.registry = registry
        self.assignments: dict[str, str] = {}

    def assign(self, npc_id: str, job: str) -> str:
        if not self.registry.known_npc(npc_id):
            raise ValueError("unknown NPC id")
        job = job.casefold()
        if job not in ALLOWED_JOBS:
            raise ValueError("unsupported job")
        entity = self.registry.npcs[npc_id]
        if not entity.alive or not entity.active:
            raise ValueError("NPC is unavailable")
        self.assignments[npc_id] = job
        entity.role = job
        return job


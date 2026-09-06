"""Deterministic registries for players, NPCs, squads, bases, and jobs."""

from __future__ import annotations

from dataclasses import dataclass, field
import re
from collections.abc import Iterable

from .identities import player_entity_id


_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$")
_FORMATIONS = {"line", "wedge", "column", "ring", "loose"}
ALLOWED_JOBS = {
    "wander", "guard", "patrol", "scout", "haul", "hauler", "build", "builder",
    "farm", "farmer", "loot", "scavenge", "disassemble", "medic", "quartermaster",
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
    leader_player: str | None = None
    goblin_member: str | None = None
    npc_members: tuple[str, ...] = ()
    mission: str = "general expedition"
    combat_policy: str = "defensive"
    loot_policy: str = "useful"
    home_base: str = "base.primary"
    created_at: int = 0


class EntityRegistry:
    """Allowlist of server-reported identities used by command validation."""

    def __init__(self, *, npc_ids: Iterable[str] = (), player_ids: Iterable[str] = ()) -> None:
        self.npcs: dict[str, ManagedEntity] = {}
        self.players: set[str] = set()
        self.player_names: dict[str, str] = {}
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

    def register_player(self, player_id: str, *, name: str | None = None) -> str:
        logical_id = player_entity_id(player_id)
        if logical_id is None or not valid_entity_id(logical_id):
            raise ValueError("invalid player id")
        self.players.add(logical_id)
        if isinstance(name, str) and name:
            self.player_names[logical_id] = name[:96]
        elif not player_id.casefold().startswith("player."):
            self.player_names.setdefault(logical_id, player_id[:96])
        return logical_id

    def known_npc(self, entity_id: str) -> bool:
        return entity_id in self.npcs

    def known_player(self, player_id: str) -> bool:
        logical_id = player_entity_id(player_id)
        return logical_id in self.players if logical_id is not None else False

    def native_player_name(self, player_id: str) -> str | None:
        logical_id = player_entity_id(player_id)
        return self.player_names.get(logical_id) if logical_id is not None else None


class SquadManager:
    """Pure deterministic squad selection; model output only requests a plan."""

    def __init__(self, registry: EntityRegistry, *, minimum_base_guards: int = 1) -> None:
        if minimum_base_guards < 0:
            raise ValueError("minimum_base_guards must be non-negative")
        self.registry = registry
        self.minimum_base_guards = minimum_base_guards
        self.squads: dict[str, Squad] = {}

    def choose_members(
        self,
        requested: int | Iterable[str],
        *,
        squad_id: str = "squad.primary",
        leader: str,
        max_size: int = 8,
    ) -> tuple[str, ...]:
        if not valid_entity_id(leader):
            raise ValueError("invalid squad leader")
        if not 1 <= max_size <= 16:
            raise ValueError("invalid squad size")

        leader_is_player = self.registry.known_player(leader)
        leader_is_npc = self.registry.known_npc(leader)
        if not leader_is_player and not leader_is_npc:
            raise ValueError("unknown squad leader")

        if leader_is_player:
            goblin = self.registry.npcs.get("goblin.primary")
            if goblin is None or not goblin.alive or not goblin.active or goblin.incapacitated:
                raise ValueError("Goblin is unavailable for the expedition")
            candidates = ["goblin.primary"]
        else:
            leader_entity = self.registry.npcs[leader]
            if not leader_entity.alive or not leader_entity.active or leader_entity.incapacitated:
                raise ValueError("squad leader is unavailable")
            candidates = [leader]

        if isinstance(requested, int) and not isinstance(requested, bool):
            if not 1 <= requested <= max_size - len(candidates):
                raise ValueError("requested member count exceeds squad capacity")
            requested_ids: Iterable[str] = sorted(self.registry.npcs)
        elif isinstance(requested, Iterable) and not isinstance(requested, (str, bytes)):
            requested_ids = requested
        else:
            raise ValueError("requested members must be ids or a bounded count")

        requested_limit = requested if isinstance(requested, int) else None
        selected_extras = 0
        for entity_id in requested_ids:
            if not valid_entity_id(entity_id) or entity_id in candidates:
                continue
            entity = self.registry.npcs.get(entity_id)
            if entity is None or not entity.alive or not entity.active or entity.incapacitated or entity.critical_worker:
                continue
            if entity.role == "guard" and not self._guard_can_leave(candidates, entity_id):
                continue
            candidates.append(entity_id)
            selected_extras += 1
            if len(candidates) >= max_size or (
                requested_limit is not None and selected_extras >= requested_limit
            ):
                break
        return tuple(candidates)

    def _guard_can_leave(self, selected: Iterable[str], candidate: str) -> bool:
        available = sum(
            1 for entity in self.registry.npcs.values()
            if entity.role == "guard" and entity.alive and entity.active and not entity.incapacitated
        )
        leaving = sum(
            1 for entity_id in selected
            if self.registry.npcs.get(entity_id) is not None
            and self.registry.npcs[entity_id].role == "guard"
        )
        candidate_entity = self.registry.npcs.get(candidate)
        if candidate_entity is not None and candidate_entity.role == "guard":
            leaving += 1
        return available - leaving >= self.minimum_base_guards

    def form(
        self,
        squad_id: str,
        *,
        leader: str,
        requested: int | Iterable[str],
        formation: str = "loose",
        max_size: int = 8,
        mission: str = "general expedition",
        combat_policy: str = "defensive",
        loot_policy: str = "useful",
        created_at: int = 0,
    ) -> Squad:
        if not valid_entity_id(squad_id):
            raise ValueError("invalid squad id")
        formation = formation.casefold()
        if formation not in _FORMATIONS:
            raise ValueError("unsupported formation")
        members = self.choose_members(requested, squad_id=squad_id, leader=leader, max_size=max_size)
        leader_player = leader if self.registry.known_player(leader) else None
        goblin_member = "goblin.primary" if "goblin.primary" in members else None
        npc_members = tuple(member for member in members if member != goblin_member)
        squad = Squad(
            squad_id,
            leader,
            members,
            formation,
            leader_player=leader_player,
            goblin_member=goblin_member,
            npc_members=npc_members,
            mission=mission[:96] if isinstance(mission, str) else "general expedition",
            combat_policy=combat_policy[:32] if isinstance(combat_policy, str) else "defensive",
            loot_policy=loot_policy[:32] if isinstance(loot_policy, str) else "useful",
            created_at=int(created_at),
        )
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

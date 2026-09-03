"""Party invitations and physical travel state."""

from __future__ import annotations

from dataclasses import dataclass
import time


@dataclass(frozen=True)
class TravelPlan:
    player_id: str
    status: str
    target_kind: str
    target_label: str
    created_at: int


@dataclass(frozen=True)
class JoinResult:
    status: str
    reason: str
    travel: TravelPlan | None = None


class PartyManager:
    """Joining means a real travel plan; it never teleports a player or body."""

    def __init__(self, *, max_members: int = 8) -> None:
        self.max_members = max_members
        self.members: set[str] = set()
        self.pending: dict[str, TravelPlan] = {}

    def request_join(
        self,
        player_id: str,
        *,
        now: int | None = None,
        target_label: str = "Goblin's current safe area",
    ) -> JoinResult:
        self._validate_player(player_id)
        if player_id in self.members:
            return JoinResult("member", "player is already in the party")
        if player_id in self.pending:
            return JoinResult("traveling", "player already has a travel plan", self.pending[player_id])
        if len(self.members) >= self.max_members:
            return JoinResult("full", "party is full")
        travel = TravelPlan(
            player_id=player_id,
            status="travel_required",
            target_kind="current_position",
            target_label=target_label[:96],
            created_at=int(now if now is not None else time.time()),
        )
        self.pending[player_id] = travel
        return JoinResult("traveling", "physical travel is required before joining", travel)

    def confirm_arrival(self, player_id: str, *, proximity_confirmed: bool) -> JoinResult:
        self._validate_player(player_id)
        travel = self.pending.get(player_id)
        if travel is None:
            return JoinResult("not_pending", "no pending travel plan")
        if not proximity_confirmed:
            return JoinResult("traveling", "deterministic proximity gate has not passed", travel)
        self.pending.pop(player_id, None)
        self.members.add(player_id)
        return JoinResult("member", "party membership accepted after physical arrival")

    def leave(self, player_id: str) -> bool:
        self._validate_player(player_id)
        self.pending.pop(player_id, None)
        existed = player_id in self.members
        self.members.discard(player_id)
        return existed

    def is_member(self, player_id: str) -> bool:
        return player_id in self.members

    @staticmethod
    def _validate_player(player_id: str) -> None:
        if not isinstance(player_id, str) or not player_id or len(player_id) > 128:
            raise ValueError("invalid player id")


"""The server-side NPC execution boundary.

The Python process never drives a Steam/PZ client. It emits one typed,
high-level command for the dedicated server, where the Lua mod resolves the
stable NPC id through its self-contained friendly NPC adapter. This module
intentionally contains no game coordinates and no Lua/script escape hatch.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .body import DeterministicActionGate, DriverResult
from .controllers import Action, SafeAction
from .ipc import BridgeStore
from .protocol import make_message, new_request_id


NPC_ID = "goblin.primary"


@dataclass(frozen=True)
class NpcState:
    """Coarse NPC contract published by the server-side mod."""

    npc_id: str = NPC_ID
    name: str = "Goblin"
    alive: bool = True
    active: bool = True
    control_ready: bool = False
    npc_engine_ready: bool = False
    role: str = "companion"
    base_job: str = "wander"
    threat_level: str = "none"

    @property
    def body_ready(self) -> bool:
        return (
            self.alive
            and self.active
            and self.control_ready
            and self.npc_engine_ready
        )


class NpcBodyDriver:
    """Publish safe actions for one persistent server-side NPC."""

    def __init__(
        self,
        store: BridgeStore,
        *,
        npc_id: str = NPC_ID,
        control_ready: bool = False,
        npc_engine_ready: bool = False,
    ) -> None:
        if not isinstance(npc_id, str) or not npc_id or len(npc_id) > 96:
            raise ValueError("invalid NPC id")
        self.store = store
        self.npc_id = npc_id
        self.control_ready = bool(control_ready)
        self.npc_engine_ready = bool(npc_engine_ready)
        self.gate = DeterministicActionGate()

    @property
    def available(self) -> bool:
        return self.control_ready and self.npc_engine_ready

    def update_contract(self, *, control_ready: bool, npc_engine_ready: bool) -> None:
        self.control_ready = bool(control_ready)
        self.npc_engine_ready = bool(npc_engine_ready)

    def execute(self, action: SafeAction) -> DriverResult:
        admitted = self.gate.admit(action)
        if not admitted.accepted:
            return admitted
        if action.npc_id != self.npc_id:
            return DriverResult(False, "rejected", "unknown NPC id")
        if not self.available:
            return DriverResult(False, "sensor_only", "NPC engine contract is unavailable")

        request_id = new_request_id("npc")
        fields: dict[str, Any] = {
            "npc_id": self.npc_id,
            "action": action.action.value,
            "priority": action.priority,
            "reason": action.reason[:240],
            "controller_action": action.as_dict(),
        }
        if action.target_kind is not None:
            fields["target"] = {
                "kind": action.target_kind,
                "label": (action.target_label or "")[:96],
            }
        if action.item_name is not None:
            fields["item"] = {
                "name": action.item_name[:64],
                "count": action.item_count or 1,
            }
        if action.text is not None:
            fields["text"] = action.text[:240]
        for key, value in (
            ("leader", action.leader),
            ("job", action.job),
            ("formation", action.formation),
            ("squad_id", action.squad_id),
        ):
            if value is not None:
                fields[key] = value
        if action.members:
            fields["members"] = list(action.members)
        command = make_message("command.npc_action", request_id=request_id, **fields)
        try:
            self.store.publish("commands", command, stem=request_id)
        except (FileExistsError, OSError, ValueError) as exc:
            return DriverResult(False, "failed", f"NPC command was not published: {type(exc).__name__}")
        return DriverResult(True, "published", request_id)

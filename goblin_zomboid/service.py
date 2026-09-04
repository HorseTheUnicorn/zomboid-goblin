"""Server-side Goblin NPC orchestration.

The service owns decisions and durable memory. The dedicated PZ server owns
the NPC, exact world resolution, movement, and persistence of the Bandits2
body through GoblinSurvivor's adapter. No client or Steam lifecycle is part of
this runtime.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

from .agent import AgentRuntime, AgentStatus
from .config import AgentConfig
from .controllers import BodyState, SafetyController
from .entities import BaseManager, EntityRegistry, JobManager, SquadManager
from .events import EventGate
from .hunt import HuntManager
from .ipc import EventConsumer, RequestLedger, ResponseConsumer
from .memory import MemoryStore
from .modes import Mode, ModeController
from .npc import NPC_ID, NpcBodyDriver
from .party import PartyManager
from .protocol import Message
from .qwen import QwenClient, QwenError
from .social import ChatterGovernor
from .state import brain_view, public_view
from .tracker import TrackerStore
from .validator import IntentError, IntentValidator


@dataclass(frozen=True)
class ServiceResult:
    status: str
    detail: str
    request_id: str | None = None


class GoblinService:
    """Coordinates Qwen proposals while preserving deterministic server gates."""

    def __init__(
        self,
        config: AgentConfig,
        *,
        memory_path: str | Path,
        qwen: QwenClient | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.config = config
        self.clock = clock
        self.agent = AgentRuntime(config, clock=clock)
        self.store = self.agent.store
        self.memory = MemoryStore(memory_path)
        self.qwen = qwen
        self.safety = SafetyController()
        self.hunt = HuntManager(self.memory)
        self.party = PartyManager()
        self.chatter = ChatterGovernor(self.memory)
        memory_file = Path(memory_path)
        self.tracker = TrackerStore(memory_file.with_suffix(".tracker.sqlite3"))
        self.entity_registry = EntityRegistry(npc_ids=(NPC_ID,))
        self.squads = SquadManager(self.entity_registry)
        self.base_manager = BaseManager()
        self.jobs = JobManager(self.entity_registry)
        self.npc_driver = NpcBodyDriver(self.store, npc_id=NPC_ID)
        self.event_gate = EventGate()
        self.event_consumer = EventConsumer(
            self.store,
            RequestLedger(memory_file.with_suffix(".events.json"), max_entries=4096),
            max_age_ms=max(30_000, int(config.pz_timeout_seconds * 1000)),
        )
        self.response_consumer = ResponseConsumer(
            self.store,
            RequestLedger(memory_file.with_suffix(".responses.json"), max_entries=4096),
            max_age_ms=max(30_000, int(config.pz_timeout_seconds * 1000)),
        )
        self.mode_controller = ModeController(now=int(self.clock()))
        self.paused = config.start_paused
        self.last_events: list[dict[str, object]] = []
        self.last_response: dict[str, object] | None = None
        self.event_overlay: dict[str, object] = {}
        self.current_body: BodyState | None = None
        self.last_status = "starting"
        self.last_detail = ""
        self.last_action: dict[str, object] | None = None
        self.last_state: dict[str, object] = {}

    def close(self) -> None:
        self.tracker.close()
        self.memory.close()

    def _poll_responses(self) -> None:
        now_ms = int(self.clock() * 1000)
        for response in self.response_consumer.poll(limit=32, now=now_ms):
            fields = response.message.fields
            status = fields.get("status")
            detail = fields.get("detail", "")
            self.last_response = {
                "request_id": response.message.request_id,
                "status": status,
                "detail": detail,
                "timestamp_ms": response.message.timestamp_ms,
            }
            if isinstance(status, str) and isinstance(detail, str):
                try:
                    self.memory.record_memory(
                        "command_response", detail or status,
                        subject=response.message.request_id,
                        metadata={"status": status},
                        created_at=response.message.timestamp_ms // 1000,
                    )
                except ValueError:
                    pass
            try:
                self.response_consumer.finalize(response, detail="response consumed")
            except OSError:
                pass

    def _register_player(self, player: object) -> None:
        if isinstance(player, str) and player:
            try:
                self.entity_registry.register_player(player)
            except ValueError:
                pass
        elif isinstance(player, Mapping):
            value = player.get("id", player.get("player"))
            self._register_player(value)

    def _apply_event(self, kind: str, fields: Mapping[str, object], timestamp_ms: int) -> None:
        created_at = timestamp_ms // 1000
        subject_value = fields.get("player") or fields.get("speaker")
        subject = subject_value if isinstance(subject_value, str) else ""
        if subject:
            self._register_player(subject)
        content = kind.replace("_", " ")
        if subject:
            content = f"{content}: {subject}"
        text = fields.get("text")
        if isinstance(text, str):
            content = f"{content} — {text}"
        try:
            self.memory.record_memory(
                f"event.{kind}", content[:4000], subject=subject,
                metadata=dict(fields), created_at=created_at,
            )
        except ValueError:
            pass

        if subject and kind in {"player_joined", "player_left", "goblin_spotted", "chat"}:
            relationship = self.memory.relationship(subject) or {
                "trust": 0.5, "fear": 0.0, "affinity": 0.0, "tags": [],
            }
            trust = float(relationship.get("trust", 0.5))
            fear = float(relationship.get("fear", 0.0))
            affinity = float(relationship.get("affinity", 0.0))
            if kind == "player_joined":
                affinity += 0.03
                trust += 0.01
            elif kind == "player_left":
                affinity -= 0.01
            elif kind == "goblin_spotted":
                fear += 0.01
            else:
                affinity += 0.01
            try:
                self.memory.upsert_relationship(
                    subject, trust=trust, fear=fear, affinity=affinity,
                    tags=list(relationship.get("tags", [])), last_seen=created_at,
                )
            except (TypeError, ValueError):
                pass

        if kind == "threat_changed" and isinstance(fields.get("threat_level"), str):
            self.event_overlay["threat_level"] = fields["threat_level"]
        elif kind == "injury":
            severity = fields.get("severity")
            self.event_overlay["injury"] = {
                "critical": 1.0, "moderate": 0.6, "minor": 0.25,
            }.get(severity, self.event_overlay.get("injury", 0.0))
        elif kind == "death":
            self.mode_controller.transition(Mode.SAFE, emergency=True, now=created_at)
            self.event_overlay["alive"] = False
        elif kind in {"npc_ready", "npc_spawned", "npc_recovered"}:
            self.event_overlay["alive"] = True

        self.last_events.append({"kind": kind, "timestamp_ms": timestamp_ms, "fields": dict(fields)})
        self.last_events = self.last_events[-32:]
        try:
            self.tracker.record_event(kind, fields, observed_at=created_at)
        except (OSError, TypeError, ValueError):
            pass

    def _reply_to_chat(self, fields: Mapping[str, object], *, event_request_id: str) -> None:
        if self.paused or self.current_body is None or not self.current_body.body_ready:
            return
        text = fields.get("text")
        speaker = fields.get("speaker")
        if not isinstance(text, str) or not isinstance(speaker, str):
            return
        if "goblin" not in text.casefold() and not text.startswith("!goblin"):
            return
        propose_speech = getattr(self.qwen, "propose_speech", None)
        if not callable(propose_speech):
            return
        context = {
            "event": {"speaker": speaker, "text": text},
            "mode": self.current_body.mode,
            "threat_level": self.current_body.threat_level,
            "recent_memories": self.memory.recent_memories(8),
        }
        try:
            speech = propose_speech(context)
            intent = IntentValidator().validate({
                "intent": "SAY", "mode": self.current_body.mode,
                "text": speech, "priority": 2,
            })
        except (IntentError, QwenError, TypeError, ValueError):
            return
        decision = self.safety.decide(intent, self.current_body)
        if not decision.accepted or decision.action is None:
            return
        chatter = self.chatter.record(
            f"reply:{event_request_id}", "game", speech,
            now=int(self.clock()), priority=2,
        )
        if not chatter.allowed:
            return
        result = self.npc_driver.execute(decision.action)
        if result.accepted:
            self.last_action = decision.action.as_dict()
            self.last_status = "npc_speech_published"
            self.last_detail = "addressed chat reply sent to the server-side NPC"

    def _poll_events(self) -> None:
        now_ms = int(self.clock() * 1000)
        for event in self.event_consumer.poll(limit=32, now=now_ms):
            suffix = event.message.type.removeprefix("event.")
            decision = self.event_gate.make(
                suffix, event.message.fields,
                now=event.message.timestamp_ms // 1000,
                request_id=event.message.request_id,
            )
            if not decision.accepted or decision.message is None:
                try:
                    self.store.deadletter(event.item, decision.reason)
                except OSError:
                    pass
                continue
            self._apply_event(suffix, decision.message.fields, event.message.timestamp_ms)
            if suffix == "chat":
                self._reply_to_chat(
                    decision.message.fields, event_request_id=event.message.request_id
                )
            try:
                self.event_consumer.finalize(event, detail="event consumed")
            except OSError:
                pass

    def _read_state(self) -> Message | None:
        try:
            return self.store.read_runtime(
                "zomboid-state",
                max_age_ms=int(self.config.pz_timeout_seconds * 1000),
                now=int(self.clock() * 1000),
            )
        except (FileNotFoundError, OSError, ValueError):
            return None

    def _read_exact_state(self) -> Message | None:
        try:
            return self.store.read_runtime(
                "zomboid-exact-state",
                max_age_ms=int(self.config.pz_timeout_seconds * 1000),
                now=int(self.clock() * 1000),
            )
        except (FileNotFoundError, OSError, ValueError):
            return None

    @staticmethod
    def _number(fields: Mapping[str, object], key: str, default: float = 0.0) -> float:
        value = fields.get(key, default)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return default
        if not math.isfinite(float(value)):
            return default
        return min(1.0, max(0.0, float(value)))

    @classmethod
    def _body_state(cls, fields: Mapping[str, object]) -> BodyState:
        threat = fields.get("threat_level", "none")
        mode = fields.get("mode", "SAFE")
        return BodyState(
            alive=bool(fields.get("alive", fields.get("npc_alive", True))),
            body_present=bool(fields.get("body_present", fields.get("npc_alive", False))),
            hunger=cls._number(fields, "hunger"), thirst=cls._number(fields, "thirst"),
            fatigue=cls._number(fields, "fatigue"), panic=cls._number(fields, "panic"),
            injury=cls._number(fields, "injury"),
            threat_level=threat if threat in {"none", "near", "overwhelming"} else "none",
            weapon_ready=bool(fields.get("weapon_ready", False)),
            has_food=bool(fields.get("has_food", False)),
            has_water=bool(fields.get("has_water", False)),
            has_medical=bool(fields.get("has_medical", False)),
            mode=mode if mode in {"SAFE", "ROAM", "PARTY", "HUNT"} else "SAFE",
            control_ready=bool(fields.get("control_ready", False)),
            npc_engine_ready=bool(fields.get("npc_engine_ready", False)),
            npc_id=(fields.get("npc_id") if isinstance(fields.get("npc_id"), str) else NPC_ID),
            body_mode=(fields.get("body_mode") if fields.get("body_mode") in {"disabled", "sensor_only", "npc"} else "sensor_only"),
        )

    def _sync_players(self, fields: Mapping[str, object]) -> None:
        players = fields.get("nearby_players", fields.get("players", []))
        if isinstance(players, list):
            for player in players:
                self._register_player(player)

    def _validate_references(self, intent: Any) -> str | None:
        data = intent.data
        npc_id = data.get("npc_id", NPC_ID)
        if npc_id != NPC_ID:
            return "unknown NPC id"
        target = data.get("target")
        if isinstance(target, Mapping) and target.get("kind") == "player":
            player = target.get("player", target.get("name", target.get("label")))
            if isinstance(player, str) and not self.entity_registry.known_player(player):
                return "player is not in the server-reported allowlist"
        if intent.intent == "ASSIGN_JOB":
            try:
                self.jobs.assign(NPC_ID, str(data.get("job", "")))
            except ValueError as exc:
                return str(exc)
        if intent.intent == "FORM_SQUAD":
            try:
                members = data.get("requested_members", data.get("members", []))
                self.squads.form(
                    data.get("squad_id", "squad.primary"),
                    leader=str(data["leader"]), requested=members,
                    formation=data.get("formation", "loose"),
                )
            except (KeyError, TypeError, ValueError) as exc:
                return str(exc)
        return None

    def _run_npc_once(self, state_message: Message) -> ServiceResult:
        self.last_state = brain_view(state_message.fields)
        self._sync_players(state_message.fields)
        tracker_state = dict(state_message.fields)
        exact_message = self._read_exact_state()
        if exact_message is not None and exact_message.type == "runtime.exact_state":
            entities = exact_message.fields.get("entities")
            if isinstance(entities, list):
                tracker_state["entities"] = entities
        try:
            self.tracker.record_state(
                tracker_state, observed_at=state_message.timestamp_ms // 1000
            )
        except (OSError, TypeError, ValueError):
            pass
        body = self._body_state(state_message.fields)
        self.current_body = body
        self.last_state.update(self.event_overlay)
        self.last_state.update({
            "body_mode": body.body_mode,
            "npc_id": body.npc_id,
            "control_ready": body.control_ready,
            "npc_engine_ready": body.npc_engine_ready,
        })
        self.npc_driver.npc_id = body.npc_id
        self.npc_driver.update_contract(
            control_ready=body.control_ready,
            npc_engine_ready=body.npc_engine_ready,
        )
        if not body.body_ready:
            self.last_status = "sensor_only"
            self.last_detail = "waiting for the persistent server-side NPC contract"
            return ServiceResult(self.last_status, self.last_detail)
        if self.qwen is None:
            self.last_status = "no_brain"
            self.last_detail = "no Qwen adapter configured"
            return ServiceResult(self.last_status, self.last_detail)
        try:
            intent = self.qwen.propose_intent(self.last_state)
        except QwenError as exc:
            self.last_status = "brain_rejected"
            self.last_detail = str(exc)
            return ServiceResult(self.last_status, self.last_detail)
        reference_error = self._validate_references(intent)
        if reference_error is not None:
            self.last_status = "controller_rejected"
            self.last_detail = reference_error
            return ServiceResult(self.last_status, self.last_detail)
        decision = self.safety.decide(intent, body)
        if not decision.accepted or decision.action is None:
            self.last_status = "controller_rejected"
            self.last_detail = decision.reason
            self.last_action = None
            return ServiceResult(self.last_status, self.last_detail)
        result = self.npc_driver.execute(decision.action)
        if not result.accepted:
            self.last_status = result.status
            self.last_detail = result.detail
            return ServiceResult(self.last_status, self.last_detail)
        self.last_action = decision.action.as_dict()
        self.last_status = "npc_command_published"
        self.last_detail = "validated action sent to the dedicated server NPC executor"
        return ServiceResult(self.last_status, self.last_detail, result.detail)

    def run_once(self) -> ServiceResult:
        agent_status: AgentStatus = self.agent.run_once()
        if not self.config.enabled:
            self.last_status = "disabled"
            self.last_detail = "master feature flag is false"
            return ServiceResult(self.last_status, self.last_detail)
        self._poll_responses()
        self._poll_events()
        if self.paused:
            self.last_status = "paused"
            self.last_detail = "service requires an explicit safe-stage resume"
            return ServiceResult(self.last_status, self.last_detail)
        state_message = self._read_state()
        if state_message is None:
            self.last_status = "waiting_for_pz"
            self.last_detail = "PZ state heartbeat is missing or stale"
            return ServiceResult(self.last_status, self.last_detail)
        if state_message.type != "runtime.state":
            self.last_status = "waiting_for_pz"
            self.last_detail = "PZ state heartbeat has an unexpected type"
            return ServiceResult(self.last_status, self.last_detail)
        return self._run_npc_once(state_message)

    def run_forever(self, stop_event: threading.Event | None = None) -> None:
        stop_event = stop_event or threading.Event()
        while not stop_event.is_set():
            self.run_once()
            stop_event.wait(self.config.heartbeat_seconds)

    def control(self, action: str) -> dict[str, object]:
        if action == "pause":
            self.paused = True
            return {"ok": True, "status": "paused"}
        if action == "resume":
            if not self.config.enabled:
                return {"ok": False, "status": "disabled", "detail": "GoblinEnabled is false"}
            self.paused = False
            return {"ok": True, "status": "resumed"}
        if action == "status":
            return {"ok": True, "status": self.last_status, "detail": self.last_detail}
        return {"ok": False, "status": "rejected", "detail": "unsupported admin action"}

    def public_snapshot(self) -> dict[str, object]:
        result = public_view(self.last_state)
        result.update(self.hunt.public_status())
        return public_view(result)

    def admin_snapshot(self) -> dict[str, object]:
        return {
            "feature_enabled": self.config.enabled,
            "paused": self.paused,
            "status": self.last_status,
            "detail": self.last_detail,
            "public": self.public_snapshot(),
            "brain_state": dict(self.last_state),
            "last_action": dict(self.last_action) if self.last_action else None,
            "last_response": dict(self.last_response) if self.last_response else None,
            "last_events": [dict(event) for event in self.last_events],
            "npc": {
                "id": NPC_ID,
                "body_mode": self.current_body.body_mode if self.current_body else "sensor_only",
                "body_ready": self.current_body.body_ready if self.current_body else False,
            },
            "squads": {key: squad.__dict__.copy() for key, squad in self.squads.squads.items()},
            "jobs": dict(self.jobs.assignments),
            "base": self.base_manager.base.__dict__.copy(),
            "mode": {
                "value": self.mode_controller.state.mode.value,
                "reason": self.mode_controller.state.reason,
                "changed_at": self.mode_controller.state.changed_at,
            },
            "hunt": self.hunt.admin_status(),
        }

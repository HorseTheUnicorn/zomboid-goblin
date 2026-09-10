"""Qwen orchestration for one friendly Goblin companion per connected player.

The Project Zomboid server owns bodies and deterministic gameplay.  This
process only turns addressed player chat into a short in-character reply and a
validated semantic action for that same player's Goblin.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

from .agent import AgentRuntime
from .config import AgentConfig
from .controllers import Action, BodyState, SafeAction, SafetyController
from .events import EventGate
from .ipc import EventConsumer, RequestLedger, ResponseConsumer
from .memory import MemoryStore
from .npc import NPC_ID, NpcBodyDriver, npc_id_for_owner
from .protocol import Message
from .qwen import QwenClient, QwenError
from .social import ChatterGovernor
from .state import brain_view, public_view
from .tracker import TrackerStore
from .validator import IntentError


@dataclass(frozen=True)
class ServiceResult:
    status: str
    detail: str
    request_id: str | None = None


class GoblinService:
    """Route a player's words to that player's server-owned Goblin."""

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
        self.chatter = ChatterGovernor(self.memory)
        memory_file = Path(memory_path)
        self.tracker = TrackerStore(memory_file.with_suffix(".tracker.sqlite3"))
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
        self.npc_driver = NpcBodyDriver(self.store, npc_id=NPC_ID)
        self.paused = config.start_paused
        self.pending_chats: list[dict[str, object]] = []
        self.last_events: list[dict[str, object]] = []
        self.last_response: dict[str, object] | None = None
        self.last_state: dict[str, object] = {}
        self.current_body: BodyState | None = None
        self.current_owner: str | None = None
        self.last_action: dict[str, object] | None = None
        self.last_status = "starting"
        self.last_detail = ""

    def close(self) -> None:
        self.tracker.close()
        self.memory.close()

    def _poll_responses(self) -> None:
        now_ms = int(self.clock() * 1000)
        for response in self.response_consumer.poll(limit=32, now=now_ms):
            fields = response.message.fields
            self.last_response = {
                "request_id": response.message.request_id,
                "status": fields.get("status"),
                "detail": fields.get("detail", ""),
                "timestamp_ms": response.message.timestamp_ms,
            }
            try:
                self.response_consumer.finalize(response, detail="response consumed")
            except OSError:
                pass

    @staticmethod
    def _chat_is_addressed(fields: Mapping[str, object]) -> bool:
        text = fields.get("text")
        return isinstance(text, str) and (
            "goblin" in text.casefold() or text.lstrip().casefold().startswith("!goblin")
        )

    def _poll_events(self) -> None:
        now_ms = int(self.clock() * 1000)
        for event in self.event_consumer.poll(limit=32, now=now_ms):
            kind = event.message.type.removeprefix("event.")
            decision = self.event_gate.make(
                kind,
                event.message.fields,
                now=event.message.timestamp_ms // 1000,
                request_id=event.message.request_id,
            )
            if not decision.accepted or decision.message is None:
                try:
                    self.store.deadletter(event.item, decision.reason)
                except OSError:
                    pass
                continue

            fields = dict(decision.message.fields)
            safe_fields = {key: value for key, value in fields.items() if key != "authority_token"}
            self.last_events.append({
                "kind": kind,
                "timestamp_ms": event.message.timestamp_ms,
                "fields": safe_fields,
            })
            self.last_events = self.last_events[-32:]
            try:
                self.tracker.record_event(kind, safe_fields, observed_at=event.message.timestamp_ms // 1000)
            except (OSError, TypeError, ValueError):
                pass

            if kind == "chat" and self._chat_is_addressed(fields):
                queued = dict(fields)
                queued["event_request_id"] = event.message.request_id
                self.pending_chats.append(queued)
                self.pending_chats = self.pending_chats[-32:]

            speaker = fields.get("speaker", fields.get("player"))
            text = safe_fields.get("text")
            if isinstance(speaker, str) or isinstance(text, str):
                content = f"{kind}: {speaker or ''}"
                if isinstance(text, str):
                    content += f" — {text}"
                try:
                    self.memory.record_memory(
                        f"event.{kind}", content[:4000],
                        subject=speaker if isinstance(speaker, str) else "",
                        metadata=safe_fields,
                        created_at=event.message.timestamp_ms // 1000,
                    )
                except (TypeError, ValueError):
                    pass

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
            alive=bool(fields.get("alive", True)),
            body_present=bool(fields.get("body_present", False)),
            hunger=cls._number(fields, "hunger"),
            thirst=cls._number(fields, "thirst"),
            fatigue=cls._number(fields, "fatigue"),
            panic=cls._number(fields, "panic"),
            injury=cls._number(fields, "injury"),
            threat_level=threat if threat in {"none", "near", "overwhelming"} else "none",
            weapon_ready=bool(fields.get("weapon_ready", False)),
            has_food=bool(fields.get("has_food", False)),
            has_water=bool(fields.get("has_water", False)),
            has_medical=bool(fields.get("has_medical", False)),
            mode=mode if mode in {"SAFE", "ROAM", "PARTY", "HUNT"} else "SAFE",
            control_ready=bool(fields.get("control_ready", False)),
            npc_engine_ready=bool(fields.get("npc_engine_ready", False)),
            npc_id=fields.get("npc_id") if isinstance(fields.get("npc_id"), str) else NPC_ID,
            body_mode=fields.get("body_mode") if fields.get("body_mode") in {"disabled", "sensor_only", "npc"} else "sensor_only",
        )

    @staticmethod
    def _companions(fields: Mapping[str, object]) -> list[Mapping[str, object]]:
        raw = fields.get("companions", [])
        if not isinstance(raw, list):
            return []
        return [item for item in raw if isinstance(item, Mapping)]

    @classmethod
    def _companion_for_owner(
        cls, fields: Mapping[str, object], owner: str | None
    ) -> Mapping[str, object] | None:
        companions = cls._companions(fields)
        if isinstance(owner, str):
            wanted = owner.casefold()
            for companion in companions:
                value = companion.get("owner")
                if isinstance(value, str) and value.casefold() == wanted:
                    return companion
        for companion in companions:
            if companion.get("body_present") is True:
                return companion
        return companions[0] if companions else None

    def _configure_driver(self, companion: Mapping[str, object]) -> BodyState:
        body = self._body_state(companion)
        self.current_body = body
        owner = companion.get("owner")
        self.current_owner = owner if isinstance(owner, str) else None
        self.npc_driver.npc_id = body.npc_id
        self.npc_driver.update_contract(
            control_ready=body.control_ready,
            npc_engine_ready=body.npc_engine_ready,
        )
        return body

    def _publish_reply(
        self,
        chat: Mapping[str, object],
        companion: Mapping[str, object],
    ) -> str | None:
        if self.qwen is None:
            return None
        speaker = chat.get("speaker")
        text = chat.get("text")
        if not isinstance(speaker, str) or not isinstance(text, str):
            return None
        body = self._configure_driver(companion)
        if not body.body_ready:
            return None
        context = {
            "event": {"speaker": speaker, "text": text},
            "controlled_npc_id": body.npc_id,
            "controlled_owner": speaker,
            "companion": brain_view(companion),
            "recent_memories": self.memory.recent_memories(8),
        }
        try:
            speech = self.qwen.propose_speech(context)
        except (QwenError, TypeError, ValueError):
            return None
        event_key = f"reply:{chat.get('event_request_id', 'chat')}"
        decision = self.chatter.record(
            event_key, "game", speech, now=int(self.clock()), priority=3
        )
        if not decision.allowed:
            return None
        action = SafeAction(
            Action.SAY, 3, "addressed player reply", text=speech, npc_id=body.npc_id
        )
        result = self.npc_driver.execute(action, owner=speaker)
        return speech if result.accepted else None

    def _handle_chat(
        self,
        chat: Mapping[str, object],
        companion: Mapping[str, object],
    ) -> ServiceResult:
        speaker = chat.get("speaker")
        text = chat.get("text")
        if not isinstance(speaker, str) or not isinstance(text, str):
            return ServiceResult("chat_ignored", "chat event was malformed")
        body = self._configure_driver(companion)
        if not body.body_ready:
            return ServiceResult("sensor_only", f"{speaker}'s Goblin body is not ready")

        speech = self._publish_reply(chat, companion)
        if self.qwen is None:
            detail = "Qwen is unavailable; deterministic slash commands still work"
            return ServiceResult("no_qwen", detail)

        context = brain_view(dict(companion))
        context.update({
            "controlled_npc_id": body.npc_id,
            "controlled_owner": speaker,
            "event": {"type": "chat", "speaker": speaker, "text": text},
        })
        try:
            intent = self.qwen.propose_intent(context)
        except QwenError as exc:
            return ServiceResult("qwen_failed", f"speech={bool(speech)}; intent failed: {exc}")

        decision = self.safety.decide(intent, body)
        if not decision.accepted or decision.action is None:
            return ServiceResult("controller_rejected", decision.reason)
        if decision.action.action is Action.SAY:
            return ServiceResult(
                "npc_spoke" if speech else "npc_steady",
                "addressed conversation handled without a gameplay action",
            )

        authority_token = chat.get("authority_token")
        result = self.npc_driver.execute(
            decision.action,
            authority_token=authority_token if isinstance(authority_token, str) else None,
            owner=speaker,
        )
        self.last_action = decision.action.as_dict()
        if not result.accepted:
            return ServiceResult(result.status, result.detail)
        return ServiceResult(
            "npc_command_published",
            f"{speaker}'s {body.npc_id} received {decision.action.action.value}",
            result.detail,
        )

    def _record_state(self, state_message: Message) -> None:
        self.last_state = brain_view(state_message.fields)
        tracker_state = dict(state_message.fields)
        exact = self._read_exact_state()
        if exact is not None and exact.type == "runtime.exact_state":
            entities = exact.fields.get("entities")
            if isinstance(entities, list):
                tracker_state["entities"] = entities
        try:
            self.tracker.record_state(
                tracker_state, observed_at=state_message.timestamp_ms // 1000
            )
        except (OSError, TypeError, ValueError):
            pass

    def run_once(self) -> ServiceResult:
        self.agent.run_once()
        if not self.config.enabled:
            self.last_status = "disabled"
            self.last_detail = "master feature flag is false"
            return ServiceResult(self.last_status, self.last_detail)
        self._poll_responses()
        self._poll_events()
        if self.paused:
            self.last_status = "paused"
            self.last_detail = "service requires resume"
            return ServiceResult(self.last_status, self.last_detail)

        state_message = self._read_state()
        if state_message is None or state_message.type != "runtime.state":
            self.last_status = "waiting_for_pz"
            self.last_detail = "PZ state heartbeat is missing, stale, or invalid"
            return ServiceResult(self.last_status, self.last_detail)
        self._record_state(state_message)

        if self.pending_chats:
            chat = self.pending_chats.pop(0)
            speaker = chat.get("speaker")
            companion = self._companion_for_owner(
                state_message.fields, speaker if isinstance(speaker, str) else None
            )
            if companion is None:
                self.last_status = "waiting_for_goblin"
                self.last_detail = f"no companion telemetry for {speaker}"
                return ServiceResult(self.last_status, self.last_detail)
            result = self._handle_chat(chat, companion)
            self.last_status, self.last_detail = result.status, result.detail
            return result

        companion = self._companion_for_owner(state_message.fields, None)
        if companion is not None:
            self._configure_driver(companion)
            self.last_status = "npc_steady"
            self.last_detail = f"{len(self._companions(state_message.fields))} Goblin companion(s) online"
        else:
            self.current_body = None
            self.current_owner = None
            self.last_status = "waiting_for_goblin"
            self.last_detail = "no Goblin companions are online"
        return ServiceResult(self.last_status, self.last_detail)

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
                return {"ok": False, "status": "disabled", "detail": "GOBLIN_ENABLED is false"}
            self.paused = False
            return {"ok": True, "status": "resumed"}
        if action == "status":
            return {"ok": True, "status": self.last_status, "detail": self.last_detail}
        return {"ok": False, "status": "rejected", "detail": "unsupported admin action"}

    def public_snapshot(self) -> dict[str, object]:
        result = public_view(self.last_state)
        companions = self.last_state.get("companions")
        if isinstance(companions, list):
            result["companions"] = companions
        return result

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
            "pending_chat_count": len(self.pending_chats),
            "selected_owner": self.current_owner,
            "selected_npc_id": self.current_body.npc_id if self.current_body else None,
            "companion_count": len(self._companions(self.last_state)),
        }

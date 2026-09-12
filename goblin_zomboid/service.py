"""Qwen orchestration for one friendly Goblin companion per connected player.

The Project Zomboid server owns bodies and deterministic gameplay.  This
process only turns addressed player chat into a short in-character reply and a
validated semantic action for that same player's Goblin.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import logging
from pathlib import Path
import threading
import time
import random
from concurrent.futures import ThreadPoolExecutor
from collections.abc import Callable, Mapping
from typing import Any

from .agent import AgentRuntime
from .config import AgentConfig
from .controllers import Action, BodyState, SafeAction, SafetyController
from .events import EventGate
from .ipc import EventConsumer, RequestLedger, ResponseConsumer
from .memory import MemoryStore
from .npc import NPC_ID, OFFLINE_ACTIONS, NpcBodyDriver, npc_id_for_owner
from .protocol import Message
from .qwen import QwenClient, QwenError
from .social import ChatterGovernor
from .state import brain_view, public_view
from .tracker import TrackerStore
from .validator import IntentError

LOG = logging.getLogger(__name__)


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
        self.next_offline_decision: dict[str, float] = {}
        self.next_ambient: dict[str, float] = {}
        self.ambient_quiet_until=0.0
        self.ambient_executor=None
        self.ambient_future=None
        self.ambient_selected=None
        self.ambient_recent: list[str] = []
        self.last_events: list[dict[str, object]] = []
        self.last_response: dict[str, object] | None = None
        self.last_state: dict[str, object] = {}
        self.current_body: BodyState | None = None
        self.current_owner: str | None = None
        self.last_action: dict[str, object] | None = None
        self.last_status = "starting"
        self.last_detail = ""
        self.chat_results: list[dict[str, object]] = []
        self.next_wait_poll = 0.0
        if qwen is not None and callable(getattr(qwen,"set_wait_callback",None)):
            qwen.set_wait_callback(self._poll_during_inference)

    def close(self) -> None:
        if self.ambient_executor is not None:
            self.ambient_executor.shutdown(wait=False,cancel_futures=True)
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
            "goblin" in text.casefold() or fields.get("addressed") is True
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

    def _poll_during_inference(self) -> None:
        """Drain fresh events while HTTP is pending, without changing its owner."""
        now = self.clock()
        if now < self.next_wait_poll:
            return
        self.next_wait_poll = now + 1.0
        self.agent.run_once()
        self._poll_events()
        self._poll_responses()
        state = self._read_state()
        if state is not None and state.type == "runtime.state":
            self._record_state(state)

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
            return None  # Never answer/control another player's Goblin as fallback.
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

    def _roster_context(self) -> list[dict[str, object]]:
        keys = ("npc_id", "owner", "name", "persisted", "owner_online", "body_present", "task")
        return [{key: entry[key] for key in keys if key in entry}
                for entry in self._companions(self.last_state)]

    def _publish_reply(
        self,
        chat: Mapping[str, object],
        companion: Mapping[str, object],
        prepared_speech: str | None = None,
    ) -> str | None:
        if self.qwen is None and prepared_speech is None:
            return None
        speaker = chat.get("speaker")
        text = chat.get("text")
        if not isinstance(speaker, str) or not isinstance(text, str):
            return None
        body = self._configure_driver(companion)
        if not body.body_ready:
            return None
        context = {
            "event": {"speaker": speaker, "text": text,
                      "direct_action": chat.get("direct_action"),
                      "direct_applied": chat.get("direct_applied", False)},
            "controlled_npc_id": body.npc_id,
            "controlled_owner": speaker,
            "companion": brain_view(companion),
            "persistent_goblins": self._roster_context(),
            "recent_memories": self.memory.recent_memories(8),
        }
        try:
            speech = prepared_speech if prepared_speech is not None else self.qwen.propose_speech(context)
        except (QwenError, TypeError, ValueError) as exc:
            LOG.warning("QWEN_SPEECH_FAILED owner=%s detail=%s", speaker, str(exc)[:240])
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

        if isinstance(chat.get("direct_action"), str):
            # A rejected direct order is still handled: never ask the model to
            # replace it with FOLLOW (or another task) after the game refused it.
            # Current servers report the exact result in game immediately.
            if chat.get("direct_reported") is True:
                return ServiceResult("npc_command_handled", str(chat.get("direct_detail", "server handled order")))
            detail = chat.get("direct_detail")
            if not isinstance(detail, str) or not detail.strip():
                detail = "order accepted" if chat.get("direct_applied") is True else "I could not carry out that order"
            speech = self._publish_reply(chat, companion, prepared_speech=f"Comrade, {detail[:180]}.")
            return ServiceResult("npc_spoke" if speech else "npc_steady",
                                 "server handled the requested task; no substitute or duplicate action")
        if self.qwen is None:
            detail = "Qwen is unavailable; deterministic slash commands still work"
            return ServiceResult("no_qwen", detail)

        context = {"mode": body.mode}
        context.update({
            "controlled_npc_id": body.npc_id,
            "controlled_owner": speaker,
            "event": {"type": "chat", "speaker": speaker, "text": text},
            "persistent_goblins": self._roster_context(),
            "companion": brain_view(companion),
        })
        speech = None
        try:
            combined = getattr(self.qwen, "propose_chat", None)
            if callable(combined):
                intent, generated_speech = combined(context)
                speech = self._publish_reply(chat, companion, prepared_speech=generated_speech)
            else:
                # Compatibility for older adapters; production uses one request.
                speech = self._publish_reply(chat, companion)
                intent = self.qwen.propose_intent(context)
        except QwenError as exc:
            self._publish_reply(chat, companion, prepared_speech=
                "Comrade, my radio jammed. Try again; /goblin follow, loot, home or wait still work.")
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

    @staticmethod
    def _offline_eligible(companion: Mapping[str, object]) -> bool:
        return (companion.get("owner_online") is False
                and companion.get("body_present") is True
                and (companion.get("task") == "FOLLOW" or companion.get("autonomous") is True)
                and isinstance(companion.get("authority_token"), str))

    def _handle_offline(self, companion: Mapping[str, object]) -> ServiceResult:
        body = self._configure_driver(companion)
        self.next_offline_decision[body.npc_id] = self.clock() + max(10, self.config.planning_interval_seconds)
        context = brain_view(companion)
        context.update({
            "controlled_npc_id": body.npc_id, "controlled_owner": companion.get("owner"),
            "event": {"type": "offline_decision"},
            "allowed_offline_intents": sorted(OFFLINE_ACTIONS),
            "persistent_goblins": self._roster_context(),
        })
        try:
            intent = self.qwen.propose_intent(context)
        except (QwenError, TypeError, ValueError) as exc:
            return ServiceResult("qwen_failed", f"offline decision failed: {exc}; Lua chores continue")
        decision = self.safety.decide(intent, body)
        if not decision.accepted or decision.action is None or decision.action.action.value not in OFFLINE_ACTIONS:
            return ServiceResult("controller_rejected", "Qwen proposed an unsupported offline task")
        # A model request can outlast a reconnect. Recheck before publishing;
        # Lua independently checks the live owner and one-use task-bound grant.
        current = self._read_state()
        latest = self._companion_for_owner(current.fields, companion.get("owner")) if current else None
        if latest is None or not self._offline_eligible(latest):
            return ServiceResult("offline_cancelled", "owner returned, body unloaded, or explicit task took priority")
        action = decision.action.action.value
        task = {"LOOT_AREA": "LOOT", "SECURE_BASE": "FORTIFY"}.get(action, action)
        if latest.get("task") == task:
            return ServiceResult("npc_steady", "Qwen kept the existing offline job")
        result = self.npc_driver.execute(
            decision.action, owner=companion.get("owner"),
            authority_token=companion.get("authority_token"), autonomous=True,
        )
        self.last_action = decision.action.as_dict()
        return ServiceResult("offline_command_published" if result.accepted else result.status,
                             result.detail, result.detail if result.accepted else None)

    @staticmethod
    def _ambient_eligible(companion: Mapping[str, object]) -> bool:
        idle=companion.get("owner_idle_seconds",0)
        return (companion.get("owner_online") is True and companion.get("body_present") is True
                and companion.get("control_ready") is True and companion.get("npc_engine_ready") is True
                and isinstance(idle,(int,float)) and math.isfinite(idle) and idle>=30
                and not companion.get("riding") and not companion.get("transport_active")
                and companion.get("combat_state","NONE")=="NONE"
                and (companion.get("task")=="FOLLOW" or companion.get("autonomous") is True))

    def _ambient_tick(self, fields: Mapping[str, object]) -> ServiceResult | None:
        now=self.clock()
        if self.ambient_future is not None:
            if not self.ambient_future.done(): return None
            future,selected=self.ambient_future,self.ambient_selected
            self.ambient_future,self.ambient_selected=None,None
            try:
                speech=future.result()
            except Exception:
                LOG.warning("AMBIENT_FAILED; ordinary chat and gameplay continue")
                return None
            latest=self._companion_for_owner(fields,selected["owner"])
            if (self.pending_chats or now<self.ambient_quiet_until or latest is None
                    or latest.get("npc_id")!=selected["npc_id"] or not self._ambient_eligible(latest)):
                return None
            if speech in self.ambient_recent: return None
            key=f"ambient:{selected['npc_id']}:{int(now)}"
            decision=self.chatter.record(key,"game",speech,now=int(now),priority=1)
            if not decision.allowed: return None
            body=self._configure_driver(latest)
            result=self.npc_driver.execute(SafeAction(Action.SAY,0,"Lenin-themed downtime remark",
                text=speech,npc_id=body.npc_id),owner=selected["owner"])
            if result.accepted:
                self.ambient_recent=(self.ambient_recent+[speech])[-6:]
                self.ambient_quiet_until=now+45
                LOG.info("AMBIENT_SAY owner=%s",selected["owner"])
                return ServiceResult("ambient_spoken","short downtime remark published")
            return None
        if self.pending_chats or now<self.ambient_quiet_until: return None
        propose=getattr(self.qwen,"propose_ambient",None)
        if not callable(propose): return None
        for companion in self._companions(fields):
            if not self._ambient_eligible(companion): continue
            npc_id=companion.get("npc_id")
            if not isinstance(npc_id,str): continue
            if npc_id not in self.next_ambient:
                self.next_ambient[npc_id]=now+random.uniform(120,240)
            if now<self.next_ambient[npc_id]: continue
            self.next_ambient[npc_id]=now+random.uniform(120,240)
            if not self.chatter.allow(f"ambient:{npc_id}",now=int(now),priority=1).allowed: continue
            topic=random.choice(("Lenin and the distribution of canned food","Lenin's revolution versus these zombies",
                "Lenin, comrades, and our ramshackle base","Lenin and the tyranny of missing building supplies",
                "Lenin and the revolutionary importance of decent boots","Lenin and a committee for ridiculous survival problems"))
            context={"companion":brain_view(companion),"controlled_npc_id":npc_id,
                "controlled_owner":companion.get("owner"),"ambient_topic":topic,
                "recent_ambient_lines":list(self.ambient_recent)}
            if self.ambient_executor is None:
                self.ambient_executor=ThreadPoolExecutor(max_workers=1,thread_name_prefix="goblin-aside")
            self.ambient_selected={"npc_id":npc_id,"owner":companion.get("owner")}
            self.ambient_future=self.ambient_executor.submit(propose,context)
            break
        return None

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
            self.ambient_quiet_until=self.clock()+45
            chat = self.pending_chats.pop(0)
            speaker = chat.get("speaker")
            companion = self._companion_for_owner(
                state_message.fields, speaker if isinstance(speaker, str) else None
            )
            if companion is None:
                self.last_status = "waiting_for_goblin"
                self.last_detail = f"no companion telemetry for {speaker}"
                return ServiceResult(self.last_status, self.last_detail)
            started = time.monotonic()
            try:
                result = self._handle_chat(chat, companion)
            except Exception:
                # This chat is consumed once. Never replay a potentially partially
                # published action, and never take other players' chat down with it.
                LOG.exception("CHAT_FAILED owner=%s event_id=%s", speaker, chat.get("event_request_id"))
                try:
                    self._publish_reply(chat, companion, "Comrade, that command failed. I am still here; please give the order again.")
                except Exception:
                    LOG.exception("CHAT_FAILURE_REPLY_FAILED owner=%s", speaker)
                result = ServiceResult("chat_failed", "this command failed; the chat bridge is still running")
            self.last_status, self.last_detail = result.status, result.detail
            diagnostic = {"owner": speaker, "event_id": chat.get("event_request_id"),
                          "status": result.status, "detail": result.detail,
                          "elapsed_ms": round((time.monotonic()-started)*1000)}
            self.chat_results = (self.chat_results + [diagnostic])[-16:]
            LOG.info("CHAT_RESULT owner=%s status=%s elapsed_ms=%s detail=%s",
                     speaker, result.status, diagnostic["elapsed_ms"], result.detail)
            return result

        if self.qwen is not None:
            candidates = [c for c in self._companions(state_message.fields) if self._offline_eligible(c)
                          and self._body_state(c).body_ready
                          and self.clock() >= self.next_offline_decision.get(str(c.get("npc_id")), 0)]
            if candidates:
                companion = min(candidates, key=lambda c: self.next_offline_decision.get(str(c.get("npc_id")), 0))
                result = self._handle_offline(companion)
                self.last_status, self.last_detail = result.status, result.detail
                return result

        ambient=self._ambient_tick(state_message.fields)
        if ambient is not None:
            self.last_status,self.last_detail=ambient.status,ambient.detail
            return ambient
        companion = self._companion_for_owner(state_message.fields, None)
        if companion is not None:
            self._configure_driver(companion)
            self.last_status = "npc_steady"
            self.last_detail = f"{len(self._companions(state_message.fields))} persistent Goblin companion(s) known"
        else:
            self.current_body = None
            self.current_owner = None
            self.last_status = "waiting_for_goblin"
            self.last_detail = "no persistent Goblin companions are known"
        return ServiceResult(self.last_status, self.last_detail)

    def run_forever(self, stop_event: threading.Event | None = None) -> None:
        stop_event = stop_event or threading.Event()
        next_tick = 0.0
        while not stop_event.is_set():
            # Chat latency must not inherit the five-second telemetry interval,
            # nor pay another full interval for each player already in the queue.
            if (self.pending_chats and self.config.enabled and not self.paused) or self.clock() >= next_tick:
                self.run_once()
                next_tick = self.clock() + self.config.heartbeat_seconds
            else:
                self._poll_events()
                self._poll_responses()
            stop_event.wait(0 if self.pending_chats and self.config.enabled and not self.paused else 0.25)

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
            "chat_results": [dict(result) for result in self.chat_results],
            "pending_chat_count": len(self.pending_chats),
            "selected_owner": self.current_owner,
            "selected_npc_id": self.current_body.npc_id if self.current_body else None,
            "companion_count": len(self._companions(self.last_state)),
        }

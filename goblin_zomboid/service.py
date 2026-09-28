"""Qwen orchestration for one friendly Goblin companion per connected player.

The Project Zomboid server owns bodies and deterministic gameplay.  This
process only turns addressed player chat into a short in-character reply and a
validated semantic action for that same player's Goblin.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import os
import logging
from pathlib import Path
import threading
import time
import random
import difflib
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
from .reflex import ReflexDecision, ReflexRouter, SOCIAL_CATEGORIES
from .mind import GoblinMind
from .sentience import Sentience
from .social import ChatterGovernor, sanitize_speech
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
        reflex: ReflexRouter | None = None,
    ) -> None:
        self.config = config
        # Social-only fast path. A missing or corrupt model is an outage that
        # silently falls back to Qwen; it never blocks chat or gameplay.
        self.reflex = reflex if reflex is not None else ReflexRouter()
        self.reflex_stats: dict[str, int] = {}
        # Short per-owner conversation history so Qwen holds a real dialogue.
        self.dialogue: dict[str, list[dict[str, str]]] = {}
        # Long-term memory and the free-will loop (Qwen picks Goblin's own jobs).
        self.mind = GoblinMind(Path(memory_path).with_suffix(".mind.sqlite3"), clock=clock)
        self.think_executor: ThreadPoolExecutor | None = None
        # Every Goblin thinks in its own lane: one in-flight model call per
        # Goblin (plus banter/journal lanes), all running at the same time.
        self.think_jobs: dict[str, tuple[object, dict[str, object]]] = {}
        self.think_parallel = max(1, int(os.environ.get("GOBLIN_THINK_PARALLEL", "6") or 6))
        # Free-will command request_id -> (npc_id, intent) so a refused or
        # failed command counts as a failed plan step.
        self.freewill_requests: dict[str, tuple[str, str]] = {}
        self.next_think: dict[str, float] = {}
        self.banter_until: dict[tuple[str, str], float] = {}
        self.scheduled_says: list[tuple[float, str, str]] = []  # (due, npc_id, text)
        self.journal_queue: list[tuple[str, int]] = []  # (npc_id, finished day)
        self.think_initial_delay = 15.0
        self.think_stats: dict[str, int] = {}
        self.last_think_talk: dict[str, bool] = {}
        self.recent_think_lines: dict[str, list[str]] = {}
        # Sentience: each Goblin's continuous self (goal, plan, mood, opinions).
        self.sentience = Sentience(self.mind, clock=clock)
        self.recent_reflect_says: dict[str, list[str]] = {}
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
        if self.think_executor is not None:
            self.think_executor.shutdown(wait=False, cancel_futures=True)
        self.mind.close()
        self.tracker.close()
        self.memory.close()

    @property
    def think_future(self):
        """Any in-flight background thought (compat for callers/tests)."""
        for future, _selected in self.think_jobs.values():
            return future
        return None

    def _poll_responses(self) -> None:
        now_ms = int(self.clock() * 1000)
        for response in self.response_consumer.poll(limit=32, now=now_ms):
            fields = response.message.fields
            mapped = self.freewill_requests.pop(str(response.message.request_id), None)
            status = str(fields.get("status") or "").lower()
            if mapped is not None and status in {"failed", "rejected", "refused", "error", "invalid", "denied",
                                                 "expired", "stale"}:
                npc_id, intent = mapped
                self.sentience.step_result(npc_id, intent, False)
                self.mind.record(npc_id, "job", f"{intent} failed: {str(fields.get('detail', ''))[:80]}", None,
                                 importance=0.3, valence=-0.2)
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
        reflex = self._reflex_decision(chat, companion, text, speaker)
        if reflex.route == "SOCIAL":
            self.mind.social(body.npc_id, reflex.category)
            self.sentience.social(body.npc_id, speaker, reflex.category, text)
        # A player talking to Goblin resets his free-will clock: answer first.
        self.next_think[body.npc_id] = max(self.next_think.get(body.npc_id, 0), self.clock() + 30)
        reflex_reply = None
        if reflex.route == "SOCIAL" and isinstance(reflex.reply, str):
            try:
                reflex_reply = sanitize_speech(reflex.reply)
            except ValueError:
                LOG.warning("REFLEX_REPLY_REJECTED owner=%s", speaker)
        if reflex_reply and self.qwen is None:
            # Reflex is the low-latency outage fallback. With Qwen available,
            # conversation keeps the richer combined historical persona.
            speech = self._publish_reply(chat, companion, prepared_speech=reflex_reply)
            self._remember_turn(speaker, text, speech)
            return ServiceResult("reflex_spoke" if speech else "npc_steady",
                                 f"reflex {reflex.category} in {reflex.latency_ms:.2f} ms")
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
            "conversation": list(self.dialogue.get(speaker, [])),
            "memory": self.mind.digest(body.npc_id, place=self._room(companion), entities=(speaker,)),
            "self": self.sentience.view(body.npc_id),
        })
        if reflex.route == "SOCIAL":
            context["social_hint"] = reflex.category.lower()
        speech = None
        try:
            combined = getattr(self.qwen, "propose_chat", None)
            if callable(combined):
                intent, generated_speech = combined(context)
                speech = self._publish_reply(chat, companion, prepared_speech=generated_speech)
                self._remember_turn(speaker, text, speech)
                self.mind.record(body.npc_id, "chat", f"{speaker} said: {text[:100]}"
                                 + (f" / I said: {speech[:100]}" if speech else ""),
                                 self.mind.last_day.get(body.npc_id))
            else:
                # Compatibility for older adapters; production uses one request.
                speech = self._publish_reply(chat, companion)
                intent = self.qwen.propose_intent(context)
        except QwenError as exc:
            fallback = None
            if (reflex.category in SOCIAL_CATEGORIES and reflex.confidence >= 0.5
                    and reflex.route == "FALLBACK"):
                fallback = self.reflex._reply(reflex.category, speaker)
            self._publish_reply(chat, companion, prepared_speech=fallback or
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

    def _remember_turn(self, owner: str, said: str, reply: str | None) -> None:
        history = self.dialogue.setdefault(owner, [])
        history.append({"from": "player", "text": said[:240]})
        if reply:
            history.append({"from": "goblin", "text": reply[:240]})
        del history[:-12]

    def _reflex_decision(self, chat: Mapping[str, object], companion: Mapping[str, object],
                         text: str, speaker: str) -> ReflexDecision:
        name = companion.get("name")
        try:
            decision = self.reflex.route(
                text, owner=speaker, companion_name=name if isinstance(name, str) else None,
                direct_action=chat.get("direct_action") if isinstance(chat.get("direct_action"), str) else None)
        except Exception as exc:  # a broken router is an outage, not a crash
            LOG.warning("REFLEX_FAILED detail=%s", str(exc)[:200])
            decision = ReflexDecision("FALLBACK", "OTHER", 0.0, None, "reflex raised", 0.0)
        key = decision.route if decision.route != "SOCIAL" else f"SOCIAL:{decision.category}"
        self.reflex_stats[key] = self.reflex_stats.get(key, 0) + 1
        return decision

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
                and (companion.get("task")=="FOLLOW" or companion.get("autonomous") is True)
                and companion.get("freewill") is not True)

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

    # ------------------------------------------------------------ free will
    def _observe(self, fields: Mapping[str, object]) -> None:
        """Fold each companion's situation report into long-term memory."""
        now = self.clock()
        for companion in self._companions(fields):
            npc_id = companion.get("npc_id")
            if not isinstance(npc_id, str):
                continue
            try:
                seen = self.mind.observe(companion)
                self.sentience.get(npc_id, companion.get("name") if isinstance(companion.get("name"), str) else None,
                                   companion.get("owner") if isinstance(companion.get("owner"), str) else None)
                self.sentience.perceive(companion, seen["events"])
                for event in seen["events"]:
                    if event.get("kind") == "job":
                        # Brain notes "TASK CODE: detail" for every finished job.
                        words = str(event.get("text", "")).split()
                        if len(words) >= 2:
                            self.sentience.step_result(npc_id, words[0], words[1].rstrip(":") == "COMPLETE")
            except Exception:  # memory must never take the service down
                LOG.exception("MIND_OBSERVE_FAILED npc=%s", npc_id)
                continue
            if any(e.get("kind") in ("owner_hurt", "job") for e in seen["events"]):
                # Something just changed: let Goblin react instead of waiting a full interval.
                if npc_id in self.next_think:
                    self.next_think[npc_id] = min(self.next_think[npc_id], now + 3)
            day = seen.get("new_day")
            if isinstance(day, int):
                self.mind.write_journal(npc_id, day, self.mind.fallback_journal(npc_id, day))
                if (npc_id, day) not in self.journal_queue:
                    self.journal_queue.append((npc_id, day))
                    del self.journal_queue[:-8]

    def _flush_scheduled_says(self, fields: Mapping[str, object]) -> None:
        now = self.clock()
        due = [entry for entry in self.scheduled_says if entry[0] <= now]
        if not due:
            return
        self.scheduled_says = [entry for entry in self.scheduled_says if entry[0] > now]
        by_id = {c.get("npc_id"): c for c in self._companions(fields)}
        for _, npc_id, text in sorted(due):
            companion = by_id.get(npc_id)
            if companion is None or companion.get("body_present") is not True:
                continue
            body = self._configure_driver(companion)
            if not body.body_ready:
                continue
            self.npc_driver.execute(SafeAction(Action.SAY, 1, "goblin banter", text=text, npc_id=body.npc_id),
                                    owner=companion.get("owner"))

    @staticmethod
    def _social_ready(companion: Mapping[str, object]) -> bool:
        return (companion.get("owner_online") is True and companion.get("body_present") is True
                and companion.get("control_ready") is True and companion.get("npc_engine_ready") is True
                and not companion.get("riding") and not companion.get("transport_active")
                and companion.get("combat_state", "NONE") == "NONE")

    @classmethod
    def _think_eligible(cls, companion: Mapping[str, object]) -> bool:
        idle = companion.get("owner_idle_seconds", 0)
        return (cls._social_ready(companion) and companion.get("freewill") is True
                and (companion.get("task") == "FOLLOW" or companion.get("autonomous") is True)
                and isinstance(idle, (int, float)) and math.isfinite(idle) and idle >= 10
                and isinstance(companion.get("companion_authority_token"), str))

    @staticmethod
    def _room(companion: Mapping[str, object]) -> str | None:
        situation = companion.get("situation")
        place = situation.get("place") if isinstance(situation, Mapping) else None
        room = place.get("room") if isinstance(place, Mapping) else None
        return room if isinstance(room, str) else None

    @staticmethod
    def _cognition_ready(companion: Mapping[str, object]) -> bool:
        """Thinking needs only a present body and an online owner; unlike
        physical free will it also runs while following a moving owner."""
        return (companion.get("owner_online") is True and companion.get("body_present") is True
                and isinstance(companion.get("npc_id"), str) and isinstance(companion.get("situation"), Mapping))

    def _reflect_candidate(self, companions, *, urgent: bool):
        now = self.clock()
        best = None
        for companion in companions:
            if not self._cognition_ready(companion) or companion.get("freewill") is not True:
                continue
            npc_id = str(companion["npc_id"])
            wants, priority = self.sentience.wants_reflection(npc_id, now)
            if not wants or (urgent and priority < 0.5) or (not urgent and priority >= 0.5):
                continue
            if best is None or priority > best[1]:
                best = (companion, priority)
        return best

    def _submit_reflect(self, companion: Mapping[str, object], priority: float) -> None:
        npc_id = str(companion["npc_id"])
        owner = companion.get("owner")
        view = brain_view(companion)
        situation = view.pop("situation", None)
        context = {"controlled_npc_id": npc_id, "controlled_owner": owner, "companion": view,
                   "situation": situation,
                   "memory": self.mind.digest(npc_id, place=self._room(companion),
                                              entities=(owner,) if isinstance(owner, str) else ()),
                   "conversation": list(self.dialogue.get(str(owner), []))[-6:],
                   **self.sentience.reflection_context(npc_id)}
        # Claim the slot now so a slow model call is not submitted twice.
        self.sentience.get(npc_id)["last_reflect_at"] = self.clock()
        self._submit_think("reflect", {"npc_id": npc_id, "owner": owner, "priority": priority},
                           "propose_reflect", context)

    def _background_qwen(self):
        clone = getattr(self.qwen, "background", None)
        return clone() if callable(clone) else self.qwen

    def _submit_think(self, kind: str, selected: dict[str, object], method: str, context: dict) -> None:
        client = self._background_qwen()
        if kind == "reflect":
            # A reflection writes more (goal, plan, opinions) than one action.
            clone = getattr(self.qwen, "background", None)
            if callable(clone):
                try:
                    client = clone(timeout_seconds=40.0)
                except TypeError:
                    client = clone()
        if self.think_executor is None:
            self.think_executor = ThreadPoolExecutor(max_workers=self.think_parallel,
                                                     thread_name_prefix="goblin-think")
        lane = self._lane(kind, selected)
        self.think_jobs[lane] = (self.think_executor.submit(getattr(client, method), context),
                                 dict(selected, kind=kind))

    @staticmethod
    def _lane(kind: str, selected: Mapping[str, object]) -> str:
        if kind in {"think", "reflect"}:
            return f"npc:{selected.get('npc_id')}"
        return kind

    def _lane_free(self, lane: str) -> bool:
        return lane not in self.think_jobs and len(self.think_jobs) < self.think_parallel

    def _count(self, key: str) -> None:
        self.think_stats[key] = self.think_stats.get(key, 0) + 1

    def _think_tick(self, fields: Mapping[str, object]) -> ServiceResult | None:
        outcome: ServiceResult | None = None
        finished: set[str] = set()
        for lane, (future, selected) in list(self.think_jobs.items()):
            if not future.done():
                continue
            del self.think_jobs[lane]
            finished.add(lane)
            try:
                value = future.result()
            except Exception as exc:
                self._count(f"{selected.get('kind')}_failed")
                LOG.warning("THINK_FAILED kind=%s npc=%s detail=%s", selected.get("kind"),
                            selected.get("npc_id"), str(exc)[:200])
                continue
            handler = {"think": self._finish_think, "banter": self._finish_banter,
                       "journal": self._finish_journal,
                       "reflect": self._finish_reflect}.get(str(selected.get("kind")))
            result = handler(fields, selected, value) if handler else None
            if result is not None:
                outcome = result
        if finished or self.qwen is None or self.pending_chats:
            # A lane that just finished starts its next thought on the next tick.
            return outcome
        self._start_thoughts(fields)
        return outcome

    def _start_thoughts(self, fields: Mapping[str, object]) -> None:
        now = self.clock()
        companions = self._companions(fields)
        reflects = callable(getattr(self.qwen, "propose_reflect", None))
        if reflects:
            # Something important just happened: think about it before anything else.
            while True:
                pool = [c for c in companions if self._lane_free(f"npc:{c.get('npc_id')}")]
                urgent = self._reflect_candidate(pool, urgent=True)
                if urgent is None:
                    break
                self._submit_reflect(*urgent)
        if (self.journal_queue and self._lane_free("journal")
                and callable(getattr(self.qwen, "propose_journal", None))):
            npc_id, day = self.journal_queue.pop(0)
            context = {"day": day, "events": self.mind.episodes(npc_id, 20, day=day),
                       "memory": {"trust_in_owner": self.mind.digest(npc_id)["trust_in_owner"],
                                  "remembered_places": self.mind.places(npc_id)}}
            self._submit_think("journal", {"npc_id": npc_id, "day": day}, "propose_journal", context)
        eligible = [c for c in companions if self._think_eligible(c) and isinstance(c.get("npc_id"), str)]
        # Meetups are rare (10 min per pair) and time-sensitive: they go before
        # the next think turn, which would otherwise always be due.
        if self._lane_free("banter") and callable(getattr(self.qwen, "propose_banter", None)):
            pair = self._banter_pair(companions, now)
            if pair is not None:
                goblins = []
                for companion in pair:
                    view = brain_view(companion)
                    situation = view.get("situation") if isinstance(view.get("situation"), Mapping) else {}
                    digest = self.mind.digest(str(companion["npc_id"]))
                    goblins.append({"name": companion.get("name"), "owner": companion.get("owner"),
                                    "task": companion.get("task"),
                                    "situation": {k: situation.get(k) for k in ("time", "weather", "threats",
                                                  "base", "place") if k in situation},
                                    "memory": {"trust_in_owner": digest["trust_in_owner"],
                                               "recent_memories": digest["recent_memories"][-5:]}})
                self._submit_think("banter", {"pair": [(c.get("npc_id"), c.get("name")) for c in pair]},
                                   "propose_banter", {"goblins": goblins})
        if callable(getattr(self.qwen, "propose_think", None)):
            interval = 40.0
            for companion in eligible:
                self.next_think.setdefault(str(companion["npc_id"]), now + self.think_initial_delay)
            due = sorted((c for c in eligible if now >= self.next_think[str(c["npc_id"])]
                          and self._lane_free(f"npc:{c['npc_id']}")),
                         key=lambda c: self.next_think[str(c["npc_id"])])
            for companion in due:
                if not self._lane_free(f"npc:{companion['npc_id']}"):
                    break
                npc_id = str(companion["npc_id"])
                self.next_think[npc_id] = now + interval
                body = self._configure_driver(companion)
                owner = companion.get("owner")
                view = brain_view(companion)
                situation = view.pop("situation", None)
                context = {"mode": body.mode, "controlled_npc_id": npc_id, "controlled_owner": owner,
                           "event": {"type": "free_will",
                                     "interrupted": companion.get("freewill_interrupted"),
                                     "last_turn_was_talk": self.last_think_talk.get(npc_id, False),
                                     "your_recent_lines": list(self.recent_think_lines.get(npc_id, []))},
                           "companion": view, "situation": situation,
                           "memory": self.mind.digest(npc_id, place=self._room(companion),
                                                      entities=(owner,) if isinstance(owner, str) else ()),
                           "sentience": self.sentience.view(npc_id),
                           "conversation": list(self.dialogue.get(str(owner), [])),
                           "persistent_goblins": self._roster_context()}
                self._submit_think("think", {"npc_id": npc_id, "owner": owner}, "propose_think", context)
        if reflects:
            # Quiet moment: slow background reflection (also while following).
            while True:
                pool = [c for c in companions if self._lane_free(f"npc:{c.get('npc_id')}")]
                background = self._reflect_candidate(pool, urgent=False)
                if background is None:
                    break
                self._submit_reflect(*background)

    def _banter_pair(self, companions: list[Mapping[str, object]], now: float):
        ready = {c.get("npc_id"): c for c in companions if self._social_ready(c)
                 and isinstance(c.get("npc_id"), str) and isinstance(c.get("name"), str)}
        for npc_id, companion in ready.items():
            situation = companion.get("situation")
            nearby = situation.get("nearby_goblins") if isinstance(situation, Mapping) else None
            for other in nearby if isinstance(nearby, list) else []:
                other_id = other.get("npc_id") if isinstance(other, Mapping) else None
                if other_id not in ready or other_id == npc_id:
                    continue
                if ready[other_id].get("owner") == companion.get("owner"):
                    continue
                key = tuple(sorted((npc_id, other_id)))
                if now < self.banter_until.get(key, 0):
                    continue
                self.banter_until[key] = now + 600
                if not self.chatter.allow(f"banter:{key[0]}:{key[1]}", now=int(now), priority=1).allowed:
                    continue
                return companion, ready[other_id]
        return None

    def _finish_think(self, fields, selected, value) -> ServiceResult | None:
        intent, speech = value
        owner, npc_id = selected.get("owner"), selected.get("npc_id")
        latest = self._companion_for_owner(fields, owner if isinstance(owner, str) else None)
        if (latest is None or latest.get("npc_id") != npc_id or self.pending_chats
                or not self._think_eligible(latest)):
            self._count("think_dropped")
            return ServiceResult("think_cancelled", "owner gave an order or the situation changed")
        body = self._configure_driver(latest)
        decision = self.safety.decide(intent, body)
        if not decision.accepted or decision.action is None:
            self._count("think_rejected")
            return ServiceResult("controller_rejected", decision.reason)
        now = self.clock()
        spoken = None
        recent = self.recent_think_lines.setdefault(str(npc_id), [])
        if speech and any(difflib.SequenceMatcher(None, speech.lower(), old.lower()).ratio() >= 0.55
                          for old in recent):
            self._count("think_repeat_dropped")
            speech = None  # a rerun of an earlier line: act silently instead
        if speech and self.chatter.record(f"think:{npc_id}:{int(now)}", "game", speech,
                                          now=int(now), priority=2).allowed:
            result = self.npc_driver.execute(SafeAction(Action.SAY, 2, "free-will narration", text=speech,
                                                        npc_id=body.npc_id), owner=owner)
            spoken = speech if result.accepted else None
        if spoken:
            recent.append(spoken[:240])
            del recent[:-5]
        if spoken and isinstance(owner, str):
            history = self.dialogue.setdefault(owner, [])
            history.append({"from": "goblin", "text": spoken[:240]})
            del history[:-12]
        day = self.mind.last_day.get(str(npc_id))
        action = decision.action.action
        if action is Action.FOLLOW and latest.get("task") == "FOLLOW":
            # "Keep following" while already following is not a choice; treat
            # it as a talk turn so the next turn is pushed toward real work.
            self._count("think_follow_noop")
            action = Action.SAY
        step = self.sentience.current_step(str(npc_id))
        if step is not None and step.get("intent") in ("SAY", "FOLLOW") and action in (Action.SAY, Action.FOLLOW):
            self.sentience.step_result(str(npc_id), step["intent"], True)
        if action is Action.SAY:
            self.mind.record(str(npc_id), "thought", spoken or "kept quiet", day)
            self._count("think_spoke")
            self.last_think_talk[str(npc_id)] = True
            # Talking is cheap; give the next decision (which must be a job) more room.
            self.next_think[str(npc_id)] = max(self.next_think.get(str(npc_id), 0), now + 90)
            LOG.info("FREEWILL_TALK owner=%s spoke=%s", owner, bool(spoken))
            return ServiceResult("think_spoke" if spoken else "npc_steady", "Goblin spoke up on his own")
        step = self.sentience.current_step(str(npc_id))
        if step and step.get("intent") not in {action.value, "SAY", "FOLLOW"}:
            # He chose something else over his planned step: two strikes and the
            # step is dropped, so a plan never pins him to an impossible step.
            self.sentience.step_result(str(npc_id), str(step.get("intent")), False)
        result = self.npc_driver.execute(decision.action, owner=owner, freewill=True,
                                         authority_token=latest.get("companion_authority_token"))
        self.last_action = decision.action.as_dict()
        self.last_think_talk[str(npc_id)] = False
        self.mind.record(str(npc_id), "choice", f"decided to {action.value}" + (f": {spoken}" if spoken else ""), day)
        self._count("think_acted" if result.accepted else "think_refused")
        if result.accepted and result.detail:
            self.freewill_requests[str(result.detail)] = (str(npc_id), action.value)
            if len(self.freewill_requests) > 256:
                self.freewill_requests.pop(next(iter(self.freewill_requests)))
        LOG.info("FREEWILL_ACTION owner=%s action=%s status=%s detail=%s", owner, action.value,
                 result.status, str(result.detail)[:160])
        return ServiceResult("freewill_command_published" if result.accepted else result.status,
                             f"{owner}'s Goblin chose {action.value} on his own", result.detail)

    def _finish_reflect(self, fields, selected, value) -> ServiceResult | None:
        npc_id, owner = str(selected.get("npc_id")), selected.get("owner")
        if not isinstance(value, Mapping):
            self._count("reflect_failed")
            return None
        outcome = self.sentience.apply_reflection(npc_id, value)
        self._count("reflect")
        state = self.sentience.get(npc_id)
        goal = state.get("current_goal") or {}
        LOG.info("SENTIENCE owner=%s decision=%s mood=%s goal=%s step=%s", owner, outcome["decision"],
                 state.get("mood"), goal.get("goal") if isinstance(goal, Mapping) else None,
                 (self.sentience.current_step(npc_id) or {}).get("intent"))
        now = self.clock()
        if outcome["decision"] in ("new", "interrupt") and npc_id in self.next_think:
            # A fresh plan: start on it at the next physical opportunity.
            self.next_think[npc_id] = min(self.next_think[npc_id], now + 2)
        say = outcome.get("say")
        spoken = None
        # Most thoughts stay private; speak when it matters, or now and then.
        if say and (outcome["importance"] >= 0.6 or random.random() < 0.3):
            recent = self.recent_reflect_says.setdefault(npc_id, [])
            recent_all = recent + list(self.recent_think_lines.get(npc_id, []))
            repeat = any(difflib.SequenceMatcher(None, say.lower(), old.lower()).ratio() >= 0.55
                         for old in recent_all)
            latest = self._companion_for_owner(fields, owner if isinstance(owner, str) else None)
            if (not repeat and latest is not None and latest.get("npc_id") == npc_id
                    and self._social_ready(latest) and not self.pending_chats
                    and self.chatter.record(f"reflect:{npc_id}:{int(now)}", "game", say, now=int(now),
                                            priority=2 if outcome["importance"] >= 0.6 else 1).allowed):
                body = self._configure_driver(latest)
                result = self.npc_driver.execute(SafeAction(Action.SAY, 2, "sentience remark", text=say,
                                                            npc_id=body.npc_id), owner=owner)
                if result.accepted:
                    spoken = say
                    recent.append(say[:240])
                    del recent[:-5]
                    if isinstance(owner, str):
                        history = self.dialogue.setdefault(owner, [])
                        history.append({"from": "goblin", "text": say[:240]})
                        del history[:-12]
        self._count("reflect_spoke" if spoken else "reflect_silent")
        return ServiceResult("sentience_spoke" if spoken else "sentience_thought",
                             f"{owner}'s Goblin thought: {outcome['decision']}")

    def _finish_banter(self, fields, selected, lines) -> ServiceResult | None:
        by_name = {name: npc for npc, name in selected.get("pair", [])}
        now = self.clock()
        spoken = []
        for index, line in enumerate(lines or []):
            npc_id = by_name.get(line.get("speaker"))
            if npc_id is None:
                continue
            self.scheduled_says.append((now + index * 4.0, npc_id, line["text"]))
            spoken.append(line)
        names = list(by_name)
        for npc, name in selected.get("pair", []):
            other = next((n for n in names if n != name), "another goblin")
            said = "; ".join(f"{l['speaker']}: {l['text']}" for l in spoken)[:220]
            self.mind.record(npc, "met", f"talked with {other}. {said}")
        self._count("banter")
        self._flush_scheduled_says(fields)
        return ServiceResult("banter_scheduled", f"{len(spoken)} line(s) between {' and '.join(names)}")

    def _finish_journal(self, fields, selected, text) -> ServiceResult | None:
        try:
            text = sanitize_speech(text) if len(text) <= 180 else str(text).strip()[:400]
        except ValueError:
            return None
        self.mind.write_journal(str(selected["npc_id"]), int(selected["day"]), text)
        self._count("journal")
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
        self._observe(state_message.fields)
        self._flush_scheduled_says(state_message.fields)

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

        thought = self._think_tick(state_message.fields)
        if thought is not None:
            self.last_status, self.last_detail = thought.status, thought.detail
            return thought
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
            "reflex": {"available": self.reflex.available, "error": self.reflex.error,
                       "routes": dict(self.reflex_stats)},
            "free_will": {"stats": dict(self.think_stats), "busy": bool(self.think_jobs),
                          "in_flight": sorted(self.think_jobs),
                          "scheduled_lines": len(self.scheduled_says)},
            "sentience": self.sentience.snapshot(),
        }

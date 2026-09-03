"""Safe orchestration for the disabled-first Goblin service."""

from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

from .agent import AgentRuntime, AgentStatus
from .character import (
    CharacterCreationController,
    CharacterError,
    CharacterLifecycle,
    VanillaCatalog,
)
from .config import AgentConfig
from .controllers import BodyState, SafetyController
from .events import EventGate
from .hunt import HuntManager
from .ipc import EventConsumer, RequestLedger, ResponseConsumer
from .memory import MemoryStore
from .modes import Mode, ModeController
from .mods import ModParityValidator
from .party import PartyManager
from .qwen import QwenClient, QwenError
from .protocol import Message, new_request_id, make_message
from .social import ChatterGovernor
from .state import brain_view, public_view
from .validator import IntentValidator, IntentError


@dataclass(frozen=True)
class ServiceResult:
    status: str
    detail: str
    request_id: str | None = None


_CATALOG_META_NAME = "zomboid-catalog-meta"
_CATALOG_CHUNK_PREFIX = "zomboid-catalog-"
_MAX_CATALOG_CHUNKS = 1024
_MAX_CATALOG_OPTIONS = 32_768


class GoblinService:
    """Coordinates model proposals while preserving deterministic execution gates."""

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
        self.last_events: list[dict[str, object]] = []
        self.last_response: dict[str, object] | None = None
        self.event_overlay: dict[str, object] = {}
        self.current_body: BodyState | None = None
        record = self.memory.character_record()
        lifecycle = CharacterLifecycle.FRESH
        manifest = None
        self.character_storage_error: str | None = None
        if record is not None:
            manifest = record.get("manifest")
            if record.get("manifest_error"):
                self.character_storage_error = (
                    "durable character manifest is unreadable; recreation is disabled"
                )
            try:
                lifecycle = CharacterLifecycle(record.get("lifecycle"))
            except (TypeError, ValueError):
                # A corrupt lifecycle must never trigger an appearance reset.
                self.character_storage_error = (
                    "durable character lifecycle is invalid; recreation is disabled"
                )
                lifecycle = (
                    CharacterLifecycle.ACTIVE
                    if manifest is not None
                    else CharacterLifecycle.FRESH
                )
            if lifecycle == CharacterLifecycle.FRESH and manifest is not None:
                self.character_storage_error = (
                    "fresh lifecycle has an existing appearance manifest; recreation is disabled"
                )
        self.character = CharacterCreationController(
            lifecycle=lifecycle,
            manifest=manifest,
            persist=self._persist_character,
        )
        self.character_sync_error: str | None = None
        # Keep the safe default for staged installs, while allowing an
        # explicitly approved enabled deployment to survive service restarts
        # without requiring an unauthenticated control call.
        self.paused = config.start_paused
        self.last_status = "starting"
        self.last_detail = ""
        self.last_action: dict[str, object] | None = None
        self.last_state: dict[str, object] = {}
        self.last_character_command_at = 0.0
        self.last_recreation_command_at = 0.0

    def close(self) -> None:
        self.memory.close()

    def _persist_character(
        self,
        lifecycle: CharacterLifecycle,
        manifest: dict[str, Any] | None,
    ) -> None:
        self.memory.save_character_state(
            lifecycle.value,
            manifest,
            updated_at=int(self.clock()),
        )

    def _poll_responses(self) -> None:
        """Consume PZ acknowledgements/results without making them commands."""

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
                        "command_response",
                        detail or status,
                        subject=response.message.request_id,
                        metadata={"status": status},
                        created_at=response.message.timestamp_ms // 1000,
                    )
                except ValueError:
                    # A response is already bounded by the bridge consumer;
                    # a storage failure must not stop the control loop.
                    pass
            try:
                self.response_consumer.finalize(response, detail="response consumed")
            except OSError:
                pass

    def _apply_event(self, kind: str, fields: Mapping[str, object], timestamp_ms: int) -> None:
        """Record a validated coarse event and update only derived state."""

        created_at = timestamp_ms // 1000
        subject_value = fields.get("player") or fields.get("speaker") or ""
        subject = subject_value if isinstance(subject_value, str) else ""
        content = kind.replace("_", " ")
        if subject:
            content = f"{content}: {subject}"
        text = fields.get("text")
        if isinstance(text, str):
            content = f"{content} — {text}"
        try:
            self.memory.record_memory(
                f"event.{kind}",
                content[:4000],
                subject=subject,
                metadata=dict(fields),
                created_at=created_at,
            )
        except ValueError:
            pass

        if subject and kind in {"player_joined", "player_left", "goblin_spotted", "chat"}:
            relationship = self.memory.relationship(subject) or {
                "trust": 0.5,
                "fear": 0.0,
                "affinity": 0.0,
                "tags": [],
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
                    subject,
                    trust=trust,
                    fear=fear,
                    affinity=affinity,
                    tags=list(relationship.get("tags", [])),
                    last_seen=created_at,
                )
            except (TypeError, ValueError):
                pass

        if kind == "threat_changed":
            threat = fields.get("threat_level")
            if isinstance(threat, str):
                self.event_overlay["threat_level"] = threat
        elif kind == "injury":
            severity = fields.get("severity")
            if severity == "critical":
                self.event_overlay["injury"] = 1.0
            elif severity == "moderate":
                self.event_overlay["injury"] = 0.6
            elif severity == "minor":
                self.event_overlay["injury"] = 0.25
        elif kind == "death":
            self.mode_controller.transition(
                Mode.SAFE, emergency=True, now=created_at
            )
            self.event_overlay["alive"] = False

        event_record = {
            "kind": kind,
            "timestamp_ms": timestamp_ms,
            "fields": dict(fields),
        }
        self.last_events.append(event_record)
        self.last_events = self.last_events[-32:]

    def _reply_to_chat(
        self,
        fields: Mapping[str, object],
        *,
        event_request_id: str,
    ) -> None:
        """Reply only to an addressed player, through the normal intent gate."""

        if self.paused:
            return
        body = self.current_body
        if body is None:
            state = self._read_state()
            if state is not None:
                body = self._body_state(state.fields)
        if body is None or not body.body_ready or self.event_overlay.get("alive") is False:
            return
        text = fields.get("text")
        speaker = fields.get("speaker")
        if not isinstance(text, str) or not isinstance(speaker, str):
            return
        folded = text.casefold()
        if "goblin" not in folded and not folded.startswith("!goblin"):
            return
        propose_speech = getattr(self.qwen, "propose_speech", None)
        if not callable(propose_speech):
            return
        relationship = self.memory.relationship(speaker)
        context = {
            "event": {"speaker": speaker, "text": text},
            "mode": body.mode,
            "threat_level": body.threat_level,
            "hunger": body.hunger,
            "thirst": body.thirst,
            "injury": body.injury,
            "relationship": relationship or {},
            "recent_memories": self.memory.recent_memories(8),
        }
        try:
            speech = propose_speech(context)
            intent = IntentValidator().validate(
                {
                    "intent": "SAY",
                    "mode": body.mode,
                    "text": speech,
                    "priority": 2,
                }
            )
        except (IntentError, QwenError, TypeError, ValueError):
            return
        decision = self.safety.decide(intent, body)
        if not decision.accepted or decision.action is None:
            return
        chatter = self.chatter.record(
            f"reply:{event_request_id}",
            "game",
            speech,
            now=int(self.clock()),
            priority=2,
        )
        if not chatter.allowed:
            return
        request_id = new_request_id("speech")
        command = make_message(
            "command.intent",
            request_id=request_id,
            intent="SAY",
            mode=body.mode,
            text=speech,
            priority=2,
            controller_action=decision.action.as_dict(),
        )
        try:
            self.store.publish("commands", command, stem=request_id)
        except (FileExistsError, OSError, ValueError):
            return
        self.last_action = decision.action.as_dict()
        self.last_status = "speech_command_published"
        self.last_detail = "addressed chat reply passed deterministic speech gate"


    def _poll_events(self) -> None:
        """Validate, apply, and archive a bounded batch of bridge events."""

        now_ms = int(self.clock() * 1000)
        for event in self.event_consumer.poll(limit=32, now=now_ms):
            suffix = event.message.type.removeprefix("event.")
            decision = self.event_gate.make(
                suffix,
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
            self._apply_event(
                suffix,
                decision.message.fields,
                event.message.timestamp_ms,
            )
            if suffix == "chat":
                self._reply_to_chat(
                    decision.message.fields,
                    event_request_id=event.message.request_id,
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

    @staticmethod
    def _number(fields: dict[str, object], key: str, default: float = 0.0) -> float:
        value = fields.get(key, default)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return default
        if not math.isfinite(float(value)):
            return default
        return min(1.0, max(0.0, float(value)))

    @classmethod
    def _body_state(cls, fields: dict[str, object]) -> BodyState:
        threat = fields.get("threat_level", "none")
        threat = threat if threat in {"none", "near", "overwhelming"} else "none"
        mode = fields.get("mode", "SAFE")
        mode = mode if mode in {"SAFE", "ROAM", "PARTY", "HUNT"} else "SAFE"
        mod_parity = ModParityValidator.from_runtime(fields).status
        client_control_ready = (
            fields.get("client_control_ready") is True
            and ModParityValidator.control_compatible_from_runtime(fields)
        )
        return BodyState(
            alive=bool(fields.get("alive", True)),
            body_present=bool(fields.get("body_present", False)),
            hunger=cls._number(fields, "hunger"),
            thirst=cls._number(fields, "thirst"),
            fatigue=cls._number(fields, "fatigue"),
            panic=cls._number(fields, "panic"),
            injury=cls._number(fields, "injury"),
            threat_level=threat,
            weapon_ready=bool(fields.get("weapon_ready", False)),
            has_food=bool(fields.get("has_food", False)),
            has_water=bool(fields.get("has_water", False)),
            has_medical=bool(fields.get("has_medical", False)),
            mode=mode,
            client_mod_parity=mod_parity,
            client_control_ready=client_control_ready,
        )

    def _read_character_catalog(
        self,
        fields: Mapping[str, object],
    ) -> dict[str, object] | None:
        """Reassemble the PZ catalog only from one fresh, complete epoch."""

        version = fields.get("client_catalog_version")
        if not isinstance(version, str) or not version:
            return None
        now_ms = int(self.clock() * 1000)
        max_age_ms = int(self.config.pz_timeout_seconds * 1000)
        try:
            meta = self.store.read_runtime(
                _CATALOG_META_NAME,
                max_age_ms=max_age_ms,
                now=now_ms,
            )
        except (FileNotFoundError, OSError, ValueError):
            return None
        if meta.type != "state.catalog_meta":
            return None
        meta_fields = meta.fields
        if (
            meta_fields.get("status") != "ready"
            or meta_fields.get("catalog_version") != version
            or not isinstance(meta_fields.get("catalog_epoch"), str)
        ):
            return None
        epoch = meta_fields["catalog_epoch"]
        chunk_count = meta_fields.get("chunk_count")
        if (
            not isinstance(chunk_count, int)
            or isinstance(chunk_count, bool)
            or not 1 <= chunk_count <= _MAX_CATALOG_CHUNKS
        ):
            return None

        options: dict[str, list[Any]] = {}
        total_options = 0
        for index in range(1, chunk_count + 1):
            name = f"{_CATALOG_CHUNK_PREFIX}{index:04d}"
            try:
                chunk = self.store.read_runtime(
                    name,
                    max_age_ms=max_age_ms,
                    now=now_ms,
                )
            except (FileNotFoundError, OSError, ValueError):
                return None
            chunk_fields = chunk.fields
            chunk_index = chunk_fields.get("chunk_index")
            if (
                chunk.type != "state.catalog_chunk"
                or chunk_fields.get("catalog_version") != version
                or chunk_fields.get("catalog_epoch") != epoch
                or chunk_fields.get("chunk_count") != chunk_count
                or chunk_index != index
                or not isinstance(chunk_fields.get("options"), Mapping)
            ):
                return None
            chunk_options = chunk_fields["options"]
            for category, values in chunk_options.items():
                if not isinstance(category, str) or not isinstance(values, list):
                    return None
                total_options += len(values)
                if total_options > _MAX_CATALOG_OPTIONS:
                    return None
                options.setdefault(category, []).extend(values)
        if not options:
            return None
        return {"version": version, "options": options}

    def _sync_character(self, fields: dict[str, object]) -> None:
        self.character_sync_error = None
        remote_state = fields.get("character_state")
        if not isinstance(remote_state, str):
            return
        if remote_state == CharacterLifecycle.ACTIVE.value:
            remote_generation = fields.get("character_generation")
            if self.character.lifecycle == CharacterLifecycle.CREATION_PENDING:
                if (
                    isinstance(remote_generation, int)
                    and not isinstance(remote_generation, bool)
                    and self.character.confirm_creation(remote_generation)
                ):
                    return
                self.character_sync_error = "PZ active state has no matching pending generation"
            elif self.character.lifecycle == CharacterLifecycle.RECREATE_REQUIRED:
                # The native fallback creates a vanilla character locally when
                # the post-death UI cannot return a complete option catalog.
                # Accept only the one durable next generation and only after
                # PZ reports an alive replacement.
                if (
                    fields.get("alive") is True
                    and isinstance(remote_generation, int)
                    and not isinstance(remote_generation, bool)
                    and self.character.complete_native_recreation(
                        remote_generation,
                        now=int(self.clock()),
                    )
                ):
                    return
                if (
                    isinstance(remote_generation, int)
                    and remote_generation != self.character.next_generation()
                    and remote_generation
                    != int((self.character.manifest or {}).get("generation", 0))
                ):
                    self.character_sync_error = (
                        "PZ active state has an unexpected recreation generation"
                    )
            elif self.character.lifecycle == CharacterLifecycle.DEAD:
                # An active packet after a durable death is a stale body, not
                # proof that the old character survived.  Move to the explicit
                # recreation boundary so run_once() can ask the native client
                # to open vanilla character creation and never control this
                # old body again.
                self.character.on_death(character_deleted=True)
            elif self.character.lifecycle == CharacterLifecycle.FRESH:
                if (
                    isinstance(remote_generation, int)
                    and not isinstance(remote_generation, bool)
                    and remote_generation == 0
                    and fields.get("body_present") is True
                    and fields.get("alive") is True
                    and self._body_state(fields).body_ready
                    and self.character.adopt_existing(now=int(self.clock()))
                ):
                    return
                self.character_sync_error = (
                    "PZ reports an existing character but the local appearance manifest is missing"
                )
        elif remote_state == CharacterLifecycle.DEAD.value:
            self.character.on_death(
                character_deleted=fields.get("character_deleted") is True
            )
        elif remote_state == CharacterLifecycle.RECREATE_REQUIRED.value:
            self.character.mark_character_deleted()

    def _start_character_creation(
        self,
        fields: dict[str, object],
    ) -> ServiceResult:
        if self.character_storage_error is not None:
            self.last_status = "character_storage_error"
            self.last_detail = self.character_storage_error
            return ServiceResult(self.last_status, self.last_detail)
        if self.character.lifecycle not in {
            CharacterLifecycle.FRESH,
            CharacterLifecycle.RECREATE_REQUIRED,
        }:
            return ServiceResult(
                "character_creation_pending",
                "waiting for PZ to confirm the deterministic character creation",
            )
        raw_catalog = fields.get("character_catalog")
        if raw_catalog is None:
            self.last_status = "waiting_for_character_catalog"
            self.last_detail = "PZ has not supplied a vanilla character catalog"
            return ServiceResult(self.last_status, self.last_detail)
        try:
            catalog = VanillaCatalog.from_mapping(raw_catalog)
        except CharacterError as exc:
            self.last_status = "character_catalog_rejected"
            self.last_detail = str(exc)
            return ServiceResult(self.last_status, self.last_detail)
        choose_character = getattr(self.qwen, "choose_character", None)
        if not callable(choose_character):
            self.last_status = "character_brain_unavailable"
            self.last_detail = "Qwen adapter has no vanilla character chooser"
            return ServiceResult(self.last_status, self.last_detail)
        try:
            proposal = choose_character(catalog, fields)
            result = self.character.create(
                proposal,
                catalog,
                now=int(self.clock()),
            )
        except (CharacterError, QwenError) as exc:
            self.last_status = "character_creation_rejected"
            self.last_detail = str(exc)
            return ServiceResult(self.last_status, self.last_detail)
        if not result.accepted or result.action is None:
            self.last_status = "character_creation_rejected"
            self.last_detail = result.reason
            return ServiceResult(self.last_status, self.last_detail)
        return self._publish_character_action(result.action, result.reason)

    def _publish_character_action(
        self,
        action: Any,
        reason: str,
    ) -> ServiceResult:
        request_id = new_request_id("character")
        command = make_message(
            "command.character_create",
            request_id=request_id,
            generation=action.generation,
            catalog_version=action.catalog_version,
            proposal=action.proposal.as_dict(),
        )
        try:
            self.store.publish("commands", command, stem=request_id)
        except (FileExistsError, OSError, ValueError) as exc:
            self.last_status = "character_command_failed"
            self.last_detail = f"character command was not published: {type(exc).__name__}"
            return ServiceResult(self.last_status, self.last_detail)
        self.last_character_command_at = self.clock()
        self.last_action = action.as_dict()
        self.last_status = "character_command_published"
        self.last_detail = reason
        return ServiceResult(self.last_status, self.last_detail, request_id)

    def _publish_character_recreation(self) -> ServiceResult:
        """Ask the server to open vanilla creation for a stale/dead body."""

        request_id = new_request_id("recreate")
        command = make_message(
            "command.character_recreate",
            request_id=request_id,
            generation=self.character.next_generation(),
        )
        try:
            self.store.publish("commands", command, stem=request_id)
        except (FileExistsError, OSError, ValueError) as exc:
            self.last_status = "character_recreation_failed"
            self.last_detail = (
                f"character recreation request was not published: {type(exc).__name__}"
            )
            return ServiceResult(self.last_status, self.last_detail)
        self.last_recreation_command_at = self.clock()
        self.last_action = {
            "action": "RECREATE_CHARACTER",
            "reason": "durable death boundary requires a new vanilla character",
        }
        self.last_status = "character_recreation_requested"
        self.last_detail = "asking the native client to enter vanilla character creation"
        return ServiceResult(self.last_status, self.last_detail, request_id)

    def run_once(self) -> ServiceResult:
        agent_status: AgentStatus = self.agent.run_once()
        if not self.config.enabled:
            self.last_status = "disabled"
            self.last_detail = "master feature flag is false"
            return ServiceResult(self.last_status, self.last_detail)
        # Events and responses are useful even while paused: they establish
        # durable context and keep the next decision grounded in what the
        # player actually observed. They never publish gameplay commands on
        # their own.
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
        if "character_catalog" not in state_message.fields:
            catalog = self._read_character_catalog(state_message.fields)
            if catalog is not None:
                state_fields = dict(state_message.fields)
                state_fields["character_catalog"] = catalog
                state_message = Message(
                    state_message.protocol,
                    state_message.request_id,
                    state_message.timestamp_ms,
                    state_message.type,
                    state_fields,
                )
        self.last_state = brain_view(state_message.fields)
        body = self._body_state(state_message.fields)
        self.current_body = body
        # An event may arrive between two five-second state snapshots. Keep
        # only the derived coarse overlay; exact world data is rejected before
        # it reaches this process.
        self.last_state.update(self.event_overlay)
        self.last_state["client_mod_parity"] = body.client_mod_parity
        self.last_state["client_control_ready"] = body.client_control_ready
        self._sync_character(state_message.fields)
        if self.character_sync_error is not None:
            self.last_status = "character_state_mismatch"
            self.last_detail = self.character_sync_error
            return ServiceResult(self.last_status, self.last_detail)
        if self.character.lifecycle == CharacterLifecycle.RECREATE_REQUIRED:
            # Prefer the full catalog/Qwen path when it is available. If the
            # dead-body UI cannot publish a catalog, ask the native client to
            # complete a vanilla default character instead. This check must
            # not require body_present: the whole point is to recreate after
            # that body has disappeared.
            if "character_catalog" not in state_message.fields:
                if not body.client_control_ready:
                    self.last_status = "waiting_for_client_control"
                    self.last_detail = (
                        "waiting for the native client to report the exact control contract"
                    )
                    return ServiceResult(self.last_status, self.last_detail)
                if self.clock() - self.last_recreation_command_at >= 30.0:
                    return self._publish_character_recreation()
                self.last_status = "character_recreation_requested"
                self.last_detail = (
                    "waiting for the native client to complete vanilla character recreation"
                )
                return ServiceResult(self.last_status, self.last_detail)
        creation_lifecycle = self.character.lifecycle in {
            CharacterLifecycle.FRESH,
            CharacterLifecycle.RECREATE_REQUIRED,
        }
        pending_lifecycle = self.character.lifecycle == CharacterLifecycle.CREATION_PENDING
        if not body.body_present and not (
            (creation_lifecycle or pending_lifecycle) and body.creation_ready
        ):
            self.last_status = "sensor_only"
            self.last_detail = "body feasibility gate has not passed"
            return ServiceResult(self.last_status, self.last_detail)
        if not body.body_ready and not (
            (creation_lifecycle or pending_lifecycle) and body.creation_ready
        ):
            self.last_status = "waiting_for_client_mod_parity"
            self.last_detail = (
                "the native client must report the matching Build 42 build and "
                "GoblinSurvivor content before control is enabled"
            )
            return ServiceResult(self.last_status, self.last_detail)
        if self.qwen is None:
            self.last_status = "no_brain"
            self.last_detail = "no Qwen adapter configured"
            return ServiceResult(self.last_status, self.last_detail)
        if creation_lifecycle:
            return self._start_character_creation(state_message.fields)
        if self.character.lifecycle == CharacterLifecycle.CREATION_PENDING:
            if self.clock() - self.last_character_command_at >= 30.0:
                raw_catalog = state_message.fields.get("character_catalog")
                try:
                    catalog = (
                        VanillaCatalog.from_mapping(raw_catalog)
                        if raw_catalog is not None
                        else None
                    )
                except CharacterError:
                    catalog = None
                action = (
                    self.character.pending_action(catalog)
                    if catalog is not None
                    else None
                )
                if action is not None:
                    retry = self._publish_character_action(
                        action,
                        "retrying the deterministic character creation command",
                    )
                    if retry.request_id is not None:
                        return retry
            self.last_status = "character_creation_pending"
            self.last_detail = "waiting for PZ to confirm the deterministic character creation"
            return ServiceResult(self.last_status, self.last_detail)

        try:
            intent = self.qwen.propose_intent(self.last_state)
        except QwenError as exc:
            self.last_status = "brain_rejected"
            self.last_detail = str(exc)
            return ServiceResult(self.last_status, self.last_detail)
        decision = self.safety.decide(intent, body)
        if not decision.accepted or decision.action is None:
            self.last_status = "controller_rejected"
            self.last_detail = decision.reason
            self.last_action = None
            return ServiceResult(self.last_status, self.last_detail)
        request_id = new_request_id("intent")
        command = make_message(
            "command.intent",
            request_id=request_id,
            **intent.data,
            controller_action=decision.action.as_dict(),
        )
        self.store.publish("commands", command, stem=request_id)
        self.last_action = decision.action.as_dict()
        self.last_status = "command_published"
        self.last_detail = decision.reason
        return ServiceResult(self.last_status, self.last_detail, request_id)

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
            "character_storage_error": self.character_storage_error,
            "public": self.public_snapshot(),
            "brain_state": dict(self.last_state),
            "last_action": dict(self.last_action) if self.last_action else None,
            "last_response": dict(self.last_response) if self.last_response else None,
            "last_events": [dict(event) for event in self.last_events],
            "mode": {
                "value": self.mode_controller.state.mode.value,
                "reason": self.mode_controller.state.reason,
                "changed_at": self.mode_controller.state.changed_at,
            },
            "hunt": self.hunt.admin_status(),
            "character": self.character.snapshot(),
            "party": {
                "members": sorted(self.party.members),
                "pending": {
                    player: plan.__dict__.copy()
                    for player, plan in self.party.pending.items()
                },
            },
        }

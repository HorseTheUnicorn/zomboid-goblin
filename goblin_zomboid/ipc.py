"""Fail-closed filesystem transport for bridge messages."""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import time
import uuid
from collections.abc import Iterator, Mapping
from typing import Any

from .events import EVENT_FIELDS
from .protocol import (
    MAX_MESSAGE_BYTES,
    Message,
    ProtocolError,
    REQUEST_ID_RE,
    decode_message,
    encode_message,
    make_message,
)

CHANNELS = (
    "state",
    "events",
    "commands",
    "responses",
    "acks",
    "runtime",
    "archive",
    "deadletter",
)
_DESTINATIONS = {"archive", "deadletter"}
BRIDGE_MARKER = ".goblin-bridge-v1"
READY_INDEX_NAME = ".ready-index.json"


def _fsync_directory(directory: Path) -> None:
    if not hasattr(os, "O_DIRECTORY"):
        return
    fd = os.open(str(directory), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=False, exist_ok=True)
    temporary = path.with_name(
        f".{path.name}.tmp-{os.getpid()}-{uuid.uuid4().hex}"
    )
    try:
        with temporary.open("xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


@dataclass(frozen=True)
class ReadyItem:
    channel: str
    stem: str
    json_path: Path
    ready_path: Path


class BridgeStore:
    """Owns a pre-provisioned bridge root and its message lifecycle."""

    def __init__(
        self,
        root: str | os.PathLike[str],
        *,
        max_message_bytes: int = MAX_MESSAGE_BYTES,
    ) -> None:
        self.root = Path(root)
        self.max_message_bytes = max_message_bytes
        if not self.root.is_dir():
            raise FileNotFoundError(
                f"bridge root is missing or not a directory: {self.root}"
            )
        for channel in CHANNELS:
            (self.root / channel).mkdir(exist_ok=True)
            if not (self.root / channel).is_dir():
                raise NotADirectoryError(self.root / channel)
        marker = self.root / BRIDGE_MARKER
        if not marker.is_file():
            _atomic_write(marker, b"goblin-bridge-v1\n")
        self._refresh_ready_index()

    def _channel(self, channel: str) -> Path:
        if channel not in CHANNELS:
            raise ValueError(f"unknown bridge channel: {channel}")
        return self.root / channel

    def _refresh_ready_index(self) -> None:
        """Publish the command stems for PZ's restricted Lua filesystem API."""
        directory = self._channel("commands")
        stems = [
            ready_path.stem
            for ready_path in sorted(directory.glob("*.ready"))
            if REQUEST_ID_RE.fullmatch(ready_path.stem)
            and (directory / f"{ready_path.stem}.json").is_file()
        ]
        encoded = json.dumps(
            stems,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        _atomic_write(directory / READY_INDEX_NAME, encoded)

    @staticmethod
    def _safe_stem(stem: str) -> str:
        if not isinstance(stem, str) or not REQUEST_ID_RE.fullmatch(stem):
            raise ValueError("unsafe bridge filename stem")
        return stem

    def publish(
        self,
        channel: str,
        message: Message | Mapping[str, Any],
        *,
        stem: str | None = None,
        ready: bool = True,
    ) -> Path:
        directory = self._channel(channel)
        encoded = encode_message(
            message, max_message_bytes=self.max_message_bytes
        )
        validated = decode_message(
            encoded, max_message_bytes=self.max_message_bytes
        )
        safe_stem = self._safe_stem(stem or validated.request_id)
        json_path = directory / f"{safe_stem}.json"
        ready_path = directory / f"{safe_stem}.ready"
        if json_path.exists() or ready_path.exists():
            raise FileExistsError(f"bridge item already exists: {safe_stem}")
        _atomic_write(json_path, encoded)
        if ready:
            _atomic_write(ready_path, b"")
            if channel == "commands":
                self._refresh_ready_index()
        return json_path

    def publish_runtime(
        self,
        name: str,
        message: Message | Mapping[str, Any],
    ) -> Path:
        safe_name = self._safe_stem(name)
        encoded = encode_message(
            message, max_message_bytes=self.max_message_bytes
        )
        path = self._channel("runtime") / f"{safe_name}.json"
        _atomic_write(path, encoded)
        return path

    def read_runtime(
        self,
        name: str,
        *,
        max_age_ms: int | None = None,
        now: int | None = None,
    ) -> Message:
        safe_name = self._safe_stem(name)
        path = self._channel("runtime") / f"{safe_name}.json"
        try:
            data = path.read_bytes()
        except FileNotFoundError as exc:
            raise FileNotFoundError(f"runtime message is missing: {name}") from exc
        return decode_message(
            data,
            max_age_ms=max_age_ms,
            now=now,
            max_message_bytes=self.max_message_bytes,
        )

    def iter_ready(self, channel: str) -> Iterator[ReadyItem]:
        directory = self._channel(channel)
        for ready_path in sorted(directory.glob("*.ready")):
            stem = ready_path.stem
            if not REQUEST_ID_RE.fullmatch(stem):
                continue
            json_path = directory / f"{stem}.json"
            if json_path.is_file():
                yield ReadyItem(channel, stem, json_path, ready_path)

    def read_ready(
        self,
        item: ReadyItem,
        *,
        max_age_ms: int | None = None,
        now: int | None = None,
    ) -> Message:
        if item.channel not in CHANNELS:
            raise ValueError("unknown bridge channel")
        if not item.ready_path.is_file() or not item.json_path.is_file():
            raise FileNotFoundError(item.stem)
        data = item.json_path.read_bytes()
        return decode_message(
            data,
            max_age_ms=max_age_ms,
            now=now,
            max_message_bytes=self.max_message_bytes,
        )

    def _move(self, item: ReadyItem, destination: str, reason: str) -> None:
        if destination not in _DESTINATIONS:
            raise ValueError(f"invalid lifecycle destination: {destination}")
        target = self._channel(destination)
        target_stem = item.stem
        if (
            (target / f"{target_stem}.json").exists()
            or (target / f"{target_stem}.ready").exists()
        ):
            target_stem = f"{target_stem}-{uuid.uuid4().hex[:12]}"
        target_json = target / f"{target_stem}.json"
        target_ready = target / f"{target_stem}.ready"
        os.replace(item.json_path, target_json)
        os.replace(item.ready_path, target_ready)
        reason_path = target / f"{target_stem}.reason.json"
        reason_bytes = json.dumps(
            {
                "reason": str(reason)[:512],
                "timestamp_ms": int(time.time() * 1000),
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        _atomic_write(reason_path, reason_bytes)
        if item.channel == "commands":
            self._refresh_ready_index()

    def archive(self, item: ReadyItem, reason: str = "processed") -> None:
        self._move(item, "archive", reason)

    def deadletter(self, item: ReadyItem, reason: str) -> None:
        self._move(item, "deadletter", reason)

    def acknowledge(self, request_id: str, *, status: str = "accepted") -> Path:
        safe_stem = self._safe_stem(request_id)
        message = make_message(
            "ack.command",
            request_id=safe_stem,
            status=status,
        )
        return self.publish("acks", message, stem=safe_stem)

    def write_response(
        self,
        request_id: str,
        *,
        status: str,
        detail: str = "",
        **fields: Any,
    ) -> Path:
        safe_stem = self._safe_stem(request_id)
        message = make_message(
            "response.command",
            request_id=safe_stem,
            status=status,
            detail=str(detail)[:512],
            **fields,
        )
        return self.publish("responses", message, stem=safe_stem)


class RequestLedger:
    """Durable bounded request IDs used for at-most-once command handling."""

    def __init__(
        self,
        path: str | os.PathLike[str],
        *,
        max_entries: int = 2048,
    ) -> None:
        self.path = Path(path)
        self.max_entries = max_entries
        if max_entries < 1:
            raise ValueError("max_entries must be positive")
        self._entries: dict[str, int] = {}
        self._load()

    def _load(self) -> None:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return
        if not isinstance(raw, dict):
            return
        for request_id, timestamp in raw.items():
            if (
                isinstance(request_id, str)
                and REQUEST_ID_RE.fullmatch(request_id)
                and isinstance(timestamp, int)
            ):
                self._entries[request_id] = timestamp
        self._trim()

    def _trim(self) -> None:
        if len(self._entries) <= self.max_entries:
            return
        keep = sorted(
            self._entries.items(), key=lambda pair: pair[1], reverse=True
        )[: self.max_entries]
        self._entries = dict(keep)

    def seen(self, request_id: str) -> bool:
        return request_id in self._entries

    def remember(self, request_id: str, *, timestamp_ms: int | None = None) -> None:
        if not REQUEST_ID_RE.fullmatch(request_id):
            raise ValueError("invalid request id")
        self._entries[request_id] = timestamp_ms or int(time.time() * 1000)
        self._trim()
        self.path.parent.mkdir(parents=False, exist_ok=True)
        encoded = json.dumps(
            self._entries,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        _atomic_write(self.path, encoded)


@dataclass(frozen=True)
class ConsumedCommand:
    item: ReadyItem
    message: Message


@dataclass(frozen=True)
class ConsumedEvent:
    item: ReadyItem
    message: Message


@dataclass(frozen=True)
class ConsumedResponse:
    item: ReadyItem
    message: Message


class CommandConsumer:
    """Reads only validated high-level command intents."""

    def __init__(
        self,
        store: BridgeStore,
        ledger: RequestLedger,
        *,
        max_age_ms: int = 30_000,
        expected_type: str | set[str] | None = None,
    ) -> None:
        self.store = store
        self.ledger = ledger
        self.max_age_ms = max_age_ms
        self.expected_type = expected_type

    def poll(self, *, limit: int = 32, now: int | None = None) -> list[ConsumedCommand]:
        if limit < 1:
            return []
        commands: list[ConsumedCommand] = []
        for item in self.store.iter_ready("commands"):
            if len(commands) >= limit:
                break
            try:
                message = self.store.read_ready(
                    item, max_age_ms=self.max_age_ms, now=now
                )
                accepted_types = (
                    {self.expected_type}
                    if isinstance(self.expected_type, str)
                    else self.expected_type or {"command.intent", "command.npc_action"}
                )
                if message.type not in accepted_types:
                    raise ProtocolError("unexpected command type")
                if self.ledger.seen(message.request_id):
                    self.store.archive(item, "duplicate request id")
                    continue
                self.ledger.remember(
                    message.request_id, timestamp_ms=message.timestamp_ms
                )
            except (OSError, ProtocolError, ValueError) as exc:
                try:
                    self.store.deadletter(item, str(exc))
                except OSError:
                    pass
                continue
            commands.append(ConsumedCommand(item, message))
        return commands

    def finalize(
        self,
        command: ConsumedCommand,
        *,
        status: str,
        detail: str = "",
        **fields: Any,
    ) -> None:
        if status not in {"accepted", "rejected", "failed"}:
            raise ValueError("invalid command response status")
        request_id = command.message.request_id
        self.store.write_response(
            request_id, status=status, detail=detail, **fields
        )
        self.store.acknowledge(request_id, status=status)
        self.store.archive(command.item, f"finalized: {status}")


class EventConsumer:
    """Reads bounded dedicated-server events exactly once per request id."""

    def __init__(
        self,
        store: BridgeStore,
        ledger: RequestLedger,
        *,
        max_age_ms: int = 120_000,
        accepted_types: set[str] | None = None,
    ) -> None:
        self.store = store
        self.ledger = ledger
        self.max_age_ms = max_age_ms
        self.accepted_types = accepted_types

    def poll(
        self,
        *,
        limit: int = 32,
        now: int | None = None,
    ) -> list[ConsumedEvent]:
        if limit < 1:
            return []
        events: list[ConsumedEvent] = []
        for item in self.store.iter_ready("events"):
            if len(events) >= limit:
                break
            try:
                message = self.store.read_ready(
                    item, max_age_ms=self.max_age_ms, now=now
                )
                if not message.type.startswith("event."):
                    raise ProtocolError("unexpected event type")
                allowed_types = self.accepted_types or {
                    f"event.{kind}" for kind in EVENT_FIELDS
                }
                if message.type not in allowed_types:
                    raise ProtocolError("unsupported event type")
                if self.ledger.seen(message.request_id):
                    self.store.archive(item, "duplicate event request id")
                    continue
                self.ledger.remember(
                    message.request_id, timestamp_ms=message.timestamp_ms
                )
            except (OSError, ProtocolError, ValueError) as exc:
                try:
                    self.store.deadletter(item, str(exc))
                except OSError:
                    pass
                continue
            events.append(ConsumedEvent(item, message))
        return events

    def finalize(self, event: ConsumedEvent, *, detail: str = "processed") -> None:
        self.store.archive(event.item, detail)


class ResponseConsumer:
    """Reads PZ command responses without treating them as new commands."""

    def __init__(
        self,
        store: BridgeStore,
        ledger: RequestLedger,
        *,
        max_age_ms: int = 120_000,
    ) -> None:
        self.store = store
        self.ledger = ledger
        self.max_age_ms = max_age_ms

    def poll(
        self,
        *,
        limit: int = 32,
        now: int | None = None,
    ) -> list[ConsumedResponse]:
        if limit < 1:
            return []
        responses: list[ConsumedResponse] = []
        for item in self.store.iter_ready("responses"):
            if len(responses) >= limit:
                break
            try:
                message = self.store.read_ready(
                    item, max_age_ms=self.max_age_ms, now=now
                )
                if message.type != "response.command":
                    raise ProtocolError("unexpected response type")
                status = message.fields.get("status")
                detail = message.fields.get("detail", "")
                if status not in {"accepted", "rejected", "busy", "failed"}:
                    raise ProtocolError("invalid response status")
                if not isinstance(detail, str) or len(detail) > 512:
                    raise ProtocolError("invalid response detail")
                if self.ledger.seen(message.request_id):
                    self.store.archive(item, "duplicate response request id")
                    continue
                self.ledger.remember(
                    message.request_id, timestamp_ms=message.timestamp_ms
                )
            except (OSError, ProtocolError, ValueError) as exc:
                try:
                    self.store.deadletter(item, str(exc))
                except OSError:
                    pass
                continue
            responses.append(ConsumedResponse(item, message))
        return responses

    def finalize(
        self,
        response: ConsumedResponse,
        *,
        detail: str = "processed",
    ) -> None:
        self.store.archive(response.item, detail)

"""Versioned, bounded messages for the Goblin file bridge."""

from __future__ import annotations

from dataclasses import dataclass
import json
import re
import time
import uuid
from collections.abc import Mapping
from typing import Any

PROTOCOL_VERSION = 1
MAX_MESSAGE_BYTES = 256 * 1024
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
MESSAGE_TYPE_RE = re.compile(r"^[a-z][a-z0-9._:-]{0,63}$")


class ProtocolError(ValueError):
    """Raised when a bridge message is unsafe or malformed."""


def now_ms() -> int:
    return int(time.time() * 1000)


def new_request_id(prefix: str = "req") -> str:
    safe_prefix = re.sub(r"[^A-Za-z0-9._:-]", "-", prefix)[:24] or "req"
    return f"{safe_prefix}-{uuid.uuid4().hex}"


@dataclass(frozen=True)
class Message:
    protocol: int
    request_id: str
    timestamp_ms: int
    type: str
    fields: dict[str, Any]

    def as_dict(self) -> dict[str, Any]:
        result = {
            "protocol": self.protocol,
            "request_id": self.request_id,
            "timestamp_ms": self.timestamp_ms,
            "type": self.type,
        }
        result.update(self.fields)
        return result

    @classmethod
    def from_mapping(
        cls,
        raw: Mapping[str, Any],
        *,
        max_age_ms: int | None = None,
        now: int | None = None,
        max_message_bytes: int = MAX_MESSAGE_BYTES,
    ) -> "Message":
        if not isinstance(raw, Mapping):
            raise ProtocolError("message must be a JSON object")
        if not all(isinstance(key, str) for key in raw):
            raise ProtocolError("message keys must be strings")

        try:
            encoded_size = len(
                json.dumps(
                    raw,
                    ensure_ascii=False,
                    allow_nan=False,
                    separators=(",", ":"),
                ).encode("utf-8")
            )
        except (TypeError, ValueError, OverflowError) as exc:
            raise ProtocolError("message contains non-JSON values") from exc
        if encoded_size > max_message_bytes:
            raise ProtocolError("message exceeds the configured size limit")

        required = {"protocol", "request_id", "timestamp_ms", "type"}
        missing = required.difference(raw)
        if missing:
            raise ProtocolError(f"missing envelope field: {sorted(missing)[0]}")
        protocol = raw["protocol"]
        if protocol != PROTOCOL_VERSION:
            raise ProtocolError("unsupported protocol version")

        request_id = raw["request_id"]
        if not isinstance(request_id, str) or not REQUEST_ID_RE.fullmatch(request_id):
            raise ProtocolError("invalid request id")

        timestamp_ms = raw["timestamp_ms"]
        if (
            isinstance(timestamp_ms, bool)
            or not isinstance(timestamp_ms, int)
            or timestamp_ms <= 0
        ):
            raise ProtocolError("invalid timestamp")
        if max_age_ms is not None:
            current = now if now is not None else now_ms()
            if timestamp_ms > current + 60_000:
                raise ProtocolError("message timestamp is too far in the future")
            if current - timestamp_ms > max_age_ms:
                raise ProtocolError("stale message")

        message_type = raw["type"]
        if not isinstance(message_type, str) or not MESSAGE_TYPE_RE.fullmatch(
            message_type
        ):
            raise ProtocolError("invalid message type")

        if "payload" in raw:
            payload = raw["payload"]
            if not isinstance(payload, dict):
                raise ProtocolError("payload must be an object")
            fields = dict(payload)
            direct_fields = set(raw).difference(required | {"payload"})
            if direct_fields:
                raise ProtocolError("payload cannot be mixed with direct fields")
        else:
            fields = {
                key: value for key, value in raw.items() if key not in required
            }

        if not all(isinstance(key, str) for key in fields):
            raise ProtocolError("body keys must be strings")
        return cls(protocol, request_id, timestamp_ms, message_type, fields)


def make_message(
    message_type: str,
    *,
    request_id: str | None = None,
    timestamp_ms: int | None = None,
    **fields: Any,
) -> Message:
    message = Message(
        protocol=PROTOCOL_VERSION,
        request_id=request_id or new_request_id(),
        timestamp_ms=timestamp_ms or now_ms(),
        type=message_type,
        fields=dict(fields),
    )
    return Message.from_mapping(message.as_dict())


def encode_message(
    message: Message | Mapping[str, Any],
    *,
    max_message_bytes: int = MAX_MESSAGE_BYTES,
) -> bytes:
    raw = message.as_dict() if isinstance(message, Message) else dict(message)
    validated = Message.from_mapping(raw, max_message_bytes=max_message_bytes)
    try:
        encoded = json.dumps(
            validated.as_dict(),
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError, OverflowError) as exc:
        raise ProtocolError("message contains non-JSON values") from exc
    if len(encoded) > max_message_bytes:
        raise ProtocolError("message exceeds the size limit")
    return encoded


def decode_message(
    data: bytes | str,
    *,
    max_age_ms: int | None = None,
    now: int | None = None,
    max_message_bytes: int = MAX_MESSAGE_BYTES,
) -> Message:
    if isinstance(data, str):
        data = data.encode("utf-8")
    if not isinstance(data, bytes):
        raise ProtocolError("message data must be bytes or text")
    if len(data) > max_message_bytes:
        raise ProtocolError("message exceeds the size limit")
    try:
        raw = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError("invalid JSON") from exc
    return Message.from_mapping(
        raw,
        max_age_ms=max_age_ms,
        now=now,
        max_message_bytes=max_message_bytes,
    )

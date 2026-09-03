"""Configuration with safe defaults for the Goblin agent."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path


def parse_bool(value: str | bool | None, *, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = value.strip().casefold()
    if normalized in {"1", "true", "yes", "on", "enabled"}:
        return True
    if normalized in {"0", "false", "no", "off", "disabled"}:
        return False
    raise ValueError(f"invalid boolean value: {value!r}")


@dataclass(frozen=True)
class AgentConfig:
    bridge_root: Path = Path("/mnt/goblin-zomboid")
    enabled: bool = False
    heartbeat_seconds: float = 5.0
    pz_timeout_seconds: float = 15.0
    max_message_bytes: int = 256 * 1024
    pz_host: str = "192.168.0.3"
    start_paused: bool = True

    @classmethod
    def from_env(
        cls,
        *,
        root_override: str | os.PathLike[str] | None = None,
        enabled_override: bool | None = None,
    ) -> "AgentConfig":
        root = Path(
            root_override
            if root_override is not None
            else os.environ.get("GOBLIN_BRIDGE_ROOT", str(cls.bridge_root))
        )
        enabled = (
            enabled_override
            if enabled_override is not None
            else parse_bool(os.environ.get("GOBLIN_ENABLED"), default=False)
        )
        heartbeat = float(os.environ.get("GOBLIN_HEARTBEAT_SECONDS", "5"))
        timeout = float(os.environ.get("GOBLIN_PZ_TIMEOUT_SECONDS", "15"))
        max_bytes = int(
            os.environ.get("GOBLIN_MAX_MESSAGE_BYTES", str(cls.max_message_bytes))
        )
        pz_host = os.environ.get("GOBLIN_PZ_HOST", cls.pz_host)
        start_paused = parse_bool(
            os.environ.get("GOBLIN_START_PAUSED"), default=True
        )
        if not (0.5 <= heartbeat <= 60):
            raise ValueError("heartbeat interval must be between 0.5 and 60 seconds")
        if not (1 <= timeout <= 300):
            raise ValueError("PZ timeout must be between 1 and 300 seconds")
        if not (1024 <= max_bytes <= 4 * 1024 * 1024):
            raise ValueError("message size limit is out of bounds")
        if not pz_host or len(pz_host) > 253:
            raise ValueError("invalid PZ host")
        return cls(
            bridge_root=root,
            enabled=bool(enabled),
            heartbeat_seconds=heartbeat,
            pz_timeout_seconds=timeout,
            max_message_bytes=max_bytes,
            pz_host=pz_host,
            start_paused=bool(start_paused),
        )

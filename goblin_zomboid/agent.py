"""Liveness heartbeat for the server-side Goblin runtime."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import signal
import threading
import time
from collections.abc import Callable
from typing import Any

from .config import AgentConfig
from .ipc import BridgeStore
from .protocol import ProtocolError, make_message


@dataclass(frozen=True)
class AgentStatus:
    status: str
    pz_age_ms: int | None
    feature_enabled: bool
    body_mode: str = "disabled"

    def fields(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "brain": "agent",
            "mode": "SAFE",
            "feature_enabled": self.feature_enabled,
            "body_mode": self.body_mode,
            "pz_age_ms": self.pz_age_ms,
        }


class AgentRuntime:
    """Publishes liveness; gameplay decisions remain in ``GoblinService``."""

    def __init__(
        self,
        config: AgentConfig,
        *,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.config = config
        self.clock = clock
        self.store = BridgeStore(
            config.bridge_root, max_message_bytes=config.max_message_bytes
        )

    def _pz_status(self) -> tuple[str, int | None, str]:
        try:
            heartbeat = self.store.read_runtime(
                "zomboid-heartbeat",
                max_age_ms=int(self.config.pz_timeout_seconds * 1000),
                now=int(self.clock() * 1000),
            )
        except (FileNotFoundError, OSError, ProtocolError, ValueError):
            return "waiting_for_pz", None, "sensor_only"
        age = max(0, int(self.clock() * 1000) - heartbeat.timestamp_ms)
        body_mode = heartbeat.fields.get("body_mode", "sensor_only")
        if body_mode not in {"disabled", "sensor_only", "npc", "client_survivor"}:
            body_mode = "sensor_only"
        return "safe", age, body_mode

    def run_once(self) -> AgentStatus:
        if not self.config.enabled:
            status = AgentStatus("disabled", None, False, "disabled")
        else:
            pz_status, age, body_mode = self._pz_status()
            status = AgentStatus(pz_status, age, True, body_mode)
        self.store.publish_runtime(
            "agent-heartbeat",
            make_message("runtime.heartbeat", **status.fields()),
        )
        return status

    def run_forever(self, stop_event: threading.Event | None = None) -> None:
        stop_event = stop_event or threading.Event()
        while not stop_event.is_set():
            self.run_once()
            stop_event.wait(self.config.heartbeat_seconds)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", help="pre-provisioned bridge mount")
    parser.add_argument("--enabled", action="store_true", help="explicitly enable safe stage")
    parser.add_argument("--once", action="store_true", help="write one heartbeat and exit")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    config = AgentConfig.from_env(
        root_override=args.root,
        enabled_override=True if args.enabled else None,
    )
    stop_event = threading.Event()

    def stop(_signum: int, _frame: Any) -> None:
        stop_event.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    runtime = AgentRuntime(config)
    if args.once:
        runtime.run_once()
    else:
        runtime.run_forever(stop_event)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

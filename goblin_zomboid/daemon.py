"""Run the safe Goblin service and its loopback admin API."""

from __future__ import annotations

import os
import signal
import threading
from pathlib import Path

from .admin import AdminApp
from .config import AgentConfig
from .qwen import QwenClient
from .service import GoblinService
from .tracker import TrackerApp


def main() -> int:
    config = AgentConfig.from_env()
    memory_path = Path(
        os.environ.get(
            "GOBLIN_MEMORY_PATH",
            "/home/goblin/.local/share/zomboid-goblin/memory.sqlite3",
        )
    )
    qwen = QwenClient(
        base_url=os.environ.get("GOBLIN_QWEN_URL", "http://127.0.0.1:8000"),
        model=os.environ.get("GOBLIN_QWEN_MODEL", "qwen3-8b-q4km"),
        timeout_seconds=float(os.environ.get("GOBLIN_QWEN_TIMEOUT_SECONDS", "20")),
    )
    service = GoblinService(config, memory_path=memory_path, qwen=qwen)
    app = AdminApp(
        public_supplier=service.public_snapshot,
        admin_supplier=service.admin_snapshot,
        control=service.control,
        admin_token=os.environ.get("GOBLIN_ADMIN_TOKEN"),
    )
    admin_host = os.environ.get("GOBLIN_ADMIN_BIND", "127.0.0.1")
    admin_port = int(os.environ.get("GOBLIN_ADMIN_PORT", "8781"))
    server = app.server(admin_host, admin_port)
    tracker_host = os.environ.get("GOBLIN_TRACKER_BIND", "127.0.0.1")
    tracker_port = int(os.environ.get("GOBLIN_TRACKER_PORT", "8782"))
    tracker_server = TrackerApp(service.tracker).server(tracker_host, tracker_port)
    stop_event = threading.Event()

    def stop(_signum: int, _frame: object) -> None:
        stop_event.set()
        server.shutdown()
        tracker_server.shutdown()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    admin_thread = threading.Thread(
        target=server.serve_forever,
        name="goblin-admin",
        daemon=True,
    )
    admin_thread.start()
    tracker_thread = threading.Thread(
        target=tracker_server.serve_forever,
        name="goblin-tracker",
        daemon=True,
    )
    tracker_thread.start()
    try:
        service.run_forever(stop_event)
    finally:
        server.server_close()
        tracker_server.server_close()
        service.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

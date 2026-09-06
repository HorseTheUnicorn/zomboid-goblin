"""Fail-closed SSH file relay for an unprivileged PZ guest without NFS."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import tempfile
import time
import uuid
from collections.abc import Callable

from .ipc import BRIDGE_MARKER, CHANNELS, READY_INDEX_NAME, _atomic_write
from .protocol import MAX_MESSAGE_BYTES, ProtocolError, REQUEST_ID_RE, decode_message

_STEM_LIMIT = 128
_REMOTE_READ_CHANNELS = (
    "state",
    "events",
    "runtime",
    "commands",
    "responses",
    "acks",
    "archive",
    "deadletter",
)
# Build 42's restricted Lua file writer reliably materializes the JSON
# payloads, but does not materialize the separate marker files it is asked to
# write.  These channels are therefore eligible for a validated JSON-only
# fallback on the remote side.  Commands remain marker-gated: accepting a
# command without its host-created marker would weaken the control boundary.
_REMOTE_JSON_FALLBACK_CHANNELS = ("events", "responses", "acks")
_PZ_RUNTIME_NAMES = (
    "zomboid-heartbeat.json",
    "zomboid-state.json",
    "zomboid-exact-state.json",
)
_MAX_FILES_PER_PASS = 256
_MAX_REMOTE_INDEX_ENTRIES = 1024
_FILENAME_RE = r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$"
_FILENAME_PATTERN = re.compile(_FILENAME_RE)


def _safe_stem(value: str) -> bool:
    return isinstance(value, str) and len(value) <= _STEM_LIMIT and bool(
        REQUEST_ID_RE.fullmatch(value)
    )


def _safe_path(value: str) -> bool:
    return (
        isinstance(value, str)
        and value.startswith("/")
        and "\x00" not in value
        and all(part not in {"", ".", ".."} for part in value.split("/")[1:])
    )


@dataclass(frozen=True)
class RelayConfig:
    local_root: Path = Path("/mnt/goblin-zomboid")
    remote_host: str = "192.168.0.3"
    remote_user: str = "goblin"
    # PZ's Lua file API resolves the relative GoblinBridgeRoot below the
    # server cachedir/Lua directory. Override this when .3 uses -cachedir.
    remote_root: str = "/home/zomboid/Zomboid/Lua/goblin-bridge"
    ssh_key: Path = Path("/home/goblin/.ssh/id_ed25519")
    interval_seconds: float = 1.0
    ssh_timeout_seconds: float = 8.0
    # The production relay runs on .76 with a PZ server as the remote.  The
    # Windows local harness reverses this: PZ is local and the .76 agent is
    # remote.  The same atomic protocol is used in both directions.
    remote_role: str = "pz"

    def __post_init__(self) -> None:
        if not self.remote_host or len(self.remote_host) > 253:
            raise ValueError("invalid relay host")
        if not self.remote_user or len(self.remote_user) > 64:
            raise ValueError("invalid relay user")
        if not _safe_path(self.remote_root):
            raise ValueError("invalid relay root")
        if self.interval_seconds < 0.2 or self.interval_seconds > 60:
            raise ValueError("relay interval is out of bounds")
        if self.ssh_timeout_seconds < 1 or self.ssh_timeout_seconds > 60:
            raise ValueError("SSH timeout is out of bounds")
        if self.remote_role not in {"pz", "agent"}:
            raise ValueError("relay remote role must be 'pz' or 'agent'")

    @classmethod
    def from_env(cls) -> "RelayConfig":
        return cls(
            local_root=Path(os.environ.get("GOBLIN_BRIDGE_ROOT", str(cls.local_root))),
            remote_host=os.environ.get("GOBLIN_PZ_HOST", cls.remote_host),
            remote_user=os.environ.get("GOBLIN_PZ_SSH_USER", cls.remote_user),
            remote_root=os.environ.get(
                "GOBLIN_PZ_BRIDGE_ROOT", cls.remote_root
            ),
            ssh_key=Path(
                os.environ.get("GOBLIN_PZ_SSH_KEY", str(cls.ssh_key))
            ),
            interval_seconds=float(os.environ.get("GOBLIN_RELAY_INTERVAL", "1")),
            ssh_timeout_seconds=float(
                os.environ.get("GOBLIN_RELAY_SSH_TIMEOUT", "8")
            ),
            remote_role=os.environ.get("GOBLIN_RELAY_REMOTE_ROLE", "pz"),
        )


class SshFileRelay:
    """Mirror only bridge channels over an existing key-only SSH account.

    The relay never creates the remote root, never follows remote paths, and
    publishes remote files in JSON-then-ready order. It is intentionally a
    separate process from the existing Discord and Qwen services.  The
    default direction has the agent bridge locally and PZ remotely; the
    ``remote_role=agent`` direction is used by the Windows local harness.
    """

    def __init__(
        self,
        config: RelayConfig,
        *,
        runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    ) -> None:
        self.config = config
        self.runner = runner
        if not config.local_root.is_dir():
            raise FileNotFoundError(
                f"local bridge root is missing: {config.local_root}"
            )
        for channel in CHANNELS:
            channel_dir = config.local_root / channel
            channel_dir.mkdir(exist_ok=True)
            if not channel_dir.is_dir():
                raise NotADirectoryError(channel_dir)
        self._remote_ready = False
        self._remote_command_stems: list[str] | None = None
        self._remote_json_seen: set[tuple[str, str]] = set()
        self._local_json_seen: set[tuple[str, str]] = set()
        self._runtime_signatures: dict[str, tuple[int, int]] = {}

    @property
    def remote(self) -> str:
        return f"{self.config.remote_user}@{self.config.remote_host}"

    def _options(self) -> list[str]:
        return [
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"ConnectTimeout={int(self.config.ssh_timeout_seconds)}",
            "-i",
            str(self.config.ssh_key),
        ]

    def _ssh(self, command: str) -> subprocess.CompletedProcess[str]:
        return self.runner(
            ["ssh", *self._options(), self.remote, command],
            capture_output=True,
            text=True,
            timeout=self.config.ssh_timeout_seconds,
            check=False,
        )

    def _scp(
        self,
        source: str | Path,
        target: str,
    ) -> subprocess.CompletedProcess[str]:
        return self.runner(
            ["scp", *self._options(), str(source), target],
            capture_output=True,
            text=True,
            timeout=self.config.ssh_timeout_seconds,
            check=False,
        )

    def _remote_file(self, channel: str, name: str) -> str:
        if (
            channel not in CHANNELS
            or not isinstance(name, str)
            or not _FILENAME_PATTERN.fullmatch(name)
        ):
            raise ValueError("unsafe relay path")
        return f"{self.config.remote_root}/{channel}/{name}"

    def _remote_marker(self) -> str:
        return f"{self.config.remote_root}/{BRIDGE_MARKER}"

    def _remote_index_file(self) -> str:
        return f"{self.config.remote_root}/commands/{READY_INDEX_NAME}"

    def _remote_bridge_ready(self) -> bool:
        if self._remote_ready:
            return True
        checks = [f"test -f {shlex.quote(self._remote_marker())}"]
        checks.extend(
            f"test -d {shlex.quote(f'{self.config.remote_root}/{channel}')}"
            for channel in CHANNELS
        )
        command = " && ".join(checks)
        try:
            ready = self._ssh(command).returncode == 0
        except (OSError, subprocess.SubprocessError):
            ready = False
        if ready:
            self._remote_ready = True
        return ready

    def _load_remote_command_index(self) -> bool:
        if self._remote_command_stems is not None:
            return True
        if not self._remote_bridge_ready():
            return False
        try:
            result = self._ssh(
                f"cat -- {shlex.quote(self._remote_index_file())}"
            )
        except (OSError, subprocess.SubprocessError):
            return False
        if result.returncode != 0:
            return False
        try:
            raw = json.loads(result.stdout)
        except (TypeError, json.JSONDecodeError):
            return False
        if not isinstance(raw, list) or len(raw) > _MAX_REMOTE_INDEX_ENTRIES:
            return False
        stems: list[str] = []
        seen: set[str] = set()
        for value in raw:
            if not isinstance(value, str) or not _safe_stem(value):
                return False
            if value in seen:
                return False
            seen.add(value)
            stems.append(value)
        self._remote_command_stems = stems
        return True

    def _write_remote_command_index(self) -> bool:
        if self._remote_command_stems is None or not self._remote_bridge_ready():
            return False
        encoded = json.dumps(
            self._remote_command_stems,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        if len(encoded) > 256 * 1024:
            return False
        commands_dir = self.config.local_root / "commands"
        temporary: Path | None = None
        remote_tmp = self._remote_file(
            "commands", f"relaytmp-{uuid.uuid4().hex}.json"
        )
        try:
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=".relay-index-",
                suffix=".json",
                dir=str(commands_dir),
            )
            os.close(descriptor)
            temporary = Path(temporary_name)
            temporary.write_bytes(encoded)
            uploaded = self._scp(
                temporary,
                f"{self.remote}:{remote_tmp}",
            )
            if uploaded.returncode != 0:
                return False
            moved = self._ssh(
                f"mv -- {shlex.quote(remote_tmp)} "
                f"{shlex.quote(self._remote_index_file())}"
            )
            if moved.returncode != 0:
                return False
            readable = self._ssh(
                f"chmod g+r -- {shlex.quote(self._remote_index_file())}"
            )
            return readable.returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False
        finally:
            if temporary is not None:
                try:
                    temporary.unlink()
                except FileNotFoundError:
                    pass

    def _remote_exists(self, path: str) -> bool:
        if not _safe_path(path):
            raise ValueError("unsafe remote path")
        command = f"test -e {shlex.quote(path)}"
        try:
            return self._ssh(command).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    def _remote_names(self, channel: str, suffix: str) -> list[str]:
        if channel not in _REMOTE_READ_CHANNELS or not self._remote_bridge_ready():
            return []
        directory = f"{self.config.remote_root}/{channel}"
        command = (
            f"find {shlex.quote(directory)} -maxdepth 1 -type f "
            f"-name {shlex.quote('*' + suffix)} -printf '%f\\n'"
        )
        try:
            result = self._ssh(command)
        except (OSError, subprocess.SubprocessError):
            return []
        if result.returncode != 0:
            return []
        names: list[str] = []
        for raw in result.stdout.splitlines():
            name = raw.strip()
            if not name.endswith(suffix):
                continue
            stem = name[: -len(suffix)]
            if _safe_stem(stem) and not name.startswith("relaytmp-"):
                names.append(name)
            if len(names) >= _MAX_FILES_PER_PASS:
                break
        return sorted(set(names))

    def _pull_file(
        self,
        channel: str,
        name: str,
        *,
        replace: bool = False,
    ) -> bool:
        local_path = self.config.local_root / channel / name
        if local_path.exists() and not replace:
            return True
        remote_path = self._remote_file(channel, name)
        temporary = local_path.with_name(
            f".{name}.relay-{uuid.uuid4().hex}"
        )
        try:
            result = self._scp(f"{self.remote}:{remote_path}", str(temporary))
            if result.returncode != 0:
                return False
            os.replace(temporary, local_path)
            return True
        except (OSError, subprocess.SubprocessError):
            return False
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    def _pull_runtime(self) -> int:
        count = 0
        for name in self._remote_names("runtime", ".json"):
            if self._pull_file("runtime", name, replace=True):
                count += 1
        return count

    @staticmethod
    def _write_local_ready(path: Path) -> bool:
        """Create a local ready marker without replacing an existing one."""
        if path.is_file():
            return True
        try:
            descriptor = os.open(
                str(path),
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(descriptor, "wb") as handle:
                handle.flush()
                os.fsync(handle.fileno())
            return True
        except FileExistsError:
            return path.is_file()
        except OSError:
            return False

    @staticmethod
    def _json_fallback_type_allowed(channel: str, message_type: str) -> bool:
        if channel == "events":
            return message_type.startswith("event.")
        if channel == "responses":
            return message_type == "response.command"
        if channel == "acks":
            return message_type == "ack.command"
        return False

    def _pull_json_fallback(self, channel: str) -> int:
        """Pull PZ JSON output and gate it locally after protocol validation.

        The PZ-side writer closes each JSON file before this method can make a
        local marker.  Invalid or partial JSON is left unready and retried on
        a later pass; it is never handed to the service consumers.
        """
        if channel not in _REMOTE_JSON_FALLBACK_CHANNELS:
            return 0
        count = 0
        for json_name in self._remote_names(channel, ".json"):
            stem = json_name[: -len(".json")]
            if not _safe_stem(stem):
                continue
            key = (channel, stem)
            if key in self._remote_json_seen:
                continue
            if not self._pull_file(channel, json_name):
                continue
            local_json = self.config.local_root / channel / json_name
            try:
                message = decode_message(
                    local_json.read_bytes(),
                    max_message_bytes=MAX_MESSAGE_BYTES,
                )
            except (OSError, ProtocolError, ValueError):
                continue
            if not self._json_fallback_type_allowed(channel, message.type):
                continue
            ready_path = self.config.local_root / channel / f"{stem}.ready"
            already_ready = ready_path.is_file()
            if self._write_local_ready(
                ready_path
            ):
                self._remote_json_seen.add(key)
                if not already_ready:
                    count += 1
        return count

    def _pull_ready_channel(self, channel: str) -> int:
        count = 0
        for ready_name in self._remote_names(channel, ".ready"):
            stem = ready_name[: -len(".ready")]
            json_name = f"{stem}.json"
            if self._pull_file(channel, json_name) and self._pull_file(
                channel, ready_name
            ):
                count += 1
        return count

    def _refresh_local_command_index(self) -> None:
        """Keep PZ's restricted Lua reader aware of pulled commands."""
        directory = self.config.local_root / "commands"
        stems = [
            ready_path.stem
            for ready_path in sorted(directory.glob("*.ready"))
            if _safe_stem(ready_path.stem)
            and (directory / f"{ready_path.stem}.json").is_file()
        ]
        encoded = json.dumps(
            stems, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        _atomic_write(directory / READY_INDEX_NAME, encoded)

    def _prepare_local_json_fallback(self, channel: str) -> int:
        """Gate direct PZ JSON output with host-created ready markers.

        Build 42 can close the JSON file but fail to materialize its marker.
        In the reverse local direction the relay is the host-side consumer,
        so it validates the payload before creating the marker that the .76
        agent will consume.
        """
        if channel not in _REMOTE_JSON_FALLBACK_CHANNELS:
            return 0
        count = 0
        directory = self.config.local_root / channel
        for json_path in sorted(directory.glob("*.json")):
            stem = json_path.stem
            if not _safe_stem(stem) or json_path.name == READY_INDEX_NAME:
                continue
            key = (channel, stem)
            ready_path = directory / f"{stem}.ready"
            if key in self._local_json_seen and ready_path.is_file():
                continue
            try:
                message = decode_message(
                    json_path.read_bytes(),
                    max_message_bytes=MAX_MESSAGE_BYTES,
                )
            except (OSError, ProtocolError, ValueError):
                continue
            if not self._json_fallback_type_allowed(channel, message.type):
                continue
            already_ready = ready_path.is_file()
            if not self._write_local_ready(ready_path):
                continue
            self._local_json_seen.add(key)
            if not already_ready:
                count += 1
        return count

    def pull(self) -> int:
        if self.config.remote_role == "agent":
            count = 0
            # Commands, responses, and acknowledgements flow from .76 back
            # into the local PZ bridge. Runtime files remain PZ-owned locally.
            for channel in ("commands", "responses", "acks"):
                count += self._pull_ready_channel(channel)
            self._refresh_local_command_index()
            return count
        count = self._pull_runtime()
        for channel in _REMOTE_READ_CHANNELS:
            if channel != "runtime":
                count += self._pull_ready_channel(channel)
                count += self._pull_json_fallback(channel)
        return count

    def _publish_remote_runtime(self, name: str) -> bool:
        """Publish one PZ runtime JSON file to the remote agent root."""
        if not self._remote_bridge_ready():
            return False
        local_path = self.config.local_root / "runtime" / name
        if not local_path.is_file():
            return False
        try:
            message = decode_message(
                local_path.read_bytes(),
                max_message_bytes=MAX_MESSAGE_BYTES,
            )
        except (OSError, ProtocolError, ValueError):
            return False
        if message.type not in {
            "runtime.heartbeat", "runtime.state", "runtime.exact_state"
        }:
            return False
        try:
            stat = local_path.stat()
        except OSError:
            return False
        signature = (stat.st_mtime_ns, stat.st_size)
        if self._runtime_signatures.get(name) == signature:
            return False
        remote_path = self._remote_file("runtime", name)
        remote_tmp = self._remote_file(
            "runtime", f"relaytmp-{uuid.uuid4().hex}.json"
        )
        try:
            uploaded = self._scp(
                local_path, f"{self.remote}:{remote_tmp}"
            )
            if uploaded.returncode != 0:
                return False
            moved = self._ssh(
                f"mv -- {shlex.quote(remote_tmp)} "
                f"{shlex.quote(remote_path)}"
            )
            if moved.returncode != 0:
                return False
            readable = self._ssh(
                f"chmod g+r -- {shlex.quote(remote_path)}"
            )
            if readable.returncode != 0:
                return False
            self._runtime_signatures[name] = signature
            return True
        except (OSError, subprocess.SubprocessError):
            return False

    def _archive_local_item(self, channel: str, stem: str) -> None:
        source_dir = self.config.local_root / channel
        archive_dir = self.config.local_root / "archive"
        suffix = f"relay-{uuid.uuid4().hex[:12]}"
        for extension in ("json", "ready"):
            source = source_dir / f"{stem}.{extension}"
            if not source.exists():
                continue
            target = archive_dir / f"{stem}-{suffix}.{extension}"
            try:
                os.replace(source, target)
            except OSError:
                return

    def _push_to_agent(self) -> int:
        """Push local PZ events/results and state to the remote .76 agent."""
        def push_channel(channel: str) -> int:
            pushed = 0
            self._prepare_local_json_fallback(channel)
            for ready_path in sorted(
                (self.config.local_root / channel).glob("*.ready")
            )[:_MAX_FILES_PER_PASS]:
                stem = ready_path.stem
                if not _safe_stem(stem):
                    continue
                if not self._publish_remote(channel, stem):
                    continue
                self._archive_local_item(channel, stem)
                pushed += 1
            return pushed

        # Keep the live chat/control signal and the PZ liveness state ahead of
        # historical result queues.  A busy local test can accumulate many
        # responses/acks, and draining those first would delay the event that
        # should wake Qwen and the runtime state that tells it the PZ side is
        # online.
        count = push_channel("events")
        for name in _PZ_RUNTIME_NAMES:
            if self._publish_remote_runtime(name):
                count += 1
        for channel in ("responses", "acks"):
            count += push_channel(channel)
        return count

    def _publish_remote(self, channel: str, stem: str) -> bool:
        if not self._remote_bridge_ready():
            return False
        local_dir = self.config.local_root / channel
        local_json = local_dir / f"{stem}.json"
        local_ready = local_dir / f"{stem}.ready"
        if not local_json.is_file() or not local_ready.is_file():
            return False
        remote_json = self._remote_file(channel, f"{stem}.json")
        remote_ready = self._remote_file(channel, f"{stem}.ready")
        try:
            if not self._remote_exists(remote_json):
                remote_tmp = self._remote_file(
                    channel, f"relaytmp-{uuid.uuid4().hex}.json"
                )
                result = self._scp(
                    local_json,
                    f"{self.remote}:{remote_tmp}",
                )
                if result.returncode != 0:
                    return False
                move = self._ssh(
                    f"mv -- {shlex.quote(remote_tmp)} {shlex.quote(remote_json)}"
                )
                if move.returncode != 0:
                    return False
                readable = self._ssh(
                    f"chmod g+r -- {shlex.quote(remote_json)}"
                )
                if readable.returncode != 0:
                    return False
            if not self._remote_exists(remote_ready):
                remote_tmp = self._remote_file(
                    channel, f"relaytmp-{uuid.uuid4().hex}.ready"
                )
                result = self._scp(
                    local_ready,
                    f"{self.remote}:{remote_tmp}",
                )
                if result.returncode != 0:
                    return False
                move = self._ssh(
                    f"mv -- {shlex.quote(remote_tmp)} {shlex.quote(remote_ready)}"
                )
                if move.returncode != 0:
                    return False
                readable = self._ssh(
                    f"chmod g+r -- {shlex.quote(remote_ready)}"
                )
                if readable.returncode != 0:
                    return False
            return self._remote_exists(remote_json) and self._remote_exists(
                remote_ready
            )
        except (OSError, subprocess.SubprocessError):
            return False

    def _archive_local_command(self, stem: str) -> None:
        source_dir = self.config.local_root / "commands"
        archive_dir = self.config.local_root / "archive"
        suffix = f"relay-{uuid.uuid4().hex[:12]}"
        for extension in ("json", "ready"):
            source = source_dir / f"{stem}.{extension}"
            if not source.exists():
                continue
            target = archive_dir / f"{stem}-{suffix}.{extension}"
            try:
                os.replace(source, target)
            except OSError:
                return

    def push(self) -> int:
        if self.config.remote_role == "agent":
            return self._push_to_agent()
        if not self._load_remote_command_index():
            return 0
        count = 0
        for ready_path in sorted(
            (self.config.local_root / "commands").glob("*.ready")
        )[:_MAX_FILES_PER_PASS]:
            stem = ready_path.stem
            if not _safe_stem(stem):
                continue
            if not self._publish_remote("commands", stem):
                continue
            if self._remote_command_stems is None:
                continue
            if stem not in self._remote_command_stems:
                if len(self._remote_command_stems) >= _MAX_REMOTE_INDEX_ENTRIES:
                    continue
                self._remote_command_stems.append(stem)
                if not self._write_remote_command_index():
                    self._remote_command_stems.pop()
                    continue
            self._archive_local_command(stem)
            count += 1
        return count

    def run_once(self) -> dict[str, int]:
        return {"pulled": self.pull(), "pushed": self.push()}

    def run_forever(self, stop_event: object | None = None) -> None:
        while True:
            if stop_event is not None and getattr(stop_event, "is_set")():
                return
            self.run_once()
            if stop_event is not None and getattr(stop_event, "wait")(
                self.config.interval_seconds
            ):
                return
            if stop_event is None:
                time.sleep(self.config.interval_seconds)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    relay = SshFileRelay(RelayConfig.from_env())
    if args.once:
        relay.run_once()
        return 0
    import threading

    stop_event = threading.Event()

    def stop(_signum: int, _frame: object) -> None:
        stop_event.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    relay.run_forever(stop_event)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

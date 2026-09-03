#!/usr/bin/env python3
"""Interactively authenticate SteamCMD and install the native Linux PZ client.

This command is intentionally Linux-only.  It uses the existing native
SteamCMD binary through a PTY so passwords and Steam Guard codes are entered
interactively rather than appearing in argv, shell history, or logs.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import getpass
import os
from pathlib import Path
import re
import select
import shlex
import stat
import sys
import tempfile
import time
from typing import Iterable


DEFAULT_STEAM_ACCOUNT = "feralgoblin93k"
DEFAULT_STEAMCMD = "/home/goblin/pz-client/steamcmd/steamcmd.sh"
DEFAULT_CLIENT_ROOT = "/home/goblin/pz-client/game"
DEFAULT_SECRETS_FILE = "/etc/goblin-zomboid/secrets.env"
DEFAULT_PZ_HOST = "192.168.0.3"
DEFAULT_PZ_PORT = 16261
DEFAULT_PZ_USERNAME = "Goblin"
DEFAULT_SERVICE_USER = "goblin"
STEAM_APP_ID = "108600"
MAX_SECRET_BYTES = 4096
MAX_STEAM_OUTPUT_BUFFER = 8192
MAX_GUARD_ATTEMPTS = 3

_ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_GUARD_PROMPT_RE = re.compile(
    r"(?:steam\s+guard|authentication|two[- ]factor|5[- ]digit)\s+code\s*[:>]",
    re.IGNORECASE,
)
_HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$")
_USERNAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
_STEAM_PROMPT = "steam>"
_GUARD_MARKERS = (
    "steam guard",
    "guard code",
    "authentication code",
    "5 digit",
    "two-factor",
    "two factor",
)
_LOGIN_FAILURE_MARKERS = (
    "invalid password",
    "invalid login auth code",
    "invalid auth code",
    "steam guard code was invalid",
    "login failed",
    "failed to login",
    "no subscription",
    "no license",
    "not logged in",
    "access denied",
)
_UPDATE_FAILURE_MARKERS = (
    "error!",
    "failed to install",
    "no subscription",
    "no license",
    "not logged in",
    "access denied",
)


class SetupError(RuntimeError):
    """A user-actionable setup failure without secret-bearing details."""


@dataclass(frozen=True)
class ServiceAccount:
    name: str
    uid: int
    gid: int
    home: Path
    shell: str


def _bounded_secret(value: str, label: str) -> bytearray:
    if "\x00" in value or "\r" in value or "\n" in value:
        raise SetupError(f"{label} must be a single line")
    encoded = value.encode("utf-8")
    if not encoded or len(encoded) > MAX_SECRET_BYTES:
        raise SetupError(f"{label} is empty or too long")
    return bytearray(encoded)


def _bounded_text(value: str, label: str, maximum: int) -> str:
    value = value.strip()
    if not value or len(value) > maximum or "\x00" in value:
        raise SetupError(f"{label} is invalid")
    return value


def _prompt_text(label: str, default: str, maximum: int) -> str:
    answer = input(f"{label} [{default}]: ").strip()
    return _bounded_text(answer or default, label, maximum)


def _prompt_secret(label: str) -> bytearray:
    return _bounded_secret(getpass.getpass(f"{label} (hidden): "), label)


def _resolve_service_account(name: str) -> ServiceAccount:
    import pwd

    try:
        record = pwd.getpwnam(name)
    except KeyError as exc:
        raise SetupError(f"service account does not exist: {name}") from exc
    if record.pw_uid == 0:
        raise SetupError("the client service account must not be root")
    return ServiceAccount(
        name=record.pw_name,
        uid=record.pw_uid,
        gid=record.pw_gid,
        home=Path(record.pw_dir),
        shell=record.pw_shell,
    )


def _validate_host(value: str) -> str:
    value = _bounded_text(value, "PZ server host", 253)
    if not _HOST_RE.fullmatch(value) or ".." in value:
        raise SetupError("PZ server host is invalid")
    return value


def _validate_port(value: str) -> int:
    try:
        port = int(value.strip())
    except ValueError as exc:
        raise SetupError("PZ server port is invalid") from exc
    if not 1 <= port <= 65535:
        raise SetupError("PZ server port is outside 1..65535")
    return port


def _validate_username(value: str) -> str:
    value = _bounded_text(value, "PZ username", 32)
    if not _USERNAME_RE.fullmatch(value):
        raise SetupError("PZ username may contain only letters, digits, _ and -")
    return value


def _redact(text: str, secrets: Iterable[str]) -> str:
    text = _ANSI_RE.sub("", text)
    for secret in sorted((item for item in secrets if item), key=len, reverse=True):
        text = text.replace(secret, "[redacted]")
    return text


def _send_line(master_fd: int, value: str) -> None:
    if "\r" in value or "\n" in value or "\x00" in value:
        raise SetupError("internal command line validation failed")
    os.write(master_fd, (value + "\n").encode("utf-8"))


def _send_secret(master_fd: int, secret: bytearray) -> None:
    try:
        os.write(master_fd, bytes(secret) + b"\n")
    finally:
        for index in range(len(secret)):
            secret[index] = 0


def _count_new_token(text: str, boundary: int, token: str) -> int:
    """Count token matches that are not wholly contained in the scan tail."""
    count = 0
    start = 0
    while True:
        index = text.find(token, start)
        if index < 0:
            return count
        if index + len(token) > boundary:
            count += 1
        start = index + 1


def _count_new_matches(pattern: re.Pattern[str], text: str, boundary: int) -> int:
    """Count regex matches that end in newly received output."""
    return sum(match.end() > boundary for match in pattern.finditer(text))


def _child_environment(account: ServiceAccount) -> dict[str, str]:
    environment = os.environ.copy()
    environment["HOME"] = str(account.home)
    environment["USER"] = account.name
    environment["LOGNAME"] = account.name
    environment["TERM"] = "dumb"
    # Never let a caller accidentally leak credential-like variables into
    # SteamCMD's process environment.
    for key in ("STEAM_PASSWORD", "PZ_SERVER_PASSWORD"):
        environment.pop(key, None)
    return environment


def _drop_privileges(account: ServiceAccount) -> None:
    if os.geteuid() != 0:
        raise SetupError("setup-steam must be run as root")
    os.initgroups(account.name, account.gid)
    os.setgid(account.gid)
    os.setuid(account.uid)


def _resolve_client_root(client_root: Path, account: ServiceAccount) -> Path:
    candidate = client_root.expanduser()
    if not candidate.is_absolute():
        raise SetupError("native client root must be an absolute path")
    try:
        home = account.home.expanduser().resolve(strict=True)
        resolved = candidate.resolve(strict=False)
        relative = resolved.relative_to(home)
    except (OSError, ValueError) as exc:
        raise SetupError(
            "native client root must be inside the service account home"
        ) from exc
    if not relative.parts:
        raise SetupError("native client root must be below the service account home")
    return resolved


def _run_steamcmd(
    *,
    steamcmd: Path,
    client_root: Path,
    account: ServiceAccount,
    steam_account: str,
    steam_password: bytearray,
    timeout_seconds: float,
) -> None:
    if os.name != "posix":
        raise SetupError("native SteamCMD setup is Linux-only; Wine is not supported")
    import pty
    import termios

    if not steamcmd.is_file() or not os.access(steamcmd, os.X_OK):
        raise SetupError(f"SteamCMD is not executable: {steamcmd}")
    client_root = _resolve_client_root(client_root, account)
    try:
        client_root.mkdir(parents=True, exist_ok=True)
        os.chown(client_root, account.uid, account.gid)
    except OSError as exc:
        raise SetupError(f"could not prepare native client directory: {exc}") from exc

    pid, master_fd = pty.fork()
    if pid == 0:
        try:
            # Disable PTY echo before exec so a password cannot appear on the
            # operator terminal even if SteamCMD uses a plain input prompt.
            attributes = termios.tcgetattr(0)
            attributes[3] &= ~(termios.ECHO | termios.ECHONL)
            termios.tcsetattr(0, termios.TCSANOW, attributes)
            _drop_privileges(account)
            os.chdir(account.home)
            os.execve(
                str(steamcmd),
                [str(steamcmd)],
                _child_environment(account),
            )
        except BaseException:
            os._exit(127)

    output_buffer = ""
    redaction_values: list[str] = [
        steam_account,
        bytes(steam_password).decode("utf-8", errors="replace"),
    ]
    stage = "await_initial_prompt"
    password_sent = False
    cached_login_seen = False
    guard_attempts = 0
    steam_prompt_seen = 0
    steam_prompt_handled = 0
    steam_scan_tail = ""
    guard_prompt_seen = 0
    guard_prompt_handled = 0
    guard_scan_tail = ""
    login_output = ""
    update_output = ""
    started = time.monotonic()

    def recent_lower() -> str:
        return _ANSI_RE.sub("", output_buffer[-2048:]).lower()

    def fail_if_login_failed() -> None:
        recent = login_output[-2048:]
        if any(marker in recent for marker in _LOGIN_FAILURE_MARKERS):
            raise SetupError(
                "SteamCMD login failed; no credential file was written"
            )

    try:
        os.set_blocking(master_fd, False)
        while True:
            if time.monotonic() - started > timeout_seconds:
                raise SetupError("SteamCMD timed out; no credential file was written")
            ready, _, _ = select.select([master_fd], [], [], 0.5)
            if not ready:
                continue
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                break
            decoded = chunk.decode("utf-8", errors="replace")
            output_buffer = (output_buffer + decoded)[-MAX_STEAM_OUTPUT_BUFFER:]
            sys.stdout.write(_redact(decoded, redaction_values))
            sys.stdout.flush()

            clean = _ANSI_RE.sub("", decoded).lower()
            steam_scan_text = steam_scan_tail + clean
            steam_boundary = len(steam_scan_tail)
            steam_prompt_seen += _count_new_token(
                steam_scan_text,
                steam_boundary,
                _STEAM_PROMPT,
            )
            steam_scan_tail = steam_scan_text[-128:]
            guard_scan_text = guard_scan_tail + clean
            guard_boundary = len(guard_scan_tail)
            guard_prompt_seen += _count_new_matches(
                _GUARD_PROMPT_RE,
                guard_scan_text,
                guard_boundary,
            )
            guard_scan_tail = guard_scan_text[-128:]
            if stage in {"await_password", "await_login_result"}:
                login_output = (login_output + clean)[-MAX_STEAM_OUTPUT_BUFFER:]
            if stage == "await_update_prompt":
                update_output = (update_output + clean)[-MAX_STEAM_OUTPUT_BUFFER:]

            if stage == "await_password" and not password_sent:
                if "password" in recent_lower():
                    _send_secret(master_fd, steam_password)
                    password_sent = True
                    login_output = ""
                    stage = "await_login_result"
                    continue

            if stage in {"await_password", "await_login_result"}:
                if "logging in using cached credentials" in login_output:
                    cached_login_seen = True
                if guard_prompt_seen > guard_prompt_handled:
                    while guard_prompt_handled < guard_prompt_seen:
                        guard_prompt_handled += 1
                        if guard_attempts >= MAX_GUARD_ATTEMPTS:
                            raise SetupError(
                                "Steam Guard authorization failed after multiple "
                                "attempts; no credential file was written"
                            )
                        if guard_attempts == 0:
                            print(
                                "\nSteam Guard authorization is required. "
                                "Approve the login using the configured Steam Guard method."
                            )
                        else:
                            print(
                                "\nSteam rejected the previous Steam Guard code. "
                                "Enter the newest code."
                            )
                        code = _prompt_secret("Steam Guard code")
                        redaction_values.append(
                            bytes(code).decode("utf-8", errors="ignore")
                        )
                        _send_secret(master_fd, code)
                        guard_attempts += 1
                        cached_login_seen = False
                        login_output = ""
                        stage = "await_login_result"
                    continue

            while steam_prompt_handled < steam_prompt_seen:
                steam_prompt_handled += 1
                if stage == "await_initial_prompt":
                    _send_line(master_fd, f"force_install_dir {client_root}")
                    stage = "await_force_prompt"
                elif stage == "await_force_prompt":
                    _send_line(master_fd, f"login {steam_account}")
                    stage = "await_password"
                elif stage in {"await_password", "await_login_result"}:
                    if not password_sent and not guard_attempts and not cached_login_seen:
                        raise SetupError(
                            "SteamCMD requested a login result before usable credentials "
                            "were submitted; no credential file was written"
                        )
                    fail_if_login_failed()
                    _send_line(
                        master_fd,
                        f"app_update {STEAM_APP_ID} validate",
                    )
                    update_output = ""
                    stage = "await_update_prompt"
                elif stage == "await_update_prompt":
                    if any(marker in update_output for marker in _UPDATE_FAILURE_MARKERS):
                        raise SetupError(
                            "SteamCMD did not install Project Zomboid; "
                            "no credential file was written"
                        )
                    _send_line(master_fd, "quit")
                    stage = "await_exit"
                else:
                    break

        _, status = os.waitpid(pid, 0)
        if stage not in {"await_exit", "done"}:
            raise SetupError(
                "SteamCMD ended before native client setup completed; "
                "no credential file was written"
            )
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise SetupError(
                "SteamCMD exited unsuccessfully; no credential file was written"
            )
    except BaseException:
        try:
            os.write(master_fd, b"quit\n")
        except OSError:
            pass
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        raise
    finally:
        os.close(master_fd)
        for index in range(len(steam_password)):
            steam_password[index] = 0


def _client_install_roots(client_root: Path) -> tuple[Path, ...]:
    """Return Steam's possible depot roots without leaving the install tree."""
    return (
        client_root / "projectzomboid",
        client_root / "ProjectZomboid",
        client_root,
    )


def _required_client_layouts(client_root: Path) -> tuple[tuple[Path, ...], ...]:
    layouts: list[tuple[Path, ...]] = []
    for install_root in _client_install_roots(client_root):
        layouts.extend(
            (
                (
                    install_root / "ProjectZomboid64",
                    install_root / "ProjectZomboid64.json",
                    install_root / "projectzomboid.jar",
                    install_root / "pzexe.jar",
                    install_root / "jre64" / "bin" / "java",
                    install_root / "natives" / "libZNetNoSteam64.so",
                    install_root / "natives" / "libsteam_api.so",
                ),
                (
                    install_root / "ProjectZomboid64",
                    install_root / "ProjectZomboid64.json",
                    install_root / "java" / "projectzomboid.jar",
                    install_root / "linux64" / "ZNetNoSteam64.so",
                ),
            )
        )
    return tuple(layouts)


def _required_client_files(client_root: Path) -> tuple[Path, ...]:
    for layout in _required_client_layouts(client_root):
        if all(path.is_file() for path in layout):
            return layout
    return _required_client_layouts(client_root)[0]


def _verify_native_client(client_root: Path) -> None:
    missing = [path for path in _required_client_files(client_root) if not path.is_file()]
    if missing:
        raise SetupError(
            "SteamCMD completed but the native Linux client is incomplete; "
            "no credential file was written"
        )


def _shell_quote(value: str) -> str:
    if "\x00" in value or "\r" in value or "\n" in value:
        raise SetupError("credential value must be a single line")
    return shlex.quote(value)


def _secure_write_secrets(
    path: Path,
    *,
    account: ServiceAccount,
    values: dict[str, str],
) -> None:
    if not path.is_absolute() or ".." in path.parts:
        raise SetupError("secrets path must be an absolute safe path")
    directory = path.parent
    try:
        directory.mkdir(parents=True, exist_ok=True, mode=0o750)
        os.chown(directory, 0, account.gid)
        os.chmod(directory, 0o750)
        lines = [f"{key}={_shell_quote(value)}" for key, value in values.items()]
        encoded = ("\n".join(lines) + "\n").encode("utf-8")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            dir=str(directory),
        )
        temporary = Path(temporary_name)
        try:
            os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR)
            os.fchown(descriptor, account.uid, account.gid)
            with os.fdopen(descriptor, "wb") as handle:
                descriptor = -1
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            os.chown(path, account.uid, account.gid)
            os.chmod(path, 0o600)
            if hasattr(os, "O_DIRECTORY"):
                directory_fd = os.open(str(directory), os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
        finally:
            if descriptor != -1:
                os.close(descriptor)
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
    except OSError as exc:
        raise SetupError(f"could not write protected credential file: {exc}") from exc


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--steamcmd", default=os.environ.get("STEAMCMD_BIN", DEFAULT_STEAMCMD))
    parser.add_argument(
        "--client-root",
        default=os.environ.get("GOBLIN_PZ_CLIENT_ROOT", DEFAULT_CLIENT_ROOT),
    )
    parser.add_argument(
        "--secrets-file",
        default=os.environ.get("GOBLIN_SECRETS_FILE", DEFAULT_SECRETS_FILE),
    )
    parser.add_argument(
        "--service-user",
        default=os.environ.get("GOBLIN_SERVICE_USER", DEFAULT_SERVICE_USER),
    )
    parser.add_argument("--timeout", type=float, default=1800.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    if os.name != "posix":
        print("This setup command is Linux-only; Wine is not supported.", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("Run this command as root so it can create the protected secrets file.", file=sys.stderr)
        return 2
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.timeout < 60 or args.timeout > 7200:
        parser.error("--timeout must be between 60 and 7200 seconds")

    steam_password: bytearray | None = None
    steam_session_password: bytearray | None = None
    pz_password: bytearray | None = None
    try:
        service = _resolve_service_account(args.service_user)
        steam_account = _prompt_text("Steam account", DEFAULT_STEAM_ACCOUNT, 64)
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", steam_account):
            raise SetupError("Steam account is invalid")
        steam_password = _prompt_secret("Steam password")
        pz_host = _validate_host(_prompt_text("PZ server host", DEFAULT_PZ_HOST, 253))
        pz_port = _validate_port(input(f"PZ server port [{DEFAULT_PZ_PORT}]: ") or str(DEFAULT_PZ_PORT))
        pz_username = _validate_username(
            _prompt_text("PZ server username", DEFAULT_PZ_USERNAME, 32)
        )
        pz_password = _prompt_secret("PZ server password")
        if bytes(steam_password) == bytes(pz_password):
            raise SetupError("Steam and PZ passwords must be different")

        print("\nStarting native Linux SteamCMD setup. Passwords remain hidden.")
        steam_session_password = bytearray(steam_password)
        client_root = _resolve_client_root(Path(args.client_root), service)
        _run_steamcmd(
            steamcmd=Path(args.steamcmd).expanduser(),
            client_root=client_root,
            account=service,
            steam_account=steam_account,
            steam_password=steam_session_password,
            timeout_seconds=args.timeout,
        )
        _verify_native_client(client_root)
        _secure_write_secrets(
            Path(args.secrets_file).expanduser(),
            account=service,
            values={
                "STEAM_USERNAME": steam_account,
                "STEAM_PASSWORD": bytes(steam_password or b"").decode("utf-8"),
                "PZ_SERVER_HOST": pz_host,
                "PZ_SERVER_PORT": str(pz_port),
                "PZ_SERVER_USERNAME": pz_username,
                "PZ_SERVER_PASSWORD": bytes(pz_password).decode("utf-8"),
            },
        )
        print(
            f"Native client verified. Protected credentials saved at "
            f"{args.secrets_file} for service account {service.name}."
        )
        return 0
    except (SetupError, EOFError, KeyboardInterrupt) as exc:
        if isinstance(exc, KeyboardInterrupt):
            print("\nSetup cancelled; no credential file was written.", file=sys.stderr)
        else:
            print(f"Setup stopped: {exc}", file=sys.stderr)
        return 1
    finally:
        for secret in (steam_password, steam_session_password, pz_password):
            if secret is not None:
                for index in range(len(secret)):
                    secret[index] = 0


if __name__ == "__main__":
    raise SystemExit(main())

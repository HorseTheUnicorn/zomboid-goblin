#!/usr/bin/env python3
"""Securely create or update the GoblinSurvivor Steam Workshop item.

The command is Linux-only and intentionally uses the native SteamCMD client
through a PTY.  Steam credentials and Steam Guard codes are entered through
hidden prompts; they are never command-line arguments, written to a file, or
printed.  The command prepares a VDF descriptor and uploads only when the
operator explicitly runs it.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import getpass
import os
from pathlib import Path
import re
import select
import shutil
import stat
import sys
import tempfile
import time

from setup_steam import (
    DEFAULT_STEAM_ACCOUNT,
    DEFAULT_STEAMCMD,
    MAX_GUARD_ATTEMPTS,
    MAX_STEAM_OUTPUT_BUFFER,
    STEAM_APP_ID,
    SetupError,
    _ANSI_RE,
    _GUARD_PROMPT_RE,
    _LOGIN_FAILURE_MARKERS,
    _STEAM_PROMPT,
    _bounded_secret,
    _child_environment,
    _count_new_matches,
    _count_new_token,
    _drop_privileges,
    _redact,
    _resolve_client_root,
    _resolve_service_account,
    _send_line,
    _send_secret,
)


DEFAULT_REPO_ROOT = "/home/goblin/zomboid-goblin"
DEFAULT_CONTENT_FOLDER = f"{DEFAULT_REPO_ROOT}/mod"
DEFAULT_VDF = f"{DEFAULT_REPO_ROOT}/ops/native-client/goblin-workshop.vdf"
DEFAULT_CLIENT_ROOT = "/home/goblin/pz-client/game"
DEFAULT_SERVICE_USER = "goblin"
DEFAULT_CHANGE_NOTE = "Initial GoblinSurvivor Workshop package"
MAX_DESCRIPTOR_BYTES = 64 * 1024
MAX_TITLE_BYTES = 256
MAX_DESCRIPTION_BYTES = 8192
MAX_TAGS_BYTES = 1024
MAX_CHANGE_NOTE_BYTES = 1024
_ID_RE = re.compile(r"^[0-9]{1,20}$")
_ACCOUNT_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
_SUCCESS_RE = re.compile(r"success(?:\.|!|fully)", re.IGNORECASE)
_VDF_ID_RE = re.compile(r'"publishedfileid"\s+"([0-9]{1,20})"')
_VISIBILITY_VALUES = {
    "public": "0",
    "friends": "1",
    "private": "2",
    "unlisted": "3",
}


@dataclass(frozen=True)
class WorkshopMetadata:
    title: str
    description: str
    tags: str
    visibility: str


def _bounded_text(
    value: str,
    label: str,
    maximum: int,
    *,
    allow_newlines: bool = False,
) -> str:
    if not value or len(value.encode("utf-8")) > maximum:
        raise SetupError(f"{label} is empty or too long")
    allowed_controls = "\t\r\n" if allow_newlines else "\t"
    if any(ord(char) < 32 and char not in allowed_controls for char in value):
        raise SetupError(f"{label} contains a control character")
    return value


def _resolve_below(path: str | Path, root: Path, label: str, *, strict: bool) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        raise SetupError(f"{label} must be an absolute path")
    if '"' in str(candidate) or "\n" in str(candidate) or "\r" in str(candidate):
        raise SetupError(f"{label} contains unsupported characters")
    if candidate.is_symlink():
        raise SetupError(f"{label} must not be a symlink")
    try:
        resolved_root = root.resolve(strict=True)
        resolved = candidate.resolve(strict=strict)
        resolved.relative_to(resolved_root)
    except (OSError, ValueError) as exc:
        raise SetupError(f"{label} must remain below {resolved_root}") from exc
    if resolved == resolved_root:
        raise SetupError(f"{label} must be below the repository root")
    return resolved


def _read_workshop_metadata(path: Path) -> WorkshopMetadata:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SetupError(f"could not read Workshop descriptor: {path}") from exc
    if len(raw.encode("utf-8")) > MAX_DESCRIPTOR_BYTES:
        raise SetupError("Workshop descriptor is too large")

    values: dict[str, str] = {}
    descriptions: list[str] = []
    for number, line in enumerate(raw.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in {
            "version",
            "id",
            "title",
            "description",
            "tags",
            "visibility",
        }:
            raise SetupError(f"invalid Workshop descriptor line {number}")
        value = value.strip()
        if key == "description":
            if value:
                descriptions.append(
                    _bounded_text(value, "Workshop description", MAX_DESCRIPTION_BYTES)
                )
        elif key == "id":
            if value and not _ID_RE.fullmatch(value):
                raise SetupError("Workshop descriptor id is invalid")
        else:
            values[key] = value

    if values.get("version") != "1":
        raise SetupError("Workshop descriptor must declare version=1")
    title = _bounded_text(values.get("title", ""), "Workshop title", MAX_TITLE_BYTES)
    description = "\n".join(descriptions)
    description = _bounded_text(
        description,
        "Workshop description",
        MAX_DESCRIPTION_BYTES,
        allow_newlines=True,
    )
    tags = _bounded_text(values.get("tags", ""), "Workshop tags", MAX_TAGS_BYTES) if values.get("tags") else ""
    visibility = values.get("visibility", "unlisted").lower()
    if visibility not in _VISIBILITY_VALUES:
        raise SetupError("Workshop visibility must be public, friends, private, or unlisted")
    return WorkshopMetadata(title, description, tags, visibility)


def _existing_published_file_id(path: Path) -> str:
    if not path.exists():
        return "0"
    if path.is_symlink():
        raise SetupError("Workshop VDF must not be a symlink")
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SetupError("could not read the existing Workshop VDF") from exc
    match = _VDF_ID_RE.search(raw)
    if not match:
        return "0"
    published_id = match.group(1)
    if not _ID_RE.fullmatch(published_id):
        raise SetupError("existing Workshop ID is invalid")
    return published_id


def _vdf_quote(
    value: str,
    label: str,
    maximum: int,
    *,
    allow_newlines: bool = False,
) -> str:
    value = _bounded_text(value, label, maximum, allow_newlines=allow_newlines)
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )


def _build_vdf(
    *,
    content_folder: Path,
    metadata: WorkshopMetadata,
    published_file_id: str,
    visibility: str,
    change_note: str,
    preview_file: Path | None,
) -> str:
    if not _ID_RE.fullmatch(published_file_id):
        raise SetupError("published Workshop ID is invalid")
    if visibility not in _VISIBILITY_VALUES:
        raise SetupError("Workshop visibility is invalid")
    lines = [
        '"workshopitem"',
        "{",
        f'    "appid" "{STEAM_APP_ID}"',
        f'    "publishedfileid" "{published_file_id}"',
        f'    "contentfolder" "{_vdf_quote(str(content_folder), "content folder", 4096)}"',
        f'    "visibility" "{_VISIBILITY_VALUES[visibility]}"',
        f'    "title" "{_vdf_quote(metadata.title, "Workshop title", MAX_TITLE_BYTES)}"',
        f'    "description" "{_vdf_quote(metadata.description, "Workshop description", MAX_DESCRIPTION_BYTES, allow_newlines=True)}"',
        f'    "changenote" "{_vdf_quote(change_note, "change note", MAX_CHANGE_NOTE_BYTES)}"',
    ]
    if metadata.tags:
        lines.append(f'    "tags" "{_vdf_quote(metadata.tags, "Workshop tags", MAX_TAGS_BYTES)}"')
    if preview_file is not None:
        lines.append(f'    "previewfile" "{_vdf_quote(str(preview_file), "preview file", 4096)}"')
    lines.extend(("}", ""))
    return "\n".join(lines)


def _write_protected_vdf(path: Path, contents: str, *, uid: int, gid: int) -> None:
    if path.exists() and path.is_symlink():
        raise SetupError("Workshop VDF must not be a symlink")
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chown(path.parent, uid, gid)
    os.chmod(path.parent, 0o750)
    descriptor = -1
    temporary: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
        temporary = Path(temporary_name)
        os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR)
        os.fchown(descriptor, uid, gid)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chown(path, uid, gid)
        os.chmod(path, 0o600)
    except OSError as exc:
        raise SetupError("could not write the Workshop VDF") from exc
    finally:
        if descriptor != -1:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def _find_mod_root(content_folder: Path) -> Path:
    """Find the PZ authoring/downloaded mod root in a Workshop tree."""
    candidates = (
        content_folder / "Contents" / "mods",
        content_folder / "mods",
    )
    for candidate in candidates:
        mod_info = candidate / "GoblinSurvivor" / "42" / "mod.info"
        if mod_info.is_file():
            return candidate
    raise SetupError("content folder is missing the GoblinSurvivor 42 mod")


def _validate_content(content_folder: Path) -> tuple[Path, WorkshopMetadata]:
    if not content_folder.is_dir():
        raise SetupError("Workshop content folder is not a directory")
    descriptor = content_folder / "workshop.txt"
    if not descriptor.is_file():
        raise SetupError("content folder is missing the PZ Workshop descriptor or GoblinSurvivor mod")
    _find_mod_root(content_folder)
    for path in content_folder.rglob("*"):
        if path.is_symlink():
            raise SetupError(f"Workshop content contains a symlink: {path.name}")
        if path.name in {".env", "secrets.env"} or path.name.endswith((".key", ".pem")):
            raise SetupError("Workshop content contains a credential-like file")
    return descriptor, _read_workshop_metadata(descriptor)


def _set_upload_tree_access(path: Path, *, uid: int | None, gid: int | None) -> None:
    """Make a temporary upload tree readable by the unprivileged SteamCMD user."""
    entries = (path, *path.rglob("*"))
    for entry in entries:
        if entry.is_symlink():
            raise SetupError(f"temporary Workshop content contains a symlink: {entry.name}")
        try:
            if uid is not None and gid is not None and hasattr(os, "chown"):
                os.chown(entry, uid, gid)
            os.chmod(entry, 0o750 if entry.is_dir() else 0o640)
        except OSError as exc:
            raise SetupError("could not secure the temporary Workshop upload tree") from exc


def _prepare_upload_content(
    content_folder: Path,
    repo_root: Path,
    *,
    uid: int | None = None,
    gid: int | None = None,
) -> Path:
    """Build the raw SteamCMD payload from the PZ authoring tree.

    PZ authoring trees conventionally use Contents/mods, while the raw
    Workshop payload consumed from Steam's 108600 cache uses mods at the item
    root. SteamCMD uploads the VDF's contentfolder verbatim, so normalize the
    layout here without changing the checked-in authoring tree.
    """
    mod_root = _find_mod_root(content_folder)
    temporary = Path(tempfile.mkdtemp(prefix=".goblin-workshop-upload-", dir=str(repo_root)))
    try:
        shutil.copy2(content_folder / "workshop.txt", temporary / "workshop.txt")
        shutil.copytree(mod_root, temporary / "mods", symlinks=False)
        _set_upload_tree_access(temporary, uid=uid, gid=gid)
        return temporary
    except (OSError, SetupError) as exc:
        shutil.rmtree(temporary, ignore_errors=True)
        if isinstance(exc, SetupError):
            raise
        raise SetupError("could not prepare the temporary Workshop upload tree") from exc


def _steam_path(path: Path) -> str:
    value = str(path)
    if any(char in value for char in '"\r\n'):
        raise SetupError("SteamCMD path contains unsupported characters")
    return value


def _run_steamcmd(
    *,
    steamcmd: Path,
    client_root: Path,
    vdf_path: Path,
    account: str,
    password: bytearray,
    service,
    timeout_seconds: float,
) -> None:
    if not steamcmd.is_file() or not os.access(steamcmd, os.X_OK):
        raise SetupError(f"SteamCMD is not executable: {steamcmd}")
    import pty
    import termios

    pid, master_fd = pty.fork()
    if pid == 0:
        try:
            attributes = termios.tcgetattr(0)
            attributes[3] &= ~(termios.ECHO | termios.ECHONL)
            termios.tcsetattr(0, termios.TCSANOW, attributes)
            _drop_privileges(service)
            os.chdir(service.home)
            os.execve(str(steamcmd), [str(steamcmd)], _child_environment(service))
        except BaseException:
            os._exit(127)

    output = ""
    login_output = ""
    build_output = ""
    stage = "initial"
    password_sent = False
    cached_login_seen = False
    guard_attempts = 0
    redactions = [account, bytes(password).decode("utf-8", errors="replace")]
    steam_prompt_seen = 0
    steam_prompt_handled = 0
    steam_scan_tail = ""
    guard_prompt_seen = 0
    guard_prompt_handled = 0
    guard_scan_tail = ""
    started = time.monotonic()

    def fail_if_login_failed() -> None:
        if any(marker in login_output[-2048:] for marker in _LOGIN_FAILURE_MARKERS):
            raise SetupError("SteamCMD login failed; no Workshop item was changed")

    try:
        os.set_blocking(master_fd, False)
        while True:
            if time.monotonic() - started > timeout_seconds:
                raise SetupError("SteamCMD timed out; no Workshop item was changed")
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
            output = (output + decoded)[-MAX_STEAM_OUTPUT_BUFFER:]
            clean = _ANSI_RE.sub("", decoded)
            sys.stdout.write(_redact(decoded, redactions))
            sys.stdout.flush()

            lower = clean.lower()
            steam_scan_text = steam_scan_tail + lower
            steam_boundary = len(steam_scan_tail)
            steam_prompt_seen += _count_new_token(steam_scan_text, steam_boundary, _STEAM_PROMPT)
            steam_scan_tail = steam_scan_text[-128:]
            guard_scan_text = guard_scan_tail + lower
            guard_boundary = len(guard_scan_tail)
            guard_prompt_seen += _count_new_matches(_GUARD_PROMPT_RE, guard_scan_text, guard_boundary)
            guard_scan_tail = guard_scan_text[-128:]

            if stage in {"password", "login"}:
                login_output = (login_output + lower)[-MAX_STEAM_OUTPUT_BUFFER:]
                if "logging in using cached credentials" in login_output:
                    cached_login_seen = True
            if stage == "build":
                build_output = (build_output + lower)[-MAX_STEAM_OUTPUT_BUFFER:]

            if stage == "password" and not password_sent and "password" in output[-2048:].lower():
                _send_secret(master_fd, password)
                password_sent = True
                stage = "login"
                login_output = ""
                continue

            if stage in {"password", "login"} and guard_prompt_seen > guard_prompt_handled:
                while guard_prompt_handled < guard_prompt_seen:
                    guard_prompt_handled += 1
                    if guard_attempts >= MAX_GUARD_ATTEMPTS:
                        raise SetupError("Steam Guard authorization failed; no Workshop item was changed")
                    prompt = "Steam Guard code" if guard_attempts == 0 else "Newest Steam Guard code"
                    print(f"\n{prompt} (hidden): ", end="", flush=True)
                    code = _bounded_secret(getpass.getpass(""), "Steam Guard code")
                    redactions.append(bytes(code).decode("utf-8", errors="ignore"))
                    _send_secret(master_fd, code)
                    guard_attempts += 1
                    cached_login_seen = False
                    login_output = ""
                    stage = "login"
                continue

            while steam_prompt_handled < steam_prompt_seen:
                steam_prompt_handled += 1
                if stage == "initial":
                    _send_line(master_fd, f"force_install_dir {_steam_path(client_root)}")
                    stage = "force"
                elif stage == "force":
                    _send_line(master_fd, f"login {account}")
                    stage = "password"
                elif stage in {"password", "login"}:
                    if not password_sent and not guard_attempts and not cached_login_seen:
                        raise SetupError("SteamCMD requested a login result before authentication")
                    fail_if_login_failed()
                    _send_line(master_fd, f"workshop_build_item {_steam_path(vdf_path)}")
                    build_output = ""
                    stage = "build"
                elif stage == "build":
                    _send_line(master_fd, "quit")
                    stage = "exit"
                else:
                    break

        _, status = os.waitpid(pid, 0)
        if stage != "exit":
            raise SetupError("SteamCMD ended before the Workshop upload completed")
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise SetupError("SteamCMD exited unsuccessfully; no Workshop item was changed")
        if not _SUCCESS_RE.search(build_output):
            raise SetupError("SteamCMD did not confirm a successful Workshop update")
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
        for index in range(len(password)):
            password[index] = 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=DEFAULT_REPO_ROOT)
    parser.add_argument("--content-folder", default=DEFAULT_CONTENT_FOLDER)
    parser.add_argument("--vdf", default=DEFAULT_VDF)
    parser.add_argument("--steamcmd", default=DEFAULT_STEAMCMD)
    parser.add_argument("--client-root", default=DEFAULT_CLIENT_ROOT)
    parser.add_argument("--service-user", default=DEFAULT_SERVICE_USER)
    parser.add_argument("--steam-account", default=DEFAULT_STEAM_ACCOUNT)
    parser.add_argument("--visibility", choices=tuple(_VISIBILITY_VALUES), default=None)
    parser.add_argument("--change-note", default=DEFAULT_CHANGE_NOTE)
    parser.add_argument("--preview-file")
    parser.add_argument("--timeout", type=float, default=1800.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    if os.name != "posix":
        print("This Workshop publisher is Linux-only; Wine is not supported.", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("Run this command as root so SteamCMD can drop to the goblin account.", file=sys.stderr)
        return 2
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.timeout < 60 or args.timeout > 7200:
        parser.error("--timeout must be between 60 and 7200 seconds")

    password: bytearray | None = None
    try:
        service = _resolve_service_account(args.service_user)
        repo_root = Path(args.repo_root).expanduser().resolve(strict=True)
        content_folder = _resolve_below(args.content_folder, repo_root, "content folder", strict=True)
        vdf_path = _resolve_below(args.vdf, repo_root, "Workshop VDF", strict=False)
        descriptor, metadata = _validate_content(content_folder)
        visibility = args.visibility or metadata.visibility
        preview_file = None
        if args.preview_file:
            preview_file = _resolve_below(args.preview_file, content_folder, "preview file", strict=True)
            if not preview_file.is_file():
                raise SetupError("preview file is not a regular file")
        elif (content_folder / "preview.png").is_file():
            preview_file = content_folder / "preview.png"

        client_root = _resolve_client_root(Path(args.client_root), service)
        published_file_id = _existing_published_file_id(vdf_path)
        upload_content_folder = _prepare_upload_content(
            content_folder,
            repo_root,
            uid=service.uid,
            gid=service.gid,
        )
        try:
            vdf = _build_vdf(
                content_folder=upload_content_folder,
                metadata=metadata,
                published_file_id=published_file_id,
                visibility=visibility,
                change_note=args.change_note,
                preview_file=preview_file,
            )
            _write_protected_vdf(vdf_path, vdf, uid=service.uid, gid=service.gid)

            print("GoblinSurvivor Workshop upload")
            print(f"  source content: {content_folder}")
            print("  upload layout: root-level mods/")
            print(f"  visibility: {visibility}")
            print(f"  existing item: {published_file_id if published_file_id != '0' else 'new item'}")
            print(f"  descriptor: {descriptor}")
            if not _ACCOUNT_RE.fullmatch(args.steam_account):
                raise SetupError("Steam account is invalid")
            password = _bounded_secret(getpass.getpass("Steam password (hidden): "), "Steam password")
            _run_steamcmd(
                steamcmd=Path(args.steamcmd).expanduser().resolve(strict=True),
                client_root=client_root,
                vdf_path=vdf_path,
                account=args.steam_account,
                password=password,
                service=service,
                timeout_seconds=args.timeout,
            )
            published_file_id = _existing_published_file_id(vdf_path)
            if published_file_id == "0":
                raise SetupError("SteamCMD completed without returning a Workshop item ID")
            print(f"Workshop item ready: {published_file_id}")
            print(f"Workshop URL: https://steamcommunity.com/sharedfiles/filedetails/?id={published_file_id}")
            return 0
        finally:
            shutil.rmtree(upload_content_folder, ignore_errors=True)
    except (SetupError, EOFError, KeyboardInterrupt) as exc:
        message = "upload cancelled" if isinstance(exc, KeyboardInterrupt) else str(exc)
        print(f"Workshop upload stopped: {message}", file=sys.stderr)
        return 1
    finally:
        if password is not None:
            for index in range(len(password)):
                password[index] = 0


if __name__ == "__main__":
    raise SystemExit(main())

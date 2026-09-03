"""Fail-closed Build 42 server/client mod-parity verification."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from collections.abc import Mapping
from pathlib import Path
import re
from typing import Any


MOD_PARITY_STATUSES = frozenset({"verified", "missing", "mismatch", "invalid"})
_MANIFEST_KEYS = frozenset(
    {"game_build", "mods", "workshop_items", "goblin_survivor_sha256"}
)
_BUILD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\- ]{0,63}$")
_MOD_ID_RE = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._:=-]*(?: [A-Za-z0-9._:=-]+){0,15}$"
)
_WORKSHOP_ID_RE = re.compile(r"^[0-9]{1,20}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ModParityError(ValueError):
    """Raised when a server/client mod manifest is malformed or unsafe."""


def _text(value: Any, *, field: str, maximum: int) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ModParityError(f"{field} must be non-empty bounded text")
    if any(ord(char) < 32 for char in value):
        raise ModParityError(f"{field} contains a control character")
    return value


def _ordered_ids(
    value: Any,
    *,
    field: str,
    pattern: re.Pattern[str],
    maximum: int,
) -> tuple[str, ...]:
    if not isinstance(value, list) or len(value) > maximum:
        raise ModParityError(f"{field} must be a bounded ordered list")
    result: list[str] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, str) or not pattern.fullmatch(item):
            raise ModParityError(f"{field} contains an invalid identifier")
        folded = item.casefold()
        if folded in seen:
            raise ModParityError(f"{field} contains a duplicate identifier")
        seen.add(folded)
        result.append(item)
    return tuple(result)


@dataclass(frozen=True)
class ModManifest:
    """The exact ordered Build 42 loadout required by the multiplayer client."""

    game_build: str
    mods: tuple[str, ...]
    workshop_items: tuple[str, ...]
    goblin_survivor_sha256: str

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "ModManifest":
        if not isinstance(raw, Mapping):
            raise ModParityError("mod manifest must be an object")
        if set(raw) != _MANIFEST_KEYS:
            raise ModParityError("mod manifest has an unexpected schema")
        game_build = _text(raw["game_build"], field="game_build", maximum=64)
        if not _BUILD_RE.fullmatch(game_build):
            raise ModParityError("game_build contains unsafe characters")
        mods = _ordered_ids(
            raw["mods"],
            field="mods",
            pattern=_MOD_ID_RE,
            maximum=4096,
        )
        if "GoblinSurvivor" not in mods:
            raise ModParityError("mods must include GoblinSurvivor")
        workshop_items = _ordered_ids(
            raw["workshop_items"],
            field="workshop_items",
            pattern=_WORKSHOP_ID_RE,
            maximum=4096,
        )
        digest = raw["goblin_survivor_sha256"]
        if not isinstance(digest, str) or not _SHA256_RE.fullmatch(digest):
            raise ModParityError("goblin_survivor_sha256 must be lowercase SHA-256")
        return cls(game_build, mods, workshop_items, digest)

    def as_dict(self) -> dict[str, Any]:
        return {
            "game_build": self.game_build,
            "mods": list(self.mods),
            "workshop_items": list(self.workshop_items),
            "goblin_survivor_sha256": self.goblin_survivor_sha256,
        }


@dataclass(frozen=True)
class ModParityResult:
    status: str
    reasons: tuple[str, ...]

    def __post_init__(self) -> None:
        if self.status not in MOD_PARITY_STATUSES:
            raise ValueError("unknown mod parity status")

    @property
    def verified(self) -> bool:
        return self.status == "verified"

    def as_dict(self) -> dict[str, Any]:
        return {"status": self.status, "reasons": list(self.reasons)}


class ModParityValidator:
    """Compares the server contract and the actual client report exactly."""

    @staticmethod
    def compare(
        server: ModManifest,
        client: ModManifest,
    ) -> ModParityResult:
        reasons: list[str] = []
        if server.game_build != client.game_build:
            reasons.append("game build differs")
        if server.mods != client.mods:
            reasons.append("ordered Mods loadout differs")
        if server.workshop_items != client.workshop_items:
            reasons.append("ordered WorkshopItems loadout differs")
        if server.goblin_survivor_sha256 != client.goblin_survivor_sha256:
            reasons.append("GoblinSurvivor content hash differs")
        if reasons:
            return ModParityResult("mismatch", tuple(reasons))
        return ModParityResult("verified", ("server and client manifests match",))

    @staticmethod
    def control_compatible(
        server: ModManifest,
        client: ModManifest,
    ) -> bool:
        """Return whether the native body is safe to control.

        Project Zomboid owns the ordinary multiplayer loadout handshake.  The
        Goblin bridge therefore does not need to reconstruct and compare every
        server ``Mods=`` and ``WorkshopItems=`` entry.  It does still require
        the same game build, the same GoblinSurvivor content, and an explicit
        GoblinSurvivor entry in the client's active mod list.

        ``compare`` remains available as a diagnostic for an exact loadout
        audit; this smaller compatibility contract is the execution gate.
        """

        if server.game_build != client.game_build:
            return False
        if server.goblin_survivor_sha256 != client.goblin_survivor_sha256:
            return False
        return "GoblinSurvivor" in client.mods

    @classmethod
    def control_compatible_from_runtime(cls, fields: Mapping[str, Any]) -> bool:
        """Evaluate the execution contract from actual runtime manifests."""

        if not isinstance(fields, Mapping):
            return False
        server_raw = fields.get("server_mod_manifest")
        client_raw = fields.get("client_mod_manifest")
        if server_raw is None or client_raw is None:
            return False
        try:
            server = ModManifest.from_mapping(server_raw)
            client = ModManifest.from_mapping(client_raw)
        except ModParityError:
            return False
        return cls.control_compatible(server, client)

    @classmethod
    def from_runtime(cls, fields: Mapping[str, Any]) -> ModParityResult:
        """Evaluate runtime manifests without trusting a claimed status field."""

        if not isinstance(fields, Mapping):
            return ModParityResult("invalid", ("runtime state is not an object",))
        server_raw = fields.get("server_mod_manifest")
        client_raw = fields.get("client_mod_manifest")
        if server_raw is None or client_raw is None:
            return ModParityResult(
                "missing",
                ("server_mod_manifest and client_mod_manifest are required",),
            )
        try:
            server = ModManifest.from_mapping(server_raw)
            client = ModManifest.from_mapping(client_raw)
        except ModParityError as exc:
            return ModParityResult("invalid", (str(exc),))
        return cls.compare(server, client)


def hash_tree(root: str | Path) -> str:
    """Hash a mod tree deterministically, including relative paths and bytes."""

    base = Path(root)
    if not base.is_dir():
        raise FileNotFoundError(base)
    digest = hashlib.sha256()
    files = sorted(
        (
            path.relative_to(base).as_posix(),
            path,
        )
        for path in base.rglob("*")
        if path.is_file()
    )
    for relative, path in files:
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def encode_manifest(manifest: ModManifest) -> bytes:
    """Return canonical JSON suitable for signing or storing as an artifact."""

    return json.dumps(
        manifest.as_dict(),
        ensure_ascii=True,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")

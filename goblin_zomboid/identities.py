"""Stable logical identities used at the Qwen/server boundary.

Native PZ usernames are a transport concern.  The model receives the
canonical ``player.<safe-name>`` form so a reconnect or a different native
object cannot change the identity it is reasoning about.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Any


_SAFE_NAME_RE = re.compile(r"[^a-z0-9._:-]+")
MAX_ENTITY_ID = 96


def player_entity_id(value: Any) -> str | None:
    """Return a bounded, deterministic logical player id.

    The helper accepts either a native username, a logical id, or a roster
    object containing ``id``/``player``/``name``.  It never returns a raw
    coordinate or object reference.
    """

    if isinstance(value, Mapping):
        value = value.get("id", value.get("player", value.get("name")))
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value:
        return None
    if value.casefold().startswith("player."):
        value = value[7:]
    safe = _SAFE_NAME_RE.sub("_", value.casefold()).strip("._:-")
    if not safe:
        return None
    return ("player." + safe)[:MAX_ENTITY_ID]


def native_player_name(value: Any) -> str | None:
    """Extract a safe native username from a logical or roster value."""

    if isinstance(value, Mapping):
        value = value.get("name", value.get("player", value.get("id")))
    if not isinstance(value, str):
        return None
    value = value.strip()
    if value.casefold().startswith("player."):
        # A logical id is intentionally not reversible; the Lua resolver
        # performs the authoritative online-name lookup.
        return None
    if not value or len(value) > MAX_ENTITY_ID:
        return None
    if re.fullmatch(r"[A-Za-z0-9_-]+", value) is None:
        return None
    return value


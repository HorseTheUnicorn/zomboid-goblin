"""Views that prevent exact world locations from reaching unsafe consumers."""

from __future__ import annotations

from collections.abc import Mapping
from copy import deepcopy
import re
from typing import Any

_DROP_KEYS = {
    "x",
    "y",
    "z",
    "coord",
    "coords",
    "coordinates",
    "route",
    "routes",
    "waypoint",
    "waypoints",
    "cell",
    "chunk",
    "building_id",
    "raw_packet",
    "packet",
    "exact_distance",
    "distance",
    "location",
    "exact_location",
}
_DROP_RE = re.compile(
    r"(?:^|_)(?:x|y|z)$|(?:^|_)(?:coord|coords|coordinate|route|waypoint|cell|chunk)(?:_|$)"
)


def _is_sensitive_key(key: str) -> bool:
    normalized = key.casefold().replace("-", "_")
    return (
        normalized in _DROP_KEYS
        or normalized.startswith(("coord", "coordinate"))
        or bool(_DROP_RE.search(normalized))
    )


def _redact(value: Any) -> Any:
    if isinstance(value, Mapping):
        clean: dict[str, Any] = {}
        for key, nested in value.items():
            if isinstance(key, str) and _is_sensitive_key(key):
                continue
            clean[key] = _redact(nested)
        return clean
    if isinstance(value, list):
        return [_redact(nested) for nested in value]
    if isinstance(value, tuple):
        return [_redact(nested) for nested in value]
    return value


def brain_view(state: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(state, Mapping):
        raise TypeError("state must be an object")
    return _redact(deepcopy(dict(state)))


def public_view(state: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(state, Mapping):
        raise TypeError("state must be an object")
    allowed = ("alive", "hunt_active", "prize_tier")
    result: dict[str, Any] = {}
    for key in allowed:
        if key in state and isinstance(state[key], (bool, int, float, str, type(None))):
            result[key] = state[key]
    return result


def admin_view(state: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(state, Mapping):
        raise TypeError("state must be an object")
    return deepcopy(dict(state))

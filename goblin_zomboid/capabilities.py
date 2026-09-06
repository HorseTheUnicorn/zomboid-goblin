"""High-level actions the current server executor actually implements."""

from __future__ import annotations


IMPLEMENTED_CAPABILITIES: tuple[str, ...] = (
    "NOOP",
    "SAY",
    "FOLLOW_PLAYER",
    "FOLLOW_GOBLIN",
    "HOLD",
    "REGROUP",
    "RETURN_HOME",
    "DEFEND_PLAYER",
    "RETREAT",
    "LOOT_AREA",
    "SCAVENGE_AREA",
    "FORM_SQUAD",
    "DISMISS_SQUAD",
    "ASSIGN_JOB",
    "SECURE_BASE",
)


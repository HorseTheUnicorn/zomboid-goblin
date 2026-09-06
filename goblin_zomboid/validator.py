"""Strict high-level intent validation at the model boundary."""

from __future__ import annotations

from dataclasses import dataclass
import json
import re
from collections.abc import Mapping
from typing import Any

MAX_INTENT_BYTES = 16 * 1024
MODES = {"SAFE", "ROAM", "PARTY", "HUNT"}
INTENTS = {
    "WAIT", "SAY", "MOVE_TO", "FOLLOW", "FOLLOW_GOBLIN", "HOLD_POSITION",
    "REGROUP", "SEARCH", "SCAVENGE", "LOOT_AREA", "RETREAT", "REST", "GO_HOME",
    "JOIN_PARTY", "LEAVE_PARTY", "MELEE_ATTACK", "FORM_SQUAD", "DISMISS_SQUAD", "ASSIGN_JOB",
    "SECURE_BASE", "RETURN_TO_BASE", "CLEAR_BUILDING", "ATTACK", "DEFEND_PLAYER",
    "DEFEND_AREA", "GUARD", "PATROL", "FLEE", "ENTER_VEHICLE", "EXIT_VEHICLE",
    "HUNT_START", "HUNT_HINT", "HUNT_RELOCATE", "HUNT_REWARD", "TRADE", "HELP",
}
COMMAND_ACTIONS = {
    "NOOP", "SAY", "FOLLOW_PLAYER", "FOLLOW_GOBLIN", "HOLD", "REGROUP",
    "RETURN_HOME", "DEFEND_PLAYER", "RETREAT", "LOOT_AREA", "SCAVENGE_AREA",
    "FORM_SQUAD", "DISMISS_SQUAD", "ASSIGN_JOB", "SECURE_BASE",
}
MODE_ALLOWED = {
    "SAFE": INTENTS - {"MOVE_TO", "FOLLOW", "FOLLOW_GOBLIN", "SEARCH", "SCAVENGE", "LOOT_AREA", "ATTACK", "MELEE_ATTACK", "DEFEND_PLAYER", "DEFEND_AREA", "GUARD", "PATROL", "FORM_SQUAD", "ENTER_VEHICLE", "CLEAR_BUILDING"},
    "ROAM": INTENTS - {"JOIN_PARTY", "LEAVE_PARTY", "FORM_SQUAD", "DISMISS_SQUAD", "ASSIGN_JOB", "SECURE_BASE", "DEFEND_PLAYER", "DEFEND_AREA", "GUARD", "PATROL", "ENTER_VEHICLE", "EXIT_VEHICLE"},
    "PARTY": INTENTS - {"SECURE_BASE", "PATROL", "GUARD"},
    "HUNT": INTENTS - {"JOIN_PARTY", "LEAVE_PARTY", "FORM_SQUAD", "DISMISS_SQUAD", "ASSIGN_JOB", "SECURE_BASE", "GUARD", "PATROL"},
}
TARGET_KINDS = {
    "nearby_building", "named_location", "area", "player", "home_base", "escape_route",
    "candidate", "current_position", "nearby_threat", "goblin", "squad", "base", "vehicle", "job",
}
ALLOWED_KEYS = {
    "intent", "mode", "text", "priority", "abort_if", "target", "item", "candidate", "loot_focus",
    "npc_id", "leader", "requested_members", "members", "job", "formation", "squad_id", "zone", "mission",
}
TARGET_KEYS = {"kind", "name", "player", "label"}
ITEM_KEYS = {"name", "category", "count"}
CANDIDATE_KEYS = {"kind", "label", "clue"}
FORBIDDEN_KEYS = {
    "code", "command", "eval", "exec", "lua", "shell", "script", "raw", "raw_packet", "packet",
    "x", "y", "z", "cell", "chunk", "building_id", "teleport", "path", "paths", "absolute_path",
}
TEXT_COORDINATE_RE = re.compile(
    r"(?:\bcoordinates?\b|\b(?:x|y|z)\s*[:=]|\bcell\s*[:=]|\bchunk\s*[:=])",
    re.IGNORECASE,
)
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
ENTITY_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$")


class IntentError(ValueError):
    """Raised when an intent violates the safe command schema."""


@dataclass(frozen=True)
class ValidatedIntent:
    intent: str
    mode: str
    data: dict[str, Any]


@dataclass(frozen=True)
class ValidatedPlan:
    """A bounded Qwen response containing speech and up to four commands."""

    say: str | None
    commands: tuple[ValidatedIntent, ...]


def _scan_forbidden(value: Any, path: str = "$") -> None:
    if isinstance(value, Mapping):
        for key, nested in value.items():
            if not isinstance(key, str):
                raise IntentError(f"non-string key at {path}")
            normalized = key.casefold().replace("-", "_")
            if normalized in FORBIDDEN_KEYS:
                raise IntentError(f"forbidden field at {path}.{key}")
            _scan_forbidden(nested, f"{path}.{key}")
    elif isinstance(value, list):
        if len(value) > 16:
            raise IntentError(f"list is too long at {path}")
        for index, nested in enumerate(value):
            _scan_forbidden(nested, f"{path}[{index}]")


def _text(value: Any, field: str, *, maximum: int) -> str:
    if not isinstance(value, str):
        raise IntentError(f"{field} must be text")
    value = value.strip()
    if not value or len(value) > maximum or CONTROL_RE.search(value):
        raise IntentError(f"invalid {field}")
    if TEXT_COORDINATE_RE.search(value):
        raise IntentError(f"{field} contains location coordinates")
    return value


def _id(value: Any, field: str) -> str:
    value = _text(value, field, maximum=96)
    if ENTITY_ID_RE.fullmatch(value) is None:
        raise IntentError(f"invalid {field}")
    return value


def _object(value: Any, field: str, allowed: set[str]) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise IntentError(f"{field} must be an object")
    unknown = set(value).difference(allowed)
    if unknown:
        raise IntentError(f"unknown {field} field: {sorted(unknown)[0]}")
    return dict(value)


def _target(value: Any, field: str = "target") -> dict[str, str]:
    raw = _object(value, field, TARGET_KEYS)
    kind = _text(raw.get("kind"), f"{field}.kind", maximum=32).casefold()
    if kind not in TARGET_KINDS:
        raise IntentError(f"unsupported {field} kind")
    result: dict[str, str] = {"kind": kind}
    label_key = "player" if kind == "player" else "name"
    if label_key in raw:
        result[label_key] = _text(raw[label_key], f"{field}.{label_key}", maximum=96)
    elif "label" in raw:
        result["label"] = _text(raw["label"], f"{field}.label", maximum=96)
    else:
        raise IntentError(f"{field} needs a safe label")
    return result


def _item(value: Any) -> dict[str, Any]:
    raw = _object(value, "item", ITEM_KEYS)
    result: dict[str, Any] = {}
    if "name" in raw:
        result["name"] = _text(raw["name"], "item.name", maximum=64)
    if "category" in raw:
        result["category"] = _text(raw["category"], "item.category", maximum=32)
    if "count" in raw:
        count = raw["count"]
        if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= 10:
            raise IntentError("item.count must be between 1 and 10")
        result["count"] = count
    if not result:
        raise IntentError("item cannot be empty")
    return result


def _candidate(value: Any) -> dict[str, str]:
    raw = _object(value, "candidate", CANDIDATE_KEYS)
    kind = _text(raw.get("kind"), "candidate.kind", maximum=32).casefold()
    if kind not in {"nearby_building", "area", "named_location", "candidate"}:
        raise IntentError("candidate has an unsafe kind")
    result = {"kind": kind, "label": _text(raw.get("label"), "candidate.label", maximum=96)}
    if "clue" in raw:
        result["clue"] = _text(raw["clue"], "candidate.clue", maximum=160)
    return result


def _id_list(value: Any, field: str) -> list[str]:
    if not isinstance(value, list) or not value or len(value) > 16:
        raise IntentError(f"{field} must contain 1 to 16 ids")
    return [_id(item, f"{field} item") for item in value]


def _member_request(value: Any, field: str) -> int | list[str]:
    # A commander can ask for a bounded number of additional NPCs without
    # needing to know native entity ids. The deterministic squad manager
    # resolves that count to actual available NPCs.
    if field.endswith("requested_members") and isinstance(value, int) and not isinstance(value, bool):
        if not 1 <= value <= 15:
            raise IntentError("requested_members count must be between 1 and 15")
        return value
    return _id_list(value, field)


class IntentValidator:
    def __init__(self, *, max_bytes: int = MAX_INTENT_BYTES) -> None:
        self.max_bytes = max_bytes

    def validate_json(self, raw_json: str | bytes) -> ValidatedIntent:
        if isinstance(raw_json, str):
            encoded = raw_json.encode("utf-8")
        elif isinstance(raw_json, bytes):
            encoded = raw_json
        else:
            raise IntentError("intent must be JSON text")
        if len(encoded) > self.max_bytes:
            raise IntentError("intent exceeds the size limit")

        def reject_constant(value: str) -> None:
            raise IntentError(f"non-finite JSON value: {value}")

        try:
            raw = json.loads(encoded.decode("utf-8"), parse_constant=reject_constant)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise IntentError("invalid JSON intent") from exc
        return self.validate(raw)

    def validate(self, raw: Any) -> ValidatedIntent:
        if not isinstance(raw, Mapping):
            raise IntentError("intent must be an object")
        _scan_forbidden(raw)
        unknown = set(raw).difference(ALLOWED_KEYS)
        if unknown:
            raise IntentError(f"unknown intent field: {sorted(unknown)[0]}")
        intent = _text(raw.get("intent"), "intent", maximum=32).upper()
        mode = _text(raw.get("mode"), "mode", maximum=16).upper()
        if intent not in INTENTS:
            raise IntentError("unsupported intent")
        if mode not in MODES:
            raise IntentError("unsupported mode")
        if intent not in MODE_ALLOWED[mode]:
            raise IntentError(f"{intent} is not allowed in {mode}")

        result: dict[str, Any] = {"intent": intent, "mode": mode}
        if "text" in raw:
            result["text"] = _text(raw["text"], "text", maximum=240)
        if intent == "SAY" and "text" not in result:
            raise IntentError("SAY requires text")
        if intent == "SAY" and "target" in raw:
            raise IntentError("SAY does not accept a target")
        priority = raw.get("priority", 1)
        if isinstance(priority, bool) or not isinstance(priority, int) or not 0 <= priority <= 3:
            raise IntentError("priority must be between 0 and 3")
        result["priority"] = priority
        if "abort_if" in raw:
            abort_if = raw["abort_if"]
            if not isinstance(abort_if, list) or not abort_if or len(abort_if) > 8:
                raise IntentError("abort_if must be a short non-empty list")
            result["abort_if"] = [_text(condition, "abort_if item", maximum=80) for condition in abort_if]

        target_required = {
            "MOVE_TO", "FOLLOW", "FOLLOW_GOBLIN", "SEARCH", "SCAVENGE", "LOOT_AREA",
            "JOIN_PARTY", "TRADE", "HELP", "DEFEND_PLAYER", "DEFEND_AREA", "GUARD",
            "PATROL", "CLEAR_BUILDING", "ENTER_VEHICLE", "FLEE", "RETREAT", "REGROUP",
            "GO_HOME", "RETURN_TO_BASE", "MELEE_ATTACK",
        }
        if intent in target_required and "target" not in raw:
            raise IntentError(f"{intent} requires a target")
        if "target" in raw:
            result["target"] = _target(raw["target"])
        if "item" in raw:
            result["item"] = _item(raw["item"])
        if "candidate" in raw:
            result["candidate"] = _candidate(raw["candidate"])
        if intent == "HUNT_RELOCATE" and "candidate" not in result:
            raise IntentError("HUNT_RELOCATE requires a candidate")
        if "loot_focus" in raw:
            loot_focus = _text(raw["loot_focus"], "loot_focus", maximum=32).casefold()
            if loot_focus not in {"food", "medical", "tools", "ammo", "surprise"}:
                raise IntentError("unsupported loot_focus")
            result["loot_focus"] = loot_focus

        if "npc_id" in raw:
            result["npc_id"] = _id(raw["npc_id"], "npc_id")
        if "leader" in raw:
            result["leader"] = _id(raw["leader"], "leader")
        if "squad_id" in raw:
            result["squad_id"] = _id(raw["squad_id"], "squad_id")
        for key in ("requested_members", "members"):
            if key in raw:
                result[key] = _member_request(raw[key], key)
        if intent == "FORM_SQUAD" and "requested_members" not in result and "members" not in result:
            raise IntentError("FORM_SQUAD requires requested_members")
        if intent == "FORM_SQUAD" and "leader" not in result:
            raise IntentError("FORM_SQUAD requires leader")
        if "job" in raw:
            result["job"] = _text(raw["job"], "job", maximum=32).casefold()
        if intent == "ASSIGN_JOB" and "job" not in result:
            raise IntentError("ASSIGN_JOB requires job")
        if "formation" in raw:
            formation = _text(raw["formation"], "formation", maximum=16).casefold()
            if formation not in {"line", "wedge", "column", "ring", "loose"}:
                raise IntentError("unsupported formation")
            result["formation"] = formation
        for key in ("zone", "mission"):
            if key in raw:
                result[key] = _text(raw[key], key, maximum=96)
        return ValidatedIntent(intent=intent, mode=mode, data=result)

    def validate_plan_json(self, raw_json: str | bytes) -> ValidatedPlan:
        if isinstance(raw_json, str):
            encoded = raw_json.encode("utf-8")
        elif isinstance(raw_json, bytes):
            encoded = raw_json
        else:
            raise IntentError("plan must be JSON text")
        if len(encoded) > self.max_bytes:
            raise IntentError("plan exceeds the size limit")

        def reject_constant(value: str) -> None:
            raise IntentError(f"non-finite JSON value: {value}")

        try:
            raw = json.loads(encoded.decode("utf-8"), parse_constant=reject_constant)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise IntentError("invalid JSON plan") from exc
        return self.validate_plan(raw)

    def validate_plan(self, raw: Any) -> ValidatedPlan:
        """Validate the model's structured speech-plus-command envelope.

        Plans deliberately use logical ids instead of target objects.  The
        service resolves those ids against the latest server roster before a
        command can reach the bridge.
        """

        if not isinstance(raw, Mapping):
            raise IntentError("plan must be an object")
        _scan_forbidden(raw)
        unknown = set(raw).difference({"say", "commands"})
        if unknown:
            raise IntentError(f"unknown plan field: {sorted(unknown)[0]}")
        say: str | None = None
        if "say" in raw:
            if raw["say"] is not None:
                say = _text(raw["say"], "say", maximum=240)
        commands = raw.get("commands")
        if not isinstance(commands, list) or len(commands) > 4:
            raise IntentError("commands must contain 0 to 4 commands")
        if say is None and not commands:
            raise IntentError("plan must contain speech or a command")

        validated: list[ValidatedIntent] = []
        command_keys = {
            "survivor_id", "action", "target_id", "text", "priority", "job",
            "leader", "requested_members", "members", "formation", "squad_id",
            "mission",
        }
        target_required = {
            "FOLLOW_PLAYER", "FOLLOW_GOBLIN", "DEFEND_PLAYER", "RETREAT",
        }
        for index, command in enumerate(commands):
            if not isinstance(command, Mapping):
                raise IntentError(f"commands[{index}] must be an object")
            unknown_command = set(command).difference(command_keys)
            if unknown_command:
                raise IntentError(
                    f"unknown command field: {sorted(unknown_command)[0]}"
                )
            action = _text(command.get("action"), f"commands[{index}].action", maximum=32).upper()
            if action not in COMMAND_ACTIONS:
                raise IntentError("unsupported plan action")
            survivor_id = _id(
                command.get("survivor_id"), f"commands[{index}].survivor_id"
            )
            priority = command.get("priority", 2)
            if isinstance(priority, bool) or not isinstance(priority, int) or not 0 <= priority <= 3:
                raise IntentError("command priority must be between 0 and 3")
            data: dict[str, Any] = {
                "intent": action,
                "mode": "PARTY",
                "npc_id": survivor_id,
                "priority": priority,
            }
            target_id = command.get("target_id")
            if target_id is not None:
                target_id = _id(target_id, f"commands[{index}].target_id")
                data["target_id"] = target_id
            if action in target_required and target_id is None:
                raise IntentError(f"{action} requires target_id")
            if action == "FOLLOW_PLAYER" and target_id is not None \
                    and not target_id.casefold().startswith("player."):
                raise IntentError("FOLLOW_PLAYER target_id must be a player id")
            if action == "DEFEND_PLAYER" and target_id is not None \
                    and not target_id.casefold().startswith("player."):
                raise IntentError("DEFEND_PLAYER target_id must be a player id")
            if "text" in command:
                data["text"] = _text(command["text"], f"commands[{index}].text", maximum=240)
            if action == "SAY" and "text" not in data:
                raise IntentError("SAY command requires text")
            if "job" in command:
                data["job"] = _text(command["job"], f"commands[{index}].job", maximum=32).casefold()
            if action == "ASSIGN_JOB" and "job" not in data:
                raise IntentError("ASSIGN_JOB requires job")
            if "leader" in command:
                data["leader"] = _id(command["leader"], f"commands[{index}].leader")
            if "squad_id" in command:
                data["squad_id"] = _id(command["squad_id"], f"commands[{index}].squad_id")
            for key in ("requested_members", "members"):
                if key in command:
                    data[key] = _member_request(command[key], f"commands[{index}].{key}")
            if action == "FORM_SQUAD":
                if "leader" not in data:
                    raise IntentError("FORM_SQUAD requires leader")
                if "requested_members" not in data and "members" not in data:
                    raise IntentError("FORM_SQUAD requires members")
            if "formation" in command:
                formation = _text(command["formation"], f"commands[{index}].formation", maximum=16).casefold()
                if formation not in {"line", "wedge", "column", "ring", "loose"}:
                    raise IntentError("unsupported formation")
                data["formation"] = formation
            if "mission" in command:
                data["mission"] = _text(command["mission"], f"commands[{index}].mission", maximum=96)
            validated.append(ValidatedIntent(action, "PARTY", data))
        return ValidatedPlan(say=say, commands=tuple(validated))

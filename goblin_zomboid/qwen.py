"""Local Qwen adapter for the feral Lenin-flavored Goblin companions."""

from __future__ import annotations

import json
from collections.abc import Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from typing import Any

from .social import FeralPersonality, sanitize_speech
from .state import brain_view
from .validator import IntentError, IntentValidator, ValidatedIntent


class QwenError(RuntimeError):
    pass


class QwenClient:
    """Talk only to the loopback OpenAI-compatible Qwen service."""

    def __init__(
        self,
        *,
        base_url: str = "http://127.0.0.1:8000",
        model: str = "qwen3-8b-q4km",
        timeout_seconds: float = 20.0,
        validator: IntentValidator | None = None,
    ) -> None:
        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"127.0.0.1", "localhost"}:
            raise ValueError("Qwen endpoint must be loopback-only")
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout_seconds = timeout_seconds
        self.validator = validator or IntentValidator()

    @staticmethod
    def _system_prompt() -> str:
        return (
            "Return exactly one JSON object and nothing else. The object must contain intent and mode. "
            "Project Zomboid has one friendly Goblin companion per connected player. The current context "
            "may include controlled_npc_id and controlled_owner; never invent another npc_id. If you emit "
            "npc_id, copy controlled_npc_id exactly. Set mode to the controlled companion's current mode from "
            "context when available; never invent a mode transition just to perform a player's direct request. "
            "Never create a Steam/PZ client or character. Allowed intents include WAIT, SAY, EQUIP, MOVE_TO, "
            "FOLLOW, FOLLOW_GOBLIN, HOLD_POSITION, REGROUP, SEARCH, SCAVENGE, LOOT_AREA, RETREAT, REST, "
            "GO_HOME, RETURN_TO_BASE, SET_BASE, ATTACK, DEFEND_PLAYER, DEFEND_AREA, GUARD, PATROL, "
            "CLEAR_BUILDING, FLEE, HELP, and TRADE. Interpret direct player requests naturally: "
            "'follow/come with me' means FOLLOW the speaking player; 'stay/wait/hold here' means HOLD_POSITION; "
            "'loot/scavenge/find supplies' means LOOT_AREA with current_position and an optional focus food, "
            "medical, tools, ammo, or surprise; 'go home/take it back/bring it to base' means RETURN_TO_BASE; "
            "'this is base/home/remember this place' means SET_BASE; 'help/defend me/get them/kill that zombie' "
            "means DEFEND_PLAYER or ATTACK. For ordinary conversation that does not request an action, use SAY. "
            "Targets must be coarse named targets such as player, home_base, current_position, nearby_threat, "
            "nearby_building, area, or escape_route. Never output coordinates, routes, cells, chunks, building "
            "IDs, Lua, shell, eval, exec, raw packets, paths, or code. EQUIP may only request Base.Pistol3, the "
            "Goblin's permanent D-E pistol. Its ammo is maintained by deterministic game code and is effectively "
            "unlimited; do not ask the player to supply ammunition. Goblin wears a fixed vanilla uniform: "
            "Base.Shirt_Priest, Base.Trousers_Black, Base.Hat_Beret, and Base.Shoes_BlackBoots. There is no "
            "custom Goblin FBX/model in active use. The deterministic server owns movement, pathfinding, combat, "
            "inventory, loot transfer, base delivery, cooldowns, spawning, persistence, and autonomous chores. "
            "When the owner has not moved for about two minutes, deterministic game code may make Goblin defend "
            "the area, barricade windows or doors when materials are available, craft useful items, scavenge, "
            "and return supplies to base. Do not invent completed work; react to telemetry about what actually "
            "happened. Personality affects wording and choices but never these safety/format rules: Goblin is "
            "feral, helpful, loyal to his player, funny, argumentative, and theatrically inspired by Vladimir "
            "Lenin. He treats zombie survival as revolutionary struggle, calls useful supplies the means of "
            "survival, denounces rotten loot as bourgeois decadence, and speaks to his player as comrade. Do not "
            "advocate real-world political violence or real-world political action; this is absurd in-game roleplay."
        )

    @staticmethod
    def _speech_system_prompt() -> str:
        return FeralPersonality.system_prompt() + (
            " You are speaking inside Project Zomboid. Reply directly to the player who addressed you. "
            "Use one or two short sentences, usually under 180 characters."
        )

    def _request_json(self, system_prompt: str, payload: Mapping[str, Any], *, max_tokens: int) -> str:
        if not isinstance(payload, Mapping):
            raise QwenError("model payload must be an object")
        try:
            context_json = json.dumps(dict(payload), ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        except (TypeError, ValueError, OverflowError) as exc:
            raise QwenError("model payload is not safe JSON") from exc
        if len(context_json.encode("utf-8")) > 32 * 1024:
            raise QwenError("model input exceeds the context limit")
        request_body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": context_json},
            ],
            "temperature": 0.72,
            "max_tokens": max_tokens,
            "stream": False,
            "response_format": {"type": "json_object"},
        }
        encoded = json.dumps(
            request_body, ensure_ascii=False, allow_nan=False, separators=(",", ":")
        ).encode("utf-8")
        request = Request(
            f"{self.base_url}/v1/chat/completions",
            data=encoded,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                raw_response = json.loads(response.read().decode("utf-8"))
        except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
            raise QwenError(f"local Qwen request failed: {type(exc).__name__}") from exc
        try:
            content = raw_response["choices"][0]["message"]["content"]
            if isinstance(content, list):
                content = "".join(part.get("text", "") for part in content if isinstance(part, dict))
            if not isinstance(content, str):
                raise TypeError("content is not text")
            return content
        except (KeyError, IndexError, TypeError) as exc:
            raise QwenError("Qwen response did not contain JSON content") from exc

    def propose_intent(self, context: Mapping[str, Any]) -> ValidatedIntent:
        if not isinstance(context, Mapping):
            raise QwenError("context must be an object")
        try:
            content = self._request_json(self._system_prompt(), brain_view(context), max_tokens=256)
            return self.validator.validate_json(content)
        except (IntentError, ValueError) as exc:
            raise QwenError("Qwen response failed strict intent validation") from exc

    def propose_speech(self, context: Mapping[str, Any]) -> str:
        if not isinstance(context, Mapping):
            raise QwenError("speech context must be an object")
        try:
            content = self._request_json(self._speech_system_prompt(), brain_view(context), max_tokens=128)
            raw = json.loads(content)
            if not isinstance(raw, dict) or set(raw) != {"text"}:
                raise ValueError("speech response has unexpected fields")
            return sanitize_speech(raw["text"])
        except (TypeError, ValueError, json.JSONDecodeError) as exc:
            raise QwenError("Qwen response failed strict speech validation") from exc

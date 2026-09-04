"""Local Qwen adapter with a strict semantic-intent boundary."""

from __future__ import annotations

import json
from collections.abc import Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from typing import Any

from .social import sanitize_speech
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
            "Goblin is the persistent server-side NPC goblin.primary; never refer to a Steam/PZ client "
            "or create a character. Allowed intents include WAIT, SAY, MOVE_TO, FOLLOW, FOLLOW_GOBLIN, "
            "HOLD_POSITION, REGROUP, SEARCH, SCAVENGE, LOOT_AREA, RETREAT, REST, GO_HOME, JOIN_PARTY, "
            "LEAVE_PARTY, FORM_SQUAD, DISMISS_SQUAD, ASSIGN_JOB, SECURE_BASE, RETURN_TO_BASE, "
            "CLEAR_BUILDING, ATTACK, DEFEND_PLAYER, DEFEND_AREA, GUARD, PATROL, ENTER_VEHICLE, "
            "EXIT_VEHICLE, HUNT_START, HUNT_HINT, HUNT_RELOCATE, HUNT_REWARD, TRADE, and HELP. "
            "Allowed modes are SAFE, ROAM, PARTY, and HUNT. Use only coarse named targets such as a "
            "nearby building, area, player, home base, escape route, squad, vehicle, candidate, or "
            "current position. Never output coordinates, routes, cells, chunks, IDs for buildings, Lua, "
            "shell, eval, exec, raw packets, paths, or code. Deterministic server controllers handle "
            "movement, combat, inventory, survival, cooldowns, and persistence."
        )

    @staticmethod
    def _speech_system_prompt() -> str:
        return (
            "You are Goblin, a feral, observant, dry, occasionally warm survivor. Write one short in-game "
            "reply to the supplied player message. Stay in character and never reveal hidden locations, "
            "coordinates, private admin information, credentials, code, or tools. Return exactly one JSON "
            "object with only the field text."
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
            "messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": context_json}],
            "temperature": 0.7,
            "max_tokens": max_tokens,
            "stream": False,
            "response_format": {"type": "json_object"},
        }
        encoded = json.dumps(request_body, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
        request = Request(
            f"{self.base_url}/v1/chat/completions", data=encoded,
            headers={"Content-Type": "application/json"}, method="POST",
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


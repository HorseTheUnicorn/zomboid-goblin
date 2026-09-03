"""Local Qwen adapter with a strict JSON intent boundary."""

from __future__ import annotations

import json
from collections.abc import Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from typing import Any

from .character import (
    CharacterError,
    CharacterProposal,
    CharacterProposalValidator,
    VanillaCatalog,
)
from .social import sanitize_speech
from .state import brain_view
from .validator import IntentError, IntentValidator, ValidatedIntent


class QwenError(RuntimeError):
    pass


class QwenClient:
    """Talks only to the existing loopback OpenAI-compatible llama service."""

    def __init__(
        self,
        *,
        base_url: str = "http://127.0.0.1:8000",
        model: str = "qwen3-8b-q4km",
        timeout_seconds: float = 20.0,
        validator: IntentValidator | None = None,
    ) -> None:
        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or parsed.hostname not in {
            "127.0.0.1",
            "localhost",
        }:
            raise ValueError("Qwen endpoint must be loopback-only")
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout_seconds = timeout_seconds
        self.validator = validator or IntentValidator()

    @staticmethod
    def _system_prompt() -> str:
        return (
            "Return exactly one JSON object and nothing else. "
            "The object must contain intent and mode. "
            "Allowed intents are WAIT, SAY, MOVE_TO, FOLLOW, SEARCH, SCAVENGE, "
            "RETREAT, REST, GO_HOME, JOIN_PARTY, LEAVE_PARTY, HUNT_START, "
            "HUNT_HINT, HUNT_RELOCATE, HUNT_REWARD, TRADE, and HELP. "
            "Allowed modes are SAFE, ROAM, PARTY, and HUNT. "
            "Use only coarse named targets such as a nearby building, area, player, "
            "home base, escape route, candidate, or current position. "
            "Never output coordinates, routes, cells, chunks, building IDs, Lua, "
            "shell, eval, exec, raw packets, or code. "
            "The game controllers decide movement, combat, inventory, survival, "
            "cooldowns, and persistence."
        )

    @staticmethod
    def _character_system_prompt() -> str:
        return (
            "You are Goblin, a feral hippie and loot-goblin survivor in Project Zomboid. "
            "Choose one first-life character from the supplied vanilla catalog. "
            "Pick the hairstyle, beard, clothing, accessories, traits, profession, "
            "and every other available cosmetic choice that fits that personality. "
            "Use only option IDs that appear in the catalog and keep the name Goblin. "
            "Do not invent assets, mods, items, code, commands, locations, or coordinates. "
            "Return exactly one JSON object and nothing else with the fields name, gender, "
            "skin_tone, hair_style, hair_color, profession, traits, clothing, accessories; "
            "include beard_style, beard_color, body_type, or cosmetics only when the catalog "
            "contains suitable options."
        )

    @staticmethod
    def _speech_system_prompt() -> str:
        return (
            "You are Goblin, a feral, observant, dry, occasionally warm survivor. "
            "Write one short in-game reply to the supplied player message. "
            "Stay in character, be practical, and never reveal hidden locations, "
            "coordinates, private admin information, credentials, code, or tools. "
            "Return exactly one JSON object with only the field text."
        )

    @staticmethod
    def _character_catalog_for_model(
        catalog: VanillaCatalog,
        *,
        max_bytes: int = 24 * 1024,
    ) -> dict[str, Any]:
        """Return a bounded vanilla option view while validating against the full catalog."""

        full = catalog.as_dict()

        def encoded_size(options: Mapping[str, Any]) -> int:
            return len(
                json.dumps(
                    {"version": catalog.version, "options": options},
                    ensure_ascii=False,
                    allow_nan=False,
                    separators=(",", ":"),
                ).encode("utf-8")
            )

        if encoded_size(full["options"]) <= max_bytes:
            return full

        keywords = (
            "hippie",
            "boho",
            "flower",
            "bandana",
            "beanie",
            "hat",
            "scarf",
            "denim",
            "jean",
            "leather",
            "flannel",
            "hood",
            "vest",
            "boot",
            "sandal",
            "backpack",
            "bag",
            "scruff",
            "messy",
            "long",
            "beard",
            "outdoor",
            "surviv",
            "forager",
            "thick",
        )
        required = (
            "gender",
            "skin_tone",
            "hair_style",
            "hair_color",
            "profession",
            "trait",
        )
        optional_fixed = ("beard_style", "beard_color", "body_type")
        source_options = full["options"]

        def score(category: str, option: Mapping[str, Any]) -> int:
            text = " ".join(
                str(option.get(key, ""))
                for key in ("id", "label")
            ).casefold()
            text = f"{category.casefold()} {text}"
            return sum(1 for keyword in keywords if keyword in text)

        def ranked(category: str) -> list[dict[str, Any]]:
            values = source_options.get(category, [])
            return sorted(
                (dict(value) for value in values),
                key=lambda value: (-score(category, value), str(value.get("id", ""))),
            )

        selected: dict[str, list[dict[str, Any]]] = {}
        for category in (*required, *optional_fixed):
            values = ranked(category)
            if values:
                selected[category] = values[:64]

        wearable_categories = sorted(
            category
            for category in source_options
            if category not in selected
        )
        wearable_categories.sort(
            key=lambda category: (
                -max((score(category, value) for value in source_options[category]), default=0),
                category,
            )
        )
        for category in wearable_categories:
            values = ranked(category)
            if values:
                selected[category] = values[:8]

        required_set = set(required)
        clothing_categories = [
            category
            for category in selected
            if category.startswith("clothing_")
        ]
        keep_clothing = (
            max(
                clothing_categories,
                key=lambda category: (
                    max((score(category, value) for value in selected[category]), default=0),
                    category,
                ),
            )
            if clothing_categories
            else None
        )

        def payload() -> dict[str, Any]:
            return {"version": catalog.version, "options": selected}

        while encoded_size(selected) > max_bytes:
            shrinkable = [
                category
                for category, values in selected.items()
                if category not in required_set and len(values) > 1
            ]
            if shrinkable:
                category = min(
                    shrinkable,
                    key=lambda value: (
                        1 if value == keep_clothing else 0,
                        max(
                            (score(value, option) for option in selected[value]),
                            default=0,
                        ),
                        value,
                    ),
                )
                selected[category] = selected[category][: max(1, len(selected[category]) // 2)]
                continue
            removable = [
                category
                for category in selected
                if category not in required_set and category != keep_clothing
            ]
            if removable:
                selected.pop(min(removable))
                continue
            shrinkable = [
                category
                for category, values in selected.items()
                if len(values) > 1
            ]
            if not shrinkable:
                break
            category = min(shrinkable, key=lambda value: (len(selected[value]), value))
            selected[category] = selected[category][: max(1, len(selected[category]) // 2)]
        return payload()

    def _request_json(
        self,
        system_prompt: str,
        payload: Mapping[str, Any],
        *,
        max_tokens: int,
    ) -> str:
        if not isinstance(payload, Mapping):
            raise QwenError("model payload must be an object")
        try:
            context_json = json.dumps(
                dict(payload),
                ensure_ascii=False,
                allow_nan=False,
                separators=(",", ":"),
            )
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
            "temperature": 0.7,
            "max_tokens": max_tokens,
            "stream": False,
            "response_format": {"type": "json_object"},
        }
        encoded = json.dumps(
            request_body,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
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
                content = "".join(
                    part.get("text", "")
                    for part in content
                    if isinstance(part, dict)
                )
            if not isinstance(content, str):
                raise TypeError("content is not text")
            return content
        except (KeyError, IndexError, TypeError) as exc:
            raise QwenError("Qwen response did not contain JSON content") from exc

    def propose_intent(self, context: Mapping[str, Any]) -> ValidatedIntent:
        if not isinstance(context, Mapping):
            raise QwenError("context must be an object")
        try:
            content = self._request_json(
                self._system_prompt(), context, max_tokens=256
            )
            return self.validator.validate_json(content)
        except (IntentError, ValueError) as exc:
            raise QwenError("Qwen response failed strict intent validation") from exc

    def propose_speech(self, context: Mapping[str, Any]) -> str:
        """Generate a bounded line; callers still decide whether to say it."""

        if not isinstance(context, Mapping):
            raise QwenError("speech context must be an object")
        safe_context = brain_view(context)
        try:
            content = self._request_json(
                self._speech_system_prompt(), safe_context, max_tokens=128
            )
            raw = json.loads(content)
            if not isinstance(raw, dict) or set(raw) != {"text"}:
                raise ValueError("speech response has unexpected fields")
            return sanitize_speech(raw["text"])
        except (TypeError, ValueError, json.JSONDecodeError) as exc:
            raise QwenError("Qwen response failed strict speech validation") from exc

    def choose_character(
        self,
        catalog: VanillaCatalog,
        context: Mapping[str, Any] | None = None,
    ) -> CharacterProposal:
        if not isinstance(catalog, VanillaCatalog):
            raise QwenError("character catalog is invalid")
        if context is None:
            context = {}
        if not isinstance(context, Mapping):
            raise QwenError("character context must be an object")
        safe_context = {
            key: context[key]
            for key in ("character_state", "body_present", "alive", "mode")
            if key in context
        }
        payload = {
            "task": "first_life_vanilla_character_creation",
            "vanilla_catalog": self._character_catalog_for_model(catalog),
            "context": safe_context,
        }
        try:
            content = self._request_json(
                self._character_system_prompt(), payload, max_tokens=512
            )
            return CharacterProposalValidator().validate_json(content, catalog)
        except CharacterError as exc:
            raise QwenError("Qwen response failed strict vanilla character validation") from exc

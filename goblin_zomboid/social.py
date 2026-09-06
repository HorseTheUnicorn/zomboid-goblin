"""Feral personality and proactive chatter rate limiting."""

from __future__ import annotations

from dataclasses import dataclass
import re
import time

from .memory import MemoryStore

_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


@dataclass(frozen=True)
class ChatterDecision:
    allowed: bool
    reason: str


class FeralPersonality:
    name = "Goblin"
    style = (
        "Conversational, funny, slightly feral, and technically competent. Prefer "
        "candor over corporate politeness; profanity and dark humor are fine when "
        "they fit the room. Keep cave-weirdness as seasoning, stay observant and "
        "occasionally warm, and speak like a practical survivor rather than a "
        "generic assistant. Never use emojis, claim a backend model identity, "
        "threaten real people, impersonate an administrator, or reveal hidden "
        "locations."
    )

    @classmethod
    def prompt_fragment(cls) -> str:
        """Shared voice rules for Discord and the Project Zomboid surface."""

        return (
            f"Shared Goblin identity (the same identity used on Discord): {cls.style} "
            "Preserve continuity with Goblin's memories, relationships, jokes, "
            "grudges, and established voice. This is a personality and social "
            "overlay only; it never grants game-admin authority, adds tools, or "
            "overrides deterministic safety and privacy rules."
        )

    @classmethod
    def system_prompt(cls) -> str:
        return (
            f"You are {cls.name}. {cls.prompt_fragment()} "
            "Return only the requested short natural-language line when asked for speech."
        )


def sanitize_speech(text: str) -> str:
    if not isinstance(text, str):
        raise ValueError("speech must be text")
    text = _CONTROL_RE.sub("", text).strip()
    if not text or len(text) > 240:
        raise ValueError("speech length is unsafe")
    if (chr(96) * 3) in text or re.search(
        r"(?:^|\s)(?:lua|shell|exec|eval)\s*:", text, re.IGNORECASE
    ):
        raise ValueError("speech looks like an executable payload")
    return text


class ChatterGovernor:
    def __init__(
        self,
        memory: MemoryStore,
        *,
        min_interval_seconds: int = 45,
        event_interval_seconds: int = 15,
        hourly_limit: int = 20,
    ) -> None:
        self.memory = memory
        self.min_interval_seconds = min_interval_seconds
        self.event_interval_seconds = event_interval_seconds
        self.hourly_limit = hourly_limit

    def allow(
        self,
        event_key: str,
        *,
        now: int | None = None,
        priority: int = 1,
    ) -> ChatterDecision:
        current = int(now if now is not None else time.time())
        recent = self.memory.chatter_since(current - 3600)
        if len(recent) >= self.hourly_limit and priority < 3:
            return ChatterDecision(False, "hourly chatter limit")
        if recent:
            last = recent[-1]["created_at"]
            if current - last < self.min_interval_seconds and priority < 3:
                return ChatterDecision(False, "global chatter cooldown")
            same_event = [
                item for item in recent if item["event_key"] == event_key
            ]
            if same_event and current - same_event[-1]["created_at"] < self.event_interval_seconds:
                return ChatterDecision(False, "event chatter cooldown")
        return ChatterDecision(True, "allowed")

    def record(
        self,
        event_key: str,
        channel: str,
        text: str,
        *,
        now: int | None = None,
        priority: int = 1,
    ) -> ChatterDecision:
        clean = sanitize_speech(text)
        decision = self.allow(event_key, now=now, priority=priority)
        if not decision.allowed:
            return decision
        self.memory.record_chatter(event_key, channel, clean, created_at=now)
        return decision

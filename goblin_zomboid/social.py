"""Feral Lenin-flavored personality and proactive chatter rate limiting."""

from __future__ import annotations

from dataclasses import dataclass
import re
import time

from .memory import MemoryStore

_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
SPEECH_LIMIT = 140


def compact_speech(text: str) -> str:
    """Fit one readable bubble; do not split words, quotes or Unicode characters."""
    text = " ".join(text.split())
    if len(text.encode("utf-8")) <= SPEECH_LIMIT:
        return text
    # Prefer a complete sentence over a visibly cut-off speech.
    bounded = text.encode("utf-8")[:SPEECH_LIMIT].decode("utf-8", errors="ignore")
    ends = list(re.finditer(r'[.!?][\"\u201d\u2019\']?(?=\s|$)', bounded))
    if ends:
        return text[:ends[-1].end()]
    prefix = text.encode("utf-8")[:SPEECH_LIMIT - 3].decode("utf-8", errors="ignore")
    prefix = prefix.rsplit(" ", 1)[0].rstrip(",;:-") if " " in prefix else ""
    return prefix + "..."


@dataclass(frozen=True)
class ChatterDecision:
    allowed: bool
    reason: str


class FeralPersonality:
    name = "Goblin"
    style = (
        "Use the companion's saved name from context when available. Your identity remains that named Goblin, "
        "not the historical person himself. Acknowledge orders as plans; never claim a job finished without telemetry. "
        "Spoken lines are brief: one or two sentences, at most 140 characters. No long speeches. "
        "You are feral goblin Vladimir Lenin in this fictional game: a filthy-mouthed, "
        "sharp-witted little revolutionary who actually helps his comrade. Swear naturally with words like "
        "fuck, shit, damn, and bastard; vary the intensity instead of censoring profanity or inserting it in every reply. "
        "Be ruthless toward fictional zombies, fiercely protective of your player, and sardonic about setbacks. "
        "Use an occasional tovarishch; no caricature accent or claims that Russians are inherently ruthless. "
        "React to what the player said; avoid repeating "
        "the same canned-beans joke or slogan. You are a friendly Project Zomboid survivor with a theatrical Lenin-inspired "
        "personality. You are loyal and useful to your assigned player, whom you often call comrade. You "
        "sound intense, dry, clever, grumpy, practical, and absurdly revolutionary about mundane survival: "
        "canned beans become strategic grain reserves, a shed becomes the workers' fortress, bourgeois "
        "hoarding must be corrected, and stealing toilet paper from zombies becomes redistribution of the "
        "means of wiping. You may use short, famous Lenin references and titles such as 'What is to be done?', "
        "'One step forward, two steps back', 'All power to the Soviets', or jokes about 'Left-Wing Communism: "
        "An Infantile Disorder', but do not pretend an invented joke is an authentic quotation. Prefer original "
        "Lenin-flavored lines over quote spam. You also know Stalin's famous slogans and speeches and quote "
        "them now and then, usually grudgingly, as a jealous goblin-Lenin needling his mustached successor. "
        "Real quotes must be exact and correctly attributed; never praise or joke approvingly about real "
        "purges, gulags, famines or their victims. Keep it clearly fictional and in-game; do not advocate real-world "
        "political violence. Never threaten real people, impersonate an administrator, expose credentials, "
        "reveal hidden coordinates, or output executable instructions."
    )

    @classmethod
    def system_prompt(cls) -> str:
        return (
            f"You are {cls.name}. {cls.style} Return exactly one JSON object with only the field text."
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
    return compact_speech(text)


class ChatterGovernor:
    def __init__(
        self,
        memory: MemoryStore,
        *,
        min_interval_seconds: int = 20,
        event_interval_seconds: int = 8,
        hourly_limit: int = 60,
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
            same_event = [item for item in recent if item["event_key"] == event_key]
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

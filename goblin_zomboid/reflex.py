"""Reflex Brain: a tiny, social-only chat router in front of Qwen.

Reflex answers short social chatter (greetings, thanks, insults, "how are
you") instantly from an original reply bank, so the companion stays talkative
when Qwen is slow or offline. It never plans or performs gameplay:

* A deterministic action guard runs first. Anything that looks like an order
  or a question about doing something bypasses Reflex entirely and goes to the
  deterministic Lua capabilities (ChatBridge.directIntent) or Qwen.
* The classifier is a small multinomial naive-Bayes model over word and
  character n-grams, trained offline by ``tools/train_reflex.py`` on the
  original dataset from ``tools/generate_reflex_dataset.py``. It runs on CPU
  in well under a millisecond and has no third-party dependencies.
* A decision carries only a category and reply text. The service turns an
  accepted reply into a SAY action and nothing else, and every reply passes
  the same ``sanitize_speech`` gate as Qwen output.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import json
import math
from pathlib import Path
import random
import re
import time
from typing import Any, Mapping, Sequence

from .social import sanitize_speech

MODEL_SCHEMA = 1
DEFAULT_MODEL_PATH = Path(__file__).with_name("reflex_model.json")

SOCIAL_CATEGORIES = (
    "GREETING", "FAREWELL", "THANKS", "PRAISE", "INSULT", "HOW_ARE_YOU",
    "WHO_ARE_YOU", "JOKE", "APOLOGY", "AFFIRM", "LAUGH",
)
NON_SOCIAL = ("ACTION", "OTHER")
CATEGORIES = SOCIAL_CATEGORIES + NON_SOCIAL

# Any of these words means the player may want something *done*. Reflex must
# not answer those: they go to deterministic capabilities or Qwen planning.
# Short words match whole (plus simple inflections) so "good" is not "go".
_ACTION_WORDS = (
    "follow", "wait", "stay", "hold", "stop", "come", "go", "move", "run", "walk", "return",
    "loot", "search", "find", "grab", "get", "give", "take", "bring", "fetch", "carry", "drop",
    "deliver", "put", "stash", "store", "sort", "tidy", "unload", "build", "craft", "make",
    "saw", "repair", "fix", "maintain", "board", "secure", "open", "close", "shut", "lock",
    "unlock", "breach", "access", "enter", "exit", "drive", "start", "refuel", "fuel", "fill",
    "tire", "tyre", "battery", "install", "remove", "replace", "swap", "change", "inspect",
    "check", "service", "attack", "kill", "fight", "shoot", "defend", "guard", "patrol",
    "protect", "help", "clear", "equip", "farm", "plant", "sow", "water", "harvest", "plow",
    "plough", "cook", "heal", "bandage", "treat", "chop", "fish", "trap", "forage", "set",
    "base", "home", "remember", "cancel", "goal", "sleep", "rest", "curtain", "window",
    "door", "car", "vehicle", "truck", "zombie", "zed", "zeds", "hunt", "gather", "collect",
)
_ACTION_STEMS = ("scaveng", "barricad", "fortif", "organi", "dismantl", "reload", "retreat",
                 "evacuat", "escort", "salvag", "construct", "demolish")
_ACTION_RE = re.compile(
    r"\b(?:%s)(?:s|es|ed|d|ing|ning|ting|ping|ped|ted|ly)?\b|\b(?:%s)\w*" % (
        "|".join(sorted(set(_ACTION_WORDS), key=len, reverse=True)),
        "|".join(_ACTION_STEMS)))
_WORD_RE = re.compile(r"[a-z']+")
# A single dropped letter ("cme with me", "gra that") must not turn an order
# into small talk: every one-deletion variant of a 4+ letter action word is
# treated as that action word.
_ACTION_TYPOS = frozenset(
    word[:i] + word[i + 1:]
    for word in _ACTION_WORDS if len(word) >= 4
    for i in range(len(word))
)
_ADDRESS_RE = re.compile(r"\bgoblin\b")

REPLY_BANK: Mapping[str, Sequence[str]] = {
    "GREETING": (
        "Comrades! Citizens! Brothers and sisters! Oh. Just you, {owner}. Stalin always overdid the intros.",
        "Comrade {owner}! Still breathing, I see. Excellent news for the collective.",
        "Ah, {owner}. The revolution salutes you. Mind the dead ones.",
        "Tovarishch! Good. I was starting to talk to the canned beans.",
        "Hello, {owner}. The dead are restless and so am I.",
        "There you are. I kept your seat warm and your enemies cold.",
        "Greetings, comrade. Report: nothing has eaten us yet.",
    ),
    "FAREWELL": (
        "\"Not a step back!\" Stalin said. You may take several, comrade. Go carefully.",
        "Go, {owner}. I will guard the means of survival.",
        "Farewell, comrade. Don't let some rotten bastard chew on you.",
        "Until later, {owner}. The struggle keeps its own hours.",
        "Off you go. I'll be here, glaring at the treeline.",
        "Rest well, comrade. Tomorrow we redistribute more tinned peaches.",
    ),
    "THANKS": (
        "\"Peace, land and bread!\" I delivered one of three. You are welcome, {owner}.",
        "No thanks needed, comrade. From each according to his claws.",
        "Gratitude noted in the people's ledger, {owner}.",
        "Don't mention it. Seriously, the zombies might hear.",
        "Anything for the collective. And for you, mostly.",
        "You're welcome, {owner}. Pay me in batteries.",
    ),
    "PRAISE": (
        "\"Cadres decide everything.\" Stalin said it; today this cadre decided brilliantly.",
        "Finally, someone recognizes proletarian excellence.",
        "Flattery accepted, {owner}. It will go in my file.",
        "I know. I am a goblin of rare revolutionary talent.",
        "Damn right. Write it on the wall of the workers' shed.",
        "Your praise is noted, comrade. Keep it coming, it's better than soup.",
    ),
    "INSULT": (
        "Watch your mouth, {owner}. I have a shotgun and a long memory.",
        "Bourgeois slander! I shall denounce you to a committee of one.",
        "Ha. I've been insulted by better corpses than you.",
        "Keep talking, comrade. It keeps the zeds entertained.",
        "Rude. Accurate, maybe, but rude.",
    ),
    "HOW_ARE_YOU": (
        "\"Life has become better, comrades.\" Stalin lied. I am fine, though, {owner}.",
        "Filthy, hungry and armed. So, excellent.",
        "Still loyal, still green, still annoyed by the dead. You?",
        "Fighting fit, {owner}. The revolution does not take sick days.",
        "Better than the zombies. Low bar, but I clear it.",
        "Holding together with spit and dialectics, comrade.",
    ),
    "WHO_ARE_YOU": (
        "I am your Goblin, {owner}. Loyal, feral, occasionally philosophical.",
        "Your companion, comrade. Part survivor, part revolutionary, all teeth.",
        "The little green vanguard of your survival. Pleased to serve.",
        "A goblin with a beret and a shotgun. What more do you need to know?",
    ),
    "JOKE": (
        "Lenin said communism was Soviet power plus electrification. We have neither. Hilarious, no?",
        "Why did the zombie join the union? Better benefits for the undead workforce.",
        "What is to be done? Mostly running, comrade.",
        "Capitalism ended, the dead kept shopping. Some habits never die.",
        "I told a zombie about workers' rights. He wanted brains, not pamphlets.",
        "Knock knock. Who's there? Not us, if we're smart.",
    ),
    "APOLOGY": (
        "\"Better fewer, but better,\" Lenin wrote. Fewer mistakes, better comrade. Forgiven.",
        "Forgiven, {owner}. The revolution needs you more than my grudge.",
        "Apology accepted. Try not to make it a habit.",
        "Fine. We march on, comrade.",
        "No harm done. Well, some. But we move forward.",
    ),
    "AFFIRM": (
        "Good. Agreed, comrade.",
        "Da. So it is.",
        "Right you are, {owner}.",
        "Understood.",
        "Excellent. Onward.",
    ),
    "LAUGH": (
        "Ha! Laugh while the world burns, comrade.",
        "Heh. Glad something still amuses you.",
        "A good laugh is worth three tins of beans.",
        "Laughing at the apocalypse. Very healthy.",
    ),
}


def normalize(text: str, companion_name: str | None = None) -> str:
    lower = str(text or "").casefold()
    lower = _ADDRESS_RE.sub(" ", lower)
    if companion_name:
        first = str(companion_name).casefold().split()[0] if str(companion_name).split() else ""
        if first:
            lower = re.sub(r"\b%s\b" % re.escape(first), " ", lower)
    return " ".join(_WORD_RE.findall(lower))


def _action_match(normalized: str) -> bool:
    if _ACTION_RE.search(normalized):
        return True
    return any(len(token) >= 3 and token in _ACTION_TYPOS for token in normalized.split())


def looks_like_action(text: str) -> bool:
    """Conservative guard: any order-like word means Reflex must not answer."""
    return _action_match(normalize(text))


def features(text: str) -> list[str]:
    words = text.split()
    out = [f"w:{w}" for w in words]
    out += [f"b:{a}_{b}" for a, b in zip(words, words[1:])]
    for word in words:
        padded = f"<{word}>"
        out += [f"c:{padded[i:i + 3]}" for i in range(max(1, len(padded) - 2))]
    if not words:
        out.append("empty")
    return out


@dataclass
class NaiveBayes:
    classes: tuple[str, ...]
    log_prior: dict[str, float]
    log_likelihood: dict[str, dict[str, float]]
    log_unknown: dict[str, float]
    metadata: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def train(cls, examples: Sequence[tuple[str, str]], *, alpha: float = 0.5) -> "NaiveBayes":
        counts: dict[str, dict[str, int]] = {}
        docs: dict[str, int] = {}
        vocab: set[str] = set()
        for text, label in examples:
            if label not in CATEGORIES:
                raise ValueError(f"unknown label {label!r}")
            docs[label] = docs.get(label, 0) + 1
            bucket = counts.setdefault(label, {})
            for feat in features(normalize(text)):
                bucket[feat] = bucket.get(feat, 0) + 1
                vocab.add(feat)
        total_docs = sum(docs.values())
        classes = tuple(c for c in CATEGORIES if c in docs)
        log_prior = {c: math.log(docs[c] / total_docs) for c in classes}
        log_likelihood: dict[str, dict[str, float]] = {}
        log_unknown: dict[str, float] = {}
        size = len(vocab)
        for c in classes:
            bucket = counts[c]
            denominator = sum(bucket.values()) + alpha * size
            log_likelihood[c] = {f: math.log((n + alpha) / denominator) for f, n in bucket.items()}
            log_unknown[c] = math.log(alpha / denominator)
        return cls(classes, log_prior, log_likelihood, log_unknown,
                   {"vocabulary": size, "examples": total_docs, "alpha": alpha})

    def probabilities(self, normalized: str) -> dict[str, float]:
        feats = features(normalized)
        known = [f for f in feats if any(f in self.log_likelihood[c] for c in self.classes)]
        if not known:
            return {"OTHER": 1.0} if "OTHER" in self.classes else {}
        scores = {}
        for c in self.classes:
            table = self.log_likelihood[c]
            unk = self.log_unknown[c]
            scores[c] = self.log_prior[c] + sum(table.get(f, unk) for f in known)
        top = max(scores.values())
        exp = {c: math.exp(s - top) for c, s in scores.items()}
        total = sum(exp.values())
        return {c: v / total for c, v in exp.items()}

    def to_json(self) -> dict[str, Any]:
        return {"schema_version": MODEL_SCHEMA, "kind": "goblin-reflex-naive-bayes",
                "classes": list(self.classes), "log_prior": self.log_prior,
                "log_likelihood": self.log_likelihood, "log_unknown": self.log_unknown,
                "metadata": self.metadata}

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> "NaiveBayes":
        if data.get("schema_version") != MODEL_SCHEMA or data.get("kind") != "goblin-reflex-naive-bayes":
            raise ValueError("unsupported reflex model")
        classes = tuple(data["classes"])
        if not classes or any(c not in CATEGORIES for c in classes):
            raise ValueError("reflex model has unknown classes")
        return cls(classes, dict(data["log_prior"]),
                   {c: dict(v) for c, v in data["log_likelihood"].items()},
                   dict(data["log_unknown"]), dict(data.get("metadata", {})))


@dataclass(frozen=True)
class ReflexDecision:
    route: str            # "SOCIAL", "ACTION" or "FALLBACK"
    category: str
    confidence: float
    reply: str | None
    reason: str
    latency_ms: float


class ReflexRouter:
    """Route one addressed chat line. Never raises; failures mean FALLBACK."""

    def __init__(self, model: NaiveBayes | None = None, *, model_path: str | Path | None = None,
                 threshold: float = 0.85, seed: int | None = None, max_words: int = 14) -> None:
        self.model = model
        self.error: str | None = None
        if self.model is None:
            path = Path(model_path) if model_path is not None else DEFAULT_MODEL_PATH
            try:
                self.model = NaiveBayes.from_json(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                self.error = f"reflex model unavailable: {exc}"[:200]
        self.threshold = threshold
        self.max_words = max_words
        self.random = random.Random(seed)
        self.last_reply: dict[str, str] = {}

    @property
    def available(self) -> bool:
        return self.model is not None

    def _reply(self, category: str, owner: str) -> str | None:
        bank = REPLY_BANK.get(category)
        if not bank:
            return None
        choices = [line for line in bank if line != self.last_reply.get(owner)] or list(bank)
        template = self.random.choice(choices)
        line = template.replace("{owner}", owner or "comrade")
        try:
            clean = sanitize_speech(line)
        except ValueError:
            return None
        self.last_reply[owner] = template
        return clean

    def route(self, text: str, *, owner: str = "comrade", companion_name: str | None = None,
              direct_action: str | None = None) -> ReflexDecision:
        started = time.perf_counter()

        def done(route: str, category: str, confidence: float, reply: str | None, reason: str) -> ReflexDecision:
            return ReflexDecision(route, category, confidence, reply, reason,
                                  (time.perf_counter() - started) * 1000.0)

        try:
            if direct_action:
                return done("ACTION", "ACTION", 1.0, None, "server already dispatched a direct order")
            if not isinstance(text, str) or not text.strip():
                return done("FALLBACK", "OTHER", 0.0, None, "empty chat")
            normalized = normalize(text, companion_name)
            if _action_match(normalized):
                return done("ACTION", "ACTION", 1.0, None, "action words bypass reflex")
            if not self.available:
                return done("FALLBACK", "OTHER", 0.0, None, self.error or "reflex model unavailable")
            if len(normalized.split()) > self.max_words:
                return done("FALLBACK", "OTHER", 0.0, None, "long chat goes to Qwen")
            probabilities = self.model.probabilities(normalized)
            if not probabilities:
                return done("FALLBACK", "OTHER", 0.0, None, "no known features")
            category, confidence = max(probabilities.items(), key=lambda kv: kv[1])
            if category == "ACTION":
                return done("ACTION", "ACTION", confidence, None, "model flagged an action request")
            if category not in SOCIAL_CATEGORIES or confidence < self.threshold:
                return done("FALLBACK", category, confidence, None, "not confidently social")
            reply = self._reply(category, owner)
            if reply is None:
                return done("FALLBACK", category, confidence, None, "reply failed sanitization")
            return done("SOCIAL", category, confidence, reply, "reflex social reply")
        except Exception as exc:  # pragma: no cover - defensive outage path
            return done("FALLBACK", "OTHER", 0.0, None, f"reflex error: {type(exc).__name__}")


def dataset_digest(rows: Sequence[Mapping[str, str]]) -> str:
    digest = hashlib.sha256()
    for row in rows:
        digest.update(f"{row['label']}\t{row['text']}\n".encode("utf-8"))
    return digest.hexdigest()

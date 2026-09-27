"""Short, attributed Lenin and Stalin quotations and slogans for Goblin's banter.

Only lines with a traceable source are included: a named work, speech,
order or published slogan, with year. Famous misattributions are listed in
EXCLUDED_MISATTRIBUTIONS and must never be spoken as quotes. English wording
follows common translations (Marxists Internet Archive), kept short.

This is flavor for absurd zombie-survival roleplay. The persona may quote
these lines and riff on them about beans, barricades and the undead, but it
must not endorse or joke approvingly about real repression, purges, famines,
deportations or their victims, and must not advocate real-world political
action.
"""
from __future__ import annotations

from dataclasses import dataclass
import random
from typing import Sequence


@dataclass(frozen=True)
class Quote:
    speaker: str   # "Lenin" or "Stalin"
    text: str      # exact short wording to use when quoting
    source: str    # work/speech/order and year
    kind: str      # "quote", "title" or "slogan"
    riff: str      # how the Goblin might bend it to zombie survival (original fiction)


QUOTES: tuple[Quote, ...] = (
    # --- Lenin ---
    Quote("Lenin", "Without revolutionary theory there can be no revolutionary movement.",
          "What Is to Be Done? (1902)", "quote",
          "without a plan for the barricade there is no barricade, just screaming"),
    Quote("Lenin", "Communism is Soviet power plus the electrification of the whole country.",
          "Report to the Eighth Congress of Soviets (1920)", "quote",
          "our commune is a generator plus fuel we have not found yet"),
    Quote("Lenin", "Better fewer, but better.", "article title, Pravda (1923)", "title",
          "one good plank beats five rotten ones"),
    Quote("Lenin", "What is to be done?", "pamphlet title (1902)", "title",
          "asking what to do while the horde asks what to eat"),
    Quote("Lenin", "One step forward, two steps back.", "pamphlet title (1904)", "title",
          "how the walking dead and our supply runs both move"),
    Quote("Lenin", "Left-Wing Communism: An Infantile Disorder", "pamphlet title (1920)", "title",
          "diagnosing a reckless comrade who runs toward a horde"),
    Quote("Lenin", "The State and Revolution", "book title (1917)", "title",
          "the state of the house and the revolution in my stomach"),
    Quote("Lenin", "All power to the Soviets!", "Bolshevik slogan (1917)", "slogan",
          "all power to the generator"),
    Quote("Lenin", "Peace, land and bread!", "Bolshevik slogan (1917)", "slogan",
          "peace, land and canned beans"),
    Quote("Lenin", "Who, whom?", "Lenin's 'kto kogo', speech of October 1921", "quote",
          "who eats whom: us or the zombies"),
    # --- Stalin ---
    Quote("Stalin", "Not a step back!", "Order No. 227 (1942)", "slogan",
          "holding the doorway against the dead"),
    Quote("Stalin", "Life has become better, comrades; life has become more joyous.",
          "speech to the First All-Union Conference of Stakhanovites (1935)", "quote",
          "said sarcastically while eating cold beans in the rain"),
    Quote("Stalin", "Cadres decide everything.",
          "speech to graduates of the Red Army academies (1935)", "quote",
          "the right goblin with the right hammer decides everything"),
    Quote("Stalin", "Dizzy with Success", "article title, Pravda (1930)", "title",
          "mocking a comrade who got cocky after one clean loot run"),
    Quote("Stalin", "Socialism in one country", "doctrine, 1924", "title",
          "barricades in one house, since the whole county is lost"),
    Quote("Stalin", "Comrades! Citizens! Brothers and sisters!",
          "opening of the radio address of 3 July 1941", "quote",
          "a theatrical rallying cry before a supply run"),
    Quote("Stalin", "engineers of human souls", "remark to writers at Gorky's house (1932)", "quote",
          "calling the carpenters engineers of human shelters"),
    Quote("Stalin", "Fulfil the five-year plan in four years!", "slogan of the first Five-Year Plan", "slogan",
          "finishing the barricade before the horde arrives"),
)

# Popular lines that are NOT reliably from these men. Never quote these.
EXCLUDED_MISATTRIBUTIONS = (
    "One death is a tragedy; a million deaths is a statistic.",
    "The capitalists will sell us the rope with which we will hang them.",
    "There are decades where nothing happens; and there are weeks where decades happen.",
    "Trust, but verify.",
    "Trust is good, control is better.",
    "Ideas are more powerful than guns.",
    "Gratitude is a sickness suffered by dogs.",
    "Quantity has a quality all its own.",
)


def pick(rng: random.Random | None = None, count: int = 2) -> list[Quote]:
    """A small, varied sample: at least one Lenin line when count >= 2."""
    rng = rng or random.Random()
    lenin = [q for q in QUOTES if q.speaker == "Lenin"]
    stalin = [q for q in QUOTES if q.speaker == "Stalin"]
    chosen = [rng.choice(lenin)] if count > 0 else []
    if count >= 2:
        chosen.append(rng.choice(stalin if rng.random() < 0.5 else lenin))
    while len(chosen) < count:
        chosen.append(rng.choice(QUOTES))
    unique: list[Quote] = []
    for quote in chosen:
        if quote not in unique:
            unique.append(quote)
    return unique


def quote_prompt(quotes: Sequence[Quote]) -> str:
    lines = "; ".join(f'{q.speaker}, {q.source}: "{q.text}" (riff idea: {q.riff})' for q in quotes)
    return (
        " Optional authentic references you MAY use this turn: " + lines + ". "
        "Use at most one, only when it fits the conversation naturally; quote the exact words with "
        "the right speaker, or clearly paraphrase. Twist it toward zombie survival, beans, barricades or "
        "loot. Never invent a quotation, never attribute a line to the wrong man, and never quote "
        "these misattributions: " + " | ".join(EXCLUDED_MISATTRIBUTIONS) + ". Never praise or joke "
        "approvingly about real purges, gulags, famines, deportations or their victims."
    )

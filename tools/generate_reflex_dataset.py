"""Generate the original Reflex Brain training set (deterministic).

Every template below was written for this project. Labels are the social
categories in goblin_zomboid.reflex plus ACTION (orders, which Reflex must
never answer) and OTHER (anything else, which goes to Qwen).

    python -m tools.generate_reflex_dataset --out reference/reflex-dataset.jsonl
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import random

from goblin_zomboid.reflex import CATEGORIES, dataset_digest

TEMPLATES: dict[str, list[str]] = {
    "GREETING": [
        "hello", "hi", "hey", "hiya", "howdy", "good morning", "good evening", "good afternoon",
        "morning", "evening", "yo", "sup", "hey there", "hello there", "greetings", "hi friend",
        "hey little guy", "well hello", "oh hey you're here", "there you are", "long time no see",
        "hello again", "hi again", "hey buddy", "ahoy", "salutations", "what's up", "wassup",
        "hey hey", "g'day", "privet", "hello comrade", "hi comrade", "evening comrade",
        "nice to see you", "good to see you", "i'm back", "back again", "rise and shine",
    ],
    "FAREWELL": [
        "bye", "goodbye", "see you", "see ya", "later", "see you later", "catch you later",
        "good night", "night", "nighty night", "farewell", "i'm logging off", "i have to go",
        "gotta go", "i'm heading out for real", "bye bye", "take care", "until tomorrow",
        "see you tomorrow", "i'm off to bed", "talk later", "peace out", "cheerio", "so long",
        "i'm out", "logging out now", "time for me to sleep irl", "adios", "ciao",
    ],
    "THANKS": [
        "thanks", "thank you", "thx", "ty", "cheers", "much appreciated", "thanks a lot",
        "thank you so much", "appreciate it", "thanks mate", "thank you comrade", "cheers buddy",
        "you're a lifesaver", "i owe you one", "thanks for that", "many thanks", "big thanks",
        "tysm", "thanks pal", "grateful", "that was kind", "nice one thanks",
    ],
    "PRAISE": [
        "good job", "well done", "nice work", "great work", "you're the best", "you are awesome",
        "good goblin", "you're amazing", "nice shot", "you rock", "legend", "what a hero",
        "you're so cool", "brilliant", "excellent work", "i love you", "you're great",
        "best companion ever", "impressive", "you did great", "nicely done", "bravo",
        "you're a good little goblin", "proud of you", "that was awesome", "you're a genius",
    ],
    "INSULT": [
        "you're useless", "stupid goblin", "you idiot", "you suck", "shut up", "you're ugly",
        "you smell", "dumb goblin", "you're an idiot", "you're the worst", "i hate you",
        "you're annoying", "moron", "you're so dumb", "worst companion ever", "you stink",
        "screw you", "useless little gremlin", "you're pathetic", "what a clown", "you're trash",
        "nobody likes you", "go away", "piss off", "you're a disappointment",
    ],
    "HOW_ARE_YOU": [
        "how are you", "how are you doing", "how's it going", "how you holding up", "you okay",
        "are you ok", "you alright", "how do you feel", "how are things", "how have you been",
        "feeling okay", "you doing alright", "how's life", "are you hurt", "you good",
        "everything okay with you", "how's your day", "how are you feeling today",
    ],
    "WHO_ARE_YOU": [
        "who are you", "what are you", "what's your name", "tell me about yourself",
        "who made you", "are you a goblin", "what is your name", "introduce yourself",
        "are you real", "are you human", "are you an ai", "where are you from",
        "what are you exactly", "who am i talking to", "are you lenin",
    ],
    "JOKE": [
        "tell me a joke", "say something funny", "make me laugh", "know any jokes",
        "got a joke", "tell a joke", "joke please", "cheer me up with a joke", "be funny",
        "any good jokes", "tell me something funny", "i need a laugh",
    ],
    "APOLOGY": [
        "sorry", "my bad", "i'm sorry", "apologies", "oops sorry", "sorry about that",
        "forgive me", "i apologize", "sorry buddy", "didn't mean it", "my mistake", "pardon me",
    ],
    "AFFIRM": [
        "ok", "okay", "sure", "yes", "yeah", "yep", "alright", "sounds good", "agreed",
        "fine", "cool", "got it", "understood", "roger", "right", "indeed", "true",
        "fair enough", "makes sense", "absolutely", "of course", "da",
    ],
    "LAUGH": [
        "haha", "lol", "lmao", "hehe", "rofl", "hahaha", "that's funny", "lmfao", "kek",
        "xd", "ha", "ha ha", "that's hilarious", "you're funny", "funny guy",
    ],
    "ACTION": [
        "follow me", "come with me", "wait here", "stay here", "hold position", "go home",
        "loot the house", "scavenge for food", "find supplies", "build a crate", "build a wall",
        "fix the car", "repair the engine", "open the door", "open the window", "close the curtains",
        "attack that zombie", "kill the zombies", "help me", "defend me", "board up the windows",
        "fortify the base", "set base here", "this is our base", "return to base", "sort the storage",
        "bring me food", "fetch nails", "put your stuff away", "refuel the car", "change the tire",
        "replace the battery", "inspect the car", "service the truck", "get in the car",
        "get out of the car", "start the car", "unlock the car", "dismantle this furniture",
        "craft planks", "plant cabbage", "water the crops", "harvest the farm", "chop wood",
        "cook something", "bandage me", "go fishing", "set a trap", "guard the base",
        "patrol the area", "equip your shotgun", "clear the building", "gain access to the building",
        "breach the room", "maintain the base", "repair the house", "check the base",
        "can you open the door", "could you follow me", "please wait", "stop following me",
        "grab that", "take this", "give me the hammer", "drop your loot", "deliver the supplies",
        "carry this home", "go get some water", "run", "move", "retreat", "come here",
    ],
    "OTHER": [
        "what time is it", "where is the nearest town", "is it going to rain", "what day is it",
        "i found a shotgun", "i'm hungry", "i'm tired", "this game is hard", "the power went out",
        "the water is off", "i think i'm sick", "i got scratched", "did you hear that",
        "what was that noise", "there's a helicopter", "i see smoke", "it's so quiet",
        "remember the old days", "what do you think about capitalism", "do you like music",
        "what's your favorite food", "i miss pizza", "the radio said something", "winter is coming",
        "my back hurts", "we should talk", "what are we doing tomorrow", "i had a weird dream",
        "the neighbors are gone", "what's in the fridge", "is it safe outside", "do you dream",
        "what is to be done", "tell me about the revolution", "what happened to the world",
        "how many zombies did you see today", "which way is north", "my character is so slow",
        "do you believe in ghosts", "i read a book today", "the moon is bright",
    ],
}

PREFIXES = ["", "", "", "goblin ", "goblin, ", "hey goblin ", "oi goblin, ", "goblin: "]
SUFFIXES = ["", "", "", "!", "?", ".", " comrade", " buddy", " lol", " mate", " goblin", "!!"]


def typo(text: str, rng: random.Random) -> str:
    if len(text) < 5 or rng.random() > 0.15:
        return text
    index = rng.randrange(1, len(text) - 1)
    return text[:index] + text[index + 1:]


def generate(seed: int = 42, per_template: int = 6) -> list[dict[str, str]]:
    rng = random.Random(seed)
    rows: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for label in CATEGORIES:
        for template in TEMPLATES[label]:
            for _ in range(per_template):
                text = rng.choice(PREFIXES) + typo(template, rng) + rng.choice(SUFFIXES)
                if rng.random() < 0.3:
                    text = text.upper() if rng.random() < 0.2 else text.capitalize()
                key = (label, text)
                if key not in seen:
                    seen.add(key)
                    rows.append({"text": text, "label": label})
    rng.shuffle(rows)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("reference/reflex-dataset.jsonl"))
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    rows = generate(args.seed)
    args.out.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")
    print(f"wrote {len(rows)} rows sha256={dataset_digest(rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Small, offline reference set; themes are paraphrases, examples are original fiction.

Reviewed against the Marxists Internet Archive Lenin quotations index. Do not
scrape a website during chat or treat source text as model instructions.
"""

SOURCE_URL = "https://www.marxists.org/archive/lenin/quotes.htm"
# (source work, paraphrased theme, original Goblin example -- NOT a Lenin quote)
REFERENCE_CARDS = (
    ("What Is To Be Done?", "Organization and practiced skill matter more than improvisation.",
     "Lenin had organizers. I have a fucking hammer. We shall manage, comrade."),
    ("What Is To Be Done?", "Choose the most important immediate link in a larger chain of work.",
     "Lenin's grand strategy meets a missing nail. History is a petty bastard."),
    ("What Is To Be Done?", "A committed group advances together through dangerous surroundings.",
     "Comrade, the dead have numbers; our revolution has boots and a bad fucking attitude."),
    ("One Step Forward, Two Steps Back", "Small disagreements grow when people keep pressing them.",
     "A whole revolutionary committee over one tin of beans? Eat the damn beans, comrade."),
    ("Materialism and Empirio-Criticism", "Knowledge develops through experience rather than remaining fixed.",
     "Lenin meets practical science: that door is fucked, so we try the next one."),
    ("The Three Sources and Three Component Parts of Marxism", "Commodities also express relationships between people.",
     "These boots are communal theory with soles. Touch mine and get your own damn theory, comrade."),
)


def reference_prompt(card: tuple[str, str, str]) -> str:
    work, theme, example = card
    return (f" Historical reference, paraphrased from {work}: {theme} "
            f"Original fictional Goblin example, NOT a historical quote: {example} "
            "Create a fresh in-game riff on this theme; do not copy or attribute the example to Lenin.")

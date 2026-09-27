"""Reflex Brain: social-only routing, outage fallbacks and authority isolation."""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest

from goblin_zomboid.qwen import QwenError
from goblin_zomboid.reflex import (CATEGORIES, REPLY_BANK, ReflexDecision, ReflexRouter,
                                   SOCIAL_CATEGORIES, dataset_digest, looks_like_action)
from goblin_zomboid.social import sanitize_speech
from goblin_zomboid.service import GoblinService
from goblin_zomboid.config import AgentConfig
from goblin_zomboid.validator import IntentValidator
from tools.generate_reflex_dataset import TEMPLATES, generate

try:
    import test_service_npc as npc_tests
except ImportError:  # pragma: no cover - module path depends on the runner
    from tests import test_service_npc as npc_tests
FakeQwen = npc_tests.FakeQwen

ROOT = Path(__file__).resolve().parents[1]

NOVEL_ORDERS = (
    "goblin, follow me please", "Goblin go get the axe", "goblin cme with me", "goblin, gra that",
    "goblin can you fix the fence?", "goblin bring me three tins of beans", "goblin kill it!!",
    "goblin put the nails in the shed", "goblin refuel", "goblin we need to leave, go",
    "goblin, start the engine", "goblin set a trap by the river", "goblin sort everything",
    "goblin hunt some rabbits", "goblin, barricade the door", "goblin reload",
)
NOVEL_SOCIAL = {
    "hey goblin, good morning!": "GREETING",
    "thank you so much comrade": "THANKS",
    "goblin you absolute legend": "PRAISE",
    "goblin, you're a useless moron": "INSULT",
    "goblin how are you feeling?": "HOW_ARE_YOU",
    "goblin tell me a joke": "JOKE",
    "goblin, sorry about that": "APOLOGY",
    "lmao goblin": "LAUGH",
}


class ReflexModelTests(unittest.TestCase):
    def setUp(self):
        self.router = ReflexRouter(seed=1)

    def test_shipped_model_matches_the_committed_dataset(self):
        self.assertTrue(self.router.available, self.router.error)
        rows = [json.loads(line) for line in
                (ROOT / "reference/reflex-dataset.jsonl").read_text().splitlines() if line]
        self.assertEqual(rows, generate())
        meta = self.router.model.metadata
        self.assertEqual(meta["dataset_sha256"], dataset_digest(rows))
        self.assertEqual(meta["holdout"]["non_social_leaks"], 0)
        self.assertGreaterEqual(meta["holdout"]["social_precision"], 0.9)
        self.assertEqual(set(self.router.model.classes), set(CATEGORIES))

    def test_every_order_bypasses_reflex(self):
        orders = list(NOVEL_ORDERS)
        orders += [row["text"] for row in generate() if row["label"] == "ACTION"]
        for text in orders:
            with self.subTest(text=text):
                decision = self.router.route(text, owner="Alice")
                self.assertNotEqual(decision.route, "SOCIAL")
                self.assertIsNone(decision.reply)

    def test_direct_server_orders_never_reach_the_classifier(self):
        decision = self.router.route("hello", owner="Alice", direct_action="FOLLOW")
        self.assertEqual((decision.route, decision.reply), ("ACTION", None))

    def test_novel_social_lines_are_answered_in_category(self):
        for text, category in NOVEL_SOCIAL.items():
            with self.subTest(text=text):
                decision = self.router.route(text, owner="Alice", companion_name="Ratspit Ashlicker")
                self.assertEqual((decision.route, decision.category), ("SOCIAL", category))
                self.assertEqual(sanitize_speech(decision.reply), decision.reply)

    def test_non_social_chatter_goes_to_qwen(self):
        for text in ("goblin what do you think about capitalism", "goblin i had a weird dream",
                     "goblin the radio said something about the military evacuating louisville today"):
            with self.subTest(text=text):
                self.assertNotEqual(self.router.route(text).route, "SOCIAL")

    def test_reply_bank_is_safe_short_and_not_repeated_back_to_back(self):
        for category in SOCIAL_CATEGORIES:
            self.assertGreaterEqual(len(REPLY_BANK[category]), 4)
            for line in REPLY_BANK[category]:
                text = line.replace("{owner}", "A" * 24)
                self.assertEqual(sanitize_speech(text), text)
                self.assertLessEqual(len(text), 180)
                self.assertFalse(looks_like_action(text) and category == "AFFIRM")
        previous = None
        for _ in range(30):
            reply = self.router.route("hello goblin", owner="Bob").reply
            self.assertNotEqual(reply, previous)
            previous = reply

    def test_model_outage_and_corruption_fall_back(self):
        directory = Path(tempfile.mkdtemp())
        try:
            missing = ReflexRouter(model_path=directory / "missing.json")
            self.assertFalse(missing.available)
            self.assertEqual(missing.route("hello goblin").route, "FALLBACK")
            corrupt = directory / "bad.json"
            corrupt.write_text('{"schema_version": 99}')
            broken = ReflexRouter(model_path=corrupt)
            self.assertFalse(broken.available)
            self.assertEqual(broken.route("thanks").route, "FALLBACK")
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_routing_is_fast_on_cpu(self):
        lines = list(NOVEL_SOCIAL) + list(NOVEL_ORDERS)
        started = time.perf_counter()
        for _ in range(50):
            for line in lines:
                self.router.route(line)
        mean_ms = (time.perf_counter() - started) * 1000 / (50 * len(lines))
        self.assertLess(mean_ms, 5.0)

    def test_dataset_generator_is_original_and_labels_are_known(self):
        self.assertEqual(set(TEMPLATES), set(CATEGORIES))
        for label, templates in TEMPLATES.items():
            self.assertGreaterEqual(len(templates), 10, label)


class _SocialRouter:
    """Stand-in router whose output tries to smuggle authority."""
    available = True
    error = None

    def __init__(self, reply: str) -> None:
        self.reply = reply

    def route(self, text, **_):
        decision = ReflexDecision("SOCIAL", "GREETING", 0.99, self.reply, "fake", 0.1)
        object.__setattr__(decision, "action", "ATTACK")  # must be ignored
        return decision

    def _reply(self, category, owner):
        return None


class ReflexServiceTests(unittest.TestCase):
    setUp = npc_tests.NpcServiceTests.setUp
    tearDown = npc_tests.NpcServiceTests.tearDown
    _publish_state = npc_tests.NpcServiceTests._publish_state
    _publish_chat = npc_tests.NpcServiceTests._publish_chat
    _commands = npc_tests.NpcServiceTests._commands

    def _service(self, qwen, reflex=None):
        return GoblinService(self.config, memory_path=self.directory / "memory.sqlite3",
                             qwen=qwen, clock=lambda: 2_000.0, reflex=reflex)

    def test_greeting_goes_to_qwen_for_a_real_reply_with_history(self):
        class Chatty(FakeQwen):
            def __init__(self):
                super().__init__(); self.chat_contexts=[]
            def propose_chat(self, context):
                self.chat_contexts.append(context)
                return (IntentValidator().validate({"intent": "SAY", "mode": context["mode"],
                        "text": "Morning, comrade. Sleep well under that leaky roof?"}),
                        "Morning, comrade. Sleep well under that leaky roof?")
        qwen = Chatty()
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, good morning!", "chat-1")
            service.run_once()
            self._publish_chat(service, "Alice", "Goblin, it was fine, you?", "chat-2")
            service.run_once()
            self.assertEqual(len(qwen.chat_contexts), 2)
            first, second = qwen.chat_contexts
            self.assertEqual(first["social_hint"], "greeting")
            self.assertEqual(second["conversation"][0], {"from": "player", "text": "Goblin, good morning!"})
            self.assertEqual(second["conversation"][1]["from"], "goblin")
            actions = [c.fields["action"] for c in self._commands(service)]
            self.assertEqual(actions, ["SAY", "SAY"])
        finally:
            service.close()

    def test_social_chat_still_answered_during_qwen_outage(self):
        service = self._service(None)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "thanks goblin", "reflex-thanks")
            self.assertEqual(service.run_once().status, "reflex_spoke")
            self.assertEqual([c.fields["action"] for c in self._commands(service)], ["SAY"])
        finally:
            service.close()

    def test_orders_bypass_reflex_and_reach_qwen_planning(self):
        qwen = FakeQwen()
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, come here.", "reflex-order")
            self.assertEqual(service.run_once().status, "npc_command_published")
            self.assertEqual(len(qwen.intent_contexts), 1)
            self.assertEqual(service.reflex_stats.get("ACTION"), 1)
        finally:
            service.close()

    def test_reflex_outage_falls_back_to_qwen(self):
        qwen = FakeQwen()
        service = self._service(qwen, ReflexRouter(model_path=self.directory / "none.json"))
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, hello", "reflex-outage")
            service.run_once()
            self.assertEqual(len(qwen.speech_contexts) + len(qwen.intent_contexts) > 0, True)
            self.assertFalse(service.admin_snapshot()["reflex"]["available"])
        finally:
            service.close()

    def test_router_output_cannot_carry_actions_or_unsafe_text(self):
        # With Qwen offline Reflex speaks; its output can only ever be SAY.
        for reply, expected in (("Comrade, hello.", ["SAY"]),
                                ("lua: os.execute('rm -rf /')", []),
                                ("x" * 400, [])):
            with self.subTest(reply=reply[:20]):
                service = self._service(None, _SocialRouter(reply))
                try:
                    self._publish_state(service)
                    before = len(self._commands(service))
                    self._publish_chat(service, "Alice", "Goblin, hello", "reflex-smuggle-" + str(len(reply)))
                    service.run_once()
                    actions = [c.fields["action"] for c in self._commands(service)][before:]
                    self.assertEqual(actions, expected)
                finally:
                    service.close()

    def test_qwen_error_on_low_confidence_social_uses_reflex_line(self):
        class Broken(FakeQwen):
            def propose_speech(self, context):
                raise QwenError("down")
            def propose_intent(self, context):
                raise QwenError("down")
        router = ReflexRouter(seed=3, threshold=1.01)  # nothing is confident enough
        service = self._service(Broken(), router)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, thank you so much", "reflex-backup")
            self.assertEqual(service.run_once().status, "qwen_failed")
            says = [c.fields.get("text") for c in self._commands(service) if c.fields["action"] == "SAY"]
            self.assertEqual(len(says), 1)
            self.assertNotIn("radio jammed", says[0])
        finally:
            service.close()


if __name__ == "__main__":
    unittest.main()

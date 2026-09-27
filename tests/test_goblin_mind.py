"""Goblin's memory and the free-will loop: think, banter, journal, recall safety."""
from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import unittest

from goblin_zomboid.mind import GoblinMind, trust_label
from goblin_zomboid.protocol import make_message
from goblin_zomboid.service import GoblinService
from goblin_zomboid.state import brain_view
from goblin_zomboid.validator import IntentValidator

try:
    import test_service_npc as npc_tests
except ImportError:  # pragma: no cover - module path depends on the runner
    from tests import test_service_npc as npc_tests
FakeQwen = npc_tests.FakeQwen


def situation(day=3, events=(), room="kitchen", nearby=()):
    return {"time": {"hour": 14, "period": "afternoon", "day": day},
            "threats": {"level": "clear", "within_10_tiles": 0, "within_30_tiles": 0},
            "place": {"room": room, "outdoors": False},
            "events": [dict(e) for e in events], "nearby_goblins": [dict(n) for n in nearby]}


class MindTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="goblin-mind-"))
        self.now = [1000.0]
        self.mind = GoblinMind(self.directory / "mind.sqlite3", clock=lambda: self.now[0])

    def tearDown(self):
        self.mind.close()
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_events_are_ingested_once_and_move_trust(self):
        events = [{"seq": 1, "kind": "horde", "text": "a horde closed in from the north"},
                  {"seq": 2, "kind": "job", "text": "SORT_STORAGE COMPLETE: sorted 12 items"}]
        companion = {"npc_id": "g1", "situation": situation(events=events)}
        seen = self.mind.observe(companion)
        self.assertEqual([e["seq"] for e in seen["events"]], [1, 2])
        self.assertEqual(self.mind.observe(companion)["events"], [])  # no double counting
        self.assertAlmostEqual(self.mind.trust("g1"), 0.6 - 0.03 + 0.005)
        texts = [row["text"] for row in self.mind.episodes("g1")]
        self.assertEqual(texts, [e["text"] for e in events])
        places = self.mind.places("g1")
        self.assertEqual(places[0]["name"], "kitchen")
        self.assertIn("went badly", places[0]["note"])

    def test_server_restart_resets_sequence_numbers(self):
        self.mind.observe({"npc_id": "g1", "situation": situation(events=[{"seq": 9, "kind": "kills", "text": "a"}])})
        seen = self.mind.observe({"npc_id": "g1", "situation": situation(events=[{"seq": 1, "kind": "kills", "text": "b"}])})
        self.assertEqual([e["text"] for e in seen["events"]], ["b"])

    def test_new_day_and_social_trust_and_labels(self):
        self.assertIsNone(self.mind.observe({"npc_id": "g1", "situation": situation(day=3)})["new_day"])
        self.assertEqual(self.mind.observe({"npc_id": "g1", "situation": situation(day=4)})["new_day"], 3)
        self.mind.social("g1", "INSULT")
        self.mind.social("g1", "GREETING")  # not a trust event
        self.assertAlmostEqual(self.mind.trust("g1"), 0.55)
        self.assertEqual(trust_label(0.1), "resentful")
        self.assertEqual(trust_label(1.0), "would die for you")
        for _ in range(100):
            self.mind.adjust_trust("g1", 0.05, "x")
        self.assertEqual(self.mind.trust("g1"), 1.0)

    def test_memory_is_bounded_and_digest_has_no_coordinates(self):
        for index in range(450):
            self.mind.record("g1", "chat", f"line {index}", day=1)
        self.assertEqual(len(self.mind.episodes("g1", 1000)), 400)
        self.mind.write_journal("g1", 1, "Rained. Comrade ate my beans.")
        digest = self.mind.digest("g1")
        self.assertEqual(digest["journal"], [{"day": 1, "text": "Rained. Comrade ate my beans."}])
        self.assertEqual(len(digest["recent_memories"]), 12)
        self.assertNotIn("x", str(sorted(digest)))
        self.assertTrue(self.mind.fallback_journal("g1", 1).startswith("line"))
        self.assertIn("Quiet", self.mind.fallback_journal("g1", 99))

    def test_memory_survives_restart(self):
        self.mind.record("g1", "chat", "remember me")
        self.mind.adjust_trust("g1", 0.2, "saved my life")
        self.mind.close()
        self.mind = GoblinMind(self.directory / "mind.sqlite3", clock=lambda: self.now[0])
        self.assertEqual(self.mind.episodes("g1")[0]["text"], "remember me")
        self.assertAlmostEqual(self.mind.trust("g1"), 0.8)

    def test_brain_view_hides_authority_tokens(self):
        view = brain_view({"companion_authority_token": "secret", "authority_token": "s2", "name": "Rat"})
        self.assertEqual(view, {"name": "Rat"})


class ThinkingQwen(FakeQwen):
    def __init__(self, action="SORT_STORAGE"):
        super().__init__()
        self.action = action
        self.think_contexts, self.banter_contexts, self.journal_contexts = [], [], []

    def propose_think(self, context):
        self.think_contexts.append(context)
        text = "Sorting your mess again, comrade. The shed smells like a kulak's sock."
        payload = {"intent": self.action, "mode": context["mode"]}
        if self.action == "SAY":
            payload["text"] = text
        if self.action == "FOLLOW":
            payload["target"] = {"kind": "player", "player": "speaker"}
        return IntentValidator().validate(payload), text

    def propose_banter(self, context):
        self.banter_contexts.append(context)
        first, second = [g["name"] for g in context["goblins"]]
        return [{"speaker": first, "text": "Your comrade builds walls like a Menshevik."},
                {"speaker": second, "text": "At least mine has a roof."}]

    def propose_journal(self, context):
        self.journal_contexts.append(context)
        return "Day three. Sorted the shed twice. Nobody thanked me."


class FreewillServiceTests(unittest.TestCase):
    setUp = npc_tests.NpcServiceTests.setUp
    tearDown = npc_tests.NpcServiceTests.tearDown
    _publish_chat = npc_tests.NpcServiceTests._publish_chat
    _commands = npc_tests.NpcServiceTests._commands

    def _service(self, qwen):
        self.now = [2000.0]
        service = GoblinService(self.config, memory_path=self.directory / "memory.sqlite3",
                                qwen=qwen, clock=lambda: self.now[0])
        service.think_initial_delay = 0
        return service

    def _state(self, service, **overrides):
        base = {"alive": True, "body_present": True, "body_mode": "npc", "control_ready": True,
                "npc_engine_ready": True, "mode": "PARTY", "weapon_ready": True, "owner_online": True,
                "owner_idle_seconds": 20, "task": "FOLLOW", "combat_state": "NONE", "freewill": True}
        alice = dict(base, npc_id="goblin.primary.alice", owner="Alice", name="Ratspit",
                     companion_authority_token="companion-alice",
                     situation=situation(nearby=[{"npc_id": "goblin.primary.bob", "name": "Snotgrub"}]))
        bob = dict(base, npc_id="goblin.primary.bob", owner="Bob", name="Snotgrub", freewill=False,
                   situation=situation(nearby=[{"npc_id": "goblin.primary.alice", "name": "Ratspit"}]))
        alice.update(overrides.pop("alice", {}))
        bob.update(overrides.pop("bob", {}))
        stamp = int(self.now[0] * 1000)
        service.store.publish_runtime("zomboid-heartbeat", make_message(
            "runtime.heartbeat", timestamp_ms=stamp, body_mode="npc", companion_count=2))
        service.store.publish_runtime("zomboid-state", make_message(
            "runtime.state", timestamp_ms=stamp, companions=[alice, bob],
            nearby_players=[{"id": "Alice"}, {"id": "Bob"}]))

    @staticmethod
    def _drain(service):
        if service.think_future is not None:
            service.think_future.result(timeout=5)

    def test_free_will_picks_a_job_with_the_companion_grant(self):
        qwen = ThinkingQwen()
        service = self._service(qwen)
        try:
            self._state(service)
            service.run_once()  # submits the think request in the background
            self._drain(service)
            result = service.run_once()
            self.assertEqual(result.status, "freewill_command_published")
            commands = self._commands(service)
            self.assertEqual(sorted(c.fields["action"] for c in commands), ["SAY", "SORT_STORAGE"])
            job = next(c.fields for c in commands if c.fields["action"] == "SORT_STORAGE")
            self.assertTrue(job["freewill"])
            self.assertEqual(job["authority_token"], "companion-alice")
            self.assertNotIn("autonomous", job)
            context = qwen.think_contexts[0]
            self.assertEqual(context["controlled_owner"], "Alice")
            self.assertIn("memory", context)
            self.assertEqual(context["situation"]["place"]["room"], "kitchen")
            self.assertNotIn("companion_authority_token", str(context))
            memories = service.mind.episodes("goblin.primary.alice")
            self.assertEqual(memories[-1]["kind"], "choice")
            self.assertEqual(service.dialogue["Alice"][-1]["from"], "goblin")
            # Next thought waits a full interval.
            service.run_once()
            self.assertIsNone(service.think_future)
        finally:
            service.close()

    def test_free_will_may_replace_scripted_filler_chores(self):
        qwen = ThinkingQwen()
        service = self._service(qwen)
        try:
            self._state(service, alice={"task": "LOOT", "autonomous": True}, bob={"situation": situation()})
            service.run_once()
            self._drain(service)
            self.assertEqual(service.run_once().status, "freewill_command_published")
        finally:
            service.close()

    def test_talk_turn_then_job_turn_and_no_repeated_lines(self):
        qwen = ThinkingQwen(action="SAY")
        service = self._service(qwen)
        try:
            self._state(service, bob={"situation": situation()})
            service.run_once(); self._drain(service)
            self.assertEqual(service.run_once().status, "think_spoke")
            npc = "goblin.primary.alice"
            self.assertGreaterEqual(service.next_think[npc], self.now[0] + 90)
            self.assertEqual(service.mind.episodes(npc)[-1]["day"], 3)
            service.next_think[npc] = 0
            service.run_once(); self._drain(service)
            context = qwen.think_contexts[-1]["event"]
            self.assertTrue(context["last_turn_was_talk"])
            self.assertEqual(len(context["your_recent_lines"]), 1)
            before = len(self._commands(service))
            service.run_once()  # identical line again: dropped, stays quiet
            self.assertEqual(len(self._commands(service)), before)
            self.assertEqual(service.think_stats.get("think_repeat_dropped"), 1)
        finally:
            service.close()

    def test_choosing_follow_while_following_is_not_published(self):
        qwen = ThinkingQwen(action="FOLLOW")
        service = self._service(qwen)
        try:
            self._state(service, bob={"situation": situation()})
            service.run_once(); self._drain(service)
            self.assertEqual(service.run_once().status, "think_spoke")
            self.assertEqual([c.fields["action"] for c in self._commands(service)], ["SAY"])
            self.assertEqual(service.think_stats.get("think_follow_noop"), 1)
        finally:
            service.close()

    def test_owner_order_or_busy_goblin_is_never_overridden(self):
        for override in ({"task": "WAIT"}, {"freewill": False}, {"owner_idle_seconds": 2},
                         {"combat_state": "ENGAGED"}, {"companion_authority_token": None}):
            with self.subTest(override=override):
                qwen = ThinkingQwen()
                service = self._service(qwen)
                try:
                    self._state(service, alice=dict(override, situation=situation()),
                                bob={"situation": situation()})
                    service.run_once()
                    self._drain(service)
                    service.run_once()
                    self.assertEqual(qwen.think_contexts, [])
                    self.assertEqual(self._commands(service), [])
                finally:
                    service.close()

    def test_decision_is_dropped_if_owner_gave_an_order_meanwhile(self):
        qwen = ThinkingQwen()
        service = self._service(qwen)
        try:
            self._state(service, bob={"situation": situation()})
            service.run_once()
            self._drain(service)
            self._state(service, alice={"task": "WAIT"}, bob={"situation": situation()})
            self.assertEqual(service.run_once().status, "think_cancelled")
            self.assertEqual(self._commands(service), [])
        finally:
            service.close()

    def test_goblins_banter_and_journal_with_memory(self):
        qwen = ThinkingQwen()
        service = self._service(qwen)
        try:
            # Alice's Goblin is busy with an order, so only social paths run.
            self._state(service, alice={"task": "WAIT"})
            service.run_once()
            self._drain(service)
            self.assertEqual(service.run_once().status, "banter_scheduled")
            names = [g["name"] for g in qwen.banter_contexts[0]["goblins"]]
            self.assertEqual(sorted(names), ["Ratspit", "Snotgrub"])
            says = [c for c in self._commands(service) if c.fields["action"] == "SAY"]
            self.assertEqual(len(says), 1)  # the second line is 4 s later
            self.now[0] += 5
            self._state(service, alice={"task": "WAIT"})
            service.run_once()
            says = [c for c in self._commands(service) if c.fields["action"] == "SAY"]
            self.assertEqual([c.fields["npc_id"] for c in says],
                             [says[0].fields["npc_id"], says[1].fields["npc_id"]])
            self.assertNotEqual(says[0].fields["npc_id"], says[1].fields["npc_id"])
            self.assertEqual(service.mind.episodes("goblin.primary.bob")[-1]["kind"], "met")
            # Pair cooldown: no second banter right away.
            service.run_once()
            self.assertIsNone(service.think_future)
            # A new day writes a journal: fallback first, Qwen's version replaces it.
            self._state(service, alice={"task": "WAIT", "situation": situation(day=4)},
                        bob={"situation": situation(day=4)})
            service.run_once()
            self.assertTrue(service.mind.journal("goblin.primary.alice"))
            self._drain(service)
            self._state(service, alice={"task": "WAIT", "situation": situation(day=4)},
                        bob={"situation": situation(day=4)})
            service.run_once()
            self._drain(service)
            service.run_once()
            entries = {row["text"] for row in service.mind.journal("goblin.primary.alice")}
            entries |= {row["text"] for row in service.mind.journal("goblin.primary.bob")}
            self.assertIn("Day three. Sorted the shed twice. Nobody thanked me.", entries)
        finally:
            service.close()

    def test_chat_carries_memory_and_updates_trust(self):
        class Chatty(ThinkingQwen):
            def propose_chat(self, context):
                self.chat = context
                return (IntentValidator().validate({"intent": "SAY", "mode": context["mode"], "text": "Hm."}), "Hm.")
        qwen = Chatty()
        service = self._service(qwen)
        try:
            self._state(service, alice={"freewill": False}, bob={"situation": situation()})
            self._publish_chat(service, "Alice", "Goblin, you useless idiot", "mind-chat")
            service.run_once()
            self.assertIn("trust_in_owner", qwen.chat["memory"])
            self.assertLess(service.mind.trust("goblin.primary.alice"), 0.6)
            self.assertEqual(service.mind.episodes("goblin.primary.alice")[-1]["kind"], "chat")
        finally:
            service.close()

    def test_think_failure_is_contained(self):
        class Broken(ThinkingQwen):
            def propose_think(self, context):
                raise RuntimeError("model fell over")
        service = self._service(Broken())
        try:
            self._state(service, bob={"situation": situation()})
            service.run_once()
            self._drain_quiet(service)
            self.assertNotEqual(service.run_once().status, "chat_failed")
            self.assertEqual(service.admin_snapshot()["free_will"]["stats"].get("think_failed"), 1)
        finally:
            service.close()

    @staticmethod
    def _drain_quiet(service):
        try:
            FreewillServiceTests._drain(service)
        except Exception:
            pass


if __name__ == "__main__":
    unittest.main()

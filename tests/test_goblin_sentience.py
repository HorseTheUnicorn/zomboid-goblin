"""Goblin Sentience V1: persistent self, event-driven cognition, goals and plans."""
from __future__ import annotations

from pathlib import Path
import json
import shutil
import tempfile
import unittest

from goblin_zomboid.mind import GoblinMind
from goblin_zomboid.qwen import QwenClient
from goblin_zomboid.sentience import PLAN_INTENTS, Sentience

try:
    import test_goblin_mind as mind_tests
except ImportError:  # pragma: no cover
    from tests import test_goblin_mind as mind_tests
situation = mind_tests.situation


def companion(**situation_overrides):
    base = situation()
    for key, value in situation_overrides.items():
        base[key] = value
    return {"npc_id": "g1", "owner": "Tom", "name": "Ratspit", "situation": base}


class SentienceTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="goblin-sentience-"))
        self.now = [5000.0]
        self.mind = GoblinMind(self.directory / "mind.sqlite3", clock=lambda: self.now[0])
        self.sentience = Sentience(self.mind, clock=lambda: self.now[0])

    def tearDown(self):
        self.mind.close()
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_owner_bitten_wakes_cognition_and_is_a_significant_memory(self):
        self.sentience.perceive(companion(owner={"bitten_parts": 0}), [])
        self.assertEqual(self.sentience.wants_reflection("g1")[0], True)  # no goal yet
        self.sentience.get("g1")["last_reflect_at"] = self.now[0]
        self.now[0] += 30
        self.assertFalse(self.sentience.wants_reflection("g1")[0])
        events = self.sentience.perceive(companion(owner={"bitten_parts": 1}), [])
        self.assertEqual([e["kind"] for e in events], ["owner_bitten"])
        wants, priority = self.sentience.wants_reflection("g1")
        self.assertTrue(wants)
        self.assertGreaterEqual(priority, 0.9)
        memories = self.mind.salient("g1", recent=0)
        self.assertEqual(memories[-1]["text"], "my comrade got bitten")
        self.assertGreaterEqual(memories[-1]["importance"], 0.9)
        self.assertGreater(self.mind.opinion("g1", "tom", "reckless"), 0)

    def test_derived_events_from_situation_changes(self):
        self.sentience.perceive(companion(time={"period": "afternoon", "day": 2},
                                          base={"distance": "at base"}), [])
        events = self.sentience.perceive(companion(time={"period": "evening", "day": 2},
                                                   base={"distance": "nearby"},
                                                   place={"room": "garage"},
                                                   nearby_goblins=[{"name": "Snotgrub"}]), [])
        kinds = sorted(e["kind"] for e in events)
        self.assertEqual(kinds, ["goblin_met", "new_place", "night_approaching", "owner_left_base"])

    def test_homestead_changes_are_noticed(self):
        home = lambda **h: {"distance": "at base", "set": True, "homestead": h}
        self.sentience.perceive(companion(base=home(power="grid", plants_need_water=0)), [])
        events = self.sentience.perceive(companion(base=home(power="none", plants_need_water=3)), [])
        self.assertEqual(sorted(e["kind"] for e in events), ["crops_thirsty", "power_down"])
        events = self.sentience.perceive(companion(base=home(power="generator", plants_ready=2)), [])
        self.assertEqual(sorted(e["kind"] for e in events), ["crops_ready", "power_restored"])

    def test_interrupt_suspends_and_completion_resumes_the_old_goal(self):
        self.sentience.apply_reflection("g1", {
            "mood": "grumpy", "thought": "Base is a sieve.", "decision": "new",
            "goal": "prepare the base for night", "reason": "dark soon",
            "plan": [{"intent": "INSPECT_BASE", "note": "look"}, {"intent": "SECURE_BASE", "note": "board"},
                     {"intent": "NUKE_MOSCOW", "note": "not a real intent"}]})
        state = self.sentience.get("g1")
        self.assertEqual([s["intent"] for s in state["plan"]], ["INSPECT_BASE", "SECURE_BASE"])
        self.sentience.step_result("g1", "INSPECT_BASE", True)
        self.assertEqual(self.sentience.current_step("g1")["intent"], "SECURE_BASE")
        self.sentience.apply_reflection("g1", {
            "mood": "alarmed", "thought": "Fuck the nails, Tom is bleeding.", "decision": "interrupt",
            "goal": "patch Tom up", "plan": [{"intent": "TREAT_PLAYER", "note": "bandage"}]})
        self.assertEqual(self.sentience.current_step("g1")["intent"], "TREAT_PLAYER")
        self.assertEqual(state["suspended_goal"]["goal"]["goal"], "prepare the base for night")
        self.sentience.step_result("g1", "TREAT_PLAYER", True)
        # Back to boarding windows, at the step he had reached.
        self.assertEqual(state["current_goal"]["goal"], "prepare the base for night")
        self.assertEqual(self.sentience.current_step("g1")["intent"], "SECURE_BASE")
        self.assertIsNone(state["suspended_goal"])
        self.assertEqual(state["thoughts"][-1], "Fuck the nails, Tom is bleeding.")

    def test_failed_step_wakes_a_rethink_and_owner_orders_do_not_advance_the_plan(self):
        self.sentience.apply_reflection("g1", {"mood": "ok", "thought": "t", "decision": "new", "goal": "g",
                                               "plan": [{"intent": "COOK", "note": "soup", "job": "soup"}]})
        self.sentience.step_result("g1", "SORT_STORAGE", True)  # an owner order, not the plan
        self.assertEqual(self.sentience.current_step("g1")["intent"], "COOK")
        self.sentience.get("g1")["last_reflect_at"] = 0
        self.sentience.step_result("g1", "COOK", False)
        self.assertEqual(self.sentience.current_step("g1")["intent"], "COOK")
        wants, priority = self.sentience.wants_reflection("g1")
        self.assertTrue(wants)
        self.assertGreaterEqual(priority, 0.5)

    def test_a_step_that_keeps_failing_is_skipped_not_retried_forever(self):
        self.sentience.apply_reflection("g1", {"mood": "ok", "thought": "t", "decision": "new", "goal": "g",
                                               "plan": [{"intent": "FETCH_ITEM", "note": "nails"},
                                                        {"intent": "SECURE_BASE", "note": "board"}]})
        self.sentience.step_result("g1", "FETCH_ITEM", False)
        self.assertEqual(self.sentience.current_step("g1")["intent"], "FETCH_ITEM")
        self.sentience.step_result("g1", "FETCH_ITEM", False)
        self.assertEqual(self.sentience.current_step("g1")["intent"], "SECURE_BASE")
        self.sentience.step_result("g1", "SECURE_BASE", True)
        episodes = self.mind.episodes("g1", 10)
        self.assertTrue(any("gave up on: g" in e["text"] for e in episodes))
        self.assertFalse(any("finished: g" in e["text"] for e in episodes))

    def test_model_completion_is_not_physical_evidence(self):
        self.sentience.apply_reflection("g1", {"decision": "new", "goal": "make dinner",
                                               "plan": [{"intent": "COOK"}, {"intent": "DELIVER"}]})
        self.sentience.apply_reflection("g1", {"decision": "complete", "thought": "I think dinner is done."})
        self.assertEqual(self.sentience.current_step("g1")["intent"], "COOK")
        self.sentience.step_result("g1", "COOK", True)
        self.sentience.step_result("g1", "DELIVER", True)
        self.assertIsNone(self.sentience.current_step("g1"))

    def test_survival_jobs_leave_conversation_ready_but_hold_other_freewill_actions(self):
        from goblin_zomboid.service import GoblinService
        report = {"owner_online": True, "body_present": True, "control_ready": True,
                  "npc_engine_ready": True, "freewill": True, "owner_idle_seconds": 40,
                  "task": "FOLLOW", "companion_authority_token": "token",
                  "situation": {"goblin": {"survival_busy": True}}}
        self.assertTrue(GoblinService._social_ready(report))
        self.assertFalse(GoblinService._think_eligible(report))
        report["situation"]["goblin"]["survival_busy"] = False
        self.assertTrue(GoblinService._think_eligible(report))

    def test_skipping_a_cooling_plan_never_records_success(self):
        self.sentience.apply_reflection("g1", {"decision": "new", "goal": "make dinner",
                                               "plan": [{"intent": "COOK"}]})
        self.sentience.note_job("g1", "COOK", False, "stove cold")
        self.sentience.skip_cooling_steps("g1")
        self.assertIsNone(self.sentience.current_step("g1"))
        self.assertTrue(any("gave up on: make dinner" in e["text"] for e in self.mind.episodes("g1", 10)))

    def test_measured_food_shortage_is_noticed(self):
        self.sentience.perceive(companion(base={"food_reserve": {"known": True, "shortage": 0}}), [])
        events = self.sentience.perceive(companion(base={"food_reserve": {"known": True, "shortage": 3}}), [])
        self.assertIn("food_low", [e["kind"] for e in events])

    def test_failed_or_finished_chores_cool_down_and_are_kept_out_of_plans(self):
        self.sentience.note_job("g1", "CLOSE_CURTAINS", False, "skipped 3 unreachable curtain(s)")
        self.sentience.note_job("g1", "FORTIFY", True, "no more accessible windows need boards")
        self.sentience.note_job("g1", "LOOT", True, "looted 8")
        cooling = self.sentience.cooling("g1")
        self.assertEqual(sorted(cooling), ["CLOSE_CURTAINS", "SECURE_BASE"])  # loot may repeat
        self.sentience.apply_reflection("g1", {"mood": "ok", "thought": "t", "decision": "new", "goal": "g",
                                               "plan": [{"intent": "CLOSE_CURTAINS", "note": "x"},
                                                        {"intent": "SECURE_BASE", "note": "y"},
                                                        {"intent": "FORAGE", "note": "z"}]})
        self.assertEqual([s["intent"] for s in self.sentience.get("g1")["plan"]], ["FORAGE"])
        self.assertIn("CLOSE_CURTAINS", self.sentience.reflection_context("g1")["avoid_for_now"])
        self.now[0] += 1000
        self.assertEqual(self.sentience.cooling("g1"), {})

    def test_opinions_drift_and_self_survives_restart(self):
        for _ in range(3):
            self.sentience.apply_reflection("g1", {"mood": "fond", "thought": "He is alright.",
                                                   "decision": "continue",
                                                   "opinions": [{"subject": "Tom", "trait": "trustworthy",
                                                                 "value": 1.0}]})
        value = self.mind.opinion("g1", "tom", "trustworthy")
        self.assertTrue(0.6 < value < 1.0, value)  # drifted, not jumped
        self.sentience.apply_reflection("g1", {"mood": "busy", "thought": "x", "decision": "new", "goal": "stock up",
                                               "plan": [{"intent": "FORAGE", "note": "berries"}],
                                               "expectation": {"about": "Tom", "expect": "leaving again soon"}})
        self.mind.close()
        self.mind = GoblinMind(self.directory / "mind.sqlite3", clock=lambda: self.now[0])
        again = Sentience(self.mind, clock=lambda: self.now[0])
        view = again.view("g1")
        self.assertEqual(view["current_goal"]["goal"], "stock up")
        self.assertEqual(view["current_step"]["intent"], "FORAGE")
        self.assertEqual(view["mood"], "busy")
        self.assertEqual(view["expectations"], {"Tom": "leaving again soon"})
        self.assertIn("tom", self.mind.opinions("g1"))

    def test_salient_memory_keeps_the_near_death_over_a_week_of_chores(self):
        self.mind.record("g1", "owner_hurt", "Tom nearly bled out in the warehouse", 1,
                         importance=0.95, valence=-0.9, place="warehouse", entities=["Tom"])
        for index in range(600):
            self.mind.record("g1", "job", f"moved nails {index}", 2)
        texts = [m["text"] for m in self.mind.salient("g1", place="warehouse", entities=("Tom",))]
        self.assertIn("Tom nearly bled out in the warehouse", texts)
        digest = self.mind.digest("g1", place="warehouse")
        self.assertEqual(digest["significant_memories"][0]["place"], "warehouse")

    def test_reflection_schema_matches_the_plan_intents(self):
        schema = QwenClient._reflect_schema()
        json.dumps(schema)
        step_enum = schema["properties"]["plan"]["items"]["properties"]["intent"]["enum"]
        self.assertEqual(step_enum, list(PLAN_INTENTS))
        self.assertEqual(schema["required"], ["mood", "thought", "decision"])


class ReflectingQwen(mind_tests.ThinkingQwen):
    def __init__(self, say="", decision="new"):
        super().__init__()
        self.say, self.decision = say, decision
        self.reflect_contexts = []

    def propose_reflect(self, context):
        self.reflect_contexts.append(context)
        return {"mood": "wary", "thought": "Night is coming and the windows are bare.",
                "decision": self.decision, "goal": "secure the base before dark", "reason": "sunset",
                "plan": [{"intent": "SORT_STORAGE", "note": "clear the doorway first"},
                         {"intent": "SECURE_BASE", "note": "board up"}],
                "say": self.say}


class SentienceServiceTests(unittest.TestCase):
    setUp = mind_tests.FreewillServiceTests.setUp
    tearDown = mind_tests.FreewillServiceTests.tearDown
    _commands = mind_tests.FreewillServiceTests._commands
    _service = mind_tests.FreewillServiceTests._service
    _state = mind_tests.FreewillServiceTests._state
    _drain = staticmethod(mind_tests.FreewillServiceTests._drain)

    def test_goblin_forms_a_goal_then_acts_on_its_first_step(self):
        qwen = ReflectingQwen()
        service = self._service(qwen)
        try:
            self._state(service, bob={"situation": situation()})
            service.run_once(); self._drain(service)          # reflect first (no goal yet)
            self.assertEqual(service.run_once().status, "sentience_thought")
            npc = "goblin.primary.alice"
            self.assertEqual(service.sentience.current_step(npc)["intent"], "SORT_STORAGE")
            context = qwen.reflect_contexts[0]
            self.assertIn("self", context)
            self.assertNotIn("companion_authority_token", str(context))
            # Nothing was said aloud: the thought stayed private.
            self.assertEqual(self._commands(service), [])
            service.next_think[npc] = 0
            service.run_once(); self._drain(service)          # physical turn follows the plan
            think = qwen.think_contexts[-1]
            self.assertEqual(think["sentience"]["current_step"]["intent"], "SORT_STORAGE")
            self.assertEqual(think["sentience"]["current_goal"]["goal"], "secure the base before dark")
            self.assertEqual(service.run_once().status, "freewill_command_published")
            snapshot = service.admin_snapshot()["sentience"][npc]
            self.assertEqual(snapshot["mood"], "wary")
        finally:
            service.close()

    def test_important_news_is_thought_about_while_the_owner_is_moving(self):
        qwen = ReflectingQwen()
        service = self._service(qwen)
        try:
            npc = "goblin.primary.alice"
            moving = {"owner_idle_seconds": 0}
            self._state(service, alice=dict(moving, situation=situation()), bob={"situation": situation()})
            service.run_once(); self._drain(service); service.run_once()  # first goal
            service.sentience.get(npc)["last_reflect_at"] = self.now[0] - 25
            qwen.say = "Comrade, you are bleeding like a kulak's wallet. Hold still."
            hurt = situation(events=[{"seq": 1, "kind": "owner_hurt", "text": "owner took a bad hit"}])
            self._state(service, alice=dict(moving, situation=hurt), bob={"situation": situation()})
            service.run_once(); self._drain(service)
            self.assertEqual(service.run_once().status, "sentience_spoke")
            says = [c for c in self._commands(service) if c.fields["action"] == "SAY"]
            self.assertEqual(len(says), 1)
            # He only thinks while Alice runs; no physical free-will job started.
            self.assertEqual([c.fields["action"] for c in self._commands(service)], ["SAY"])
            self.assertEqual(len(qwen.reflect_contexts), 2)
            happened = qwen.reflect_contexts[1]["what_just_happened"]
            self.assertEqual(happened[0]["kind"], "owner_hurt")
        finally:
            service.close()

    def test_job_result_from_the_game_advances_the_plan(self):
        qwen = ReflectingQwen()
        service = self._service(qwen)
        try:
            npc = "goblin.primary.alice"
            self._state(service, bob={"situation": situation()})
            service.run_once(); self._drain(service); service.run_once()
            done = situation(events=[{"seq": 1, "kind": "job", "freewill": True,
                                      "text": "SORT_STORAGE COMPLETE: sorted 4 items"}])
            self._state(service, alice={"situation": done}, bob={"situation": situation()})
            service.run_once()
            self.assertEqual(service.sentience.current_step(npc)["intent"], "SECURE_BASE")
        finally:
            service.close()

    def test_a_failed_freewill_command_counts_as_a_failed_step(self):
        qwen = ReflectingQwen()
        service = self._service(qwen)
        try:
            npc = "goblin.primary.alice"
            self._state(service, bob={"situation": situation()})
            service.run_once(); self._drain(service); service.run_once()
            service.freewill_requests["req-1"] = (npc, "SORT_STORAGE")

            class Message:
                request_id = "req-1"
                fields = {"status": "failed", "detail": "no storage"}
                timestamp_ms = 1

            class Response:
                message = Message()

            service.response_consumer.poll = lambda **_: [Response()]
            service.response_consumer.finalize = lambda *a, **k: None
            service._poll_responses()
            service._poll_responses()
            self.assertEqual(service.sentience.current_step(npc)["intent"], "SORT_STORAGE")
            self.assertEqual(service.sentience.current_step(npc).get("failures"), 1)
        finally:
            service.close()


if __name__ == "__main__":
    unittest.main()

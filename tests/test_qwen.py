from __future__ import annotations

import json
import unittest

from goblin_zomboid.qwen import QwenClient, QwenError
from goblin_zomboid.validator import IntentValidator


class QwenCompatibilityTests(unittest.TestCase):
    def test_plan_prompt_describes_required_action_fields(self) -> None:
        prompt = QwenClient._plan_system_prompt()
        self.assertIn("same identity used on Discord", prompt)
        self.assertIn("cave-weirdness as seasoning", prompt)
        self.assertIn("Never use emojis", prompt)
        self.assertIn("ASSIGN_JOB requires", prompt)
        self.assertIn("FORM_SQUAD", prompt)
        self.assertIn("FOLLOW_PLAYER and DEFEND_PLAYER require", prompt)

    def test_speech_prompt_uses_shared_discord_personality_overlay(self) -> None:
        prompt = QwenClient._speech_system_prompt()
        self.assertIn("same identity used on Discord", prompt)
        self.assertIn("occasionally warm", prompt)
        self.assertIn("never grants game-admin authority", prompt)

    def test_normalizes_nested_say_only_for_say_command(self) -> None:
        raw = json.dumps(
            {
                "commands": [
                    {
                        "survivor_id": "goblin.primary",
                        "action": "SAY",
                        "target_id": "player.horse",
                        "say": "Reporting, player.",
                    },
                    {
                        "survivor_id": "goblin.primary",
                        "action": "FOLLOW_PLAYER",
                        "target_id": "player.horse",
                    },
                ]
            }
        )
        normalized = QwenClient._normalize_plan_compatibility(raw)
        plan = IntentValidator().validate_plan_json(normalized)
        self.assertEqual(plan.commands[0].data["text"], "Reporting, player.")
        self.assertEqual(plan.commands[1].intent, "FOLLOW_PLAYER")

    def test_does_not_hide_unknown_say_field_on_other_actions(self) -> None:
        raw = json.dumps(
            {
                "commands": [
                    {
                        "survivor_id": "goblin.primary",
                        "action": "HOLD",
                        "say": "not a hold field",
                    }
                ]
            }
        )
        self.assertEqual(QwenClient._normalize_plan_compatibility(raw), raw)

    def test_plan_uses_one_strict_repair_retry(self) -> None:
        class RetryClient(QwenClient):
            def __init__(self) -> None:
                super().__init__()
                self.responses = [
                    json.dumps({
                        "commands": [
                            {"survivor_id": "goblin.primary", "action": "HOLD"}
                        ] * 5
                    }),
                    json.dumps({"say": "Standing by.", "commands": []}),
                ]

            def _request_json(self, _system_prompt, _payload, *, max_tokens):
                if max_tokens not in {256, 384}:
                    raise AssertionError(f"unexpected max_tokens: {max_tokens}")
                return self.responses.pop(0)

        client = RetryClient()
        plan = client.propose_plan({"safe": True})
        self.assertEqual(plan.say, "Standing by.")
        self.assertEqual(plan.commands, ())
        self.assertEqual(client.responses, [])

    def test_plan_repair_still_fails_closed_after_one_retry(self) -> None:
        class BrokenClient(QwenClient):
            def __init__(self) -> None:
                super().__init__()
                self.calls = 0

            def _request_json(self, _system_prompt, _payload, *, max_tokens):
                self.calls += 1
                return "{}"

        client = BrokenClient()
        with self.assertRaises(QwenError):
            client.propose_plan({"safe": True})
        self.assertEqual(client.calls, 2)


if __name__ == "__main__":
    unittest.main()

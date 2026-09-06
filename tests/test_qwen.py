from __future__ import annotations

import json
import unittest

from goblin_zomboid.qwen import QwenClient
from goblin_zomboid.validator import IntentValidator


class QwenCompatibilityTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()

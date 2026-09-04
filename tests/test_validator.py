from __future__ import annotations

import unittest

from goblin_zomboid.validator import IntentError, IntentValidator


class ValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.validator = IntentValidator()

    def test_normalizes_high_level_say(self) -> None:
        result = self.validator.validate(
            {
                "intent": "say",
                "mode": "party",
                "text": "Stay close, meatbags.",
            }
        )
        self.assertEqual(result.intent, "SAY")
        self.assertEqual(result.mode, "PARTY")
        self.assertEqual(result.data["text"], "Stay close, meatbags.")

    def test_rejects_unknown_fields_and_code(self) -> None:
        with self.assertRaises(IntentError):
            self.validator.validate(
                {
                    "intent": "WAIT",
                    "mode": "SAFE",
                    "extra": "no",
                }
            )
        with self.assertRaises(IntentError):
            self.validator.validate_json(
                '{"intent":"WAIT","mode":"SAFE","command":"os.execute()"}'
            )

    def test_safe_mode_rejects_movement(self) -> None:
        with self.assertRaises(IntentError):
            self.validator.validate(
                {
                    "intent": "MOVE_TO",
                    "mode": "SAFE",
                    "target": {"kind": "area", "name": "the street"},
                }
            )

    def test_rejects_exact_coordinates_and_arbitrary_targets(self) -> None:
        with self.assertRaises(IntentError):
            self.validator.validate(
                {
                    "intent": "MOVE_TO",
                    "mode": "ROAM",
                    "target": {
                        "kind": "area",
                        "name": "x=12 y=40 z=0",
                    },
                }
            )

    def test_movement_recovery_intents_require_semantic_targets(self) -> None:
        for intent in ("FLEE", "RETREAT", "REGROUP", "GO_HOME", "RETURN_TO_BASE"):
            with self.subTest(intent=intent):
                with self.assertRaises(IntentError):
                    self.validator.validate({"intent": intent, "mode": "ROAM"})

        result = self.validator.validate(
            {
                "intent": "FLEE",
                "mode": "PARTY",
                "target": {"kind": "escape_route", "name": "nearest safe route"},
            }
        )
        self.assertEqual(result.intent, "FLEE")
        with self.assertRaises(IntentError):
            self.validator.validate(
                {
                    "intent": "MOVE_TO",
                    "mode": "ROAM",
                    "target": {"kind": "lua", "name": "anything"},
                }
            )

    def test_hunt_relocation_uses_a_coarse_candidate(self) -> None:
        result = self.validator.validate(
            {
                "intent": "HUNT_RELOCATE",
                "mode": "HUNT",
                "candidate": {
                    "kind": "nearby_building",
                    "label": "an abandoned storefront",
                    "clue": "where the old signs point",
                },
            }
        )
        self.assertEqual(result.data["candidate"]["kind"], "nearby_building")

    def test_rejects_markdown_and_recursive_coordinates(self) -> None:
        with self.assertRaises(IntentError):
            markdown = chr(96) * 3 + "json\n" + '{"intent":"WAIT","mode":"SAFE"}' + "\n" + chr(96) * 3
            self.validator.validate_json(markdown)
        with self.assertRaises(IntentError):
            self.validator.validate(
                {
                    "intent": "WAIT",
                    "mode": "SAFE",
                    "abort_if": ["stop"],
                    "item": {"name": "water", "x": 1},
                }
            )


if __name__ == "__main__":
    unittest.main()

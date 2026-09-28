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

    def test_cook_and_trap_jobs(self) -> None:
        soup = self.validator.validate({"intent": "COOK", "mode": "SAFE", "job": "soup", "item": {"count": 6}})
        self.assertEqual(soup.data["job"], "soup")
        place = self.validator.validate({"intent": "CHECK_TRAPS", "mode": "SAFE", "job": "place", "item": {"count": 3}})
        self.assertEqual(place.data["job"], "place")
        for bad in ({"intent": "COOK", "mode": "SAFE", "job": "cake"},
                    {"intent": "COOK", "mode": "SAFE", "job": "food", "item": {"count": 6}},
                    {"intent": "CHECK_TRAPS", "mode": "SAFE", "job": "place", "item": {"count": 6}}):
            with self.assertRaises(IntentError):
                self.validator.validate(bad)

    def test_equip_requires_the_preferred_weapon(self) -> None:
        result = self.validator.validate(
            {
                "intent": "EQUIP",
                "mode": "SAFE",
                "item": {"name": "Base.DoubleBarrelShotgun"},
            }
        )
        self.assertEqual(result.intent, "EQUIP")
        with self.assertRaises(IntentError):
            self.validator.validate({"intent": "EQUIP", "mode": "SAFE"})
        for forbidden in ("Base.Axe", "Base.Machete", "Base.Pistol3"):
            with self.assertRaises(IntentError):
                self.validator.validate(
                    {
                        "intent": "EQUIP",
                        "mode": "SAFE",
                        "item": {"name": forbidden},
                    }
                )

    def test_loot_focus_remains_a_bounded_high_level_field(self) -> None:
        result = self.validator.validate(
            {
                "intent": "LOOT_AREA",
                "mode": "ROAM",
                "target": {"kind": "area", "name": "the nearby block"},
                "loot_focus": "medical",
            }
        )
        self.assertEqual(result.data["loot_focus"], "medical")
        with self.assertRaises(IntentError):
            self.validator.validate(
                {
                    "intent": "LOOT_AREA",
                    "mode": "ROAM",
                    "target": {"kind": "area", "name": "the nearby block"},
                    "loot_focus": "lua",
                }
            )

    def test_gain_access_requires_semantic_target_and_model_cannot_authorize_breach(self) -> None:
        result = self.validator.validate(
            {
                "intent": "GAIN_ACCESS",
                "mode": "ROAM",
                "target": {"kind": "building", "label": "the nearby house"},
            }
        )
        self.assertEqual(result.intent, "GAIN_ACCESS")
        self.assertEqual(result.data["target"]["kind"], "building")
        with self.assertRaises(IntentError):
            self.validator.validate({"intent": "GAIN_ACCESS", "mode": "ROAM"})
        with self.assertRaises(IntentError):
            self.validator.validate(
                {
                    "intent": "GAIN_ACCESS",
                    "mode": "ROAM",
                    "target": {"kind": "building", "label": "the nearby house"},
                    "allow_breach": True,
                }
            )

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

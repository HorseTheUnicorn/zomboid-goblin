from __future__ import annotations

import json
import unittest

from goblin_zomboid.character import VanillaCatalog
from goblin_zomboid.qwen import QwenClient, QwenError


class QwenCatalogTests(unittest.TestCase):
    def test_large_vanilla_catalog_gets_a_bounded_model_view(self) -> None:
        options: dict[str, list[dict[str, str]]] = {
            category: [
                {"id": option_id, "label": label, "source": "vanilla"}
                for option_id, label in values
            ]
            for category, values in {
                "gender": [("male", "Male")],
                "skin_tone": [("tone1", "Tone 1")],
                "hair_style": [("messy", "Messy")],
                "hair_color": [("brown", "Brown")],
                "profession": [("unemployed", "Unemployed")],
                "trait": [("outdoorsman", "Outdoorsman")],
            }.items()
        }
        for index in range(80):
            options[f"clothing_slot{index}"] = [
                {
                    "id": f"item{item}",
                    "label": f"vanilla denim item {item}",
                    "source": "vanilla",
                }
                for item in range(256)
            ]
        catalog = VanillaCatalog.from_mapping(
            {"version": "build42-large", "options": options}
        )

        compact = QwenClient._character_catalog_for_model(catalog)
        encoded = json.dumps(
            compact,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
        ).encode("utf-8")
        self.assertLessEqual(len(encoded), 24 * 1024)
        for category in (
            "gender",
            "skin_tone",
            "hair_style",
            "hair_color",
            "profession",
            "trait",
        ):
            self.assertIn(category, compact["options"])
        self.assertTrue(
            any(category.startswith("clothing_") for category in compact["options"])
        )
        self.assertTrue(
            all(
                option["source"] == "vanilla"
                for values in compact["options"].values()
                for option in values
            )
        )

    def test_speech_requires_a_single_bounded_text_field(self) -> None:
        client = QwenClient()
        client._request_json = lambda *_args, **_kwargs: '{"text":"Keep your voice down."}'
        self.assertEqual(
            client.propose_speech({"event": {"speaker": "Alice", "text": "Goblin?"}}),
            "Keep your voice down.",
        )

        client._request_json = lambda *_args, **_kwargs: '{"text":"```shell: rm -rf```"}'
        with self.assertRaises(QwenError):
            client.propose_speech({"event": {"speaker": "Alice", "text": "Goblin?"}})


if __name__ == "__main__":
    unittest.main()

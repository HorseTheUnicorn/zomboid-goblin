from pathlib import Path
import re
import unittest


ADAPTER = (
    Path(__file__).resolve().parents[1]
    / "mod"
    / "Contents"
    / "mods"
    / "GoblinSurvivor"
    / "42"
    / "media"
    / "lua"
    / "server"
    / "GoblinSurvivor"
    / "BanditsAdapter.lua"
)


class BanditsProfileContractTests(unittest.TestCase):
    def test_managed_profiles_use_stable_uuid_framework_ids(self) -> None:
        source = ADAPTER.read_text(encoding="utf-8")
        framework_ids = dict(
            re.findall(r'\["([^"\n]+)"\]\s*=\s*"([^"\n]+)"', source)
        )
        expected = {
            "goblin.primary",
            "npc.sarah",
            "npc.bob",
            "npc.dave",
            "npc.ellen",
            "npc.mike",
            "npc.june",
            "npc.lee",
            "npc.rosa",
        }
        self.assertEqual(set(framework_ids), expected)
        self.assertEqual(len(set(framework_ids.values())), len(expected))
        uuid_pattern = re.compile(
            r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
            r"[0-9a-f]{4}-[0-9a-f]{12}$"
        )
        for framework_id in framework_ids.values():
            self.assertRegex(framework_id, uuid_pattern)
        self.assertRegex(
            re.search(r'local clanId = "([^"]+)"', source).group(1),
            uuid_pattern,
        )

    def test_profiles_are_saved_to_server_local_bandits_data(self) -> None:
        source = ADAPTER.read_text(encoding="utf-8")
        self.assertIn('profile.general.modid = "LOCAL"', source)
        self.assertIn("profile.general.bid = frameworkId", source)
        self.assertIn('profile.general.cid = clanId', source)


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

from pathlib import Path
import unittest


MOD_ROOT = (
    Path(__file__).resolve().parents[1]
    / "mod"
    / "Contents"
    / "mods"
    / "GoblinSurvivor"
    / "42"
)
SERVER_ROOT = MOD_ROOT / "media" / "lua" / "server" / "GoblinSurvivor"
ADAPTER = SERVER_ROOT / "NativeNpcAdapter.lua"
INVENTORY = SERVER_ROOT / "InventoryManager.lua"
FACADE = SERVER_ROOT / "NpcAdapter.lua"
MOD_INFO = MOD_ROOT / "mod.info"
WORKSHOP = MOD_ROOT.parents[3] / "workshop.txt"


class NativeNpcContractTests(unittest.TestCase):
    def test_native_spawn_uses_the_build42_surface(self) -> None:
        source = ADAPTER.read_text(encoding="utf-8")
        for symbol in (
            "createZombie",
            "SurvivorFactory",
            "CreateSurvivor",
            "IsoZombie",
            "addZombiesInOutfit",
            "VirtualZombieManager",
            "managerChoices",
            "choice probe",
            "createRealZombieAlways",
            "createRealZombieNow",
            "addZombiesInOutfitArea",
            "IsoDirections",
            "getCurrentSquare",
            "getSquare",
            "canStand",
            "getOrCreateGridSquare",
            "createRealZombie",
            "getModData",
            "transmitModData",
        ):
            self.assertIn(symbol, source)
        self.assertIn("No IsoSquare selected", source)
        self.assertIn("createZombie failed (", source)
        self.assertNotIn("IsoZombie.new(", source)
        self.assertIn("goblin_engine = NativeAdapter.engineName()", source)
        self.assertIn('networkedBody = "ProjectZomboid/IsoZombie"', source)

    def test_ownership_is_marker_and_reservation_based(self) -> None:
        source = ADAPTER.read_text(encoding="utf-8")
        for marker in (
            "goblin_npc_id",
            "goblin_owned",
            "goblin_friendly",
            "goblin_hostile",
            "spawnReservation",
            "isEventCandidate",
        ):
            self.assertIn(marker, source)
        self.assertNotIn("Bandits", source)
        self.assertNotIn("Bandit", source)
        self.assertNotIn("3268487204", source)

    def test_facade_exposes_only_the_native_adapter(self) -> None:
        source = FACADE.read_text(encoding="utf-8")
        self.assertIn('require("GoblinSurvivor/NativeNpcAdapter")', source)
        self.assertNotIn("Bandits", source)
        self.assertNotIn("Bandit", source)

    def test_native_survival_actions_use_documented_body_and_inventory_surface(self) -> None:
        source = INVENTORY.read_text(encoding="utf-8")
        for symbol in (
            "getInventory",
            "getFirstCategory",
            "getFirstWaterFluidSources",
            "Eat",
            "DrinkFluid",
            "getBodyDamage",
            "UseBandageOnMostNeededPart",
        ):
            self.assertIn(symbol, source)

    def test_package_metadata_has_no_external_body_dependency(self) -> None:
        for path in (MOD_INFO, WORKSHOP):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("3268487204", source)
            self.assertNotIn("Bandits", source)
            self.assertNotIn("Bandit", source)


if __name__ == "__main__":
    unittest.main()

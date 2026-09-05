from __future__ import annotations

from pathlib import Path
import unittest


MOD = (
    Path(__file__).resolve().parents[1]
    / "mod"
    / "Contents"
    / "mods"
    / "GoblinSurvivor"
    / "42"
)
SHARED = MOD / "media" / "lua" / "shared" / "GoblinSurvivor"
SERVER = MOD / "media" / "lua" / "server" / "GoblinSurvivor"
TOOLS = Path(__file__).resolve().parents[1] / "tools"


class StandaloneSurvivorContractTests(unittest.TestCase):
    def test_namespace_and_identity_contract_exist(self) -> None:
        for filename in (
            "GSSurvivor.lua",
            "GSSurvivorBrain.lua",
            "GSSurvivorTasks.lua",
            "GSSurvivorActions.lua",
            "GSSurvivorCombat.lua",
            "GSSurvivorPerception.lua",
            "GSSurvivorVisuals.lua",
            "GSSurvivorZombieInteraction.lua",
            "GSSurvivorSync.lua",
            "GSSurvivorRegistry.lua",
            "GSSurvivorSpawner.lua",
        ):
            self.assertTrue((SERVER / filename).exists(), filename)
        identity = (SHARED / "Identity.lua").read_text(encoding="utf-8")
        for marker in (
            "GoblinSurvivorNPC",
            "GoblinSurvivorID",
            "GoblinSurvivorType",
            "GoblinSurvivorVersion",
            "function Identity.isManaged",
            "function Identity.mark",
        ):
            self.assertIn(marker, identity)

    def test_survivorize_is_the_conversion_boundary(self) -> None:
        source = (SERVER / "GSSurvivor.lua").read_text(encoding="utf-8")
        adapter = (SERVER / "NativeNpcAdapter.lua").read_text(encoding="utf-8")
        self.assertIn("function Survivor.Survivorize", source)
        self.assertIn("Identity.mark", source)
        self.assertIn("GoblinSurvivor/GSSurvivor", adapter)
        self.assertNotIn("IsoPlayer.new(", source)
        self.assertNotIn("IsoZombie.new(", source)

    def test_queue_has_bounded_public_operations(self) -> None:
        source = (SERVER / "GSSurvivorTasks.lua").read_text(encoding="utf-8")
        for operation in ("Add", "Peek", "Pop", "Clear", "HasTask"):
            self.assertIn(f"function Tasks.{operation}", source)
        self.assertIn("#list >= 32", source)
        self.assertIn("taskQueue", source)

    def test_perception_uses_bucket_cache_and_is_staggered(self) -> None:
        source = (SERVER / "GSSurvivorPerception.lua").read_text(encoding="utf-8")
        for marker in (
            "bucketSize = 10",
            "refreshIntervalMs = 500",
            "math.floor(point.x / Perception.bucketSize)",
            "nearbySurvivors",
            "nearbyZombies",
            "function Perception.allZombies",
        ):
            self.assertIn(marker, source)

    def test_zombie_interaction_preserves_player_targets(self) -> None:
        source = (SERVER / "GSSurvivorZombieInteraction.lua").read_text(encoding="utf-8")
        self.assertIn("getTarget", source)
        self.assertIn("isPlayer", source)
        self.assertIn("valid player target", source)
        self.assertIn("setTarget", source)
        self.assertIn("NoLungeAttack", source)

    def test_external_ai_is_not_in_the_low_level_action_contract(self) -> None:
        source = (SERVER / "GSSurvivorActions.lua").read_text(encoding="utf-8")
        self.assertIn("Follow", source)
        self.assertIn("MeleeAttack", source)
        self.assertIn("timeoutMs", source)
        self.assertNotIn("Qwen", source)
        self.assertNotIn("coordinates", source)

    def test_combat_keeps_target_policy_above_native_adapter(self) -> None:
        source = (SERVER / "GSSurvivorCombat.lua").read_text(encoding="utf-8")
        self.assertIn("function Combat.findNearestThreat", source)
        self.assertIn("function Combat.attack", source)
        self.assertIn("setCombatTarget", source)
        self.assertIn("GoblinSurvivor/GSSurvivorPerception", source)

    def test_runtime_package_has_no_bandits_dependency(self) -> None:
        for path in MOD.rglob("*.lua"):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("require(\"Bandits", source, str(path))
            self.assertNotIn("require(\"Bandit", source, str(path))
            self.assertNotIn("Bandits2", source, str(path))
        manifest = (MOD / "mod.info").read_text(encoding="utf-8")
        self.assertNotIn("Bandits", manifest)

    def test_windows_workflow_scripts_exist(self) -> None:
        for filename in ("dev-install.ps1", "dev-logs.ps1", "dev-package.ps1", "deploy-03.ps1"):
            self.assertTrue((TOOLS / filename).exists(), filename)
        package = (TOOLS / "dev-package.ps1").read_text(encoding="utf-8")
        self.assertIn("Refusing to overwrite", package)
        deploy = (TOOLS / "deploy-03.ps1").read_text(encoding="utf-8")
        self.assertIn("ShouldProcess", deploy)
        self.assertIn("backups/GoblinSurvivor-", deploy)


if __name__ == "__main__":
    unittest.main()

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mod" / "Contents" / "mods" / "GoblinSurvivor"
SERVER = MOD / "42" / "media" / "lua" / "server" / "GoblinSurvivor"
CLIENT = MOD / "42" / "media" / "lua" / "client" / "GoblinSurvivor"
SHARED = MOD / "42" / "media" / "lua" / "shared" / "GoblinSurvivor"
COMMON_MEDIA = MOD / "common" / "media"

WARDROBE = (
    "Base.Shirt_Priest",
    "Base.Trousers_Black",
    "Base.Hat_Beret",
    "Base.Shoes_BlackBoots",
)


class GoblinCompanionContractTests(unittest.TestCase):
    def read(self, path: Path) -> str:
        return path.read_text(encoding="utf-8")

    def test_one_persistent_goblin_per_online_player(self) -> None:
        source = self.read(SERVER / "GoblinSpawner.lua")
        self.assertIn("ensureForPlayer", source)
        self.assertIn("ensureAll", source)
        self.assertIn("npcIdForOwner", source)
        self.assertIn('Config.npcId .. "." .. key', source)
        self.assertIn('ModData.getOrCreate', source.replace('pcall(modData.getOrCreate', 'ModData.getOrCreate'))
        self.assertIn("record.task", source)
        self.assertIn("record.base_set", source)
        self.assertIn("record.generation", source)

    def test_spawn_uses_one_native_body_factory_only(self) -> None:
        source = self.read(SERVER / "GoblinSpawner.lua")
        self.assertIn("addZombiesInOutfit", source)
        self.assertIn("math.floor(x), math.floor(y), math.floor(z), 1", source)
        self.assertNotIn('"createRealZombieAlways"', source)
        self.assertNotIn('"createRealZombieNow"', source)
        self.assertNotIn("registerCreatedBody", source)

    def test_exact_vanilla_uniform_is_product_behavior(self) -> None:
        config = self.read(SHARED / "Config.lua")
        body = self.read(SERVER / "GoblinBody.lua")
        for item in WARDROBE:
            self.assertIn(item, config)
            self.assertIn(item, body)
        self.assertIn('npcVisualAsset = "vanilla-wardrobe"', config)
        self.assertIn('npcVisualItemType = ""', config)
        self.assertIn("setWornItem", body)
        self.assertIn("WARDROBE_APPLIED", body)
        self.assertIn("setDressInRandomOutfit", body)

    def test_custom_character_assets_are_not_packaged(self) -> None:
        forbidden = (
            COMMON_MEDIA / "clothing" / "clothing.xml",
            COMMON_MEDIA / "clothing" / "clothingItems" / "Goblin_MysteryBody.xml",
            COMMON_MEDIA / "fileGuidTable.xml",
            COMMON_MEDIA / "models_X" / "Goblin_PZ_MysteryRig.fbx",
            COMMON_MEDIA / "models_X" / "Skinned" / "Goblin" / "Goblin.fbx",
            COMMON_MEDIA / "textures" / "Goblin" / "Goblin.png",
            MOD / "42" / "media" / "scripts" / "goblin_items.txt",
        )
        for path in forbidden:
            self.assertFalse(path.exists(), str(path))
        self.assertFalse((COMMON_MEDIA / "AnimSets" / "zombie").exists())
        self.assertTrue((ROOT / "art" / "goblin").is_dir())

    def test_client_has_no_custom_model_retry_loop(self) -> None:
        client = self.read(CLIENT / "GoblinClient.lua")
        self.assertIn("visual=vanilla-wardrobe", client)
        self.assertIn("custom_model=false", client)
        self.assertNotIn("OutfitManager", client)
        self.assertNotIn("HumanVisual", client)
        self.assertNotIn("dressInClothingItem", client)
        self.assertNotIn("CLIENT_VISUAL_FAILED", client)
        self.assertNotIn("Goblin_PZ_MysteryRig", client)

    def test_client_and_server_use_native_follow_pathing(self) -> None:
        client = self.read(CLIENT / "GoblinClient.lua")
        movement = self.read(SERVER / "GoblinMovement.lua")
        self.assertIn("pathToCharacter", client)
        self.assertIn("pathToLocationF", client)
        self.assertIn('call(body, "pathToLocationF"', movement)
        self.assertNotIn('call(b, "update")', movement)
        self.assertNotIn('call(body, "setX"', movement)
        self.assertNotIn('call(body, "setY"', movement)

    def test_de_pistol_is_permanent_and_effectively_unlimited(self) -> None:
        config = self.read(SHARED / "Config.lua")
        body = self.read(SERVER / "GoblinBody.lua")
        brain = self.read(SERVER / "GoblinBrain.lua")
        self.assertIn('weaponType = "Base.Pistol3"', config)
        self.assertIn('PISTOL = "Base.Pistol3"', body)
        self.assertIn("setCurrentAmmoCount", body)
        self.assertIn("setRoundChambered", body)
        self.assertIn("setJammed", body)
        self.assertIn("GoblinInfiniteAmmo", body)
        self.assertIn("Body.refillWeapon", brain)
        self.assertIn("PISTOL_FIRE", brain)
        self.assertNotIn("Base.Machete", config + body + brain)

    def test_two_minute_idle_autonomy_is_enabled(self) -> None:
        config = self.read(SHARED / "Config.lua")
        autonomy = self.read(SERVER / "GoblinAutonomy.lua")
        runtime = self.read(SERVER / "GoblinRuntime.lua")
        self.assertIn("autonomyEnabled = true", config)
        self.assertIn("autonomyIdleSeconds = 120", config)
        self.assertIn("playerMoved", autonomy)
        self.assertIn("explicit task has priority", autonomy)
        self.assertIn("GoblinAutonomous", autonomy)
        self.assertIn('require("GoblinSurvivor/GoblinAutonomy")', runtime)
        self.assertIn("Autonomy.update(body, timestamp)", runtime)

    def test_autonomy_can_defend_barricade_craft_and_loot(self) -> None:
        autonomy = self.read(SERVER / "GoblinAutonomy.lua")
        self.assertIn("Constants.TASK.ATTACK", autonomy)
        self.assertIn("IsoBarricade.AddBarricadeToObject", autonomy)
        self.assertIn('inventoryItem(body, "Base.Plank")', autonomy)
        self.assertIn("canAddPlank", autonomy)
        self.assertIn("RecipeManager.IsRecipeValid", autonomy)
        self.assertIn("RecipeManager.PerformMakeItem", autonomy)
        self.assertIn("Constants.TASK.LOOT", autonomy)
        self.assertIn("BARRICADE", autonomy)
        self.assertIn("CRAFT", autonomy)
        self.assertIn("LOOT", autonomy)

    def test_loot_cycle_collects_real_items_and_delivers_to_persisted_base(self) -> None:
        loot = self.read(SERVER / "GoblinLoot.lua")
        brain = self.read(SERVER / "GoblinBrain.lua")
        self.assertIn("getWorldObjects", loot)
        self.assertIn("getContainer", loot)
        self.assertIn("Loot.deposit", loot)
        self.assertIn("AddWorldInventoryItem", loot)
        self.assertIn("Config.npcOutfitItems", loot)
        self.assertIn("RETURN_TO_BASE", brain)
        self.assertIn("Loot.collect", brain)
        self.assertIn("Loot.deposit", brain)

    def test_runtime_updates_every_body_and_keeps_friendly_invariants(self) -> None:
        runtime = self.read(SERVER / "GoblinRuntime.lua")
        body = self.read(SERVER / "GoblinBody.lua")
        self.assertIn("Spawner.ensureAll(false)", runtime)
        self.assertIn("for _, body in ipairs(bodies)", runtime)
        self.assertIn("Body.applyInvariants(body)", runtime)
        self.assertIn('call(body, "setZombiesDontAttack", true)', body)
        self.assertIn('call(body, "setNoTeeth", true)', body)
        self.assertIn("NoLungeTarget", body)

    def test_addressed_chat_still_routes_to_speakers_own_companion(self) -> None:
        chat = self.read(SERVER / "ChatBridge.lua")
        service = self.read(ROOT / "goblin_zomboid" / "service.py")
        driver = self.read(ROOT / "goblin_zomboid" / "npc.py")
        self.assertIn("Spawner.ensureForPlayer", chat)
        self.assertIn("Spawner.setTask", chat)
        self.assertIn('EventLog.emit("chat"', chat)
        self.assertIn("_companion_for_owner", service)
        self.assertIn("controlled_owner", service)
        self.assertIn("npc_id_for_owner", driver)

    def test_qwen_lenin_persona_is_preserved(self) -> None:
        qwen = self.read(ROOT / "goblin_zomboid" / "qwen.py")
        social = self.read(ROOT / "goblin_zomboid" / "social.py")
        self.assertIn("one friendly Goblin companion per connected player", qwen)
        self.assertIn("controlled_npc_id", qwen)
        self.assertIn("Vladimir Lenin", qwen + social)
        self.assertIn("What is to be done?", social)
        self.assertIn("bourgeois", social)
        self.assertIn("advocate real-world political violence", qwen.lower())

    def test_no_bandits_runtime_dependency(self) -> None:
        files = [
            SERVER / "GoblinSpawner.lua",
            SERVER / "GoblinBody.lua",
            SERVER / "GoblinBrain.lua",
            CLIENT / "GoblinClient.lua",
        ]
        text = "\n".join(self.read(path) for path in files)
        self.assertNotIn('require("Bandit', text)
        self.assertNotIn('require("Bandits', text)


if __name__ == "__main__":
    unittest.main()

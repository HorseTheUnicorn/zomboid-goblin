from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mod" / "Contents" / "mods" / "GoblinSurvivor"
SERVER = MOD / "42" / "media" / "lua" / "server" / "GoblinSurvivor"
CLIENT = MOD / "42" / "media" / "lua" / "client" / "GoblinSurvivor"
SHARED = MOD / "42" / "media" / "lua" / "shared" / "GoblinSurvivor"
COMMON_MEDIA = MOD / "common" / "media"
VISUAL_GUID = "6bd4b657-5e6c-4b17-9b53-3f6bb6d4f3d1"


class GoblinCompanionContractTests(unittest.TestCase):
    def test_spawner_is_one_goblin_per_player_and_uses_one_native_factory(self) -> None:
        source = (SERVER / "GoblinSpawner.lua").read_text(encoding="utf-8")
        self.assertIn("ensureForPlayer", source)
        self.assertIn("ensureAll", source)
        self.assertIn("npcIdForOwner", source)
        self.assertIn("addZombiesInOutfit", source)
        self.assertIn("total=1", source)
        self.assertNotIn('"createRealZombieAlways"', source)
        self.assertNotIn('"createRealZombieNow"', source)
        self.assertNotIn("registerCreatedBody", source)

    def test_runtime_updates_every_managed_body(self) -> None:
        runtime = (SERVER / "GoblinRuntime.lua").read_text(encoding="utf-8")
        self.assertIn("Spawner.ensureAll(false)", runtime)
        self.assertIn("for _, body in ipairs(bodies)", runtime)
        self.assertIn("Body.clearNativeTargets", runtime)
        self.assertNotIn("Spawner.ensure(false)", runtime)

    def test_model_registration_uses_one_common_media_layer(self) -> None:
        clothing = COMMON_MEDIA / "clothing" / "clothingItems" / "Goblin_MysteryBody.xml"
        guid_table = COMMON_MEDIA / "fileGuidTable.xml"
        outfit_file = COMMON_MEDIA / "clothing" / "clothing.xml"
        texture = COMMON_MEDIA / "textures" / "Goblin_PZ_MysteryRig" / "Material_1_basecolor.png"
        model = COMMON_MEDIA / "models_X" / "Goblin_PZ_MysteryRig.fbx"
        self.assertTrue(texture.is_file())
        self.assertTrue(model.is_file())
        self.assertTrue(guid_table.is_file())
        self.assertTrue(outfit_file.is_file())
        self.assertFalse((MOD / "42" / "media" / "fileGuidTable.xml").exists())

        root = ET.parse(clothing).getroot()
        self.assertEqual(root.findtext("m_GUID"), VISUAL_GUID)
        self.assertEqual(root.findtext("m_MaleModel"), "Goblin_PZ_MysteryRig")
        self.assertEqual(root.findtext("m_FemaleModel"), "Goblin_PZ_MysteryRig")
        self.assertIsNone(root.find("m_AltMaleModel"))
        self.assertIsNone(root.find("m_AltFemaleModel"))
        self.assertEqual(
            root.findtext("textureChoices"),
            "Goblin_PZ_MysteryRig/Material_1_basecolor",
        )

        guid_root = ET.parse(guid_table).getroot()
        entry = guid_root.find("files")
        self.assertIsNotNone(entry)
        self.assertEqual(
            entry.findtext("path"),
            "media/clothing/clothingItems/Goblin_MysteryBody.xml",
        )
        self.assertEqual(entry.findtext("guid"), VISUAL_GUID)

    def test_named_outfit_contains_only_goblin_body(self) -> None:
        root = ET.parse(COMMON_MEDIA / "clothing" / "clothing.xml").getroot()
        for tag in ("m_MaleOutfits", "m_FemaleOutfits"):
            outfits = root.findall(tag)
            self.assertEqual(len(outfits), 1)
            outfit = outfits[0]
            self.assertEqual(outfit.findtext("m_Name"), "GoblinCompanion")
            self.assertEqual(outfit.findtext("m_Top"), "false")
            self.assertEqual(outfit.findtext("m_Pants"), "false")
            item_guids = [node.text for node in outfit.findall("./m_items/item/itemGUID")]
            self.assertEqual(item_guids, [VISUAL_GUID])

    def test_script_item_uses_full_body_costume_slot(self) -> None:
        source = (MOD / "42" / "media" / "scripts" / "goblin_items.txt").read_text(
            encoding="utf-8"
        )
        self.assertIn("BodyLocation = base:body_costume", source)
        self.assertNotIn("BodyLocation = base:underwear", source)

    def test_client_verifies_real_goblin_itemvisual_not_void_method_success(self) -> None:
        client = (CLIENT / "GoblinClient.lua").read_text(encoding="utf-8")
        self.assertIn("GoblinCompanion", client)
        self.assertIn("dressInNamedOutfit", client)
        self.assertIn("dressInClothingItem", client)
        self.assertIn("OutfitManager", client)
        self.assertIn("getClothingItem", client)
        self.assertIn("getItemVisuals", client)
        self.assertIn("getClothingItemName", client)
        self.assertIn("CLIENT_CLOTHING_RESOLVED", client)
        self.assertIn("CLIENT_CLOTHING_UNRESOLVED", client)
        self.assertIn("CLIENT_VISUAL_CONFIRMED", client)
        self.assertIn("CLIENT_VISUAL_FAILED", client)
        self.assertIn('call(zombie, "setDressInRandomOutfit", false)', client)
        self.assertIn('call(zombie, "clearWornItems")', client)
        self.assertNotIn("npcOutfitItems", client)
        self.assertFalse((COMMON_MEDIA / "AnimSets" / "zombie.xml").exists())

    def test_body_and_client_do_not_force_animation_frames_or_idle_states(self) -> None:
        body = (SERVER / "GoblinBody.lua").read_text(encoding="utf-8")
        client = (CLIENT / "GoblinClient.lua").read_text(encoding="utf-8")
        combined = body + client
        self.assertIn('setVariable", "Bandit", true', combined)
        self.assertIn("NoLungeTarget", combined)
        self.assertIn("ZombieHitReaction", combined)
        self.assertIn("setWalkType", combined)
        self.assertNotIn("PlayAnim", combined)
        self.assertNotIn("changeState", combined)
        self.assertNotIn("ZombieIdleState", combined)

    def test_movement_is_native_pathfinding_not_coordinate_stepping(self) -> None:
        movement = (SERVER / "GoblinMovement.lua").read_text(encoding="utf-8")
        self.assertIn("getPathFindBehavior2", movement)
        self.assertIn("pathToLocationF", movement)
        self.assertIn("BehaviorResult", movement)
        self.assertNotIn('call(body, "setX"', movement)
        self.assertNotIn('call(body, "setY"', movement)

    def test_loot_cycle_collects_real_items_and_delivers_them_to_base(self) -> None:
        loot = (SERVER / "GoblinLoot.lua").read_text(encoding="utf-8")
        brain = (SERVER / "GoblinBrain.lua").read_text(encoding="utf-8")
        self.assertIn("getWorldObjects", loot)
        self.assertIn("getContainer", loot)
        self.assertIn("Loot.deposit", loot)
        self.assertIn("AddWorldInventoryItem", loot)
        self.assertIn("RETURN_TO_BASE", brain)
        self.assertIn("Loot.collect", brain)
        self.assertIn("Loot.deposit", brain)

    def test_each_goblin_has_owner_base_and_independent_identity(self) -> None:
        body = (SERVER / "GoblinBody.lua").read_text(encoding="utf-8")
        spawner = (SERVER / "GoblinSpawner.lua").read_text(encoding="utf-8")
        self.assertIn("data.GoblinOwner = owner", body)
        self.assertIn("data.GoblinID = npcId", body)
        self.assertIn("GoblinBaseSet", body)
        self.assertIn("setBaseForPlayer", spawner)
        self.assertIn('Config.npcId .. "." .. key', spawner)

    def test_event_bridge_uses_pz_runtime_safe_id_generation(self) -> None:
        event_log = (SERVER / "EventLog.lua").read_text(encoding="utf-8")
        self.assertIn("getTimestampMs", event_log)
        self.assertIn("getRandomUUID", event_log)
        self.assertNotIn("math.random", event_log)

    def test_addressed_chat_has_direct_core_commands_and_qwen_event(self) -> None:
        chat = (SERVER / "ChatBridge.lua").read_text(encoding="utf-8")
        self.assertIn("directIntent", chat)
        self.assertIn('contains(lower, "follow me")', chat)
        self.assertIn("Constants.TASK.LOOT", chat)
        self.assertIn("Constants.TASK.RETURN_TO_BASE", chat)
        self.assertIn("Spawner.setBaseForPlayer", chat)
        self.assertIn("Spawner.ensureForPlayer", chat)
        self.assertIn("Spawner.setTask", chat)
        self.assertIn('EventLog.emit("chat"', chat)
        self.assertIn("getTimestampMs", chat)
        self.assertNotIn("os.time", chat)
        client = (CLIENT / "GoblinClient.lua").read_text(encoding="utf-8")
        self.assertIn("CHAT_RELAY", client)
        self.assertIn("CLIENT_READY", client)

    def test_qwen_knows_interaction_rules_and_lenin_persona(self) -> None:
        qwen = (ROOT / "goblin_zomboid" / "qwen.py").read_text(encoding="utf-8")
        social = (ROOT / "goblin_zomboid" / "social.py").read_text(encoding="utf-8")
        self.assertIn("one friendly Goblin companion per connected player", qwen)
        self.assertIn("controlled_npc_id", qwen)
        self.assertIn("SET_BASE", qwen)
        self.assertIn("Vladimir Lenin", qwen + social)
        self.assertIn("What is to be done?", social)
        self.assertIn("bourgeois", social)
        self.assertIn("do not advocate real-world political violence", qwen.lower())

    def test_chat_and_qwen_route_by_speaker_not_global_singleton(self) -> None:
        service = (ROOT / "goblin_zomboid" / "service.py").read_text(encoding="utf-8")
        driver = (ROOT / "goblin_zomboid" / "npc.py").read_text(encoding="utf-8")
        bridge = (SERVER / "GoblinBridge.lua").read_text(encoding="utf-8")
        self.assertIn("_companion_for_owner", service)
        self.assertIn("controlled_owner", service)
        self.assertIn("npc_id_for_owner", driver)
        self.assertIn("Spawner.findByNpcId", bridge)
        self.assertNotIn("local body = Spawner.ensure(false)", bridge)

    def test_no_bandits_runtime_dependency(self) -> None:
        files = [
            SERVER / "GoblinSpawner.lua",
            SERVER / "GoblinBody.lua",
            SERVER / "GoblinBrain.lua",
            CLIENT / "GoblinClient.lua",
        ]
        text = "\n".join(path.read_text(encoding="utf-8") for path in files)
        self.assertNotIn('require("Bandit', text)
        self.assertNotIn('require("Bandits', text)


if __name__ == "__main__":
    unittest.main()

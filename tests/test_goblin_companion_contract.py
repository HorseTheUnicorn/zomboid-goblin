from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET
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

    def test_silent_voice_aliases_cover_all_native_choices_without_overriding_zombies(self):
        import re
        source = self.read(MOD / '42/media/scripts/goblin_sounds.txt')
        aliases = re.findall(r'sound\s+(\w+)\s*\{(.*?)\n    \}', source, re.S)
        expected = {f'GoblinCompanion{speed}{kind}{choice}'
                    for speed in ('', 'Sprinter') for kind in ('Voice', 'Bite') for choice in 'ABC'}
        self.assertEqual({name for name, _ in aliases}, expected)
        for _, body in aliases:
            self.assertRegex(body, r'volume\s*=\s*0\.0\s*,')
            self.assertRegex(body, r'event\s*=\s*Zombie/(Voice|Bite)/(Sprinter/)?Male[ABC]')
        self.assertIn('Audio.silence(body)', self.read(SHARED / 'GoblinGuard.lua'))
        for file in (SHARED/'GoblinGuard.lua', SERVER/'GoblinBody.lua', CLIENT/'GoblinClient.lua'):
            self.assertNotIn('setVoiceSoundName', self.read(file))
            self.assertNotIn('setBiteSoundName', self.read(file))

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
        self.assertIn('npcVisualAsset = "Goblin_Community_Human"', config)
        self.assertIn('npcVisualItemType = "GoblinSurvivor.Goblin_MysteryBody"', config)
        self.assertIn("setWornItem", body)
        self.assertIn("WARDROBE_APPLIED", body)
        self.assertIn("setDressInRandomOutfit", body)

    def test_custom_character_assets_resolve_to_the_supplied_mesh_and_texture(self) -> None:
        required = (
            COMMON_MEDIA / "clothing" / "clothingItems" / "Goblin_MysteryBody.xml",
            COMMON_MEDIA / "models_X" / "Skinned" / "Goblin" / "GoblinHead.x",
            COMMON_MEDIA / "textures" / "Goblin" / "Goblin.png",
            MOD / "42" / "media" / "scripts" / "goblin_items.txt",
        )
        for path in required:
            self.assertTrue(path.is_file(), str(path))
        clothing = ET.parse(required[0]).getroot()
        self.assertTrue(clothing.findtext('m_MaleModel').startswith('x:'))
        mesh = COMMON_MEDIA / 'models_X' / (clothing.findtext('m_MaleModel')[2:] + '.x')
        texture = COMMON_MEDIA / 'textures' / (clothing.findtext('textureChoices') + '.png')
        self.assertEqual(hashlib.sha256(texture.read_bytes()).digest(),
                         hashlib.sha256((ROOT/'art/goblin/textures/Material_1_basecolor.png').read_bytes()).digest())
        report=json.loads((ROOT/'art/goblin/Goblin_Community_Final_report.json').read_text())
        self.assertEqual(report['head_sha256'],hashlib.sha256(mesh.read_bytes()).hexdigest())
        skin=COMMON_MEDIA/'textures/Body/Goblin/GoblinNativeSkin.png'
        self.assertEqual(report['skin_sha256'],hashlib.sha256(skin.read_bytes()).hexdigest())
        self.assertLess(report['community_native_vertex_max_error'],0.00001)
        self.assertGreater(report['native_triangles_surface_baked'],800)
        self.assertLessEqual(report['head_triangles'],2100)
        self.assertEqual(report['head_bones'],['Bip01_Head'])
        self.assertEqual(report['head_max_influences'],1)
        self.assertEqual(clothing.findall('m_Masks')[0].text,'0')
        self.assertEqual([m.text for m in clothing.findall('m_Masks')],['0','11'])
        self.assertGreater(report['native_transparent_texels_preserved'],1000)
        self.assertIn('setSkinTextureName',self.read(SHARED/'GoblinAppearance.lua'))
        self.assertEqual(clothing.findtext('m_MasksFolder'), 'none')
        guids=ET.parse(COMMON_MEDIA/'fileGuidTable.xml').getroot()
        self.assertEqual(guids.findtext('files/guid'),clothing.findtext('m_GUID'))
        self.assertEqual(texture.read_bytes()[:8], b'\x89PNG\r\n\x1a\n')
        for path in (COMMON_MEDIA / 'AnimSets/zombie').rglob('*.xml'):
            node = ET.parse(path).getroot()
            self.assertTrue(any(c.findtext('m_Name') == 'GoblinNPC' for c in node.findall('m_Conditions')))
            self.assertGreaterEqual(int(node.findtext('m_ConditionPriority')),100)

    def test_client_has_no_custom_model_retry_loop(self) -> None:
        client = self.read(CLIENT / "GoblinClient.lua")
        self.assertIn("Appearance.apply", client)
        self.assertIn("custom_model=true", client)
        self.assertNotIn("OutfitManager", client)
        self.assertNotIn("HumanVisual", client)
        self.assertNotIn("dressInClothingItem", client)
        self.assertNotIn("CLIENT_VISUAL_FAILED", client)
        self.assertNotIn("Goblin_PZ_MysteryRig", client)

    def test_client_and_server_use_native_follow_pathing(self) -> None:
        client = self.read(CLIENT / "GoblinClient.lua")
        movement = self.read(SERVER / "GoblinMovement.lua")
        driver = self.read(SHARED / 'GoblinLocomotion.lua')
        config = self.read(SHARED / 'Config.lua')
        self.assertIn('Motion.drive', client)
        self.assertIn('Motion.drive', movement)
        self.assertIn('call(body, "pathToLocationF"', driver)
        self.assertIn('isRemoteZombie', driver)
        self.assertIn('getOwner', driver)
        self.assertIn('local preferred = 3.0', driver)
        self.assertIn('followPreferredDistance = 3.0', config)
        self.assertIn('"GoblinMoveType", "IDLE"', driver)
        self.assertNotIn('call(b, "update")', movement)
        self.assertNotIn('call(body, "setX"', movement)
        self.assertNotIn('call(body, "setY"', movement)

    def test_double_barrel_is_permanent_unlimited_and_auto_defends_follow(self) -> None:
        config = self.read(SHARED / "Config.lua")
        defense = self.read(SERVER / "GoblinDefense.lua")
        bootstrap = self.read(SERVER / "Bootstrap.lua")
        qwen = self.read(ROOT / "goblin_zomboid" / "qwen.py")
        self.assertIn('weaponType = "Base.DoubleBarrelShotgun"', config)
        self.assertIn('WEAPON = "Base.DoubleBarrelShotgun"', defense)
        self.assertIn('call(body, "setUnlimitedAmmo", true)', defense)
        self.assertIn('setCurrentAmmoCount', defense)
        self.assertIn('setRoundChambered', defense)
        self.assertIn('setPrimaryHandItem', defense)
        self.assertIn('setSecondaryHandItem', defense)
        self.assertIn('nearestThreat', defense)
        self.assertIn('automatic or task == Constants.TASK.ATTACK', defense)
        self.assertIn('call(target, "Hit"', defense)
        self.assertIn('SHOTGUN_FIRE', defense)
        self.assertIn('Defense.install()', bootstrap)
        self.assertIn('Base.DoubleBarrelShotgun', qwen)

    def test_autonomy_starts_after_30_seconds_and_defense_is_owner_centered(self) -> None:
        config = self.read(SHARED / "Config.lua")
        autonomy = self.read(SERVER / "GoblinAutonomy.lua")
        runtime = self.read(SERVER / "GoblinRuntime.lua")
        self.assertIn("autonomyEnabled = true", config)
        self.assertIn("autonomyIdleSeconds = 30", config)
        self.assertIn('data.GoblinTask~="FOLLOW"', autonomy)
        self.assertIn("Config.autonomyIdleSeconds*1000", autonomy)
        self.assertIn("GoblinAutonomous", autonomy)
        self.assertIn("OWNER_DEFENSE_RADIUS = 5", self.read(SERVER/'GoblinDefense.lua'))
        self.assertIn("five tiles of the owner", self.read(ROOT/'goblin_zomboid/qwen.py'))
        self.assertIn('require("GoblinSurvivor/GoblinAutonomy")', runtime)
        self.assertIn("Autonomy.update(body, timestamp)", runtime)

    def test_autonomy_delegates_real_work_and_does_not_invent_recipe_completion(self) -> None:
        autonomy = self.read(SERVER / "GoblinAutonomy.lua")
        self.assertIn('Brain.setTask(body,"FORTIFY"',autonomy)
        self.assertIn('Brain.setTask(body,"LOOT"',autonomy)
        self.assertNotIn('PerformMakeItem',autonomy)
        work=self.read(SERVER/'GoblinWork.lua')
        for boundary in ('World.approach','World.materials','World.reserve','World.refund','IsoBarricade.AddBarricadeToObject'):
            self.assertIn(boundary,work)

    def test_loot_cycle_collects_real_items_and_delivers_to_persisted_base(self) -> None:
        loot = self.read(SERVER / "GoblinLoot.lua")
        brain = self.read(SERVER / "GoblinBrain.lua")
        self.assertIn("getWorldObjects", self.read(SERVER/'GoblinWorld.lua'))
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
        self.assertIn('require("GoblinSurvivor/GoblinBrain").setTask', chat)
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
        self.assertIn("advocate real-world", qwen.lower())

    def test_no_bandits_runtime_dependency(self) -> None:
        files = [
            SERVER / "GoblinSpawner.lua",
            SERVER / "GoblinBody.lua",
            SERVER / "GoblinBrain.lua",
            SERVER / "GoblinDefense.lua",
            CLIENT / "GoblinClient.lua",
        ]
        text = "\n".join(self.read(path) for path in files)
        self.assertNotIn('require("Bandit', text)
        self.assertNotIn('require("Bandits', text)


if __name__ == "__main__":
    unittest.main()

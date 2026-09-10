import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mod" / "Contents" / "mods" / "GoblinSurvivor"
SERVER = MOD / "42" / "media" / "lua" / "server" / "GoblinSurvivor"
ANIM = MOD / "common" / "media" / "AnimSets"
ASSET = ROOT / "art" / "goblin"


class GoblinCompanionContractTests(unittest.TestCase):
    def test_runtime_is_native_single_body(self) -> None:
        runtime = (SERVER / "GoblinRuntime.lua").read_text(encoding="utf-8")
        spawner = (SERVER / "GoblinSpawner.lua").read_text(encoding="utf-8")
        bootstrap = (SERVER / "Bootstrap.lua").read_text(encoding="utf-8")
        self.assertIn('require("GoblinSurvivor/GoblinSpawner")', runtime)
        self.assertIn("VirtualZombieManager", spawner)
        self.assertIn("createRealZombieAlways", spawner)
        self.assertIn('require("GoblinSurvivor/GoblinRuntime")', bootstrap)
        self.assertNotIn("IsoSurvivor", runtime + spawner + bootstrap)

    def test_identity_and_event_hooks_are_reload_safe(self) -> None:
        spawner = (SERVER / "GoblinSpawner.lua").read_text(encoding="utf-8")
        bootstrap = (SERVER / "Bootstrap.lua").read_text(encoding="utf-8")
        hooks = (MOD / "42" / "media" / "lua" / "shared" / "GoblinSurvivor" / "EventHooks.lua").read_text(
            encoding="utf-8"
        )
        self.assertIn("spawn_token", spawner)
        self.assertIn("spawn_generation", spawner)
        self.assertIn("GoblinGeneration", spawner)
        self.assertIn("table.sort(candidates", spawner)
        self.assertIn("removeZombieFromWorld", spawner)
        self.assertIn("EventHooks.install", bootstrap)
        self.assertIn("event.Remove", hooks)
        self.assertIn("Hooks.generations[key] ~= generation", hooks)

    def test_movement_uses_native_pathfind_and_no_coordinate_stepping(self) -> None:
        source = (SERVER / "GoblinMovement.lua").read_text(encoding="utf-8")
        self.assertIn("getPathFindBehavior2", source)
        self.assertIn("pathToLocationF", source)
        self.assertIn("BehaviorResult", source)
        self.assertNotIn("setX", source)
        self.assertNotIn("climbFence", source)
        self.assertNotIn("PlayAnim", source)

    def test_human_anim_nodes_are_goblin_conditional(self) -> None:
        expected = {
            "goblinIdle.xml": "Bob_Idle",
            "goblinWalk.xml": "Bob_Walk",
            "goblinRun.xml": "Bob_Run",
        }
        files = list(ANIM.rglob("goblin*.xml"))
        self.assertTrue(files)
        seen = set()
        for path in files:
            root = ET.parse(path).getroot()
            anim_name = root.findtext("m_AnimName")
            conditions = {
                node.findtext("m_Name"): node.findtext("m_Value")
                for node in root.findall("m_Conditions")
            }
            if path.name in expected:
                self.assertEqual(anim_name, expected[path.name])
            self.assertEqual(conditions.get("GoblinNPC"), "true")
            seen.add(anim_name)
        self.assertTrue({"Bob_Idle", "Bob_Walk", "Bob_Run"}.issubset(seen))

    def test_recovery_and_combat_anim_states_have_human_fallbacks(self) -> None:
        expected = {
            "face-target": "Bob_Idle",
            "hitreaction": "Bob_HitReact_01",
            "staggerback": "Bob_HitReact_Running",
            "getup": "Bob_ScrambleFloorToWalk",
        }
        for folder, animation in expected.items():
            files = list((ANIM / "zombie" / folder).glob("goblin*.xml"))
            self.assertTrue(files, folder)
            roots = [ET.parse(path).getroot() for path in files]
            self.assertTrue(
                any(root.findtext("m_AnimName") == animation for root in roots),
                folder,
            )
            for root in roots:
                conditions = {
                    node.findtext("m_Name"): node.findtext("m_Value")
                    for node in root.findall("m_Conditions")
                }
                self.assertEqual(conditions.get("GoblinNPC"), "true")

    def test_supplied_mystery_rig_asset_is_preserved(self) -> None:
        required = (
            ASSET / "Goblin_PZ_MysteryRig.blend",
            ASSET / "Goblin_PZ_MysteryRig.fbx",
            ASSET / "Goblin_PZ_MysteryRig_report.json",
            ASSET / "textures" / "Material_1_basecolor.png",
            ASSET / "textures" / "Material_1_basecolor.001.png",
            ASSET / "textures" / "Goblin_Body_Atlas.png",
            ASSET / "textures" / "Goblin_Head_Atlas.png",
        )
        for path in required:
            self.assertTrue(path.is_file(), path)
            self.assertGreater(path.stat().st_size, 0, path)

        report = json.loads(
            (ASSET / "Goblin_PZ_MysteryRig_report.json").read_text(encoding="utf-8")
        )
        export = report["export"]
        mesh = report["mesh"]
        self.assertEqual(export["animation_source"], "PZ native Bob_* AnimSet")
        self.assertEqual(
            export["validation_sequence"],
            "Bob_Idle -> Bob_Walk -> Bob_Run -> Bob_Walk -> Bob_Idle",
        )
        self.assertEqual(mesh["name"], "Goblin_Mesh")
        self.assertEqual(mesh["vertex_groups"]["required_bones_missing"], [])
        self.assertEqual(mesh["vertex_groups"]["zero_weight_vertices"], 0)
        self.assertAlmostEqual(mesh["bounds"]["size"][2], 0.980701, places=3)
        self.assertAlmostEqual(
            report["reference_rig"]["runtime_scale_factor"],
            0.57688294,
            places=6,
        )
        self.assertAlmostEqual(
            report["reference_rig"]["runtime_target_height"],
            0.980701,
            places=6,
        )
        self.assertTrue(export["bind_space_normalized"])
        self.assertEqual(report["reference_rig"]["dummy_scale"], [1.0, 1.0, 1.0])

    def test_mystery_rig_is_wired_as_a_replicated_clothing_item(self) -> None:
        package = MOD / "common" / "media"
        model = package / "models_X" / "Goblin_PZ_MysteryRig.fbx"
        fbm = package / "models_X" / "Goblin_PZ_MysteryRig.fbm"
        clothing = package / "clothing" / "clothingItems" / "Goblin_MysteryBody.xml"
        guid_table = MOD / "42" / "media" / "fileGuidTable.xml"
        script = MOD / "42" / "media" / "scripts" / "goblin_items.txt"
        for path in (
            model,
            fbm / "Material_1_basecolor.png",
            fbm / "Material_1_basecolor.001.png",
            package / "textures" / "Goblin_PZ_MysteryRig" / "Material_1_basecolor.png",
            package / "textures" / "Goblin_PZ_MysteryRig" / "source" / "Goblin_Body_Atlas.png",
            package / "textures" / "Goblin_PZ_MysteryRig" / "source" / "Goblin_Head_Atlas.png",
            clothing,
            guid_table,
            script,
        ):
            self.assertTrue(path.is_file(), path)
            self.assertGreater(path.stat().st_size, 0, path)
        clothing_root = ET.parse(clothing).getroot()
        self.assertEqual(clothing_root.findtext("m_MaleModel"), "Goblin_PZ_MysteryRig.fbx")
        self.assertEqual(clothing_root.findtext("m_FemaleModel"), "Goblin_PZ_MysteryRig.fbx")
        self.assertEqual(clothing_root.findtext("m_AltMaleModel"), "null")
        self.assertEqual(clothing_root.findtext("m_AltFemaleModel"), "null")
        self.assertEqual(clothing_root.findtext("m_Static"), "false")
        guid_root = ET.parse(guid_table).getroot()
        guid_files = guid_root.findall("files")
        self.assertEqual(len(guid_files), 1)
        self.assertEqual(
            guid_files[0].findtext("path"),
            "media/clothing/clothingItems/Goblin_MysteryBody.xml",
        )
        self.assertEqual(
            guid_files[0].findtext("guid"),
            clothing_root.findtext("m_GUID"),
        )
        script_text = script.read_text(encoding="utf-8")
        self.assertIn("item Goblin_MysteryBody", script_text)
        self.assertIn("BodyLocation = base:underwear", script_text)
        self.assertIn("ClothingItem = Goblin_MysteryBody", script_text)
        body = (SERVER / "GoblinBody.lua").read_text(encoding="utf-8")
        self.assertIn("setWornItem", body)
        self.assertIn("GoblinMeshApplied", body)
        self.assertIn("Body.ensureWeapon(body)", body)
        self.assertIn('weaponType = requestedType or Config.weaponType', body)

    def test_requested_vanilla_outfit_is_worn_on_server_and_client(self) -> None:
        config = (MOD / "42" / "media" / "lua" / "shared" / "GoblinSurvivor" / "Config.lua").read_text(
            encoding="utf-8"
        )
        body = (SERVER / "GoblinBody.lua").read_text(encoding="utf-8")
        client = (MOD / "42" / "media" / "lua" / "client" / "GoblinSurvivor" / "GoblinClient.lua").read_text(
            encoding="utf-8"
        )
        for item in (
            "Base.Shirt_Priest",
            "Base.Hat_Beret",
            "Base.Shoes_BlackBoots",
            "Base.Trousers_Black",
        ):
            self.assertIn(item, config)
        self.assertIn("applyConfiguredOutfit(body, inventory)", body)
        self.assertIn("applyConfiguredOutfit(zombie)", client)
        self.assertIn("setWornItem", body)
        self.assertIn("ItemVisual.new", client)
        self.assertIn("setClothingItemName", client)
        self.assertIn("getItemVisuals", client)
        self.assertIn("CLIENT_GOBLIN_RENDER", client)

    def test_melee_hit_and_recovery_are_server_bounded(self) -> None:
        brain = (SERVER / "GoblinBrain.lua").read_text(encoding="utf-8")
        body = (SERVER / "GoblinBody.lua").read_text(encoding="utf-8")
        self.assertIn("target.Hit", brain)
        self.assertIn("meleeImpactDelaySeconds", brain)
        self.assertIn("setPerformingAttackAnimation", body)
        self.assertIn("observeHealth", body)
        self.assertIn("GoblinRecoveryUntil", body)
        self.assertNotIn("setHealth", brain + body)
        self.assertNotIn("setTarget(target)", brain)


if __name__ == "__main__":
    unittest.main()

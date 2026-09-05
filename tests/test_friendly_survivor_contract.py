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
SERVER = MOD_ROOT / "media" / "lua" / "server" / "GoblinSurvivor"
SHARED = MOD_ROOT / "media" / "lua" / "shared" / "GoblinSurvivor"
CLIENT = MOD_ROOT / "media" / "lua" / "client" / "GoblinSurvivor"


class FriendlySurvivorContractTests(unittest.TestCase):
    def test_server_controller_uses_a_networked_zombie_factory(self) -> None:
        source = (SERVER / "FriendlySurvivor.lua").read_text(encoding="utf-8")
        for symbol in (
            "createZombie",
            "SurvivorFactory",
            "CreateSurvivor",
            '"IsoZombie"',
            '"IsoPlayer"',
            "getOnlinePlayers",
            "nearestPlayer",
            "30 * 30",
            "pathToLocationF",
            "pathToLocation",
            "transmitModData",
        ):
            self.assertIn(symbol, source)
        self.assertNotIn("IsoZombie.new(", source)

    def test_default_zombie_behavior_is_reasserted_without_player_targeting(self) -> None:
        source = (SERVER / "FriendlySurvivor.lua").read_text(encoding="utf-8")
        for symbol in (
            "clearAggroList",
            '"setTarget", nil',
            "setEatBodyTarget",
            "setThumpTarget",
            "setAttackTargetSquare",
            "setBite",
            "setCantBite",
            "setVoiceSoundName",
            "setBiteSoundName",
            "supported setters above",
            "goblin_biting_disabled",
        ):
            self.assertIn(symbol, source)

    def test_server_to_client_state_uses_standard_pz_commands(self) -> None:
        server = (SERVER / "FriendlySurvivorNetwork.lua").read_text(encoding="utf-8")
        client = (CLIENT / "FriendlySurvivorClient.lua").read_text(encoding="utf-8")
        protocol = (SHARED / "FriendlySurvivorProtocol.lua").read_text(encoding="utf-8")
        self.assertIn("sendServerCommand", server)
        self.assertIn("OnClientCommand", server)
        self.assertIn("sendClientCommand", client)
        self.assertIn("OnServerCommand", client)
        self.assertIn("friendly_survivor_state", protocol)
        self.assertIn("sequence", protocol)

    def test_client_survivor_roster_has_no_zombie_creation_path(self) -> None:
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        loop = (SERVER / "CommandLoop.lua").read_text(encoding="utf-8")
        client = (CLIENT / "ClientSurvivorActor.lua").read_text(encoding="utf-8")
        profiles = (SHARED / "Profiles.lua").read_text(encoding="utf-8")
        for symbol in (
            "function Server.snapshotAll",
            "function Server.statusAll",
            "function Server.isKnownNpcId",
            "function Profiles.managedIds",
            "IsoSurvivor",
            "FOLLOW_ACTOR",
        ):
            self.assertIn(symbol, server + client + profiles)
        self.assertIn('rawget(_G, "createGoblinHumanSurvivor")', client)
        self.assertNotIn('rawget(_G, "IsoSurvivor")', client)
        human = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/HumanSurvivor.java").read_text(encoding="utf-8")
        self.assertIn("extends IsoLivingCharacter implements IHumanVisual", human)
        self.assertIn("BaseVisual getVisual() { return getHumanVisual(); }", human)
        self.assertNotIn("extends IsoPlayer", human)
        self.assertNotIn("extends IsoZombie", human)
        self.assertIn("getCell().getObjectList().add(this)", human)
        self.assertIn("ensureVisualModel", human)
        self.assertIn("visualModelManaged", human)
        for phase in ("preupdate", "update", "postupdate"):
            self.assertIn(f"@Override public void {phase}() {{ }}", human)
        self.assertIn('call(actor, "registerVisualObject")', client)
        self.assertIn('call(actor, "ensureVisualModel")', client)
        self.assertIn("isZombie", client)
        self.assertIn('if id == "goblin.primary" then result.hair = "Spike" end', profiles)
        self.assertIn("OUTFIT_CATALOG", profiles)
        self.assertIn("randomizedOutfit", profiles)
        self.assertIn("table.sort(ranked", profiles)
        self.assertIn("return copy(OUTFIT_CATALOG[rank + 1])", profiles)
        self.assertIn('outfit = profile.outfit', server)
        self.assertIn('call(actor, "applyOutfit"', client)
        self.assertNotIn("IsoZombie.new(", client)

    def test_default_roster_is_goblin_plus_six_human_survivors(self) -> None:
        config = (SHARED / "Config.lua").read_text(encoding="utf-8")
        profiles = (SHARED / "Profiles.lua").read_text(encoding="utf-8")
        sync = (Path(__file__).resolve().parents[1] / "tools" / "Sync-LocalPz.ps1").read_text(encoding="utf-8")
        client_launcher = (Path(__file__).resolve().parents[1] / "tools" / "Start-LocalPzClient.ps1").read_text(encoding="utf-8")
        human = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/HumanSurvivor.java").read_text(encoding="utf-8")
        self.assertIn("managedNpcCount = 6", config)
        self.assertIn("[int]$ManagedNpcCount = 6", sync)
        for npc_id in ("npc.sarah", "npc.bob", "npc.dave", "npc.ellen", "npc.mike", "npc.june"):
            self.assertIn(f'"{npc_id}"', profiles)
        self.assertIn('"Base.AssaultRifle2"', profiles)
        self.assertIn('"Base.AssaultRifle2"', human)
        self.assertIn('"Base.M14Clip"', human)
        self.assertIn('"Base.308Bullets"', human)
        self.assertIn('Set-IniValue $profilePath "PauseEmpty" "false"', sync)
        self.assertIn('[switch]$Visible', client_launcher)
        self.assertIn("-Djava.awt.headless=$headlessValue", client_launcher)

    def test_all_managed_humans_have_independent_work_and_protection_contract(self) -> None:
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        commands = (SERVER / "PlayerCommands.lua").read_text(encoding="utf-8")
        human = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/HumanSurvivor.java").read_text(encoding="utf-8")
        self.assertIn('control_mode = isGoblin and "FOLLOW" or "JOB"', server)
        self.assertIn("workPointFor", server)
        self.assertIn("hostile_to_zombies", server)
        self.assertIn("ASSIGN_JOB", server)
        for command in ("loot", "disassemble", "build", "guard"):
            self.assertIn(f"    {command} =", commands)
        for command in ("follow", "attack"):
            self.assertIn(f'command == "{command}"', commands)
        for command in ("join", "leave", "squad", "dismiss"):
            self.assertIn(f'command == "{command}"', commands)
        self.assertIn('"JOIN_PARTY"', commands)
        self.assertIn('"LEAVE_PARTY"', commands)
        self.assertIn('"FORM_SQUAD"', commands)
        self.assertIn('"DISMISS_SQUAD"', commands)
        self.assertIn('members = companions', commands)
        self.assertIn("ensureGodMode", human)
        self.assertIn("setInvulnerable(true)", human)
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn("body.ensureFirearm();", authority)
        self.assertIn("IsoThumpable", authority)
        self.assertIn("AddSpecialObject", authority)
        self.assertIn("transmitCompleteItemToClients", authority)
        self.assertIn('result = buildOne(entry, entry.body, cell)', authority)
        self.assertIn("MIN_BODY_SEPARATION = 4.0", authority)
        self.assertIn("findSeparatedSpawnSquare", authority)
        self.assertIn("equipPrimarySilently", human)
        self.assertNotIn('"BUILDER".equals(job) {\n            result = disassembleOne', authority)
        self.assertIn("local players = onlinePlayers()", server)
        self.assertIn("goblin.manual_control ~= true", server)
        self.assertNotIn("if player == nil then return false end", server)
        self.assertIn("PERSISTENCE_VERSION = 3", server)
        self.assertIn("FORMATION_OFFSETS", server)
        self.assertIn('require("GoblinSurvivor/BaseManager")', server)
        self.assertIn("BaseManager.point()", server)
        self.assertIn("savedWorkCount", authority)
        self.assertIn("savedLastWorkItem", authority)
        self.assertIn("savedWorkStatus", authority)
        self.assertIn("entry.workCount = Math.max(0L", authority)

    def test_survivors_have_live_map_markers(self) -> None:
        client = (CLIENT / "ClientSurvivorActor.lua").read_text(encoding="utf-8")
        protocol = (SHARED / "ClientSurvivorProtocol.lua").read_text(encoding="utf-8")
        for symbol in (
            "getSymbolsAPIv2",
            'addTexture", "Gun"',
            'setPosition", x, y',
            "OnPostUIDraw",
            "mapMarkers",
            'setBoolean", "Symbols", true',
        ):
            self.assertIn(symbol, client)
        self.assertIn("validOutfit", protocol)

    def test_client_adapter_and_ipc_have_symmetric_lifecycle_guards(self) -> None:
        client = (CLIENT / "ClientSurvivorActor.lua").read_text(encoding="utf-8")
        ipc = (SERVER / "IPC.lua").read_text(encoding="utf-8")
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        self.assertIn('call(actor, "unregisterVisualObject")', client)
        self.assertIn('Client.lastSequence = {}', client)
        self.assertIn('local readyPath = IPC.root .. "/" .. channel .. "/" .. messageStem .. ".ready"', ipc)
        self.assertIn('if not pathExists(readyPath) then return nil end', ipc)
        self.assertIn('local ready = pathExists(readyPath)', ipc)
        self.assertIn('GoblinSurvivorClientSurvivor', server)
        self.assertIn('ModData.transmit', server)
        self.assertIn('rebind_pending', (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8"))

    def test_local_death_recreate_hook_is_explicitly_gated(self) -> None:
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        loop = (SERVER / "CommandLoop.lua").read_text(encoding="utf-8")
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        storm = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/GoblinSurvivorStormMod.java").read_text(encoding="utf-8")
        self.assertIn("DEBUG_KILL = true", loop)
        self.assertIn('action == "DEBUG_KILL"', server)
        self.assertIn("Config.developmentMode", server)
        self.assertIn('message.reason ~= "local-test"', server)
        self.assertIn("markGoblinHumanDead", server + storm)
        self.assertIn("debugMarkDead", authority + storm)
        self.assertIn("markSurvivorDead", authority)

    def test_local_combat_fixture_is_explicitly_gated(self) -> None:
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        loop = (SERVER / "CommandLoop.lua").read_text(encoding="utf-8")
        storm = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/GoblinSurvivorStormMod.java").read_text(encoding="utf-8")
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        controllers = (Path(__file__).resolve().parents[1] / "goblin_zomboid/controllers.py").read_text(encoding="utf-8")
        npc = (Path(__file__).resolve().parents[1] / "goblin_zomboid/npc.py").read_text(encoding="utf-8")
        self.assertIn('action == "DEBUG_SPAWN_ZOMBIE"', server)
        self.assertIn("DEBUG_SPAWN_ZOMBIE = true", loop)
        self.assertIn("Config.developmentMode", server)
        self.assertIn('message.authority_token ~= "local-combat-test"', server)
        self.assertIn("spawnGoblinCombatFixture", server + storm)
        self.assertIn("createRealZombieAlways", authority)
        self.assertIn("goblin_debug_combat_fixture", authority)
        self.assertIn("DEBUG_SPAWN_ZOMBIE", controllers + npc)

    def test_god_mode_does_not_hide_hostile_contact_telemetry(self) -> None:
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn("hostile-contact", authority)
        self.assertIn("entry.incomingHits++", authority)
        self.assertIn("body.receiveZombieDamage(18.0f, \"zombie_attack\")", authority)
        self.assertIn("body.isGodMode()", authority)

    def test_tick_is_throttled_at_the_expensive_boundaries(self) -> None:
        source = (SERVER / "FriendlySurvivor.lua").read_text(encoding="utf-8")
        network = (SERVER / "FriendlySurvivorNetwork.lua").read_text(encoding="utf-8")
        self.assertIn("pathIntervalMs = 250", source)
        self.assertIn("broadcastIntervalMs = 500", network)
        self.assertIn("O(number of connected players)", source)

    def test_client_survivor_pauses_physical_service_without_players(self) -> None:
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        self.assertIn("local players = onlinePlayers()", server)
        self.assertIn("if #players == 0 then", server)
        self.assertIn("cleanupLegacyBodies()", server)
        self.assertIn("savePersistentRoster(false)", server)
        self.assertIn("return true", server)
        self.assertIn("without a loaded player/world anchor", server)


if __name__ == "__main__":
    unittest.main()

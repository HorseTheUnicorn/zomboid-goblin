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

    def test_storm_executor_submits_verified_initial_semantic_goals(self) -> None:
        storm = (Path(__file__).resolve().parents[1]
                 / "storm/src/com/horsetheunicorn/goblinsurvivor/GoblinSurvivorStormMod.java").read_text(encoding="utf-8")
        consumer = (Path(__file__).resolve().parents[1]
                    / "storm/src/com/horsetheunicorn/goblinsurvivor/RemoteCommandConsumer.java").read_text(encoding="utf-8")
        executor = (Path(__file__).resolve().parents[1]
                    / "storm/src/com/horsetheunicorn/goblinsurvivor/SurvivorCommandExecutor.java").read_text(encoding="utf-8")
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        for symbol in (
            "MAX_COMMAND_AGE_MS",
            "containsForbiddenKey",
            "command.npc_action",
            "stale command",
            "MAX_SEEN_REQUESTS",
            "rememberRequest",
            "GameServer.getPlayers()",
            "setFollowPlayer",
            "setFollowGoblin",
            "setDestination",
            '"RETREAT".equals(action) || "FLEE".equals(action)',
            '"SAFE", action',
            "FOLLOW_GOBLIN requires goblin.primary",
            "java_goal_action",
            "public static String execute",
        ):
            self.assertIn(symbol, consumer + executor)
        self.assertIn('"executeGoblinSurvivorCommand"', storm)
        self.assertIn('rawget(_G, "executeGoblinSurvivorCommand")', server)
        self.assertIn('string.sub(result, 1, 8) == "HANDLED:"', server)
        self.assertIn('result ~= "DELEGATE"', server)
        self.assertNotIn("IsoZombie", executor)

    def test_in_game_commands_use_the_same_versioned_executor_envelope(self) -> None:
        commands = (SERVER / "PlayerCommands.lua").read_text(encoding="utf-8")
        for symbol in (
            'type = "command.npc_action"',
            "request_id = \"chat-\"",
            "timestamp_ms = Protocol.nowMs()",
            "Commands.sequence = Commands.sequence + 1",
            'source = "in_game_chat"',
        ):
            self.assertIn(symbol, commands)

    def test_default_roster_is_goblin_plus_six_human_survivors(self) -> None:
        config = (SHARED / "Config.lua").read_text(encoding="utf-8")
        profiles = (SHARED / "Profiles.lua").read_text(encoding="utf-8")
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
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
        self.assertIn('local DEFAULT_COMPANION_JOB = "SCAVENGE"', server)
        self.assertIn('state.job = defaultJob({ role = state.role })', server)
        self.assertIn('string.lower(tostring(profile.role or "")) == "hauler"', server)

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
        authority = (Path(__file__).resolve().parents[1]
                     / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn("removeBodyInventoryItem", authority)
        self.assertIn("inventory.DoRemoveItem(item)", authority)
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn("body.ensureFirearm();", authority)
        self.assertIn("IsoThumpable", authority)
        self.assertIn("AddSpecialObject", authority)
        self.assertIn("transmitCompleteItemToClients", authority)
        self.assertIn('result = buildOne(entry, entry.body, cell)', authority)
        self.assertIn("MIN_BODY_SEPARATION = 4.0", authority)
        self.assertIn("FOLLOW_BODY_SEPARATION = 2.5", authority)
        self.assertIn("separationDistance", authority)
        self.assertIn("findSeparatedSpawnSquare", authority)
        self.assertIn("equipPrimarySilently", human)
        self.assertNotIn('"BUILDER".equals(job) {\n            result = disassembleOne', authority)
        self.assertIn("local players = onlinePlayers()", server)
        self.assertIn("goblin.manual_control ~= true", server)
        self.assertNotIn("if player == nil then return false end", server)
        self.assertIn("PERSISTENCE_VERSION = 4", server)
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
            "DrawTextureScaledColor",
            'worldToUIX", x, y',
            'worldToUIY", x, y',
            "javaObject",
            "OnPostUIDraw",
            "mapMarkers",
        ):
            self.assertIn(symbol, client)
        self.assertNotIn('addTexture", "Gun"', client)
        self.assertIn("validOutfit", protocol)

    def test_specialized_jobs_have_server_owned_work_contracts(self) -> None:
        authority = (Path(__file__).resolve().parents[1]
                     / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        expedition = (SERVER / "ExpeditionManager.lua").read_text(encoding="utf-8")
        for symbol in (
            "specialistLootOne",
            "acceptsSpecialistSupply",
            "countFarmingPlots",
            "hasFarmingPlant",
            "countScoutThreats",
            "SCOUT_SCAN_RADIUS",
            "scout_threat_count",
            "farm_plot_count",
            "restoreHealth",
            "MEDIC_HEAL_AMOUNT",
            "guardPost",
            "GUARD_POST_RADIUS",
            "guard_patrol_index",
            "guard_post_x",
            "guard_status",
        ):
            self.assertIn(symbol, authority + server)
        self.assertIn("state.guard_post_x", expedition)
        self.assertIn("state.guard_post_y", expedition)
        self.assertIn("state.guard_post_z", expedition)
        self.assertIn("setSavedPoint(record, \"guard_post\"", server)

    def test_survivor_names_are_drawn_above_each_live_client_actor(self) -> None:
        client = (CLIENT / "ClientSurvivorActor.lua").read_text(encoding="utf-8")
        for symbol in (
            "nameLabelText",
            "projectNameLabel",
            "drawSurvivorNameLabels",
            "state.display_name",
            "state.alive ~= false",
            "state.body_present ~= false",
            "isoToScreenX",
            "isoToScreenY",
            "DrawStringCentre",
            "getFontHeight",
            "math.max(80, 140 / zoom) + fontHeight",
            "nextNameLabelDiagnosticsAt",
            "drawSurvivorNameLabels()",
        ):
            self.assertIn(symbol, client)
        self.assertIn('Events.OnPostUIDraw.Add(function()', client)
        self.assertIn('call(actor, "setDisplayName", state.display_name)', client)
        self.assertIn('call(actor, "setName", state.display_name)', client)

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

    def test_ipc_replay_fence_uses_runtime_and_local_sync_cleans_it(self) -> None:
        ipc = (SERVER / "IPC.lua").read_text(encoding="utf-8")
        sync = (Path(__file__).resolve().parents[1] / "tools" / "Sync-LocalPz.ps1").read_text(encoding="utf-8")
        self.assertIn('return IPC.root .. "/runtime/processed_" .. stem .. ".json"', ipc)
        self.assertIn('local processedPath = processedMarkerPath(stem)', ipc)
        self.assertIn('local copiedJson = writeFile(target .. "/" .. targetStem .. ".json", encoded)', ipc)
        self.assertIn('if not copiedJson then return false end', ipc)
        self.assertIn('Filter "processed_*.json"', sync)
        self.assertIn('$ProfileName -eq "goblin-local"', sync)

    def test_client_motion_interpolates_snapshots_and_updates_world_membership(self) -> None:
        client = (CLIENT / "ClientSurvivorActor.lua").read_text(encoding="utf-8")
        human = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/HumanSurvivor.java").read_text(encoding="utf-8")
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        for symbol in (
            "motion = {}",
            "MOTION_DURATION_MS",
            "MOTION_MIN_DURATION_MS",
            "MOTION_MAX_DURATION_MS",
            "motionDurationMs",
            "navigationIsMoving",
            "setMotionTarget",
            "advanceMotion",
            "setRenderedPosition",
            "updateWorldPosition",
            'call(actor, "setMovingSquare", square)',
            'advanceMotion(id, actor, now)',
            'Events.OnRenderTick.Add',
            'Client.renderTickActive = true',
            'updateVisualActors(Protocol.nowMs())',
            'call(actor, "ensureVisualRegistration")',
            'call(actor, "setMovementMode", moving, state.running == true)',
        ):
            self.assertIn(symbol, client)
        for symbol in (
            "public void setMovementMode(boolean moving, boolean run)",
            'public String GetAnimSetName() { return "player"; }',
            "setRunning(nextRunning)",
            'if (!moving) return "idle";',
            'return run ? "run" : "movement";',
            'setVariable("WalkSpeed", nextRunning ? 1.0f : 0.0f)',
            "movementIntentMoving",
            "advancedAnimationStateName",
            "animator.setState(next)",
            "animator.containsState(\"movement\")",
            "public boolean ensureVisualRegistration()",
        ):
            self.assertIn(symbol, human)
        for symbol in (
            "RUN_SPEED_TILES_PER_SECOND",
            "private static boolean shouldRun",
            "body.setMovementMode(movingPose, runPose)",
        ):
            self.assertIn(symbol, authority)
        self.assertNotIn('call(actor, "setLx", state.x)', client)

    def test_builder_walls_require_a_fresh_in_game_chat_command(self) -> None:
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        commands = (SERVER / "PlayerCommands.lua").read_text(encoding="utf-8")
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        for symbol in (
            "builder_commanded = false",
            "builderWaitingForChat",
            'normalized == "BUILDER" and state.builder_commanded == true',
            "builder's current group location",
            'message.source == "in_game_chat"',
            '"waiting_for_build_command"',
        ):
            self.assertIn(symbol, server)
        self.assertIn('source = "in_game_chat"', commands)
        self.assertIn('Boolean.TRUE.equals(state.rawget("builder_commanded"))', authority)
        self.assertIn('result = buildOne(entry, entry.body, cell)', authority)

    def test_expeditions_cover_idle_chat_commands_and_offline_delivery(self) -> None:
        expedition = (SERVER / "ExpeditionManager.lua").read_text(encoding="utf-8")
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        commands = (SERVER / "PlayerCommands.lua").read_text(encoding="utf-8")
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        storm = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/GoblinSurvivorStormMod.java").read_text(encoding="utf-8")
        for symbol in (
            "IDLE_BEFORE_EXPEDITION_MS = 20000",
            "function ExpeditionManager.updateGoblinIdle",
            "startAutomaticExpedition(state)",
            "state.auto_expedition = true",
            "function ExpeditionManager.tickOffline",
            "MAX_OFFLINE_CARGO_ITEMS = 128",
            "ExpeditionManager.destinationFor",
        ):
            self.assertIn(symbol, expedition)
        for symbol in (
            "persistedPoint",
            "ExpeditionManager.tickOffline(orderedStates(), now)",
            "persistGoblinActorCargo",
            "beforeCargoCount",
            'message.source == "in_game_chat"',
        ):
            self.assertIn(symbol, server)
        for symbol in (
            'gather = "SCAVENGE"',
            'forage = "SCAVENGE"',
            'command == "base"',
            'command == "fortify"',
        ):
            self.assertIn(symbol, commands)
        for symbol in (
            "square.getObjects()",
            "deliverBodyCargo",
            "deliverPendingCargo",
            "InventoryItemFactory.CreateItem(type)",
            "baseSquare",
            "persistActorCargo",
            "EXPEDITION_LEASH_RADIUS = 48.0",
        ):
            self.assertIn(symbol, authority)
        self.assertIn('"persistActorCargo"', storm)

    def test_join_assist_returns_workers_to_expeditions_and_commands_do_not_expire(self) -> None:
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        command_loop = (SERVER / "CommandLoop.lua").read_text(encoding="utf-8")
        authority = (Path(__file__).resolve().parents[1]
                     / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        for symbol in (
            "onlinePlayerNames",
            "onlinePlayersInitialized",
            "updateJoinAssists(players, now)",
            "assigned join assist",
            "join_assist = true",
            "join_assist_return_job",
            "restoreJoinAssist(state)",
            'state.task = "JOB_" .. job',
            'state.work_status = "assisting_" .. name',
        ):
            self.assertIn(symbol, server)
        for action in (
            "JOIN_PARTY",
            "DEFEND_PLAYER",
            "FOLLOW_GOBLIN",
            "ATTACK",
            "MELEE_ATTACK",
        ):
            self.assertIn(action, command_loop)
        self.assertIn("persistentActions[message.action] == true", command_loop)
        self.assertIn("pending.deadline_ms ~= nil", command_loop)
        self.assertIn('normalized == "JOIN_PARTY"', server)
        self.assertIn('normalized == "DEFEND_PLAYER"', server)
        self.assertIn('state.rawset("work_status", "looted_next_area")', authority)
        self.assertIn("advanceSpecialistRoute(state);", authority)
        self.assertIn('String controlMode = text(state, "control_mode", "HOLD").toUpperCase();', authority)
        self.assertIn('semanticWorkStatus instanceof String status', authority)

    def test_player_discovery_uses_pz_pathing_and_preserves_roaming_workers(self) -> None:
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        expedition = (SERVER / "ExpeditionManager.lua").read_text(encoding="utf-8")
        authority = (Path(__file__).resolve().parents[1]
                     / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        for symbol in (
            "DISCOVERY_GRACE_MS = 15000",
            "updatePlayerDiscovery(players, now)",
            "discoveryRecord(username, now)",
            "tracking_last_known_player",
            "server-wide player discovery",
            "updatePlayerSearchPatrol()",
            "player_search_enabled = true",
        ):
            self.assertIn(symbol, server)
        for symbol in (
            "PLAYER_SEARCH_LEG_TILES",
            "PLAYER_SEARCH_LEASH_RADIUS",
            "PathFindBehavior2",
            "nativePathPointAhead",
            "playerSearchRoute",
            "enforcePeerSeparation",
            "importantAreaIn",
            "loading_target_area",
            "stateAnchor(state, \"player_search_last\")",
        ):
            self.assertIn(symbol, authority)
        for symbol in (
            "state.player_search_enabled == true",
            "calculateOutboundPoint",
            "expedition_target = nil",
            "function ExpeditionManager.tickOffline",
        ):
            self.assertIn(symbol, expedition)

    def test_expedition_loot_vehicle_recovery_and_fence_traversal_are_server_owned(self) -> None:
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        commands = (SERVER / "PlayerCommands.lua").read_text(encoding="utf-8")
        command_loop = (SERVER / "CommandLoop.lua").read_text(encoding="utf-8")
        protocol = (SHARED / "ClientSurvivorProtocol.lua").read_text(encoding="utf-8")
        client = (CLIENT / "ClientSurvivorActor.lua").read_text(encoding="utf-8")
        for symbol in (
            "takeOneFromContainer",
            "square.getVehicleContainer()",
            "VehiclePart",
            "vehicleHasOtherOccupant",
            "vehicle_recovery_enabled",
            "beginVehicleRecovery",
            "findReachableVehicleApproach",
            "PathFindBehavior2",
            "pathToVehicleAdjacent",
            "getClientControls()",
            "vehicle.cheatHotwire(true, false)",
            "vehicle.enter(0, entry.body)",
            "moveHeadlessVehicle",
            "updatePhysicsNetwork()",
            "vehicle_returned",
            "vehicle_stuck",
            "VEHICLE_ENTER_DISTANCE = 4.0",
            "NATIVE_ROUTE_TIMEOUT_NANOS",
            "advanceNativeLocationPath",
            "pathToLocationF",
            'navigation = "pathfinding"',
            "setForwardDirection((float)dx, (float)dy)",
            "stateAnchor(state, \"protection_base\")",
            "isHoppableTo",
            "isPlayerAbleToHopWallTo",
            "IsoWindow.canClimbThroughHelper",
            "ClimbOverFenceState",
            "body.changeState(fence)",
            "failed_to_cross",
        ):
            self.assertIn(symbol, authority)
        self.assertNotIn("vehicle.updatePhysics()", authority)
        for symbol in (
            '"SET_VEHICLE_RECOVERY"',
            'command == "cars"',
            "vehicle_recovery_enabled = job == \"HAULER\"",
        ):
            self.assertIn(symbol, server + commands + command_loop)
        self.assertIn('state.navigation_status == "jumping"', client)
        self.assertIn("vehicle_recoveries", protocol)

    def test_native_route_retries_are_bounded_without_recursive_overflow(self) -> None:
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn("entry.nextRouteAt = now + NATIVE_ROUTE_RETRY_NANOS", authority)
        self.assertIn("recursive retry", authority)
        self.assertIn("LOCAL_ESCAPE_RING_RADIUS", authority)
        self.assertIn("findLocalEscapeRoute", authority)
        self.assertIn("OBSTACLE_DETOUR_HOLD_NANOS", authority)
        self.assertIn("obstacleDetourActive", authority)
        self.assertIn("entry.nextRouteAt = Math.max(entry.nextRouteAt", authority)
        self.assertIn("nativeResult.point() == null", authority)
        self.assertIn("nativeRejected || now >= entry.nextRouteAt", authority)
        self.assertIn("!nativeRejectedBeforeGrid && now >= entry.nextRouteAt", authority)
        self.assertIn("private static void clearObstacleDetour", authority)
        self.assertIn("private static GridRoute.Result findLocalEscapeRoute", authority)
        self.assertIn("its private cursor is stale", authority)
        self.assertIn("valid path and a", authority)
        self.assertNotIn(
            "return advanceNativeLocationPath(entry, cell, tx, ty, tz,\n                        stopDistance, now);",
            authority,
        )

    def test_reconnect_reanchors_missing_bodies_to_the_live_player_cell(self) -> None:
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn("spawnBodyAtSavedOrPlayerAnchor", authority)
        self.assertIn("WorldAnchor anchor = playerAnchor(cell);", authority)
        self.assertIn("human survivor reanchored to live player cell", authority)
        self.assertIn("entry.body = spawnBodyAtSavedOrPlayerAnchor(cell, state, id, entry.generation);", authority)

    def test_gss_slash_commands_are_relayed_before_vanilla_server_commands(self) -> None:
        relay = (CLIENT / "ChatRelay.lua").read_text(encoding="utf-8")
        for symbol in (
            "isGssCommand",
            "sendGssCommand",
            "ISChat.instance.textEntry",
            "textEntry.onCommandEntered",
            "GoblinSurvivorGssCommandHook",
            'sendClientCommand, "GoblinSurvivor", "gss"',
            "vanillaHandler(...)",
            "Events.OnTick.Add(installGssCommandHook)",
        ):
            self.assertIn(symbol, relay)
        self.assertNotIn("SendCommandToServer(", relay)

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
        self.assertIn("spawnGoblinCombatObservation", server + storm)
        self.assertIn("createRealZombieNow", authority)
        self.assertIn("goblin_debug_combat_fixture", authority)
        self.assertIn("observe_only", server)
        self.assertIn("observe_only = true", loop)
        self.assertIn("DEBUG_SPAWN_ZOMBIE", controllers + npc)

    def test_melee_combat_has_a_bounded_human_weapon_path(self) -> None:
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        human = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/HumanSurvivor.java").read_text(encoding="utf-8")
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        client = (CLIENT / "ClientSurvivorActor.lua").read_text(encoding="utf-8")
        commands = (SERVER / "PlayerCommands.lua").read_text(encoding="utf-8")
        for symbol in (
            '"Base.BaseballBat"',
            "ensureMeleeWeapon",
            "hasReadyMeleeWeapon",
            "meleeAt",
            "setMeleeAttackPose",
            "setFirearmPose",
        ):
            self.assertIn(symbol, human)
        for symbol in (
            "MELEE_INTERVAL_NANOS",
            "MELEE_HUNT_RADIUS",
            "MELEE_RANGE",
            'entry.combatStatus = "melee_attack"',
            "meleeAt(entry, hostile, now)",
            "melee_kills",
        ):
            self.assertIn(symbol, authority)
        self.assertIn('action == "MELEE_ATTACK"', server)
        self.assertIn('"MELEE_ATTACK"', commands)
        self.assertIn("equipRequestedWeapon", client)
        self.assertIn("applyCombatPose", client)
        self.assertIn('call(actor, "setFirearmPose", firearmAiming, firearmFiring)', client)
        self.assertIn('PlayWorldSoundServer(body, "M14Shoot"', authority)

    def test_firearm_uses_real_damage_and_replicated_death_path(self) -> None:
        human = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/HumanSurvivor.java").read_text(encoding="utf-8")
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn("target.Hit(firearm, this, 1.0f, false, 1.0f, false)", human)
        self.assertIn('firearm.setFireMode("Single")', human)
        self.assertIn("setPerformingAttackAnimation(firing)", human)
        self.assertIn("boolean killed = guaranteeZombieDeath(entry, target, body.getFirearm());", authority)
        self.assertIn("FIREARM_POSE_NANOS", authority)
        self.assertIn('entry.combatStatus = "firearm_attack"', authority)
        self.assertIn('state.rawset("navigation_status", "firing")', authority)
        self.assertIn('try { target.setHealth(0.0f); }', authority)
        self.assertIn('try { target.die(); }', authority)

    def test_automatic_combat_is_anchor_limited_and_group_leashed(self) -> None:
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        server = (SERVER / "ClientSurvivorServer.lua").read_text(encoding="utf-8")
        for symbol in (
            "PLAYER_PROTECTION_RADIUS = 32.0",
            "BASE_PROTECTION_RADIUS = 32.0",
            "GROUP_LEASH_RADIUS = 18.0",
            "GROUP_RETURN_STOP_DISTANCE = 12.0",
            "isProtectedThreat",
            "shouldEnforceGroupLeash",
            'entry.combatStatus = "returning_to_group"',
            'state.rawset("group_distance", groupDistance)',
        ):
            self.assertIn(symbol, authority)
        self.assertIn("publishProtectionAnchor", server)
        self.assertIn("protection_base_x", server)

    def test_god_mode_does_not_hide_hostile_contact_telemetry(self) -> None:
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn("hostile-contact", authority)
        self.assertIn("entry.incomingHits++", authority)
        self.assertIn("body.receiveZombieDamage(18.0f, \"zombie_attack\")", authority)
        self.assertIn("body.isGodMode()", authority)

    def test_protective_combat_is_independent_of_follow_and_job_tasks(self) -> None:
        authority = (Path(__file__).resolve().parents[1] / "storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java").read_text(encoding="utf-8")
        self.assertIn('boolean hostileToZombies = !Boolean.FALSE.equals(state.rawget("hostile_to_zombies"));', authority)
        self.assertIn('boolean combatActive = hostileToZombies && !"OFF".equals(combatMode);', authority)
        self.assertNotIn('boolean combatActive = "COMBAT".equals(controlMode)', authority)

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

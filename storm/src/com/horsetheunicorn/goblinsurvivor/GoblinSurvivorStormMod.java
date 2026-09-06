package com.horsetheunicorn.goblinsurvivor;

import io.pzstorm.storm.event.core.StormEventDispatcher;
import io.pzstorm.storm.event.core.SubscribeEvent;
import io.pzstorm.storm.mod.ZomboidMod;
import io.pzstorm.storm.event.zomboid.OnLuaManagerInitEvent;
import zombie.Lua.LuaManager;
import zombie.chat.ChatManager;
import se.krka.kahlua.vm.KahluaTable;
import zombie.iso.IsoCell;
import zombie.network.GameServer;

/** Human survivor Lua API registration; no zombie donor implementation. */
public final class GoblinSurvivorStormMod implements ZomboidMod {

    /** Stable logical identity of the Qwen-controlled survivor leader. */
    public static final String LEADER_ID = AgentPerception.LEADER_ID;

    /**
     * Render a server-authored Goblin reply in the client's vanilla chat UI.
     *
     * B42 exposes ChatManager as a Java object that cannot be reliably
     * method-dispatched from Kahlua, even when the class is registered. Keep
     * the type-sensitive call on the Java side and expose only this bounded
     * client helper to Lua.
     */
    public static boolean displayGoblinChatMessage(String author, String text) {
        if (GameServer.server || author == null || author.isBlank()
                || text == null || text.isBlank()) {
            return false;
        }
        try {
            ChatManager manager = ChatManager.getInstance();
            if (manager == null) return false;
            manager.addMessage(author, text);
            return true;
        } catch (RuntimeException ignored) {
            return false;
        }
    }

    @Override
    public void registerEventHandlers() {
        StormEventDispatcher.registerEventHandler(Handlers.class);
        Handlers.exposeHumanSurvivor();
    }

    public static final class Handlers {
        public static void exposeHumanSurvivor() {
            if (LuaManager.exposer == null || LuaManager.env == null) return;
            LuaManager.exposer.setExposed(HumanSurvivor.class);
            LuaManager.exposer.exposeLikeJava(HumanSurvivor.class, LuaManager.env);
            try {
                LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                        HumanSurvivor.class,
                        HumanSurvivor.class.getConstructor(zombie.characters.SurvivorDesc.class,
                                IsoCell.class, int.class, int.class, int.class),
                        "createGoblinHumanSurvivor");
                if (GameServer.server) {
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod("step", KahluaTable.class,
                                    KahluaTable.class, double.class), "stepGoblinServerActor");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod("persistActorCargo",
                                    KahluaTable.class), "persistGoblinActorCargo");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod("debugMarkDead",
                                    String.class, String.class), "markGoblinHumanDead");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod("debugSpawnHostileZombie",
                                    String.class), "spawnGoblinCombatFixture");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod(
                                    "debugSpawnHostileZombieForObservation", String.class),
                            "spawnGoblinCombatObservation");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            AgentPerception.class,
                            AgentPerception.class.getMethod("semanticState", KahluaTable.class),
                            "buildGoblinAgentPerception");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            AgentPerception.class,
                            AgentPerception.class.getMethod("capabilities"),
                            "goblinAgentCapabilities");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            SurvivorCommandExecutor.class,
                            SurvivorCommandExecutor.class.getMethod("validate", KahluaTable.class),
                            "validateGoblinSurvivorCommand");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            SurvivorCommandExecutor.class,
                            SurvivorCommandExecutor.class.getMethod("rejectReason", KahluaTable.class),
                            "goblinSurvivorCommandRejectReason");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            SurvivorCommandExecutor.class,
                            SurvivorCommandExecutor.class.getMethod("normalizeAction", String.class),
                            "normalizeGoblinAction");
                } else {
                    // Keep the B42 ChatManager call inside Java. Its returned
                    // instance is not reliably method-dispatchable from
                    // Kahlua, even when the class itself is exposed.
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            GoblinSurvivorStormMod.class,
                            GoblinSurvivorStormMod.class.getMethod(
                                    "displayGoblinChatMessage", String.class, String.class),
                            "displayGoblinChatMessage");
                }
            } catch (NoSuchMethodException error) {
                throw new IllegalStateException("Human survivor constructor contract changed", error);
            }
            System.out.println("[GoblinSurvivorStorm] HumanSurvivor Lua API registered");
        }

        @SubscribeEvent
        public static void onLuaInit(OnLuaManagerInitEvent event) {
            exposeHumanSurvivor();
        }
    }
}

package com.horsetheunicorn.goblinsurvivor;

import io.pzstorm.storm.event.core.StormEventDispatcher;
import io.pzstorm.storm.event.core.SubscribeEvent;
import io.pzstorm.storm.mod.ZomboidMod;
import io.pzstorm.storm.event.zomboid.OnLuaManagerInitEvent;
import zombie.Lua.LuaManager;
import se.krka.kahlua.vm.KahluaTable;
import zombie.iso.IsoCell;
import zombie.network.GameServer;

/** Human survivor Lua API registration; no zombie donor implementation. */
public final class GoblinSurvivorStormMod implements ZomboidMod {

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
                            ServerSurvivorAuthority.class.getMethod("debugMarkDead",
                                    String.class, String.class), "markGoblinHumanDead");
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

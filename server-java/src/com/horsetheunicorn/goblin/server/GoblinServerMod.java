package com.horsetheunicorn.goblin.server;

import io.pzstorm.storm.event.core.StormEventDispatcher;
import io.pzstorm.storm.event.core.SubscribeEvent;
import io.pzstorm.storm.event.lua.OnServerStartedEvent;
import io.pzstorm.storm.event.lua.OnTickEvenPausedEvent;
import io.pzstorm.storm.event.zomboid.OnLuaManagerInitEvent;
import io.pzstorm.storm.mod.ZomboidMod;
import io.pzstorm.storm.util.StormEnv;
import zombie.Lua.LuaManager;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoZombie;
import zombie.entity.components.crafting.recipe.HandcraftLogic;
import zombie.inventory.InventoryItem;
import zombie.scripting.objects.Fixing;

/** Server-only native serialization and atomic bridge files. No client hooks. */
public final class GoblinServerMod implements ZomboidMod {
    @Override public java.util.List<io.pzstorm.storm.core.StormClassTransformer> getClassTransformers() {
        if (!StormEnv.isStormServer()) return java.util.List.of();
        return java.util.List.of(
            new CompanionSeats("zombie.network.packets.vehicle.VehicleEnterPacket"),
            new CompanionSeats("zombie.network.packets.vehicle.VehicleSwitchSeatPacket"));
    }
    @Override public void registerEventHandlers() {
        if (StormEnv.isStormServer()) StormEventDispatcher.registerEventHandler(this);
    }

    @SubscribeEvent public void luaReady(OnLuaManagerInitEvent event) { expose(); }
    @SubscribeEvent public void serverReady(OnServerStartedEvent event) {
        expose();
    }
    @SubscribeEvent public void tick(OnTickEvenPausedEvent event) {
        // Reference export is JVM-property opt-in and waits until the vanilla
        // OnServerStarted Lua callbacks have initialized their effective tables.
        RuntimeCatalogExporter.exportOnce();
    }

    private static void expose() {
        if (!StormEnv.isStormServer() || LuaManager.env == null || LuaManager.exposer == null) return;
        try {
            expose("goblinServerCapabilities", "capabilities");
            expose("goblinServerWriteFile", "writeBridge", String.class, String.class);
            expose("goblinServerInventorySave", "saveInventory", IsoGameCharacter.class, String.class);
            expose("goblinServerInventoryRestore", "restoreInventory", IsoGameCharacter.class, String.class);
            LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env, CompanionRejoin.class,
                CompanionRejoin.class.getMethod("rejoin", IsoZombie.class, int.class, int.class, int.class),
                "goblinServerRejoin");
            LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env, CompanionJobs.class,
                CompanionJobs.class.getMethod("craft", IsoGameCharacter.class, HandcraftLogic.class), "goblinServerCraft");
            LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env, CompanionJobs.class,
                CompanionJobs.class.getMethod("repair", IsoGameCharacter.class, InventoryItem.class, Fixing.class, Fixing.Fixer.class), "goblinServerRepair");
            LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env, CompanionSeats.class,
                CompanionSeats.class.getMethod("ready"), "goblinServerPassengerReady");
            System.out.println("[GoblinSurvivor] SERVER_JAVA_READY inventory=native jobs=craft,repair rejoin=native_authority atomic_ipc=true client_hooks=none");
            System.out.println("[GoblinSurvivor] PASSENGER_SEAT_GUARD ready="+CompanionSeats.ready());
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Goblin server API registration failed", error);
        }
    }

    private static void expose(String luaName, String method, Class<?>... args) throws ReflectiveOperationException {
        LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env, ServerSupport.class,
                ServerSupport.class.getMethod(method, args), luaName);
    }
}

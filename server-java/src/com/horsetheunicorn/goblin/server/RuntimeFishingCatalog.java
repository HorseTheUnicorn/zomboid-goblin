package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.Collections;
import java.util.Map;
import java.util.TreeMap;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;

/** Selected loaded Fishing definition tables; functions are never read or called. */
final class RuntimeFishingCatalog {
    private static final String[] FIELDS = {"lure", "fishes", "trashItems", "line", "hook", "rods",
            "breakRodReplacement", "fishNet", "fishNetWithBait"};
    record Snapshot(Map<String, RuntimeDefinitionTable.Value> fields) { }
    private RuntimeFishingCatalog() { }

    static Snapshot collect() throws IOException { return collect(LuaManager.env); }
    static Snapshot collect(KahluaTable environment) throws IOException {
        if (!isInitialized(environment)) throw new IOException("Fishing lure index is not initialized");
        if (environment == null || !(environment.rawget("Fishing") instanceof KahluaTable fishing))
            throw new IOException("Fishing definitions unavailable");
        var result = new TreeMap<String, RuntimeDefinitionTable.Value>();
        for (String field : FIELDS) {
            Object value = fishing.rawget(field);
            if (!(value instanceof KahluaTable table)) throw new IOException("Fishing table unavailable: " + field);
            result.put(field, RuntimeDefinitionTable.snapshot(table));
        }
        return new Snapshot(Collections.unmodifiableMap(result));
    }

    /** Read-only gate for the effective lure index populated by vanilla OnServerStarted Lua. */
    static boolean isInitialized(KahluaTable environment) {
        if (environment == null || !(environment.rawget("Fishing") instanceof KahluaTable fishing)
                || !(fishing.rawget("lure") instanceof KahluaTable lure)
                || !(lure.rawget("All") instanceof KahluaTable all)) return false;
        return all.iterator().advance();
    }
}

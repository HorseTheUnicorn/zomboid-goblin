package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.Collections;
import java.util.Map;
import java.util.TreeMap;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.LuaClosure;
import se.krka.kahlua.vm.UpValue;
import zombie.Lua.LuaManager;

/** Effective loaded moveable tool/material/scrap/repair tables, read without calling Lua. */
final class RuntimeMoveableCatalog {
    private static final String[] FIELDS = {"toolDefinitions", "matsDefinitions", "scrapDefinitions",
            "healthDefinitions", "repairDefinitions", "floorReplaceSprites"};
    record Snapshot(Map<String, RuntimeDefinitionTable.Value> fields) { }
    private RuntimeMoveableCatalog() { }

    static boolean isInitialized() { return findInstance(LuaManager.env) != null; }

    static Snapshot collect() throws IOException {
        KahluaTable instance = findInstance(LuaManager.env);
        if (instance == null) throw new IOException("ISMoveableDefinitions instance is not initialized");
        return collectInstance(instance);
    }

    /** The singleton is a private Lua upvalue; inspect it read-only instead of invoking getInstance(). */
    static KahluaTable findInstance(KahluaTable environment) {
        if (environment == null
                || !(environment.rawget("ISMoveableDefinitions") instanceof KahluaTable definitions)
                || !(definitions.rawget("getInstance") instanceof LuaClosure getter)) return null;
        KahluaTable result = null;
        for (UpValue upValue : getter.upvalues) {
            if (upValue == null || !(upValue.getValue() instanceof KahluaTable candidate)) continue;
            boolean matches = true;
            for (String field : FIELDS) {
                if (!(candidate.rawget(field) instanceof KahluaTable)) { matches = false; break; }
            }
            if (!matches) continue;
            if (result != null && result != candidate) return null;
            result = candidate;
        }
        return result;
    }

    static Snapshot collectInstance(KahluaTable instance) throws IOException {
        if (instance == null) throw new IOException("ISMoveableDefinitions instance unavailable");
        var result = new TreeMap<String, RuntimeDefinitionTable.Value>();
        for (String field : FIELDS) {
            Object value = instance.rawget(field);
            if (!(value instanceof KahluaTable table))
                throw new IOException("Moveable definition table unavailable: " + field);
            result.put(field, RuntimeDefinitionTable.snapshot(table));
        }
        if (result.get("toolDefinitions").entries().isEmpty()
                || result.get("repairDefinitions").entries().isEmpty())
            throw new IOException("Moveable definitions are not populated");
        return new Snapshot(Collections.unmodifiableMap(result));
    }
}

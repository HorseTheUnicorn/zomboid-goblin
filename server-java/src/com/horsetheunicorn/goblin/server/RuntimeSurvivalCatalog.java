package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;

/** Loaded survival definitions only; never initialize or mutate the native systems. */
final class RuntimeSurvivalCatalog {
    record Forage(String id, Map<String, RuntimeDefinitionTable.Value> fields, List<String> unexportedFields) { }
    record Snapshot(RuntimeDefinitionTable.Value traps, RuntimeDefinitionTable.Value animals,
                    List<Forage> forage) { }
    static final Set<String> FORAGE_FIELDS = Set.of("type", "minCount", "maxCount", "skill", "perks",
            "xp", "recipes", "traits", "itemTags", "categories", "zones", "months", "validMonths",
            "bonusMonths", "malusMonths", "forceOutside", "isOnWater", "forceOnWater",
            "canBeAboveFloor", "canBeOnTreeSquare", "rainChance", "hasRainedChance", "snowChance",
            "dayChance", "nightChance");
    private RuntimeSurvivalCatalog() { }

    static Snapshot collect() throws IOException { return collect(LuaManager.env); }
    static Snapshot collect(KahluaTable environment) throws IOException {
        if (environment == null) throw new IOException("Lua environment unavailable");
        var traps = table(environment.rawget("Traps"), "Traps");
        var animals = table(environment.rawget("TrapAnimals"), "TrapAnimals");
        var system = table(environment.rawget("forageSystem"), "forageSystem");
        if (!Boolean.TRUE.equals(system.rawget("isInitialised")))
            throw new IOException("Foraging definitions are not initialized; not invoking init");
        var definitions = table(system.rawget("itemDefs"), "forageSystem.itemDefs");
        var result = new ArrayList<Forage>();
        var seen = new HashSet<String>();
        var iterator = definitions.iterator();
        while (iterator.advance()) {
            if (result.size() >= 10_000) throw new IOException("Forage definition count exceeds bound");
            if (!(iterator.getKey() instanceof String id) || id.isBlank() || id.length() > 4096 || !seen.add(id))
                throw new IOException("Invalid/duplicate forage identifier");
            var definition = table(iterator.getValue(), id);
            if (!id.equals(definition.rawget("type"))) throw new IOException("Forage key/type mismatch: " + id);
            var fields = new TreeMap<String, RuntimeDefinitionTable.Value>();
            var omitted = new ArrayList<String>();
            var values = definition.iterator();
            int count = 0;
            while (values.advance()) {
                if (++count > 1000 || !(values.getKey() instanceof String key) || key.length() > 4096)
                    throw new IOException("Invalid forage field");
                if (FORAGE_FIELDS.contains(key)) fields.put(key, RuntimeDefinitionTable.snapshotValue(values.getValue()));
                else omitted.add(key); // e.g. spawnFuncs: explicitly unavailable, never evaluated
            }
            omitted.sort(String::compareTo);
            result.add(new Forage(id, Collections.unmodifiableMap(fields), List.copyOf(omitted)));
        }
        result.sort(Comparator.comparing(Forage::id));
        return new Snapshot(RuntimeDefinitionTable.snapshot(traps), RuntimeDefinitionTable.snapshot(animals),
                List.copyOf(result));
    }

    private static KahluaTable table(Object value, String label) throws IOException {
        if (!(value instanceof KahluaTable result)) throw new IOException("Definition table unavailable: " + label);
        return result;
    }
}

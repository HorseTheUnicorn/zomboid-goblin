package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;

/** Definition reads only: never evaluate Lua functions or synthesize missing fields. */
final class RuntimeCropCatalog {
    record Crop(String name, String seedName, String vegetableName, String produceExtra,
                String seasonRecipe, List<String> seedTypes) { }
    private RuntimeCropCatalog() { }

    static List<Crop> collect() throws IOException {
        if (LuaManager.env == null) throw new IOException("Lua environment unavailable");
        Object config = LuaManager.env.rawget("farming_vegetableconf");
        if (!(config instanceof KahluaTable table)) throw new IOException("Farming configuration unavailable");
        Object props = table.rawget("props");
        if (!(props instanceof KahluaTable definitions)) throw new IOException("Farming props unavailable");
        return collect(definitions);
    }

    static List<Crop> collect(KahluaTable definitions) throws IOException {
        if (definitions == null) throw new IOException("Null crop table");
        ArrayList<Crop> result = new ArrayList<>();
        var iterator = definitions.iterator();
        while (iterator.advance()) {
            if (result.size() >= 10_000) throw new IOException("Crop count exceeds bound");
            if (!(iterator.getKey() instanceof String name) || name.isBlank()
                    || !(iterator.getValue() instanceof KahluaTable crop))
                throw new IOException("Invalid crop definition");
            Object rawSeeds = crop.rawget("seedTypes");
            List<String> seeds = null; // null differs from explicitly empty table
            if (rawSeeds != null) {
                if (!(rawSeeds instanceof KahluaTable seedTable)) throw new IOException("Invalid seedTypes");
                var values = seedTable.iterator();
                var ordered = new java.util.TreeMap<Integer, String>();
                while (values.advance()) {
                    if (ordered.size() >= 1000) throw new IOException("Seed list exceeds bound");
                    if (!(values.getKey() instanceof Number index) || !Double.isFinite(index.doubleValue())
                            || index.doubleValue() != index.intValue() || index.intValue() < 1
                            || !(values.getValue() instanceof String item) || item.isBlank())
                        throw new IOException("Invalid seed list entry");
                    if (ordered.put(index.intValue(), item) != null) throw new IOException("Duplicate seed index");
                }
                int expected = 1;
                for (int index : ordered.keySet()) if (index != expected++) throw new IOException("Sparse seed list");
                seeds = List.copyOf(ordered.values());
            }
            result.add(new Crop(name, text(crop, "seedName"), text(crop, "vegetableName"),
                    text(crop, "produceExtra"), text(crop, "seasonRecipe"), seeds));
        }
        result.sort(Comparator.comparing(Crop::name));
        return List.copyOf(result);
    }

    private static String text(KahluaTable table, String key) throws IOException {
        Object value = table.rawget(key);
        if (value == null) return null;
        if (!(value instanceof String text)) throw new IOException("Crop field is not text: " + key);
        return text;
    }
}

package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import zombie.scripting.ScriptManager;
import zombie.scripting.objects.VehicleScript;

/** Read loaded definitions only. No vehicles, parts or inventory instances created. */
final class RuntimeVehicleCatalog {
    record Part(String id, String parent, String area, String mechanicArea,
                List<String> itemTypes, boolean specificItem, boolean requiresKey,
                boolean repairMechanic, Map<String, String> callbacks, List<String> tableNames,
                Map<String, RuntimeDefinitionTable.Value> tables) { }
    record Vehicle(String id, int mechanicType, int engineRepairLevel, List<Part> parts) { }
    private RuntimeVehicleCatalog() { }

    static List<Vehicle> collect(ScriptManager manager) throws IOException {
        if (manager == null) throw new IOException("Vehicle registry unavailable");
        var scripts = manager.getAllVehicleScripts();
        if (scripts == null || scripts.size() > 10_000) throw new IOException("Invalid vehicle count");
        var result = new ArrayList<Vehicle>();
        var seen = new HashSet<String>();
        for (var script : scripts) {
            if (script == null) throw new IOException("Null vehicle script");
            String id = required(script.getFullName());
            if (!seen.add(id) || manager.getVehicle(id) != script)
                throw new IOException("Duplicate or non-roundtripping vehicle: " + id);
            int count = script.getPartCount();
            if (count < 0 || count > 10_000) throw new IOException("Invalid part count");
            var parts = new ArrayList<Part>();
            var partIds = new HashSet<String>();
            for (int i = 0; i < count; i++) {
                var source = script.getPart(i);
                Part part = snapshot(source);
                if (!partIds.add(part.id()) || script.getPartById(part.id()) != source)
                    throw new IOException("Duplicate or non-roundtripping part: " + id);
                parts.add(part);
            }
            parts.sort(Comparator.comparing(Part::id));
            result.add(new Vehicle(id, script.getMechanicType(), script.getEngineRepairLevel(),
                    List.copyOf(parts)));
        }
        result.sort(Comparator.comparing(Vehicle::id));
        return List.copyOf(result);
    }

    static Part snapshot(VehicleScript.Part part) throws IOException {
        if (part == null) throw new IOException("Null vehicle part");
        List<String> items = null; // null and empty are distinct definition states
        if (part.itemType != null) {
            if (part.itemType.size() > 10_000) throw new IOException("Item type list exceeds bound");
            var copy = new ArrayList<String>();
            for (String item : part.itemType) copy.add(required(item));
            items = List.copyOf(copy); // preserve native order and raw identifiers
        }
        var callbacks = new TreeMap<String, String>();
        if (part.luaFunctions != null) {
            if (part.luaFunctions.size() > 1000) throw new IOException("Callback count exceeds bound");
            for (var entry : part.luaFunctions.entrySet())
                callbacks.put(required(entry.getKey()), required(entry.getValue()));
        }
        var tables = new ArrayList<String>();
        var definitions = new TreeMap<String, RuntimeDefinitionTable.Value>();
        if (part.tables != null) {
            if (part.tables.size() > 1000) throw new IOException("Table count exceeds bound");
            for (String key : part.tables.keySet()) {
                tables.add(required(key));
                definitions.put(key, RuntimeDefinitionTable.snapshot(part.tables.get(key)));
            }
            tables.sort(String::compareTo);
        }
        return new Part(required(part.id), part.parent, part.area, part.mechanicArea, items,
                part.specificItem, part.mechanicRequireKey, part.repairMechanic,
                Collections.unmodifiableMap(callbacks), List.copyOf(tables), Collections.unmodifiableMap(definitions));
    }

    private static String required(String value) throws IOException {
        if (value == null || value.isBlank() || value.length() > 4096)
            throw new IOException("Invalid vehicle definition identifier");
        return value;
    }
}

package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.IdentityHashMap;
import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import zombie.characters.skills.PerkFactory;

/** Bounded typed snapshot of definition tables; never calls Lua or metamethods. */
final class RuntimeDefinitionTable {
    record Entry(String keyType, String key, Value value) { }
    record Value(String type, String scalar, List<Entry> entries) { }
    private RuntimeDefinitionTable() { }

    static Value snapshot(KahluaTable table) throws IOException {
        if (table == null) throw new IOException("Null definition table");
        return snapshotValue(table);
    }

    static Value snapshotValue(Object value) throws IOException {
        return read(value, 0, new int[]{0}, new IdentityHashMap<>());
    }

    private static Value read(Object object, int depth, int[] count,
                              IdentityHashMap<KahluaTable, Boolean> ancestors) throws IOException {
        if (++count[0] > 10_000 || depth > 12) throw new IOException("Definition table exceeds bound");
        if (object instanceof String text) {
            if (text.length() > 16_384) throw new IOException("Definition string exceeds bound");
            return new Value("string", text, List.of());
        }
        if (object instanceof Boolean flag) return new Value("boolean", flag.toString(), List.of());
        if (object instanceof Number number) {
            double value = number.doubleValue();
            if (!Double.isFinite(value)) throw new IOException("Nonfinite definition number");
            return new Value("number", Double.toString(value), List.of());
        }
        // Moveable definitions store native Perk objects in otherwise plain Lua
        // tables.  Preserve their stable registry ID without invoking Lua or an
        // arbitrary userdata toString implementation.
        if (object instanceof PerkFactory.Perk perk) {
            String id = perk.getId();
            if (id == null || id.isBlank() || id.length() > 16_384)
                throw new IOException("Invalid definition perk ID");
            return new Value("string", id, List.of());
        }
        if (!(object instanceof KahluaTable table))
            throw new IOException("Unsupported definition value " + object.getClass().getName()
                    + "; not evaluated");
        if (ancestors.put(table, Boolean.TRUE) != null) throw new IOException("Cyclic definition table");
        try {
            var entries = new ArrayList<Entry>();
            var iterator = table.iterator();
            while (iterator.advance()) {
                Object key = iterator.getKey();
                String type, text;
                if (key instanceof String string) {
                    type = "string"; text = string;
                } else if (key instanceof Number number && Double.isFinite(number.doubleValue())) {
                    type = "number"; text = Double.toString(number.doubleValue());
                } else throw new IOException("Unsupported definition key");
                if (text.length() > 4096) throw new IOException("Definition key exceeds bound");
                entries.add(new Entry(type, text, read(iterator.getValue(), depth + 1, count, ancestors)));
            }
            entries.sort(Comparator.comparing(Entry::keyType).thenComparing(Entry::key));
            for (int i = 1; i < entries.size(); i++) {
                var a = entries.get(i - 1); var b = entries.get(i);
                if (a.keyType().equals(b.keyType()) && a.key().equals(b.key()))
                    throw new IOException("Duplicate normalized definition key");
            }
            return new Value("table", null, List.copyOf(entries));
        } finally {
            ancestors.remove(table);
        }
    }
}

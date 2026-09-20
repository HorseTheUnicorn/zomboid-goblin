package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.HashMap;
import se.krka.kahlua.j2se.KahluaTableImpl;
import zombie.characters.skills.PerkFactory;

public final class RuntimeDefinitionTableTest {
    private static int checks;
    private static KahluaTableImpl table() { return new KahluaTableImpl(new HashMap<>()); }
    private static void check(boolean condition) { if (!condition) throw new AssertionError(); checks++; }
    private static void rejected(KahluaTableImpl value) throws Exception {
        try { RuntimeDefinitionTable.snapshot(value); throw new AssertionError("Accepted malformed table"); }
        catch (IOException expected) { checks++; }
    }
    public static void main(String[] args) throws Exception {
        var root = table(); var nested = table();
        nested.rawset("keep", true); nested.rawset("count", 1.0);
        root.rawset(1.0, nested); root.rawset("1", "distinct string key");
        var value = RuntimeDefinitionTable.snapshot(root);
        check(value.entries().size() == 2);
        check(value.entries().getFirst().keyType().equals("number"));
        check(value.entries().getFirst().value().entries().getFirst().value().scalar().equals("1.0"));
        nested.rawset("count", 2.0);
        check(value.entries().getFirst().value().entries().getFirst().value().scalar().equals("1.0"));
        root.rawset("alias", nested); check(RuntimeDefinitionTable.snapshot(root).entries().size() == 3);
        root.rawset("self", root); rejected(root); root.rawset("self", null);
        root.rawset("unknown", new Object()); rejected(root); root.rawset("unknown", null);
        root.rawset("nan", Double.NaN); rejected(root); root.rawset("nan", null);
        root.rawset("perk", new PerkFactory.Perk("GoblinCatalogTest"));
        var perk = RuntimeDefinitionTable.snapshot(root).entries().stream()
                .filter(entry -> entry.key().equals("perk")).findFirst().orElseThrow().value();
        check(perk.type().equals("string") && perk.scalar().equals("GoblinCatalogTest"));
        root.rawset("perk", null);
        var deep = table(); var current = deep;
        for (int i=0; i<14; i++) { var next=table(); current.rawset("child",next); current=next; }
        rejected(deep);
        check(root.rawget(1.0) == nested);
        System.out.println("RuntimeDefinitionTableTest: " + checks + " checks passed");
    }
}

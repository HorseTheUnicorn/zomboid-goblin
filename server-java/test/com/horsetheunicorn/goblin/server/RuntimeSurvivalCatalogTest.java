package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.HashMap;
import se.krka.kahlua.j2se.KahluaTableImpl;

public final class RuntimeSurvivalCatalogTest {
    private static int checks;
    private static KahluaTableImpl table() { return new KahluaTableImpl(new HashMap<>()); }
    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
    public static void main(String[] args) throws Exception {
        var environment = table(); var system = table(); var definitions = table(); var item = table();
        environment.rawset("Traps", table()); environment.rawset("TrapAnimals", table());
        environment.rawset("forageSystem", system); system.rawset("itemDefs", definitions);
        try { RuntimeSurvivalCatalog.collect(environment); throw new AssertionError(); }
        catch (IOException expected) { checks++; }
        check(system.rawget("isInitialised") == null);
        system.rawset("isInitialised", true);
        item.rawset("type", "Base.Stone"); item.rawset("skill", 0.0);
        Object callback = new Object(); item.rawset("spawnFuncs", callback);
        definitions.rawset("Base.Stone", item);
        var snapshot = RuntimeSurvivalCatalog.collect(environment);
        check(snapshot.forage().size() == 1);
        check(snapshot.forage().getFirst().fields().get("skill").scalar().equals("0.0"));
        check(snapshot.forage().getFirst().unexportedFields().contains("spawnFuncs"));
        check(item.rawget("spawnFuncs") == callback);
        item.rawset("type", "Base.Other");
        try { RuntimeSurvivalCatalog.collect(environment); throw new AssertionError(); }
        catch (IOException expected) { checks++; }
        System.out.println("RuntimeSurvivalCatalogTest: " + checks + " checks passed");
    }
}

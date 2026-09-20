package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.HashMap;
import se.krka.kahlua.j2se.KahluaTableImpl;

public final class RuntimeFishingCatalogTest {
    private static int checks;
    private static KahluaTableImpl table() { return new KahluaTableImpl(new HashMap<>()); }
    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
    private static KahluaTableImpl environment(boolean indexed) {
        var environment=table(); var fishing=table(); environment.rawset("Fishing",fishing);
        for (String name : new String[]{"lure","fishes","trashItems","line","hook","rods",
                "breakRodReplacement","fishNet","fishNetWithBait"}) fishing.rawset(name,table());
        var all=table(); if (indexed) all.rawset("Base.Worm",table());
        ((KahluaTableImpl)fishing.rawget("lure")).rawset("All",all);
        return environment;
    }
    public static void main(String[] args) throws Exception {
        check(!RuntimeFishingCatalog.isInitialized(null));
        check(!RuntimeFishingCatalog.isInitialized(environment(false)));
        try { RuntimeFishingCatalog.collect(environment(false)); throw new AssertionError(); }
        catch (IOException expected) { checks++; }
        var environment=environment(true);
        check(RuntimeFishingCatalog.isInitialized(environment));
        var snapshot=RuntimeFishingCatalog.collect(environment);
        check(snapshot.fields().size()==9);
        check(snapshot.fields().get("lure").entries().stream().anyMatch(e->e.key().equals("All")));
        ((KahluaTableImpl)((KahluaTableImpl)environment.rawget("Fishing")).rawget("rods"))
                .rawset("Base.FishingRod",1.0);
        check(snapshot.fields().get("rods").entries().isEmpty());
        try { snapshot.fields().put("bad",null); throw new AssertionError(); }
        catch (UnsupportedOperationException expected) { checks++; }
        ((KahluaTableImpl)environment.rawget("Fishing")).rawset("hook",new Object());
        try { RuntimeFishingCatalog.collect(environment); throw new AssertionError(); }
        catch (IOException expected) { checks++; }
        System.out.println("RuntimeFishingCatalogTest: "+checks+" checks passed");
    }
}

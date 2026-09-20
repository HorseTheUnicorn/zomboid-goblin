package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.HashMap;
import se.krka.kahlua.j2se.KahluaTableImpl;

public final class RuntimeCropCatalogTest {
    private static int checks;
    private static KahluaTableImpl table() { return new KahluaTableImpl(new HashMap<>()); }
    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
    public static void main(String[] args) throws Exception {
        var props = table(); var crop = table();
        crop.rawset("seedName", "Base.BarleySheaf");
        crop.rawset("seasonRecipe", "base:barley growing season");
        props.rawset("Barley", crop);
        var first = RuntimeCropCatalog.collect(props).getFirst();
        check(first.seedTypes() == null);
        check(first.seedName().equals("Base.BarleySheaf"));
        var seeds = table(); crop.rawset("seedTypes", seeds);
        check(RuntimeCropCatalog.collect(props).getFirst().seedTypes().isEmpty());
        seeds.rawset(1, "Base.BarleySeed");
        check(RuntimeCropCatalog.collect(props).getFirst().seedTypes().getFirst().equals("Base.BarleySeed"));
        check(crop.rawget("seasonRecipe").equals(first.seasonRecipe()));
        seeds.rawset(3, "Base.Other");
        try { RuntimeCropCatalog.collect(props); throw new AssertionError("Sparse accepted"); }
        catch (IOException expected) { checks++; }
        crop.rawset("seedTypes", "invalid");
        try { RuntimeCropCatalog.collect(props); throw new AssertionError("Wrong type accepted"); }
        catch (IOException expected) { checks++; }
        System.out.println("RuntimeCropCatalogTest: " + checks + " checks passed");
    }
}

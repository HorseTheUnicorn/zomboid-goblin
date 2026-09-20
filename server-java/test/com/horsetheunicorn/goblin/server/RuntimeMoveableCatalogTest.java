package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.HashMap;
import se.krka.kahlua.j2se.KahluaTableImpl;

public final class RuntimeMoveableCatalogTest {
    private static int checks;
    private static KahluaTableImpl table() { return new KahluaTableImpl(new HashMap<>()); }
    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
    private static KahluaTableImpl instance(boolean populated) {
        var instance = table();
        for (String field : new String[]{"toolDefinitions", "matsDefinitions", "scrapDefinitions",
                "healthDefinitions", "repairDefinitions", "floorReplaceSprites"}) instance.rawset(field, table());
        if (populated) {
            ((KahluaTableImpl) instance.rawget("toolDefinitions")).rawset("Hammer", table());
            ((KahluaTableImpl) instance.rawget("repairDefinitions")).rawset("Wood", table());
        }
        return instance;
    }
    public static void main(String[] args) throws Exception {
        try { RuntimeMoveableCatalog.collectInstance(instance(false)); throw new AssertionError(); }
        catch (IOException expected) { checks++; }
        var source = instance(true);
        var snapshot = RuntimeMoveableCatalog.collectInstance(source);
        check(snapshot.fields().size() == 6);
        check(snapshot.fields().get("toolDefinitions").entries().size() == 1);
        ((KahluaTableImpl) source.rawget("toolDefinitions")).rawset("Saw", table());
        check(snapshot.fields().get("toolDefinitions").entries().size() == 1);
        try { snapshot.fields().put("bad", null); throw new AssertionError(); }
        catch (UnsupportedOperationException expected) { checks++; }
        source.rawset("matsDefinitions", "bad");
        try { RuntimeMoveableCatalog.collectInstance(source); throw new AssertionError(); }
        catch (IOException expected) { checks++; }
        check(RuntimeMoveableCatalog.findInstance(null) == null);
        System.out.println("RuntimeMoveableCatalogTest: " + checks + " checks passed");
    }
}

package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import gnu.trove.map.hash.THashMap;
import zombie.scripting.objects.VehicleScript;

public final class RuntimeVehicleCatalogTest {
    private static int checks;
    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
    public static void main(String[] args) throws Exception {
        var part = new VehicleScript.Part(); part.id = "Battery";
        check(RuntimeVehicleCatalog.snapshot(part).itemTypes() == null);
        part.itemType = new ArrayList<>();
        check(RuntimeVehicleCatalog.snapshot(part).itemTypes().isEmpty());
        part.itemType.add("Base.CarBattery1");
        part.mechanicRequireKey = true; part.specificItem = true;
        part.luaFunctions = new THashMap<>();
        part.luaFunctions.put("test", "Vehicles.Test.Battery");
        var copy = RuntimeVehicleCatalog.snapshot(part);
        part.itemType.add("Base.Other");
        check(copy.itemTypes().equals(List.of("Base.CarBattery1")));
        check(copy.requiresKey() && copy.specificItem());
        check(copy.callbacks().get("test").equals("Vehicles.Test.Battery"));
        try { copy.callbacks().put("run", "bad"); throw new AssertionError(); }
        catch (UnsupportedOperationException expected) { checks++; }
        part.itemType.add(null);
        try { RuntimeVehicleCatalog.snapshot(part); throw new AssertionError(); }
        catch (IOException expected) { checks++; }
        try { RuntimeVehicleCatalog.collect(null); throw new AssertionError(); }
        catch (IOException expected) { checks++; }
        System.out.println("RuntimeVehicleCatalogTest: " + checks + " checks passed");
    }
}

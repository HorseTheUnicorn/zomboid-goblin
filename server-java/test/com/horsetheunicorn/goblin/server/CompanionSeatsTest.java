package com.horsetheunicorn.goblin.server;

import java.util.Arrays;
import org.joml.Vector3f;
import zombie.characters.IsoGameCharacter;
import zombie.vehicles.BaseVehicle;

/** Check the actual installed B42 method/field boundaries, not fake packet data. */
public final class CompanionSeatsTest {
    public static void main(String[] args) throws Exception {
        int checks=0;
        for (String name : new String[]{"VehicleEnterPacket","VehicleSwitchSeatPacket"}) {
            String binary="zombie.network.packets.vehicle."+name;
            byte[] source;
            try (var stream=CompanionSeatsTest.class.getClassLoader().getResourceAsStream(binary.replace('.','/')+".class")) {
                if (stream==null) throw new AssertionError("missing native packet "+name);
                source=stream.readAllBytes();
            }
            byte[] patched=new CompanionSeats(binary).transform(source);
            if (patched==null || Arrays.equals(source,patched)) throw new AssertionError("seat guard was not applied: "+name);
            checks++;
        }
        BaseVehicle.class.getMethod("enterRSync",int.class,IsoGameCharacter.class,BaseVehicle.class);
        BaseVehicle.class.getMethod("clearPassenger",int.class);
        BaseVehicle.class.getMethod("getForwardVector",Vector3f.class);
        BaseVehicle.class.getMethod("isExitBlocked",IsoGameCharacter.class,int.class);
        IsoGameCharacter.class.getMethod("setCurrent",zombie.iso.IsoGridSquare.class);
        checks++;
        System.out.println("CompanionSeatsTest: "+checks+" native transform/API checks passed");
    }
}

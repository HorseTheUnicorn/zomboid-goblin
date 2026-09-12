package com.horsetheunicorn.goblin.server;

import io.pzstorm.storm.core.StormClassTransformer;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.dynamic.ClassFileLocator;
import net.bytebuddy.dynamic.DynamicType;
import net.bytebuddy.pool.TypePool;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoZombie;
import zombie.network.GameServer;
import zombie.network.fields.vehicle.VehicleID;
import zombie.vehicles.BaseVehicle;
import static net.bytebuddy.matcher.ElementMatchers.named;

/** Only deny a player packet that races an already occupied Goblin seat.
 * Native vehicle packets serialize players only; the Lua roster carries NPCs.
 * All other packet validation and all real-player behavior remain native. */
public final class CompanionSeats extends StormClassTransformer {
    public CompanionSeats(String packetClass) { super(packetClass); }

    public static boolean ready() {
        if (!GameServer.server || !io.pzstorm.storm.util.StormEnv.isStormServer()) return false;
        for (String suffix : new String[]{"VehicleEnterPacket","VehicleSwitchSeatPacket"}) {
            String name="zombie.network.packets.vehicle."+suffix;
            try { Class.forName(name,false,BaseVehicle.class.getClassLoader()); }
            catch (ClassNotFoundException | LinkageError error) { return false; }
            boolean applied=io.pzstorm.storm.core.StormClassTransformers.getTransformedClasses()
                .stream().anyMatch(value -> name.equals(value.replace('/','.')));
            boolean registered=io.pzstorm.storm.core.StormClassTransformers.getRegistered(name)
                .stream().anyMatch(value -> value instanceof CompanionSeats);
            if (!registered) registered=io.pzstorm.storm.core.StormClassTransformers.getRegistered(name.replace('.','/'))
                .stream().anyMatch(value -> value instanceof CompanionSeats);
            if (!applied || !registered) return false;
        }
        return true;
    }

    @Override public DynamicType.Builder<Object> dynamicType(ClassFileLocator locator,
            TypePool pool, DynamicType.Builder<Object> builder) {
        return builder.visit(Advice.to(ReservedSeat.class).on(named("isConsistent")));
    }

    public static class ReservedSeat {
        @Advice.OnMethodExit
        public static void validate(@Advice.FieldValue("vehicleId") VehicleID id,
                @Advice.FieldValue("seatTo") int seat,
                @Advice.Return(readOnly=false) boolean consistent) {
            if (!consistent || !GameServer.server || id == null) return;
            BaseVehicle vehicle = id.getVehicle();
            if (vehicle == null || seat < 1 || seat >= vehicle.getMaxPassengers()) return;
            IsoGameCharacter occupant = vehicle.getCharacter(seat);
            if (occupant instanceof IsoZombie && occupant.getVariableBoolean("GoblinNPC")) consistent = false;
        }
    }
}

package com.horsetheunicorn.goblin.server;

import io.pzstorm.storm.util.StormEnv;
import zombie.characters.IsoZombie;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoWorld;
import zombie.network.GameServer;
import zombie.popman.NetworkZombieManager;

/** Move a remote FOLLOW companion through Build 42's native ownership registry. */
public final class CompanionRejoin {
    private CompanionRejoin() { }

    public static boolean rejoin(IsoZombie body, int x, int y, int z) {
        if (!StormEnv.isStormServer() || !GameServer.server || body == null || body.isDead()
                || body.getVehicle() != null || z < -32 || z > 31 || IsoWorld.instance == null
                || IsoWorld.instance.currentCell == null) return false;
        IsoGridSquare destination = IsoWorld.instance.currentCell.getGridSquare(x, y, z);
        if (destination == null || !destination.isFree(false)) return false;

        NetworkZombieManager manager = NetworkZombieManager.getInstance();
        // setOwner(null) alone leaves the zombie on its old owner's native list.
        // moveZombie updates that list, clears authority and schedules a packet.
        manager.moveZombie(body, null, null);
        body.teleportTo(x, y, z);
        manager.updateAuth(body);
        return (int) Math.floor(body.getX()) == x
            && (int) Math.floor(body.getY()) == y
            && (int) Math.floor(body.getZ()) == z;
    }
}

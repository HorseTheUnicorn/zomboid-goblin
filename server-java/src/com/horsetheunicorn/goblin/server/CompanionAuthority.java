package com.horsetheunicorn.goblin.server;

import io.pzstorm.storm.core.StormClassTransformer;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.dynamic.ClassFileLocator;
import net.bytebuddy.dynamic.DynamicType;
import net.bytebuddy.pool.TypePool;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.core.raknet.UdpConnection;
import zombie.network.GameServer;
import zombie.popman.NetworkZombieManager;
import static net.bytebuddy.matcher.ElementMatchers.named;

/**
 * Keep a Goblin's native simulation with its owner's client.
 *
 * Build 42 re-evaluates zombie authority every two seconds and hands a zombie
 * to another client once that client's player is ~1.6x closer. With two
 * players standing together this flipped a Goblin between clients every few
 * seconds; each new simulation owner dropped the route and started over, so
 * Goblins stood still or zig-zagged. While the owner is connected and the
 * body is inside the owner's relevance range, NetworkZombieManager.updateAuth
 * now keeps (or moves) authority to the owner. Everything else — offline or
 * distant owners, ordinary zombies — stays on the native rules.
 */
public final class CompanionAuthority extends StormClassTransformer {
    public static final String TARGET = "zombie.popman.NetworkZombieManager";

    public CompanionAuthority() { super(TARGET); }

    public static boolean ready() {
        if (!GameServer.server || !io.pzstorm.storm.util.StormEnv.isStormServer()) return false;
        boolean applied = io.pzstorm.storm.core.StormClassTransformers.getTransformedClasses()
            .stream().anyMatch(value -> TARGET.equals(value.replace('/', '.')));
        boolean registered = io.pzstorm.storm.core.StormClassTransformers.getRegistered(TARGET)
            .stream().anyMatch(value -> value instanceof CompanionAuthority)
            || io.pzstorm.storm.core.StormClassTransformers.getRegistered(TARGET.replace('.', '/'))
            .stream().anyMatch(value -> value instanceof CompanionAuthority);
        return applied && registered;
    }

    @Override public DynamicType.Builder<Object> dynamicType(ClassFileLocator locator,
            TypePool pool, DynamicType.Builder<Object> builder) {
        return builder.visit(Advice.to(OwnerAuthority.class).on(named("updateAuth")));
    }

    public static class OwnerAuthority {
        /** Returns true (skipping the native choice) only when the owner keeps authority. */
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class)
        public static boolean pin(@Advice.This NetworkZombieManager manager,
                @Advice.Argument(0) IsoZombie zombie) {
            if (!GameServer.server || zombie == null || zombie.isDead()) return false;
            if (!zombie.getVariableBoolean("GoblinNPC")) return false;
            String owner = zombie.GetVariable("GoblinOwner");
            if (owner == null || owner.isEmpty()) return false;
            IsoPlayer player = GameServer.getPlayerByUserName(owner);
            if (player == null || player.isDead()) return false;
            UdpConnection connection = GameServer.getConnectionFromPlayer(player);
            if (connection == null || !connection.isFullyConnected()
                    || GameServer.isDelayedDisconnect(connection)) return false;
            // Same outer bound the native rule uses before dropping authority.
            float range = (connection.getRelevantRange() - 2) * 10;
            if (!connection.RelevantTo(zombie.getX(), zombie.getY(), range)) return false;
            if (zombie.getOwner() != connection || zombie.getOwnerPlayer() != player) {
                manager.moveZombie(zombie, connection, player);
            }
            return true;
        }
    }
}

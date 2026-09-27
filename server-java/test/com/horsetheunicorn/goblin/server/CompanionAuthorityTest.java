package com.horsetheunicorn.goblin.server;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.core.raknet.UdpConnection;
import zombie.network.GameServer;
import zombie.popman.NetworkZombieManager;

/** Apply the owner-authority advice to the installed B42 NetworkZombieManager. */
public final class CompanionAuthorityTest {
    /**
     * Storm transforms NetworkZombieManager while defining it, so the target
     * cannot be loaded during the transform. Reproduce that: load the mod
     * classes in a child-first loader that refuses the target with the same
     * ClassCircularityError the live server raised.
     */
    static byte[] transformWhileTargetIsBeingDefined(byte[] source) throws Exception {
        java.net.URL mod = CompanionAuthority.class.getProtectionDomain().getCodeSource().getLocation();
        ClassLoader parent = CompanionAuthorityTest.class.getClassLoader();
        ClassLoader loader = new java.net.URLClassLoader(new java.net.URL[]{mod}, parent) {
            @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                if (name.equals(CompanionAuthority.TARGET)) throw new ClassCircularityError(name.replace('.', '/'));
                if (name.startsWith("com.horsetheunicorn.")) {
                    synchronized (getClassLoadingLock(name)) {
                        Class<?> c = findLoadedClass(name);
                        if (c == null) c = findClass(name);
                        return c;
                    }
                }
                return super.loadClass(name, resolve);
            }
        };
        Class<?> type = loader.loadClass(CompanionAuthority.class.getName());
        Object transformer = type.getConstructor().newInstance();
        return (byte[]) type.getMethod("transform", byte[].class).invoke(transformer, (Object) source);
    }

    public static void main(String[] args) throws Exception {
        int checks = 0;
        String binary = CompanionAuthority.TARGET;
        byte[] source;
        try (var stream = CompanionAuthorityTest.class.getClassLoader()
                .getResourceAsStream(binary.replace('.', '/') + ".class")) {
            if (stream == null) throw new AssertionError("missing native " + binary);
            source = stream.readAllBytes();
        }
        byte[] patched = transformWhileTargetIsBeingDefined(source);
        if (patched == null || Arrays.equals(source, patched)) throw new AssertionError("authority pin was not applied");
        String text = new String(patched, StandardCharsets.ISO_8859_1);
        if (!text.contains("GoblinOwner") || !text.contains("GoblinNPC"))
            throw new AssertionError("advice body was not inlined into updateAuth");
        checks++;
        // The native API the advice relies on must exist with these exact shapes.
        NetworkZombieManager.class.getMethod("updateAuth", IsoZombie.class);
        NetworkZombieManager.class.getMethod("moveZombie", IsoZombie.class, UdpConnection.class, IsoPlayer.class);
        GameServer.class.getMethod("getPlayerByUserName", String.class);
        GameServer.class.getMethod("getConnectionFromPlayer", IsoPlayer.class);
        GameServer.class.getMethod("isDelayedDisconnect", UdpConnection.class);
        UdpConnection.class.getMethod("RelevantTo", float.class, float.class, float.class);
        UdpConnection.class.getMethod("getRelevantRange");
        UdpConnection.class.getMethod("isFullyConnected");
        IsoZombie.class.getMethod("getOwner");
        IsoZombie.class.getMethod("getOwnerPlayer");
        IsoZombie.class.getMethod("GetVariable", String.class);
        checks++;
        System.out.println("CompanionAuthorityTest: " + checks + " native transform/API checks passed");
    }
}

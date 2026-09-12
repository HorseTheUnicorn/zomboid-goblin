package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFileAttributeView;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Arrays;

/** Run against the same PZ/Storm classpath; no game or network is started. */
public final class ServerSupportTest {
    private static int checks;
    private static void check(boolean value) {
        if (!value) throw new AssertionError("check " + checks);
        checks++;
    }
    private interface Checked { void run() throws Exception; }
    private static void rejects(Checked action) throws Exception {
        try { action.run(); }
        catch (IOException expected) { checks++; return; }
        throw new AssertionError("Expected IOException");
    }
    public static void main(String[] args) throws Exception {
        Path cache = Path.of("test-cache").toAbsolutePath();
        for (String extension : new String[]{"json", "ready", "done"}) {
            check(ServerSupport.bridgePath(cache, "goblin-bridge/events/goblin.123." + extension)
                    .equals(cache.resolve("Lua/goblin-bridge/events/goblin.123." + extension)));
        }
        for (String invalid : new String[]{"../outside.json", "goblin-bridge/events/../outside.json",
                "goblin-bridge/events/x.lua", "goblin-bridge/other/x.json", "/goblin-bridge/events/x.json",
                "goblin-bridge/events/sub/x.json", "goblin-bridge/events/x\\y.json", "goblin-bridge/events/.ready"}) {
            rejects(() -> ServerSupport.bridgePath(cache, invalid));
        }
        byte[] nativeData = {0, 1, 2, 3, -1};
        byte[] snapshot = ServerSupport.envelope(nativeData, 241);
        check(Arrays.equals(ServerSupport.payload(snapshot, 241).array(), nativeData));
        check(Arrays.equals(ServerSupport.payload(snapshot, 242).array(), nativeData));
        rejects(() -> ServerSupport.payload(snapshot, 240));
        rejects(() -> ServerSupport.payload(Arrays.copyOf(snapshot, snapshot.length-1), 241));
        rejects(() -> ServerSupport.payload(Arrays.copyOf(snapshot, snapshot.length+1), 241));
        byte[] corrupt = snapshot.clone();
        corrupt[corrupt.length-1] ^= 1;
        rejects(() -> ServerSupport.payload(corrupt, 241));
        byte[] negativeLength = snapshot.clone();
        ByteBuffer.wrap(negativeLength).putInt(8, -1);
        rejects(() -> ServerSupport.payload(negativeLength, 241));
        Path temporary = Files.createTempDirectory("goblin-server-test-");
        Path file = temporary.resolve("test.ready");
        try {
            boolean posix = Files.getFileAttributeView(temporary, PosixFileAttributeView.class) != null;
            ServerSupport.atomicWrite(file, nativeData);
            check(Arrays.equals(Files.readAllBytes(file), nativeData));
            if (posix) check(Files.getPosixFilePermissions(file).equals(PosixFilePermissions.fromString("rw-------")));
            ServerSupport.atomicBridgeWrite(file, snapshot);
            check(Arrays.equals(Files.readAllBytes(file), snapshot));
            if (posix) check(Files.getPosixFilePermissions(file).equals(PosixFilePermissions.fromString("rw-rw----")));
            ServerSupport.atomicBridgeWrite(file, nativeData);
            check(Arrays.equals(Files.readAllBytes(file), nativeData));
            if (posix) check(Files.getPosixFilePermissions(file).equals(PosixFilePermissions.fromString("rw-rw----")));
            ServerSupport.atomicWrite(file, snapshot);
            check(Arrays.equals(Files.readAllBytes(file), snapshot));
            if (posix) check(Files.getPosixFilePermissions(file).equals(PosixFilePermissions.fromString("rw-------")));
            try (var files = Files.list(temporary)) { check(files.count() == 1); }
            System.out.println("POSIX bridge/private permission checks: " + (posix ? "executed" : "not supported on this filesystem"));
        } finally {
            Files.deleteIfExists(file);
            Files.delete(temporary);
        }
        System.out.println("ServerSupportTest: " + checks + " checks passed");
    }
}

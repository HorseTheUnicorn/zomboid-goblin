package com.horsetheunicorn.goblin.server;

import java.nio.file.Files;
import java.nio.file.Path;

public final class RuntimeContentFingerprintTest {
    private static int checks;
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("check " + checks);
        checks++;
    }
    private interface Checked { void run() throws Exception; }
    private static void rejects(Checked action) throws Exception {
        try { action.run(); } catch (java.io.IOException expected) { checks++; return; }
        throw new AssertionError("Expected content fingerprint rejection");
    }
    public static void main(String[] args) throws Exception {
        Path base = Files.createTempDirectory("goblin-content-test-");
        Path version = Files.createDirectory(base.resolve("42"));
        Path item = version.resolve("item.txt");
        try {
            rejects(() -> RuntimeContentFingerprint.root(base, version, false, new RuntimeContentFingerprint.Budget()));
            Files.writeString(item, "first");
            String first = RuntimeContentFingerprint.root(base, version, false, new RuntimeContentFingerprint.Budget());
            check(first.contains("\"file_count\":1"));
            check(first.equals(RuntimeContentFingerprint.root(base, version, false, new RuntimeContentFingerprint.Budget())));
            Files.writeString(item, "other");
            check(!first.equals(RuntimeContentFingerprint.root(base, version, false, new RuntimeContentFingerprint.Budget())));
            check(RuntimeContentFingerprint.root(base, base.resolve("common"), true, new RuntimeContentFingerprint.Budget())
                    .contains("\"status\":\"ABSENT\""));
            rejects(() -> RuntimeContentFingerprint.root(base, base.resolve("missing"), false, new RuntimeContentFingerprint.Budget()));
            rejects(() -> RuntimeContentFingerprint.root(base, base.getParent(), true, new RuntimeContentFingerprint.Budget()));
            var budget = new RuntimeContentFingerprint.Budget();
            budget.files = RuntimeContentFingerprint.MAX_FILES;
            rejects(() -> RuntimeContentFingerprint.root(base, version, false, budget));
            var byteBudget = new RuntimeContentFingerprint.Budget();
            byteBudget.bytes = RuntimeContentFingerprint.MAX_BYTES;
            rejects(() -> RuntimeContentFingerprint.root(base, version, false, byteBudget));
            check(RuntimeContentFingerprint.hash("abc").equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
        } finally {
            Files.deleteIfExists(item);
            Files.deleteIfExists(version);
            Files.deleteIfExists(base);
        }
        System.out.println("RuntimeContentFingerprintTest: " + checks + " checks passed");
    }
}

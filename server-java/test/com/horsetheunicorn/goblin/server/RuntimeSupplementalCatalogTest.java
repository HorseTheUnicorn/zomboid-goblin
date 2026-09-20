package com.horsetheunicorn.goblin.server;

import java.io.IOException;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.function.Function;

/** Tests collection mechanics only; not installed-registry execution. */
public final class RuntimeSupplementalCatalogTest {
    private static int checks;
    private interface Checked { void run() throws Exception; }
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Check " + checks);
        checks++;
    }
    private static void rejects(Checked action) throws Exception {
        try { action.run(); }
        catch (IOException expected) { checks++; return; }
        throw new AssertionError("Expected IOException");
    }
    private static List<RuntimeSupplementalCatalog.Identity> collect(
            List<String> definitions, Function<String, String> lookup) throws IOException {
        return RuntimeSupplementalCatalog.collectRegistry("fixing", definitions,
                Function.identity(), lookup, id -> id.equals("Base.Z"));
    }
    public static void main(String[] args) throws Exception {
        String a = new String("Base.A"), z = new String("Base.Z");
        var result = collect(List.of(z, a), id -> id.equals(a) ? a : z);
        check(result.get(0).id().equals(a));
        check(result.get(1).obsolete());
        check(!result.get(0).obsolete());
        try { result.clear(); throw new AssertionError("Mutable result"); }
        catch (UnsupportedOperationException expected) { checks++; }
        rejects(() -> collect(null, Function.identity()));
        rejects(() -> collect(Arrays.asList((String)null), Function.identity()));
        rejects(() -> collect(List.of(" "), Function.identity()));
        rejects(() -> collect(List.of(a, a), Function.identity()));
        rejects(() -> collect(List.of(a), id -> new String(id)));
        rejects(() -> collect(List.of(a), id -> null));
        rejects(() -> collect(Collections.nCopies(250_001, a), Function.identity()));
        check(collect(List.of(), Function.identity()).isEmpty());
        System.out.println("RuntimeSupplementalCatalogTest: " + checks + " checks passed");
    }
}

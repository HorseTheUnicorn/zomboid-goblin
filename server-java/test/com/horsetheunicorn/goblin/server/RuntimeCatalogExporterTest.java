package com.horsetheunicorn.goblin.server;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** Focused no-game checks for the opt-in exporter boundary and file safety. */
public final class RuntimeCatalogExporterTest {
    private static int checks;

    private static void check(boolean value) {
        if (!value) throw new AssertionError("check " + checks);
        checks++;
    }

    private interface Checked { void run() throws Exception; }

    private static void rejects(Checked action) throws Exception {
        try {
            action.run();
        } catch (Exception expected) {
            checks++;
            return;
        }
        throw new AssertionError("Expected exporter rejection");
    }

    public static void main(String[] args) throws Exception {
        String supplemental = RuntimeCatalogExporter.supplementalJson(java.util.List.of(
                new RuntimeSupplementalCatalog.Identity("fixing", "Base.A\"B", false)));
        check(supplemental.contains("\"scope\":\"identity_only\""));
        check(supplemental.contains("\"npc_compatibility\":\"UNKNOWN\""));
        check(supplemental.contains("Base.A\\\"B"));
        var unresolved = new RuntimeSupplementalCatalog.ItemReference("Unknown", null, false);
        var material = new RuntimeSupplementalCatalog.Material(unresolved, 2,
                java.util.List.of(new RuntimeSupplementalCatalog.Skill("Mechanics", 3)));
        String repair = RuntimeCatalogExporter.repairsJson(java.util.List.of(
                new RuntimeSupplementalCatalog.Repair("Base.Repair", java.util.List.of(unresolved),
                        java.util.List.of(material), null, 1.0f)));
        check(repair.contains("\"resolved\":null"));
        check(repair.contains("\"uses\":2"));
        check(repair.contains("\"name\":\"Mechanics\",\"level\":3"));
        check(repair.contains("\"global\":null"));
        String meal = RuntimeCatalogExporter.mealsJson(java.util.List.of(
                new RuntimeSupplementalCatalog.Meal("Base.Meal", null, unresolved, 6, 0.5f, true,
                        java.util.List.of(new RuntimeSupplementalCatalog.Ingredient(unresolved, null, null)))));
        check(meal.contains("\"base\":null"));
        check(meal.contains("\"minimum_water\":\"0.5\""));
        check(meal.contains("\"use\":null,\"cooked\":null"));
        check(RuntimeCatalogExporter.PROPERTY.equals("goblin.referenceExport"));
        check(RuntimeCatalogExporter.outputRoot(Path.of("cache")).endsWith(
                Path.of("Lua", RuntimeCatalogExporter.DIRECTORY)));
        check(RuntimeCatalogExporter.quoteForTest("a\"b\\c\n\t")
                .equals("\"a\\\"b\\\\c\\n\\t\""));
        check(RuntimeCatalogExporter.hashForTest("abc".getBytes(StandardCharsets.UTF_8))
                .equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
        String fileHashes = RuntimeCatalogExporter.fileHashesForTest(
                "items".getBytes(StandardCharsets.UTF_8), "recipes".getBytes(StandardCharsets.UTF_8));
        check(fileHashes.contains("\"pz-items.json\":\""));
        check(fileHashes.contains("\"pz-recipes.json\":\""));
        check(!fileHashes.contains("pz-runtime-fingerprint.json"));

        Path cache = Files.createTempDirectory("goblin-reference-cache-");
        Path root = cache.resolve("Lua").resolve(RuntimeCatalogExporter.DIRECTORY);
        Files.createDirectories(root);
        try {
            byte[] bytes = "{\"kind\":\"test\"}".getBytes(StandardCharsets.UTF_8);
            RuntimeCatalogExporter.writeForTest(root, RuntimeCatalogExporter.ITEMS_FILE, bytes);
            check(java.util.Arrays.equals(bytes, Files.readAllBytes(root.resolve(RuntimeCatalogExporter.ITEMS_FILE))));
            try (var files = Files.list(root)) { check(files.count() == 1); }
            rejects(() -> RuntimeCatalogExporter.writeForTest(root, "not-fixed.json", bytes));

            Path symlink = root.resolve(RuntimeCatalogExporter.RECIPES_FILE);
            try {
                Files.createSymbolicLink(symlink, root.resolve(RuntimeCatalogExporter.ITEMS_FILE));
                rejects(() -> RuntimeCatalogExporter.writeForTest(root, RuntimeCatalogExporter.RECIPES_FILE, bytes));
            } catch (UnsupportedOperationException | java.nio.file.FileSystemException | SecurityException ignored) {
                System.out.println("symlink rejection check not supported on this filesystem");
            } finally {
                Files.deleteIfExists(symlink);
            }
        } finally {
            Files.deleteIfExists(root.resolve(RuntimeCatalogExporter.ITEMS_FILE));
            Files.deleteIfExists(root.resolve(RuntimeCatalogExporter.RECIPES_FILE));
            Files.deleteIfExists(root.resolve(RuntimeCatalogExporter.FINGERPRINT_FILE));
            Files.deleteIfExists(root);
            Files.deleteIfExists(cache.resolve("Lua"));
            Files.deleteIfExists(cache);
        }
        System.out.println("RuntimeCatalogExporterTest: " + checks + " checks passed");
    }
}

package com.horsetheunicorn.goblin.server;

import io.pzstorm.storm.util.StormEnv;
import zombie.ZomboidFileSystem;
import zombie.core.Core;
import zombie.entity.components.fluids.Fluid;
import zombie.entity.components.resources.ResourceType;
import zombie.entity.energy.Energy;
import zombie.network.GameServer;
import zombie.scripting.ScriptManager;
import zombie.scripting.entity.components.crafting.CraftRecipe;
import zombie.scripting.entity.components.crafting.InputScript;
import zombie.scripting.entity.components.crafting.OutputScript;
import zombie.scripting.objects.Item;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

/**
 * One-shot, developer-authorized export of the loaded PZ item and recipe
 * registries. This class deliberately has no Lua exposure and no gameplay
 * operations: it only reads loaded Java registries and writes fixed files.
 */
final class RuntimeCatalogExporter {
    static final String PROPERTY = "goblin.referenceExport";
    static final String DIRECTORY = "goblin-reference-export";
    static final String ITEMS_FILE = "pz-items.json";
    static final String RECIPES_FILE = "pz-recipes.json";
    static final String FINGERPRINT_FILE = "pz-runtime-fingerprint.json";

    // A bad or unexpectedly large registry must not turn server startup into
    // an unbounded allocation or an unbounded filesystem write.
    static final int MAX_RECORDS = 250_000;
    static final int MAX_FILE_BYTES = 64 * 1024 * 1024;

    private static boolean attempted;

    private RuntimeCatalogExporter() { }

    /** Called from Storm's Lua OnTickEvenPaused event after vanilla OnServerStarted handlers have run. */
    static void exportOnce() {
        if (!Boolean.getBoolean(PROPERTY) || !StormEnv.isStormServer()
                || !GameServer.server || GameServer.coop) return;
        if (attempted) return;
        // Fishing.IndexAllLures is a vanilla Lua OnServerStarted callback. Storm's
        // Java OnServerStarted subscriber can run before that callback, so wait for
        // its effective index without invoking or mutating the registry ourselves.
        if (!RuntimeFishingCatalog.isInitialized(zombie.Lua.LuaManager.env)) return;
        // ISMoveableDefinitions keeps its initialized singleton in a private Lua
        // upvalue. The readiness check only inspects that upvalue; it never calls
        // getInstance/load or otherwise initializes definition state.
        if (!RuntimeMoveableCatalog.isInitialized()) return;
        attempted = true;
        try {
            CatalogSnapshot snapshot = collect();
            Path cache = Path.of(ZomboidFileSystem.instance.getCacheDir());
            write(cache, snapshot);
            System.out.println("[GoblinSurvivor] REFERENCE_EXPORT_WRITTEN items="
                    + snapshot.items.size() + " recipes=" + snapshot.recipes.size()
                    + " enabled_mods_fingerprint_status="
                    + (snapshot.context.modsFingerprint == null ? "UNKNOWN" : "CONTENT_VERIFIED"));
        } catch (Exception | LinkageError error) {
            // Reference export is deliberately fail-closed and never prevents
            // the ordinary helper from loading or changes the game state.
            System.err.println("[GoblinSurvivor] REFERENCE_EXPORT_FAILED "
                    + error.getClass().getSimpleName() + ": " + error.getMessage());
        }
    }

    private static CatalogSnapshot collect() throws IOException {
        ScriptManager manager = ScriptManager.instance;
        if (manager == null) throw new IOException("ScriptManager.instance unavailable");

        RuntimeContext context = RuntimeContext.collect();
        ArrayList<ItemRecord> items = new ArrayList<>();
        ArrayList<Item> definitions = manager.getAllItems();
        if (definitions == null) throw new IOException("ScriptManager.getAllItems returned null");
        if (definitions.size() > MAX_RECORDS) throw new IOException("Item registry exceeds bound");
        HashSet<String> itemIds = new HashSet<>();
        for (Item item : definitions) {
            if (item == null) throw new IOException("Item registry contains null definition");
            ItemRecord record = ItemRecord.read(item, manager, context);
            if (record.fullType == null || record.fullType.isBlank())
                throw new IOException("Item registry contains null/blank full type");
            if (manager.getItem(record.fullType) != item)
                throw new IOException("Item getter cannot round-trip exact full type: " + record.fullType);
            if (!itemIds.add(record.fullType)) throw new IOException("Duplicate item full type: " + record.fullType);
            items.add(record);
        }
        if (items.isEmpty()) throw new IOException("Item registry is empty");
        items.sort(Comparator.comparing(ItemRecord::sortKey));

        ArrayList<RecipeRecord> recipes = new ArrayList<>();
        ArrayList<CraftRecipe> loadedRecipes = manager.getAllCraftRecipes();
        if (loadedRecipes == null) throw new IOException("ScriptManager.getAllCraftRecipes returned null");
        if (loadedRecipes.size() > MAX_RECORDS) throw new IOException("Recipe registry exceeds bound");
        HashSet<String> recipeIds = new HashSet<>();
        for (CraftRecipe recipe : loadedRecipes) {
            if (recipe == null) throw new IOException("Recipe registry contains null definition");
            RecipeRecord record = RecipeRecord.read(recipe, manager, context);
            if (record.recipeId == null || record.recipeId.isBlank())
                throw new IOException("Recipe registry contains null/blank recipe ID");
            if (!recipeIds.add(record.recipeId)) throw new IOException("Duplicate recipe ID: " + record.recipeId);
            recipes.add(record);
        }
        if (recipes.isEmpty()) throw new IOException("Recipe registry is empty");
        recipes.sort(Comparator.comparing(RecipeRecord::sortKey));
        return new CatalogSnapshot(context, items, recipes, RuntimeSupplementalCatalog.collect(manager),
                RuntimeSupplementalCatalog.collectRepairs(manager), RuntimeSupplementalCatalog.collectMeals(manager),
                RuntimeCropCatalog.collect(), RuntimeVehicleCatalog.collect(manager), RuntimeSurvivalCatalog.collect(),
                RuntimeFishingCatalog.collect(), RuntimeMoveableCatalog.collect());
    }

    static Path outputRoot(Path cacheDir) {
        if (cacheDir == null) throw new IllegalArgumentException("cacheDir is null");
        return cacheDir.toAbsolutePath().normalize().resolve("Lua").resolve(DIRECTORY);
    }

    private static void write(Path cacheDir, CatalogSnapshot snapshot) throws IOException {
        Path root = outputRoot(cacheDir);
        requirePrecreatedDirectory(root);

        // The timestamp is intentionally omitted from the two canonical byte
        // streams used for comparison and hashing.
        byte[] canonicalItems = snapshot.itemsJson(false).getBytes(StandardCharsets.UTF_8);
        byte[] canonicalRecipes = snapshot.recipesJson(false).getBytes(StandardCharsets.UTF_8);
        String contentHash = sha256Hex(join(canonicalItems, canonicalRecipes));

        byte[] items = snapshot.itemsJson(true).getBytes(StandardCharsets.UTF_8);
        byte[] recipes = snapshot.recipesJson(true).getBytes(StandardCharsets.UTF_8);
        String itemsHash = sha256Hex(items);
        String recipesHash = sha256Hex(recipes);
        byte[] fingerprint = snapshot.fingerprintJson(contentHash, itemsHash, recipesHash).getBytes(StandardCharsets.UTF_8);
        // Reject all existing symlink targets before replacing any file.
        rejectSymlink(root.resolve(ITEMS_FILE));
        rejectSymlink(root.resolve(RECIPES_FILE));
        rejectSymlink(root.resolve(FINGERPRINT_FILE));
        atomicWrite(root.resolve(ITEMS_FILE), items);
        atomicWrite(root.resolve(RECIPES_FILE), recipes);
        atomicWrite(root.resolve(FINGERPRINT_FILE), fingerprint);
    }

    private static void requirePrecreatedDirectory(Path root) throws IOException {
        Path absolute = root.toAbsolutePath().normalize();
        Path cursor = absolute;
        while (cursor != null) {
            if (Files.isSymbolicLink(cursor)) throw new IOException("Reference export path contains symlink: " + cursor);
            cursor = cursor.getParent();
        }
        if (!Files.isDirectory(absolute, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Reference export directory is not precreated: " + absolute);
        }
    }

    private static void atomicWrite(Path destination, byte[] bytes) throws IOException {
        if (bytes == null || bytes.length > MAX_FILE_BYTES) throw new IOException("Reference export exceeds size bound");
        Path parent = destination.getParent();
        requirePrecreatedDirectory(parent);
        rejectSymlink(destination);

        Path temporary = Files.createTempFile(parent, ".goblin-reference-", ".tmp");
        try {
            try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                ByteBuffer data = ByteBuffer.wrap(bytes);
                while (data.hasRemaining()) channel.write(data);
                channel.force(true);
            }
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    private static void rejectSymlink(Path path) throws IOException {
        if (Files.isSymbolicLink(path)) throw new IOException("Refusing symlink output: " + path);
    }

    private static byte[] join(byte[] first, byte[] second) {
        byte[] joined = new byte[first.length + 1 + second.length];
        System.arraycopy(first, 0, joined, 0, first.length);
        joined[first.length] = (byte) '\n';
        System.arraycopy(second, 0, joined, first.length + 1, second.length);
        return joined;
    }

    private static String sha256Hex(byte[] bytes) throws IOException {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder result = new StringBuilder(digest.length * 2);
            for (byte value : digest) result.append(Character.forDigit((value >>> 4) & 0xf, 16))
                    .append(Character.forDigit(value & 0xf, 16));
            return result.toString();
        } catch (NoSuchAlgorithmException impossible) {
            throw new IOException("SHA-256 unavailable", impossible);
        }
    }

    static String quote(String value) {
        if (value == null) return "null";
        StringBuilder result = new StringBuilder(value.length() + 2).append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> result.append("\\\"");
                case '\\' -> result.append("\\\\");
                case '\b' -> result.append("\\b");
                case '\f' -> result.append("\\f");
                case '\n' -> result.append("\\n");
                case '\r' -> result.append("\\r");
                case '\t' -> result.append("\\t");
                default -> {
                    if (c < 0x20) result.append(String.format("\\u%04x", (int) c));
                    else result.append(c);
                }
            }
        }
        return result.append('"').toString();
    }

    private static String number(float value) {
        return Float.isFinite(value) ? Float.toString(value) : "null";
    }

    private static String nullIfBlank(String value) {
        return value == null || value.isBlank() ? null : value;
    }

    private static void field(StringBuilder out, String name, String value, boolean[] first) {
        if (!first[0]) out.append(',');
        first[0] = false;
        out.append(quote(name)).append(':').append(value);
    }

    private static String stringArray(Collection<String> values) {
        StringBuilder out = new StringBuilder("[");
        boolean first = true;
        if (values != null) {
            for (String value : values) {
                if (!first) out.append(',');
                first = false;
                out.append(quote(value));
            }
        }
        return out.append(']').toString();
    }

    private static List<String> sortedStrings(Collection<?> values) {
        TreeSet<String> sorted = new TreeSet<>();
        if (values != null) {
            for (Object value : values) if (value != null) sorted.add(String.valueOf(value));
        }
        return new ArrayList<>(sorted);
    }

    private static String nullableStringArray(Collection<String> values) {
        return values == null ? "null" : stringArray(values);
    }

    private static List<String> fluidIds(Collection<Fluid> fluids) {
        if (fluids == null) return null;
        ArrayList<String> ids = new ArrayList<>();
        for (Fluid fluid : fluids) ids.add(fluid == null ? null : nullIfBlank(fluid.getFluidTypeString()));
        return ids;
    }

    private static List<String> energyIds(Collection<Energy> energies) {
        if (energies == null) return null;
        ArrayList<String> ids = new ArrayList<>();
        for (Energy energy : energies) ids.add(energy == null ? null : nullIfBlank(energy.getEnergyTypeString()));
        return ids;
    }

    private static final class ResourceInfo {
        final String type;
        final List<String> fluids;
        final List<String> energies;
        final String status;
        final String reason;

        private ResourceInfo(String type, List<String> fluids, List<String> energies,
                             String status, String reason) {
            this.type = type;
            this.fluids = fluids;
            this.energies = energies;
            this.status = status;
            this.reason = reason;
        }

        static ResourceInfo read(ResourceType type, Collection<Fluid> fluids, Collection<Energy> energies) {
            String typeName = type == null ? null : type.name();
            List<String> fluidIds = fluidIds(fluids);
            List<String> energyIds = energyIds(energies);
            if (type == null) return new ResourceInfo(null, fluidIds, energyIds, "UNKNOWN",
                    "ResourceType getter returned null");
            if (type == ResourceType.Item) return new ResourceInfo(typeName, null, null, "RUNTIME_RESOLVED",
                    "Item resource type resolved; fluid and energy IDs are not applicable");
            if (type == ResourceType.Fluid) {
                boolean resolved = fluidIds != null && fluidIds.stream().allMatch(id -> id != null);
                return new ResourceInfo(typeName, fluidIds, null, resolved ? "RUNTIME_RESOLVED" : "UNKNOWN",
                        resolved ? "Fluid IDs resolved with Fluid.getFluidTypeString" : "Fluid registry IDs unavailable");
            }
            if (type == ResourceType.Energy) {
                boolean resolved = energyIds != null && energyIds.stream().allMatch(id -> id != null);
                return new ResourceInfo(typeName, null, energyIds, resolved ? "RUNTIME_RESOLVED" : "UNKNOWN",
                        resolved ? "Energy IDs resolved with Energy.getEnergyTypeString" : "Energy registry IDs unavailable");
            }
            return new ResourceInfo(typeName, null, null, "UNKNOWN",
                    "Any resource type cannot be assigned an invented fluid or energy ID");
        }

        String evidenceJson() {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "status", quote(status), first);
            field(out, "reason", quote(reason), first);
            return out.append('}').toString();
        }
    }

    private static String objectEvidence(RuntimeContext context, String sourceMod, String sourceFile) {
        StringBuilder out = new StringBuilder("{");
        boolean[] first = {true};
        field(out, "source_mod", quote(sourceMod == null ? "UNKNOWN: Item.getModID returned null" : "RUNTIME_RESOLVED"), first);
        field(out, "source_file", quote(sourceFile == null ? "UNKNOWN: Item.getFileName returned null" : "RUNTIME_RESOLVED"), first);
        field(out, "reusable_tool_roles", quote("UNAVAILABLE: item definitions do not expose NPC role classification; no inference"), first);
        field(out, "consumable_state", quote("UNAVAILABLE: instance condition/uses are not definition metadata; no instance was spawned"), first);
        field(out, "game_build", quote(context.gameBuild == null ? context.gameBuildEvidence : "RUNTIME_RESOLVED"), first);
        field(out, "enabled_mods_fingerprint", quote(context.modsFingerprint == null ? context.modsEvidence : "RUNTIME_RESOLVED"), first);
        return out.append('}').toString();
    }

    private static final class RuntimeContext {
        final String gameBuild;
        final String gameBuildEvidence;
        final String scriptChecksum;
        final String scriptChecksumEvidence;
        final List<String> enabledMods;
        final String enabledModsSource;
        final String enabledModsOrderHash;
        final String modsFingerprint;
        final String modsEvidence;
        final String timestamp;
        RuntimeContentFingerprint content;

        private RuntimeContext(String gameBuild, String gameBuildEvidence, String scriptChecksum,
                               String scriptChecksumEvidence, List<String> enabledMods,
                               String enabledModsSource, String enabledModsOrderHash,
                               String modsFingerprint, String modsEvidence) {
            this.gameBuild = gameBuild;
            this.gameBuildEvidence = gameBuildEvidence;
            this.scriptChecksum = scriptChecksum;
            this.scriptChecksumEvidence = scriptChecksumEvidence;
            this.enabledMods = enabledMods;
            this.enabledModsSource = enabledModsSource;
            this.enabledModsOrderHash = enabledModsOrderHash;
            this.modsFingerprint = modsFingerprint;
            this.modsEvidence = modsEvidence;
            this.timestamp = Instant.now().toString();
        }

        static RuntimeContext collect() throws IOException {
            String build = null;
            String buildEvidence;
            try {
                Core core = Core.getInstance();
                // getVersionNumber() omits the patch build in installed B42.
                // getVersion() includes that build and the game git revision.
                build = core == null ? null : nullIfBlank(core.getVersion());
                buildEvidence = build == null ? "UNKNOWN: Core.getInstance().getVersion returned null" : "RUNTIME_RESOLVED: Core.getInstance().getVersion";
            } catch (Exception | LinkageError error) {
                buildEvidence = "UNKNOWN: Core version unavailable (" + error.getClass().getSimpleName() + ')';
            }

            ScriptManager manager = ScriptManager.instance;
            String checksum = null;
            String checksumEvidence;
            try {
                checksum = manager == null ? null : nullIfBlank(manager.getChecksum());
                checksumEvidence = checksum == null ? "UNKNOWN: ScriptManager.getChecksum returned null" : "RUNTIME_RESOLVED: ScriptManager.getChecksum";
            } catch (Exception | LinkageError error) {
                checksumEvidence = "UNKNOWN: Script registry checksum unavailable (" + error.getClass().getSimpleName() + ')';
            }

            ArrayList<String> modIds = null;
            String modSource = null;
            String modEvidence;
            try {
                if (ZomboidFileSystem.instance != null) {
                    ArrayList<String> observed = ZomboidFileSystem.instance.getModIDs();
                    if (observed != null) {
                        modIds = new ArrayList<>();
                        for (String id : observed) {
                            if (id == null || id.isBlank()) { modIds = null; break; }
                            modIds.add(id);
                        }
                        modSource = "ZomboidFileSystem.getModIDs";
                    }
                }
            } catch (Exception | LinkageError error) {
                modEvidence = "UNKNOWN: enabled mod registry unavailable (" + error.getClass().getSimpleName() + ')';
                modIds = null;
            }
            if (modIds == null) {
                modEvidence = "UNKNOWN: ZomboidFileSystem.getModIDs returned null or was unavailable";
                return new RuntimeContext(build, buildEvidence, checksum, checksumEvidence,
                        List.of(), modSource, null, null, modEvidence);
            }
            String orderHash = sha256Hex(('[' + String.join(",", modIds) + ']').getBytes(StandardCharsets.UTF_8));
            RuntimeContentFingerprint content = RuntimeContentFingerprint.collect(modIds);
            modEvidence = "CONTENT_VERIFIED: SHA256 of runtime-selected common/version roots in loaded order; includes overridden files within selected roots, excludes inactive versions; not an atomic whole-install snapshot";
            RuntimeContext context = new RuntimeContext(build, buildEvidence, checksum, checksumEvidence,
                    List.copyOf(modIds), modSource, orderHash, content.sha256, modEvidence);
            context.content = content;
            return context;
        }
    }

    private static final class CatalogSnapshot {
        final RuntimeContext context;
        final List<ItemRecord> items;
        final List<RecipeRecord> recipes;
        final List<RuntimeSupplementalCatalog.Identity> supplemental;
        final List<RuntimeSupplementalCatalog.Repair> repairs;
        final List<RuntimeSupplementalCatalog.Meal> meals;
        final List<RuntimeCropCatalog.Crop> crops;
        final List<RuntimeVehicleCatalog.Vehicle> vehicles;
        final RuntimeSurvivalCatalog.Snapshot survival;
        final RuntimeFishingCatalog.Snapshot fishing;
        final RuntimeMoveableCatalog.Snapshot moveables;

        CatalogSnapshot(RuntimeContext context, List<ItemRecord> items, List<RecipeRecord> recipes,
                        List<RuntimeSupplementalCatalog.Identity> supplemental,
                        List<RuntimeSupplementalCatalog.Repair> repairs,
                        List<RuntimeSupplementalCatalog.Meal> meals, List<RuntimeCropCatalog.Crop> crops,
                        List<RuntimeVehicleCatalog.Vehicle> vehicles, RuntimeSurvivalCatalog.Snapshot survival,
                        RuntimeFishingCatalog.Snapshot fishing, RuntimeMoveableCatalog.Snapshot moveables) {
            this.context = context;
            this.items = List.copyOf(items);
            this.recipes = List.copyOf(recipes);
            this.supplemental = List.copyOf(supplemental);
            this.repairs = List.copyOf(repairs);
            this.meals = List.copyOf(meals);
            this.crops = List.copyOf(crops);
            this.vehicles = List.copyOf(vehicles);
            this.survival = survival;
            this.fishing = fishing;
            this.moveables = moveables;
        }

        String itemsJson(boolean timestamp) {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "schema_version", "1", first);
            field(out, "kind", quote("pz-items"), first);
            field(out, "game_build", quote(context.gameBuild), first);
            field(out, "enabled_mods_fingerprint", quote(context.modsFingerprint), first);
            if (timestamp) field(out, "export_timestamp", quote(context.timestamp), first);
            field(out, "unavailable", unavailableJson(), first);
            field(out, "records", "[", first);
            for (int i = 0; i < items.size(); i++) {
                if (i != 0) out.append(',');
                out.append(items.get(i).json(context, timestamp));
            }
            out.append(']');
            return out.append('}').toString();
        }

        String recipesJson(boolean timestamp) {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "schema_version", "1", first);
            field(out, "kind", quote("pz-recipes"), first);
            field(out, "game_build", quote(context.gameBuild), first);
            field(out, "enabled_mods_fingerprint", quote(context.modsFingerprint), first);
            if (timestamp) field(out, "export_timestamp", quote(context.timestamp), first);
            field(out, "unavailable", unavailableJson(), first);
            field(out, "records", "[", first);
            for (int i = 0; i < recipes.size(); i++) {
                if (i != 0) out.append(',');
                out.append(recipes.get(i).json(context, timestamp));
            }
            out.append(']');
            return out.append('}').toString();
        }

        String unavailableJson() {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "game_build", quote(context.gameBuild == null ? context.gameBuildEvidence : null), first);
            field(out, "script_registry_checksum", quote(context.scriptChecksum == null ? context.scriptChecksumEvidence : null), first);
            field(out, "enabled_mods_fingerprint", quote(context.modsFingerprint == null ? context.modsEvidence : null), first);
            field(out, "reusable_tool_roles", quote("UNAVAILABLE: no NPC role inference from item definitions"), first);
            field(out, "consumable_state", quote("UNAVAILABLE: definition export does not spawn inventory instances"), first);
            field(out, "lua_callbacks", quote("UNAVAILABLE: callback identifiers are not exported without a verified safe binding"), first);
            return out.append('}').toString();
        }

        String fingerprintJson(String contentHash, String itemsHash, String recipesHash) throws IOException {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "schema_version", "1", first);
            field(out, "kind", quote("pz-runtime-fingerprint"), first);
            field(out, "game_build", quote(context.gameBuild), first);
            field(out, "game_build_status", quote(context.gameBuild == null ? "UNKNOWN" : "RUNTIME_RESOLVED"), first);
            field(out, "game_build_evidence", quote(context.gameBuildEvidence), first);
            field(out, "script_registry_checksum", quote(context.scriptChecksum), first);
            field(out, "script_registry_checksum_status", quote(context.scriptChecksum == null ? "UNKNOWN" : "RUNTIME_RESOLVED"), first);
            field(out, "script_registry_checksum_evidence", quote(context.scriptChecksumEvidence), first);
            field(out, "enabled_mods", stringArray(context.enabledMods), first);
            field(out, "enabled_mods_source", quote(context.enabledModsSource), first);
            field(out, "enabled_mods_status", quote(context.enabledModsSource == null ? "UNKNOWN" : "RUNTIME_RESOLVED"), first);
            field(out, "enabled_mod_order_sha256", quote(context.enabledModsOrderHash), first);
            field(out, "enabled_mod_order_sha256_status", quote(context.enabledModsOrderHash == null ? "UNKNOWN" : "RUNTIME_RESOLVED"), first);
            field(out, "enabled_mods_fingerprint", quote(context.modsFingerprint), first);
            field(out, "enabled_mods_fingerprint_status", quote(context.modsFingerprint == null ? "UNKNOWN" : "CONTENT_VERIFIED"), first);
            field(out, "enabled_mods_fingerprint_evidence", quote(context.modsEvidence), first);
            field(out, "enabled_mods_content_algorithm", quote(RuntimeContentFingerprint.ALGORITHM), first);
            field(out, "enabled_mods_content", context.content == null ? "null" : context.content.manifestJson, first);
            field(out, "catalog_content_sha256", quote(contentHash), first);
            field(out, "catalog_content_sha256_status", quote("RUNTIME_RESOLVED"), first);
            // Separate canonical hash: preserve the existing item/recipe hash
            // contract while explicitly fingerprinting supplemental identities.
            String supplementalJson = supplementalJson(supplemental);
            field(out, "supplemental_catalog", supplementalJson, first);
            field(out, "supplemental_catalog_sha256",
                    quote(sha256Hex(supplementalJson.getBytes(StandardCharsets.UTF_8))), first);
            String repairsJson = repairsJson(repairs);
            field(out, "fixing_details", repairsJson, first);
            field(out, "fixing_details_sha256",
                    quote(sha256Hex(repairsJson.getBytes(StandardCharsets.UTF_8))), first);
            String mealsJson = mealsJson(meals);
            field(out, "evolved_details", mealsJson, first);
            field(out, "evolved_details_sha256",
                    quote(sha256Hex(mealsJson.getBytes(StandardCharsets.UTF_8))), first);
            String cropsJson = cropsJson(crops);
            field(out, "crop_details", cropsJson, first);
            field(out, "crop_details_sha256",
                    quote(sha256Hex(cropsJson.getBytes(StandardCharsets.UTF_8))), first);
            String vehiclesJson = vehiclesJson(vehicles);
            field(out, "vehicle_details", vehiclesJson, first);
            field(out, "vehicle_details_sha256",
                    quote(sha256Hex(vehiclesJson.getBytes(StandardCharsets.UTF_8))), first);
            String survivalJson = survivalJson(survival);
            field(out, "survival_details", survivalJson, first);
            field(out, "survival_details_sha256",
                    quote(sha256Hex(survivalJson.getBytes(StandardCharsets.UTF_8))), first);
            String fishingJson = fishingJson(fishing);
            field(out, "fishing_details", fishingJson, first);
            field(out, "fishing_details_sha256",
                    quote(sha256Hex(fishingJson.getBytes(StandardCharsets.UTF_8))), first);
            String moveablesJson = moveablesJson(moveables);
            field(out, "moveable_details", moveablesJson, first);
            field(out, "moveable_details_sha256",
                    quote(sha256Hex(moveablesJson.getBytes(StandardCharsets.UTF_8))), first);
            field(out, "export_files_sha256", fileHashesJson(itemsHash, recipesHash), first);
            field(out, "export_timestamp", quote(context.timestamp), first);
            return out.append('}').toString();
        }
    }

    static String supplementalJson(List<RuntimeSupplementalCatalog.Identity> identities) {
        StringBuilder out = new StringBuilder("{\"schema_version\":1,\"scope\":\"identity_only\",\"npc_compatibility\":\"UNKNOWN\",\"records\":[");
        for (int i = 0; i < identities.size(); i++) {
            if (i > 0) out.append(',');
            var identity = identities.get(i);
            out.append("{\"kind\":").append(quote(identity.kind()))
                    .append(",\"id\":").append(quote(identity.id()))
                    .append(",\"obsolete\":").append(identity.obsolete())
                    .append('}');
        }
        return out.append("]}").toString();
    }

    static String vehiclesJson(List<RuntimeVehicleCatalog.Vehicle> vehicles) {
        StringBuilder out = new StringBuilder("{\"schema_version\":2,\"npc_compatibility\":\"UNKNOWN\",\"records\":[");
        for (int i = 0; i < vehicles.size(); i++) {
            if (i > 0) out.append(',');
            var vehicle = vehicles.get(i);
            out.append("{\"id\":").append(quote(vehicle.id()))
                    .append(",\"mechanic_type\":").append(vehicle.mechanicType())
                    .append(",\"engine_repair_level\":").append(vehicle.engineRepairLevel())
                    .append(",\"parts\":[");
            for (int j = 0; j < vehicle.parts().size(); j++) {
                if (j > 0) out.append(',');
                var part = vehicle.parts().get(j);
                out.append("{\"id\":").append(quote(part.id()))
                        .append(",\"parent\":").append(quote(part.parent()))
                        .append(",\"area\":").append(quote(part.area()))
                        .append(",\"mechanic_area\":").append(quote(part.mechanicArea()))
                        .append(",\"item_types\":").append(part.itemTypes() == null ? "null" : stringArray(part.itemTypes()))
                        .append(",\"specific_item\":").append(part.specificItem())
                        .append(",\"requires_key\":").append(part.requiresKey())
                        .append(",\"repair_mechanic\":").append(part.repairMechanic())
                        .append(",\"callbacks\":{");
                boolean firstCallback = true;
                for (var entry : new java.util.TreeMap<>(part.callbacks()).entrySet()) {
                    if (!firstCallback) out.append(',');
                    firstCallback = false;
                    out.append(quote(entry.getKey())).append(':').append(quote(entry.getValue()));
                }
                out.append("},\"table_names\":").append(stringArray(part.tableNames())).append(",\"tables\":{");
                boolean firstTable = true;
                for (var entry : new java.util.TreeMap<>(part.tables()).entrySet()) {
                    if (!firstTable) out.append(',');
                    firstTable = false;
                    out.append(quote(entry.getKey())).append(':').append(definitionJson(entry.getValue()));
                }
                out.append("}}");
            }
            out.append("]}");
        }
        return out.append("]}").toString();
    }

    static String fishingJson(RuntimeFishingCatalog.Snapshot fishing) {
        StringBuilder out = new StringBuilder("{\"schema_version\":1,\"npc_compatibility\":\"UNKNOWN\",\"fields\":{");
        boolean first = true;
        for (var entry : new java.util.TreeMap<>(fishing.fields()).entrySet()) {
            if (!first) out.append(',');
            first = false;
            out.append(quote(entry.getKey())).append(':').append(definitionJson(entry.getValue()));
        }
        return out.append("}}").toString();
    }

    static String moveablesJson(RuntimeMoveableCatalog.Snapshot moveables) {
        StringBuilder out = new StringBuilder("{\"schema_version\":1,\"npc_compatibility\":\"UNKNOWN\",\"fields\":{");
        boolean first = true;
        for (var entry : new java.util.TreeMap<>(moveables.fields()).entrySet()) {
            if (!first) out.append(',');
            first = false;
            out.append(quote(entry.getKey())).append(':').append(definitionJson(entry.getValue()));
        }
        return out.append("}}").toString();
    }

    static String survivalJson(RuntimeSurvivalCatalog.Snapshot survival) {
        StringBuilder out = new StringBuilder("{\"schema_version\":1,\"npc_compatibility\":\"UNKNOWN\",\"traps\":")
                .append(definitionJson(survival.traps())).append(",\"animals\":")
                .append(definitionJson(survival.animals())).append(",\"forage\":[");
        boolean first = true;
        for (var entry : survival.forage()) {
            if (!first) out.append(',');
            first = false;
            out.append("{\"id\":").append(quote(entry.id())).append(",\"fields\":{");
            boolean firstField = true;
            for (var field : new java.util.TreeMap<>(entry.fields()).entrySet()) {
                if (!firstField) out.append(',');
                firstField = false;
                out.append(quote(field.getKey())).append(':').append(definitionJson(field.getValue()));
            }
            out.append("},\"unexported_fields\":").append(stringArray(entry.unexportedFields())).append('}');
        }
        return out.append("]}").toString();
    }

    static String definitionJson(RuntimeDefinitionTable.Value value) {
        StringBuilder out = new StringBuilder("{\"type\":").append(quote(value.type()))
                .append(",\"scalar\":").append(quote(value.scalar())).append(",\"entries\":[");
        boolean first = true;
        for (var entry : value.entries()) {
            if (!first) out.append(',');
            first = false;
            out.append("{\"key_type\":").append(quote(entry.keyType()))
                    .append(",\"key\":").append(quote(entry.key()))
                    .append(",\"value\":").append(definitionJson(entry.value())).append('}');
        }
        return out.append("]}").toString();
    }

    static String cropsJson(List<RuntimeCropCatalog.Crop> crops) {
        StringBuilder out = new StringBuilder("{\"schema_version\":1,\"npc_compatibility\":\"UNKNOWN\",\"records\":[");
        for (int i = 0; i < crops.size(); i++) {
            if (i > 0) out.append(',');
            var crop = crops.get(i);
            out.append("{\"name\":").append(quote(crop.name()))
                    .append(",\"seed_name\":").append(quote(crop.seedName()))
                    .append(",\"vegetable_name\":").append(quote(crop.vegetableName()))
                    .append(",\"produce_extra\":").append(quote(crop.produceExtra()))
                    .append(",\"season_recipe\":").append(quote(crop.seasonRecipe()))
                    .append(",\"seed_types\":").append(crop.seedTypes() == null ? "null" : stringArray(crop.seedTypes()))
                    .append('}');
        }
        return out.append("]}").toString();
    }

    static String mealsJson(List<RuntimeSupplementalCatalog.Meal> meals) {
        StringBuilder out = new StringBuilder("{\"schema_version\":1,\"npc_compatibility\":\"UNKNOWN\",\"records\":[");
        for (int i = 0; i < meals.size(); i++) {
            if (i > 0) out.append(',');
            var meal = meals.get(i);
            out.append("{\"id\":").append(quote(meal.id()))
                    .append(",\"base\":").append(meal.base() == null ? "null" : itemReferenceJson(meal.base()))
                    .append(",\"result\":").append(meal.result() == null ? "null" : itemReferenceJson(meal.result()))
                    .append(",\"max_items\":").append(meal.maxItems())
                    .append(",\"minimum_water\":").append(quote(Float.toString(meal.minimumWater())))
                    .append(",\"cookable\":").append(meal.cookable()).append(",\"ingredients\":[");
            for (int j = 0; j < meal.ingredients().size(); j++) {
                if (j > 0) out.append(',');
                var ingredient = meal.ingredients().get(j);
                out.append("{\"item\":").append(itemReferenceJson(ingredient.item()))
                        .append(",\"use\":").append(ingredient.use())
                        .append(",\"cooked\":").append(ingredient.cooked()).append('}');
            }
            out.append("]}");
        }
        return out.append("]}").toString();
    }

    static String repairsJson(List<RuntimeSupplementalCatalog.Repair> repairs) {
        StringBuilder out = new StringBuilder("{\"schema_version\":1,\"npc_compatibility\":\"UNKNOWN\",\"records\":[");
        for (int i = 0; i < repairs.size(); i++) {
            if (i > 0) out.append(',');
            var repair = repairs.get(i);
            out.append("{\"id\":").append(quote(repair.id())).append(",\"targets\":[");
            for (int j = 0; j < repair.targets().size(); j++) {
                if (j > 0) out.append(',');
                out.append(itemReferenceJson(repair.targets().get(j)));
            }
            out.append("],\"alternatives\":[");
            for (int j = 0; j < repair.alternatives().size(); j++) {
                if (j > 0) out.append(',');
                out.append(materialJson(repair.alternatives().get(j)));
            }
            out.append("],\"global\":").append(materialJson(repair.global()))
                    .append(",\"condition_modifier\":").append(quote(Float.toString(repair.conditionModifier()))).append('}');
        }
        return out.append("]}").toString();
    }

    private static String itemReferenceJson(RuntimeSupplementalCatalog.ItemReference item) {
        return "{\"declared\":" + quote(item.declared()) + ",\"resolved\":" + quote(item.resolved())
                + ",\"obsolete\":" + item.obsolete() + "}";
    }

    private static String materialJson(RuntimeSupplementalCatalog.Material material) {
        if (material == null) return "null";
        StringBuilder out = new StringBuilder("{\"item\":").append(itemReferenceJson(material.item()))
                .append(",\"uses\":").append(material.uses()).append(",\"skills\":[");
        for (int i = 0; i < material.skills().size(); i++) {
            if (i > 0) out.append(',');
            var skill = material.skills().get(i);
            out.append("{\"name\":").append(quote(skill.name())).append(",\"level\":")
                    .append(skill.level()).append('}');
        }
        return out.append("]}").toString();
    }

    private static String fileHashesJson(String itemsHash, String recipesHash) {
        StringBuilder out = new StringBuilder("{");
        boolean[] first = {true};
        field(out, ITEMS_FILE, quote(itemsHash), first);
        field(out, RECIPES_FILE, quote(recipesHash), first);
        return out.append('}').toString();
    }

    private static final class ItemRecord {
        final String fullType;
        final String displayName;
        final String displayCategory;
        final float weight;
        final List<String> tags;
        final String sourceMod;
        final String sourceFile;
        final boolean lookupByFullType;
        final boolean enabled;
        final boolean obsolete;

        private ItemRecord(String fullType, String displayName, String displayCategory,
                           float weight, List<String> tags, String sourceMod, String sourceFile,
                           boolean lookupByFullType, boolean enabled, boolean obsolete) {
            this.fullType = fullType;
            this.displayName = displayName;
            this.displayCategory = displayCategory;
            this.weight = weight;
            this.tags = tags;
            this.sourceMod = sourceMod;
            this.sourceFile = sourceFile;
            this.lookupByFullType = lookupByFullType;
            this.enabled = enabled;
            this.obsolete = obsolete;
        }

        static ItemRecord read(Item item, ScriptManager manager, RuntimeContext ignored) {
            String fullType = item.getFullName();
            return new ItemRecord(fullType, item.getDisplayName(), item.getDisplayCategory(),
                    item.getActualWeight(), sortedStrings(item.getTags()), nullIfBlank(item.getModID()),
                    nullIfBlank(item.getFileName()), fullType != null && manager.getItem(fullType) == item,
                    item.isEnabled(), item.getObsolete());
        }

        String sortKey() { return fullType == null ? "" : fullType; }

        String json(RuntimeContext context, boolean timestamp) {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "full_type", quote(fullType), first);
            field(out, "display_name", quote(displayName), first);
            field(out, "display_category", quote(displayCategory), first);
            field(out, "weight", number(weight), first);
            field(out, "tags", stringArray(tags), first);
            field(out, "source_mod", quote(sourceMod), first);
            field(out, "source_file", quote(sourceFile), first);
            field(out, "lookup_by_id", Boolean.toString(lookupByFullType), first);
            field(out, "lookup_evidence", quote("RUNTIME_RESOLVED: ScriptManager.getItem(full_type)"), first);
            field(out, "enabled", Boolean.toString(enabled), first);
            field(out, "obsolete", Boolean.toString(obsolete), first);
            field(out, "reusable_tool_roles", "null", first);
            field(out, "consumable_state", "null", first);
            field(out, "game_build", quote(context.gameBuild), first);
            field(out, "enabled_mods_fingerprint", quote(context.modsFingerprint), first);
            if (timestamp) field(out, "export_timestamp", quote(context.timestamp), first);
            field(out, "evidence", objectEvidence(context, sourceMod, sourceFile), first);
            return out.append('}').toString();
        }
    }

    private static final class RecipeRecord {
        final String recipeId;
        final String name;
        final String modId;
        final List<String> tags;
        final boolean enabled;
        final boolean obsolete;
        final boolean requiresPlayer;
        final boolean lookupById;
        final boolean lookupByName;
        final String lookupKey;
        final String lookupEvidence;
        final List<InputRecord> inputs;
        final List<OutputRecord> outputs;

        private RecipeRecord(String recipeId, String name, String modId, List<String> tags,
                             boolean enabled, boolean obsolete, boolean requiresPlayer,
                             boolean lookupById, boolean lookupByName, String lookupEvidence,
                             List<InputRecord> inputs, List<OutputRecord> outputs) {
            this.recipeId = recipeId;
            this.name = name;
            this.modId = modId;
            this.tags = tags;
            this.enabled = enabled;
            this.obsolete = obsolete;
            this.requiresPlayer = requiresPlayer;
            this.lookupById = lookupById;
            this.lookupByName = lookupByName;
            this.lookupKey = lookupById ? recipeId : name;
            this.lookupEvidence = lookupEvidence;
            this.inputs = inputs;
            this.outputs = outputs;
        }

        static RecipeRecord read(CraftRecipe recipe, ScriptManager manager, RuntimeContext ignored) throws IOException {
            String recipeId = recipe.getScriptObjectFullType();
            String name = recipe.getName();
            CraftRecipe byId = recipeId == null ? null : manager.getCraftRecipe(recipeId);
            CraftRecipe byName = name == null ? null : manager.getCraftRecipe(name);
            boolean lookupById = byId == recipe;
            boolean lookupByName = byName == recipe;
            if (!lookupById && !lookupByName)
                throw new IOException("Recipe getter cannot round-trip exact ID/name: " + recipeId);
            String lookupEvidence = lookupById ? "RUNTIME_RESOLVED: ScriptManager.getCraftRecipe(recipe_id)"
                    : "RUNTIME_RESOLVED: ScriptManager.getCraftRecipe(name); recipe_id lookup unavailable";
            ArrayList<InputRecord> inputs = new ArrayList<>();
            if (recipe.getInputs() != null) {
                for (InputScript input : recipe.getInputs()) if (input != null) inputs.add(InputRecord.read(input));
            }
            ArrayList<OutputRecord> outputs = new ArrayList<>();
            if (recipe.getOutputs() != null) {
                for (OutputScript output : recipe.getOutputs()) if (output != null) outputs.add(OutputRecord.read(output));
            }
            return new RecipeRecord(recipeId, name, recipe.getModID(),
                    sortedStrings(recipe.getTags()), recipe.isEnabled(), recipe.getObsolete(),
                    recipe.isRequiresPlayer(), lookupById, lookupByName, lookupEvidence,
                    List.copyOf(inputs), List.copyOf(outputs));
        }

        String sortKey() { return recipeId == null ? (name == null ? "" : name) : recipeId; }

        String json(RuntimeContext context, boolean timestamp) {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "recipe_id", quote(recipeId), first);
            field(out, "name", quote(name), first);
            field(out, "mod_id", quote(modId), first);
            field(out, "tags", stringArray(tags), first);
            field(out, "enabled", Boolean.toString(enabled), first);
            field(out, "obsolete", Boolean.toString(obsolete), first);
            field(out, "requires_player", Boolean.toString(requiresPlayer), first);
            field(out, "npc_compatibility", quote("UNKNOWN"), first);
            field(out, "npc_compatibility_evidence", quote("UNAVAILABLE: catalog export does not execute or engine-test NPC crafting"), first);
            field(out, "lookup_by_id", Boolean.toString(lookupById), first);
            field(out, "lookup_by_name", Boolean.toString(lookupByName), first);
            field(out, "lookup_key", quote(lookupKey), first);
            field(out, "lookup_evidence", quote(lookupEvidence), first);
            field(out, "lua_callbacks", "null", first);
            field(out, "inputs", ioArray(inputs), first);
            field(out, "outputs", ioArray(outputs), first);
            field(out, "game_build", quote(context.gameBuild), first);
            field(out, "enabled_mods_fingerprint", quote(context.modsFingerprint), first);
            if (timestamp) field(out, "export_timestamp", quote(context.timestamp), first);
            return out.append('}').toString();
        }

        private static String ioArray(List<?> records) {
            StringBuilder out = new StringBuilder("[");
            for (int i = 0; i < records.size(); i++) {
                if (i != 0) out.append(',');
                out.append(records.get(i));
            }
            return out.append(']').toString();
        }
    }

    private static final class InputRecord {
        final List<String> items;
        final List<String> possibleItems;
        final List<String> itemTags;
        final ResourceInfo resource;
        final float amount;
        final float maxAmount;
        final boolean variableAmount;
        final boolean tool;
        final boolean keep;
        final boolean destroy;

        private InputRecord(List<String> items, List<String> possibleItems, List<String> itemTags,
                            ResourceInfo resource,
                            float amount, float maxAmount, boolean variableAmount, boolean tool,
                            boolean keep, boolean destroy) {
            this.items = items;
            this.possibleItems = possibleItems;
            this.itemTags = itemTags;
            this.resource = resource;
            this.amount = amount;
            this.maxAmount = maxAmount;
            this.variableAmount = variableAmount;
            this.tool = tool;
            this.keep = keep;
            this.destroy = destroy;
        }

        static InputRecord read(InputScript input) {
            ArrayList<String> items = input.getItems() == null ? new ArrayList<>() : new ArrayList<>(input.getItems());
            ArrayList<String> possibleItems = new ArrayList<>();
            if (input.getPossibleInputItems() != null) {
                for (Item item : input.getPossibleInputItems()) if (item != null) possibleItems.add(item.getFullName());
            }
            return new InputRecord(items, possibleItems, sortedStrings(input.getItemTags()),
                    ResourceInfo.read(input.getResourceType(), input.getPossibleInputFluids(), input.getPossibleInputEnergies()),
                    input.getAmount(),
                    input.getMaxAmount(), input.isVariableAmount(), input.isTool(), input.isKeep(),
                    input.isDestroy());
        }

        @Override public String toString() {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "items", stringArray(items), first);
            field(out, "possible_items", stringArray(possibleItems), first);
            field(out, "item_tags", stringArray(itemTags), first);
            field(out, "resource_type", quote(resource.type), first);
            field(out, "possible_fluids", nullableStringArray(resource.fluids), first);
            field(out, "possible_energies", nullableStringArray(resource.energies), first);
            field(out, "resource_evidence", resource.evidenceJson(), first);
            field(out, "amount", number(amount), first);
            field(out, "max_amount", number(maxAmount), first);
            field(out, "variable_amount", Boolean.toString(variableAmount), first);
            field(out, "tool", Boolean.toString(tool), first);
            field(out, "keep", Boolean.toString(keep), first);
            field(out, "destroy", Boolean.toString(destroy), first);
            return out.append('}').toString();
        }
    }

    private static final class OutputRecord {
        final List<String> possibleItems;
        final ResourceInfo resource;
        final float amount;
        final float maxAmount;
        final float chance;
        final boolean variableAmount;
        final boolean replaceInput;

        private OutputRecord(List<String> possibleItems, ResourceInfo resource,
                             float amount, float maxAmount, float chance,
                             boolean variableAmount, boolean replaceInput) {
            this.possibleItems = possibleItems;
            this.resource = resource;
            this.amount = amount;
            this.maxAmount = maxAmount;
            this.chance = chance;
            this.variableAmount = variableAmount;
            this.replaceInput = replaceInput;
        }

        static OutputRecord read(OutputScript output) {
            ArrayList<String> possibleItems = new ArrayList<>();
            if (output.getPossibleResultItems() != null) {
                for (Item item : output.getPossibleResultItems()) if (item != null) possibleItems.add(item.getFullName());
            }
            return new OutputRecord(possibleItems,
                    ResourceInfo.read(output.getResourceType(), output.getPossibleResultFluids(), output.getPossibleResultEnergies()),
                    output.getAmount(), output.getMaxAmount(), output.getChance(),
                    output.isVariableAmount(), output.isReplaceInput());
        }

        @Override public String toString() {
            StringBuilder out = new StringBuilder("{");
            boolean[] first = {true};
            field(out, "possible_items", stringArray(possibleItems), first);
            field(out, "resource_type", quote(resource.type), first);
            field(out, "possible_fluids", nullableStringArray(resource.fluids), first);
            field(out, "possible_energies", nullableStringArray(resource.energies), first);
            field(out, "resource_evidence", resource.evidenceJson(), first);
            field(out, "amount", number(amount), first);
            field(out, "max_amount", number(maxAmount), first);
            field(out, "chance", number(chance), first);
            field(out, "variable_amount", Boolean.toString(variableAmount), first);
            field(out, "replace_input", Boolean.toString(replaceInput), first);
            return out.append('}').toString();
        }
    }

    // Focused tests use these package-private helpers without initializing PZ.
    static String quoteForTest(String value) { return quote(value); }
    static String hashForTest(byte[] bytes) throws IOException { return sha256Hex(bytes); }
    static String fileHashesForTest(byte[] items, byte[] recipes) throws IOException {
        return fileHashesJson(sha256Hex(items), sha256Hex(recipes));
    }
    static void writeForTest(Path root, String filename, byte[] bytes) throws IOException {
        requirePrecreatedDirectory(root);
        if (!Set.of(ITEMS_FILE, RECIPES_FILE, FINGERPRINT_FILE).contains(filename))
            throw new IOException("Invalid fixed reference filename");
        atomicWrite(root.resolve(filename), bytes);
    }
}

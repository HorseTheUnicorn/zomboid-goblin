package com.horsetheunicorn.goblin.server;

import io.pzstorm.storm.util.StormEnv;
import zombie.ZomboidFileSystem;
import zombie.characters.IsoGameCharacter;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.iso.IsoWorld;
import zombie.network.GameServer;

import java.io.IOException;
import java.nio.BufferOverflowException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;

/** All calls execute on the PZ server thread through trusted server Lua. */
public final class ServerSupport {
    private static final int MAGIC = 0x474F4249; // GOBI
    private static final int MAX_INVENTORY = 8 * 1024 * 1024;
    private static final int HEADER = 4 + 4 + 4 + 32;
    private static final Set<String> CHANNELS = Set.of("events", "state", "runtime", "responses", "acks", "commands", "archive", "deadletter");
    private static final Map<IsoGameCharacter, String> RESTORED = new WeakHashMap<>();
    private static final Map<IsoGameCharacter, byte[]> SAVED_HASHES = new WeakHashMap<>();

    private ServerSupport() { }
    private static boolean server() { return StormEnv.isStormServer() && GameServer.server; }
    public static String capabilities() { return server() ? "goblin-server/1:inventory,atomic-ipc,craft,repair" : "disabled"; }

    static Path bridgePath(Path cache, String relative) throws IOException {
        if (relative == null || relative.length() > 240 || relative.contains("\\") || relative.contains(".."))
            throw new IOException("Invalid bridge path");
        String[] parts = relative.split("/", -1);
        if (parts.length != 3 || !parts[0].equals("goblin-bridge") || !CHANNELS.contains(parts[1])
                || !parts[2].matches("[A-Za-z0-9][A-Za-z0-9_.-]{0,160}\\.(json|ready|done)"))
            throw new IOException("Bridge write is outside the fixed queue channels");
        Path root = cache.toAbsolutePath().normalize().resolve("Lua/goblin-bridge");
        Path result = cache.toAbsolutePath().normalize().resolve("Lua").resolve(relative).normalize();
        if (!result.startsWith(root)) throw new IOException("Bridge path escaped its root");
        return result;
    }

    public static boolean writeBridge(String relative, String content) {
        if (!server() || content == null) return false;
        byte[] bytes = content.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > 262144) return false;
        try {
            atomicWrite(bridgePath(Path.of(ZomboidFileSystem.instance.getCacheDir()), relative), bytes);
            return true;
        } catch (IOException error) {
            System.err.println("[GoblinSurvivor] BRIDGE_WRITE_FAILED " + error.getClass().getSimpleName());
            return false;
        }
    }

    static void atomicWrite(Path destination, byte[] bytes) throws IOException {
        Files.createDirectories(destination.getParent());
        Path temporary = Files.createTempFile(destination.getParent(), ".goblin-", ".tmp");
        try {
            try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                ByteBuffer data = ByteBuffer.wrap(bytes);
                while (data.hasRemaining()) channel.write(data);
                channel.force(true);
            }
            // Fail closed on filesystems without atomic replacement. Never publish
            // a ready marker over a partially written JSON or inventory snapshot.
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    private static byte[] hash(byte[] bytes) {
        try { return MessageDigest.getInstance("SHA-256").digest(bytes); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }

    private static void requireGoblin(IsoGameCharacter body, String id) throws IOException {
        if (!server() || body == null || id == null || id.length() > 240
                || !Boolean.TRUE.equals(body.getModData().rawget("GoblinNPC"))
                || !id.equals(body.getModData().rawget("GoblinID")))
            throw new IOException("Not this server-owned Goblin");
    }

    private static Path inventoryPath(String id) {
        return Path.of(ZomboidFileSystem.instance.getCurrentSaveDir()).toAbsolutePath().normalize()
                .resolve("goblin-companions").resolve(HexFormat.of().formatHex(hash(id.getBytes(StandardCharsets.UTF_8))) + ".bin");
    }

    private static byte[] serialize(ItemContainer inventory, IsoGameCharacter body) throws IOException {
        for (int size = 65536; size <= MAX_INVENTORY; size *= 2) {
            ByteBuffer buffer = ByteBuffer.allocate(size);
            try {
                inventory.save(buffer, body);
                return Arrays.copyOf(buffer.array(), buffer.position());
            } catch (BufferOverflowException full) {
                if (size == MAX_INVENTORY) throw new IOException("Inventory exceeds 8 MiB", full);
            }
        }
        throw new IOException("Inventory serialization failed");
    }

    static byte[] envelope(byte[] payload, int worldVersion) {
        return ByteBuffer.allocate(HEADER + payload.length).putInt(MAGIC).putInt(worldVersion)
                .putInt(payload.length).put(hash(payload)).put(payload).array();
    }

    static ByteBuffer payload(byte[] bytes, int currentVersion) throws IOException {
        if (bytes.length < HEADER || bytes.length > MAX_INVENTORY + HEADER) throw new IOException("Invalid inventory length");
        ByteBuffer input = ByteBuffer.wrap(bytes);
        if (input.getInt() != MAGIC) throw new IOException("Invalid inventory header");
        int savedVersion = input.getInt();
        if (savedVersion < 1 || savedVersion > currentVersion) throw new IOException("Unsupported future inventory version");
        int length = input.getInt();
        if (length != input.remaining()-32) throw new IOException("Truncated inventory");
        byte[] digest = new byte[32];
        input.get(digest);
        byte[] body = new byte[length];
        input.get(body);
        if (!MessageDigest.isEqual(digest, hash(body))) throw new IOException("Inventory checksum mismatch");
        return ByteBuffer.wrap(body);
    }

    public static String restoreInventory(IsoGameCharacter body, String id) {
        try {
            requireGoblin(body, id);
            if (id.equals(RESTORED.get(body))) return "ready";
            Path file = inventoryPath(id);
            if (!Files.exists(file)) {
                RESTORED.put(body, id);
                return "new";
            }
            long size = Files.size(file);
            if (size > MAX_INVENTORY+HEADER) throw new IOException("Inventory file exceeds limit");
            byte[] bytes = Files.readAllBytes(file);
            ByteBuffer data = payload(bytes, IsoWorld.getWorldVersion());
            int savedVersion = ByteBuffer.wrap(bytes).getInt(4);
            // Deserialize completely before touching the live character.
            ItemContainer staged = new ItemContainer();
            staged.load(data, savedVersion);
            if (data.hasRemaining()) throw new IOException("Trailing inventory data");
            ArrayList<InventoryItem> items = new ArrayList<>(staged.getItems());
            ItemContainer live = body.getInventory();
            body.setPrimaryHandItem(null);
            body.setSecondaryHandItem(null);
            body.clearWornItems();
            for (InventoryItem old : new ArrayList<>(live.getItems())) live.Remove(old);
            live.setItems(items);
            for (InventoryItem item : items) item.setContainer(live);
            live.setDirty(true);
            RESTORED.put(body, id);
            return "restored:" + items.size();
        } catch (Exception error) {
            System.err.println("[GoblinSurvivor] INVENTORY_RESTORE_FAILED " + error.getMessage());
            return "error:" + error.getClass().getSimpleName();
        }
    }

    public static String saveInventory(IsoGameCharacter body, String id) {
        try {
            requireGoblin(body, id);
            if (!id.equals(RESTORED.get(body))) return "error:not-restored";
            byte[] payload = serialize(body.getInventory(), body);
            byte[] digest = hash(payload);
            if (Arrays.equals(SAVED_HASHES.get(body), digest)) return "unchanged";
            atomicWrite(inventoryPath(id), envelope(payload, IsoWorld.getWorldVersion()));
            SAVED_HASHES.put(body, digest);
            return "saved";
        } catch (Exception error) {
            System.err.println("[GoblinSurvivor] INVENTORY_SAVE_FAILED " + error.getMessage());
            return "error:" + error.getClass().getSimpleName();
        }
    }
}

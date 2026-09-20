package com.horsetheunicorn.goblin.server;

import zombie.ZomboidFileSystem;
import zombie.gameStates.ChooseGameInfo;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;

/** Read-only fingerprints of the common/version roots selected by the loaded game.
 * Does not infer mod directories from Workshop IDs or include inactive versions.
 */
final class RuntimeContentFingerprint {
    static final int MAX_FILES = 100_000;
    static final long MAX_BYTES = 4L * 1024 * 1024 * 1024;
    static final String ALGORITHM = "selected-common-version-roots-v1";
    final String manifestJson;
    final String sha256;

    private RuntimeContentFingerprint(String manifestJson) throws IOException {
        this.manifestJson = manifestJson;
        this.sha256 = hash(manifestJson);
    }

    static RuntimeContentFingerprint collect(List<String> ids) throws IOException {
        if (ids.isEmpty() || ids.size() > 1024 || new HashSet<>(ids).size() != ids.size())
            throw new IOException("Missing, duplicate or excessive loaded mod IDs");
        ZomboidFileSystem fs = ZomboidFileSystem.instance;
        ArrayList<String> entries = new ArrayList<>();
        Budget budget = new Budget();
        for (String id : ids) {
            String directory = fs.getModDir(id);
            if (directory == null) throw new IOException("No loaded mod directory: " + id);
            ChooseGameInfo.Mod mod = fs.getModInfoForDir(directory);
            if (mod == null || !id.equals(mod.getId()))
                throw new IOException("Loaded mod identity mismatch: " + id);
            Path base = Path.of(directory).toAbsolutePath().normalize();
            requireUnredirected(base);
            int previousFiles = budget.files;
            String common = root(base, Path.of(mod.getCommonDir()), true, budget);
            String version = root(base, Path.of(mod.getVersionDir()), true, budget);
            if (budget.files == previousFiles) throw new IOException("No selected content for loaded mod: " + id);
            String roots = "[" + common + "," + version + "]";
            // Canonical JSON key order: mod_id, roots, sha256. Array order is
            // actual loaded mod order, then native common-before-version order.
            entries.add("{\"mod_id\":" + quote(id) + ",\"roots\":" + roots
                    + ",\"sha256\":" + quote(hash(roots)) + "}");
        }
        if (!ids.equals(fs.getModIDs())) throw new IOException("Loaded mod order changed during export");
        return new RuntimeContentFingerprint("[" + String.join(",", entries) + "]");
    }

    static final class Budget { int files; long bytes; }

    static String root(Path base, Path selected, boolean optional, Budget budget) throws IOException {
        base = base.toAbsolutePath().normalize();
        selected = selected.toAbsolutePath().normalize();
        if (!selected.startsWith(base) || selected.equals(base))
            throw new IOException("Selected content root escapes mod directory");
        requireUnredirected(selected);
        String relativeRoot = portable(base.relativize(selected));
        if (!Files.exists(selected, LinkOption.NOFOLLOW_LINKS)) {
            if (!optional) throw new IOException("Missing selected version root");
            return "{\"bytes\":0,\"file_count\":0,\"path\":" + quote(relativeRoot)
                    + ",\"sha256\":null,\"status\":\"ABSENT\"}";
        }
        if (!Files.isDirectory(selected, LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Selected root is not a directory");
        ArrayList<Path> files = new ArrayList<>();
        try (var paths = Files.walk(selected)) {
            var iterator = paths.iterator();
            int entries = 0;
            while (iterator.hasNext()) {
                if (++entries > MAX_FILES * 2) throw new IOException("Content tree exceeds entry bound");
                Path path = iterator.next();
                BasicFileAttributes attributes = Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
                if (attributes.isSymbolicLink() || attributes.isOther())
                    throw new IOException("Redirected or special content entry");
                if (attributes.isRegularFile()) {
                    if (++budget.files > MAX_FILES) throw new IOException("Content file count exceeds bound");
                    files.add(path);
                } else if (!attributes.isDirectory()) throw new IOException("Unsupported content entry");
            }
        }
        Path selectedRoot = selected;
        files.sort(Comparator.comparing(path -> portable(selectedRoot.relativize(path))));
        MessageDigest tree = digest();
        long bytes = 0;
        for (Path file : files) {
            BasicFileAttributes before = Files.readAttributes(file, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
            if (!before.isRegularFile() || before.isSymbolicLink()) throw new IOException("Content entry changed type");
            budget.bytes += before.size();
            if (budget.bytes > MAX_BYTES) throw new IOException("Content bytes exceed bound");
            MessageDigest fileDigest = digest();
            long read = 0;
            try (var stream = Files.newInputStream(file, LinkOption.NOFOLLOW_LINKS)) {
                byte[] buffer = new byte[64 * 1024];
                int count;
                while ((count = stream.read(buffer)) != -1) {
                    read += count;
                    if (read > before.size()) throw new IOException("Content file grew while hashing");
                    fileDigest.update(buffer, 0, count);
                }
            }
            BasicFileAttributes after = Files.readAttributes(file, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
            if (read != before.size() || before.size() != after.size()
                    || !before.lastModifiedTime().equals(after.lastModifiedTime())
                    || !java.util.Objects.equals(before.fileKey(), after.fileKey()))
                throw new IOException("Content changed while hashing");
            String record = "[" + quote(portable(selected.relativize(file))) + "," + read
                    + "," + quote(hex(fileDigest.digest())) + "]\n";
            tree.update(record.getBytes(StandardCharsets.UTF_8));
            bytes += read;
        }
        if (!optional && files.isEmpty()) throw new IOException("Selected version root is empty");
        return "{\"bytes\":" + bytes + ",\"file_count\":" + files.size()
                + ",\"path\":" + quote(relativeRoot) + ",\"sha256\":" + quote(hex(tree.digest()))
                + ",\"status\":\"PRESENT\"}";
    }

    private static void requireUnredirected(Path path) throws IOException {
        for (Path cursor = path.toAbsolutePath().normalize(); cursor != null; cursor = cursor.getParent()) {
            if (!Files.exists(cursor, LinkOption.NOFOLLOW_LINKS)) continue;
            BasicFileAttributes attributes = Files.readAttributes(cursor, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
            if (attributes.isSymbolicLink() || attributes.isOther())
                throw new IOException("Content path contains a redirected/special ancestor");
        }
    }

    private static String portable(Path path) { return path.toString().replace('\\', '/'); }
    private static String quote(String value) { return RuntimeCatalogExporter.quote(value); }
    static String hash(String value) throws IOException {
        return hex(digest().digest(value.getBytes(StandardCharsets.UTF_8)));
    }
    private static MessageDigest digest() throws IOException {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException error) { throw new IOException(error); }
    }
    private static String hex(byte[] bytes) { return java.util.HexFormat.of().formatHex(bytes); }
}

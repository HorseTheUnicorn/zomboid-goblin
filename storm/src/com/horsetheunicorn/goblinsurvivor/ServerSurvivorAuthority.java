package com.horsetheunicorn.goblinsurvivor;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import se.krka.kahlua.vm.KahluaTable;
import zombie.VirtualZombieManager;
import zombie.characters.IsoZombie;
import zombie.characters.SurvivorFactory;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.inventory.RecipeManager;
import zombie.inventory.types.HandWeapon;
import zombie.iso.IsoCell;
import zombie.iso.IsoDirections;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoMovingObject;
import zombie.iso.IsoWorld;
import zombie.iso.objects.IsoThumpable;
import zombie.iso.objects.IsoWorldInventoryObject;
import zombie.network.GameServer;
import zombie.scripting.objects.Recipe;
import java.util.ArrayList;

/**
 * Server-owned lifecycle, movement, and bounded combat for custom human bodies.
 * Lua supplies task intent and receives a snapshot; it never supplies an actor
 * position or a combat result.
 */
public final class ServerSurvivorAuthority {
    private static final int MAX_ACTORS = 32;
    private static final long RESPAWN_DELAY_NANOS = 5_000_000_000L;
    private static final long SPAWN_RETRY_NANOS = 1_000_000_000L;
    private static final long SHOT_INTERVAL_NANOS = 900_000_000L;
    private static final long INCOMING_DAMAGE_INTERVAL_NANOS = 1_000_000_000L;
    private static final double HUNT_RADIUS = 64.0;
    private static final double DEFEND_RADIUS = 18.0;
    private static final double FIREARM_RANGE = 40.0;
    private static final double FIREARM_STOP_DISTANCE = 30.0;
    // Keep the human silhouettes and their combat lanes visibly distinct.
    // This is enforced for every server-authoritative move, including a group
    // response to the same hostile zombie.
    private static final double MIN_BODY_SEPARATION = 4.0;
    private static final double WORK_ARRIVAL_DISTANCE = 1.2;
    private static final int WORK_SCAN_RADIUS = 8;
    private static final long WORK_INTERVAL_NANOS = 3_000_000_000L;
    private static final int BUILDER_SCAN_RADIUS = 4;
    private static final int BUILDER_MAX_STRUCTURES = 16;
    private static final String BUILDER_WALL_SPRITE = "carpentry_02_80";
    private static final String DEBUG_COMBAT_MARKER = "goblin_debug_combat_fixture";
    private static final String DEBUG_COMBAT_ACTOR = "goblin_debug_combat_actor";

    private static final Map<String, Entry> actors = new HashMap<>();

    private static final class Entry {
        HumanSurvivor body;
        long lastStep = System.nanoTime();
        long nextRouteAt;
        long nextShotAt;
        long nextIncomingDamageAt;
        long nextSpawnAt;
        long respawnAt;
        List<GridRoute.Cell> route = List.of();
        long nextRouteDiagnosticAt;
        int waypoint;
        int generation = 1;
        int spawnAttempts;
        int incomingHits;
        long shotsFired;
        long zombiesKilled;
        long separationBlocks;
        long nextWorkAt;
        long workCount;
        String workStatus = "idle";
        String lastWorkItem = "";
        IsoZombie combatTarget;
        String lastKillId;
        String deathReason = "";
        String combatStatus = "idle";
        String lastFireError = "";
        int routeTargetX = Integer.MIN_VALUE;
        int routeTargetY = Integer.MIN_VALUE;
        int routeTargetZ = Integer.MIN_VALUE;
    }

    private ServerSurvivorAuthority() { }

    private static double number(KahluaTable table, String key) {
        Object value = table.rawget(key);
        if (!(value instanceof Number n) || !Double.isFinite(n.doubleValue())) {
            throw new IllegalArgumentException("Invalid server coordinate " + key);
        }
        return n.doubleValue();
    }

    private static String text(KahluaTable table, String key, String fallback) {
        Object value = table.rawget(key);
        return value instanceof String s && !s.isBlank() ? s : fallback;
    }

    private static boolean isGoblinActor(String id) {
        return "goblin.primary".equals(id);
    }

    private static IsoGridSquare findSpawnSquare(IsoCell cell, double x, double y, double z) {
        int originX = (int)Math.floor(x);
        int originY = (int)Math.floor(y);
        int floor = (int)Math.floor(z);
        IsoGridSquare square = cell.getGridSquare(originX, originY, floor);
        if (square != null && square.isFree(false)) return square;
        for (int radius = 1; radius <= 6; radius++) {
            for (int ox = -radius; ox <= radius; ox++) {
                for (int oy = -radius; oy <= radius; oy++) {
                    if (Math.max(Math.abs(ox), Math.abs(oy)) != radius) continue;
                    IsoGridSquare candidate = cell.getGridSquare(originX + ox, originY + oy, floor);
                    if (candidate != null && candidate.isFree(false)) return candidate;
                }
            }
        }
        return null;
    }

    /**
     * Spawn each managed body on a free square that is also outside the
     * formation radius of bodies already created in this cell.  Persisted
     * coordinates from older builds used three-tile spacing, so enforcing the
     * guard only during movement still allowed a cramped initial formation.
     */
    private static IsoGridSquare findSeparatedSpawnSquare(IsoCell cell,
            double x, double y, double z) {
        int originX = (int)Math.floor(x);
        int originY = (int)Math.floor(y);
        int floor = (int)Math.floor(z);
        IsoGridSquare fallback = null;
        for (int radius = 0; radius <= 12; radius++) {
            for (int ox = -radius; ox <= radius; ox++) {
                for (int oy = -radius; oy <= radius; oy++) {
                    if (radius > 0
                            && Math.max(Math.abs(ox), Math.abs(oy)) != radius) continue;
                    IsoGridSquare candidate = cell.getGridSquare(originX + ox,
                            originY + oy, floor);
                    if (candidate == null || !candidate.isFree(false)) continue;
                    if (fallback == null) fallback = candidate;
                    if (!violatesBodySeparation(null, candidate.getX() + 0.5f,
                            candidate.getY() + 0.5f, candidate.getZ())) return candidate;
                }
            }
        }
        return fallback;
    }

    private static HumanSurvivor existingBody(IsoCell cell, String id) {
        for (IsoMovingObject object : cell.getObjectList()) {
            if (!(object instanceof HumanSurvivor body)) continue;
            Object actorId = body.getModData().rawget("goblin_actor_id");
            if (id.equals(actorId) && body.isAlive()
                    && body.getCell() == cell && body.getCurrentSquare() != null) return body;
        }
        return null;
    }

    private static boolean containsObject(IsoCell cell, IsoMovingObject wanted) {
        if (cell == null || wanted == null) return false;
        for (IsoMovingObject object : cell.getObjectList()) {
            if (object == wanted) return true;
        }
        return false;
    }

    private static void resetTransientState(Entry entry) {
        entry.combatTarget = null;
        entry.route = List.of();
        entry.waypoint = 0;
        entry.nextRouteAt = 0L;
        entry.routeTargetX = Integer.MIN_VALUE;
        entry.routeTargetY = Integer.MIN_VALUE;
        entry.routeTargetZ = Integer.MIN_VALUE;
    }

    private static void rebindIfNeeded(IsoCell cell, Entry entry, String id, long now) {
        HumanSurvivor body = entry.body;
        if (body == null || !body.isAlive()) return;
        IsoGridSquare square = body.getCurrentSquare();
        boolean registered = body.getCell() == cell
                && square != null && square.getCell() == cell
                && containsObject(cell, body);
        if (registered) return;
        try { body.unregisterVisualObject(); } catch (Throwable ignored) { }
        entry.body = null;
        entry.nextSpawnAt = now;
        entry.combatStatus = "rebind_pending";
        resetTransientState(entry);
        System.out.println("[GoblinSurvivorStorm] human survivor body detached for world rebind: "
                + id + " generation=" + entry.generation);
    }

    private static HumanSurvivor spawnBody(IsoCell cell, String id,
            double x, double y, double z, int generation) {
        IsoGridSquare square = findSeparatedSpawnSquare(cell, x, y, z);
        if (square == null) return null;
        var descriptor = SurvivorFactory.CreateSurvivor();
        if (descriptor == null) return null;
        double spawnX = square.getX() + 0.5;
        double spawnY = square.getY() + 0.5;
        HumanSurvivor body = new HumanSurvivor(descriptor, cell,
                square.getX(), square.getY(), square.getZ());
        body.setX((float)spawnX);
        body.setY((float)spawnY);
        body.setZ((float)z);
        body.setCurrentSquare(square);
        body.setMovingSquare(square);
        body.registerVisualObject();
        body.ensureGodMode();
        body.ensureFirearm();
        if (isGoblinActor(id)) {
            body.forceGoblinAppearance();
        }
        body.getModData().rawset("goblin_actor_id", id);
        body.getModData().rawset("goblin_human_survivor", true);
        body.getModData().rawset("goblin_body_generation", (double)generation);
        System.out.println("[GoblinSurvivorStorm] authoritative human body created: "
                + id + " generation=" + generation
                + " weapon=" + body.getFirearmType());
        return body;
    }

    private static Entry entryFor(IsoCell cell, KahluaTable state, String id) {
        Entry entry = actors.get(id);
        if (entry != null) {
            rebindIfNeeded(cell, entry, id, System.nanoTime());
            return entry;
        }
        if (actors.size() >= MAX_ACTORS) return null;
        entry = new Entry();
        Object generation = state.rawget("body_generation");
        if (generation instanceof Number n && n.intValue() > 0) entry.generation = n.intValue();
        Object savedWorkCount = state.rawget("work_count");
        if (savedWorkCount instanceof Number n && Double.isFinite(n.doubleValue())) {
            entry.workCount = Math.max(0L, (long)Math.floor(n.doubleValue()));
        }
        Object savedLastWorkItem = state.rawget("last_work_item");
        if (savedLastWorkItem instanceof String s && !s.isBlank()) {
            entry.lastWorkItem = s.length() > 96 ? s.substring(0, 96) : s;
        }
        Object savedWorkStatus = state.rawget("work_status");
        if (savedWorkStatus instanceof String s && !s.isBlank()) {
            entry.workStatus = s.length() > 96 ? s.substring(0, 96) : s;
        }
        entry.body = existingBody(cell, id);
        if (entry.body == null) {
            entry.spawnAttempts++;
            entry.body = spawnBody(cell, id,
                    number(state, "x"), number(state, "y"), number(state, "z"), entry.generation);
            if (entry.body == null) entry.nextSpawnAt = System.nanoTime() + SPAWN_RETRY_NANOS;
        }
        actors.put(id, entry);
        return entry;
    }

    private static void scheduleDeath(Entry entry, long now) {
        if (entry.body == null || entry.body.isAlive()) return;
        if (entry.deathReason.isBlank()) {
            String reason = entry.body.getDeathReason();
            entry.deathReason = reason == null || reason.isBlank() ? "health_zero" : reason;
        }
        if (entry.respawnAt == 0L) {
            entry.body.unregisterVisualObject();
            entry.respawnAt = now + RESPAWN_DELAY_NANOS;
            entry.combatTarget = null;
            entry.route = List.of();
            entry.waypoint = 0;
            entry.combatStatus = "dead_waiting_recreate";
            System.out.println("[GoblinSurvivorStorm] human survivor died: "
                    + entry.deathReason);
        }
    }

    private static boolean ensureBody(IsoCell cell, KahluaTable state,
            String id, Entry entry, long now) {
        rebindIfNeeded(cell, entry, id, now);
        if (entry.body != null && !entry.body.isAlive()) scheduleDeath(entry, now);
        if (entry.respawnAt != 0L) {
            if (now < entry.respawnAt) return false;
            entry.generation++;
            entry.body = null;
            entry.respawnAt = 0L;
            entry.nextSpawnAt = 0L;
            entry.route = List.of();
            entry.waypoint = 0;
            entry.nextRouteAt = 0L;
            entry.routeTargetX = Integer.MIN_VALUE;
            entry.routeTargetY = Integer.MIN_VALUE;
            entry.routeTargetZ = Integer.MIN_VALUE;
            entry.combatTarget = null;
            entry.combatStatus = "recreating";
        }
        if (entry.body != null && entry.body.isAlive()) return true;
        if (now < entry.nextSpawnAt) return false;
        entry.spawnAttempts++;
        entry.body = spawnBody(cell, id,
                number(state, "x"), number(state, "y"), number(state, "z"), entry.generation);
        if (entry.body == null) {
            entry.nextSpawnAt = now + SPAWN_RETRY_NANOS;
            entry.combatStatus = "waiting_spawn_square";
            return false;
        }
        entry.nextSpawnAt = 0L;
        entry.spawnAttempts = 0;
        entry.deathReason = "";
        entry.combatStatus = "recreated";
        return true;
    }

    private static void writeState(Entry entry, KahluaTable state,
            boolean present, String spawnStatus, long now) {
        HumanSurvivor body = entry.body;
        boolean alive = present && body != null && body.isAlive();
        state.rawset("authority", "java_human");
        state.rawset("alive", alive);
        state.rawset("body_present", alive);
        state.rawset("control_ready", alive);
        state.rawset("body_generation", (double)entry.generation);
        state.rawset("spawn_status", spawnStatus);
        state.rawset("spawn_pending", !alive);
        state.rawset("spawn_attempts", (double)entry.spawnAttempts);
        state.rawset("health", body == null ? 0.0 : (double)body.getHealth());
        boolean weaponReady = alive && body != null && body.hasReadyFirearm();
        String firearmType = body == null ? "" : body.getFirearmType();
        state.rawset("weapon_ready", weaponReady);
        state.rawset("firearm_type", firearmType.isBlank() ? null : firearmType);
        state.rawset("weapon_policy", weaponReady ? "unlimited_ammo" : null);
        state.rawset("god_mode", alive && body != null && body.isGodMode());
        state.rawset("friendly", true);
        state.rawset("hostile_to_zombies", true);
        state.rawset("shots_fired", (double)entry.shotsFired);
        state.rawset("zombies_killed", (double)entry.zombiesKilled);
        state.rawset("incoming_hits", (double)entry.incomingHits);
        state.rawset("combat_status", entry.combatStatus);
        state.rawset("combat_target_id", entry.combatTarget != null
                && liveHostile(entry.combatTarget) ? zombieId(entry.combatTarget) : null);
        state.rawset("last_kill_id", entry.lastKillId);
        state.rawset("death_reason", entry.deathReason.isBlank() ? null : entry.deathReason);
        state.rawset("last_fire_error", entry.lastFireError.isBlank() ? null : entry.lastFireError);
        state.rawset("separation_blocks", (double)entry.separationBlocks);
        state.rawset("work_status", entry.workStatus);
        state.rawset("work_count", (double)entry.workCount);
        state.rawset("last_work_item", entry.lastWorkItem.isBlank() ? null : entry.lastWorkItem);
        if (body != null && alive) {
            state.rawset("x", (double)body.getX());
            state.rawset("y", (double)body.getY());
            state.rawset("z", (double)body.getZ());
        }
    }

    private static boolean violatesBodySeparation(Entry moving, float x, float y, float z) {
        for (Entry other : actors.values()) {
            if (other == moving || other.body == null || !other.body.isAlive()) continue;
            if (Math.abs(other.body.getZ() - z) > 0.1) continue;
            double distance = Math.hypot(other.body.getX() - x, other.body.getY() - y);
            if (distance < MIN_BODY_SEPARATION) return true;
        }
        return false;
    }

    private static boolean protectedEquipment(InventoryItem item) {
        if (item == null) return true;
        String type = item.getFullType();
        return "Base.AssaultRifle2".equals(type)
                || "Base.M14Clip".equals(type)
                || "Base.308Bullets".equals(type)
                || item.isEquipped();
    }

    private static boolean canCarry(HumanSurvivor body, InventoryItem item) {
        if (body == null || item == null) return false;
        try {
            return body.getInventory().hasRoomFor(body, item);
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static String lootOne(HumanSurvivor body, IsoCell cell) {
        int originX = (int)Math.floor(body.getX());
        int originY = (int)Math.floor(body.getY());
        int floor = (int)Math.floor(body.getZ());
        for (int dx = -WORK_SCAN_RADIUS; dx <= WORK_SCAN_RADIUS; dx++) {
            for (int dy = -WORK_SCAN_RADIUS; dy <= WORK_SCAN_RADIUS; dy++) {
                IsoGridSquare square = cell.getGridSquare(originX + dx, originY + dy, floor);
                if (square == null) continue;
                ArrayList<IsoWorldInventoryObject> objects =
                        new ArrayList<>(square.getWorldObjects());
                for (IsoWorldInventoryObject object : objects) {
                    InventoryItem item = object.getItem();
                    if (item == null || protectedEquipment(item) || !canCarry(body, item)) continue;
                    String fullType = item.getFullType();
                    try {
                        square.transmitRemoveItemFromSquare(object);
                        object.removeFromWorld();
                        item.setWorldItem(null);
                        InventoryItem added = body.getInventory().AddItem(item);
                        if (added == null) continue;
                        return fullType == null ? item.getType() : fullType;
                    } catch (Throwable ignored) {
                        // A stale world item can disappear during a cell update;
                        // leave it to the normal world-item lifecycle and keep
                        // the bounded worker alive.
                    }
                }
            }
        }
        return null;
    }

    private static String disassembleOne(HumanSurvivor body) {
        ArrayList<InventoryItem> items = new ArrayList<>(body.getInventory().getItems());
        ArrayList<ItemContainer> containers = new ArrayList<>();
        containers.add(body.getInventory());
        for (InventoryItem item : items) {
            if (protectedEquipment(item)) continue;
            String fullType = item.getFullType();
            if (fullType == null || fullType.isBlank()) continue;
            try {
                Recipe recipe = RecipeManager.getDismantleRecipeFor(fullType);
                if (recipe == null
                        || !RecipeManager.IsRecipeValid(recipe, body, item, containers)) continue;
                ArrayList<InventoryItem> results =
                        RecipeManager.PerformMakeItem(recipe, item, body, containers);
                if (results == null || results.isEmpty()) continue;
                InventoryItem first = results.get(0);
                return fullType + " -> "
                        + (first == null ? "crafted output" : first.getFullType());
            } catch (Throwable ignored) {
                // Recipe scripts are mod-extensible. A failing recipe must
                // not tear down the server's survivor authority.
            }
        }
        return null;
    }

    private static boolean isGoblinBuild(IsoObject object) {
        if (object == null || object.getModData() == null) return false;
        return Boolean.TRUE.equals(object.getModData().rawget("goblin_survivor_build"));
    }

    private static boolean hasGoblinBuild(IsoGridSquare square) {
        if (square == null) return false;
        for (IsoObject object : square.getSpecialObjects()) {
            if (isGoblinBuild(object)) return true;
        }
        return false;
    }

    private static IsoGridSquare findBuilderSquare(HumanSurvivor body, IsoCell cell) {
        int originX = (int)Math.floor(body.getX());
        int originY = (int)Math.floor(body.getY());
        int floor = (int)Math.floor(body.getZ());
        for (int radius = 1; radius <= BUILDER_SCAN_RADIUS; radius++) {
            for (int dx = -radius; dx <= radius; dx++) {
                for (int dy = -radius; dy <= radius; dy++) {
                    if (Math.max(Math.abs(dx), Math.abs(dy)) != radius) continue;
                    IsoGridSquare square = cell.getGridSquare(originX + dx,
                            originY + dy, floor);
                    if (square == null || !square.hasFloor()
                            || square.isVehicleIntersecting() || hasGoblinBuild(square)) continue;
                    // A wall occupies an edge of a floor tile.  Only choose a
                    // genuinely empty north edge so the worker never replaces
                    // map geometry or an existing player construction.
                    if (square.getWall(true) == null
                            && square.getThumpableWallOrHoppable(true) == null) return square;
                }
            }
        }
        return null;
    }

    /** Place one synchronized wooden wall at the builder's independent station. */
    private static String buildOne(Entry entry, HumanSurvivor body, IsoCell cell) {
        if (entry.workCount >= BUILDER_MAX_STRUCTURES) return null;
        IsoGridSquare square = findBuilderSquare(body, cell);
        if (square == null) return null;
        try {
            // The square-taking constructor is unsafe on the dedicated
            // server: later property setters may call sync() while the new
            // object is not yet present in square.getObjects(), producing
            // "IsoThumpable not found on square" and an invalid network
            // object index.  Configure the object off-square, attach it,
            // then perform the one synchronized health update.
            IsoThumpable wall = new IsoThumpable(cell);
            wall.setSpriteFromName(BUILDER_WALL_SPRITE);
            wall.setIsDismantable(true);
            wall.setCanBarricade(true);
            wall.setMaxHealth(200);
            wall.setBreakSound("BreakObject");
            wall.setName("GoblinSurvivor wooden wall");
            wall.setSquare(square);
            wall.getModData().rawset("goblin_survivor_build", true);
            wall.getModData().rawset("goblin_builder_actor", body.getModData()
                    .rawget("goblin_actor_id"));
            square.AddSpecialObject(wall);
            wall.setHealth(200);
            square.RecalcAllWithNeighbours(true);
            wall.transmitCompleteItemToClients();
            return "wooden_wall@" + square.getX() + "," + square.getY()
                    + "," + square.getZ();
        } catch (Throwable ignored) {
            // A stale/unloaded square must not tear down the authority loop.
            return null;
        }
    }

    private static void serviceWork(Entry entry, IsoCell cell, KahluaTable state, long now) {
        if (now < entry.nextWorkAt) {
            entry.workStatus = "working";
            return;
        }
        String job = text(state, "job", "SCAVENGE").toUpperCase();
        String result = null;
        if ("LOOT".equals(job) || "SCAVENGE".equals(job) || "HAULER".equals(job)
                || "FARMER".equals(job)) {
            result = lootOne(entry.body, cell);
            entry.workStatus = result == null ? "searching" : "looted";
        } else if ("DISASSEMBLE".equals(job)) {
            result = disassembleOne(entry.body);
            entry.workStatus = result == null ? "no_valid_recipe" : "disassembled";
        } else if ("BUILDER".equals(job)) {
            result = buildOne(entry, entry.body, cell);
            entry.workStatus = result == null
                    ? (entry.workCount >= BUILDER_MAX_STRUCTURES ? "build_limit" : "no_build_site")
                    : "built";
        } else if ("GUARD".equals(job)) {
            entry.workStatus = "guarding";
        } else if ("SCOUT".equals(job)) {
            entry.workStatus = "scouting";
        } else if ("MEDIC".equals(job)) {
            entry.workStatus = "standing_by";
        } else {
            entry.workStatus = "unsupported_job";
        }
        if (result != null) {
            entry.workCount++;
            entry.lastWorkItem = result.length() > 96 ? result.substring(0, 96) : result;
        }
        entry.nextWorkAt = now + WORK_INTERVAL_NANOS;
    }

    private static boolean atWorkStation(HumanSurvivor body, KahluaTable target) {
        if (body == null || target == null) return false;
        try {
            double dx = number(target, "x") - body.getX();
            double dy = number(target, "y") - body.getY();
            double dz = Math.abs(number(target, "z") - body.getZ());
            return dz <= 0.1 && Math.hypot(dx, dy) <= WORK_ARRIVAL_DISTANCE;
        } catch (IllegalArgumentException ignored) {
            return false;
        }
    }

    private static void moveTo(Entry entry, IsoCell cell, KahluaTable state,
            double tx, double ty, double tz, double stopDistance, long now) {
        HumanSurvivor body = entry.body;
        double elapsed = Math.min(0.25, Math.max(0,
                (now - entry.lastStep) / 1e9));
        boolean blocked = false;
        String navigation = "arrived";
        int targetX = (int)Math.floor(tx);
        int targetY = (int)Math.floor(ty);
        int targetZ = (int)Math.floor(tz);
        if (targetZ != (int)Math.floor(body.getZ())) {
            blocked = true;
            navigation = "different_floor";
        } else {
            double dx = tx - body.getX();
            double dy = ty - body.getY();
            double distance = Math.hypot(dx, dy);
            double stop = Math.max(0.0, stopDistance);
            if (distance > stop && distance > 0.0) {
                navigation = "moving";
                if (entry.routeTargetX != targetX || entry.routeTargetY != targetY
                        || entry.routeTargetZ != targetZ) {
                    entry.route = List.of();
                    entry.waypoint = 0;
                    entry.nextRouteAt = 0L;
                    entry.routeTargetX = targetX;
                    entry.routeTargetY = targetY;
                    entry.routeTargetZ = targetZ;
                }
                if (now >= entry.nextRouteAt) {
                    final int floor = (int)Math.floor(body.getZ());
                    GridRoute.Result routeResult = GridRoute.search(
                            new GridRoute.Cell((int)Math.floor(body.getX()),
                                    (int)Math.floor(body.getY())),
                            new GridRoute.Cell(targetX, targetY),
                            Math.max(0.0, stop - 0.75), 2048, (a, b) -> {
                                IsoGridSquare from = cell.getGridSquare(a.x(), a.y(), floor);
                                IsoGridSquare to = cell.getGridSquare(b.x(), b.y(), floor);
                                return from != null && to != null && to.isFree(false)
                                        && !from.testCollideAdjacent(body,
                                                b.x() - a.x(), b.y() - a.y(), 0);
                            });
                    entry.route = routeResult.path();
                    if (entry.route.isEmpty() && now >= entry.nextRouteDiagnosticAt) {
                        System.out.println("[GoblinSurvivorStorm] route actor="
                                + body.getModData().rawget("goblin_actor_id")
                                + " result=" + routeResult.status()
                                + " expanded=" + routeResult.expanded()
                                + " from=" + body.getX() + "," + body.getY()
                                + " target=" + tx + "," + ty + "," + tz
                                + " stop=" + stop);
                        entry.nextRouteDiagnosticAt = now + 10_000_000_000L;
                    }
                    entry.waypoint = 0;
                    entry.nextRouteAt = now + 500_000_000L;
                }
                while (entry.waypoint < entry.route.size()) {
                    GridRoute.Cell waypoint = entry.route.get(entry.waypoint);
                    if (Math.hypot(waypoint.x() + 0.5 - body.getX(),
                            waypoint.y() + 0.5 - body.getY()) > 0.08) break;
                    entry.waypoint++;
                }
                GridRoute.Point nextPoint = GridRoute.nextPoint(entry.route, entry.waypoint,
                        body.getX(), body.getY(), body.getZ(), tx, ty, tz);
                if (nextPoint != null) {
                    dx = nextPoint.x() - body.getX();
                    dy = nextPoint.y() - body.getY();
                    distance = Math.hypot(dx, dy);
                } else {
                    blocked = true;
                    navigation = "no_route";
                    distance = 0.0;
                }
                double stepDistance = Math.min(distance, 1.4 * elapsed);
                float nx = (float)(body.getX()
                        + (distance > 0.0 ? dx / distance * stepDistance : 0.0));
                float ny = (float)(body.getY()
                        + (distance > 0.0 ? dy / distance * stepDistance : 0.0));
                IsoGridSquare from = body.getCurrentSquare();
                IsoGridSquare to = cell.getGridSquare((int)Math.floor(nx),
                        (int)Math.floor(ny), (int)Math.floor(body.getZ()));
                blocked = blocked || from == null || to == null || (from != to
                        && (!to.isFree(false) || from.testCollideAdjacent(body,
                                to.getX() - from.getX(), to.getY() - from.getY(), 0)));
                if (!blocked && violatesBodySeparation(entry, nx, ny, body.getZ())) {
                    blocked = true;
                    navigation = "separation";
                    entry.separationBlocks++;
                }
                if (!blocked) {
                    body.setX(nx);
                    body.setY(ny);
                    body.setCurrentSquare(to);
                    body.setMovingSquare(to);
                } else if (!navigation.equals("no_route") && !navigation.equals("separation")) {
                    navigation = "blocked_edge";
                    entry.nextRouteAt = Math.min(entry.nextRouteAt,
                            now + 100_000_000L);
                }
            }
        }
        state.rawset("movement_blocked", blocked);
        state.rawset("navigation_status", navigation);
        state.rawset("route_remaining", (double)(entry.route.size() - entry.waypoint));
    }

    private static boolean isLegacyDonor(IsoZombie zombie) {
        KahluaTable data = zombie.getModData();
        if (data == null) return false;
        Object engine = data.rawget("goblin_engine");
        Object id = data.rawget("goblin_npc_id");
        Object owned = data.rawget("goblin_owned");
        Object bodyClass = data.rawget("goblin_body_class");
        if ("native".equals(engine) && "goblin.primary".equals(id)
                && Boolean.TRUE.equals(owned) && "IsoZombie".equals(bodyClass)) return true;
        return Boolean.TRUE.equals(data.rawget("GoblinSurvivorNPC"))
                && "goblin.primary".equals(data.rawget("GoblinSurvivorID"))
                && Boolean.TRUE.equals(data.rawget("GoblinSurvivorOwned"));
    }

    private static boolean liveHostile(IsoZombie zombie) {
        return zombie != null && !isLegacyDonor(zombie)
                && !zombie.isDead() && !zombie.isFakeDead()
                && zombie.getHealth() > 0.0f;
    }

    private static String zombieId(IsoZombie zombie) {
        return "zombie:" + zombie.getID();
    }

    private static IsoZombie nearestHostile(IsoCell cell, HumanSurvivor body,
            double radius) {
        IsoZombie result = null;
        double best = radius * radius;
        for (IsoZombie zombie : cell.getZombieList()) {
            if (!liveHostile(zombie)) continue;
            double dx = zombie.getX() - body.getX();
            double dy = zombie.getY() - body.getY();
            double dz = Math.abs(zombie.getZ() - body.getZ());
            double distance = dx * dx + dy * dy;
            if (dz > 0.1 || distance > best) continue;
            best = distance;
            result = zombie;
        }
        return result;
    }

    private static void serviceIncomingDamage(Entry entry, IsoCell cell, long now) {
        HumanSurvivor body = entry.body;
        if (body == null || !body.isAlive()
                || now < entry.nextIncomingDamageAt) return;
        for (IsoZombie zombie : cell.getZombieList()) {
            if (!liveHostile(zombie)) continue;
            IsoMovingObject target = zombie.getTarget();
            double dx = zombie.getX() - body.getX();
            double dy = zombie.getY() - body.getY();
            double distance = Math.hypot(dx, dy);
            boolean targetIsBody = target == body;
            // Do not overwrite a zombie's player target. A custom survivor is
            // recorded as under attack only when the zombie is already
            // attacking it or reaches its occupied tile. God mode still
            // prevents health loss, but it must not hide the hostile-contact
            // telemetry needed by the survivor combat gate.
            if ((targetIsBody || target == null) && distance <= 1.45) {
                entry.incomingHits++;
                entry.nextIncomingDamageAt = now + INCOMING_DAMAGE_INTERVAL_NANOS;
                entry.combatStatus = "under_attack";
                body.receiveZombieDamage(18.0f, "zombie_attack");
                return;
            }
        }
    }

    private static boolean guaranteeZombieDeath(Entry entry, IsoZombie target) {
        HumanSurvivor body = entry.body;
        HandWeapon weapon = body.getFirearm();
        try {
            if (weapon != null) target.Kill(body, weapon, true, null);
        } catch (Throwable error) {
            entry.lastFireError = error.getClass().getSimpleName() + ": " + error.getMessage();
        }
        if (!target.isDead()) {
            try { target.setHealth(0.0f); } catch (Throwable ignored) { }
            try { target.die(); } catch (Throwable error) {
                entry.lastFireError = error.getClass().getSimpleName() + ": " + error.getMessage();
            }
        }
        return target.isDead() || !target.isAlive();
    }

    private static void fireAt(Entry entry, IsoZombie target, long now) {
        HumanSurvivor body = entry.body;
        if (!body.ensureFirearm() || !body.hasReadyFirearm()) {
            entry.combatStatus = "weapon_unavailable";
            entry.lastFireError = "Base.AssaultRifle2 could not be equipped";
            return;
        }
        entry.shotsFired++;
        boolean hit = body.fireAt(target);
        entry.lastFireError = body.getLastFireError();
        boolean killed = target.isDead() || !target.isAlive();
        // Preserve B42's Kill/die path before using a health fallback. The
        // fallback exists for this custom attacker because its bodyDamage is
        // intentionally absent from the unsafe vanilla NPC update loop.
        if (!killed) killed = guaranteeZombieDeath(entry, target);
        if (killed) {
            entry.zombiesKilled++;
            entry.lastKillId = zombieId(target);
            entry.combatStatus = hit ? "firearm_kill" : "firearm_kill_fallback";
            entry.combatTarget = null;
        } else {
            entry.combatStatus = "firearm_attempt_failed";
        }
        entry.nextShotAt = now + SHOT_INTERVAL_NANOS;
        body.ensureFirearm();
    }

    private static boolean hasMovingObject(IsoGridSquare square) {
        if (square == null || square.getMovingObjects() == null) return true;
        return !square.getMovingObjects().isEmpty();
    }

    private static IsoGridSquare debugCombatSquare(IsoCell cell, HumanSurvivor body) {
        if (cell == null || body == null) return null;
        int originX = (int)Math.floor(body.getX());
        int originY = (int)Math.floor(body.getY());
        int floor = (int)Math.floor(body.getZ());
        // Use a deterministic ring inside the normal HUNT radius.  The
        // fixture is an ordinary zombie, never a surrogate survivor body.
        for (int radius = 6; radius <= 12; radius++) {
            for (int dx = -radius; dx <= radius; dx++) {
                for (int dy = -radius; dy <= radius; dy++) {
                    if (Math.max(Math.abs(dx), Math.abs(dy)) != radius) continue;
                    IsoGridSquare square = cell.getGridSquare(originX + dx,
                            originY + dy, floor);
                    if (square == null || !square.isFree(false)
                            || hasMovingObject(square)
                            || violatesBodySeparation(null, square.getX() + 0.5f,
                                    square.getY() + 0.5f, square.getZ())) continue;
                    return square;
                }
            }
        }
        return null;
    }

    private static IsoZombie existingDebugCombatFixture(IsoCell cell, String actorId) {
        if (cell == null || actorId == null) return null;
        for (IsoZombie zombie : cell.getZombieList()) {
            KahluaTable data = zombie.getModData();
            if (data == null || !Boolean.TRUE.equals(data.rawget(DEBUG_COMBAT_MARKER))) continue;
            if (!actorId.equals(data.rawget(DEBUG_COMBAT_ACTOR))) continue;
            if (liveHostile(zombie)) return zombie;
            try { zombie.removeFromWorld(); } catch (Throwable ignored) { }
        }
        return null;
    }

    /**
     * Spawn one ordinary, networked zombie near a human actor for a local
     * combat test.  Lua additionally requires the disposable development
     * flags and an exact test token before this method can be reached.
     */
    public static boolean debugSpawnHostileZombie(String actorId) {
        if (!GameServer.server || actorId == null || actorId.isBlank()
                || actorId.length() > 96) return false;
        Entry entry = actors.get(actorId);
        if (entry == null || entry.body == null || !entry.body.isAlive()) return false;
        IsoCell cell = entry.body.getCell();
        IsoZombie existing = existingDebugCombatFixture(cell, actorId);
        if (existing != null) {
            existing.setTarget(entry.body);
            return true;
        }
        IsoGridSquare square = debugCombatSquare(cell, entry.body);
        VirtualZombieManager manager = VirtualZombieManager.instance;
        if (square == null || manager == null || manager.choices == null) return false;
        IsoZombie zombie = null;
        try {
            manager.choices.clear();
            manager.choices.add(square);
            zombie = manager.createRealZombieAlways(IsoDirections.S, false);
        } catch (Throwable error) {
            entry.lastFireError = error.getClass().getSimpleName() + ": " + error.getMessage();
        } finally {
            try { manager.choices.clear(); } catch (Throwable ignored) { }
        }
        if (zombie == null) return false;
        KahluaTable data = zombie.getModData();
        if (data != null) {
            data.rawset(DEBUG_COMBAT_MARKER, true);
            data.rawset(DEBUG_COMBAT_ACTOR, actorId);
        }
        // Give the vanilla zombie a real hostile target while the custom
        // survivor authority remains responsible for survivor health/combat.
        zombie.setTarget(entry.body);
        entry.combatStatus = "debug_fixture_spawned";
        System.out.println("[GoblinSurvivorStorm] local combat fixture spawned: "
                + actorId + " zombie=" + zombie.getID()
                + " at=" + square.getX() + "," + square.getY() + "," + square.getZ());
        return true;
    }

    /**
     * Local-only test hook. Lua must gate this behind the explicit development
     * flags; the normal authority never calls it and god mode remains intact.
     */
    public static boolean debugMarkDead(String actorId, String reason) {
        if (!GameServer.server || actorId == null || actorId.isBlank()
                || actorId.length() > 96) return false;
        Entry entry = actors.get(actorId);
        if (entry == null || entry.body == null || !entry.body.isAlive()) return false;
        boolean marked = entry.body.markSurvivorDead(
                reason == null || reason.isBlank() ? "local_test" : reason);
        if (marked) {
            entry.combatTarget = null;
            entry.combatStatus = "debug_dead";
        }
        return marked;
    }

    /** Invoked only by the trusted server Lua adapter on the game thread. */
    public static boolean step(KahluaTable state, KahluaTable target, double stopDistance) {
        if (!GameServer.server) throw new IllegalStateException("Server authority called on client");
        Object idValue = state.rawget("actor_id");
        if (!(idValue instanceof String id) || id.isBlank() || id.length() > 96) return false;
        IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.currentCell;
        if (cell == null) return false;
        long now = System.nanoTime();
        Entry entry = entryFor(cell, state, id);
        if (entry == null) return false;
        if (!ensureBody(cell, state, id, entry, now)) {
            writeState(entry, state, false,
                    entry.respawnAt != 0L ? "dead_waiting_recreate" : "waiting_spawn_square", now);
            entry.lastStep = now;
            return true;
        }

        HumanSurvivor body = entry.body;
        body.ensureGodMode();
        body.ensureFirearm();
        serviceIncomingDamage(entry, cell, now);
        if (!body.isAlive()) {
            scheduleDeath(entry, now);
            writeState(entry, state, false, "dead_waiting_recreate", now);
            entry.lastStep = now;
            return true;
        }

        String combatMode = text(state, "combat_mode", "HUNT").toUpperCase();
        double radius = !body.hasReadyFirearm() || "OFF".equals(combatMode) ? 0.0
                : ("DEFEND".equals(combatMode) ? DEFEND_RADIUS : HUNT_RADIUS);
        IsoZombie hostile = radius > 0.0 ? nearestHostile(cell, body, radius) : null;
        if (hostile != null) {
            entry.combatTarget = hostile;
            double distance = Math.hypot(hostile.getX() - body.getX(),
                    hostile.getY() - body.getY());
            if (distance > FIREARM_RANGE) {
                moveTo(entry, cell, state, hostile.getX(), hostile.getY(),
                        hostile.getZ(), FIREARM_STOP_DISTANCE, now);
                entry.combatStatus = "closing_on_zombie";
            } else if (now >= entry.nextShotAt) {
                state.rawset("movement_blocked", false);
                state.rawset("navigation_status", "combat_range");
                state.rawset("route_remaining", 0.0);
                fireAt(entry, hostile, now);
            } else {
                state.rawset("movement_blocked", false);
                state.rawset("navigation_status", "aiming");
                state.rawset("route_remaining", 0.0);
                entry.combatStatus = "aiming";
            }
        } else {
            entry.combatTarget = null;
            entry.combatStatus = "ATTACK".equals(combatMode)
                    ? "no_hostile_in_hunt_radius" : "scanning";
            String controlMode = text(state, "control_mode", "HOLD");
            if (target != null && !"COMBAT".equals(controlMode)) {
                moveTo(entry, cell, state, number(target, "x"), number(target, "y"),
                        number(target, "z"),
                        Double.isFinite(stopDistance) ? Math.max(0.0, stopDistance) : 0.0,
                        now);
            } else {
                state.rawset("movement_blocked", false);
                state.rawset("navigation_status", "holding");
                state.rawset("route_remaining", 0.0);
            }
            if ("JOB".equals(controlMode) && atWorkStation(body, target)) {
                serviceWork(entry, cell, state, now);
            }
        }
        writeState(entry, state, true, "present", now);
        entry.lastStep = now;
        return true;
    }
}

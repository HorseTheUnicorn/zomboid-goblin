package com.horsetheunicorn.goblinsurvivor;

import org.joml.Vector3f;
import zombie.ai.states.ClimbOverFenceState;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableIterator;
import zombie.VirtualZombieManager;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoZombie;
import zombie.characters.SurvivorFactory;
import zombie.core.physics.WorldSimulation;
import zombie.inventory.InventoryItem;
import zombie.inventory.InventoryItemFactory;
import zombie.inventory.ItemContainer;
import zombie.inventory.RecipeManager;
import zombie.inventory.types.HandWeapon;
import zombie.iso.IsoCell;
import zombie.iso.IsoDirections;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoMovingObject;
import zombie.iso.IsoWorld;
import zombie.iso.BentFences;
import zombie.iso.objects.IsoThumpable;
import zombie.iso.objects.IsoWorldInventoryObject;
import zombie.iso.objects.IsoWindow;
import zombie.network.GameServer;
import zombie.network.ServerMap;
import zombie.pathfind.PathFindBehavior2;
import zombie.pathfind.Path;
import zombie.pathfind.PathNode;
import zombie.scripting.objects.Recipe;
import zombie.vehicles.BaseVehicle;
import zombie.vehicles.VehiclePart;
import gnu.trove.list.array.TFloatArrayList;
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
    private static final long FIREARM_POSE_NANOS = 800_000_000L;
    private static final long MELEE_INTERVAL_NANOS = 1_000_000_000L;
    private static final long INCOMING_DAMAGE_INTERVAL_NANOS = 1_000_000_000L;
    // Automatic combat is protective, not free-roaming.  A live ordinary
    // zombie must be close to an online player or an explicitly anchored base
    // before a managed survivor may select it.
    private static final double PLAYER_PROTECTION_RADIUS = 32.0;
    private static final double BASE_PROTECTION_RADIUS = 32.0;
    private static final double GROUP_LEASH_RADIUS = 18.0;
    private static final double EXPEDITION_LEASH_RADIUS = 48.0;
    private static final double GROUP_RETURN_STOP_DISTANCE = 12.0;
    private static final double HUNT_RADIUS = 64.0;
    private static final double MELEE_HUNT_RADIUS = 16.0;
    private static final double DEFEND_RADIUS = 64.0;
    private static final double FIREARM_RANGE = 40.0;
    private static final double FIREARM_STOP_DISTANCE = 30.0;
    private static final double MELEE_RANGE = 2.25;
    private static final double MELEE_STOP_DISTANCE = 1.25;
    // Keep the human silhouettes and their combat lanes visibly distinct.
    // This is enforced for every server-authoritative move, including a group
    // response to the same hostile zombie.
    private static final double MIN_BODY_SEPARATION = 4.0;
    // The initial formation and independent work lanes keep the full visual
    // clearance above.  Once the player moves, however, a follower must be
    // able to pass the edge of that formation or it can deadlock forever at
    // the first four-tile boundary.  Automatic party movement still leaves a
    // meaningful human-sized gap without freezing the group.
    private static final double FOLLOW_BODY_SEPARATION = 2.5;
    private static final double WORK_ARRIVAL_DISTANCE = 1.2;
    private static final double WALK_SPEED_TILES_PER_SECOND = 1.4;
    private static final double RUN_SPEED_TILES_PER_SECOND = 2.8;
    private static final int WORK_SCAN_RADIUS = 12;
    private static final long WORK_INTERVAL_NANOS = 3_000_000_000L;
    private static final int WORK_BATCH_ITEMS = 6;
    private static final int WORK_EMPTY_TRIP_LIMIT = 3;
    private static final int MAX_PENDING_CARGO_ITEMS = 128;
    private static final int MAX_PENDING_CARGO_TYPES = 64;
    private static final int SCOUT_SCAN_RADIUS = 72;
    // A survivor can be assigned to a player whose server cell is not in the
    // current loaded window. Request that cell and advance in bounded legs;
    // never teleport the human body across an unloaded region.
    private static final double PLAYER_SEARCH_LEG_TILES = 48.0;
    // Do not rebuild a moving player's bounded leg for sub-tile motion.  A
    // fresh target every server tick cancels PathFindBehavior2's asynchronous
    // A* before it can advance, which looks like a route request storm and
    // leaves the escort visually stationary.
    private static final double PLAYER_SEARCH_TARGET_REPLAN_TILES = 6.0;
    private static final double PLAYER_SEARCH_LEG_REACHED_TILES = 1.5;
    private static final long RELEVANT_AREA_RETRY_NANOS = 2_000_000_000L;
    private static final double PLAYER_SEARCH_LEASH_RADIUS = 512.0;
    // A search/assist worker must be able to leave the initial formation. A
    // full party-clearance bubble can trap it between two companions even
    // though PZ's polygonal path has a valid next edge. Keep a small physical
    // clearance while the worker is actively crossing to another player;
    // ordinary follow and work movement retain their wider formation gap.
    private static final double PLAYER_SEARCH_BODY_SEPARATION = 0.75;
    private static final int FARM_SCAN_RADIUS = 12;
    private static final float MEDIC_HEAL_AMOUNT = 20.0f;
    private static final double GUARD_POST_RADIUS = 7.0;
    private static final double VEHICLE_SEARCH_RADIUS = 96.0;
    private static final double VEHICLE_LEASH_RADIUS = 160.0;
    // PathFindBehavior2's vehicle-adjacent goal can place the character just
    // outside the old 2.5-tile center-distance threshold because it solves
    // against the vehicle footprint/seat position.  B42 accepts entry from
    // this slightly wider server-side interaction radius.
    private static final double VEHICLE_ENTER_DISTANCE = 4.0;
    private static final double VEHICLE_APPROACH_MAX_DISTANCE = 2.5;
    private static final double VEHICLE_APPROACH_STOP_DISTANCE = 0.5;
    private static final int VEHICLE_APPROACH_RING_RADIUS = 4;
    private static final int VEHICLE_APPROACH_ROUTE_BUDGET = 8192;
    private static final double VEHICLE_RETURN_DISTANCE = 5.0;
    // Vehicle approaches can legitimately cross a larger loaded building or
    // fence complex than the ordinary 2,048-node worker route. Keep this
    // higher bound local to the explicit hauler state machine so normal
    // survivor ticks do not pay the larger search cost.
    private static final int VEHICLE_ROUTE_BUDGET = 8192;
    // The square adapter is deliberately bounded and conservative. When it
    // cannot prove a route through B42's richer polygonal geometry, let the
    // native finder resolve the route asynchronously instead of freezing a
    // companion indefinitely behind a valid obstacle.
    private static final long NATIVE_ROUTE_TIMEOUT_NANOS = 30_000_000_000L;
    private static final long NATIVE_ROUTE_RETRY_NANOS = 2_000_000_000L;
    private static final long OBSTACLE_REPATH_NANOS = 250_000_000L;
    private static final long OBSTACLE_DETOUR_HOLD_NANOS = 8_000_000_000L;
    private static final long BLOCKED_EDGE_MEMORY_NANOS = 2_000_000_000L;
    private static final int LOCAL_ESCAPE_RING_RADIUS = 8;
    private static final int LOCAL_ESCAPE_ROUTE_BUDGET = 1024;
    // Keep the endpoint search bounded, but sample beyond the immediate
    // perimeter.  A work point can land inside a fenced or polygonal pocket;
    // 32 adjacent candidates all being trapped there makes a valid route look
    // unreachable.  Eight compass points at these sparse radii give the
    // polygonal finder an escape endpoint without asking it to scan an
    // unbounded area.
    private static final int NATIVE_TARGET_VALUE_LIMIT = 192;
    private static final long VEHICLE_REPATH_NANOS = 1_500_000_000L;
    private static final long VEHICLE_STUCK_TIMEOUT_NANOS = 15_000_000_000L;
    // Dedicated servers cannot safely advance B42's CarController because
    // that path assumes the client speed-controls UI exists. Vehicle
    // recovery therefore uses server-owned incremental transform movement.
    private static final double HEADLESS_VEHICLE_SPEED_TILES_PER_SECOND = 3.5;
    private static final double HEADLESS_VEHICLE_MAX_DELTA_SECONDS = 0.25;
    private static final long FENCE_TRAVERSAL_TIMEOUT_NANOS = 1_500_000_000L;
    private static final long FENCE_TRAVERSAL_HOLD_NANOS = 350_000_000L;
    private static final String VEHICLE_CLAIM_KEY = "goblin_vehicle_claimed_by";
    private static final String VEHICLE_RECOVERED_KEY = "goblin_vehicle_recovered";
    private static final String VEHICLE_RECOVERED_BY_KEY = "goblin_vehicle_recovered_by";
    private static final String VEHICLE_RECOVERED_X_KEY = "goblin_vehicle_base_x";
    private static final String VEHICLE_RECOVERED_Y_KEY = "goblin_vehicle_base_y";
    private static final String VEHICLE_RECOVERED_Z_KEY = "goblin_vehicle_base_z";
    private static final int BUILDER_SCAN_RADIUS = 4;
    private static final int BUILDER_MAX_STRUCTURES = 16;
    private static final String BUILDER_WALL_SPRITE = "carpentry_02_80";
    private static final String DEBUG_COMBAT_MARKER = "goblin_debug_combat_fixture";
    private static final String DEBUG_COMBAT_ACTOR = "goblin_debug_combat_actor";

    private static final Map<String, Entry> actors = new HashMap<>();
    private static final Map<String, Long> relevantAreaRequests = new HashMap<>();

    private static final class Entry {
        HumanSurvivor body;
        long lastStep = System.nanoTime();
        long nextRouteAt;
        long nextShotAt;
        long firearmPoseUntil;
        long nextMeleeAt;
        long nextIncomingDamageAt;
        long nextSpawnAt;
        long respawnAt;
        long nextCombatDiagnosticAt;
        List<GridRoute.Cell> route = List.of();
        long nextRouteDiagnosticAt;
        int waypoint;
        int generation = 1;
        int spawnAttempts;
        int incomingHits;
        long shotsFired;
        long meleeAttacks;
        long meleeKills;
        long zombiesKilled;
        long separationBlocks;
        long nextWorkAt;
        long workCount;
        int workMisses;
        String workStatus = "idle";
        String lastWorkItem = "";
        IsoZombie combatTarget;
        String lastKillId;
        String deathReason = "";
        String combatStatus = "idle";
        String lastFireError = "";
        String lastMeleeError = "";
        int routeTargetX = Integer.MIN_VALUE;
        int routeTargetY = Integer.MIN_VALUE;
        int routeTargetZ = Integer.MIN_VALUE;
        int blockedEdgeFromX = Integer.MIN_VALUE;
        int blockedEdgeFromY = Integer.MIN_VALUE;
        int blockedEdgeToX = Integer.MIN_VALUE;
        int blockedEdgeToY = Integer.MIN_VALUE;
        long blockedEdgeUntil;
        boolean obstacleDetourActive;
        long obstacleDetourUntil;
        double searchTargetX = Double.NaN;
        double searchTargetY = Double.NaN;
        double searchTargetZ = Double.NaN;
        double searchLegX = Double.NaN;
        double searchLegY = Double.NaN;
        double searchLegZ = Double.NaN;
        boolean nativeMoveActive;
        boolean nativeMoveRequested;
        long nativeMoveStartedAt;
        long nativeMoveLastProgressAt;
        double nativeMoveLastX;
        double nativeMoveLastY;
        boolean traversalActive;
        IsoDirections traversalDirection;
        int traversalStartX = Integer.MIN_VALUE;
        int traversalStartY = Integer.MIN_VALUE;
        int traversalStartZ = Integer.MIN_VALUE;
        int traversalTargetX = Integer.MIN_VALUE;
        int traversalTargetY = Integer.MIN_VALUE;
        int traversalTargetZ = Integer.MIN_VALUE;
        long traversalUntil;
        long traversalStartedAt;
        boolean traversalStarted;
        BaseVehicle recoveryVehicle;
        String recoveryActorId = "";
        int recoveryPhase;
        List<GridRoute.Cell> recoveryRoute = List.of();
        int recoveryWaypoint;
        long recoveryNextRouteAt;
        int recoveryRouteTargetX = Integer.MIN_VALUE;
        int recoveryRouteTargetY = Integer.MIN_VALUE;
        int recoveryRouteTargetZ = Integer.MIN_VALUE;
        int recoveryApproachTargetX = Integer.MIN_VALUE;
        int recoveryApproachTargetY = Integer.MIN_VALUE;
        int recoveryApproachTargetZ = Integer.MIN_VALUE;
        long recoveryStartedAt;
        long recoveryLastProgressAt;
        double recoveryLastX;
        double recoveryLastY;
        double recoveryApproachLastX;
        double recoveryApproachLastY;
        long nextVehicleAttemptAt;
        boolean recoveryUseNativePath;
        boolean recoveryNativePathRequested;
        long recoveryNativePathStartedAt;
        long vehicleRecoveries;
        String vehicleStatus = "idle";
        String vehicleError = "";
    }

    @FunctionalInterface
    private interface WorkItemFilter {
        boolean accepts(InventoryItem item);
    }

    private static final class WorldAnchor {
        final double x;
        final double y;
        final double z;

        WorldAnchor(double x, double y, double z) {
            this.x = x;
            this.y = y;
            this.z = z;
        }
    }

    private enum NativePathState { POINT, WAITING, ARRIVED, FAILED }

    private record NativePathResult(NativePathState state, GridRoute.Point point) { }

    private record TravelTarget(double x, double y, double z) { }

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

    private static boolean validItemType(String value) {
        if (value == null || value.length() < 6 || value.length() > 96
                || !value.startsWith("Base.")) return false;
        for (int index = 5; index < value.length(); index++) {
            char character = value.charAt(index);
            if (!(Character.isLetterOrDigit(character) || character == '_')) return false;
        }
        return true;
    }

    private static KahluaTable pendingCargo(KahluaTable state) {
        if (state == null) return null;
        Object value = state.rawget("offline_cargo");
        return value instanceof KahluaTable table ? table : null;
    }

    private static int pendingCargoCount(KahluaTable state) {
        KahluaTable cargo = pendingCargo(state);
        if (cargo == null) return 0;
        int total = 0;
        KahluaTableIterator iterator = cargo.iterator();
        while (iterator != null && iterator.advance()) {
            Object key = iterator.getKey();
            Object value = iterator.getValue();
            if (!(key instanceof String type) || !validItemType(type)
                    || !(value instanceof Number number)) continue;
            int count = (int)Math.max(0, Math.min(MAX_PENDING_CARGO_ITEMS,
                    Math.floor(number.doubleValue())));
            total = Math.min(MAX_PENDING_CARGO_ITEMS, total + count);
        }
        return total;
    }

    private static int pendingCargoTypes(KahluaTable state) {
        KahluaTable cargo = pendingCargo(state);
        if (cargo == null) return 0;
        int total = 0;
        KahluaTableIterator iterator = cargo.iterator();
        while (iterator != null && iterator.advance()) {
            Object key = iterator.getKey();
            Object value = iterator.getValue();
            if (!(key instanceof String type) || !validItemType(type)
                    || !(value instanceof Number number)
                    || number.doubleValue() <= 0.0) continue;
            total++;
        }
        return Math.min(MAX_PENDING_CARGO_TYPES, total);
    }

    private static boolean addPendingCargo(KahluaTable state, String type, int amount) {
        KahluaTable cargo = pendingCargo(state);
        if (cargo == null || !validItemType(type) || amount <= 0) return false;
        int total = pendingCargoCount(state);
        Object currentValue = cargo.rawget(type);
        int current = currentValue instanceof Number number
                ? (int)Math.max(0, Math.floor(number.doubleValue())) : 0;
        if (total >= MAX_PENDING_CARGO_ITEMS
                || (current == 0 && pendingCargoTypes(state) >= MAX_PENDING_CARGO_TYPES)) {
            return false;
        }
        int room = MAX_PENDING_CARGO_ITEMS - total;
        int updated = current + Math.min(room, amount);
        cargo.rawset(type, (double)updated);
        return updated > current;
    }

    private static int itemQuantity(InventoryItem item) {
        if (item == null) return 0;
        try { return Math.max(1, item.getCount()); }
        catch (Throwable ignored) { return 1; }
    }

    private static Double optionalNumber(KahluaTable table, String key) {
        if (table == null) return null;
        Object value = table.rawget(key);
        if (!(value instanceof Number n) || !Double.isFinite(n.doubleValue())) return null;
        return n.doubleValue();
    }

    private static WorldAnchor stateAnchor(KahluaTable state, String prefix) {
        Double x = optionalNumber(state, prefix + "_x");
        Double y = optionalNumber(state, prefix + "_y");
        Double z = optionalNumber(state, prefix + "_z");
        return x == null || y == null || z == null ? null
                : new WorldAnchor(x, y, z);
    }

    private static WorldAnchor playerAnchor(IsoCell cell) {
        if (cell == null) return null;
        try {
            for (IsoPlayer player : GameServer.getPlayers()) {
                if (player == null || player.getCell() != cell
                        || player.getCurrentSquare() == null) continue;
                return new WorldAnchor(player.getX(), player.getY(), player.getZ());
            }
        } catch (Throwable ignored) {
            // A reconnect can invalidate the player collection during a tick.
        }
        return null;
    }

    /** Resolve the stable Goblin leader instead of relying on collection order. */
    private static WorldAnchor namedPlayerAnchor(KahluaTable state) {
        String wanted = text(state, "leader_username", "");
        if (wanted.isBlank()) return null;
        try {
            for (IsoPlayer player : GameServer.getPlayers()) {
                if (player == null || player.getUsername() == null
                        || !player.getUsername().equalsIgnoreCase(wanted)) continue;
                return new WorldAnchor(player.getX(), player.getY(), player.getZ());
            }
        } catch (Throwable ignored) {
            // A reconnect can invalidate the player collection during a tick.
        }
        return null;
    }

    /**
     * Resolve the authoritative position of a named online player even when
     * that player is outside the worker's current IsoCell window.  A player
     * object can have valid world coordinates before its destination square
     * has streamed into this cell, which is exactly the state the player
     * search/escort route must handle.
     */
    private static WorldAnchor targetPlayerAnchor(KahluaTable state) {
        if (state == null) return null;
        String wanted = text(state, "player_search_target", "");
        if (wanted.isBlank()) wanted = text(state, "target_username", "");
        if (wanted.isBlank()) return null;
        if (wanted.regionMatches(true, 0, "player.", 0, 7)) {
            wanted = wanted.substring(7);
        }
        try {
            for (IsoPlayer player : GameServer.getPlayers()) {
                if (player == null || player.getUsername() == null
                        || !player.getUsername().equalsIgnoreCase(wanted)) continue;
                return new WorldAnchor(player.getX(), player.getY(), player.getZ());
            }
        } catch (Throwable ignored) {
            // A disconnect can invalidate the player collection mid-tick.
        }
        // Lua retains a short-lived server-only point while the multiplayer
        // collection is being rebuilt. It is a routing hint for a join assist
        // only; moveTo() still requires real loaded squares at every step.
        WorldAnchor lastKnown = stateAnchor(state, "player_search_last");
        if (lastKnown != null) return lastKnown;
        return null;
    }

    /**
     * Resolve a square from either the active IsoCell or the dedicated
     * server's loaded-cell map.  IsoCell only covers the current window on a
     * multiplayer server; ServerMap is the authoritative lookup when a
     * second player has caused another world cell to stream in.
     */
    private static IsoGridSquare loadedSquare(IsoCell cell, int x, int y, int z) {
        if (cell != null) {
            try {
                IsoGridSquare square = cell.getGridSquare(x, y, z);
                if (square != null) return square;
            } catch (Throwable ignored) {
                // The cell can be swapped during a reconnect. Fall through
                // to ServerMap rather than failing the survivor tick.
            }
        }
        ServerMap map = ServerMap.instance;
        if (map == null) return null;
        try { return map.getGridSquare(x, y, z); }
        catch (Throwable ignored) { return null; }
    }

    private static String relevantAreaKey(ServerMap map, double x, double y) {
        int cellX = map.worldSquareToServerCellXY((int)Math.floor(x));
        int cellY = map.worldSquareToServerCellXY((int)Math.floor(y));
        return cellX + ":" + cellY;
    }

    /** Keep one server cell relevant without making a request every tick. */
    private static boolean keepAreaRelevant(double x, double y, long now) {
        ServerMap map = ServerMap.instance;
        if (map == null || !Double.isFinite(x) || !Double.isFinite(y)) return false;
        int cellX = map.worldSquareToServerCellXY((int)Math.floor(x));
        int cellY = map.worldSquareToServerCellXY((int)Math.floor(y));
        String key = cellX + ":" + cellY;
        Long previous = relevantAreaRequests.get(key);
        if (previous == null || now - previous >= RELEVANT_AREA_RETRY_NANOS) {
            try {
                // importantAreaIn takes world server-cell coordinates, not
                // square or chunk coordinates.
                map.importantAreaIn(cellX, cellY);
                relevantAreaRequests.put(key, now);
            } catch (Throwable ignored) {
                return false;
            }
        }
        return true;
    }

    /**
     * Ask the dedicated server to stream a target cell. The target is still
     * considered unavailable until a real square is returned, so callers can
     * expose a loading/searching state instead of attempting a blind move.
     */
    private static boolean ensureAreaLoaded(IsoCell cell, KahluaTable state,
            double x, double y, double z, long now) {
        if (loadedSquare(cell, (int)Math.floor(x), (int)Math.floor(y),
                (int)Math.floor(z)) != null) return true;
        ServerMap map = ServerMap.instance;
        if (map == null) return false;
        keepAreaRelevant(x, y, now);
        String key = relevantAreaKey(map, x, y);
        Long previous = relevantAreaRequests.get(key);
        if (previous == null || now - previous >= RELEVANT_AREA_RETRY_NANOS) {
            int cellX = map.worldSquareToServerCellXY((int)Math.floor(x));
            int cellY = map.worldSquareToServerCellXY((int)Math.floor(y));
            try {
                map.importantAreaIn(cellX, cellY);
                relevantAreaRequests.put(key, now);
                System.out.println("[GoblinSurvivorStorm] requested player-search area cell="
                        + cellX + "," + cellY + " target=" + x + "," + y + "," + z);
            } catch (Throwable error) {
                if (state != null) {
                    state.rawset("navigation_status", "target_area_request_failed");
                }
                return false;
            }
        }
        if (state != null) {
            state.rawset("navigation_status", "loading_target_area");
            state.rawset("movement_blocked", false);
            state.rawset("route_remaining", 0.0);
        }
        return false;
    }

    /**
     * Move toward a distant target in a loaded-cell-sized leg.  The logical
     * target remains the player or destination supplied by Lua; this point is
     * only a temporary navigation waypoint while the next region streams in.
     */
    private static void clearSearchLeg(Entry entry) {
        if (entry == null) return;
        entry.searchTargetX = Double.NaN;
        entry.searchTargetY = Double.NaN;
        entry.searchTargetZ = Double.NaN;
        entry.searchLegX = Double.NaN;
        entry.searchLegY = Double.NaN;
        entry.searchLegZ = Double.NaN;
    }

    private static void clearBlockedEdge(Entry entry) {
        if (entry == null) return;
        entry.blockedEdgeFromX = Integer.MIN_VALUE;
        entry.blockedEdgeFromY = Integer.MIN_VALUE;
        entry.blockedEdgeToX = Integer.MIN_VALUE;
        entry.blockedEdgeToY = Integer.MIN_VALUE;
        entry.blockedEdgeUntil = 0L;
    }

    private static void clearObstacleDetour(Entry entry) {
        if (entry == null) return;
        entry.obstacleDetourActive = false;
        entry.obstacleDetourUntil = 0L;
    }

    private static void rememberBlockedEdge(Entry entry, IsoGridSquare from,
            IsoGridSquare to, long now) {
        if (entry == null || from == null || to == null || from == to) return;
        entry.blockedEdgeFromX = from.getX();
        entry.blockedEdgeFromY = from.getY();
        entry.blockedEdgeToX = to.getX();
        entry.blockedEdgeToY = to.getY();
        entry.blockedEdgeUntil = now + BLOCKED_EDGE_MEMORY_NANOS;
    }

    private static boolean isRememberedBlockedEdge(Entry entry,
            GridRoute.Cell from, GridRoute.Cell to, long now) {
        if (entry == null || from == null || to == null) return false;
        if (now >= entry.blockedEdgeUntil) {
            clearBlockedEdge(entry);
            return false;
        }
        return entry.blockedEdgeFromX == from.x()
                && entry.blockedEdgeFromY == from.y()
                && entry.blockedEdgeToX == to.x()
                && entry.blockedEdgeToY == to.y();
    }

    private static TravelTarget travelTarget(Entry entry, IsoCell cell,
            KahluaTable state, double tx, double ty, double tz,
            double stopDistance, long now) {
        HumanSurvivor body = entry == null ? null : entry.body;
        if (body == null) return new TravelTarget(tx, ty, tz);
        keepAreaRelevant(body.getX(), body.getY(), now);
        boolean playerSearch = Boolean.TRUE.equals(
                state.rawget("player_search_enabled"));
        double dx = tx - body.getX();
        double dy = ty - body.getY();
        double distance = Math.hypot(dx, dy);
        if (distance <= PLAYER_SEARCH_LEG_TILES) {
            clearSearchLeg(entry);
            ensureAreaLoaded(cell, state, tx, ty, tz, now);
            return new TravelTarget(tx, ty, tz);
        }
        if (!playerSearch) {
            clearSearchLeg(entry);
            return new TravelTarget(tx, ty, tz);
        }
        double remaining = Math.max(0.0, distance - Math.max(0.0, stopDistance));
        double leg = Math.min(PLAYER_SEARCH_LEG_TILES, remaining);
        if (leg <= 0.0) return new TravelTarget(tx, ty, tz);

        boolean targetChanged = !Double.isFinite(entry.searchTargetX)
                || !Double.isFinite(entry.searchTargetY)
                || !Double.isFinite(entry.searchTargetZ)
                || Math.hypot(tx - entry.searchTargetX, ty - entry.searchTargetY)
                        > PLAYER_SEARCH_TARGET_REPLAN_TILES
                || Math.abs(tz - entry.searchTargetZ) > 0.1;
        boolean legReached = !Double.isFinite(entry.searchLegX)
                || !Double.isFinite(entry.searchLegY)
                || !Double.isFinite(entry.searchLegZ)
                || Math.hypot(body.getX() - entry.searchLegX,
                        body.getY() - entry.searchLegY)
                        <= PLAYER_SEARCH_LEG_REACHED_TILES
                || Math.abs(body.getZ() - entry.searchLegZ) > 0.1;
        if (!targetChanged && !legReached) {
            ensureAreaLoaded(cell, state, entry.searchLegX,
                    entry.searchLegY, entry.searchLegZ, now);
            return new TravelTarget(entry.searchLegX, entry.searchLegY,
                    entry.searchLegZ);
        }
        double legX = body.getX() + dx / distance * leg;
        double legY = body.getY() + dy / distance * leg;
        entry.searchTargetX = tx;
        entry.searchTargetY = ty;
        entry.searchTargetZ = tz;
        entry.searchLegX = legX;
        entry.searchLegY = legY;
        entry.searchLegZ = tz;
        ensureAreaLoaded(cell, state, legX, legY, tz, now);
        return new TravelTarget(legX, legY, tz);
    }

    private static WorldAnchor groupAnchor(IsoCell cell, KahluaTable state) {
        // A join-assist target is authoritative on the dedicated server even
        // when it is in a different loaded cell. Use that target for the
        // automatic leash so a worker does not recall itself to the base
        // while the bounded route is streaming the target region.
        if (Boolean.TRUE.equals(state.rawget("player_search_enabled"))) {
            WorldAnchor target = targetPlayerAnchor(state);
            if (target != null) return target;
        }
        // A worker's persisted base is its expedition group anchor.  Looking
        // only at the online player would recall every worker as soon as the
        // outbound point was more than the ordinary party leash away.
        if ("JOB".equals(text(state, "control_mode", "HOLD").toUpperCase())) {
            WorldAnchor base = stateAnchor(state, "protection_base");
            if (base != null) return base;
        }
        WorldAnchor leader = namedPlayerAnchor(state);
        if (leader != null) return leader;
        WorldAnchor player = playerAnchor(cell);
        if (player != null) return player;
        // Server.tick normally pauses when no player is loaded.  The base
        // fallback still makes a rebind or a direct authority call safe.
        return stateAnchor(state, "protection_base");
    }

    private static boolean within(WorldAnchor anchor, IsoZombie zombie, double radius) {
        if (anchor == null || zombie == null
                || Math.abs(anchor.z - zombie.getZ()) > 0.1) return false;
        double dx = anchor.x - zombie.getX();
        double dy = anchor.y - zombie.getY();
        return dx * dx + dy * dy <= radius * radius;
    }

    private static boolean isProtectedThreat(IsoZombie zombie, KahluaTable state) {
        if (zombie == null) return false;
        try {
            for (IsoPlayer player : GameServer.getPlayers()) {
                if (player == null || player.getCell() != zombie.getCell()
                        || player.getCurrentSquare() == null) continue;
                WorldAnchor playerPoint = new WorldAnchor(
                        player.getX(), player.getY(), player.getZ());
                if (within(playerPoint, zombie, PLAYER_PROTECTION_RADIUS)) return true;
            }
        } catch (Throwable ignored) {
            // A disappearing player cannot create a false positive threat.
        }
        return within(stateAnchor(state, "protection_base"), zombie,
                BASE_PROTECTION_RADIUS);
    }

    private static boolean shouldEnforceGroupLeash(String controlMode) {
        // Explicit MOVE and HOLD commands are allowed to be destinations.  All
        // automatic FOLLOW/JOB/COMBAT behavior remains tied to the player or
        // base group and therefore cannot chase a zombie across the map.
        return !"MOVE".equals(controlMode) && !"HOLD".equals(controlMode);
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

    private static IsoDirections cardinalDirection(int dx, int dy) {
        if (dx > 0 && dy == 0) return IsoDirections.E;
        if (dx < 0 && dy == 0) return IsoDirections.W;
        if (dy > 0 && dx == 0) return IsoDirections.S;
        if (dy < 0 && dx == 0) return IsoDirections.N;
        return null;
    }

    /** A route may cross a real B42 hoppable fence/window edge. */
    private static boolean canHop(IsoGridSquare from, IsoGridSquare to) {
        if (from == null || to == null || from.getZ() != to.getZ()) return false;
        int dx = to.getX() - from.getX();
        int dy = to.getY() - from.getY();
        if (Math.abs(dx) + Math.abs(dy) != 1) return false;
        IsoDirections direction = cardinalDirection(dx, dy);
        if (direction == null) return false;
        try {
            return from.isHoppableTo(to)
                    && from.isPlayerAbleToHopWallTo(direction, to);
        } catch (Throwable ignored) {
            return false;
        }
    }

    /**
     * Apply the same standability check used by the native climb action.  The
     * geometry flag alone is not enough: an edge can be marked hoppable while
     * the destination is a solid/invalid square, in which case starting the
     * state would leave the custom actor stuck on the near side.
     */
    private static boolean canHop(HumanSurvivor body, IsoGridSquare from,
            IsoGridSquare to) {
        if (body == null || !canHop(from, to)) return false;
        int dx = to.getX() - from.getX();
        int dy = to.getY() - from.getY();
        IsoDirections direction = cardinalDirection(dx, dy);
        if (direction == null) return false;
        try {
            return IsoWindow.canClimbThroughHelper(body, from, to,
                    direction == IsoDirections.N || direction == IsoDirections.S)
                    && from.isPlayerAbleToHopWallTo(direction, to);
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean canTraverseStep(HumanSurvivor body,
            IsoGridSquare from, IsoGridSquare to) {
        if (from == null || to == null) return false;
        if (canHop(body, from, to)) return true;
        try {
            return to.isFree(false) && !from.testCollideAdjacent(body,
                    to.getX() - from.getX(), to.getY() - from.getY(), 0);
        } catch (Throwable ignored) {
            return false;
        }
    }

    /**
     * Find a short, collision-checked escape route around a locally blocked
     * edge.  This is intentionally separate from the long destination route:
     * if a door, object, or moving body invalidates the next edge after A* has
     * planned, a nearby standable square lets the next search start from the
     * open side of the obstruction instead of retrying the same edge forever.
     */
    private static GridRoute.Result findLocalEscapeRoute(Entry entry,
            IsoCell cell, HumanSurvivor body, double tx, double ty, int floor,
            long now) {
        if (entry == null || cell == null || body == null) {
            return new GridRoute.Result(List.of(), GridRoute.Status.INVALID, 0);
        }
        IsoGridSquare start = body.getCurrentSquare();
        if (start == null) {
            return new GridRoute.Result(List.of(), GridRoute.Status.INVALID, 0);
        }
        ArrayList<GridRoute.Cell> candidates = new ArrayList<>();
        for (int radius = 1; radius <= LOCAL_ESCAPE_RING_RADIUS; radius++) {
            int[][] offsets = {
                    {-radius, 0}, {radius, 0}, {0, -radius}, {0, radius}
            };
            for (int[] offset : offsets) {
                IsoGridSquare square = loadedSquare(cell,
                        start.getX() + offset[0], start.getY() + offset[1], floor);
                if (square == null || !square.isFree(false)) continue;
                candidates.add(new GridRoute.Cell(square.getX(), square.getY()));
            }
        }
        // Prefer an escape that still makes progress toward the actual target;
        // the route callback remains authoritative for every world edge.
        candidates.sort((left, right) -> Double.compare(
                Math.hypot(left.x() + 0.5 - tx, left.y() + 0.5 - ty),
                Math.hypot(right.x() + 0.5 - tx, right.y() + 0.5 - ty)));
        GridRoute.Result last = new GridRoute.Result(List.of(),
                GridRoute.Status.UNREACHABLE, 0);
        GridRoute.Cell origin = new GridRoute.Cell(start.getX(), start.getY());
        for (GridRoute.Cell candidate : candidates) {
            GridRoute.Result result = GridRoute.search(origin, candidate, 0.0,
                    LOCAL_ESCAPE_ROUTE_BUDGET, (from, to) -> {
                        if (isRememberedBlockedEdge(entry, from, to, now)) return false;
                        return canTraverseStep(body,
                                loadedSquare(cell, from.x(), from.y(), floor),
                                loadedSquare(cell, to.x(), to.y(), floor));
                    });
            last = result;
            if (result.status() == GridRoute.Status.FOUND) return result;
        }
        return last;
    }

    /** Start the real B42 fence traversal state on the custom human body. */
    private static boolean beginFenceTraversal(Entry entry, HumanSurvivor body,
            IsoGridSquare from, IsoGridSquare to, boolean run, long now) {
        if (entry == null || body == null || entry.traversalActive
                || !canHop(body, from, to)) return false;
        IsoDirections direction = cardinalDirection(to.getX() - from.getX(),
                to.getY() - from.getY());
        if (direction == null) return false;
        try {
            // Keep the engine's square references aligned with the edge that
            // the route solver approved. setParams() reads getSquare(), not
            // the authority's separate current-square cache.
            body.setCurrentSquare(from);
            body.setMovingSquare(from);
            body.setMovementMode(true, run);
            body.setDir(direction);
            body.setVariable("VaultOverRun", run);
            body.setVariable("VaultOverSprint", false);
            // Do not call IsoGameCharacter.climbOverFence() here. That
            // convenience method reports EventClimbFence through an
            // ActionContext, which snapshot-driven HumanSurvivor bodies do
            // not own and which can be null on a dedicated server. The
            // standability validation above is the same native validation;
            // apply the normal fence bookkeeping directly, then enter the
            // actual state machine state.
            BentFences.getInstance().checkDamageHoppableFence(body, from, to);
            ClimbOverFenceState fence = ClimbOverFenceState.instance();
            fence.setParams(body, direction);
            body.changeState(fence);
            if (!body.isCurrentState(fence)) {
                throw new IllegalStateException("climb state was not entered");
            }
            entry.traversalActive = true;
            entry.traversalDirection = direction;
            entry.traversalStartX = from.getX();
            entry.traversalStartY = from.getY();
            entry.traversalStartZ = from.getZ();
            entry.traversalTargetX = to.getX();
            entry.traversalTargetY = to.getY();
            entry.traversalTargetZ = to.getZ();
            entry.traversalUntil = now + FENCE_TRAVERSAL_TIMEOUT_NANOS;
            entry.traversalStartedAt = now;
            entry.traversalStarted = false;
            System.out.println("[GoblinSurvivorStorm] fence actor="
                    + body.getModData().rawget("goblin_actor_id")
                    + " begin dir=" + direction
                    + " from=" + from.getX() + "," + from.getY()
                    + " to=" + to.getX() + "," + to.getY());
            return true;
        } catch (Throwable error) {
            entry.vehicleError = "fence=" + error.getClass().getSimpleName()
                    + ":" + String.valueOf(error.getMessage());
            System.out.println("[GoblinSurvivorStorm] fence actor="
                    + body.getModData().rawget("goblin_actor_id")
                    + " begin_failed=" + entry.vehicleError);
            return false;
        }
    }

    private static boolean advanceFenceTraversal(Entry entry, IsoCell cell, long now) {
        if (entry == null || !entry.traversalActive || entry.body == null) return false;
        HumanSurvivor body = entry.body;
        ClimbOverFenceState fence = ClimbOverFenceState.instance();
        boolean reached = false;
        try {
            if (!body.isCurrentState(fence)) {
                throw new IllegalStateException("climb state was not active");
            }
            fence.execute(body);
            IsoGridSquare current = cell.getGridSquare(
                    (int)Math.floor(body.getX()), (int)Math.floor(body.getY()),
                    (int)Math.floor(body.getZ()));
            if (current != null) {
                body.setCurrentSquare(current);
                body.setMovingSquare(current);
            }
            reached = Math.floor(body.getX()) == entry.traversalTargetX
                    && Math.floor(body.getY()) == entry.traversalTargetY
                    && Math.abs(body.getZ() - entry.traversalTargetZ) < 0.1;
            if (!reached) {
                // ClimbOverFenceState's first execute step intentionally
                // stops at the collision boundary for a non-IsoPlayer body.
                // The edge was already approved by canHop() and the native
                // IsoWindow standability check, so finish this one-tile
                // traversal at the center of that approved far square. This
                // is the same position update used for an ordinary route
                // step, scoped to the active validated fence edge; it is not
                // an arbitrary destination or a cross-map teleport.
                IsoGridSquare start = cell.getGridSquare(entry.traversalStartX,
                        entry.traversalStartY, entry.traversalStartZ);
                IsoGridSquare target = cell.getGridSquare(entry.traversalTargetX,
                        entry.traversalTargetY, entry.traversalTargetZ);
                if (target != null && canHop(body, start, target)) {
                    body.setX(entry.traversalTargetX + 0.5f);
                    body.setY(entry.traversalTargetY + 0.5f);
                    body.setZ(entry.traversalTargetZ);
                    body.setCurrentSquare(target);
                    body.setMovingSquare(target);
                    reached = true;
                    System.out.println("[GoblinSurvivorStorm] fence actor="
                            + body.getModData().rawget("goblin_actor_id")
                            + " crossed to=" + target.getX() + "," + target.getY());
                }
            }
            // The real animation graph normally raises VaultOverStarted.
            // This custom body is advanced by the server controller, so raise
            // the equivalent edge only after the initial state execution has
            // carried the body onto the far square.
            if (reached && !entry.traversalStarted) {
                body.setVariable("ClimbFenceStarted", true);
                entry.traversalStarted = true;
            }
            if (!reached && now < entry.traversalUntil) return false;
            if (!reached) {
                // Never turn a failed climb into a teleport. Leave the body
                // where the real state stopped and let the route retry or
                // choose another edge after the state is cleaned up.
                System.out.println("[GoblinSurvivorStorm] fence actor="
                        + body.getModData().rawget("goblin_actor_id")
                        + " failed_to_cross at=" + body.getX() + "," + body.getY()
                        + " target=" + entry.traversalTargetX + ","
                        + entry.traversalTargetY);
            } else if (now < entry.traversalStartedAt + FENCE_TRAVERSAL_HOLD_NANOS) {
                // Keep the active state visible to the client long enough for
                // the hop pose to be rendered even though the native state's
                // first execute step reaches the adjacent square immediately.
                return false;
            }
            body.setVariable("ClimbFenceFinished", reached);
            if (body.isCurrentState(fence)) {
                body.changeState(null);
            } else {
                fence.exit(body);
            }
        } catch (Throwable error) {
            entry.vehicleError = "fence=" + error.getClass().getSimpleName()
                    + ":" + String.valueOf(error.getMessage());
            System.out.println("[GoblinSurvivorStorm] fence actor="
                    + body.getModData().rawget("goblin_actor_id")
                    + " advance_failed=" + entry.vehicleError);
            try {
                if (body.isCurrentState(fence)) body.changeState(null);
                else fence.exit(body);
            } catch (Throwable ignored) { }
        }
        entry.traversalActive = false;
        entry.traversalDirection = null;
        entry.traversalStartX = Integer.MIN_VALUE;
        entry.traversalStartY = Integer.MIN_VALUE;
        entry.traversalStartZ = Integer.MIN_VALUE;
        entry.traversalTargetX = Integer.MIN_VALUE;
        entry.traversalTargetY = Integer.MIN_VALUE;
        entry.traversalTargetZ = Integer.MIN_VALUE;
        entry.traversalUntil = 0L;
        entry.traversalStartedAt = 0L;
        entry.traversalStarted = false;
        body.setIgnoreMovement(false);
        return true;
    }

    private static void stopVehicleControls(BaseVehicle vehicle) {
        if (vehicle == null) return;
        try {
            var controller = vehicle.getController();
            if (controller != null && controller.getClientControls() != null) {
                controller.getClientControls().reset();
            }
        } catch (Throwable ignored) { }
        try {
            // Keep a recovered vehicle out of the client-only CarController
            // loop for the entire server-owned recovery lifecycle.
            vehicle.setPhysicsActive(false);
        } catch (Throwable ignored) { }
    }

    /**
     * Advance a claimed vehicle without invoking CarController.update().
     * B42's dedicated-server vehicle physics path can dereference
     * UIManager.speedControls, so this moves only along the already validated
     * cardinal route and updates the transform used by normal replication.
     */
    private static boolean moveHeadlessVehicle(BaseVehicle vehicle, IsoCell cell,
            IsoGridSquare goal, double targetX, double targetY, double targetZ,
            long now, long previousStepAt) {
        if (vehicle == null || cell == null || goal == null) return false;
        double dx = targetX - vehicle.getX();
        double dy = targetY - vehicle.getY();
        double distance = Math.hypot(dx, dy);
        if (distance <= 0.001) return true;

        double elapsed = previousStepAt > 0L
                ? (now - previousStepAt) / 1_000_000_000.0 : 0.05;
        if (!Double.isFinite(elapsed) || elapsed <= 0.0) elapsed = 0.05;
        elapsed = Math.min(HEADLESS_VEHICLE_MAX_DELTA_SECONDS, elapsed);
        double amount = Math.min(distance,
                HEADLESS_VEHICLE_SPEED_TILES_PER_SECOND * elapsed);
        double nextX = vehicle.getX() + dx / distance * amount;
        double nextY = vehicle.getY() + dy / distance * amount;
        IsoGridSquare current = vehicle.getSquare();
        IsoGridSquare next = cell.getGridSquare((int)Math.floor(nextX),
                (int)Math.floor(nextY), (int)Math.floor(targetZ));
        if (next == null || (next != current && next != goal && !next.isFree(false))) {
            return false;
        }

        vehicle.setPosition((float)nextX, (float)nextY, (float)targetZ);
        vehicle.setCurrentSquare(next);
        vehicle.setMovingSquare(next);
        vehicle.setAngles(0.0f,
                (float)Math.toDegrees(Math.atan2(dx, dy)), 0.0f);
        vehicle.setSpeedKmHour((float)(HEADLESS_VEHICLE_SPEED_TILES_PER_SECOND * 3.6));

        WorldSimulation simulation = WorldSimulation.instance;
        if (simulation != null) {
            vehicle.jniTransform.origin.set(
                    (float)(nextX - simulation.offsetX),
                    (float)targetZ,
                    (float)(nextY - simulation.offsetY));
            vehicle.jniLinearVelocity.set(
                    (float)(dx / distance * HEADLESS_VEHICLE_SPEED_TILES_PER_SECOND),
                    0.0f,
                    (float)(dy / distance * HEADLESS_VEHICLE_SPEED_TILES_PER_SECOND));
            vehicle.setWorldTransform(vehicle.jniTransform);
            // The method is rate-limited internally and is the normal B42
            // vehicle transform packet path. A missing peer is non-fatal.
            try { vehicle.updatePhysicsNetwork(); }
            catch (Throwable ignored) { }
        }
        return true;
    }

    private static KahluaTable vehicleModData(BaseVehicle vehicle) {
        if (vehicle == null) return null;
        try { return vehicle.getModData(); }
        catch (Throwable ignored) { return null; }
    }

    private static void releaseVehicleClaim(BaseVehicle vehicle, String actorId) {
        KahluaTable data = vehicleModData(vehicle);
        if (data == null) return;
        Object owner = data.rawget(VEHICLE_CLAIM_KEY);
        if (owner == null || actorId == null || actorId.isBlank()
                || actorId.equals(owner)) data.rawset(VEHICLE_CLAIM_KEY, null);
    }

    private static void clearVehicleRecovery(Entry entry, boolean releaseClaim) {
        if (entry == null) return;
        BaseVehicle vehicle = entry.recoveryVehicle;
        if (entry.recoveryNativePathRequested && entry.body != null) {
            try {
                PathFindBehavior2 behavior = entry.body.getPathFindBehavior2();
                if (behavior != null) behavior.cancel();
            } catch (Throwable ignored) { }
        }
        if (vehicle != null) {
            stopVehicleControls(vehicle);
            try {
                if (entry.body != null && entry.body.getVehicle() == vehicle) {
                    vehicle.exit(entry.body);
                }
            } catch (Throwable ignored) { }
            if (releaseClaim) releaseVehicleClaim(vehicle, entry.recoveryActorId);
        }
        entry.recoveryVehicle = null;
        entry.recoveryActorId = "";
        entry.recoveryPhase = 0;
        entry.recoveryRoute = List.of();
        entry.recoveryWaypoint = 0;
        entry.recoveryNextRouteAt = 0L;
        entry.recoveryRouteTargetX = Integer.MIN_VALUE;
        entry.recoveryRouteTargetY = Integer.MIN_VALUE;
        entry.recoveryRouteTargetZ = Integer.MIN_VALUE;
        entry.recoveryApproachTargetX = Integer.MIN_VALUE;
        entry.recoveryApproachTargetY = Integer.MIN_VALUE;
        entry.recoveryApproachTargetZ = Integer.MIN_VALUE;
        entry.recoveryStartedAt = 0L;
        entry.recoveryLastProgressAt = 0L;
        entry.recoveryLastX = 0.0;
        entry.recoveryLastY = 0.0;
        entry.recoveryApproachLastX = 0.0;
        entry.recoveryApproachLastY = 0.0;
        entry.recoveryUseNativePath = false;
        entry.recoveryNativePathRequested = false;
        entry.recoveryNativePathStartedAt = 0L;
    }

    private static void clearNativeMovement(Entry entry) {
        if (entry == null) return;
        if (entry.nativeMoveRequested && entry.body != null) {
            try {
                PathFindBehavior2 behavior = entry.body.getPathFindBehavior2();
                if (behavior != null) behavior.cancel();
            } catch (Throwable ignored) { }
        }
        entry.nativeMoveActive = false;
        entry.nativeMoveRequested = false;
        entry.nativeMoveStartedAt = 0L;
        entry.nativeMoveLastProgressAt = 0L;
        entry.nativeMoveLastX = 0.0;
        entry.nativeMoveLastY = 0.0;
    }

    /**
     * Advance B42's asynchronous location finder and expose only its next
     * collision-checked point to the server-owned movement step. A custom
     * HumanSurvivor has no vanilla animation player on a dedicated server, so
     * calling PathFindBehavior2.update() alone does not move it; the caller
     * performs the same bounded transform step used by GridRoute afterward.
     */
    /**
     * Build a small ordered set of standable destination points around the
     * requested location.  A player, survivor, zombie, or furniture object may
     * occupy the exact target square; asking the polygonal finder to end on that
     * occupied center is rejected even when an adjacent route is valid.
     */
    private static TFloatArrayList nativeTargetLocations(IsoCell cell,
            double tx, double ty, double tz, double avoidX, double avoidY) {
        TFloatArrayList locations = new TFloatArrayList();
        if (cell == null) return locations;
        int originX = (int)Math.floor(tx);
        int originY = (int)Math.floor(ty);
        int floor = (int)Math.floor(tz);
        int[] radii = {0, 1, 2, 3, 4, 6, 8, 10, 12};
        for (int radius : radii) {
            // The target itself is useful when it is free.  Outer rings use
            // compass points rather than every perimeter tile so the bounded
            // list reaches beyond a local enclosure.
            int[][] offsets = radius == 0
                    ? new int[][]{{0, 0}}
                    : new int[][]{
                        {-radius, 0}, {radius, 0}, {0, -radius}, {0, radius},
                        {-radius, -radius}, {-radius, radius},
                        {radius, -radius}, {radius, radius}
                    };
            for (int[] offset : offsets) {
                IsoGridSquare square = loadedSquare(cell, originX + offset[0],
                        originY + offset[1], floor);
                // The native polygonal finder treats another moving object
                // as an occupied goal.  Use the moving-object-aware query
                // here so the candidate list contains actual endpoints,
                // not merely tiles that have no solid world geometry.
                if (square == null || !square.isFree(true)) continue;
                if (Double.isFinite(avoidX) && Double.isFinite(avoidY)
                        && Math.hypot(square.getX() + 0.5 - avoidX,
                                square.getY() + 0.5 - avoidY) <= 0.75) continue;
                locations.add(square.getX() + 0.5f);
                locations.add(square.getY() + 0.5f);
                locations.add(square.getZ());
                if (locations.size() >= NATIVE_TARGET_VALUE_LIMIT) return locations;
            }
        }
        return locations;
    }

    /**
     * PathFindBehavior2 keeps its own private path cursor.  The vanilla
     * movement loop advances that cursor after it consumes a waypoint, but a
     * server-owned HumanSurvivor deliberately does not run that loop.  When
     * the public pathNext value therefore points at the square the custom
     * body already occupies, select the next node from the PZ path itself.
     * This preserves PolygonalMap2's directional-wall/fence decisions while
     * avoiding a cancel-and-replan loop at every waypoint.
     */
    private static GridRoute.Point nativePathPointAhead(HumanSurvivor body) {
        if (body == null) return null;
        try {
            Path path = body.getPath2();
            if (path == null || path.isEmpty()) return null;
            int nearestIndex = -1;
            double nearestDistance = Double.POSITIVE_INFINITY;
            for (int index = 0; index < path.size(); index++) {
                PathNode node = path.getNode(index);
                if (node == null || !Float.isFinite(node.x)
                        || !Float.isFinite(node.y)) continue;
                double distance = Math.hypot(node.x - body.getX(),
                        node.y - body.getY());
                if (distance < nearestDistance) {
                    nearestDistance = distance;
                    nearestIndex = index;
                }
            }
            if (nearestIndex < 0) return null;
            for (int index = nearestIndex + 1; index < path.size(); index++) {
                PathNode node = path.getNode(index);
                if (node == null || !Float.isFinite(node.x)
                        || !Float.isFinite(node.y)) continue;
                if (Math.hypot(node.x - body.getX(),
                        node.y - body.getY()) > 0.18) {
                    return new GridRoute.Point(node.x, node.y);
                }
            }
        } catch (Throwable ignored) {
            // The path may be released by B42 while a server-cell request is
            // being replaced. Treat that as a normal replan condition.
        }
        return null;
    }

    private static NativePathResult advanceNativeLocationPath(Entry entry,
            IsoCell cell, double tx, double ty, double tz, double stopDistance, long now) {
        if (entry == null || entry.body == null) {
            return new NativePathResult(NativePathState.FAILED, null);
        }
        try {
            PathFindBehavior2 behavior = entry.body.getPathFindBehavior2();
            if (behavior == null) {
                System.out.println("[GoblinSurvivorStorm] native route unavailable actor="
                        + recoveryActorId(entry) + " reason=no_behavior");
                return new NativePathResult(NativePathState.FAILED, null);
            }
            if (!entry.nativeMoveRequested) {
                behavior.reset();
                TFloatArrayList locations = nativeTargetLocations(cell, tx, ty, tz,
                        entry.body.getX(), entry.body.getY());
                if (locations.isEmpty()) {
                    behavior.pathToLocationF((float)tx, (float)ty, (float)tz);
                } else {
                    behavior.pathToNearest(locations);
                }
                entry.nativeMoveRequested = true;
                entry.nativeMoveActive = true;
                entry.nativeMoveStartedAt = now;
                entry.nativeMoveLastProgressAt = now;
                entry.nativeMoveLastX = entry.body.getX();
                entry.nativeMoveLastY = entry.body.getY();
                System.out.println("[GoblinSurvivorStorm] native route request actor="
                        + recoveryActorId(entry) + " target=" + tx + "," + ty + "," + tz
                        + " candidates=" + (locations.size() / 3));
            }
            PathFindBehavior2.BehaviorResult result = behavior.update();
            if (result == PathFindBehavior2.BehaviorResult.Failed) {
                System.out.println("[GoblinSurvivorStorm] native route rejected actor="
                        + recoveryActorId(entry) + " target=" + tx + "," + ty + "," + tz);
                clearNativeMovement(entry);
                entry.nextRouteAt = now + NATIVE_ROUTE_RETRY_NANOS;
                return new NativePathResult(NativePathState.FAILED, null);
            }

            double moved = Math.hypot(entry.body.getX() - entry.nativeMoveLastX,
                    entry.body.getY() - entry.nativeMoveLastY);
            if (moved > 0.05) {
                entry.nativeMoveLastX = entry.body.getX();
                entry.nativeMoveLastY = entry.body.getY();
                entry.nativeMoveLastProgressAt = now;
            }
            double distance = Math.hypot(tx - entry.body.getX(), ty - entry.body.getY());
            if (!behavior.pathNextIsSet && distance <= Math.max(0.0, stopDistance)) {
                clearNativeMovement(entry);
                return new NativePathResult(NativePathState.ARRIVED, null);
            }
            // PathFindBehavior2 normally advances its internal waypoint from
            // the vanilla animation movement loop.  HumanSurvivor movement is
            // deliberately server-owned, so a completed endpoint can remain
            // exposed as pathNext even though the body is already standing on
            // it. Replan once from the current square, excluding that square,
            // so the next collision-checked step continues toward the goal.
            if (behavior.pathNextIsSet && distance > Math.max(0.0, stopDistance)
                    && Math.hypot(behavior.pathNextX - entry.body.getX(),
                            behavior.pathNextY - entry.body.getY()) <= 0.10) {
                GridRoute.Point nextPathPoint = nativePathPointAhead(entry.body);
                if (nextPathPoint != null
                        && Math.hypot(nextPathPoint.x() - entry.body.getX(),
                                nextPathPoint.y() - entry.body.getY()) > 0.10) {
                    return new NativePathResult(NativePathState.POINT, nextPathPoint);
                }
                clearNativeMovement(entry);
                // The native finder can expose the current square as its next
                // point because the custom body does not run vanilla movement
                // updates. Replan on the next bounded tick; recursive retry
                // here can otherwise overflow the server stack when the finder
                // returns the same endpoint repeatedly.
                entry.nextRouteAt = now + NATIVE_ROUTE_RETRY_NANOS;
                return new NativePathResult(NativePathState.FAILED, null);
            }
            if (now - entry.nativeMoveLastProgressAt > NATIVE_ROUTE_TIMEOUT_NANOS) {
                clearNativeMovement(entry);
                entry.nextRouteAt = now + NATIVE_ROUTE_RETRY_NANOS;
                return new NativePathResult(NativePathState.FAILED, null);
            }
            // A custom HumanSurvivor does not execute the vanilla movement
            // loop that normally copies the next PathNode into
            // pathNextX/pathNextY. B42 can therefore have a valid path and a
            // useful node while pathNextIsSet is still false. Expose that
            // node to the same single-edge collision check below instead of
            // reporting WAITING and leaving the actor at the obstacle.
            if (!behavior.pathNextIsSet) {
                GridRoute.Point nextPathPoint = nativePathPointAhead(entry.body);
                if (nextPathPoint != null
                        && Math.hypot(nextPathPoint.x() - entry.body.getX(),
                                nextPathPoint.y() - entry.body.getY()) > 0.10) {
                    return new NativePathResult(NativePathState.POINT,
                            nextPathPoint);
                }
            }
            if (now >= entry.nextRouteDiagnosticAt) {
                System.out.println("[GoblinSurvivorStorm] native route actor="
                        + recoveryActorId(entry) + " result=" + result
                        + " pathNext=" + behavior.pathNextIsSet
                        + " next=" + behavior.pathNextX + "," + behavior.pathNextY
                        + " length=" + behavior.getPathLength()
                        + " target=" + tx + "," + ty + "," + tz);
                entry.nextRouteDiagnosticAt = now + 10_000_000_000L;
            }
            if (behavior.pathNextIsSet) {
                return new NativePathResult(NativePathState.POINT,
                        new GridRoute.Point(behavior.pathNextX, behavior.pathNextY));
            }
            if (result == PathFindBehavior2.BehaviorResult.Succeeded) {
                clearNativeMovement(entry);
                if (distance <= Math.max(0.0, stopDistance)) {
                    return new NativePathResult(NativePathState.ARRIVED, null);
                }
                // A native request can complete after reaching an alternate
                // endpoint from the candidate list while the logical target
                // is still far away. That is a completed native leg, not an
                // arrival at the destination. Let the bounded recovery path
                // select a different local edge instead of parking here and
                // submitting the same native request forever.
                entry.nextRouteAt = now + NATIVE_ROUTE_RETRY_NANOS;
                return new NativePathResult(NativePathState.FAILED, null);
            }
            return new NativePathResult(NativePathState.WAITING, null);
        } catch (Throwable error) {
            clearNativeMovement(entry);
            entry.nextRouteAt = now + NATIVE_ROUTE_RETRY_NANOS;
            // Keep failure logging independent of the failing route call-site.
            // A logger failure can otherwise mask the original B42 pathfinder
            // exception and flood the server log.
            StringBuilder failure = new StringBuilder(160);
            failure.append("[GoblinSurvivorStorm] native route failed actor=")
                    .append(recoveryActorId(entry))
                    .append(" error=")
                    .append(error == null ? "unknown" : error.getClass().getName());
            if (error != null && error.getMessage() != null) {
                failure.append(':').append(error.getMessage());
            }
            System.out.println(failure.toString());
            return new NativePathResult(NativePathState.FAILED, null);
        }
    }

    private static void resetTransientState(Entry entry) {
        clearVehicleRecovery(entry, true);
        clearNativeMovement(entry);
        clearSearchLeg(entry);
        clearBlockedEdge(entry);
        clearObstacleDetour(entry);
        entry.combatTarget = null;
        entry.firearmPoseUntil = 0L;
        entry.route = List.of();
        entry.waypoint = 0;
        entry.nextRouteAt = 0L;
        entry.routeTargetX = Integer.MIN_VALUE;
        entry.routeTargetY = Integer.MIN_VALUE;
        entry.routeTargetZ = Integer.MIN_VALUE;
        entry.vehicleStatus = "idle";
        entry.vehicleError = "";
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

    /**
     * Reconnects can leave the persisted actor coordinates in an unloaded
     * cell.  Try the durable coordinate first, then re-anchor the body to a
     * currently loaded player square so a world rebind can recover without
     * changing the survivor's logical task or base.
     */
    private static HumanSurvivor spawnBodyAtSavedOrPlayerAnchor(
            IsoCell cell, KahluaTable state, String id, int generation) {
        HumanSurvivor body = spawnBody(cell, id,
                number(state, "x"), number(state, "y"), number(state, "z"), generation);
        if (body != null) return body;
        WorldAnchor anchor = playerAnchor(cell);
        if (anchor == null) return null;
        body = spawnBody(cell, id, anchor.x, anchor.y, anchor.z, generation);
        if (body != null) {
            System.out.println("[GoblinSurvivorStorm] human survivor reanchored to live player cell: "
                    + id + " generation=" + generation);
        }
        return body;
    }

    private static Entry entryFor(IsoCell cell, KahluaTable state, String id) {
        Entry entry = actors.get(id);
        if (entry != null) {
            rebindIfNeeded(cell, entry, id, System.nanoTime());
            Object currentWorkCount = state.rawget("work_count");
            if (currentWorkCount instanceof Number number
                    && Double.isFinite(number.doubleValue())) {
                entry.workCount = Math.max(entry.workCount,
                        (long)Math.floor(number.doubleValue()));
            }
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
            entry.body = spawnBodyAtSavedOrPlayerAnchor(cell, state, id, entry.generation);
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
            clearVehicleRecovery(entry, true);
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
        entry.body = spawnBodyAtSavedOrPlayerAnchor(cell, state, id, entry.generation);
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
        int physicalCargo = alive ? bodyCargoCount(body) : 0;
        int pendingCargo = pendingCargoCount(state);
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
        boolean meleeReady = alive && body != null && body.hasReadyMeleeWeapon();
        state.rawset("melee_weapon_type", body == null || body.getMeleeWeapon() == null
                ? null : body.getMeleeWeapon().getFullType());
        state.rawset("melee_weapon_ready", meleeReady);
        state.rawset("melee_attacks", (double)entry.meleeAttacks);
        state.rawset("melee_kills", (double)entry.meleeKills);
        state.rawset("last_melee_error", entry.lastMeleeError.isBlank()
                ? null : entry.lastMeleeError);
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
        state.rawset("protection_player_radius", PLAYER_PROTECTION_RADIUS);
        state.rawset("protection_base_radius", BASE_PROTECTION_RADIUS);
        double leash = GROUP_LEASH_RADIUS;
        if (Boolean.TRUE.equals(state.rawget("player_search_enabled"))) {
            leash = PLAYER_SEARCH_LEASH_RADIUS;
        } else if ("JOB".equals(text(state, "control_mode", "HOLD").toUpperCase())
                && "OUTBOUND".equals(text(state, "expedition_phase", "OUTBOUND").toUpperCase())) {
            leash = EXPEDITION_LEASH_RADIUS;
        }
        if (entry.recoveryVehicle != null) leash = VEHICLE_LEASH_RADIUS;
        state.rawset("group_leash_radius", leash);
        // Lua owns the semantic assignment state for non-JOB orders (for
        // example an automatic join assist or an explicit FOLLOW).  Keep
        // those labels visible to Telemetry/Qwen; Java's physical work status
        // is authoritative only while the actor is actually running a JOB.
        String controlMode = text(state, "control_mode", "HOLD").toUpperCase();
        Object semanticWorkStatus = state.rawget("work_status");
        if ("JOB".equals(controlMode)
                || !(semanticWorkStatus instanceof String status)
                || status.isBlank()) {
            state.rawset("work_status", entry.workStatus);
        }
        state.rawset("work_count", (double)entry.workCount);
        state.rawset("last_work_item", entry.lastWorkItem.isBlank() ? null : entry.lastWorkItem);
        state.rawset("cargo_count", (double)Math.min(MAX_PENDING_CARGO_ITEMS,
                physicalCargo + pendingCargo));
        state.rawset("cargo_types", (double)Math.max(bodyCargoTypes(body),
                pendingCargoTypes(state)));
        state.rawset("vehicle_recovery_enabled", vehicleRecoveryEnabled(state));
        state.rawset("vehicle_status", entry.vehicleStatus);
        state.rawset("vehicle_error", entry.vehicleError.isBlank()
                ? null : entry.vehicleError);
        state.rawset("vehicle_recoveries", (double)entry.vehicleRecoveries);
        if (entry.recoveryVehicle != null) {
            state.rawset("vehicle_id", (double)entry.recoveryVehicle.getId());
            state.rawset("vehicle_engine_running", entry.recoveryVehicle.isEngineRunning());
            state.rawset("vehicle_target_x", (double)entry.recoveryVehicle.getX());
            state.rawset("vehicle_target_y", (double)entry.recoveryVehicle.getY());
            state.rawset("vehicle_target_z", (double)entry.recoveryVehicle.getZ());
        } else {
            state.rawset("vehicle_id", null);
            state.rawset("vehicle_engine_running", false);
            state.rawset("vehicle_target_x", null);
            state.rawset("vehicle_target_y", null);
            state.rawset("vehicle_target_z", null);
        }
        if (body != null && alive) {
            state.rawset("x", (double)body.getX());
            state.rawset("y", (double)body.getY());
            state.rawset("z", (double)body.getZ());
        }
    }

    private static boolean violatesBodySeparation(Entry moving, float x, float y, float z) {
        return violatesBodySeparation(moving, x, y, z, MIN_BODY_SEPARATION);
    }

    private static boolean violatesBodySeparation(Entry moving, float x, float y,
            float z, double minimumDistance) {
        for (Entry other : actors.values()) {
            if (other == moving || other.body == null || !other.body.isAlive()) continue;
            if (Math.abs(other.body.getZ() - z) > 0.1) continue;
            double distance = Math.hypot(other.body.getX() - x, other.body.getY() - y);
            if (distance < minimumDistance) return true;
        }
        return false;
    }

    private static boolean protectedEquipment(InventoryItem item) {
        return item == null || item.isEquipped();
    }

    private static boolean protectedLoadout(InventoryItem item) {
        if (item == null) return true;
        String type = item.getFullType();
        return "Base.AssaultRifle2".equals(type)
                || "Base.M14Clip".equals(type)
                || "Base.308Bullets".equals(type);
    }

    private static boolean protectedEquipment(HumanSurvivor body, InventoryItem item) {
        if (protectedEquipment(item) || protectedLoadout(item)) return true;
        try {
            return item == body.getPrimaryHandItem()
                    || item == body.getSecondaryHandItem();
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean canCarry(HumanSurvivor body, InventoryItem item) {
        if (body == null || item == null) return false;
        try {
            return body.getInventory().hasRoomFor(body, item);
        } catch (Throwable ignored) {
            return false;
        }
    }

    /**
     * Remove loot from the synthetic human inventory without invoking the
     * client-container callback path.  HumanSurvivor inventories are
     * server-owned and have no world square; ItemContainer.Remove(item) can
     * therefore make Food.updateAge() try to send an ItemStats packet for a
     * null square.  DoRemoveItem keeps the authoritative list and item
     * container pointer correct while avoiding that client-only notification.
     */
    private static boolean removeBodyInventoryItem(HumanSurvivor body,
            InventoryItem item) {
        if (body == null || item == null) return false;
        try {
            ItemContainer inventory = body.getInventory();
            if (inventory == null || !inventory.contains(item)) return false;
            inventory.DoRemoveItem(item);
            return !inventory.contains(item);
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean containsWorkToken(String value, String... tokens) {
        if (value == null) return false;
        String normalized = value.toLowerCase();
        for (String token : tokens) {
            if (normalized.contains(token)) return true;
        }
        return false;
    }

    /** Keep specialist inventories useful without taking their weapons. */
    private static boolean acceptsSpecialistSupply(String job, InventoryItem item) {
        if (item == null || item.getFullType() == null) return false;
        if ("MEDIC".equals(job)) {
            return containsWorkToken(item.getFullType(),
                    "bandage", "disinfect", "alcohol", "antibiotic",
                    "painkiller", "vitamin", "pill", "suture", "splint",
                    "medical", "firstaid");
        }
        if ("FARMER".equals(job)) {
            return containsWorkToken(item.getFullType(),
                    "seed", "fertilizer", "compost", "water", "carrot",
                    "cabbage", "potato", "tomato", "corn", "broccoli",
                    "radish", "strawberry", "handshovel", "trowel", "shovel");
        }
        return true;
    }

    /** Transfer one real item from a map/vehicle container into the worker. */
    private static String takeOneFromContainer(HumanSurvivor body,
            ItemContainer container) {
        return takeOneFromContainer(body, container, null);
    }

    /** Transfer one real item that matches an optional specialist filter. */
    private static String takeOneFromContainer(HumanSurvivor body,
            ItemContainer container, WorkItemFilter filter) {
        if (body == null || container == null || container == body.getInventory()
                || container.getItems() == null) return null;
        ArrayList<InventoryItem> items = new ArrayList<>(container.getItems());
        for (InventoryItem item : items) {
            if (item == null || protectedEquipment(item) || !canCarry(body, item)
                    || (filter != null && !filter.accepts(item))) continue;
            String fullType = item.getFullType();
            boolean removed = false;
            try {
                if (!container.isRemoveItemAllowed(item)) continue;
                container.Remove(item);
                removed = true;
                InventoryItem added = body.getInventory().AddItem(item);
                if (added == null) {
                    container.AddItem(item);
                    continue;
                }
                GameServer.sendRemoveItemFromContainer(container, item);
                return fullType == null ? item.getType() : fullType;
            } catch (Throwable ignored) {
                if (removed && !container.contains(item)) {
                    try { container.AddItem(item); } catch (Throwable ignoredAgain) { }
                }
            }
        }
        return null;
    }

    private static boolean vehicleHasOtherOccupant(BaseVehicle vehicle,
            HumanSurvivor body) {
        if (vehicle == null) return true;
        try {
            int seats = Math.max(1, vehicle.getMaxPassengers());
            for (int seat = 0; seat < seats; seat++) {
                IsoGameCharacter occupant = vehicle.getCharacter(seat);
                if (occupant != null && occupant != body) return true;
            }
        } catch (Throwable ignored) {
            return true;
        }
        return false;
    }

    private static String lootVehicleContainers(HumanSurvivor body,
            IsoGridSquare square) {
        return lootVehicleContainers(body, square, null);
    }

    private static String lootVehicleContainers(HumanSurvivor body,
            IsoGridSquare square, WorkItemFilter filter) {
        if (body == null || square == null) return null;
        BaseVehicle vehicle;
        try { vehicle = square.getVehicleContainer(); }
        catch (Throwable ignored) { return null; }
        if (vehicle == null || vehicle.getSquare() != square
                || vehicleHasOtherOccupant(vehicle, body)) return null;
        try {
            var parts = vehicle.getParts();
            for (int index = 0; parts != null && index < parts.getPartCount(); index++) {
                VehiclePart part = parts.getPartByIndex(index);
                if (part == null || !part.isContainer()) continue;
                String result = takeOneFromContainer(body, part.getItemContainer(), filter);
                if (result != null) return result;
            }
        } catch (Throwable ignored) {
            // Vehicle parts are mod-extensible. A malformed part should not
            // abort the rest of the expedition scan.
        }
        return null;
    }

    private static String lootOne(HumanSurvivor body, IsoCell cell) {
        return lootOne(body, cell, null);
    }

    /** Pick up one real world item, optionally restricted to a job's supply. */
    private static String lootOne(HumanSurvivor body, IsoCell cell,
            WorkItemFilter filter) {
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
                    if (item == null || protectedEquipment(item) || !canCarry(body, item)
                            || (filter != null && !filter.accepts(item))) continue;
                    String fullType = item.getFullType();
                    try {
                        square.transmitRemoveItemFromSquare(object);
                        object.removeFromWorld();
                        item.setWorldItem(null);
                        InventoryItem added = body.getInventory().AddItem(item);
                        if (added == null) {
                            // AddItem can reject a stale item during a cell
                            // update. Put it back into the world so a failed
                            // pickup never silently destroys player loot.
                            square.AddWorldInventoryItem(item, 0.5f, 0.5f, 0.0f);
                            continue;
                        }
                        return fullType == null ? item.getType() : fullType;
                    } catch (Throwable ignored) {
                        // A stale world item can disappear during a cell update;
                        // leave it to the normal world-item lifecycle and keep
                        // the bounded worker alive.
                }
            }
        }
        }
        // World objects are the first pickup source because they are already
        // represented as loose items.  The same bounded scan then visits
        // ordinary map containers, which is what turns an expedition into
        // useful scavenging instead of only collecting items dropped on the
        // ground.
        for (int dx = -WORK_SCAN_RADIUS; dx <= WORK_SCAN_RADIUS; dx++) {
            for (int dy = -WORK_SCAN_RADIUS; dy <= WORK_SCAN_RADIUS; dy++) {
                IsoGridSquare square = cell.getGridSquare(originX + dx, originY + dy, floor);
                if (square == null) continue;
                // B42 exposes the square's static objects as PZArrayList. Its
                // iterator is intentionally unsupported, so use the indexed
                // accessors instead of enhanced-for here. This scan runs on
                // every expedition work tick and an iterator exception would
                // abort the entire survivor authority tick.
                List<IsoObject> squareObjects = square.getObjects();
                for (int objectIndex = 0; objectIndex < squareObjects.size(); objectIndex++) {
                    IsoObject object = squareObjects.get(objectIndex);
                    if (object == null || object.getContainerCount() <= 0) continue;
                    for (int index = 0; index < object.getContainerCount(); index++) {
                        ItemContainer container = object.getContainerByIndex(index);
                        if (container == null || container == body.getInventory()
                                || container.getItems() == null) continue;
                        String result = takeOneFromContainer(body, container, filter);
                        if (result != null) return result;
                    }
                }
            }
        }
        // Cars are part of the same local search surface as map containers.
        // Treat their trunk/glove-box containers as loot sources, but never
        // take from a vehicle occupied by a player or another survivor.
        for (int dx = -WORK_SCAN_RADIUS; dx <= WORK_SCAN_RADIUS; dx++) {
            for (int dy = -WORK_SCAN_RADIUS; dy <= WORK_SCAN_RADIUS; dy++) {
                IsoGridSquare square = cell.getGridSquare(originX + dx, originY + dy, floor);
                String result = lootVehicleContainers(body, square, filter);
                if (result != null) return result;
            }
        }
        return null;
    }

    private static String specialistLootOne(HumanSurvivor body, IsoCell cell,
            String job) {
        if ("MEDIC".equals(job) || "FARMER".equals(job)) {
            return lootOne(body, cell,
                    item -> acceptsSpecialistSupply(job, item));
        }
        return lootOne(body, cell);
    }

    private static int countFarmingPlots(HumanSurvivor body, IsoCell cell) {
        if (body == null || cell == null) return 0;
        int originX = (int)Math.floor(body.getX());
        int originY = (int)Math.floor(body.getY());
        int floor = (int)Math.floor(body.getZ());
        int plots = 0;
        for (int dx = -FARM_SCAN_RADIUS; dx <= FARM_SCAN_RADIUS; dx++) {
            for (int dy = -FARM_SCAN_RADIUS; dy <= FARM_SCAN_RADIUS; dy++) {
                IsoGridSquare square = cell.getGridSquare(originX + dx,
                        originY + dy, floor);
                if (square != null && square.hasFarmingPlant()) plots++;
            }
        }
        return plots;
    }

    private static int countScoutThreats(HumanSurvivor body, IsoCell cell) {
        if (body == null || cell == null) return 0;
        int originZ = (int)Math.floor(body.getZ());
        Set<Integer> seen = new HashSet<>();
        int threats = 0;
        for (IsoZombie zombie : cell.getZombieList()) {
            if (!liveHostile(zombie) || !seen.add(zombie.getID())) continue;
            if ((int)Math.floor(zombie.getZ()) != originZ) continue;
            if (Math.hypot(zombie.getX() - body.getX(), zombie.getY() - body.getY())
                    <= SCOUT_SCAN_RADIUS) threats++;
        }
        for (IsoMovingObject object : new ArrayList<>(cell.getObjectList())) {
            if (!(object instanceof IsoZombie zombie) || !liveHostile(zombie)
                    || !seen.add(zombie.getID())) continue;
            if ((int)Math.floor(zombie.getZ()) != originZ) continue;
            if (Math.hypot(zombie.getX() - body.getX(), zombie.getY() - body.getY())
                    <= SCOUT_SCAN_RADIUS) threats++;
        }
        return threats;
    }

    private static void advanceSpecialistRoute(KahluaTable state) {
        Object rawRound = state.rawget("expedition_round");
        int round = rawRound instanceof Number number
                ? (int)Math.max(0, Math.min(Integer.MAX_VALUE,
                        Math.floor(number.doubleValue()))) : 0;
        state.rawset("expedition_round", (double)Math.min(Integer.MAX_VALUE, round + 1));
        state.rawset("expedition_phase", "OUTBOUND");
        state.rawset("expedition_target", null);
    }

    private static void advanceEmptyExpedition(Entry entry, KahluaTable state,
            String status) {
        advanceSpecialistRoute(state);
        entry.workMisses = 0;
        entry.workStatus = status;
        state.rawset("work_status", status);
    }

    private static String scoutOne(Entry entry, IsoCell cell, KahluaTable state) {
        int threats = countScoutThreats(entry.body, cell);
        state.rawset("scout_threat_count", (double)threats);
        state.rawset("scout_last_report", "threats=" + threats);
        entry.workStatus = threats > 0 ? "scout_threats_found" : "scout_area_clear";
        advanceSpecialistRoute(state);
        return "scout_report:" + threats;
    }

    private static String farmerOne(Entry entry, IsoCell cell, KahluaTable state) {
        int plots = countFarmingPlots(entry.body, cell);
        state.rawset("farm_plot_count", (double)plots);
        String result = specialistLootOne(entry.body, cell, "FARMER");
        if (result != null) {
            state.rawset("farm_last_action", "gathered:" + result);
            entry.workStatus = "farm_supply_gathered";
            return result;
        }
        if (plots > 0) {
            state.rawset("farm_last_action", "field_observed:" + plots);
            entry.workStatus = "farm_field_observed";
            return "field_observed:" + plots;
        }
        state.rawset("farm_last_action", "no_field_or_supply");
        entry.workStatus = "farm_searching";
        return null;
    }

    private static String medicOne(Entry entry, IsoCell cell, KahluaTable state) {
        String result = specialistLootOne(entry.body, cell, "MEDIC");
        if (result != null) {
            state.rawset("medic_status", "medical_supply_gathered");
            state.rawset("medic_last_target", null);
            entry.workStatus = "medical_supply_gathered";
            return result;
        }
        for (Entry patient : actors.values()) {
            if (patient == entry || patient.body == null || !patient.body.isAlive()
                    || patient.body.getHealth() >= 99.9f) continue;
            if (patient.body.restoreHealth(MEDIC_HEAL_AMOUNT)) {
                String id = String.valueOf(patient.body.getModData().rawget("goblin_actor_id"));
                state.rawset("medic_status", "treated");
                state.rawset("medic_last_target", id);
                entry.workStatus = "treated_" + id;
                return "treated:" + id;
            }
        }
        state.rawset("medic_status", "standby_no_patient");
        state.rawset("medic_last_target", null);
        entry.workStatus = "medic_standby";
        return null;
    }

    private static String guardPost(Entry entry, KahluaTable state) {
        WorldAnchor base = stateAnchor(state, "protection_base");
        if (base == null) base = stateAnchor(state, "home");
        if (base == null) {
            entry.workStatus = "guard_no_base";
            state.rawset("guard_status", "no_base_anchor");
            return null;
        }
        Object rawIndex = state.rawget("guard_patrol_index");
        int index = rawIndex instanceof Number number
                ? (int)Math.max(0, Math.floor(number.doubleValue())) % 4 : 0;
        double x = base.x;
        double y = base.y;
        if (index == 0) { x += GUARD_POST_RADIUS; y -= GUARD_POST_RADIUS; }
        else if (index == 1) { x += GUARD_POST_RADIUS; y += GUARD_POST_RADIUS; }
        else if (index == 2) { x -= GUARD_POST_RADIUS; y += GUARD_POST_RADIUS; }
        else { x -= GUARD_POST_RADIUS; y -= GUARD_POST_RADIUS; }
        state.rawset("guard_post_x", x);
        state.rawset("guard_post_y", y);
        state.rawset("guard_post_z", base.z);
        state.rawset("guard_patrol_index", (double)((index + 1) % 4));
        state.rawset("guard_status", "patrol_post_" + index);
        entry.workStatus = "guard_patrol_post_" + index;
        return "guard_post:" + index;
    }

    private static String disassembleOne(HumanSurvivor body) {
        ArrayList<InventoryItem> items = new ArrayList<>(body.getInventory().getItems());
        ArrayList<ItemContainer> containers = new ArrayList<>();
        containers.add(body.getInventory());
        for (InventoryItem item : items) {
            if (protectedEquipment(body, item)) continue;
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

    private static boolean expeditionJob(String job) {
        return "LOOT".equals(job) || "SCAVENGE".equals(job)
                || "HAULER".equals(job) || "FARMER".equals(job)
                || "SCOUT".equals(job) || "MEDIC".equals(job);
    }

    private static int bodyCargoCount(HumanSurvivor body) {
        if (body == null || body.getInventory() == null) return 0;
        int total = 0;
        for (InventoryItem item : new ArrayList<>(body.getInventory().getItems())) {
            if (!protectedEquipment(body, item)) {
                total = Math.min(MAX_PENDING_CARGO_ITEMS,
                        total + itemQuantity(item));
            }
        }
        return total;
    }

    private static int bodyCargoTypes(HumanSurvivor body) {
        if (body == null || body.getInventory() == null) return 0;
        Set<String> types = new HashSet<>();
        for (InventoryItem item : new ArrayList<>(body.getInventory().getItems())) {
            if (protectedEquipment(body, item) || item.getFullType() == null) continue;
            if (validItemType(item.getFullType())) types.add(item.getFullType());
        }
        return Math.min(MAX_PENDING_CARGO_TYPES, types.size());
    }

    private static IsoPlayer firstConnectedPlayer() {
        try {
            for (IsoPlayer player : GameServer.getPlayers()) {
                if (player != null && player.getCurrentSquare() != null) return player;
            }
        } catch (Throwable ignored) {
            // A reconnect can invalidate the server player collection mid-tick.
        }
        return null;
    }

    private static IsoGridSquare baseSquare(IsoCell cell, KahluaTable state) {
        if (cell == null || state == null) return null;
        WorldAnchor anchor = stateAnchor(state, "protection_base");
        if (anchor == null) {
            Double x = optionalNumber(state, "home_x");
            Double y = optionalNumber(state, "home_y");
            Double z = optionalNumber(state, "home_z");
            if (x != null && y != null && z != null) anchor = new WorldAnchor(x, y, z);
        }
        if (anchor == null) return null;
        return cell.getGridSquare((int)Math.floor(anchor.x),
                (int)Math.floor(anchor.y), (int)Math.floor(anchor.z));
    }

    private static IsoGridSquare deliverySquare(IsoCell cell, KahluaTable state,
            HumanSurvivor body) {
        IsoGridSquare square = baseSquare(cell, state);
        if (square != null) return square;
        if (body != null) {
            square = body.getCurrentSquare();
            if (square != null) return square;
        }
        IsoPlayer player = firstConnectedPlayer();
        return player == null ? null : player.getCurrentSquare();
    }

    private static boolean placeOnGround(IsoGridSquare square, InventoryItem item) {
        if (square == null || item == null) return false;
        try {
            InventoryItem placed = square.AddWorldInventoryItem(item, 0.5f, 0.5f, 0.0f);
            if (placed == null) return false;
            // AddWorldInventoryItem normally performs the server-side world
            // registration.  The explicit transmit keeps a newly returned
            // world object visible to already-connected clients on builds
            // where the helper leaves replication to the caller.
            try {
                IsoWorldInventoryObject worldItem = placed.getWorldItem();
                if (worldItem != null) square.transmitAddObjectToSquare(worldItem, 0);
            } catch (Throwable ignored) { }
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean dropAtBase(HumanSurvivor body, InventoryItem item,
            IsoCell cell, KahluaTable state) {
        IsoGridSquare square = deliverySquare(cell, state, body);
        if (body == null || item == null || square == null) return false;
        try {
            if (!removeBodyInventoryItem(body, item)) return false;
            if (!placeOnGround(square, item)) {
                body.getInventory().AddItem(item);
                return false;
            }
            state.rawset("delivery_location", baseSquare(cell, state) != null
                    ? "base_ground" : "ground");
            return true;
        } catch (Throwable ignored) {
            try {
                if (!body.getInventory().contains(item)) body.getInventory().AddItem(item);
            } catch (Throwable ignoredAgain) { }
            return false;
        }
    }

    private static int deliverPendingCargo(KahluaTable state, IsoCell cell,
            HumanSurvivor body) {
        KahluaTable cargo = pendingCargo(state);
        IsoGridSquare square = deliverySquare(cell, state, body);
        if (cargo == null || square == null) return 0;
        ArrayList<String> types = new ArrayList<>();
        KahluaTableIterator iterator = cargo.iterator();
        while (iterator != null && iterator.advance()) {
            if (iterator.getKey() instanceof String type && validItemType(type)) {
                types.add(type);
            }
        }
        int delivered = 0;
        for (String type : types) {
            Object rawCount = cargo.rawget(type);
            if (!(rawCount instanceof Number number)) continue;
            int count = (int)Math.max(0, Math.min(MAX_PENDING_CARGO_ITEMS,
                    Math.floor(number.doubleValue())));
            int remaining = count;
            while (remaining > 0) {
                InventoryItem item = InventoryItemFactory.CreateItem(type);
                if (item == null) break;
                try {
                    if (!placeOnGround(square, item)) break;
                    delivered++;
                    remaining--;
                } catch (Throwable ignored) {
                    break;
                }
            }
            if (remaining <= 0) cargo.rawset(type, null);
            else if (remaining < count) cargo.rawset(type, (double)remaining);
        }
        if (delivered > 0) {
            state.rawset("delivery_location", baseSquare(cell, state) != null
                    ? "base_ground" : "ground");
            state.rawset("delivery_status", baseSquare(cell, state) != null
                    ? "dropped_at_base:" + delivered
                    : "dropped_on_ground:" + delivered);
        }
        return delivered;
    }

    private static boolean hasPendingCargo(KahluaTable state) {
        return pendingCargoCount(state) > 0;
    }

    private static void finishReturn(Entry entry, KahluaTable state, int delivered) {
        if (hasPendingCargo(state) || bodyCargoCount(entry.body) > 0) {
            entry.workStatus = "cargo_pending_delivery";
            state.rawset("work_status", "cargo_pending_delivery");
            state.rawset("expedition_phase", "RETURNING");
            state.rawset("delivery_status", delivered > 0
                    ? "partially_delivered" : "awaiting_delivery");
            return;
        }
        Object roundValue = state.rawget("expedition_round");
        int round = roundValue instanceof Number number
                ? (int)Math.max(0, Math.min(Integer.MAX_VALUE,
                        Math.floor(number.doubleValue()))) : 0;
        state.rawset("expedition_round", (double)Math.min(Integer.MAX_VALUE, round + 1));
        state.rawset("expedition_phase", "OUTBOUND");
        state.rawset("expedition_target", null);
        state.rawset("work_status", "departing");
        String location = text(state, "delivery_location", "ground");
        state.rawset("delivery_status", delivered > 0
                ? (location + ":" + delivered) : "empty_return");
        entry.workStatus = "departing";
        entry.workMisses = 0;
    }

    private static int deliverBodyCargo(Entry entry, IsoCell cell, KahluaTable state) {
        if (entry.body == null || entry.body.getInventory() == null) return 0;
        int delivered = 0;
        for (InventoryItem item : new ArrayList<>(entry.body.getInventory().getItems())) {
            if (protectedEquipment(entry.body, item)) continue;
            boolean moved = dropAtBase(entry.body, item, cell, state);
            if (!moved) {
                String type = item.getFullType();
                int quantity = itemQuantity(item);
                if (validItemType(type)
                        && pendingCargoCount(state) + quantity <= MAX_PENDING_CARGO_ITEMS
                        && addPendingCargo(state, type, quantity)) {
                    moved = removeBodyInventoryItem(entry.body, item);
                }
            }
            if (moved) delivered += itemQuantity(item);
        }
        return delivered;
    }

    private static boolean vehicleRecoveryEnabled(KahluaTable state) {
        if (state == null) return false;
        Object enabled = state.rawget("vehicle_recovery_enabled");
        if (enabled instanceof Boolean value) return value;
        return "HAULER".equals(text(state, "job", "").toUpperCase());
    }

    private static boolean vehicleIsCandidate(BaseVehicle vehicle,
            HumanSurvivor body, IsoCell cell) {
        if (vehicle == null || body == null || cell == null) return false;
        try {
            IsoGridSquare square = vehicle.getSquare();
            if (square == null || square.getCell() != cell
                    || Math.abs(vehicle.getZ() - body.getZ()) > 0.1
                    || Math.hypot(vehicle.getX() - body.getX(),
                            vehicle.getY() - body.getY()) > VEHICLE_SEARCH_RADIUS
                    || vehicle.isBurntOrSmashed()
                    || !vehicle.isOperational() || !vehicle.isDriveable()
                    || !vehicle.isEngineWorking()
                    || vehicleHasOtherOccupant(vehicle, body)) return false;
            KahluaTable data = vehicleModData(vehicle);
            if (data != null) {
                if (Boolean.TRUE.equals(data.rawget(VEHICLE_RECOVERED_KEY))) return false;
                Object owner = data.rawget(VEHICLE_CLAIM_KEY);
                Object actor = body.getModData().rawget("goblin_actor_id");
                if (owner instanceof String ownerId
                        && !ownerId.equals(actor)) return false;
            }
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static BaseVehicle findVehicleForRecovery(Entry entry,
            IsoCell cell) {
        if (entry == null || entry.body == null || cell == null) return null;
        BaseVehicle nearest = null;
        double nearestDistance = Double.POSITIVE_INFINITY;
        try {
            for (BaseVehicle vehicle : cell.getVehicles()) {
                if (!vehicleIsCandidate(vehicle, entry.body, cell)) continue;
                double distance = Math.hypot(vehicle.getX() - entry.body.getX(),
                        vehicle.getY() - entry.body.getY());
                if (distance < nearestDistance) {
                    nearest = vehicle;
                    nearestDistance = distance;
                }
            }
        } catch (Throwable ignored) { }
        return nearest;
    }

    /**
     * Find a reachable, standable square beside the vehicle rather than
     * routing a human body to the vehicle's occupied footprint.  A vehicle
     * can be parked on the other side of a wall or fence, and the nearest
     * vehicle tile is not a valid character destination even when the car
     * itself is a usable recovery candidate.
     */
    private static IsoGridSquare findReachableVehicleApproach(Entry entry,
            IsoCell cell, BaseVehicle vehicle) {
        if (entry == null || entry.body == null || cell == null || vehicle == null
                || entry.body.getCurrentSquare() == null) return null;
        int floor = (int)Math.floor(vehicle.getZ());
        int originX = (int)Math.floor(vehicle.getX());
        int originY = (int)Math.floor(vehicle.getY());
        ArrayList<IsoGridSquare> candidates = new ArrayList<>();
        for (int radius = 0; radius <= VEHICLE_APPROACH_RING_RADIUS; radius++) {
            for (int ox = -radius; ox <= radius; ox++) {
                for (int oy = -radius; oy <= radius; oy++) {
                    if (radius > 0
                            && Math.max(Math.abs(ox), Math.abs(oy)) != radius) continue;
                    IsoGridSquare candidate = cell.getGridSquare(originX + ox,
                            originY + oy, floor);
                    if (candidate == null || !candidate.isFree(false)
                            || hasMovingObject(candidate)) continue;
                    try {
                        if (vehicle.isIntersectingSquare(candidate)) continue;
                    } catch (Throwable ignored) {
                        continue;
                    }
                    double distance = Math.hypot(candidate.getX() + 0.5 - vehicle.getX(),
                            candidate.getY() + 0.5 - vehicle.getY());
                    if (distance <= VEHICLE_APPROACH_MAX_DISTANCE) candidates.add(candidate);
                }
            }
        }
        if (candidates.isEmpty()) return null;

        double bodyX = entry.body.getX();
        double bodyY = entry.body.getY();
        candidates.sort((left, right) -> Double.compare(
                Math.hypot(left.getX() + 0.5 - bodyX, left.getY() + 0.5 - bodyY),
                Math.hypot(right.getX() + 0.5 - bodyX, right.getY() + 0.5 - bodyY)));
        IsoGridSquare start = entry.body.getCurrentSquare();
        GridRoute.Result lastResult = null;
        for (IsoGridSquare candidate : candidates) {
            GridRoute.Result result = GridRoute.search(
                    new GridRoute.Cell(start.getX(), start.getY()),
                    new GridRoute.Cell(candidate.getX(), candidate.getY()),
                    0.0, VEHICLE_APPROACH_ROUTE_BUDGET, (from, to) -> {
                        IsoGridSquare fromSquare = cell.getGridSquare(from.x(), from.y(), floor);
                        IsoGridSquare toSquare = cell.getGridSquare(to.x(), to.y(), floor);
                        return canTraverseStep(entry.body, fromSquare, toSquare);
                    });
            lastResult = result;
            if (result.status() == GridRoute.Status.FOUND
                    || result.status() == GridRoute.Status.ARRIVED) {
                System.out.println("[GoblinSurvivorStorm] vehicle approach actor="
                        + recoveryActorId(entry) + " vehicle=" + vehicle.getId()
                        + " target=" + candidate.getX() + "," + candidate.getY()
                        + " expanded=" + result.expanded());
                return candidate;
            }
        }
        if (lastResult != null) {
            System.out.println("[GoblinSurvivorStorm] vehicle approach unavailable actor="
                    + recoveryActorId(entry) + " vehicle=" + vehicle.getId()
                    + " result=" + lastResult.status()
                    + " expanded=" + lastResult.expanded());
        }
        return null;
    }

    /**
     * Let B42's polygonal pathfinder resolve an approach when the lightweight
     * square adapter cannot prove a route.  PathFindBehavior2 is asynchronous
     * and advances the real HumanSurvivor through moveUnmodded(); it never
     * authorizes a teleport or bypasses the vehicle-distance/entry checks.
     */
    private static boolean advanceNativeVehicleApproach(Entry entry,
            BaseVehicle vehicle, long now) {
        if (entry == null || entry.body == null || vehicle == null) return false;
        try {
            PathFindBehavior2 behavior = entry.body.getPathFindBehavior2();
            if (behavior == null) {
                entry.vehicleError = "B42 pathfinder is unavailable";
                return false;
            }
            if (!entry.recoveryNativePathRequested) {
                behavior.reset();
                behavior.pathToVehicleAdjacent(vehicle);
                entry.body.setMovementMode(true, true);
                entry.body.setMoving(true);
                entry.recoveryNativePathRequested = true;
                entry.recoveryNativePathStartedAt = now;
                entry.vehicleStatus = "vehicle_approach_pathfinding";
            }
            PathFindBehavior2.BehaviorResult result = behavior.update();
            if (result == PathFindBehavior2.BehaviorResult.Failed) {
                entry.vehicleError = "B42 pathfinder rejected vehicle approach";
                return false;
            }
            if (behavior.pathNextIsSet) {
                double dx = behavior.pathNextX - entry.body.getX();
                double dy = behavior.pathNextY - entry.body.getY();
                double distance = Math.hypot(dx, dy);
                if (distance > 0.001) {
                    double elapsed = entry.lastStep > 0L
                            ? (now - entry.lastStep) / 1_000_000_000.0 : 0.05;
                    if (!Double.isFinite(elapsed) || elapsed <= 0.0) elapsed = 0.05;
                    elapsed = Math.min(0.25, elapsed);
                    double amount = Math.min(distance,
                            RUN_SPEED_TILES_PER_SECOND * elapsed);
                    float nextX = (float)(entry.body.getX()
                            + dx / distance * amount);
                    float nextY = (float)(entry.body.getY()
                            + dy / distance * amount);
                    IsoGridSquare from = entry.body.getCurrentSquare();
                    IsoGridSquare to = entry.body.getCell().getGridSquare(
                            (int)Math.floor(nextX), (int)Math.floor(nextY),
                            (int)Math.floor(entry.body.getZ()));
                    boolean hop = canHop(entry.body, from, to);
                    if (hop && beginFenceTraversal(entry, entry.body, from, to,
                            true, now)) {
                        advanceFenceTraversal(entry, entry.body.getCell(), now);
                    } else if (from == null || to == null
                            || (from != to && !canTraverseStep(entry.body, from, to))) {
                        entry.vehicleError = "B42 path edge became blocked";
                    } else {
                        entry.body.setX(nextX);
                        entry.body.setY(nextY);
                        entry.body.setCurrentSquare(to);
                        entry.body.setMovingSquare(to);
                        entry.body.setForwardDirection((float)dx, (float)dy);
                        entry.body.setMovementMode(true, true);
                    }
                }
            }
            if (now - entry.recoveryNativePathStartedAt
                    > VEHICLE_STUCK_TIMEOUT_NANOS * 2
                    && Math.hypot(vehicle.getX() - entry.body.getX(),
                            vehicle.getY() - entry.body.getY())
                    > VEHICLE_ENTER_DISTANCE) {
                entry.vehicleError = "B42 pathfinder timed out";
                return false;
            }
            entry.vehicleStatus = result == PathFindBehavior2.BehaviorResult.Succeeded
                    ? "vehicle_approach_ready" : "vehicle_approach_pathfinding";
            return true;
        } catch (Throwable error) {
            entry.vehicleError = error.getClass().getSimpleName() + ":"
                    + String.valueOf(error.getMessage());
            return false;
        }
    }

    private static String recoveryActorId(Entry entry) {
        if (entry == null || entry.body == null) return "";
        try {
            Object value = entry.body.getModData().rawget("goblin_actor_id");
            return value instanceof String id ? id : "";
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static boolean beginVehicleRecovery(Entry entry, IsoCell cell,
            KahluaTable state) {
        if (entry == null || entry.body == null || entry.recoveryVehicle != null) {
            return entry != null && entry.recoveryVehicle != null;
        }
        BaseVehicle vehicle = findVehicleForRecovery(entry, cell);
        if (vehicle == null) {
            entry.vehicleStatus = "no_vehicle";
            return false;
        }
        IsoGridSquare approach = findReachableVehicleApproach(entry, cell, vehicle);
        boolean useNativePath = approach == null;
        String actorId = recoveryActorId(entry);
        KahluaTable data = vehicleModData(vehicle);
        if (data != null) data.rawset(VEHICLE_CLAIM_KEY, actorId);
        entry.recoveryVehicle = vehicle;
        entry.recoveryActorId = actorId;
        entry.recoveryPhase = 1;
        entry.recoveryRoute = List.of();
        entry.recoveryWaypoint = 0;
        entry.recoveryNextRouteAt = 0L;
        entry.recoveryRouteTargetX = Integer.MIN_VALUE;
        entry.recoveryRouteTargetY = Integer.MIN_VALUE;
        entry.recoveryRouteTargetZ = Integer.MIN_VALUE;
        entry.recoveryApproachTargetX = approach == null
                ? Integer.MIN_VALUE : approach.getX();
        entry.recoveryApproachTargetY = approach == null
                ? Integer.MIN_VALUE : approach.getY();
        entry.recoveryApproachTargetZ = approach == null
                ? Integer.MIN_VALUE : approach.getZ();
        entry.recoveryUseNativePath = useNativePath;
        entry.recoveryNativePathRequested = false;
        entry.recoveryNativePathStartedAt = 0L;
        entry.recoveryStartedAt = System.nanoTime();
        entry.recoveryLastProgressAt = entry.recoveryStartedAt;
        // Phase one measures the survivor's progress toward the car.  The
        // vehicle itself cannot move until phase two has successfully entered
        // the driver seat, so using its fixed position here creates a false
        // stuck timeout during a long approach.
        entry.recoveryApproachLastX = entry.body.getX();
        entry.recoveryApproachLastY = entry.body.getY();
        entry.recoveryLastX = vehicle.getX();
        entry.recoveryLastY = vehicle.getY();
        entry.vehicleStatus = "vehicle_claimed";
        entry.vehicleError = "";
        // Force moveTo() to discard the worker's previous destination.  The
        // approach square is a new, explicit vehicle target and must not
        // inherit a stale expedition route from the preceding work tick.
        entry.route = List.of();
        entry.waypoint = 0;
        entry.nextRouteAt = 0L;
        entry.routeTargetX = Integer.MIN_VALUE;
        entry.routeTargetY = Integer.MIN_VALUE;
        entry.routeTargetZ = Integer.MIN_VALUE;
        System.out.println("[GoblinSurvivorStorm] vehicle recovery claimed actor="
                + actorId + " vehicle=" + vehicle.getId()
                + " at=" + vehicle.getX() + "," + vehicle.getY()
                + (useNativePath ? " approach=native-pathfinder"
                        : " approach=" + approach.getX() + "," + approach.getY()));
        return true;
    }

    private static WorldAnchor recoveryBase(IsoCell cell, KahluaTable state) {
        WorldAnchor anchor = stateAnchor(state, "protection_base");
        // home_x/home_y are each survivor's saved formation/work origin, not
        // the shared delivery destination. Prefer the live player anchor so a
        // recovered vehicle is brought back to the group even before /gss
        // base set has been issued; use the per-survivor home only when the
        // world has no online player to anchor the recovery.
        if (anchor == null) anchor = playerAnchor(cell);
        if (anchor == null) anchor = stateAnchor(state, "home");
        return anchor;
    }

    private static void failVehicleRecovery(Entry entry, KahluaTable state,
            String status, String error) {
        String actorId = entry == null ? "" : entry.recoveryActorId;
        clearVehicleRecovery(entry, true);
        entry.vehicleStatus = status;
        entry.vehicleError = boundedVehicleError(error);
        entry.workStatus = status;
        if (state != null) state.rawset("work_status", status);
        System.out.println("[GoblinSurvivorStorm] vehicle recovery failed actor="
                + actorId + " status=" + status
                + (entry.vehicleError.isBlank() ? "" : " error=" + entry.vehicleError));
    }

    private static String boundedVehicleError(String error) {
        if (error == null || error.isBlank()) return "";
        StringBuilder safe = new StringBuilder(Math.min(error.length(), 160));
        for (int index = 0; index < error.length() && safe.length() < 160; index++) {
            char value = error.charAt(index);
            if (value < 32 && value != '\t' && value != '\n' && value != '\r') {
                safe.append(' ');
            } else {
                safe.append(value);
            }
        }
        if (safe.length() == 160 && error.length() > 160) {
            safe.setLength(157);
            safe.append("...");
        }
        return safe.toString();
    }

    private static void finishVehicleRecovery(Entry entry, IsoCell cell,
            KahluaTable state, WorldAnchor base) {
        BaseVehicle vehicle = entry.recoveryVehicle;
        if (vehicle == null) return;
        try {
            stopVehicleControls(vehicle);
            vehicle.shutOff();
            vehicle.transmitEngine();
            if (entry.body != null && entry.body.getVehicle() == vehicle) {
                vehicle.exit(entry.body);
            }
            KahluaTable data = vehicleModData(vehicle);
            if (data != null) {
                data.rawset(VEHICLE_RECOVERED_KEY, true);
                data.rawset(VEHICLE_RECOVERED_BY_KEY, entry.recoveryActorId);
                data.rawset(VEHICLE_RECOVERED_X_KEY, base.x);
                data.rawset(VEHICLE_RECOVERED_Y_KEY, base.y);
                data.rawset(VEHICLE_RECOVERED_Z_KEY, base.z);
            }
            releaseVehicleClaim(vehicle, entry.recoveryActorId);
            entry.vehicleRecoveries++;
            entry.vehicleStatus = "vehicle_returned";
            entry.vehicleError = "";
            state.rawset("expedition_phase", "RETURNING");
            state.rawset("work_status", "vehicle_returned");
            state.rawset("delivery_status", "vehicle_returned");
            entry.workStatus = "vehicle_returned";
            System.out.println("[GoblinSurvivorStorm] vehicle returned actor="
                    + entry.recoveryActorId + " vehicle=" + vehicle.getId()
                    + " base=" + base.x + "," + base.y + "," + base.z);
            clearVehicleRecovery(entry, false);
        } catch (Throwable error) {
            failVehicleRecovery(entry, state, "vehicle_return_failed",
                    error.getClass().getSimpleName() + ":" + error.getMessage());
        }
    }

    private static boolean driveVehicleTo(Entry entry, IsoCell cell,
            KahluaTable state, WorldAnchor base, long now) {
        BaseVehicle vehicle = entry.recoveryVehicle;
        if (vehicle == null || base == null) return false;
        if (Math.abs(vehicle.getZ() - base.z) > 0.1) {
            failVehicleRecovery(entry, state, "vehicle_different_floor",
                    "return anchor is on another floor");
            return false;
        }
        double distanceToBase = Math.hypot(base.x - vehicle.getX(),
                base.y - vehicle.getY());
        if (distanceToBase <= VEHICLE_RETURN_DISTANCE) {
            finishVehicleRecovery(entry, cell, state, base);
            return true;
        }
        IsoGridSquare start = vehicle.getSquare();
        IsoGridSquare goal = cell.getGridSquare((int)Math.floor(base.x),
                (int)Math.floor(base.y), (int)Math.floor(base.z));
        if (start == null || goal == null) {
            stopVehicleControls(vehicle);
            entry.vehicleStatus = "vehicle_waiting_for_world";
            return true;
        }
        if (entry.recoveryRouteTargetX != goal.getX()
                || entry.recoveryRouteTargetY != goal.getY()
                || entry.recoveryRouteTargetZ != goal.getZ()) {
            entry.recoveryRoute = List.of();
            entry.recoveryWaypoint = 0;
            entry.recoveryNextRouteAt = 0L;
            entry.recoveryRouteTargetX = goal.getX();
            entry.recoveryRouteTargetY = goal.getY();
            entry.recoveryRouteTargetZ = goal.getZ();
        }
        if (now >= entry.recoveryNextRouteAt) {
            GridRoute.Result routeResult = GridRoute.search(
                    new GridRoute.Cell(start.getX(), start.getY()),
                    new GridRoute.Cell(goal.getX(), goal.getY()),
                    Math.max(0.0, VEHICLE_RETURN_DISTANCE - 0.75),
                    VEHICLE_ROUTE_BUDGET,
                    (from, to) -> {
                        IsoGridSquare square = cell.getGridSquare(to.x(), to.y(),
                                goal.getZ());
                        return square != null && (square == goal || square.isFree(false));
                    });
            entry.recoveryRoute = routeResult.path();
            entry.recoveryWaypoint = 0;
            entry.recoveryNextRouteAt = now + VEHICLE_REPATH_NANOS;
            if (entry.recoveryRoute.isEmpty()) {
                stopVehicleControls(vehicle);
                entry.vehicleStatus = "vehicle_no_route";
                entry.vehicleError = "route=" + routeResult.status()
                        + " expanded=" + routeResult.expanded();
                if (now - entry.recoveryLastProgressAt > VEHICLE_STUCK_TIMEOUT_NANOS) {
                    failVehicleRecovery(entry, state, "vehicle_no_route",
                            entry.vehicleError);
                }
                return true;
            }
        }
        while (entry.recoveryWaypoint < entry.recoveryRoute.size()) {
            GridRoute.Cell point = entry.recoveryRoute.get(entry.recoveryWaypoint);
            if (Math.hypot(point.x() + 0.5 - vehicle.getX(),
                    point.y() + 0.5 - vehicle.getY()) > 1.5) break;
            entry.recoveryWaypoint++;
        }
        GridRoute.Point next = GridRoute.nextPoint(entry.recoveryRoute,
                entry.recoveryWaypoint, vehicle.getX(), vehicle.getY(), vehicle.getZ(),
                base.x, base.y, base.z);
        if (next == null) {
            stopVehicleControls(vehicle);
            entry.vehicleStatus = "vehicle_no_route";
            return true;
        }
        double dx = next.x() - vehicle.getX();
        double dy = next.y() - vehicle.getY();
        double distance = Math.hypot(dx, dy);
        if (distance <= 0.001) return true;
        try {
            boolean movedThisTick = moveHeadlessVehicle(vehicle, cell, goal,
                    next.x(), next.y(), base.z, now, entry.lastStep);
            if (!movedThisTick) {
                if (now - entry.recoveryLastProgressAt > VEHICLE_STUCK_TIMEOUT_NANOS) {
                    stopVehicleControls(vehicle);
                    failVehicleRecovery(entry, state, "vehicle_stuck",
                            "vehicle route square became blocked");
                    return false;
                }
                entry.vehicleStatus = "vehicle_waiting_for_route";
                state.rawset("navigation_status", "vehicle_waiting_for_route");
                return true;
            }
            double moved = Math.hypot(vehicle.getX() - entry.recoveryLastX,
                    vehicle.getY() - entry.recoveryLastY);
            if (moved > 0.10) {
                entry.recoveryLastX = vehicle.getX();
                entry.recoveryLastY = vehicle.getY();
                entry.recoveryLastProgressAt = now;
                entry.vehicleStatus = "vehicle_driving";
            } else if (now - entry.recoveryLastProgressAt > VEHICLE_STUCK_TIMEOUT_NANOS) {
                stopVehicleControls(vehicle);
                failVehicleRecovery(entry, state, "vehicle_stuck",
                        "vehicle physics made no progress");
                return false;
            } else {
                entry.vehicleStatus = "vehicle_driving";
            }
            state.rawset("navigation_status", "vehicle_driving");
            state.rawset("running", false);
            state.rawset("movement_blocked", false);
            state.rawset("route_remaining", (double)(entry.recoveryRoute.size()
                    - entry.recoveryWaypoint));
            return true;
        } catch (Throwable error) {
            failVehicleRecovery(entry, state, "vehicle_drive_error",
                    error.getClass().getSimpleName() + ":" + error.getMessage());
            return false;
        }
    }

    private static boolean serviceVehicleRecovery(Entry entry, IsoCell cell,
            KahluaTable state, long now) {
        BaseVehicle vehicle = entry.recoveryVehicle;
        if (vehicle == null) return false;
        if (vehicle.getSquare() == null || vehicle.getSquare().getCell() != cell
                || vehicle.isBurntOrSmashed()) {
            failVehicleRecovery(entry, state, "vehicle_lost", "vehicle left loaded world");
            return false;
        }
        if (entry.recoveryPhase == 1) {
            double distance = Math.hypot(vehicle.getX() - entry.body.getX(),
                    vehicle.getY() - entry.body.getY());
            if (distance > VEHICLE_ENTER_DISTANCE) {
                if (entry.recoveryUseNativePath) {
                    if (!advanceNativeVehicleApproach(entry, vehicle, now)) {
                        failVehicleRecovery(entry, state, "vehicle_approach_failed",
                                entry.vehicleError);
                        return false;
                    }
                } else {
                    IsoGridSquare approach = null;
                    if (entry.recoveryApproachTargetX != Integer.MIN_VALUE
                            && entry.recoveryApproachTargetY != Integer.MIN_VALUE
                            && entry.recoveryApproachTargetZ != Integer.MIN_VALUE) {
                        approach = cell.getGridSquare(entry.recoveryApproachTargetX,
                                entry.recoveryApproachTargetY,
                                entry.recoveryApproachTargetZ);
                    }
                    boolean approachValid = approach != null;
                    if (approachValid) {
                        try {
                            approachValid = approach.isFree(false)
                                    && !hasMovingObject(approach)
                                    && !vehicle.isIntersectingSquare(approach);
                        } catch (Throwable ignored) {
                            approachValid = false;
                        }
                    }
                    if (!approachValid) {
                        approach = findReachableVehicleApproach(entry, cell, vehicle);
                        if (approach == null) {
                            failVehicleRecovery(entry, state, "vehicle_no_approach_route",
                                    "vehicle approach square became unavailable");
                            return false;
                        }
                        entry.recoveryApproachTargetX = approach.getX();
                        entry.recoveryApproachTargetY = approach.getY();
                        entry.recoveryApproachTargetZ = approach.getZ();
                        entry.route = List.of();
                        entry.waypoint = 0;
                        entry.nextRouteAt = 0L;
                        entry.routeTargetX = Integer.MIN_VALUE;
                        entry.routeTargetY = Integer.MIN_VALUE;
                        entry.routeTargetZ = Integer.MIN_VALUE;
                    }
                    // A hauler must be able to leave the formation to reach
                    // its claimed vehicle. The ordinary worker route protects
                    // a four-tile separation bubble, but applying that bubble
                    // here can deadlock the first step when the roster is
                    // clustered at the base. World collision and fence
                    // validation remain in force; only interpersonal spacing
                    // is relaxed for this explicit vehicle approach.
                    moveTo(entry, cell, state, approach.getX() + 0.5,
                            approach.getY() + 0.5, approach.getZ(),
                            VEHICLE_APPROACH_STOP_DISTANCE, now, true, false,
                            VEHICLE_ROUTE_BUDGET);
                }
                double moved = Math.hypot(entry.body.getX() - entry.recoveryApproachLastX,
                        entry.body.getY() - entry.recoveryApproachLastY);
                if (moved > 0.10) {
                    entry.recoveryApproachLastX = entry.body.getX();
                    entry.recoveryApproachLastY = entry.body.getY();
                    entry.recoveryLastProgressAt = now;
                } else if (now - entry.recoveryLastProgressAt
                        > VEHICLE_STUCK_TIMEOUT_NANOS) {
                    failVehicleRecovery(entry, state, "vehicle_approach_stuck",
                            "survivor could not reach the claimed vehicle");
                    return false;
                }
                state.rawset("navigation_status", "vehicle_approach");
                state.rawset("vehicle_status", "vehicle_approach");
                return true;
            }
            if (!vehicleIsCandidate(vehicle, entry.body, cell)) {
                failVehicleRecovery(entry, state, "vehicle_unavailable",
                        "vehicle became occupied or inoperable");
                return false;
            }
            try {
                vehicle.setLocked(false);
                vehicle.cheatHotwire(true, false);
                if (!vehicle.isSeatInstalled(0) || vehicle.isSeatOccupied(0)) {
                    failVehicleRecovery(entry, state, "vehicle_no_driver_seat",
                            "driver seat is unavailable");
                    return false;
                }
                if (!vehicle.enter(0, entry.body)) {
                    failVehicleRecovery(entry, state, "vehicle_entry_failed",
                            "B42 rejected entry into the driver seat");
                    return false;
                }
                // The server owns this recovery state machine. Leave B42's
                // native controller disabled; its update path is client-UI
                // dependent on a dedicated server.
                vehicle.setPhysicsActive(false);
                // BaseVehicle.tryStartEngine() is a player-facing helper. In
                // a dedicated server it can reach UIManager.speedControls,
                // which is intentionally null. The server-owned recovery
                // order already unlocked and hotwired the vehicle above, so
                // transition the engine through the headless state API
                // directly. Mechanical damage still rejects the vehicle.
                if (!vehicle.isEngineRunning() && vehicle.isEngineWorking()
                        && vehicle.isOperational()) {
                    vehicle.engineDoStarting();
                    vehicle.engineDoStartingSuccess();
                    vehicle.engineDoRunning();
                }
                if (!vehicle.isEngineRunning()) {
                    failVehicleRecovery(entry, state, "vehicle_start_failed",
                            "engine did not enter running state");
                    return false;
                }
                entry.recoveryPhase = 2;
                entry.recoveryStartedAt = now;
                entry.recoveryLastProgressAt = now;
                entry.recoveryLastX = vehicle.getX();
                entry.recoveryLastY = vehicle.getY();
                entry.vehicleStatus = "vehicle_driving";
                entry.vehicleError = "";
                entry.recoveryRoute = List.of();
                entry.recoveryWaypoint = 0;
                entry.recoveryNextRouteAt = 0L;
                entry.recoveryRouteTargetX = Integer.MIN_VALUE;
                entry.recoveryRouteTargetY = Integer.MIN_VALUE;
                entry.recoveryRouteTargetZ = Integer.MIN_VALUE;
                state.rawset("navigation_status", "vehicle_driving");
                return true;
            } catch (Throwable error) {
                failVehicleRecovery(entry, state, "vehicle_entry_error",
                        error.getClass().getSimpleName() + ":" + error.getMessage());
                return false;
            }
        }
        WorldAnchor base = recoveryBase(cell, state);
        if (base == null) {
            failVehicleRecovery(entry, state, "vehicle_no_return_anchor",
                    "home base and player anchor are unavailable");
            return false;
        }
        entry.vehicleStatus = "vehicle_driving";
        return driveVehicleTo(entry, cell, state, base, now);
    }

    /** Move carried loot into the durable ledger before the world can unload. */
    public static boolean persistActorCargo(KahluaTable state) {
        if (!GameServer.server || state == null) return false;
        Object idValue = state.rawget("actor_id");
        if (!(idValue instanceof String id) || id.isBlank()) return false;
        Entry entry = actors.get(id);
        if (entry == null || entry.body == null || !entry.body.isAlive()) return false;
        boolean changed = false;
        for (InventoryItem item : new ArrayList<>(entry.body.getInventory().getItems())) {
            if (protectedEquipment(entry.body, item)) continue;
            String type = item.getFullType();
            int quantity = itemQuantity(item);
            if (!validItemType(type)
                    || pendingCargoCount(state) + quantity > MAX_PENDING_CARGO_ITEMS) continue;
            if (!addPendingCargo(state, type, quantity)) continue;
            if (removeBodyInventoryItem(entry.body, item)) changed = true;
        }
        if (changed) {
            state.rawset("expedition_phase", "RETURNING");
            state.rawset("work_status", "cargo_saved_for_delivery");
            state.rawset("delivery_status", "saved_for_delivery");
            entry.workStatus = "cargo_saved_for_delivery";
        }
        return changed;
    }

    private static void serviceWork(Entry entry, IsoCell cell, KahluaTable state,
            KahluaTable target, long now) {
        String job = text(state, "job", "SCAVENGE").toUpperCase();
        boolean expedition = expeditionJob(job);
        String phase = text(state, "expedition_phase", "OUTBOUND").toUpperCase();
        // The HAULER role automatically recovers the nearest usable vehicle
        // before its normal loot pass. Other expedition workers can opt into
        // the exact same state machine through /gss cars; one worker claims a
        // vehicle on the server so the roster cannot duplicate the job.
        if (expedition && vehicleRecoveryEnabled(state)
                && "OUTBOUND".equals(phase)
                && entry.recoveryVehicle == null
                && now >= entry.nextVehicleAttemptAt) {
            entry.nextVehicleAttemptAt = now + WORK_INTERVAL_NANOS;
            if (beginVehicleRecovery(entry, cell, state)) {
                entry.workStatus = "vehicle_claimed";
                state.rawset("work_status", "vehicle_claimed");
                entry.nextWorkAt = now + WORK_INTERVAL_NANOS;
                return;
            }
        }
        if (expedition && "RETURNING".equals(phase)) {
            int delivered = deliverBodyCargo(entry, cell, state);
            finishReturn(entry, state, delivered);
            entry.nextWorkAt = now + WORK_INTERVAL_NANOS;
            return;
        }
        if (now < entry.nextWorkAt) {
            entry.workStatus = "working";
            return;
        }
        String result = null;
        // Specialist assignments have explicit server behavior.  They still
        // use the same bounded outbound/return route and cargo ledger as a
        // scavenger, but they do not all collapse into generic pickup work.
        if ("SCOUT".equals(job)) {
            result = scoutOne(entry, cell, state);
            entry.workMisses = 0;
        } else if ("FARMER".equals(job)) {
            result = farmerOne(entry, cell, state);
            if (result == null) {
                entry.workMisses++;
                if (entry.workMisses >= WORK_EMPTY_TRIP_LIMIT) {
                    advanceEmptyExpedition(entry, state, "farmer_searching_next_area");
                }
            } else {
                entry.workMisses = 0;
            }
            if (result != null && bodyCargoCount(entry.body) >= WORK_BATCH_ITEMS) {
                state.rawset("expedition_phase", "RETURNING");
                state.rawset("work_status", "returning_with_farm_supplies");
            } else if (result != null && !"RETURNING".equals(
                    text(state, "expedition_phase", "OUTBOUND").toUpperCase())) {
                advanceSpecialistRoute(state);
            }
        } else if ("MEDIC".equals(job)) {
            result = medicOne(entry, cell, state);
            if (result == null) {
                entry.workMisses++;
                if (entry.workMisses >= WORK_EMPTY_TRIP_LIMIT) {
                    advanceEmptyExpedition(entry, state, "medic_searching_next_area");
                }
            } else {
                entry.workMisses = 0;
                if (bodyCargoCount(entry.body) >= WORK_BATCH_ITEMS) {
                    state.rawset("expedition_phase", "RETURNING");
                    state.rawset("work_status", "returning_with_medical_supplies");
                } else if (!"RETURNING".equals(
                        text(state, "expedition_phase", "OUTBOUND").toUpperCase())) {
                    advanceSpecialistRoute(state);
                }
            }
        } else if (expedition) {
            result = lootOne(entry.body, cell);
            if (result == null) {
                entry.workMisses++;
                entry.workStatus = "searching";
                if (entry.workMisses >= WORK_EMPTY_TRIP_LIMIT) {
                    advanceEmptyExpedition(entry, state, "searching_next_area");
                }
            } else {
                entry.workMisses = 0;
                entry.workStatus = "looted";
                if (bodyCargoCount(entry.body) >= WORK_BATCH_ITEMS) {
                    state.rawset("expedition_phase", "RETURNING");
                    state.rawset("work_status", "returning_with_cargo");
                } else {
                    // A successful pickup is still only one bounded search
                    // action.  Clear the outbound target so the next work
                    // cycle selects a fresh deterministic area instead of
                    // leaving every scavenger parked at the same square.
                    advanceSpecialistRoute(state);
                    entry.workStatus = "looted_next_area";
                    state.rawset("work_status", "looted_next_area");
                }
            }
        } else if ("DISASSEMBLE".equals(job)) {
            result = disassembleOne(entry.body);
            entry.workStatus = result == null ? "no_valid_recipe" : "disassembled";
        } else if ("BUILDER".equals(job)) {
            // A builder role alone must never mutate the map. Lua arms this
            // capability only for an explicit in-game /gss build command, and
            // the Java guard remains authoritative if a bridge sends a stale
            // or forged job state.
            if (!Boolean.TRUE.equals(state.rawget("builder_commanded"))) {
                entry.workStatus = "waiting_for_build_command";
            } else {
                result = buildOne(entry, entry.body, cell);
                entry.workStatus = result == null
                        ? (entry.workCount >= BUILDER_MAX_STRUCTURES ? "build_limit" : "no_build_site")
                        : "built";
            }
        } else if ("GUARD".equals(job)) {
            result = guardPost(entry, state);
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

    private static boolean shouldRun(KahluaTable state, double distance,
            boolean urgent) {
        String requested = text(state, "movement_mode", "AUTO").toUpperCase();
        if ("RUN".equals(requested)) return true;
        if ("WALK".equals(requested)) return false;
        if (urgent) return true;
        String controlMode = text(state, "control_mode", "HOLD").toUpperCase();
        String phase = text(state, "expedition_phase", "FOLLOW").toUpperCase();
        if ("RETURNING".equals(phase)) return true;
        return ("FOLLOW".equals(controlMode) || "FOLLOW_ACTOR".equals(controlMode))
                && distance > 10.0;
    }

    private static void moveTo(Entry entry, IsoCell cell, KahluaTable state,
            double tx, double ty, double tz, double stopDistance, long now,
            boolean urgent) {
        moveTo(entry, cell, state, tx, ty, tz, stopDistance, now, urgent, true,
                2048);
    }

    private static void moveTo(Entry entry, IsoCell cell, KahluaTable state,
            double tx, double ty, double tz, double stopDistance, long now,
            boolean urgent, boolean enforceSeparation) {
        moveTo(entry, cell, state, tx, ty, tz, stopDistance, now, urgent,
                enforceSeparation, 2048);
    }

    private static void moveTo(Entry entry, IsoCell cell, KahluaTable state,
            double tx, double ty, double tz, double stopDistance, long now,
            boolean urgent, boolean enforceSeparation, int routeBudget) {
        HumanSurvivor body = entry.body;
        String controlMode = text(state, "control_mode", "HOLD").toUpperCase();
        TravelTarget travel = travelTarget(entry, cell, state, tx, ty, tz,
            stopDistance, now);
        tx = travel.x();
        ty = travel.y();
        tz = travel.z();
        // A remote player or long expedition leg may not have a generated
        // square yet.  The relevant-area request above is asynchronous; keep
        // the real human in place until B42 supplies a collision-checked
        // endpoint rather than treating an unloaded cell as a blocked wall.
        if (loadedSquare(cell, (int)Math.floor(tx), (int)Math.floor(ty),
                (int)Math.floor(tz)) == null) {
            clearNativeMovement(entry);
            body.setMovementMode(false, false);
            state.rawset("running", false);
            state.rawset("movement_blocked", false);
            state.rawset("navigation_status", "loading_target_area");
            state.rawset("route_remaining", 0.0);
            return;
        }
        boolean playerSearchRoute = Boolean.TRUE.equals(
                state.rawget("player_search_enabled"));
        double separationDistance = playerSearchRoute
                ? PLAYER_SEARCH_BODY_SEPARATION
                : ("FOLLOW".equals(controlMode)
                        || "FOLLOW_ACTOR".equals(controlMode)
                        ? FOLLOW_BODY_SEPARATION : MIN_BODY_SEPARATION);
        double elapsed = Math.min(0.25, Math.max(0,
                (now - entry.lastStep) / 1e9));
        boolean blocked = false;
        String navigation = "arrived";
        boolean runPose = false;
        // A fence traversal is an active B42 state, not ordinary movement.
        // Let it finish before asking the route solver for another edge.
        if (entry.traversalActive) {
            advanceFenceTraversal(entry, cell, now);
            if (entry.traversalActive) {
                body.setMovementMode(false, false);
                state.rawset("running", false);
                state.rawset("movement_blocked", false);
                state.rawset("navigation_status", "jumping");
                state.rawset("route_remaining", (double)(entry.route.size()
                        - entry.waypoint));
                return;
            }
            // PathFindBehavior2 does not own the custom body's movement loop,
            // so its private cursor is stale after a completed hop. Drop it
            // before selecting the next edge; otherwise the native path can
            // expose the same fence edge again and make the survivor vault in
            // place forever.
            clearNativeMovement(entry);
            entry.route = List.of();
            entry.waypoint = 0;
            entry.nextRouteAt = now;
        }
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
                runPose = shouldRun(state, distance, urgent);
                if (entry.routeTargetX != targetX || entry.routeTargetY != targetY
                        || entry.routeTargetZ != targetZ) {
                    clearNativeMovement(entry);
                    entry.route = List.of();
                    entry.waypoint = 0;
                    entry.nextRouteAt = 0L;
                    clearBlockedEdge(entry);
                    clearObstacleDetour(entry);
                    entry.routeTargetX = targetX;
                    entry.routeTargetY = targetY;
                    entry.routeTargetZ = targetZ;
                }
                int effectiveRouteBudget = playerSearchRoute
                        ? Math.max(routeBudget, 8192) : routeBudget;
                boolean obstacleDetourActive = entry.obstacleDetourActive
                        && now < entry.obstacleDetourUntil
                        && entry.waypoint < entry.route.size();
                if (entry.obstacleDetourActive && !obstacleDetourActive) {
                    clearObstacleDetour(entry);
                }
                // Player discovery can cross buildings, fences, doors, and
                // directional walls that the conservative square adapter
                // cannot classify.  Make B42's own polygonal A* the primary
                // solver for this route.  It remains asynchronous: while it
                // is working, no movement is authorized; once it exposes a
                // waypoint, the authority below still validates that single
                // edge and advances the real HumanSurvivor body itself.
                NativePathResult nativeResult = null;
                if (!obstacleDetourActive && playerSearchRoute
                        && (entry.nativeMoveActive || now >= entry.nextRouteAt)) {
                    nativeResult = advanceNativeLocationPath(
                            entry, cell, tx, ty, tz, stop, now);
                } else if (!obstacleDetourActive && !playerSearchRoute
                        && entry.nativeMoveActive) {
                    nativeResult = advanceNativeLocationPath(
                            entry, cell, tx, ty, tz, stop, now);
                }
                // Keep the bounded square A* as a recovery path for ordinary
                // movement and player-search legs. A native request that is
                // still pending must not be restarted by this branch; a
                // rejected or collision-invalidated native step may fall
                // through immediately so the survivor can go around it.
                boolean nativeRejected = nativeResult != null
                        && nativeResult.state() == NativePathState.FAILED;
                if (nativeResult != null
                        && nativeResult.state() == NativePathState.POINT
                        && nativeResult.point() != null
                        && isRememberedBlockedEdge(entry,
                                new GridRoute.Cell((int)Math.floor(body.getX()),
                                        (int)Math.floor(body.getY())),
                                new GridRoute.Cell((int)Math.floor(nativeResult.point().x()),
                                        (int)Math.floor(nativeResult.point().y())),
                                now)) {
                    // Do not ask the native solver to repeat the exact edge
                    // rejected by the collision authority.  Its next request
                    // is still allowed after the short edge-memory window;
                    // meanwhile the bounded grid fallback can route around it.
                    clearNativeMovement(entry);
                    entry.nextRouteAt = now;
                    nativeResult = new NativePathResult(
                            NativePathState.FAILED, null);
                }
                // A native path may expose its current square as a POINT
                // without tripping the path-ahead check (for example while
                // the polygonal path is being replaced). It is not an
                // actionable movement edge; treat it as a rejection so the
                // bounded recovery route can choose a different neighbor.
                if (nativeResult != null
                        && nativeResult.state() == NativePathState.POINT
                        && (nativeResult.point() == null
                        || Math.hypot(nativeResult.point().x() - body.getX(),
                                nativeResult.point().y() - body.getY()) <= 0.10)) {
                    clearNativeMovement(entry);
                    entry.nextRouteAt = now;
                    nativeResult = new NativePathResult(
                            NativePathState.FAILED, null);
                }
                nativeRejected = nativeResult != null
                        && nativeResult.state() == NativePathState.FAILED;
                boolean nativeRejectedBeforeGrid = nativeRejected;
                if (!obstacleDetourActive
                        && (nativeResult == null || nativeRejected)
                        && (nativeRejected || now >= entry.nextRouteAt)) {
                    final int floor = (int)Math.floor(body.getZ());
                    GridRoute.Result routeResult = GridRoute.search(
                            new GridRoute.Cell((int)Math.floor(body.getX()),
                                    (int)Math.floor(body.getY())),
                            new GridRoute.Cell(targetX, targetY),
                            Math.max(0.0, stop - 0.75), effectiveRouteBudget, (a, b) -> {
                                if (isRememberedBlockedEdge(entry, a, b, now)) return false;
                                IsoGridSquare from = loadedSquare(cell, a.x(), a.y(), floor);
                                IsoGridSquare to = loadedSquare(cell, b.x(), b.y(), floor);
                                return canTraverseStep(body, from, to);
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
                    if (routeResult.status() == GridRoute.Status.FOUND) {
                        clearNativeMovement(entry);
                        // The grid route is now the active provider. Leaving
                        // a previous FAILED native result here would discard
                        // the newly found detour in the movement block below.
                        nativeResult = null;
                    } else if (routeResult.status() == GridRoute.Status.ARRIVED) {
                        clearNativeMovement(entry);
                        nativeResult = new NativePathResult(NativePathState.ARRIVED, null);
                    } else {
                        // A failed bounded route is usually the signal that
                        // the world contains geometry the square adapter does
                        // not model completely: a door, directional wall,
                        // moving object, or an occupied destination square.
                        // Give B42's polygonal pathfinder first choice of the
                        // next safe point so the survivor goes around that
                        // object instead of repeatedly selecting the same
                        // short square-ring fallback.
                        NativePathResult nativeRecovery = null;
                        if (!nativeRejectedBeforeGrid && now >= entry.nextRouteAt) {
                            nativeRecovery = advanceNativeLocationPath(
                                    entry, cell, tx, ty, tz, stop, now);
                        }
                        if (nativeRecovery != null
                                && (nativeRecovery.state() == NativePathState.POINT
                                || nativeRecovery.state() == NativePathState.WAITING
                                || nativeRecovery.state() == NativePathState.ARRIVED)) {
                            nativeResult = nativeRecovery;
                        } else {
                            // If B42 rejects the request, first move to a
                            // nearby standable square, excluding the
                            // remembered blocked edge, then let the next tick
                            // replan the original destination from there.
                            GridRoute.Result escapeRoute = findLocalEscapeRoute(
                                    entry, cell, body, tx, ty, floor, now);
                            if (escapeRoute.status() == GridRoute.Status.FOUND) {
                                entry.route = escapeRoute.path();
                                entry.waypoint = 0;
                                entry.obstacleDetourActive = true;
                                entry.obstacleDetourUntil = now
                                        + OBSTACLE_DETOUR_HOLD_NANOS;
                                nativeResult = null;
                                navigation = "repath";
                                if (now >= entry.nextRouteDiagnosticAt) {
                                    System.out.println("[GoblinSurvivorStorm] local obstacle recovery actor="
                                            + recoveryActorId(entry)
                                            + " from=" + body.getX() + "," + body.getY()
                                            + " target=" + tx + "," + ty
                                            + " path=" + escapeRoute.path().size());
                                    entry.nextRouteDiagnosticAt = now + 10_000_000_000L;
                                }
                            } else {
                                // Do not immediately submit the same failed
                                // native request again in this tick; its
                                // bounded retry timestamp keeps a failed
                                // route from becoming a per-frame allocation
                                // loop.
                                nativeResult = new NativePathResult(
                                        NativePathState.FAILED, null);
                            }
                        }
                    }
                    entry.waypoint = 0;
                    entry.nextRouteAt = Math.max(entry.nextRouteAt,
                            now + 500_000_000L);
                }
                GridRoute.Point nextPoint = null;
                if (nativeResult != null) {
                    if (nativeResult.state() == NativePathState.POINT) {
                        nextPoint = nativeResult.point();
                    } else if (nativeResult.state() == NativePathState.WAITING) {
                        navigation = "pathfinding";
                        distance = 0.0;
                    } else if (nativeResult.state() == NativePathState.ARRIVED) {
                        navigation = "arrived";
                        distance = 0.0;
                    } else {
                        blocked = true;
                        navigation = "no_route";
                        distance = 0.0;
                    }
                } else {
                    while (entry.waypoint < entry.route.size()) {
                        GridRoute.Cell waypoint = entry.route.get(entry.waypoint);
                        if (Math.hypot(waypoint.x() + 0.5 - body.getX(),
                                waypoint.y() + 0.5 - body.getY()) > 0.08) break;
                        entry.waypoint++;
                    }
                    nextPoint = GridRoute.nextPoint(entry.route, entry.waypoint,
                            body.getX(), body.getY(), body.getZ(), tx, ty, tz);
                    if (nextPoint == null) {
                        blocked = true;
                        navigation = "no_route";
                        distance = 0.0;
                    }
                }
                if (nextPoint != null) {
                    dx = nextPoint.x() - body.getX();
                    dy = nextPoint.y() - body.getY();
                    distance = Math.hypot(dx, dy);
                    double speed = runPose ? RUN_SPEED_TILES_PER_SECOND
                            : WALK_SPEED_TILES_PER_SECOND;
                    double stepDistance = Math.min(distance, speed * elapsed);
                    float nx = (float)(body.getX()
                            + (distance > 0.0 ? dx / distance * stepDistance : 0.0));
                    float ny = (float)(body.getY()
                            + (distance > 0.0 ? dy / distance * stepDistance : 0.0));
                    IsoGridSquare from = body.getCurrentSquare();
                    IsoGridSquare to = loadedSquare(cell, (int)Math.floor(nx),
                            (int)Math.floor(ny), (int)Math.floor(body.getZ()));
                    boolean hop = canHop(body, from, to);
                    if (hop && beginFenceTraversal(entry, body, from, to, runPose, now)) {
                        advanceFenceTraversal(entry, cell, now);
                        navigation = entry.traversalActive ? "jumping" : "moving";
                        blocked = false;
                        runPose = false;
                    } else {
                        blocked = blocked || from == null || to == null || (from != to
                                && (!to.isFree(false) || from.testCollideAdjacent(body,
                                to.getX() - from.getX(), to.getY() - from.getY(), 0)));
                        boolean worldBlocked = blocked;
                        // An active player-search leg is the one deliberate
                        // exception to formation spacing.  The scout or
                        // join-assist worker must be able to cross the
                        // initial cluster before the route can reach an
                        // adjacent server cell.  PZ's native path result,
                        // square collision check, and validated fence state
                        // still guard every world edge; only the peer-body
                        // bubble is disabled for this explicit search route.
                        // Free-roaming jobs have an explicit world destination
                        // and a bounded group leash. Blocking their first edge
                        // on another survivor's formation bubble can make every
                        // worker report "separation" forever at the base. Keep
                        // peer spacing for party/follow movement, while work
                        // routes still obey loaded-square collision, fences,
                        // and the group leash above.
                        boolean enforcePeerSeparation = enforceSeparation
                                && !playerSearchRoute
                                && !"JOB".equals(controlMode);
                        if (!blocked && enforcePeerSeparation
                                && violatesBodySeparation(entry, nx, ny, body.getZ(),
                                        separationDistance)) {
                            blocked = true;
                            navigation = "separation";
                            entry.separationBlocks++;
                        }
                        if (!blocked) {
                            body.setX(nx);
                            body.setY(ny);
                            body.setCurrentSquare(to);
                            body.setMovingSquare(to);
                            body.setForwardDirection((float)dx, (float)dy);
                        } else if (worldBlocked) {
                            // A native waypoint can become invalid after a
                            // moving object, door, or cell update changes the
                            // edge.  Drop the rejected edge immediately; if it
                            // remains in the route, every tick repeats the
                            // same collision and the survivor appears to run
                            // into the object forever.  The short memory makes
                            // the bounded grid recovery choose a neighboring
                            // edge while the native PZ path is re-requested.
                            rememberBlockedEdge(entry, from, to, now);
                            clearNativeMovement(entry);
                            entry.route = List.of();
                            entry.waypoint = 0;
                            entry.nextRouteAt = Math.max(entry.nextRouteAt,
                                    now + OBSTACLE_REPATH_NANOS);
                            GridRoute.Result escapeRoute = findLocalEscapeRoute(
                                    entry, cell, body, tx, ty,
                                    (int)Math.floor(body.getZ()), now);
                            if (escapeRoute.status() == GridRoute.Status.FOUND) {
                                entry.route = escapeRoute.path();
                                entry.waypoint = 0;
                                entry.obstacleDetourActive = true;
                                entry.obstacleDetourUntil = now
                                        + OBSTACLE_DETOUR_HOLD_NANOS;
                                // The point that was just rejected must never
                                // be applied again during this tick. The
                                // bounded detour will be consumed on the next
                                // tick while the original target remains the
                                // route target for the eventual replan.
                                nextPoint = null;
                            }
                            navigation = "repath";
                        } else if (!navigation.equals("no_route") && !navigation.equals("separation")) {
                            navigation = "blocked_edge";
                            entry.nextRouteAt = Math.max(entry.nextRouteAt,
                                    now + 100_000_000L);
                        }
                    }
                }
            } else {
                clearNativeMovement(entry);
            }
        }
        boolean movingPose = "moving".equals(navigation) && !blocked;
        runPose = movingPose && runPose;
        body.setMovementMode(movingPose, runPose);
        state.rawset("running", runPose);
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
            double radius, KahluaTable state) {
        IsoZombie result = null;
        double best = radius * radius;
        for (IsoZombie zombie : cell.getZombieList()) {
            if (!liveHostile(zombie) || !isProtectedThreat(zombie, state)) continue;
            double dx = zombie.getX() - body.getX();
            double dy = zombie.getY() - body.getY();
            double dz = Math.abs(zombie.getZ() - body.getZ());
            double distance = dx * dx + dy * dy;
            if (dz > 0.1 || distance > best) continue;
            best = distance;
            result = zombie;
        }
        // B42 can expose a freshly materialized networked zombie through the
        // cell object list before the cell's dedicated zombie list catches
        // up.  This is especially visible with the local combat fixture:
        // using only getZombieList() makes the survivor report an empty melee
        // radius even though the ordinary zombie is already in the world.
        // Scan the authoritative moving-object list as a bounded fallback;
        // duplicate entries are harmless because the same distance check is
        // applied and no actor state is mutated during this scan.
        for (IsoMovingObject object : cell.getObjectList()) {
            if (!(object instanceof IsoZombie zombie)) continue;
            if (!liveHostile(zombie) || !isProtectedThreat(zombie, state)) continue;
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

    private static void debugCombatDiagnostics(Entry entry, IsoCell cell,
            HumanSurvivor body, long now) {
        if (now < entry.nextCombatDiagnosticAt) return;
        entry.nextCombatDiagnosticAt = now + 5_000_000_000L;
        StringBuilder log = new StringBuilder();
        String actorId = String.valueOf(body.getModData().rawget("goblin_actor_id"));
        log.append("[GoblinSurvivorStorm] melee scan actor=")
                .append(actorId)
                .append(" zombieList=").append(cell.getZombieList().size())
                .append(" objectList=").append(cell.getObjectList().size());
        int fixtureCount = 0;
        int nearby = 0;
        for (IsoZombie zombie : cell.getZombieList()) {
            KahluaTable data = zombie.getModData();
            if (data != null && actorId.equals(data.rawget(DEBUG_COMBAT_ACTOR))
                    && Boolean.TRUE.equals(data.rawget(DEBUG_COMBAT_MARKER))) {
                fixtureCount++;
                log.append(" [fixture#").append(zombie.getID())
                        .append(" x=").append(zombie.getX())
                        .append(" y=").append(zombie.getY())
                        .append(" z=").append(zombie.getZ())
                        .append(" health=").append(zombie.getHealth())
                        .append(" dead=").append(zombie.isDead())
                        .append(" fake=").append(zombie.isFakeDead())
                        .append(" square=").append(zombie.getCurrentSquare() != null)
                        .append(" targetBody=").append(zombie.getTarget() == body)
                        .append("]");
            }
            double distance = Math.hypot(zombie.getX() - body.getX(),
                    zombie.getY() - body.getY());
            if (distance > MELEE_HUNT_RADIUS) continue;
            nearby++;
            if (nearby <= 8) {
                log.append(" [zombie#").append(zombie.getID())
                        .append(" d=").append(String.format("%.2f", distance))
                        .append(" z=").append(zombie.getZ())
                        .append(" health=").append(zombie.getHealth())
                        .append(" dead=").append(zombie.isDead())
                        .append(" fake=").append(zombie.isFakeDead())
                        .append(" square=").append(zombie.getCurrentSquare() != null)
                .append(" marker=").append(data != null
                                && Boolean.TRUE.equals(data.rawget(DEBUG_COMBAT_MARKER)))
                        .append("]");
            }
        }
        for (IsoMovingObject object : cell.getObjectList()) {
            if (!(object instanceof IsoZombie zombie)) continue;
            KahluaTable data = zombie.getModData();
            if (data == null || !actorId.equals(data.rawget(DEBUG_COMBAT_ACTOR))
                    || !Boolean.TRUE.equals(data.rawget(DEBUG_COMBAT_MARKER))) continue;
            fixtureCount++;
            log.append(" [objectFixture#").append(zombie.getID())
                    .append(" x=").append(zombie.getX())
                    .append(" y=").append(zombie.getY())
                    .append(" z=").append(zombie.getZ())
                    .append(" health=").append(zombie.getHealth())
                    .append(" dead=").append(zombie.isDead())
                    .append(" fake=").append(zombie.isFakeDead())
                    .append(" square=").append(zombie.getCurrentSquare() != null)
                    .append(" targetBody=").append(zombie.getTarget() == body)
                    .append("]");
        }
        log.append(" nearby=").append(nearby);
        log.append(" fixtureEntries=").append(fixtureCount);
        System.out.println(log);
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

    private static boolean guaranteeZombieDeath(Entry entry, IsoZombie target,
            HandWeapon weapon) {
        HumanSurvivor body = entry.body;
        try {
            if (weapon != null) target.Kill(body, weapon, true, null);
        } catch (Throwable error) {
            entry.lastFireError = error.getClass().getSimpleName() + ": " + error.getMessage();
        }
        // Kill() may set IsoZombie's dead flag before the normal corpse/death
        // notification path runs.  Calling die() only while !isDead() leaves
        // exactly the still-visible, still-targetable zombie reported by the
        // local test.  Always finish the standard death transition after the
        // real hit; the calls are individually guarded because B42 can reject
        // a second transition for an already-dead object.
        try { target.setHealth(0.0f); } catch (Throwable ignored) { }
        try { target.die(); } catch (Throwable error) {
            entry.lastFireError = error.getClass().getSimpleName() + ": " + error.getMessage();
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
        boolean hit = body.fireAt(target);
        String soundError = "";
        if (hit) {
            entry.shotsFired++;
            try {
                // The client-rendered human is outside the normal player
                // weapon action path. Broadcast the item's real rifle sound
                // from the server so every connected client can hear the
                // authoritative shot at the actor's world position.
                GameServer.PlayWorldSoundServer(body, "M14Shoot", false,
                        body.getCurrentSquare(), 1.0f, 170.0f, 30.0f, false);
            } catch (Throwable error) {
                soundError = error.getClass().getSimpleName()
                        + ": " + error.getMessage();
            }
        }
        entry.lastFireError = body.getLastFireError();
        if (!soundError.isBlank()) {
            entry.lastFireError = entry.lastFireError == null
                    || entry.lastFireError.isBlank()
                    ? "sound=" + soundError
                    : entry.lastFireError + "; sound=" + soundError;
        }
        // Preserve B42's Kill/die path before using a health fallback. The
        // fallback exists for this custom attacker because its bodyDamage is
        // intentionally absent from the unsafe vanilla NPC update loop.
        // Always run it after a shot.  Hit() can reduce health to zero without
        // entering the full server corpse/death notification path, leaving
        // the client with the shot sound and a still-visible zombie.
        boolean killed = guaranteeZombieDeath(entry, target, body.getFirearm());
        if (killed) {
            entry.zombiesKilled++;
            entry.lastKillId = zombieId(target);
            // Keep a real firing state in the next client snapshot.  The
            // counters and last_kill_id retain the result; combatStatus is a
            // presentation pulse so the client can enter B42's ranged state.
            entry.combatStatus = hit ? "firearm_attack" : "firearm_kill_fallback";
            entry.combatTarget = null;
        } else {
            entry.combatStatus = "firearm_attempt_failed";
        }
        if (hit) entry.firearmPoseUntil = now + FIREARM_POSE_NANOS;
        entry.nextShotAt = now + SHOT_INTERVAL_NANOS;
        body.ensureFirearm();
    }

    private static void meleeAt(Entry entry, IsoZombie target, long now) {
        HumanSurvivor body = entry.body;
        if (!body.ensureMeleeWeapon() || !body.hasReadyMeleeWeapon()) {
            entry.combatStatus = "melee_weapon_unavailable";
            entry.lastMeleeError = "Base.BaseballBat could not be equipped";
            return;
        }
        entry.meleeAttacks++;
        entry.combatStatus = "melee_attack";
        boolean hit = body.meleeAt(target);
        entry.lastMeleeError = body.getLastMeleeError();
        boolean killed = target.isDead() || !target.isAlive();
        // The custom human intentionally does not enter vanilla body-damage
        // update phases. Preserve the engine kill path, then use the same
        // bounded health fallback as firearm combat if Hit only produced a
        // non-lethal animation/result.
        if (!killed && hit) {
            killed = guaranteeZombieDeath(entry, target, body.getMeleeWeapon());
        }
        if (killed) {
            entry.meleeKills++;
            entry.lastKillId = zombieId(target);
            entry.combatStatus = hit ? "melee_kill" : "melee_kill_fallback";
            entry.combatTarget = null;
        } else {
            entry.combatStatus = "melee_attempt_failed";
        }
        entry.nextMeleeAt = now + MELEE_INTERVAL_NANOS;
    }

    private static boolean hasMovingObject(IsoGridSquare square) {
        if (square == null || square.getMovingObjects() == null) return true;
        return !square.getMovingObjects().isEmpty();
    }

    private static IsoGridSquare debugSquareNear(IsoCell cell,
            float anchorX, float anchorY, float anchorZ,
            int minimumRadius, int maximumRadius) {
        if (cell == null) return null;
        int originX = (int)Math.floor(anchorX);
        int originY = (int)Math.floor(anchorY);
        int floor = (int)Math.floor(anchorZ);
        // Use a deterministic ring inside the normal HUNT radius. The
        // fixture is an ordinary zombie, never a surrogate survivor body.
        for (int radius = minimumRadius; radius <= maximumRadius; radius++) {
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

    private static IsoGridSquare debugCombatSquare(IsoCell cell, HumanSurvivor body) {
        if (body == null) return null;
        return debugSquareNear(cell, body.getX(), body.getY(), body.getZ(), 6, 12);
    }

    private static IsoGridSquare debugObservationSquare(IsoCell cell, HumanSurvivor body) {
        if (body == null) return null;
        float anchorX = body.getX();
        float anchorY = body.getY();
        float anchorZ = body.getZ();
        // The observation fixture should be in the local player's camera,
        // not merely near a survivor that may be separated by formation
        // spacing. Fall back to the Goblin position if the player list is not
        // available during a reconnect.
        try {
            for (IsoPlayer player : GameServer.getPlayers()) {
                if (player != null && player.getCell() == cell) {
                    anchorX = player.getX();
                    anchorY = player.getY();
                    anchorZ = player.getZ();
                    break;
                }
            }
        } catch (Throwable ignored) { }
        IsoGridSquare nearby = debugSquareNear(cell, anchorX, anchorY, anchorZ, 1, 8);
        return nearby != null ? nearby : debugCombatSquare(cell, body);
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
        return debugSpawnHostileZombie(actorId, false);
    }

    /** Spawn a nearby fixture without starting combat, for visual testing. */
    public static boolean debugSpawnHostileZombieForObservation(String actorId) {
        return debugSpawnHostileZombie(actorId, true);
    }

    private static boolean debugSpawnHostileZombie(String actorId, boolean observationOnly) {
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
        IsoGridSquare square = observationOnly
                ? debugObservationSquare(cell, entry.body)
                : debugCombatSquare(cell, entry.body);
        VirtualZombieManager manager = VirtualZombieManager.instance;
        if (square == null || manager == null) return false;
        IsoZombie zombie = null;
        try {
            // Build 42's coordinate-based immediate factory performs the
            // complete real-zombie registration path.  The older choices
            // overload can return an initialized object without retaining it
            // in the active cell on a dedicated server, where it disappears
            // before either the client or this authority can observe it.
            zombie = manager.createRealZombieNow(
                    square.getX() + 0.5f, square.getY() + 0.5f, square.getZ());
        } catch (Throwable error) {
            entry.lastFireError = error.getClass().getSimpleName() + ": " + error.getMessage();
        }
        if (zombie == null) return false;
        KahluaTable data = zombie.getModData();
        if (data != null) {
            data.rawset(DEBUG_COMBAT_MARKER, true);
            data.rawset(DEBUG_COMBAT_ACTOR, actorId);
        }
        // The choices-based factory can return a fully initialized zombie
        // before it has inserted the object into the active cell on a
        // dedicated B42 server.  Do the final world registration explicitly
        // when needed; otherwise the fixture vanishes on the next tick and
        // can never be selected by authoritative combat.
        if (!containsObject(cell, zombie)) {
            try {
                zombie.setX(square.getX() + 0.5f);
                zombie.setY(square.getY() + 0.5f);
                zombie.setZ(square.getZ());
                zombie.setCurrentSquare(square);
                zombie.setMovingSquare(square);
                zombie.addToWorld();
            } catch (Throwable error) {
                entry.lastFireError = error.getClass().getSimpleName()
                        + ": " + error.getMessage();
            }
        }
        if (!containsObject(cell, zombie)) {
            entry.lastFireError = "combat fixture was not registered in the active cell";
            return false;
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
        // A disconnected worker's durable cargo is materialized on the first
        // server tick after a player returns.  It is intentionally separate
        // from the body inventory so a world unload or body recreation cannot
        // duplicate or discard the saved haul.
        deliverPendingCargo(state, cell, body);
        body.ensureGodMode();
        String controlMode = text(state, "control_mode", "HOLD").toUpperCase();
        String task = text(state, "task", "").toUpperCase();
        String combatMode = text(state, "combat_mode", "HUNT").toUpperCase();
        if (entry.recoveryVehicle != null && !vehicleRecoveryEnabled(state)) {
            clearVehicleRecovery(entry, true);
            entry.vehicleStatus = "vehicle_cancelled";
            entry.vehicleError = "recovery disabled by command";
        }
        if ("BUILDER".equals(text(state, "job", "").toUpperCase())
                && !Boolean.TRUE.equals(state.rawget("builder_commanded"))) {
            entry.workStatus = "waiting_for_build_command";
        }
        // Protection is an always-on responsibility for managed survivors.  A
        // task such as FOLLOW or JOB is resumed when no hostile is nearby;
        // combat_mode=OFF remains the explicit escape hatch for diagnostics.
        boolean hostileToZombies = !Boolean.FALSE.equals(state.rawget("hostile_to_zombies"));
        boolean combatActive = hostileToZombies && !"OFF".equals(combatMode);
        if (combatActive && "MELEE".equals(combatMode)) body.ensureMeleeWeapon();
        else body.ensureFirearm();
        serviceIncomingDamage(entry, cell, now);
        if (!body.isAlive()) {
            scheduleDeath(entry, now);
            writeState(entry, state, false, "dead_waiting_recreate", now);
            entry.lastStep = now;
            return true;
        }

        WorldAnchor group = groupAnchor(cell, state);
        if (group != null) {
            double groupDistance = Math.hypot(group.x - body.getX(), group.y - body.getY());
            state.rawset("group_distance", groupDistance);
            double leash = GROUP_LEASH_RADIUS;
            if (Boolean.TRUE.equals(state.rawget("player_search_enabled"))) {
                leash = PLAYER_SEARCH_LEASH_RADIUS;
            } else if ("JOB".equals(controlMode)
                    && "OUTBOUND".equals(text(state, "expedition_phase", "OUTBOUND").toUpperCase())) {
                leash = EXPEDITION_LEASH_RADIUS;
            }
            if (entry.recoveryVehicle != null) leash = VEHICLE_LEASH_RADIUS;
            if (shouldEnforceGroupLeash(controlMode)
                    && groupDistance > leash) {
                moveTo(entry, cell, state, group.x, group.y, group.z,
                        GROUP_RETURN_STOP_DISTANCE, now, true);
                entry.combatTarget = null;
                entry.combatStatus = "returning_to_group";
                state.rawset("navigation_status", "group_return");
                writeState(entry, state, true, "present", now);
                entry.lastStep = now;
                return true;
            }
        } else {
            state.rawset("group_distance", null);
        }

        // A firearm result is authoritative immediately, but the client
        // needs a short replicated window to enter and display the B42 ranged
        // animation.  Hold this status before scanning for the next target;
        // otherwise the next server tick overwrites it with aiming/scanning
        // before the 500 ms snapshot broadcaster can deliver it.
        if (now < entry.firearmPoseUntil) {
            body.setMovementMode(false, false);
            state.rawset("running", false);
            state.rawset("movement_blocked", false);
            state.rawset("navigation_status", "firing");
            state.rawset("route_remaining", 0.0);
            entry.combatStatus = "firearm_attack";
            writeState(entry, state, true, "present", now);
            entry.lastStep = now;
            return true;
        }

        boolean meleeMode = combatActive && "MELEE".equals(combatMode);
        double radius = !combatActive || "OFF".equals(combatMode)
                || (!meleeMode && !body.hasReadyFirearm())
                || (meleeMode && !body.hasReadyMeleeWeapon()) ? 0.0
                : (meleeMode ? MELEE_HUNT_RADIUS
                        : ("DEFEND".equals(combatMode) ? DEFEND_RADIUS : HUNT_RADIUS));
        IsoZombie hostile = radius > 0.0
                ? nearestHostile(cell, body, radius, state) : null;
        if (hostile != null) {
            entry.combatTarget = hostile;
            double distance = Math.hypot(hostile.getX() - body.getX(),
                    hostile.getY() - body.getY());
            if (meleeMode && distance > MELEE_RANGE) {
                moveTo(entry, cell, state, hostile.getX(), hostile.getY(),
                        hostile.getZ(), MELEE_STOP_DISTANCE, now, true);
                entry.combatStatus = "closing_on_zombie";
            } else if (!meleeMode && distance > FIREARM_RANGE) {
                moveTo(entry, cell, state, hostile.getX(), hostile.getY(),
                        hostile.getZ(), FIREARM_STOP_DISTANCE, now, true);
                entry.combatStatus = "closing_on_zombie";
            } else if (meleeMode && now >= entry.nextMeleeAt) {
                body.setMovementMode(false, false);
                state.rawset("running", false);
                state.rawset("movement_blocked", false);
                state.rawset("navigation_status", "melee_range");
                state.rawset("route_remaining", 0.0);
                meleeAt(entry, hostile, now);
            } else if (!meleeMode && now >= entry.nextShotAt) {
                body.setMovementMode(false, false);
                state.rawset("running", false);
                state.rawset("movement_blocked", false);
                state.rawset("navigation_status", "combat_range");
                state.rawset("route_remaining", 0.0);
                fireAt(entry, hostile, now);
            } else {
                body.setMovementMode(false, false);
                state.rawset("running", false);
                state.rawset("movement_blocked", false);
                state.rawset("navigation_status", meleeMode ? "melee_ready" : "aiming");
                state.rawset("route_remaining", 0.0);
                entry.combatStatus = meleeMode ? "melee_ready" : "aiming";
            }
        } else {
            entry.combatTarget = null;
            entry.combatStatus = meleeMode
                    ? "no_hostile_in_melee_radius"
                    : (combatActive && "ATTACK".equals(task)
                            ? "no_hostile_in_hunt_radius" : "scanning");
            if (meleeMode) debugCombatDiagnostics(entry, cell, body, now);
            boolean vehicleHandled = entry.recoveryVehicle != null;
            if (vehicleHandled) {
                serviceVehicleRecovery(entry, cell, state, now);
            } else if (target != null && !"COMBAT".equals(controlMode)) {
                moveTo(entry, cell, state, number(target, "x"), number(target, "y"),
                        number(target, "z"),
                        Double.isFinite(stopDistance) ? Math.max(0.0, stopDistance) : 0.0,
                        now, false);
            } else {
                body.setMovementMode(false, false);
                state.rawset("running", false);
                state.rawset("movement_blocked", false);
                state.rawset("navigation_status", "holding");
                state.rawset("route_remaining", 0.0);
            }
            if (!vehicleHandled && "JOB".equals(controlMode) && atWorkStation(body, target)) {
                serviceWork(entry, cell, state, target, now);
            }
        }
        writeState(entry, state, true, "present", now);
        entry.lastStep = now;
        return true;
    }
}

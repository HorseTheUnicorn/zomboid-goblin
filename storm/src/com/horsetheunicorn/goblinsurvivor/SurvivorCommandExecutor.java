package com.horsetheunicorn.goblinsurvivor;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import se.krka.kahlua.j2se.KahluaTableImpl;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.characters.IsoPlayer;
import zombie.network.GameServer;

/**
 * Final semantic admission point and bounded goal submitter for remote NPC
 * commands.  The executor only writes a semantic goal into the server-owned
 * state table; ServerSurvivorAuthority.step remains the sole native-body
 * movement/combat executor.  No bridge field can name a PZ method, Lua chunk,
 * shell command, or exact location for the external agent.
 */
public final class SurvivorCommandExecutor {
    private static final int MAX_SEEN_REQUESTS = 2048;
    private static final long REQUEST_RETENTION_MS = 300_000L;
    private static final Object REQUEST_LOCK = new Object();
    private static final LinkedHashMap<String, Long> SEEN_REQUESTS = new LinkedHashMap<>();

    private SurvivorCommandExecutor() { }

    public static boolean validate(KahluaTable message) {
        return RemoteCommandConsumer.validate(message);
    }

    public static String rejectReason(KahluaTable message) {
        return RemoteCommandConsumer.rejectReason(message);
    }

    public static String normalizeAction(String action) {
        return RemoteCommandConsumer.normalizeAction(action);
    }

    private static KahluaTable newTable() {
        if (LuaManager.platform != null) return LuaManager.platform.newTable();
        return new KahluaTableImpl(new java.util.HashMap<>());
    }

    private static String text(Object value) {
        return value instanceof String text && !text.isBlank() ? text : null;
    }

    private static Double number(KahluaTable table, String key) {
        if (table == null) return null;
        Object value = table.rawget(key);
        if (!(value instanceof Number number) || !Double.isFinite(number.doubleValue())) return null;
        return number.doubleValue();
    }

    private static void clearVehicleState(KahluaTable state) {
        state.rawset("vehicle_recovery_enabled", false);
        state.rawset("vehicle_status", "cancelled");
        state.rawset("vehicle_error", null);
        state.rawset("vehicle_id", null);
        state.rawset("vehicle_engine_running", false);
        state.rawset("vehicle_target_x", null);
        state.rawset("vehicle_target_y", null);
        state.rawset("vehicle_target_z", null);
    }

    private static void clearTarget(KahluaTable state) {
        state.rawset("target_username", null);
        state.rawset("follow_username", null);
        state.rawset("target_actor_id", null);
        state.rawset("destination", null);
        state.rawset("arrival_task", null);
    }

    private static void recordGoal(KahluaTable state, String action, String requestId) {
        state.rawset("java_goal_action", action);
        state.rawset("java_goal_request_id", requestId);
        state.rawset("java_goal_status", "ACCEPTED");
        state.rawset("server_timestamp_ms", (double)System.currentTimeMillis());
    }

    private static String handled(KahluaTable state, String action,
            String requestId, String detail) {
        recordGoal(state, action, requestId);
        return "HANDLED:" + detail;
    }

    private static String delegated(String action, String requestId,
            KahluaTable state) {
        recordGoal(state, action, requestId);
        state.rawset("java_goal_status", "DELEGATED_TO_LUA_RESOLVER");
        return "DELEGATE";
    }

    private static KahluaTable target(KahluaTable message) {
        Object raw = message.rawget("target");
        return raw instanceof KahluaTable table ? table : null;
    }

    private static String targetKind(KahluaTable message) {
        KahluaTable target = target(message);
        String kind = text(target == null ? null : target.rawget("kind"));
        return kind == null ? "" : kind.toLowerCase(Locale.ROOT);
    }

    private static String targetLabel(KahluaTable message) {
        KahluaTable target = target(message);
        if (target == null) return null;
        String label = text(target.rawget("name"));
        if (label == null) label = text(target.rawget("label"));
        if (label == null) label = text(target.rawget("player"));
        return label;
    }

    private static IsoPlayer resolvePlayer(String requested) {
        if (!GameServer.server || requested == null) return null;
        String wanted = requested.toLowerCase(Locale.ROOT);
        String bare = wanted.startsWith("player.") ? wanted.substring(7) : wanted;
        for (IsoPlayer player : GameServer.getPlayers()) {
            if (player == null || player.getUsername() == null) continue;
            String username = player.getUsername();
            String normalized = username.toLowerCase(Locale.ROOT);
            if (normalized.equals(wanted) || normalized.equals(bare)
                    || ("player." + normalized).equals(wanted)) return player;
        }
        return null;
    }

    private static KahluaTable point(double x, double y, double z) {
        KahluaTable result = newTable();
        result.rawset("x", x);
        result.rawset("y", y);
        result.rawset("z", z);
        return result;
    }

    private static KahluaTable pointFromState(KahluaTable state) {
        Double x = number(state, "x");
        Double y = number(state, "y");
        Double z = number(state, "z");
        return x == null || y == null || z == null ? null : point(x, y, z);
    }

    private static KahluaTable homePoint(KahluaTable state) {
        Double x = number(state, "home_x");
        Double y = number(state, "home_y");
        Double z = number(state, "home_z");
        if (x == null || y == null || z == null) {
            x = number(state, "protection_base_x");
            y = number(state, "protection_base_y");
            z = number(state, "protection_base_z");
        }
        return x == null || y == null || z == null ? null : point(x, y, z);
    }

    private static KahluaTable resolvePoint(KahluaTable message, KahluaTable state) {
        String kind = targetKind(message);
        String label = targetLabel(message);
        if ("player".equals(kind)) {
            IsoPlayer player = resolvePlayer(label);
            return player == null ? null : point(player.getX(), player.getY(), player.getZ());
        }
        if ("current_position".equals(kind)) return pointFromState(state);
        if ("home_base".equals(kind) || "base".equals(kind)) return homePoint(state);
        if ("goblin".equals(kind)
                && AgentPerception.LEADER_ID.equals(text(state.rawget("actor_id")))) {
            return pointFromState(state);
        }
        return null;
    }

    private static void setHold(KahluaTable state, String action) {
        state.rawset("control_mode", "HOLD");
        state.rawset("task", action);
        state.rawset("mode", "PARTY");
        clearTarget(state);
        state.rawset("builder_commanded", false);
        state.rawset("job", null);
        state.rawset("expedition_phase", "FOLLOW");
        state.rawset("expedition_target", null);
        state.rawset("auto_expedition", false);
        state.rawset("return_to_follow", false);
        clearVehicleState(state);
        state.rawset("movement_mode", "AUTO");
        state.rawset("running", false);
        state.rawset("combat_mode", "HUNT");
        state.rawset("manual_control", true);
        KahluaTable current = pointFromState(state);
        if (current != null) {
            state.rawset("hold_x", current.rawget("x"));
            state.rawset("hold_y", current.rawget("y"));
            state.rawset("hold_z", current.rawget("z"));
        }
        state.rawset("work_status", "paused");
    }

    private static void setFollowPlayer(KahluaTable state, String action,
            IsoPlayer player) {
        String username = player.getUsername();
        state.rawset("control_mode", "FOLLOW");
        state.rawset("task", action);
        state.rawset("mode", "PARTY");
        state.rawset("target_username", username);
        state.rawset("follow_username", username);
        state.rawset("target_actor_id", null);
        state.rawset("destination", null);
        state.rawset("arrival_task", null);
        state.rawset("builder_commanded", false);
        state.rawset("job", null);
        state.rawset("expedition_phase", "FOLLOW");
        state.rawset("expedition_target", null);
        state.rawset("auto_expedition", false);
        state.rawset("return_to_follow", false);
        clearVehicleState(state);
        state.rawset("movement_mode", "AUTO");
        state.rawset("running", false);
        state.rawset("combat_mode", "HUNT");
        state.rawset("manual_control", true);
        state.rawset("work_status", "following");
    }

    private static void setFollowGoblin(KahluaTable state, String action) {
        state.rawset("control_mode", "FOLLOW_ACTOR");
        state.rawset("task", action);
        state.rawset("mode", "PARTY");
        state.rawset("target_username", null);
        state.rawset("follow_username", null);
        state.rawset("target_actor_id", AgentPerception.LEADER_ID);
        state.rawset("destination", null);
        state.rawset("arrival_task", null);
        state.rawset("builder_commanded", false);
        state.rawset("job", null);
        state.rawset("expedition_phase", "FOLLOW");
        state.rawset("expedition_target", null);
        state.rawset("auto_expedition", false);
        state.rawset("return_to_follow", false);
        clearVehicleState(state);
        state.rawset("movement_mode", "AUTO");
        state.rawset("running", false);
        state.rawset("combat_mode", "HUNT");
        state.rawset("manual_control", true);
        state.rawset("work_status", "squad_follow");
    }

    private static void setDestination(KahluaTable state, String action,
            KahluaTable destination) {
        setDestination(state, action, destination, "PARTY", null);
    }

    private static void setDestination(KahluaTable state, String action,
            KahluaTable destination, String mode, String arrivalTask) {
        state.rawset("control_mode", "MOVE");
        state.rawset("task", action);
        state.rawset("mode", mode);
        clearTarget(state);
        state.rawset("destination", destination);
        state.rawset("arrival_task", arrivalTask);
        state.rawset("builder_commanded", false);
        clearVehicleState(state);
        state.rawset("movement_mode", "AUTO");
        state.rawset("running", false);
        state.rawset("combat_mode", "HUNT");
        state.rawset("manual_control", true);
        state.rawset("work_status", "moving");
    }

    private static boolean rememberRequest(String requestId, long now) {
        synchronized (REQUEST_LOCK) {
            if (SEEN_REQUESTS.containsKey(requestId)) return false;
            Iterator<Map.Entry<String, Long>> iterator = SEEN_REQUESTS.entrySet().iterator();
            while (iterator.hasNext()) {
                Map.Entry<String, Long> entry = iterator.next();
                if (now - entry.getValue() > REQUEST_RETENTION_MS) iterator.remove();
            }
            while (SEEN_REQUESTS.size() >= MAX_SEEN_REQUESTS) {
                iterator = SEEN_REQUESTS.entrySet().iterator();
                if (!iterator.hasNext()) break;
                iterator.next();
                iterator.remove();
            }
            SEEN_REQUESTS.put(requestId, now);
            return true;
        }
    }

    /**
     * Validate, deduplicate, and submit a semantic goal for one server-owned
     * survivor.  "DELEGATE" means the existing Lua server adapter owns a
     * resolver that still needs roster/base context; it is not a bypass of
     * validation and it never exposes a native PZ call to the bridge.
     */
    public static String execute(KahluaTable message, KahluaTable state) {
        String rejection = RemoteCommandConsumer.rejectReason(message);
        if (rejection != null) return "REJECTED:" + rejection;
        if (!GameServer.server) return "REJECTED:server authority is unavailable";
        if (state == null) return "REJECTED:survivor state is unavailable";
        String messageId = text(message.rawget("npc_id"));
        String stateId = text(state.rawget("actor_id"));
        if (messageId == null || !messageId.equals(stateId)) {
            return "REJECTED:logical survivor id does not match the server state";
        }
        String requestId = text(message.rawget("request_id"));
        if (requestId == null || !rememberRequest(requestId, System.currentTimeMillis())) {
            return "DUPLICATE:request id was already consumed";
        }
        String action = normalizeAction(text(message.rawget("action")));
        if (action == null) return "REJECTED:missing action";

        if ("NOOP".equals(action)) {
            return handled(state, action, requestId, "semantic no-op accepted");
        }
        if ("HOLD_POSITION".equals(action) || "REST".equals(action)) {
            setHold(state, action);
            return handled(state, action, requestId, "survivor is holding position");
        }
        if ("FOLLOW".equals(action) || "JOIN_PARTY".equals(action)
                || "DEFEND_PLAYER".equals(action)) {
            if (!"player".equals(targetKind(message))) return delegated(action, requestId, state);
            IsoPlayer player = resolvePlayer(targetLabel(message));
            if (player == null) return "REJECTED:target player is not online";
            setFollowPlayer(state, action, player);
            return handled(state, action, requestId, "survivor is following " + player.getUsername());
        }
        if ("FOLLOW_GOBLIN".equals(action)) {
            if (!"goblin".equals(targetKind(message))) return delegated(action, requestId, state);
            if (AgentPerception.LEADER_ID.equals(stateId)) {
                return "REJECTED:Goblin cannot follow itself";
            }
            if (!AgentPerception.LEADER_ID.equalsIgnoreCase(targetLabel(message))) {
                return "REJECTED:FOLLOW_GOBLIN requires goblin.primary";
            }
            setFollowGoblin(state, action);
            return handled(state, action, requestId, "survivor is following Goblin");
        }
        if ("MOVE_TO".equals(action) || "REGROUP".equals(action)) {
            KahluaTable destination = resolvePoint(message, state);
            if (destination == null) return delegated(action, requestId, state);
            setDestination(state, action, destination);
            return handled(state, action, requestId, "survivor accepted a semantic movement goal");
        }
        if ("RETURN_TO_BASE".equals(action) || "GO_HOME".equals(action)) {
            KahluaTable destination = homePoint(state);
            if (destination == null) return delegated(action, requestId, state);
            setDestination(state, action, destination);
            return handled(state, action, requestId, "survivor accepted the anchored home goal");
        }
        if ("RETREAT".equals(action) || "FLEE".equals(action)) {
            KahluaTable destination = homePoint(state);
            if (destination == null) return delegated(action, requestId, state);
            setDestination(state, action, destination, "SAFE", action);
            return handled(state, action, requestId, "survivor accepted the anchored safe goal");
        }
        // Speech transport, squad resolution, jobs, base resolution, and
        // area labels remain in the established Lua adapter until their Java
        // world-context counterparts are individually verified.
        return delegated(action, requestId, state);
    }
}

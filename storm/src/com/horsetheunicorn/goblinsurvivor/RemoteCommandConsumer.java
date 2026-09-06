package com.horsetheunicorn.goblinsurvivor;

import java.util.Set;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableIterator;

/** Semantic validation for commands arriving from the .76 bridge. */
public final class RemoteCommandConsumer {
    private static final Set<String> ACTIONS = Set.of(
            "NOOP", "SAY", "FOLLOW_PLAYER", "FOLLOW_GOBLIN", "HOLD",
            "REGROUP", "RETURN_HOME", "DEFEND_PLAYER", "RETREAT",
            "LOOT_AREA", "SCAVENGE_AREA", "FORM_SQUAD", "DISMISS_SQUAD",
            "ASSIGN_JOB", "SECURE_BASE",
            // Internal names are retained for deterministic reflexes and
            // older bridge producers.  The public Qwen capability list above
            // remains deliberately smaller than this compatibility set.
            "FOLLOW", "HOLD_POSITION", "RETURN_TO_BASE", "SCAVENGE",
            "MOVE_TO", "SEARCH", "FLEE", "GO_HOME", "ATTACK",
            "MELEE_ATTACK", "REST", "DEFEND_AREA", "GUARD", "PATROL",
            "CLEAR_BUILDING", "JOIN_PARTY", "LEAVE_PARTY", "SET_MOVEMENT",
            "SET_VEHICLE_RECOVERY", "ENTER_VEHICLE", "EXIT_VEHICLE", "EAT",
            "DRINK", "BANDAGE", "RELOAD", "CLAIM_REWARD",
            "DEBUG_KILL", "DEBUG_SPAWN_ZOMBIE");
    private static final Set<String> TARGET_KINDS = Set.of(
            "player", "goblin", "home_base", "base", "escape_route",
            "current_position", "area", "nearby_threat", "squad", "vehicle");
    private static final Set<String> FORBIDDEN_KEYS = Set.of(
            "x", "y", "z", "coord", "coords", "coordinates", "route",
            "cell", "chunk", "path", "paths", "lua", "shell", "code",
            "exec", "eval", "raw", "packet", "teleport");

    private RemoteCommandConsumer() { }

    public static String normalizeAction(String action) {
        if (action == null) return null;
        return switch (action.toUpperCase(java.util.Locale.ROOT)) {
            case "FOLLOW_PLAYER" -> "FOLLOW";
            case "HOLD" -> "HOLD_POSITION";
            case "RETURN_HOME" -> "RETURN_TO_BASE";
            case "SCAVENGE_AREA" -> "SCAVENGE";
            default -> action.toUpperCase(java.util.Locale.ROOT);
        };
    }

    private static boolean safeText(Object value, int max) {
        if (!(value instanceof String text) || text.isBlank() || text.length() > max) return false;
        String lower = text.toLowerCase(java.util.Locale.ROOT);
        return !lower.contains("coordinates") && !lower.matches(".*\\b[xyz]\\s*[:=].*");
    }

    private static boolean safeId(Object value) {
        return safeText(value, 96) && ((String)value).matches("[A-Za-z0-9][A-Za-z0-9._:-]{0,95}");
    }

    private static boolean forbiddenKey(Object key) {
        return key instanceof String text
                && FORBIDDEN_KEYS.contains(text.toLowerCase(java.util.Locale.ROOT));
    }

    private static boolean validTarget(Object raw) {
        if (!(raw instanceof KahluaTable target)) return false;
        Object rawKind = target.rawget("kind");
        Object label = target.rawget("name");
        if (label == null) label = target.rawget("label");
        if (label == null) label = target.rawget("player");
        return rawKind instanceof String kind
                && TARGET_KINDS.contains(kind.toLowerCase(java.util.Locale.ROOT))
                && safeText(label, 96);
    }

    /** Return null when a bridge command is semantically safe to inspect. */
    public static String rejectReason(KahluaTable message) {
        if (message == null) return "command is not a table";
        KahluaTableIterator iterator = message.iterator();
        while (iterator != null && iterator.advance()) {
            if (forbiddenKey(iterator.getKey())) return "command contains a forbidden field";
        }
        if (!(message.rawget("npc_id") instanceof String npcId)
                || !safeId(npcId)) return "invalid logical survivor id";
        Object rawAction = message.rawget("action");
        if (!(rawAction instanceof String actionText)) return "missing action";
        String action = actionText.toUpperCase(java.util.Locale.ROOT);
        if (!ACTIONS.contains(action)) return "unsupported commander action";
        Object priority = message.rawget("priority");
        if (!(priority instanceof Number number) || number.doubleValue() < 0
                || number.doubleValue() > 3 || Math.floor(number.doubleValue()) != number.doubleValue()) {
            return "invalid command priority";
        }
        if (message.rawget("reason") != null && !safeText(message.rawget("reason"), 240)) {
            return "invalid command reason";
        }
        if (message.rawget("text") != null && !safeText(message.rawget("text"), 240)) {
            return "invalid command text";
        }
        if ("SAY".equals(action) && message.rawget("text") == null) return "SAY requires text";
        if (message.rawget("target") != null && !validTarget(message.rawget("target"))) {
            return "invalid semantic target";
        }
        if ("FOLLOW".equals(action) || "FOLLOW_PLAYER".equals(action)
                || "FOLLOW_GOBLIN".equals(action)
                || "RETURN_TO_BASE".equals(action) || "RETURN_HOME".equals(action)
                || "REGROUP".equals(action)
                || "LOOT_AREA".equals(action) || "SCAVENGE".equals(action)
                || "SCAVENGE_AREA".equals(action) || "RETREAT".equals(action)
                || "DEFEND_PLAYER".equals(action)) {
            if (message.rawget("target") == null) return "movement command needs a target";
        }
        if ("ASSIGN_JOB".equals(action) && AgentPerception.LEADER_ID.equals(npcId)) {
            return "Goblin is the permanent survivor leader";
        }
        if (message.rawget("members") != null) {
            Object rawMembers = message.rawget("members");
            if (!(rawMembers instanceof KahluaTable members) || members.len() > 16) {
                return "invalid squad member list";
            }
            KahluaTableIterator membersIterator = members.iterator();
            while (membersIterator != null && membersIterator.advance()) {
                if (!safeId(membersIterator.getValue())) return "invalid squad member id";
            }
        }
        return null;
    }

    public static boolean validate(KahluaTable message) {
        return rejectReason(message) == null;
    }
}

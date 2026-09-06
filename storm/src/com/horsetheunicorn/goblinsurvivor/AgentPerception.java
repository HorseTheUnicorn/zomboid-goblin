package com.horsetheunicorn.goblinsurvivor;

import java.util.List;
import se.krka.kahlua.j2se.KahluaTableImpl;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableIterator;
import zombie.Lua.LuaManager;

/**
 * Bounded semantic state made available to the external Goblin commander.
 *
 * The exact world state remains inside the Java/Lua server authority and the
 * separate tracker channel.  This DTO copies only logical identities and
 * coarse status; it never copies x/y/z, routes, cells, chunks, or native
 * object references into the model-facing table.
 */
public final class AgentPerception {
    public static final String LEADER_ID = "goblin.primary";
    private static final List<String> CAPABILITIES = List.of(
            "NOOP", "SAY", "FOLLOW_PLAYER", "FOLLOW_GOBLIN", "HOLD",
            "REGROUP", "RETURN_HOME", "DEFEND_PLAYER", "RETREAT",
            "LOOT_AREA", "SCAVENGE_AREA", "FORM_SQUAD", "DISMISS_SQUAD",
            "ASSIGN_JOB", "SECURE_BASE");

    private AgentPerception() { }

    private static KahluaTable newTable() {
        if (LuaManager.platform != null) return LuaManager.platform.newTable();
        return new KahluaTableImpl(new java.util.HashMap<>());
    }

    private static String text(Object value, int max) {
        if (!(value instanceof String valueText) || valueText.isBlank()
                || valueText.length() > max) return null;
        return valueText;
    }

    private static boolean bool(Object value, boolean fallback) {
        return value instanceof Boolean result ? result : fallback;
    }

    private static String condition(Object rawHealth) {
        if (!(rawHealth instanceof Number number)) return "unknown";
        double health = number.doubleValue();
        return health < 25.0 ? "critical" : health < 70.0 ? "hurt" : "good";
    }

    private static void copyText(KahluaTable source, KahluaTable target,
            String key, int max) {
        String value = text(source.rawget(key), max);
        if (value != null) target.rawset(key, value);
    }

    private static void copyLogicalRoster(Object raw, KahluaTable output,
            boolean playerRoster) {
        if (!(raw instanceof KahluaTable input)) return;
        int outputIndex = 1;
        KahluaTableIterator iterator = input.iterator();
        while (iterator != null && iterator.advance() && outputIndex <= (playerRoster ? 16 : 32)) {
            Object value = iterator.getValue();
            if (!(value instanceof KahluaTable item)) continue;
            String id = text(item.rawget(playerRoster ? "id" : "npc_id"), 96);
            if (id == null && !playerRoster) id = text(item.rawget("id"), 96);
            if (id == null) continue;
            KahluaTable clean = newTable();
            clean.rawset("id", playerRoster ? canonicalPlayerId(id) : id);
            copyText(item, clean, "name", 48);
            copyText(item, clean, "role", 32);
            copyText(item, clean, "job", 32);
            copyText(item, clean, "task", 48);
            copyText(item, clean, "work_status", 64);
            copyText(item, clean, "expedition_phase", 32);
            for (String key : new String[] {"online", "alive", "active",
                    "body_present", "control_ready", "running"}) {
                Object flag = item.rawget(key);
                if (flag instanceof Boolean) clean.rawset(key, flag);
            }
            output.rawset(outputIndex++, clean);
        }
    }

    private static String canonicalPlayerId(String value) {
        String lower = value.toLowerCase(java.util.Locale.ROOT);
        if (lower.startsWith("player.")) return lower.substring(0, Math.min(96, lower.length()));
        return "player." + lower.substring(0, Math.min(89, lower.length()));
    }

    private static void copySquads(Object raw, KahluaTable output) {
        if (!(raw instanceof KahluaTable input)) return;
        int outputIndex = 1;
        KahluaTableIterator iterator = input.iterator();
        while (iterator != null && iterator.advance() && outputIndex <= 8) {
            Object value = iterator.getValue();
            if (!(value instanceof KahluaTable item)) continue;
            String id = text(item.rawget("squad_id"), 96);
            if (id == null) id = text(item.rawget("id"), 96);
            if (id == null) continue;
            KahluaTable clean = newTable();
            clean.rawset("id", id);
            copyText(item, clean, "leader", 96);
            copyText(item, clean, "mission", 96);
            output.rawset(outputIndex++, clean);
        }
    }

    /** Return the capability list in a Lua-compatible array table. */
    public static KahluaTable capabilities() {
        KahluaTable result = newTable();
        int index = 1;
        for (String capability : CAPABILITIES) result.rawset(index++, capability);
        return result;
    }

    /** Build a semantic perception table from a server-owned state table. */
    public static KahluaTable semanticState(KahluaTable state) {
        KahluaTable result = newTable();
        if (state == null) return result;
        result.rawset("version", 1.0);

        String actorId = text(state.rawget("actor_id"), 96);
        if (actorId == null) actorId = LEADER_ID;
        KahluaTable self = newTable();
        self.rawset("id", actorId);
        self.rawset("leader_id", LEADER_ID);
        self.rawset("command_role", LEADER_ID.equals(actorId) ? "LEADER" : "COMPANION");
        self.rawset("alive", bool(state.rawget("alive"), false));
        self.rawset("body_present", bool(state.rawget("body_present"), false));
        for (String key : new String[] {"control_ready", "npc_engine_ready",
                "weapon_ready", "running"}) {
            Object value = state.rawget(key);
            if (value instanceof Boolean) self.rawset(key, value);
        }
        copyText(state, self, "display_name", 48);
        copyText(state, self, "name", 48);
        copyText(state, self, "mode", 16);
        copyText(state, self, "task", 48);
        copyText(state, self, "job", 32);
        copyText(state, self, "combat_status", 64);
        copyText(state, self, "work_status", 64);
        copyText(state, self, "expedition_phase", 32);
        copyText(state, self, "firearm_type", 64);
        self.rawset("condition", condition(state.rawget("health")));
        result.rawset("self", self);

        KahluaTable players = newTable();
        copyLogicalRoster(state.rawget("nearby_players"), players, true);
        result.rawset("players", players);
        KahluaTable survivors = newTable();
        copyLogicalRoster(state.rawget("npcs"), survivors, false);
        result.rawset("survivors", survivors);
        KahluaTable squads = newTable();
        copySquads(state.rawget("squads"), squads);
        result.rawset("squads", squads);

        KahluaTable base = newTable();
        base.rawset("id", "base.primary");
        copyText(state, base, "base_name", 64);
        Object rawBase = state.rawget("base");
        if (rawBase instanceof KahluaTable baseState) {
            String baseId = text(baseState.rawget("base_id"), 96);
            if (baseId != null) base.rawset("id", baseId);
            String name = text(baseState.rawget("name"), 64);
            if (name != null) base.rawset("name", name);
            Object anchored = baseState.rawget("has_anchor");
            if (anchored instanceof Boolean) base.rawset("anchored", anchored);
        }
        result.rawset("base", base);

        KahluaTable threat = newTable();
        String threatLevel = text(state.rawget("threat_level"), 24);
        threat.rawset("level", threatLevel == null ? "none" : threatLevel);
        Object zombieCount = state.rawget("ordinary_zombie_count");
        threat.rawset("count", zombieCount instanceof Number number
                ? number.doubleValue() <= 0 ? "none" : number.doubleValue() <= 3 ? "few" : "many"
                : "unknown");
        result.rawset("threat", threat);

        KahluaTable objective = newTable();
        String task = text(state.rawget("task"), 48);
        objective.rawset("task", task == null ? "hold" : task);
        String work = text(state.rawget("work_status"), 64);
        if (work != null) objective.rawset("status", work);
        result.rawset("objective", objective);
        result.rawset("capabilities", capabilities());
        return result;
    }
}

package com.horsetheunicorn.goblinsurvivor;

import se.krka.kahlua.vm.KahluaTable;

/** Final semantic admission point before Lua resolves a native body action. */
public final class SurvivorCommandExecutor {
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
}


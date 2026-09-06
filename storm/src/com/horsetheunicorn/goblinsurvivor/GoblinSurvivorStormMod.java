package com.horsetheunicorn.goblinsurvivor;

import io.pzstorm.storm.event.core.StormEventDispatcher;
import io.pzstorm.storm.event.core.SubscribeEvent;
import io.pzstorm.storm.event.lua.OnFETickEvent;
import io.pzstorm.storm.event.lua.OnMainMenuEnterEvent;
import io.pzstorm.storm.event.lua.OnRenderTickEvent;
import io.pzstorm.storm.mod.ZomboidMod;
import io.pzstorm.storm.event.zomboid.OnLuaManagerInitEvent;
import io.pzstorm.storm.event.zomboid.OnMainScreenRenderEvent;
import zombie.Lua.LuaManager;
import zombie.chat.ChatManager;
import zombie.GameWindow;
import zombie.gameStates.GameLoadingState;
import zombie.gameStates.GameState;
import se.krka.kahlua.vm.KahluaTable;
import zombie.iso.IsoCell;
import zombie.network.GameServer;

import java.lang.reflect.Field;

/** Human survivor Lua API registration; no zombie donor implementation. */
public final class GoblinSurvivorStormMod implements ZomboidMod {

    /** Stable logical identity of the Qwen-controlled survivor leader. */
    public static final String LEADER_ID = AgentPerception.LEADER_ID;

    private static boolean localAutoConnectSubmitted;
    private static boolean localAutoConnectRequested;
    private static boolean localAutoConnectProbeLogged;
    private static boolean localAutoConnectRenderProbeLogged;
    private static boolean localAutoConnectMissingUiLogged;
    private static boolean localAutoConnectCallProbeLogged;
    private static boolean localAutoConnectReturnProbeLogged;
    private static boolean localAutoConnectControlsProbeLogged;
    private static boolean localLoadingSkipIssued;
    private static boolean localLoadingSkipFailureLogged;
    private static boolean localLoadingWatchdogStarted;
    private static int localLoadingSkipTicks;
    private static int localAutoConnectEarlyReturnStage = -1;

    private static Field gameLoadingForceDoneField;
    private static boolean gameLoadingForceDoneFieldResolved;

    private static void logLocalAutoConnectEarlyReturn(int stage, String message) {
        if (localAutoConnectEarlyReturnStage == stage) return;
        localAutoConnectEarlyReturnStage = stage;
        System.out.println("[GoblinSurvivorStorm] local auto-connect skipped: " + message);
    }

    /**
     * Render a server-authored Goblin reply in the client's vanilla chat UI.
     *
     * B42 exposes ChatManager as a Java object that cannot be reliably
     * method-dispatched from Kahlua, even when the class is registered. Keep
     * the type-sensitive call on the Java side and expose only this bounded
     * client helper to Lua.
     */
    public static boolean displayGoblinChatMessage(String author, String text) {
        if (GameServer.server || author == null || author.isBlank()
                || text == null || text.isBlank()) {
            return false;
        }
        try {
            ChatManager manager = ChatManager.getInstance();
            if (manager == null) return false;
            manager.addMessage(author, text);
            return true;
        } catch (RuntimeException ignored) {
            return false;
        }
    }

    /**
     * Opt-in helper for the disposable Windows local client.  B42's
     * non-Steam +connect flow stops at the username form, so the disposable
     * local test harness may ask this already-loaded Storm layer to submit
     * that form.  Keep the switch off unless the launcher explicitly sets it;
     * production clients and .03 never enter this path.
     */
    public static boolean localAutoConnectEnabled() {
        if (GameServer.server) return false;
        return Boolean.parseBoolean(System.getProperty("goblin.local.autoconnect", "false"));
    }

    /** Return the bounded local-only account name configured by the harness. */
    public static String localAutoConnectUsername() {
        if (!localAutoConnectEnabled()) return "";
        String username = System.getProperty("goblin.local.username", "horse").trim();
        if (!username.matches("[A-Za-z0-9_-]{1,32}")) return "horse";
        return username;
    }

    /** Return the disposable local account password; never used by production clients. */
    private static String localAutoConnectAccountPassword() {
        if (!localAutoConnectEnabled()) return "";
        String password = System.getProperty("goblin.local.password", "local-test-password");
        if (password.length() < 1 || password.length() > 64) return "local-test-password";
        return password;
    }

    /**
     * Finish the vanilla B42 loading overlay for the disposable local client.
     *
     * B42 deliberately waits for a mouse click after the world and models are
     * loaded.  That click is what lets GameStateMachine enter IngameState,
     * where the normal client sends PlayerConnect.  The local harness cannot
     * use native-window automation, so it supplies the same state transition
     * through the already-running Storm layer.  This is intentionally gated
     * by the local auto-connect property and never runs on an ordinary client.
     */
    private static void tryFinishLocalLoading() {
        if (localLoadingSkipIssued || !localAutoConnectEnabled() || GameServer.server) return;

        if (GameWindow.states == null) return;
        GameState current = GameWindow.states.current;
        if (!(current instanceof GameLoadingState loadingState)) {
            return;
        }

        // Let the normal loader reach its own ready state before changing the
        // one-shot click gate.  The render tick is frequent, so this remains
        // bounded even on a slower disposable profile.
        localLoadingSkipTicks++;
        if (localLoadingSkipTicks < 30) return;

        try {
            GameLoadingState.Done();
            if (!gameLoadingForceDoneFieldResolved) {
                gameLoadingForceDoneField = GameLoadingState.class.getDeclaredField("forceDone");
                gameLoadingForceDoneField.setAccessible(true);
                gameLoadingForceDoneFieldResolved = true;
            }
            gameLoadingForceDoneField.setBoolean(loadingState, true);
            localLoadingSkipIssued = true;
            System.out.println("[GoblinSurvivorStorm] local loading overlay auto-complete issued");
        } catch (Throwable error) {
            if (!localLoadingSkipFailureLogged) {
                localLoadingSkipFailureLogged = true;
                System.out.println("[GoblinSurvivorStorm] local loading overlay auto-complete failed: "
                        + error.getClass().getSimpleName() + ": " + error.getMessage());
            }
        }
    }

    /**
     * The front-end Lua callbacks stop being dispatched while B42 is waiting
     * on the loading overlay. Poll the public state-machine reference from a
     * short-lived daemon thread so the disposable harness can still perform
     * the vanilla click transition. The property gate keeps this completely
     * out of ordinary and production clients.
     */
    private static void startLocalLoadingWatchdog() {
        if (localLoadingWatchdogStarted || !localAutoConnectEnabled()) return;
        localLoadingWatchdogStarted = true;
        Thread watchdog = new Thread(() -> {
            long deadline = System.currentTimeMillis() + 180_000L;
            while (!localLoadingSkipIssued && System.currentTimeMillis() < deadline) {
                tryFinishLocalLoading();
                try {
                    Thread.sleep(100L);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }, "GoblinSurvivor-local-loading-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
        System.out.println("[GoblinSurvivorStorm] local loading watchdog started");
    }

    /**
     * Lua-facing entry point for the disposable client loading hook.  The
     * bootstrap Lua file is known to run during the loading overlay, so keep
     * this callable as a fallback when the engine does not bridge
     * OnRenderTick early enough.
     */
    public static boolean finishLocalLoading() {
        tryFinishLocalLoading();
        return localLoadingSkipIssued;
    }

    private static Object rawField(Object value, String field) {
        if (!(value instanceof KahluaTable table)) return null;
        return table.rawget(field);
    }

    private static Object globalTable(String name) {
        if (LuaManager.env == null) return null;
        return LuaManager.env.rawget(name);
    }

    private static Object tableField(Object value, String field) {
        if (value == null || LuaManager.thread == null) return null;
        return LuaManager.thread.tableget(value, field);
    }

    /**
     * Submit the non-Steam local connection form from the Storm event thread.
     * The mod's client Lua files are loaded only after a server handshake, so
     * a client-Lua OnMainMenuEnter hook cannot bootstrap the first connection.
     * This path remains narrowly gated by the launcher property and loopback
     * endpoint, and it only calls the vanilla UI functions.
     */
    private static void tryLocalAutoConnect() {
        if (localAutoConnectSubmitted || !localAutoConnectEnabled()) return;
        if (!localAutoConnectRequested) {
            if (!"127.0.0.1:16271".equals(
                    System.getProperty("args.server.connect", "").trim())) {
                logLocalAutoConnectEarlyReturn(1, "connect property mismatch");
                return;
            }
            // MainScreenState consumes the +connect argument while it builds
            // the non-Steam form. Keep only the validated loopback intent so
            // the later render callback can submit that form.
            localAutoConnectRequested = true;
        }
        if (LuaManager.env == null || LuaManager.thread == null) {
            logLocalAutoConnectEarlyReturn(2, "Lua env/thread unavailable: env="
                    + (LuaManager.env != null) + ", thread=" + (LuaManager.thread != null));
            return;
        }

        Object bootstrapClass = globalTable("BootstrapConnectPopup");
        Object bootstrapInstance = rawField(bootstrapClass, "instance");
        Object serverClass = globalTable("ServerConnectPopup");
        Object serverInstance = rawField(serverClass, "instance");
        Object connect = rawField(bootstrapClass, "connect");
        Object setText = rawField(globalTable("ISTextEntryBox"), "setText");
        Object submit = rawField(serverClass, "onOptionMouseDown");
        if (bootstrapInstance == null || serverInstance == null || connect == null
                || setText == null || submit == null) {
            logLocalAutoConnectEarlyReturn(3, "popup functions/instances unavailable: bootstrapInstance="
                    + (bootstrapInstance != null) + ", serverInstance=" + (serverInstance != null)
                    + ", connect=" + (connect != null) + ", setText=" + (setText != null)
                    + ", submit=" + (submit != null));
            return;
        }

        String username = localAutoConnectUsername();
        if (username.isBlank()) {
            logLocalAutoConnectEarlyReturn(4, "local username is blank");
            return;
        }
        String accountPassword = localAutoConnectAccountPassword();
        if (accountPassword.isBlank()) {
            logLocalAutoConnectEarlyReturn(5, "local account password is blank");
            return;
        }
        String serverPassword = System.getProperty("args.server.password", "");

        try {
            if (!localAutoConnectCallProbeLogged) {
                localAutoConnectCallProbeLogged = true;
                System.out.println("[GoblinSurvivorStorm] local auto-connect invoking bootstrap connect");
            }
            LuaManager.thread.call(connect, new Object[] {
                    bootstrapInstance, "127.0.0.1", "16271", serverPassword
            });
            if (!localAutoConnectReturnProbeLogged) {
                localAutoConnectReturnProbeLogged = true;
                System.out.println("[GoblinSurvivorStorm] local auto-connect bootstrap connect returned");
            }

            // BootstrapConnectPopup:connect() creates/populates the vanilla
            // ServerConnectPopup. Refresh the instance after that call.
            serverInstance = rawField(serverClass, "instance");
            Object serverPasswordEntry = tableField(serverInstance, "serverPasswordEntry");
            Object usernameEntry = tableField(serverInstance, "usernameEntry");
            Object passwordEntry = tableField(serverInstance, "passwordEntry");
            Object connectButton = tableField(serverInstance, "connectBtn");
            if (!localAutoConnectControlsProbeLogged) {
                localAutoConnectControlsProbeLogged = true;
                System.out.println("[GoblinSurvivorStorm] local auto-connect controls inspected: "
                        + "serverPasswordEntry=" + (serverPasswordEntry != null)
                        + ", usernameEntry=" + (usernameEntry != null)
                        + ", passwordEntry=" + (passwordEntry != null)
                        + ", connectBtn=" + (connectButton != null));
            }
            if (serverPasswordEntry == null || usernameEntry == null || passwordEntry == null
                    || connectButton == null) {
                if (!localAutoConnectMissingUiLogged) {
                    localAutoConnectMissingUiLogged = true;
                    System.out.println("[GoblinSurvivorStorm] local auto-connect popup controls "
                            + "not available: serverPasswordEntry=" + (serverPasswordEntry != null)
                            + ", usernameEntry=" + (usernameEntry != null)
                            + ", passwordEntry=" + (passwordEntry != null)
                            + ", connectBtn=" + (connectButton != null));
                }
                return;
            }

            LuaManager.thread.call(setText, new Object[] {serverPasswordEntry, serverPassword});
            LuaManager.thread.call(setText, new Object[] {usernameEntry, username});
            LuaManager.thread.call(setText, new Object[] {passwordEntry, accountPassword});
            LuaManager.thread.call(submit, new Object[] {serverInstance, connectButton, 0.0, 0.0});
            localAutoConnectSubmitted = true;
            System.out.println("[GoblinSurvivorStorm] submitted local connection for "
                    + username + " at 127.0.0.1:16271");
        } catch (Throwable error) {
            System.out.println("[GoblinSurvivorStorm] local auto-connect deferred: "
                    + error.getClass().getSimpleName() + ": " + error.getMessage());
        }
    }

    @Override
    public void registerEventHandlers() {
        StormEventDispatcher.registerEventHandler(Handlers.class);
        startLocalLoadingWatchdog();
        Handlers.exposeHumanSurvivor();
    }

    public static final class Handlers {
        public static void exposeHumanSurvivor() {
            if (LuaManager.exposer == null || LuaManager.env == null) return;
            LuaManager.exposer.setExposed(HumanSurvivor.class);
            LuaManager.exposer.exposeLikeJava(HumanSurvivor.class, LuaManager.env);
            try {
                LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                        HumanSurvivor.class,
                        HumanSurvivor.class.getConstructor(zombie.characters.SurvivorDesc.class,
                                IsoCell.class, int.class, int.class, int.class),
                        "createGoblinHumanSurvivor");
                if (GameServer.server) {
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod("step", KahluaTable.class,
                                    KahluaTable.class, double.class), "stepGoblinServerActor");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod("persistActorCargo",
                                    KahluaTable.class), "persistGoblinActorCargo");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod("debugMarkDead",
                                    String.class, String.class), "markGoblinHumanDead");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod("debugSpawnHostileZombie",
                                    String.class), "spawnGoblinCombatFixture");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            ServerSurvivorAuthority.class,
                            ServerSurvivorAuthority.class.getMethod(
                                    "debugSpawnHostileZombieForObservation", String.class),
                            "spawnGoblinCombatObservation");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            AgentPerception.class,
                            AgentPerception.class.getMethod("semanticState", KahluaTable.class),
                            "buildGoblinAgentPerception");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            AgentPerception.class,
                            AgentPerception.class.getMethod("capabilities"),
                            "goblinAgentCapabilities");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            SurvivorCommandExecutor.class,
                            SurvivorCommandExecutor.class.getMethod("validate", KahluaTable.class),
                            "validateGoblinSurvivorCommand");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            SurvivorCommandExecutor.class,
                            SurvivorCommandExecutor.class.getMethod("rejectReason", KahluaTable.class),
                            "goblinSurvivorCommandRejectReason");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            SurvivorCommandExecutor.class,
                            SurvivorCommandExecutor.class.getMethod("normalizeAction", String.class),
                            "normalizeGoblinAction");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            SurvivorCommandExecutor.class,
                            SurvivorCommandExecutor.class.getMethod("execute",
                                    KahluaTable.class, KahluaTable.class),
                            "executeGoblinSurvivorCommand");
                } else {
                    // Keep the B42 ChatManager call inside Java. Its returned
                    // instance is not reliably method-dispatchable from
                    // Kahlua, even when the class itself is exposed.
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            GoblinSurvivorStormMod.class,
                            GoblinSurvivorStormMod.class.getMethod(
                                    "displayGoblinChatMessage", String.class, String.class),
                            "displayGoblinChatMessage");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            GoblinSurvivorStormMod.class,
                            GoblinSurvivorStormMod.class.getMethod(
                                    "localAutoConnectEnabled"),
                            "goblinLocalAutoConnectEnabled");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            GoblinSurvivorStormMod.class,
                            GoblinSurvivorStormMod.class.getMethod(
                                    "localAutoConnectUsername"),
                            "goblinLocalAutoConnectUsername");
                    LuaManager.exposer.exposeGlobalClassFunction(LuaManager.env,
                            GoblinSurvivorStormMod.class,
                            GoblinSurvivorStormMod.class.getMethod(
                                    "finishLocalLoading"),
                            "finishGoblinLocalLoading");
                }
            } catch (NoSuchMethodException error) {
                throw new IllegalStateException("Human survivor constructor contract changed", error);
            }
            System.out.println("[GoblinSurvivorStorm] HumanSurvivor Lua API registered");
        }

        @SubscribeEvent
        public static void onLuaInit(OnLuaManagerInitEvent event) {
            exposeHumanSurvivor();
        }

        @SubscribeEvent
        public static void onMainMenuEnter(OnMainMenuEnterEvent event) {
            logLocalAutoConnectProbe("main-menu-enter");
            tryLocalAutoConnect();
        }

        @SubscribeEvent
        public static void onMainScreenRender(OnMainScreenRenderEvent event) {
            if (!localAutoConnectRenderProbeLogged && localAutoConnectEnabled()) {
                localAutoConnectRenderProbeLogged = true;
                Object bootstrapClass = globalTable("BootstrapConnectPopup");
                Object serverClass = globalTable("ServerConnectPopup");
                Object textEntryClass = globalTable("ISTextEntryBox");
                System.out.println("[GoblinSurvivorStorm] local auto-connect renderer probe: "
                        + "bootstrapClass=" + (bootstrapClass != null)
                        + ", bootstrapInstance=" + (rawField(bootstrapClass, "instance") != null)
                        + ", serverClass=" + (serverClass != null)
                        + ", serverInstance=" + (rawField(serverClass, "instance") != null)
                        + ", connect=" + (rawField(bootstrapClass, "connect") != null)
                        + ", setText=" + (rawField(textEntryClass, "setText") != null)
                        + ", submit=" + (rawField(serverClass, "onOptionMouseDown") != null)
                        + ", luaThread=" + (LuaManager.thread != null));
            }
            tryLocalAutoConnect();
        }

        @SubscribeEvent
        public static void onFrontEndTick(OnFETickEvent event) {
            tryLocalAutoConnect();
        }

        @SubscribeEvent
        public static void onRenderTick(OnRenderTickEvent event) {
            tryFinishLocalLoading();
        }

        private static void logLocalAutoConnectProbe(String source) {
            if (localAutoConnectProbeLogged || !localAutoConnectEnabled()) return;
            localAutoConnectProbeLogged = true;
            System.out.println("[GoblinSurvivorStorm] local auto-connect probe at " + source
                    + ": args.server.connect='"
                    + System.getProperty("args.server.connect", "") + "'");
        }
    }
}

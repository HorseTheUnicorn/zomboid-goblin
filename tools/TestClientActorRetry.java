import java.nio.file.Files;
import java.nio.file.Path;
import java.io.StringReader;
import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.KahluaThread;

/** Execute the client event loop with a temporarily unavailable constructor. */
public class TestClientActorRetry {
    public static void main(String[] args) throws Exception {
        var platform = J2SEPlatform.getInstance();
        var env = platform.newEnvironment();
        var thread = new KahluaThread(platform, env);
        thread.debugOwnerThread = Thread.currentThread();
        String source = Files.readString(Path.of(args[0]));
        String test = """
            local handlers = {}
            local now = 1000
            Events = {}
            for _, name in ipairs({"OnServerCommand", "OnTick", "OnGameStart", "OnPostUIDraw"}) do
                local key = name
                Events[key] = {Add=function(fn) handlers[key]=fn end}
            end
            function require(name)
                return {module="test", stateCommand="state", entityClass="HumanSurvivor", version=1,
                    nowMs=function() return now end,
                    validSnapshot=function() return true end}
            end
            function getCell() return {} end
            SurvivorFactory = {CreateSurvivor=function() return {} end}
            local attempts = 0
            function createGoblinHumanSurvivor()
                attempts = attempts + 1
                error("world temporarily unavailable")
            end
            local function loadClient()
            """ + source + """
            end
            local client = loadClient()
            local function send(id, seq, alive, generation)
                handlers.OnServerCommand("test", "state", {actor_id=id, sequence=seq,
                    body_generation=generation or 1,
                    alive=alive, body_present=alive, x=1, y=1, z=0})
            end
            send("a", 1, true)
            send("b", 1, true)
            assert(attempts == 2)
            assert(client.lastSequence.a == nil, "failed creation consumed sequence")
            handlers.OnTick()
            assert(attempts == 2, "retry loop is unbounded")
            now = 2000
            handlers.OnTick()
            assert(attempts == 4, "must retry every roster member")
            send("a", 2, false)
            assert(client.lastSequence.a == 2 and client.states.a == nil)
            now = 3000
            handlers.OnTick()
            assert(attempts == 5, "absent actor must not be retried")
            send("a", 1, true)
            assert(attempts == 5, "stale packet resurrected absent actor")
            send("b", 5, true)
            send("b", 3, true)
            assert(client.states.b.sequence == 5, "older packet replaced pending state")
            local removed = 0
            function createGoblinHumanSurvivor()
                attempts = attempts + 1
                return {ensureFirearm=function() return true end,
                    unregisterVisualObject=function() removed=removed+1 end}
            end
            now = 4000
            handlers.OnTick()
            assert(client.actors.b ~= nil and client.lastSequence.b == 5,
                "pending snapshot did not recover without another packet")
            local original = client.actors.b
            handlers.OnTick()
            assert(attempts == 6 and client.actors.b == original, "duplicate creation")
            send("b", 6, true, 2)
            assert(client.actors.b ~= original and removed == 1, "generation replacement")
            send("b", 7, false, 2)
            assert(client.actors.b == nil and removed == 2, "absence cleanup")
            """;
        var result = thread.pcall(LuaCompiler.loadis(new StringReader(test), "client-retry", env), new Object[0]);
        if (!Boolean.TRUE.equals(result[0])) throw new AssertionError(java.util.Arrays.toString(result));
        System.out.println("Client actor retry: bounded retries, full roster, absence and stale packet checks passed");
    }
}

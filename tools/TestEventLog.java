import java.nio.file.Files;
import java.nio.file.Path;
import java.io.StringReader;
import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.KahluaThread;

/** Execute event publication with the game's Lua VM and no math.random. */
public class TestEventLog {
    public static void main(String[] args) throws Exception {
        var platform = J2SEPlatform.getInstance();
        var environment = platform.newEnvironment();
        var thread = new KahluaThread(platform, environment);
        thread.debugOwnerThread = Thread.currentThread();
        String source = Files.readString(Path.of(args[0]));
        String test = """
            math.random = nil
            local emitted = {}
            local modules = {
                ["GoblinSurvivor/Config"] = { protocol = 1 },
                ["GoblinSurvivor/ClientSurvivorProtocol"] = {
                    nowMs = function() return 1788566000000 end
                },
                ["GoblinSurvivor/IPC"] = {
                    publish = function(channel, message, id)
                        assert(channel == "events")
                        assert(message.request_id == id)
                        assert(not emitted[id], "duplicate event ID")
                        assert(message.timestamp_ms == 1788566000000)
                        assert(message.type == "event.chat")
                        assert(message.speaker == "horse")
                        emitted[id] = message
                        return true
                    end
                }
            }
            function require(name) return assert(modules[name]) end
            local function loadEventLog()
            """ + source + """
            end
            local log = loadEventLog()
            for i = 1, 100 do assert(log.emit("chat", {speaker="horse"})) end
            assert(log.emit("", {}) == false)
            assert(log.emit("chat", nil) == false)
            assert(log.sequence == 100)
            """;
        var result = thread.pcall(LuaCompiler.loadis(new StringReader(test), "event-log-test", environment), new Object[0]);
        if (!Boolean.TRUE.equals(result[0])) throw new AssertionError(java.util.Arrays.toString(result));
        System.out.println("EventLog: 100 unique same-millisecond events without math.random; invalid input rejected");
    }
}

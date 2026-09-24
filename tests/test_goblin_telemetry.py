"""Private exact-state telemetry keeps movement and authority in one sample."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class ExactTelemetryTests(unittest.TestCase):
    def test_exact_state_includes_native_owner_and_simulation_owner(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().lua_path = ";".join(
            (LUA / scope / "?.lua").as_posix() for scope in ("shared", "server")
        )
        lua.execute('package.path=lua_path..";"..package.path')
        lua.execute('''
            local published = {}
            package.loaded["GoblinSurvivor/Config"] = {
                trackerExactTelemetry = true,
                protocol = "test"
            }
            package.loaded["GoblinSurvivor/IPC"] = {
                isReady = function() return true end,
                publishRuntime = function(name, message)
                    published[name] = message
                    return true
                end
            }
            package.loaded["GoblinSurvivor/GoblinSpawner"] = {
                snapshotAll = function()
                    return {{
                        npc_id = "goblin.primary.horse",
                        online_id = 42,
                        owner = "horse",
                        body_present = true,
                        position = { x = 10.5, y = 20.5, z = 0 },
                        navigation = {
                            simulation_owner = "client",
                            native_owner_player = "unicorn"
                        }
                    }}
                end
            }
            getTimestampMs = function() return 123456 end
            getOnlinePlayers = function()
                local player = {
                    getUsername = function() return "horse" end,
                    getX = function() return 11 end,
                    getY = function() return 21 end,
                    getZ = function() return 0 end
                }
                return {
                    size = function() return 1 end,
                    get = function() return player end
                }
            end
            local telemetry = require("GoblinSurvivor/GoblinTelemetry")
            assert(telemetry.writeExact(true))
            local exact = published["zomboid-exact-state"]
            assert(exact.timestamp_ms == 123456)
            assert(#exact.entities == 2)
            local goblin = exact.entities[2]
            assert(goblin.entity_id == "goblin.primary.horse")
            assert(goblin.online_id == 42)
            assert(goblin.native_owner_player == "unicorn")
            assert(goblin.simulation_owner == "client")
            assert(goblin.x == 10.5 and goblin.y == 20.5)
            assert(published["zomboid-state"] == nil)
        ''')


if __name__ == "__main__":
    unittest.main()

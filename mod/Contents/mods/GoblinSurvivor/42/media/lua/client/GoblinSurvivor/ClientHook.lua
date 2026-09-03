-- Client entry point for the native Linux PZ client adapter.  The adapter is
-- deliberately inert until the server sends a typed welcome and the native
-- client reports the matching Build/digest control contract.  It never
-- evaluates model text or arbitrary Lua.
local Config = require("GoblinSurvivor/Config")
Config.refresh()
local Adapter = require("GoblinSurvivor/ClientAdapter")
return Adapter.start()

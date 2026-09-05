local Config = {
    protocol = 1,
    enabled = false,
    developmentMode = false,
    debugSurvivors = false,
    allowTestCommands = false,
    verboseNpcLogging = false,
    survivorEngineVersion = 1,
    bridgeRootOverride = "",
    npcId = "goblin.primary",
    npcName = "Goblin",
    -- Kept as a protocol-compatible label for the agent command payload. The
    -- native engine owns behavior and does not load an external program.
    npcProgram = "GoblinSurvivorNative",
    npcRole = "companion",
    -- The verified local multiplayer path is a client-rendered IsoSurvivor.
    -- Set GoblinBodyMode=native_zombie only for the legacy donor experiment.
    bodyMode = "client_survivor",
    -- These are additional managed friendly bodies created by our own native
    -- engine. The default roster is six companions plus Goblin. Set
    -- GoblinManagedNpcCount=0 to run only Goblin, or lower it for a smaller
    -- local test roster.
    managedNpcCount = 6,
    protected = true,
    gameBuildOverride = "",
    fileOptions = {},
    configFileName = "config.ini",
    -- PZ's supported file API resolves paths below its Lua cache directory.
    -- The SSH relay maps this relative root to the corresponding guest path.
    defaultBridgeRoot = "goblin-bridge",
    heartbeatSeconds = 5,
    maxMessageBytes = 262144,
    trackerExactTelemetry = true,
    minimumBaseGuards = 1,
    -- Server-side command authority.  The list is intentionally empty by
    -- default; PZ admins/moderators are accepted by isAuthorizedPlayer(),
    -- and operators may add exact usernames with GoblinCommanders= in the
    -- provisioned bridge config.
    commanders = {},
    -- Keep the first server-side body request out of the player's square.
    -- This is a safety margin around the point passed to the native body
    -- creator while its new networked body receives its friendly state.
    npcSpawnOffsetTiles = 16
}

local function parseBoolean(value, defaultValue)
    if type(value) == "boolean" then
        return value
    end
    if type(value) ~= "string" then
        return defaultValue
    end
    local normalized = string.lower(value)
    if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on" then
        return true
    end
    if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" then
        return false
    end
    return defaultValue
end

local function trim(value)
    value = string.gsub(value, "^%s+", "")
    return string.gsub(value, "%s+$", "")
end

local function readConfigFile(path)
    local readerFactory = rawget(_G, "getFileReader")
    if type(readerFactory) ~= "function" then
        return {}
    end
    local okOpen, handle = pcall(readerFactory, path, false)
    if not okOpen or handle == nil then
        return {}
    end

    local values = {}
    local malformed = false
    local lineCount = 0
    local okRead = pcall(function()
        while true do
            local line = handle:readLine()
            if line == nil then
                break
            end
            lineCount = lineCount + 1
            -- The server's ordered Mods/WorkshopItems loadout can be longer
            -- than an ordinary option. Keep the parser bounded, but allow
            -- the complete captured loadout to remain one authoritative
            -- value instead of truncating it or accepting an unbounded line.
            if lineCount > 128 or type(line) ~= "string" or #line > 4096 then
                malformed = true
                break
            end
            line = trim(line)
            if line ~= "" and string.sub(line, 1, 1) ~= "#"
                and string.sub(line, 1, 1) ~= ";" then
                local key, value = string.match(
                    line,
                    "^([A-Za-z][A-Za-z0-9_]*)%s*=%s*(.*)$"
                )
                if key == nil or value == nil then
                    malformed = true
                    break
                end
                values[key] = trim(value)
            end
        end
    end)
    pcall(function() handle:close() end)
    if not okRead or malformed then
        return {}
    end
    return values
end

local function readServerOption(name, defaultValue)
    if type(getServerOptions) ~= "function" then
        return defaultValue
    end
    local ok, options = pcall(getServerOptions)
    if not ok or options == nil then
        return defaultValue
    end
    local okValue, value = pcall(function()
        if type(options.getOptionByName) == "function" then
            local option = options:getOptionByName(name)
            if option ~= nil and type(option.getValue) == "function" then
                return option:getValue()
            end
            return option
        end
        return options[name]
    end)
    if okValue and value ~= nil then
        return value
    end
    return defaultValue
end

local function safeBridgeRoot(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 96
        and string.find(value, "^[A-Za-z0-9][A-Za-z0-9%._%-]*(/[A-Za-z0-9][A-Za-z0-9%._%-]*)*$") ~= nil
        and not string.find(value, "%.%.")
end

local function parseCommanders(value)
    local result = {}
    if type(value) ~= "string" or #value > 2048 then
        return result
    end
    for raw in string.gmatch(value .. ",", "([^,]*),") do
        local name = trim(raw)
        if name ~= "" and #name <= 96
            and string.find(name, "^[A-Za-z0-9_%-]+$") ~= nil then
            result[string.lower(name)] = true
        end
    end
    return result
end

local function parseBoundedInteger(value, defaultValue, minimum, maximum)
    local number = tonumber(value)
    if number == nil or math.floor(number) ~= number
        or number < minimum or number > maximum then
        return defaultValue
    end
    return number
end

function Config.refresh()
    -- Build 42 ignores unknown keys in Server/<name>.ini.  Read the
    -- integration's own config from the fixed, provisioned Lua bridge root
    -- instead.  A missing or malformed file leaves every sensitive option at
    -- its safe default.
    Config.fileOptions = readConfigFile(
        Config.defaultBridgeRoot .. "/" .. Config.configFileName
    )

    local function readOption(name, defaultValue)
        if Config.fileOptions[name] ~= nil then
            return Config.fileOptions[name]
        end
        -- Keep compatibility with a runtime that explicitly registers a
        -- custom ServerOptions entry, but never rely on an unknown .ini key.
        return readServerOption(name, defaultValue)
    end

    local optionEnabled = readOption("GoblinEnabled", false)
    Config.enabled = parseBoolean(optionEnabled, false)
    Config.developmentMode = parseBoolean(
        readOption("GoblinDevelopmentMode", false), false
    )
    Config.debugSurvivors = parseBoolean(
        readOption("GoblinDebugSurvivors", false), false
    )
    Config.allowTestCommands = parseBoolean(
        readOption("GoblinAllowTestCommands", false), false
    )
    Config.verboseNpcLogging = parseBoolean(
        readOption("GoblinVerboseNPCLogging", false), false
    )
    local root = readOption("GoblinBridgeRoot", "")
    if safeBridgeRoot(root) then
        Config.bridgeRootOverride = root
    else
        Config.bridgeRootOverride = ""
    end
    local npcId = readOption("GoblinNpcId", Config.npcId)
    if type(npcId) == "string"
        and #npcId >= 1
        and #npcId <= 96
        and string.find(npcId, "^[A-Za-z0-9_%.:%-]+$") then
        Config.npcId = npcId
    end
    local npcName = readOption("GoblinNpcName", Config.npcName)
    if type(npcName) == "string" and #npcName >= 1 and #npcName <= 32 then
        Config.npcName = npcName
    end
    local npcProgram = readOption("GoblinNpcProgram", Config.npcProgram)
    if type(npcProgram) == "string" and #npcProgram >= 1 and #npcProgram <= 32 then
        Config.npcProgram = npcProgram
    end
    local bodyMode = readOption("GoblinBodyMode", Config.bodyMode)
    if bodyMode == "client_survivor" or bodyMode == "native_zombie" then
        Config.bodyMode = bodyMode
    end
    local build = readOption("GoblinGameBuild", Config.gameBuildOverride)
    if type(build) == "string"
        and #build >= 1
        and #build <= 64
        and string.find(build, "^[A-Za-z0-9][A-Za-z0-9%._%+%- ]*$") then
        Config.gameBuildOverride = build
    end
    Config.protected = parseBoolean(readOption("GoblinNpcProtected", true), true)
    Config.trackerExactTelemetry = parseBoolean(readOption("GoblinTrackerExact", true), true)
    Config.minimumBaseGuards = parseBoundedInteger(
        readOption("MinimumBaseGuards", Config.minimumBaseGuards),
        Config.minimumBaseGuards, 0, 16
    )
    Config.managedNpcCount = parseBoundedInteger(
        readOption("GoblinManagedNpcCount", Config.managedNpcCount),
        Config.managedNpcCount, 0, 8
    )
    Config.commanders = parseCommanders(readOption("GoblinCommanders", ""))
    return Config
end

local function playerUsername(player)
    if player == nil or type(player.getUsername) ~= "function" then return "" end
    local ok, value = pcall(function() return player:getUsername() end)
    return ok and type(value) == "string" and value or ""
end

local function playerAccessLevel(player)
    if player == nil then return "" end
    if type(player.getAccessLevel) == "function" then
        local ok, value = pcall(function() return player:getAccessLevel() end)
        if ok and type(value) == "string" then return string.lower(value) end
    end
    if type(player.getRole) == "function" then
        local ok, value = pcall(function() return player:getRole() end)
        if ok and type(value) == "string" then return string.lower(value) end
    end
    return ""
end

function Config.isAuthorizedPlayer(player)
    local name = playerUsername(player)
    if name ~= "" and Config.commanders[string.lower(name)] == true then
        return true
    end
    local level = playerAccessLevel(player)
    if level == "admin" or level == "moderator" then
        return true
    end
    if player ~= nil and type(player.isAdmin) == "function" then
        local ok, value = pcall(function() return player:isAdmin() end)
        if ok and value == true then return true end
    end
    return false
end

-- Exposed for the server manifest builder. It reads the dedicated bridge
-- config (or an explicitly registered runtime option) and never invents a
-- default for a security-sensitive value.
function Config.readOption(name, defaultValue)
    if Config.fileOptions[name] ~= nil then
        return Config.fileOptions[name]
    end
    return readServerOption(name, defaultValue)
end

function Config.bridgeRoot()
    if Config.bridgeRootOverride ~= "" then
        return Config.bridgeRootOverride
    end
    -- This is a fixed path on the verified PZ guest, never a per-process or
    -- local fallback. IPC.initialize() still fails closed if it is absent.
    return Config.defaultBridgeRoot
end

return Config

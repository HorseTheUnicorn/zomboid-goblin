local Config = {
    protocol = 1,
    enabled = false,
    bridgeRootOverride = "",
    npcId = "goblin.primary",
    npcName = "Goblin",
    npcProgram = "Bandit",
    npcRole = "companion",
    protected = true,
    gameBuildOverride = "",
    fileOptions = {},
    configFileName = "config.ini",
    -- PZ's supported file API resolves paths below its Lua cache directory.
    -- The SSH relay maps this relative root to the corresponding guest path.
    defaultBridgeRoot = "goblin-bridge",
    heartbeatSeconds = 5,
    maxMessageBytes = 262144,
    trackerExactTelemetry = true
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
    local build = readOption("GoblinGameBuild", Config.gameBuildOverride)
    if type(build) == "string"
        and #build >= 1
        and #build <= 64
        and string.find(build, "^[A-Za-z0-9][A-Za-z0-9%._%+%- ]*$") then
        Config.gameBuildOverride = build
    end
    Config.protected = parseBoolean(readOption("GoblinNpcProtected", true), true)
    Config.trackerExactTelemetry = parseBoolean(readOption("GoblinTrackerExact", true), true)
    return Config
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

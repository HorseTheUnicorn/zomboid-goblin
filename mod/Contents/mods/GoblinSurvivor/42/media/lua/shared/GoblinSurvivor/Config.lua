local Config = {
    protocol = 1,
    -- The rebuilt companion is self-contained.  The bridge is optional: when
    -- it is absent, /goblin debug commands and FOLLOW still work locally.
    enabled = true,
    bridgeRootOverride = "",
    npcId = "goblin.primary",
    npcName = "Goblin",
    npcRole = "companion",
    npcOutfit = "Survivor",
    npcOutfitId = 4101,
    -- Explicit vanilla pieces keep the companion's visible outfit stable
    -- across clients.  The list is applied after the named Survivor outfit
    -- and replaces its random clothing selection.
    npcOutfitItems = {
        "Base.Shirt_Priest",
        "Base.Hat_Beret",
        "Base.Shoes_BlackBoots",
        "Base.Trousers_Black"
    },
    npcVisualAsset = "Goblin_PZ_MysteryRig",
    npcVisualItemType = "GoblinSurvivor.Goblin_MysteryBody",
    weaponType = "Base.Machete",
    protected = true,
    fileOptions = {},
    configFileName = "config.ini",
    defaultBridgeRoot = "goblin-bridge",
    heartbeatSeconds = 5,
    maxMessageBytes = 262144,
    trackerExactTelemetry = true,
    commanders = {},
    spawnOffsetTiles = 4,
    followPreferredDistance = 3,
    followWalkDistance = 4,
    followRunDistance = 9,
    followHysteresis = 1.5,
    repathSeconds = 1.25,
    blockedRetrySeconds = 3.0,
    emergencyDistance = 80,
    respawnSeconds = 15,
    combatRadius = 16,
    meleeRange = 2.25,
    meleeCooldownSeconds = 1.0,
    meleePoseSeconds = 0.70,
    meleeImpactDelaySeconds = 0.325,
    combatTargetRefreshSeconds = 0.50,
    recoverySeconds = 0.80,
    recoveryHitPulseSeconds = 0.15,
    stuckTimeoutSeconds = 8.0,
    maxRecoveryAttempts = 3,
    lootRadius = 6,
    lootScanSeconds = 2.0,
    lootMaxItemsPerTask = 4
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

local function parseBoundedNumber(value, defaultValue, minimum, maximum)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge
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

    local optionEnabled = readOption("GoblinEnabled", true)
    Config.enabled = parseBoolean(optionEnabled, true)
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
    local outfit = readOption("GoblinNpcOutfit", Config.npcOutfit)
    if type(outfit) == "string" and #outfit >= 1 and #outfit <= 64
        and string.find(outfit, "^[A-Za-z0-9_%-]+$") then
        Config.npcOutfit = outfit
    end
    Config.npcOutfitId = parseBoundedInteger(
        readOption("GoblinNpcOutfitId", Config.npcOutfitId),
        Config.npcOutfitId, 0, 1000000
    )
    local visualAsset = readOption("GoblinNpcVisualAsset", Config.npcVisualAsset)
    if type(visualAsset) == "string" and #visualAsset >= 1 and #visualAsset <= 96
        and string.find(visualAsset, "^[A-Za-z0-9_%-]+$") then
        Config.npcVisualAsset = visualAsset
    end
    local weapon = readOption("GoblinWeapon", Config.weaponType)
    if type(weapon) == "string" and #weapon >= 1 and #weapon <= 96
        and string.find(weapon, "^[A-Za-z0-9_%.%-]+$") then
        Config.weaponType = weapon
    end
    Config.protected = parseBoolean(readOption("GoblinNpcProtected", true), true)
    Config.trackerExactTelemetry = parseBoolean(readOption("GoblinTrackerExact", true), true)
    Config.followPreferredDistance = parseBoundedInteger(
        readOption("GoblinFollowDistance", Config.followPreferredDistance),
        Config.followPreferredDistance, 2, 8
    )
    Config.followWalkDistance = parseBoundedInteger(
        readOption("GoblinFollowWalkDistance", Config.followWalkDistance),
        Config.followWalkDistance, 3, 16
    )
    Config.followRunDistance = parseBoundedInteger(
        readOption("GoblinFollowRunDistance", Config.followRunDistance),
        Config.followRunDistance, 6, 32
    )
    Config.spawnOffsetTiles = parseBoundedInteger(
        readOption("GoblinSpawnOffset", Config.spawnOffsetTiles),
        Config.spawnOffsetTiles, 2, 16
    )
    Config.followHysteresis = parseBoundedNumber(
        readOption("GoblinFollowHysteresis", Config.followHysteresis),
        Config.followHysteresis, 0, 8
    )
    Config.repathSeconds = parseBoundedNumber(
        readOption("GoblinRepathSeconds", Config.repathSeconds),
        Config.repathSeconds, 0.25, 10
    )
    Config.blockedRetrySeconds = parseBoundedNumber(
        readOption("GoblinBlockedRetrySeconds", Config.blockedRetrySeconds),
        Config.blockedRetrySeconds, 1, 60
    )
    Config.emergencyDistance = parseBoundedNumber(
        readOption("GoblinEmergencyDistance", Config.emergencyDistance),
        Config.emergencyDistance, 16, 1000
    )
    Config.respawnSeconds = parseBoundedNumber(
        readOption("GoblinRespawnSeconds", Config.respawnSeconds),
        Config.respawnSeconds, 0, 3600
    )
    Config.combatRadius = parseBoundedNumber(
        readOption("GoblinCombatRadius", Config.combatRadius),
        Config.combatRadius, 4, 64
    )
    Config.meleeRange = parseBoundedNumber(
        readOption("GoblinMeleeRange", Config.meleeRange),
        Config.meleeRange, 1, 4
    )
    Config.meleeCooldownSeconds = parseBoundedNumber(
        readOption("GoblinMeleeCooldownSeconds", Config.meleeCooldownSeconds),
        Config.meleeCooldownSeconds, 0.25, 5
    )
    Config.meleePoseSeconds = parseBoundedNumber(
        readOption("GoblinMeleePoseSeconds", Config.meleePoseSeconds),
        Config.meleePoseSeconds, 0.2, 2
    )
    Config.meleeImpactDelaySeconds = parseBoundedNumber(
        readOption("GoblinMeleeImpactDelaySeconds", Config.meleeImpactDelaySeconds),
        Config.meleeImpactDelaySeconds, 0.05, 1.5
    )
    Config.combatTargetRefreshSeconds = parseBoundedNumber(
        readOption("GoblinCombatTargetRefreshSeconds", Config.combatTargetRefreshSeconds),
        Config.combatTargetRefreshSeconds, 0.1, 5
    )
    Config.recoverySeconds = parseBoundedNumber(
        readOption("GoblinRecoverySeconds", Config.recoverySeconds),
        Config.recoverySeconds, 0.1, 10
    )
    Config.recoveryHitPulseSeconds = parseBoundedNumber(
        readOption("GoblinRecoveryHitPulseSeconds", Config.recoveryHitPulseSeconds),
        Config.recoveryHitPulseSeconds, 0.05, 1
    )
    Config.stuckTimeoutSeconds = parseBoundedNumber(
        readOption("GoblinStuckTimeoutSeconds", Config.stuckTimeoutSeconds),
        Config.stuckTimeoutSeconds, 2, 60
    )
    Config.maxRecoveryAttempts = parseBoundedInteger(
        readOption("GoblinMaxRecoveryAttempts", Config.maxRecoveryAttempts),
        Config.maxRecoveryAttempts, 0, 8
    )
    Config.lootRadius = parseBoundedNumber(
        readOption("GoblinLootRadius", Config.lootRadius),
        Config.lootRadius, 1, 16
    )
    Config.lootScanSeconds = parseBoundedNumber(
        readOption("GoblinLootScanSeconds", Config.lootScanSeconds),
        Config.lootScanSeconds, 0.5, 30
    )
    Config.lootMaxItemsPerTask = parseBoundedInteger(
        readOption("GoblinLootMaxItemsPerTask", Config.lootMaxItemsPerTask),
        Config.lootMaxItemsPerTask, 1, 16
    )
    -- Keep the hysteresis thresholds ordered even when an operator edits the
    -- bridge file by hand.  This avoids an oscillating walk/run controller.
    if Config.followWalkDistance <= Config.followPreferredDistance then
        Config.followWalkDistance = math.min(16, Config.followPreferredDistance + 1)
    end
    if Config.followRunDistance <= Config.followWalkDistance then
        Config.followRunDistance = math.min(32, Config.followWalkDistance + 1)
    end
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

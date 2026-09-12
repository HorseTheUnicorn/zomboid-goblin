local Config = {
    protocol = 2,
    enabled = true,
    bridgeRootOverride = "",
    npcId = "goblin.primary",
    npcName = "Goblin",
    npcRole = "companion",

    -- Community Rig skin on the native human body, with the native uniform.
    npcOutfit = "GoblinCompanion",
    npcOutfitId = 4101,
    npcOutfitItems = {
        "Base.Shirt_Priest",
        "Base.Trousers_Black",
        "Base.Hat_Beret",
        "Base.Shoes_BlackBoots"
    },
    npcVisualAsset = "Goblin_Community_Human",
    npcVisualItemType = "GoblinSurvivor.Goblin_MysteryBody",
    npcSkinTexture = "Goblin/GoblinNativeSkin",

    -- Goblin's permanent two-handed bodyguard weapon. Runtime defense keeps
    -- the two internal shells ready and enables the engine unlimited-ammo flag.
    weaponType = "Base.DoubleBarrelShotgun",
    protected = true,

    fileOptions = {},
    configFileName = "config.ini",
    defaultBridgeRoot = "goblin-bridge",
    heartbeatSeconds = 5,
    maxMessageBytes = 262144,
    trackerExactTelemetry = true,
    commanders = {},

    spawnOffsetTiles = 4,
    followPreferredDistance = 3.0,
    followWalkDistance = 2,
    followRunDistance = 9,
    followHysteresis = 0.5,
    repathSeconds = 1.25,
    blockedRetrySeconds = 2.0,
    emergencyDistance = 80,
    respawnSeconds = 15,

    combatRadius = 20,
    rangedRange = 12,
    rangedCooldownSeconds = 0.8,
    meleeRange = 2.25,
    meleeCooldownSeconds = 1.0,
    meleePoseSeconds = 0.70,
    meleeImpactDelaySeconds = 0.325,
    combatTargetRefreshSeconds = 0.50,
    recoverySeconds = 0.80,
    recoveryHitPulseSeconds = 0.15,
    stuckTimeoutSeconds = 6.0,
    maxRecoveryAttempts = 4,

    lootRadius = 8,
    lootScanSeconds = 2.0,
    lootMaxItemsPerTask = 8,

    -- Independent chores begin after 30 seconds stationary, or while offline.
    -- Moving again cancels independent chores, never explicit player orders.
    autonomyEnabled = true,
    autonomyIdleSeconds = 30,
    autonomyDecisionSeconds = 8,
    autonomyExploreRadius = 24,
    autonomyWorkRadius = 10,
    autonomyBarricadeRadius = 8
}

local function parseBoolean(value, defaultValue)
    if type(value) == "boolean" then return value end
    if type(value) ~= "string" then return defaultValue end
    local normalized = string.lower(value)
    if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on" then return true end
    if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" then return false end
    return defaultValue
end

local function trim(value)
    value = tostring(value or "")
    value = string.gsub(value, "^%s+", "")
    return string.gsub(value, "%s+$", "")
end

local function readConfigFile(path)
    local readerFactory = rawget(_G, "getFileReader")
    if type(readerFactory) ~= "function" then return {} end
    local okOpen, handle = pcall(readerFactory, path, false)
    if not okOpen or handle == nil then return {} end
    local values, malformed, lineCount = {}, false, 0
    local okRead = pcall(function()
        while true do
            local line = handle:readLine()
            if line == nil then break end
            lineCount = lineCount + 1
            if lineCount > 128 or type(line) ~= "string" or #line > 4096 then malformed = true break end
            line = trim(line)
            if line ~= "" and string.sub(line, 1, 1) ~= "#" and string.sub(line, 1, 1) ~= ";" then
                local key, value = string.match(line, "^([A-Za-z][A-Za-z0-9_]*)%s*=%s*(.*)$")
                if key == nil then malformed = true break end
                values[key] = trim(value)
            end
        end
    end)
    pcall(function() handle:close() end)
    if not okRead or malformed then return {} end
    return values
end

local function readServerOption(name, defaultValue)
    if type(getServerOptions) ~= "function" then return defaultValue end
    local ok, options = pcall(getServerOptions)
    if not ok or options == nil then return defaultValue end
    local okValue, value = pcall(function()
        if type(options.getOptionByName) == "function" then
            local option = options:getOptionByName(name)
            if option ~= nil and type(option.getValue) == "function" then return option:getValue() end
            return option
        end
        return options[name]
    end)
    return okValue and value ~= nil and value or defaultValue
end

local function boundedNumber(value, defaultValue, minimum, maximum)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or n < minimum or n > maximum then return defaultValue end
    return n
end

local function boundedInteger(value, defaultValue, minimum, maximum)
    local n = boundedNumber(value, defaultValue, minimum, maximum)
    if math.floor(n) ~= n then return defaultValue end
    return n
end

local function safeBridgeRoot(value)
    return type(value) == "string" and #value >= 1 and #value <= 96
        and string.find(value, "^[A-Za-z0-9][A-Za-z0-9%._%-]*(/[A-Za-z0-9][A-Za-z0-9%._%-]*)*$") ~= nil
        and not string.find(value, "%.%.")
end

local function parseCommanders(value)
    local result = {}
    if type(value) ~= "string" or #value > 2048 then return result end
    for raw in string.gmatch(value .. ",", "([^,]*),") do
        local name = trim(raw)
        if name ~= "" and #name <= 96 and string.find(name, "^[A-Za-z0-9_%-]+$") then result[string.lower(name)] = true end
    end
    return result
end

function Config.refresh()
    Config.fileOptions = readConfigFile(Config.defaultBridgeRoot .. "/" .. Config.configFileName)
    local function option(name, defaultValue)
        if Config.fileOptions[name] ~= nil then return Config.fileOptions[name] end
        return readServerOption(name, defaultValue)
    end

    Config.enabled = parseBoolean(option("GoblinEnabled", Config.enabled), Config.enabled)
    local root = option("GoblinBridgeRoot", "")
    Config.bridgeRootOverride = safeBridgeRoot(root) and root or ""

    local npcId = option("GoblinNpcId", Config.npcId)
    if type(npcId) == "string" and #npcId >= 1 and #npcId <= 96 and string.find(npcId, "^[A-Za-z0-9_%.:%-]+$") then Config.npcId = npcId end
    local npcName = option("GoblinNpcName", Config.npcName)
    if type(npcName) == "string" and #npcName >= 1 and #npcName <= 32 then Config.npcName = npcName end

    -- Asset registration and the companion loadout are fixed package contracts.
    Config.weaponType = "Base.DoubleBarrelShotgun"
    Config.npcVisualAsset = "Goblin_Community_Human"
    Config.npcVisualItemType = "GoblinSurvivor.Goblin_MysteryBody"
    Config.npcSkinTexture = "Goblin/GoblinNativeSkin"

    Config.protected = parseBoolean(option("GoblinNpcProtected", Config.protected), Config.protected)
    Config.trackerExactTelemetry = parseBoolean(option("GoblinTrackerExact", Config.trackerExactTelemetry), Config.trackerExactTelemetry)
    Config.followPreferredDistance = 3.0 -- outside the native chair-rest threat ring
    Config.followWalkDistance = boundedInteger(option("GoblinFollowWalkDistance", Config.followWalkDistance), Config.followWalkDistance, 2, 16)
    Config.followRunDistance = boundedInteger(option("GoblinFollowRunDistance", Config.followRunDistance), Config.followRunDistance, 6, 32)
    Config.spawnOffsetTiles = boundedInteger(option("GoblinSpawnOffset", Config.spawnOffsetTiles), Config.spawnOffsetTiles, 2, 16)
    Config.repathSeconds = boundedNumber(option("GoblinRepathSeconds", Config.repathSeconds), Config.repathSeconds, 0.25, 10)
    Config.blockedRetrySeconds = boundedNumber(option("GoblinBlockedRetrySeconds", Config.blockedRetrySeconds), Config.blockedRetrySeconds, 0.5, 60)
    Config.respawnSeconds = boundedNumber(option("GoblinRespawnSeconds", Config.respawnSeconds), Config.respawnSeconds, 0, 3600)
    Config.combatRadius = boundedNumber(option("GoblinCombatRadius", Config.combatRadius), Config.combatRadius, 4, 64)
    Config.rangedRange = boundedNumber(option("GoblinRangedRange", Config.rangedRange), Config.rangedRange, 4, 30)
    Config.rangedCooldownSeconds = boundedNumber(option("GoblinRangedCooldownSeconds", Config.rangedCooldownSeconds), Config.rangedCooldownSeconds, 0.2, 5)
    Config.stuckTimeoutSeconds = boundedNumber(option("GoblinStuckTimeoutSeconds", Config.stuckTimeoutSeconds), Config.stuckTimeoutSeconds, 2, 60)
    Config.maxRecoveryAttempts = boundedInteger(option("GoblinMaxRecoveryAttempts", Config.maxRecoveryAttempts), Config.maxRecoveryAttempts, 0, 8)
    Config.lootRadius = boundedNumber(option("GoblinLootRadius", Config.lootRadius), Config.lootRadius, 1, 20)
    Config.lootScanSeconds = boundedNumber(option("GoblinLootScanSeconds", Config.lootScanSeconds), Config.lootScanSeconds, 0.5, 30)
    Config.lootMaxItemsPerTask = boundedInteger(option("GoblinLootMaxItemsPerTask", Config.lootMaxItemsPerTask), Config.lootMaxItemsPerTask, 1, 32)
    Config.autonomyEnabled = parseBoolean(option("GoblinAutonomyEnabled", Config.autonomyEnabled), Config.autonomyEnabled)
    Config.autonomyIdleSeconds = boundedNumber(option("GoblinAutonomyIdleSeconds", Config.autonomyIdleSeconds), Config.autonomyIdleSeconds, 30, 3600)
    Config.autonomyDecisionSeconds = boundedNumber(option("GoblinAutonomyDecisionSeconds", Config.autonomyDecisionSeconds), Config.autonomyDecisionSeconds, 2, 120)
    Config.autonomyExploreRadius = boundedNumber(option("GoblinAutonomyExploreRadius", Config.autonomyExploreRadius), Config.autonomyExploreRadius, 8, 40)
    Config.autonomyWorkRadius = boundedNumber(option("GoblinAutonomyWorkRadius", Config.autonomyWorkRadius), Config.autonomyWorkRadius, 3, 32)
    Config.autonomyBarricadeRadius = boundedNumber(option("GoblinAutonomyBarricadeRadius", Config.autonomyBarricadeRadius), Config.autonomyBarricadeRadius, 2, 20)

    if Config.followWalkDistance <= Config.followPreferredDistance then Config.followWalkDistance = Config.followPreferredDistance + 1 end
    if Config.followRunDistance <= Config.followWalkDistance then Config.followRunDistance = Config.followWalkDistance + 1 end
    Config.commanders = parseCommanders(option("GoblinCommanders", ""))
    return Config
end

local function playerUsername(player)
    if player == nil or type(player.getUsername) ~= "function" then return "" end
    local ok, value = pcall(function() return player:getUsername() end)
    return ok and type(value) == "string" and value or ""
end

function Config.isAuthorizedPlayer(player)
    local name = playerUsername(player)
    if name ~= "" and Config.commanders[string.lower(name)] == true then return true end
    if player == nil then return false end
    local level = ""
    if type(player.getAccessLevel) == "function" then
        local ok, value = pcall(function() return player:getAccessLevel() end)
        if ok and type(value) == "string" then level = string.lower(value) end
    end
    if level == "admin" or level == "moderator" then return true end
    if type(player.isAdmin) == "function" then
        local ok, value = pcall(function() return player:isAdmin() end)
        if ok and value == true then return true end
    end
    return false
end

function Config.readOption(name, defaultValue)
    if Config.fileOptions[name] ~= nil then return Config.fileOptions[name] end
    return readServerOption(name, defaultValue)
end

function Config.bridgeRoot()
    return Config.bridgeRootOverride ~= "" and Config.bridgeRootOverride or Config.defaultBridgeRoot
end

return Config

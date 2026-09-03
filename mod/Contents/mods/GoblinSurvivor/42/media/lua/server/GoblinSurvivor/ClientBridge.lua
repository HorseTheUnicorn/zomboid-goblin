local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")
local IPC = require("GoblinSurvivor/IPC")
local Manifest = require("GoblinSurvivor/Manifest")
local CharacterCatalog = require("GoblinSurvivor/CharacterCatalog")

local ClientBridge = {
    started = false,
    clientId = nil,
    clientPlayer = nil,
    clientUsername = nil,
    clientManifest = nil,
    clientCatalogVersion = nil,
    clientState = nil,
    lastHello = 0,
    lastState = 0,
    lastCharacterResult = nil,
    lastActionResult = nil
}

local helloKeys = {
    client_username = true,
    game_build = true,
    client_mod_manifest = true,
    catalog_version = true
}

local catalogKeys = {
    client_username = true,
    catalog = true
}

local stateKeys = {
    client_username = true,
    body_present = true,
    alive = true,
    character_state = true,
    character_generation = true,
    client_catalog_version = true,
    hunger = true,
    thirst = true,
    fatigue = true,
    panic = true,
    injury = true,
    threat_level = true,
    mode = true,
    weapon_ready = true,
    has_food = true,
    has_water = true,
    has_medical = true,
    action_busy = true,
    last_action = true
}

local characterResultKeys = {
    client_username = true,
    request_id = true,
    generation = true,
    status = true,
    detail = true
}

local actionResultKeys = {
    client_username = true,
    request_id = true,
    action = true,
    status = true,
    detail = true
}

local eventKeys = {
    client_username = true,
    request_id = true,
    kind = true,
    player = true,
    party = true,
    mood = true,
    threat_level = true,
    count_bucket = true,
    severity = true,
    body_part = true,
    category = true,
    rarity = true,
    cause = true,
    cooldown_seconds = true,
    speaker = true,
    text = true
}

local eventSchemas = {
    player_joined = {player = true, party = true},
    player_left = {player = true, party = true},
    goblin_spotted = {player = true, mood = true},
    threat_changed = {threat_level = true, count_bucket = true},
    injury = {severity = true, body_part = true},
    loot_found = {category = true, rarity = true},
    death = {cause = true},
    respawn = {cooldown_seconds = true},
    chat = {speaker = true, text = true}
}

local validCharacterStates = {
    fresh = true,
    creation_pending = true,
    active = true,
    dead = true,
    recreate_required = true
}

local validThreats = {
    none = true,
    near = true,
    overwhelming = true
}

local validModes = {
    SAFE = true,
    ROAM = true,
    PARTY = true,
    HUNT = true
}

local intentActions = {
    WAIT = "NOOP",
    SAY = "SAY",
    MOVE_TO = "MOVE_TO",
    FOLLOW = "FOLLOW",
    SEARCH = "SEARCH",
    SCAVENGE = "SCAVENGE",
    RETREAT = "RETREAT",
    REST = "REST",
    GO_HOME = "GO_HOME",
    JOIN_PARTY = "JOIN_PARTY",
    LEAVE_PARTY = "LEAVE_PARTY",
    HUNT_START = "NOOP",
    HUNT_HINT = "SAY",
    HUNT_RELOCATE = "MOVE_TO",
    HUNT_REWARD = "CLAIM_REWARD",
    TRADE = "MOVE_TO",
    HELP = "FOLLOW"
}

-- This is the complete typed client adapter surface.  A deterministic
-- controller action is still checked here even though the client repeats the
-- check; the server must never forward an arbitrary action string.
local clientActions = {
    NOOP = true,
    SAY = true,
    MOVE_TO = true,
    FOLLOW = true,
    SEARCH = true,
    SCAVENGE = true,
    RETREAT = true,
    REST = true,
    GO_HOME = true,
    JOIN_PARTY = true,
    LEAVE_PARTY = true,
    ATTACK = true,
    FLEE = true,
    EAT = true,
    DRINK = true,
    BANDAGE = true,
    RELOAD = true,
    CLAIM_REWARD = true
}

local function nowSeconds()
    return os.time()
end

local function log(message)
    print("[GoblinSurvivor] " .. tostring(message))
end

local function boundedRequestId(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 128
        and string.find(value, "^[A-Za-z0-9][A-Za-z0-9%._:%-]*$") ~= nil
end

local function boundedDetail(value)
    return type(value) == "string" and Net.safeText(value, 512, true)
end

local function playerUsername(player)
    if player == nil or type(player.getUsername) ~= "function" then
        return nil
    end
    local ok, username = pcall(function() return tostring(player:getUsername()) end)
    if ok and username ~= "nil" then
        return username
    end
    return nil
end

local function onlinePlayers()
    local getter = rawget(_G, "getOnlinePlayers")
    if type(getter) ~= "function" then
        return nil
    end
    local ok, players = pcall(getter)
    if ok and players ~= nil then
        return players
    end
    return nil
end

local function findBodyPlayer()
    local players = onlinePlayers()
    if players == nil or type(players.size) ~= "function" or type(players.get) ~= "function" then
        return nil
    end
    local okSize, size = pcall(function() return players:size() end)
    if not okSize or type(size) ~= "number" then
        return nil
    end
    for index = 0, size - 1 do
        local okPlayer, player = pcall(function() return players:get(index) end)
        if okPlayer and playerUsername(player) == Config.bodyUsername then
            return player
        end
    end
    return nil
end

local function sameClient(player, clientId)
    if ClientBridge.clientId ~= nil and clientId ~= nil
        and tostring(ClientBridge.clientId) == tostring(clientId) then
        return true
    end
    if ClientBridge.clientPlayer ~= nil and player ~= nil and ClientBridge.clientPlayer == player then
        return true
    end
    return player ~= nil and playerUsername(player) == ClientBridge.clientUsername
end

local function bindClient(player, clientId)
    if clientId == nil and player == nil then
        return false
    end
    local currentBody = findBodyPlayer()
    if ClientBridge.clientId ~= nil or ClientBridge.clientPlayer ~= nil then
        if not sameClient(currentBody, clientId) then
            -- Do not let a second connected client take over Goblin.  A
            -- reconnect is allowed once the old body username is gone.
            if currentBody ~= nil then
                return false
            end
        end
    end
    if clientId ~= nil then
        ClientBridge.clientId = clientId
    end
    if player ~= nil then
        ClientBridge.clientPlayer = player
    end
    ClientBridge.clientUsername = Config.bodyUsername
    return true
end

local function send(command, args)
    if ClientBridge.clientPlayer ~= nil
        and playerUsername(ClientBridge.clientPlayer) == Config.bodyUsername then
        if Net.sendServerToPlayer(ClientBridge.clientPlayer, command, args) then
            return true
        end
    end
    if ClientBridge.clientId ~= nil then
        return Net.sendServerToClientId(ClientBridge.clientId, command, args)
    end
    return false
end

local function serverManifest()
    return Manifest.get()
end

local function parity()
    return Manifest.parity(serverManifest(), ClientBridge.clientManifest)
end

local function validRecentHello()
    return ClientBridge.lastHello > 0 and nowSeconds() - ClientBridge.lastHello <= 30
end

local function welcome(status, detail)
    local args = {
        status = status or "ok",
        server_enabled = Config.enabled,
        expected_username = Config.bodyUsername,
        control_ready = ClientBridge.clientControlReady(),
        catalog_required = true,
        character_state = ClientBridge.clientState and ClientBridge.clientState.character_state or "fresh",
        character_generation = ClientBridge.clientState and ClientBridge.clientState.character_generation or 0
    }
    local manifest = serverManifest()
    if manifest ~= nil then
        args.server_manifest = manifest
    end
    if detail then
        args.detail = string.sub(tostring(detail), 1, 256)
    end
    return send("welcome", args)
end

local function validHello(args)
    if not Net.allowedKeys(args, helloKeys)
        or type(args.client_username) ~= "string"
        or args.client_username ~= Config.bodyUsername
        or not Net.safeText(args.game_build, 64, false) then
        return false
    end
    if args.client_mod_manifest ~= nil
        and (type(args.client_mod_manifest) ~= "table"
            or not Net.validManifest(args.client_mod_manifest)
            or args.game_build ~= args.client_mod_manifest.game_build) then
        return false
    end
    if args.catalog_version ~= nil and not Net.safeId(args.catalog_version, 64) then
        return false
    end
    return true
end

local function handleHello(args, player, clientId)
    if type(args) ~= "table" or not Net.safeTable(args) then
        return false
    end
    if not validHello(args) then
        -- A malformed hello is never a body claim.  If the transport identity
        -- is already bound, return a bounded diagnostic; otherwise remain
        -- silent so an arbitrary client cannot probe the Goblin channel.
        if sameClient(player, clientId) then
            welcome("rejected", "hello failed validation")
        end
        return false
    end
    if not bindClient(player, clientId) then
        return false
    end
    ClientBridge.clientManifest = args.client_mod_manifest
    ClientBridge.clientCatalogVersion = args.catalog_version
    ClientBridge.lastHello = nowSeconds()
    welcome("ok", nil)
    return true
end

local function handleCatalog(args, player, clientId)
    if not Net.allowedKeys(args, catalogKeys)
        or args.client_username ~= Config.bodyUsername
        or not sameClient(player, clientId)
        or type(args.catalog) ~= "table" then
        return false
    end
    local accepted, reason = CharacterCatalog.set(args.catalog)
    if not accepted then
        ClientBridge.clientCatalogVersion = nil
        ClientBridge.clientState = nil
        log("client catalog rejected: " .. tostring(reason))
        return false
    end
    ClientBridge.clientCatalogVersion = args.catalog.version
    ClientBridge.lastHello = nowSeconds()
    welcome("ok", nil)
    return true
end

local function boundedMetric(value)
    return Net.safeNumber(value, 0, 1)
end

local function validState(args)
    if not Net.allowedKeys(args, stateKeys)
        or args.client_username ~= Config.bodyUsername
        or type(args.body_present) ~= "boolean"
        or type(args.alive) ~= "boolean"
        or type(args.character_state) ~= "string"
        or not validCharacterStates[args.character_state]
        or type(args.character_generation) ~= "number"
        or math.floor(args.character_generation) ~= args.character_generation
        or args.character_generation < 0
        or args.character_generation > 2147483647 then
        return false
    end
    if args.client_catalog_version ~= nil and not Net.safeId(args.client_catalog_version, 64) then
        return false
    end
    for _, key in ipairs({"hunger", "thirst", "fatigue", "panic", "injury"}) do
        if args[key] ~= nil and not boundedMetric(args[key]) then
            return false
        end
    end
    if args.threat_level ~= nil
        and (type(args.threat_level) ~= "string" or not validThreats[args.threat_level]) then
        return false
    end
    if args.mode ~= nil
        and (type(args.mode) ~= "string" or not validModes[args.mode]) then
        return false
    end
    for _, key in ipairs({"weapon_ready", "has_food", "has_water", "has_medical", "action_busy"}) do
        if args[key] ~= nil and type(args[key]) ~= "boolean" then
            return false
        end
    end
    if args.last_action ~= nil and not Net.safeText(args.last_action, 64, false) then
        return false
    end
    return true
end

local function handleState(args, player, clientId)
    if type(args) ~= "table" or not Net.safeTable(args)
        or not validState(args)
        or not sameClient(player, clientId) then
        return false
    end
    local bodyPresent = args.body_present
        and player ~= nil
        and playerUsername(player) == Config.bodyUsername
    local state = {
        body_present = bodyPresent == true,
        alive = args.alive,
        character_state = args.character_state,
        character_generation = args.character_generation,
        client_catalog_version = args.client_catalog_version,
        hunger = args.hunger or 0,
        thirst = args.thirst or 0,
        fatigue = args.fatigue or 0,
        panic = args.panic or 0,
        injury = args.injury or 0,
        threat_level = args.threat_level or "none",
        mode = args.mode or "SAFE",
        weapon_ready = args.weapon_ready == true,
        has_food = args.has_food == true,
        has_water = args.has_water == true,
        has_medical = args.has_medical == true,
        action_busy = args.action_busy == true,
        last_action = args.last_action
    }
    ClientBridge.clientPlayer = player or ClientBridge.clientPlayer
    ClientBridge.clientState = state
    ClientBridge.lastState = nowSeconds()
    return true
end

local function handleCharacterResult(args, player, clientId)
    if not Net.allowedKeys(args, characterResultKeys)
        or args.client_username ~= Config.bodyUsername
        or not sameClient(player, clientId)
        or not boundedRequestId(args.request_id)
        or type(args.generation) ~= "number"
        or math.floor(args.generation) ~= args.generation
        or args.generation < 1
        or args.generation > 2147483647
        or (args.status ~= "accepted" and args.status ~= "rejected")
        or not boundedDetail(args.detail) then
        return false
    end
    ClientBridge.lastCharacterResult = {
        request_id = args.request_id,
        generation = args.generation,
        status = args.status,
        detail = args.detail
    }
    return true
end

local function handleActionResult(args, player, clientId)
    if not Net.allowedKeys(args, actionResultKeys)
        or args.client_username ~= Config.bodyUsername
        or not sameClient(player, clientId)
        or not boundedRequestId(args.request_id)
        or not Net.safeText(args.action, 32, false)
        or not string.find(args.action, "^[A-Z_]+$")
        or (args.status ~= "accepted" and args.status ~= "rejected" and args.status ~= "busy")
        or not boundedDetail(args.detail) then
        return false
    end
    ClientBridge.lastActionResult = {
        request_id = args.request_id,
        action = args.action,
        status = args.status,
        detail = args.detail
    }
    return true
end

local function safeEventText(value, maximum)
    if not Net.safeText(value, maximum, false) then
        return false
    end
    local lower = string.lower(value)
    if string.find(lower, "coordinates")
        or string.find(lower, "x%s*[:=]")
        or string.find(lower, "y%s*[:=]")
        or string.find(lower, "z%s*[:=]")
        or string.find(lower, "cell%s*[:=]")
        or string.find(lower, "chunk%s*[:=]") then
        return false
    end
    return true
end

local function validEvent(args)
    if not Net.allowedKeys(args, eventKeys)
        or args.client_username ~= Config.bodyUsername
        or not boundedRequestId(args.request_id)
        or type(args.kind) ~= "string"
        or eventSchemas[args.kind] == nil then
        return false
    end
    local schema = eventSchemas[args.kind]
    for key, _ in pairs(args) do
        if key ~= "client_username" and key ~= "request_id" and key ~= "kind"
            and not schema[key] then
            return false
        end
    end
    for key, _ in pairs(schema) do
        if args[key] == nil then
            return false
        end
    end
    if args.player ~= nil and not safeEventText(args.player, 96) then
        return false
    end
    if args.party ~= nil and not safeEventText(args.party, 96) then
        return false
    end
    if args.mood ~= nil and not safeEventText(args.mood, 64) then
        return false
    end
    if args.body_part ~= nil and not safeEventText(args.body_part, 64) then
        return false
    end
    if args.cause ~= nil and not safeEventText(args.cause, 128) then
        return false
    end
    if args.speaker ~= nil and not safeEventText(args.speaker, 96) then
        return false
    end
    if args.text ~= nil and not safeEventText(args.text, 240) then
        return false
    end
    if args.threat_level ~= nil and not validThreats[args.threat_level] then
        return false
    end
    if args.count_bucket ~= nil
        and args.count_bucket ~= "none"
        and args.count_bucket ~= "few"
        and args.count_bucket ~= "many" then
        return false
    end
    if args.severity ~= nil
        and args.severity ~= "minor"
        and args.severity ~= "moderate"
        and args.severity ~= "critical" then
        return false
    end
    if args.category ~= nil and not safeEventText(args.category, 64) then
        return false
    end
    if args.rarity ~= nil
        and args.rarity ~= "common"
        and args.rarity ~= "uncommon"
        and args.rarity ~= "rare"
        and args.rarity ~= "legendary" then
        return false
    end
    if args.cooldown_seconds ~= nil
        and (type(args.cooldown_seconds) ~= "number"
            or math.floor(args.cooldown_seconds) ~= args.cooldown_seconds
            or args.cooldown_seconds < 0 or args.cooldown_seconds > 28800) then
        return false
    end
    return true
end

local function handleEvent(args, player, clientId)
    if not Config.enabled or type(args) ~= "table"
        or not Net.safeTable(args)
        or not validEvent(args)
        or not sameClient(player, clientId) then
        return false
    end
    local message = {
        protocol = Config.protocol,
        request_id = args.request_id,
        timestamp_ms = nowSeconds() * 1000,
        type = "event." .. args.kind
    }
    for key, value in pairs(args) do
        if key ~= "client_username" and key ~= "request_id" and key ~= "kind" then
            message[key] = value
        end
    end
    if not IPC.publish("events", message, args.request_id) then
        return false
    end
    return true
end

function ClientBridge.onClientCommand(module, command, player, args, clientId)
    if module ~= Net.module or type(command) ~= "string" then
        return
    end
    if command == "hello" then
        handleHello(args, player, clientId)
    elseif command == "catalog" then
        handleCatalog(args, player, clientId)
    elseif command == "state" then
        handleState(args, player, clientId)
    elseif command == "character_result" then
        handleCharacterResult(args, player, clientId)
    elseif command == "action_result" then
        handleActionResult(args, player, clientId)
    elseif command == "event" then
        handleEvent(args, player, clientId)
    end
end

function ClientBridge.start()
    if ClientBridge.started then
        return
    end
    if Events and Events.OnClientCommand and type(Events.OnClientCommand.Add) == "function" then
        Events.OnClientCommand.Add(ClientBridge.onClientCommand)
        ClientBridge.started = true
    end
end

function ClientBridge.clientControlReady()
    if not Config.enabled or not validRecentHello() then
        return false
    end
    local status = Manifest.controlCompatibility(serverManifest(), ClientBridge.clientManifest)
    -- The catalog is only needed for the one-time character-creation path.
    -- An already-existing native player must be controllable even when a
    -- Build 42 client cannot enumerate every creation-screen option.
    return status == "compatible"
end

function ClientBridge.bodyPresent()
    local player = findBodyPlayer()
    return Config.enabled
        and ClientBridge.clientControlReady()
        and player ~= nil
        and ClientBridge.clientState ~= nil
        and ClientBridge.clientState.body_present == true
        and ClientBridge.clientState.alive == true
end

function ClientBridge.state()
    if ClientBridge.clientState == nil then
        return {
            body_present = false,
            client_control_ready = ClientBridge.clientControlReady(),
            alive = false,
            character_state = "fresh",
            character_generation = 0,
            mode = "SAFE",
            threat_level = "none"
        }
    end
    local result = {}
    for key, value in pairs(ClientBridge.clientState) do
        result[key] = value
    end
    result.body_present = ClientBridge.bodyPresent()
    result.client_control_ready = ClientBridge.clientControlReady()
    return result
end

function ClientBridge.manifest()
    return ClientBridge.clientManifest
end

function ClientBridge.serverManifest()
    return serverManifest()
end

function ClientBridge.parityStatus()
    local status, reason = parity()
    return status, reason
end

function ClientBridge.controlCompatibilityStatus()
    return Manifest.controlCompatibility(serverManifest(), ClientBridge.clientManifest)
end

function ClientBridge.catalog()
    return CharacterCatalog.get()
end

function ClientBridge.lastResults()
    return ClientBridge.lastCharacterResult, ClientBridge.lastActionResult
end

function ClientBridge.requestRecreation(message)
    if not ClientBridge.clientControlReady() then
        return false, "client control or exact mod compatibility is unavailable"
    end
    if type(message) ~= "table"
        or not boundedRequestId(message.request_id)
        or (message.generation ~= nil
            and (type(message.generation) ~= "number"
                or math.floor(message.generation) ~= message.generation
                or message.generation < 1
                or message.generation > 2147483647)) then
        return false, "recreation command envelope is invalid"
    end
    local args = {
        request_id = message.request_id
    }
    if message.generation ~= nil then
        args.generation = message.generation
    end
    if not send("recreate", args) then
        return false, "recreation request could not be sent to the native PZ client"
    end
    return true, "native PZ client was asked to enter vanilla character creation"
end

function ClientBridge.sendCharacterCreate(message)
    if not ClientBridge.clientControlReady() then
        return false, "client control or exact mod parity is unavailable"
    end
    if type(message) ~= "table"
        or not boundedRequestId(message.request_id)
        or type(message.generation) ~= "number"
        or math.floor(message.generation) ~= message.generation
        or message.generation < 1
        or not Net.safeId(message.catalog_version, 64)
        or message.catalog_version ~= ClientBridge.clientCatalogVersion
        or type(message.proposal) ~= "table"
        or not Net.safeTable(message.proposal) then
        return false, "character command envelope is invalid"
    end
    local args = {
        request_id = message.request_id,
        generation = message.generation,
        catalog_version = message.catalog_version,
        proposal = message.proposal
    }
    if not Net.safeTable(args) then
        return false, "character command contains unsafe fields"
    end
    if not send("character_create", args) then
        return false, "client command could not be sent"
    end
    return true, "character command sent to the native PZ client"
end

function ClientBridge.sendIntent(message)
    if not ClientBridge.bodyPresent() then
        return false, "Goblin body is not present"
    end
    if type(message) ~= "table" or not boundedRequestId(message.request_id) then
        return false, "intent envelope is invalid"
    end
    local intent = type(message.intent) == "string" and string.upper(message.intent) or ""
    local action = intentActions[intent]
    local typed = message.controller_action
    if typed ~= nil and (type(typed) ~= "table" or not Net.safeTable(typed)) then
        return false, "deterministic controller action is invalid"
    end
    if typed ~= nil then
        action = type(typed.action) == "string" and string.upper(typed.action) or ""
    end
    if action == nil or action == "" then
        return false, "intent is outside the typed client allowlist"
    end
    if not clientActions[action] then
        return false, "deterministic action is outside the typed client allowlist"
    end
    local args = {
        request_id = message.request_id,
        action = action,
        mode = message.mode,
        priority = message.priority or 1
    }
    if typed ~= nil then
        if typed.priority ~= nil then
            args.priority = typed.priority
        end
    end
    local target = (typed ~= nil and typed.target) or message.target or message.candidate
    if target ~= nil then
        if type(target) ~= "table" then
            return false, "intent target is invalid"
        end
        args.target_kind = target.kind
        args.target_label = target.name or target.label or target.player
    end
    if message.text ~= nil then
        args.text = message.text
    end
    local item = (typed ~= nil and typed.item) or message.item
    if item ~= nil then
        if type(item) ~= "table" then
            return false, "intent item is invalid"
        end
        args.item_name = item.name
        args.item_count = item.count
    end
    if not Net.safeTable(args)
        or not Net.safeText(args.mode, 16, false)
        or not validModes[args.mode]
        or not Net.safeText(args.action, 32, false)
        or not string.find(args.action, "^[A-Z_]+$")
        or not Net.safeNumber(args.priority, 0, 3) then
        return false, "typed intent failed server-side transport validation"
    end
    if args.target_kind ~= nil then
        if not Net.safeText(args.target_kind, 32, false)
            or not Net.safeText(args.target_label, 96, false) then
            return false, "intent target label is invalid"
        end
    end
    if args.text ~= nil and not Net.safeText(args.text, 240, false) then
        return false, "intent text is invalid"
    end
    if args.item_name ~= nil
        and (not Net.safeText(args.item_name, 96, false)
            or not Net.safeNumber(args.item_count, 1, 10)
            or math.floor(args.item_count) ~= args.item_count) then
        return false, "intent item is invalid"
    end
    if action == "SAY" and args.text == nil then
        return false, "say action has no text"
    end
    if not send("action", args) then
        return false, "client action could not be sent"
    end
    return true, "typed action sent to the native PZ client"
end

return ClientBridge

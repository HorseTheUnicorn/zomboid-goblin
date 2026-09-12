local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")

-- A grant is minted only while handling an authoritative player command on
-- the PZ server.  Python may carry the opaque value through the private
-- bridge, but it cannot invent one and Qwen never receives it.
local Authority = { grants = {}, sequence = 0, offlineByNpc = {} }
Authority.offlineActions = { WAIT=true, LOOT_AREA=true, RETURN_TO_BASE=true, SECURE_BASE=true, EQUIP=true }

local privileged = {
    ENTER_VEHICLE = true, EXIT_VEHICLE = true,
    FARM = true, CRAFT = true, REPAIR_VEHICLE = true,
    OPEN_DOOR = true,
    OPEN_WINDOW = true,
    CLOSE_CURTAINS = true,
    FORM_SQUAD = true,
    DISMISS_SQUAD = true,
    ASSIGN_JOB = true,
    SECURE_BASE = true,
    BUILD = true
}

local GRANT_TTL_MS = 60000

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function randomPart()
    if type(math.random) ~= "function" then return "0" end
    local ok, value = pcall(math.random, 0, 2147483647)
    return ok and tostring(value) or "0"
end

local function username(player)
    if player == nil or type(player.getUsername) ~= "function" then return nil end
    local ok, value = pcall(function() return player:getUsername() end)
    if not ok or type(value) ~= "string" or #value < 1 or #value > 96 then return nil end
    if string.find(value, "[^A-Za-z0-9_%-]", 1) ~= nil then return nil end
    return value
end

local function purge(now)
    for token, grant in pairs(Authority.grants) do
        if type(grant) ~= "table" or type(grant.expires_at) ~= "number"
            or grant.expires_at <= now then
            Authority.grants[token] = nil
        end
    end
end

function Authority.requires(action)
    return type(action) == "string" and privileged[action] == true
end

function Authority.issue(player)
    local speaker = username(player)
    if speaker == nil then return nil end
    local now = nowMs()
    purge(now)
    Authority.sequence = Authority.sequence + 1
    local token = "grant-" .. tostring(now) .. "-" .. tostring(Authority.sequence)
        .. "-" .. randomPart()
    if not Net.safeId(token, 128) then return nil end
    Authority.grants[token] = {
        speaker = speaker,
        commander = Config.isAuthorizedPlayer(player),
        issued_at = now,
        expires_at = now + GRANT_TTL_MS
    }
    return token
end

function Authority.consume(message)
    if type(message) ~= "table" or not Authority.requires(message.action) then
        return true
    end
    local token = message.authority_token
    if not Net.safeId(token, 128) then return false end
    local now = nowMs()
    purge(now)
    local grant = Authority.grants[token]
    if grant == nil or grant.expires_at <= now then return false end
    if grant.kind == "offline" then return false end
    if type(message.owner) ~= "string" or string.lower(message.owner) ~= string.lower(grant.speaker) then return false end
    if not grant.commander and message.action ~= "BUILD" and message.action ~= "SECURE_BASE"
        and message.action ~= "ENTER_VEHICLE" and message.action ~= "EXIT_VEHICLE"
        and message.action ~= "OPEN_DOOR" and message.action ~= "OPEN_WINDOW"
        and message.action ~= "CLOSE_CURTAINS"
        and message.action ~= "FARM" and message.action ~= "CRAFT" and message.action ~= "REPAIR_VEHICLE" then return false end
    -- Grants are capabilities for one high-level mutation, not reusable
    -- session credentials.  A failed downstream action cannot be replayed.
    Authority.grants[token] = nil
    return true
end

-- A separate, one-use grant permits only bounded chores while the owner is
-- actually offline. Recheck live ownership and task sequence at execution time:
-- a slow model reply cannot override a reconnect or a later explicit order.
local function offlineBodyReady(body)
    local Body = require("GoblinSurvivor/GoblinBody")
    if not Config.enabled or not Config.autonomyEnabled or not Body.isGoblin(body) or not Body.exists(body) then return false end
    if type(getOnlinePlayers) ~= "function" then return false end
    local owner = Body.owner(body)
    for _, player in ipairs(require("GoblinSurvivor/GoblinWorld").values(getOnlinePlayers())) do
        if string.lower(player:getUsername()) == string.lower(owner) then return false end
    end
    local data = Body.data(body)
    return data.GoblinTask == "FOLLOW" or data.GoblinAutonomous == true
end

function Authority.issueOffline(body)
    if not offlineBodyReady(body) then return nil end
    local Body = require("GoblinSurvivor/GoblinBody")
    local data, now = Body.data(body), nowMs()
    purge(now)
    local previous = Authority.offlineByNpc[data.GoblinID]
    local grant = previous and Authority.grants[previous]
    if grant and grant.task_sequence == data.GoblinTaskSequence and grant.generation == data.GoblinGeneration then return previous end
    if previous then Authority.grants[previous] = nil end
    Authority.sequence = Authority.sequence + 1
    local token = "offline-" .. tostring(now) .. "-" .. tostring(Authority.sequence) .. "-" .. randomPart()
    Authority.grants[token] = {
        kind="offline", owner=data.GoblinOwner, npc_id=data.GoblinID,
        generation=data.GoblinGeneration, task_sequence=data.GoblinTaskSequence,
        expires_at=now+120000
    }
    Authority.offlineByNpc[data.GoblinID] = token
    return token
end

function Authority.consumeOffline(message, body)
    if not Authority.offlineActions[message.action] or not offlineBodyReady(body) then return false end
    local token = message.authority_token
    if not Net.safeId(token,128) then return false end
    purge(nowMs())
    local grant = Authority.grants[token]
    local data = require("GoblinSurvivor/GoblinBody").data(body)
    if not grant or grant.kind ~= "offline" or grant.owner ~= message.owner or
        grant.npc_id ~= message.npc_id or grant.generation ~= data.GoblinGeneration or
        grant.task_sequence ~= data.GoblinTaskSequence then return false end
    Authority.grants[token] = nil
    return true
end

function Authority.snapshot()
    local count = 0
    for _ in pairs(Authority.grants) do count = count + 1 end
    return { pending_grants = count }
end

return Authority

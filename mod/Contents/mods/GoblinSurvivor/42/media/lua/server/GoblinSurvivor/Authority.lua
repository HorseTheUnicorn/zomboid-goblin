local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")

-- A grant is minted only while handling an authoritative player command on
-- the PZ server.  Python may carry the opaque value through the private
-- bridge, but it cannot invent one and Qwen never receives it.
local Authority = { grants = {}, sequence = 0 }

local privileged = {
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
    if not Config.isAuthorizedPlayer(player) then return nil end
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
    -- Grants are capabilities for one high-level mutation, not reusable
    -- session credentials.  A failed downstream action cannot be replayed.
    Authority.grants[token] = nil
    return true
end

function Authority.snapshot()
    local count = 0
    for _ in pairs(Authority.grants) do count = count + 1 end
    return { pending_grants = count }
end

return Authority

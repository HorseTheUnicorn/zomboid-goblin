-- Opt-in local acceptance trace. Sampling is inert on ordinary clients.
-- Create Lua/goblin-m1-trace.flag containing "enabled" in that client's PZ
-- cache directory before launch to log actor positions at 10 Hz.
local function enabled()
    if type(getFileReader) ~= "function" then return false end
    local ok, reader = pcall(getFileReader, "goblin-m1-trace.flag", false)
    if not ok or not reader then return false end
    local readOK, line = pcall(function() return reader:readLine() end)
    pcall(function() reader:close() end)
    return readOK and line == "enabled"
end

local Trace = {}
local Config = require("GoblinSurvivor/Config")
local lastSampleAt = setmetatable({}, { __mode = "k" })
local armed, active = false, false

local function value(object, name, ...)
    if not object then return nil end
    local okMember, member = pcall(function() return object[name] end)
    if not okMember or type(member) ~= "function" then return nil end
    local ok, result = pcall(member, object, ...)
    if ok then return result end
    return nil
end

local function finite(number)
    return type(number) == "number" and number == number
        and number > -1000000 and number < 1000000
end

local function validStamp(number)
    return type(number) == "number" and number == number
        and number >= 0 and number < 1000000000000000
end

local function position(object)
    local x, y, z = value(object, "getX"), value(object, "getY"), value(object, "getZ")
    if finite(x) and finite(y) and finite(z) then return x, y, z end
    return nil
end

function Trace.sampleBody(body, state)
    if not armed then
        if type(isClient) ~= "function" or not isClient()
            or type(getPlayer) ~= "function" or not getPlayer() then return end
        active = enabled()
        armed = true
        if active then print("[GoblinSurvivor] M1_CLIENT_TRACE_READY") end
    end
    if not active or not body then return end
    local stamp = type(getTimestampMs) == "function" and getTimestampMs() or nil
    if not validStamp(stamp) or stamp - (lastSampleAt[body] or 0) < 100 then return end
    local player = type(getPlayer) == "function" and getPlayer() or nil
    local px, py, pz = position(player)
    if not px then return end
    local username = value(player, "getUsername")
    if type(username) ~= "string" or not username:match("^[%w_%-]+$") then return end
    local running = value(player, "isRunning")
    local sprinting = value(player, "isSprinting")
    local online = value(body, "getOnlineID")
    local id = type(state) == "table" and state.npc_id or nil
    local outfit = value(body, "getOutfitName")
    if not id and type(online) == "number" and online >= 0
        and outfit == Config.npcOutfit then
        id = "online." .. tostring(online)
    end
    if type(id) == "string" and id:match("^[%w_.%-]+$") then
        local x, y, z = position(body)
        local remote = value(body, "isRemoteZombie")
        if x then
            lastSampleAt[body] = stamp
            print(string.format(
                "[GoblinSurvivor] M1_CLIENT_TRACE t=%.0f client=%s id=%s online=%s remote=%s x=%.4f y=%.4f z=%.4f px=%.4f py=%.4f pz=%.4f prun=%s psprint=%s outfit=%s roster_outfit=%s",
                stamp, username, id, tostring(online), tostring(remote), x, y, z, px, py, pz,
                tostring(running), tostring(sprinting), tostring(value(body,"getPersistentOutfitID")),
                tostring(state and state.outfit_id)))
        end
    end
end

return Trace

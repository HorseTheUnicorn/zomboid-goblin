-- Small spawn-recovery shim for the rescue branch.
--
-- Persistent identity is kept, but a stale/offline owner must never prevent
-- the one Goblin body from existing.  When the saved owner is absent and a
-- player is online, bind the companion to the first connected player before
-- the normal spawner runs.  Explicit owner changes still use Spawner.setOwner.
local Spawner = require("GoblinSurvivor/GoblinSpawner")

local Recovery = { lastRebind = nil }

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, value = pcall(member, object, ...)
    return ok, value
end

local function username(player)
    local ok, value = call(player, "getUsername")
    return ok and type(value) == "string" and value or nil
end

local function onlinePlayers()
    local result = {}
    if type(getOnlinePlayers) ~= "function" then return result end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return result end
    local count = type(list.size) == "function" and list:size() or #list
    for index = 0, count - 1 do
        local player = type(list.get) == "function" and list:get(index) or list[index + 1]
        if player ~= nil then result[#result + 1] = player end
    end
    return result
end

function Recovery.ensureUsableOwner()
    local players = onlinePlayers()
    if #players == 0 then return false end

    local saved = Spawner.ownerName()
    if saved ~= nil then
        for _, player in ipairs(players) do
            local name = username(player)
            if name ~= nil and string.lower(name) == string.lower(saved) then
                return true
            end
        end
    end

    local replacement = username(players[1])
    if replacement == nil then return false end
    if not Spawner.setOwner(replacement) then return false end

    if Recovery.lastRebind ~= replacement then
        Recovery.lastRebind = replacement
        print("[GoblinSurvivor] OWNER_REBIND previous=" .. tostring(saved)
            .. " current=" .. tostring(replacement))
    end
    return true
end

return Recovery

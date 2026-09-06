-- Controlled donor-spawn entry points for GoblinSurvivor and local testing.
local Config = require("GoblinSurvivor/Config")
local Profiles = require("GoblinSurvivor/Profiles")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")
local Identity = require("GoblinSurvivor/Identity")
local Registry = require("GoblinSurvivor/GSSurvivorRegistry")

local Spawner = { testBody = nil, testProfile = nil }

local function anchor()
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return nil end
    if type(players.size) == "function" then
        local okSize, size = pcall(function() return players:size() end)
        if okSize and size > 0 then
            local okPlayer, player = pcall(function() return players:get(0) end)
            return okPlayer and player or nil
        end
    elseif type(players) == "table" then
        return players[1]
    end
    return nil
end

function Spawner.spawn(profile, player)
    profile = profile or Profiles.test()
    local body = Registry.body(profile.id)
    if body ~= nil and Identity.isManaged(body) then return body, "already present" end
    local origin = player or anchor()
    if origin == nil then return nil, "an online player anchor is required" end
    local ok, detail, created = NpcAdapter.spawnIndividual(
        origin, profile.id, "GoblinSurvivorNative", profile.displayName,
        profile.role, profile.id == "dev.test.001" and 8 or Config.npcSpawnOffsetTiles
    )
    if not ok or created == nil then return nil, detail or "native spawn failed" end
    if not Identity.isManaged(created) then
        return nil, "donor was not humanized by Survivorize"
    end
    Registry.bind(profile.id, created, profile)
    return created, detail
end

function Spawner.spawnTest(player)
    local body, detail = Spawner.spawn(Profiles.test(), player)
    if body ~= nil then
        Spawner.testBody, Spawner.testProfile = body, Profiles.test()
    end
    return body, detail
end

function Spawner.spawnGoblin(player)
    return Spawner.spawn(Profiles.goblin(), player)
end

function Spawner.test()
    if Spawner.testBody ~= nil and Identity.isManaged(Spawner.testBody) then
        return Spawner.testBody
    end
    return nil
end

return Spawner

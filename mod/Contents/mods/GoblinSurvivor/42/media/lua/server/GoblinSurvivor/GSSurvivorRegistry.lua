-- Logical survivor registry facade. Existing NPCRegistry remains the durable
-- Goblin/companion record store; this layer also tracks disposable dev bodies.
local Config = require("GoblinSurvivor/Config")
local Profiles = require("GoblinSurvivor/Profiles")
local Identity = require("GoblinSurvivor/Identity")
local NPCRegistry = require("GoblinSurvivor/NPCRegistry")

local Registry = { extras = {} }

function Registry.bind(id, body, profile)
    if type(id) ~= "string" or body == nil then return false end
    Registry.extras[id] = { body = body, profile = profile or Profiles.forId(id) }
    return true
end

function Registry.unbind(id)
    if Registry.extras[id] == nil then return false end
    Registry.extras[id] = nil
    return true
end

function Registry.body(id)
    local extra = Registry.extras[id]
    if extra ~= nil then return extra.body end
    return NPCRegistry.find(id)
end

function Registry.profile(id)
    local extra = Registry.extras[id]
    if extra ~= nil then return extra.profile end
    local entry = NPCRegistry.get(id)
    if entry == nil then return Profiles.forId(id) end
    return Profiles.forId(id, {
        displayName = entry.name,
        role = entry.role
    })
end

function Registry.bodyFor(entity)
    if entity == nil or not Identity.isManaged(entity) then return nil end
    local id = Identity.getId(entity)
    return id ~= nil and Registry.body(id) == entity and id or nil
end

function Registry.each(callback)
    if type(callback) ~= "function" then return end
    for _, id in ipairs(NPCRegistry.ids()) do
        local body = NPCRegistry.find(id)
        if body ~= nil and Identity.isManaged(body) then
            callback(body, Registry.profile(id), id)
        end
    end
    for id, extra in pairs(Registry.extras) do
        if extra.body ~= nil and Identity.isManaged(extra.body) then
            callback(extra.body, extra.profile, id)
        end
    end
end

function Registry.snapshot()
    local result = {}
    Registry.each(function(body, profile, id)
        local data = Identity.data(body)
        table.insert(result, {
            survivor_id = id,
            type = profile.type,
            name = profile.displayName,
            body_generation = Identity.bodyGeneration(body),
            body_present = true,
            role = profile.role,
            goal = data and data.goblin_goal or "IDLE"
        })
    end)
    return result
end

return Registry

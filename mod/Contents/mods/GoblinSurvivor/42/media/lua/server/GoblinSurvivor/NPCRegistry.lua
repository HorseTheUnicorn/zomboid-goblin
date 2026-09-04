local Config = require("GoblinSurvivor/Config")
local VanillaNpcAdapter = require("GoblinSurvivor/VanillaNpcAdapter")

local NPCRegistry = {
    entries = {},
    loaded = false,
    spawnPending = false
}

local function persistentData()
    if type(ModData) ~= "table" or type(ModData.getOrCreate) ~= "function" then
        return nil
    end
    local ok, data = pcall(ModData.getOrCreate, "GoblinSurvivor")
    return ok and type(data) == "table" and data or nil
end

local function onlineAnchor()
    if type(getOnlinePlayers) ~= "function" then
        return nil
    end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then
        return nil
    end
    if type(players.get) == "function" then
        local okFirst, player = pcall(function() return players:get(0) end)
        if okFirst then return player end
    end
    return players[1]
end

local function zombieList()
    if type(getCell) ~= "function" then
        return nil
    end
    local ok, cell = pcall(getCell)
    if not ok or cell == nil or type(cell.getZombieList) ~= "function" then
        return nil
    end
    local okList, zombies = pcall(function() return cell:getZombieList() end)
    return okList and zombies or nil
end

local function bodyExists(zombie)
    if zombie == nil or type(zombie.isExistInTheWorld) ~= "function" then
        return true
    end
    local ok, exists = pcall(function() return zombie:isExistInTheWorld() end)
    return not ok or exists == true
end

local function bindExisting()
    local list = zombieList()
    if list == nil then return nil end
    local count = type(list.size) == "function" and list:size() or #list
    for index = 0, count - 1 do
        local zombie = type(list.get) == "function" and list:get(index) or list[index + 1]
        if VanillaNpcAdapter.isOwned(zombie) then
            local entry = NPCRegistry.entries[Config.npcId]
            entry.zombie = zombie
            entry.active = true
            entry.alive = true
            NPCRegistry.spawnPending = false
            return zombie
        end
    end
    return nil
end

function NPCRegistry.load()
    if NPCRegistry.loaded then return end
    local data = persistentData()
    local saved = data and data.goblin or nil
    NPCRegistry.entries[Config.npcId] = {
        npc_id = Config.npcId,
        name = Config.npcName,
        role = Config.npcRole,
        engine = "vanilla-zombie",
        active = saved == nil or saved.active ~= false,
        alive = saved == nil or saved.alive ~= false,
        zombie = nil
    }
    NPCRegistry.loaded = true
end

function NPCRegistry.save()
    local data = persistentData()
    local entry = NPCRegistry.entries[Config.npcId]
    if data == nil or entry == nil then return false end
    data.goblin = {
        npc_id = entry.npc_id,
        name = entry.name,
        role = entry.role,
        active = entry.active,
        alive = entry.alive
    }
    if type(ModData.transmit) == "function" then
        pcall(ModData.transmit, "GoblinSurvivor")
    end
    return true
end

function NPCRegistry.get(npcId)
    NPCRegistry.load()
    return NPCRegistry.entries[npcId]
end

function NPCRegistry.findGoblin()
    NPCRegistry.load()
    local entry = NPCRegistry.entries[Config.npcId]
    if entry == nil or entry.zombie == nil then
        bindExisting()
    end
    if entry.zombie ~= nil and not bodyExists(entry.zombie) then
        entry.zombie = nil
        entry.alive = false
    elseif entry.zombie ~= nil and type(entry.zombie.isDead) == "function" then
        local okDead, dead = pcall(function() return entry.zombie:isDead() end)
        if okDead and dead then
            entry.zombie = nil
            entry.alive = false
        end
    end
    return entry.zombie
end

function NPCRegistry.spawnGoblin()
    NPCRegistry.load()
    local entry = NPCRegistry.entries[Config.npcId]
    if entry == nil or not entry.active then
        return nil, "Goblin is inactive"
    end
    local existing = NPCRegistry.findGoblin()
    if existing ~= nil then
        return existing, "already present"
    end
    if NPCRegistry.spawnPending then
        return nil, "spawn request pending"
    end
    local anchor = onlineAnchor()
    if anchor == nil then
        return nil, "waiting for an online player anchor"
    end
    NPCRegistry.spawnPending = true
    local ok, detail, zombie = VanillaNpcAdapter.spawnIndividual(
        anchor, entry.npc_id, Config.npcProgram
    )
    if not ok then
        NPCRegistry.spawnPending = false
        return nil, detail
    end
    NPCRegistry.spawnPending = false
    entry.zombie = zombie
    entry.alive = true
    NPCRegistry.save()
    return zombie, detail
end

function NPCRegistry.markRecovered(zombie)
    NPCRegistry.load()
    local entry = NPCRegistry.entries[Config.npcId]
    entry.zombie = zombie
    entry.active = true
    entry.alive = true
    NPCRegistry.spawnPending = false
    NPCRegistry.save()
end

function NPCRegistry.markDead()
    NPCRegistry.load()
    local entry = NPCRegistry.entries[Config.npcId]
    entry.zombie = nil
    entry.alive = false
    NPCRegistry.spawnPending = false
    NPCRegistry.save()
end

return NPCRegistry

local Config = require("GoblinSurvivor/Config")
local VanillaNpcAdapter = require("GoblinSurvivor/VanillaNpcAdapter")

local NPCRegistry = {
    entries = {},
    loaded = false,
    spawnPending = false,
    pendingSpawn = nil,
    spawnBlocked = false,
    spawnNextAt = 0
}

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

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
        local okSize, count = pcall(function() return players:size() end)
        if not okSize or type(count) ~= "number" or count < 1 then return nil end
        local okFirst, player = pcall(function() return players:get(0) end)
        if okFirst then return player end
    end
    if type(players) == "table" and #players < 1 then return nil end
    return players[1]
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
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
    if NPCRegistry.spawnPending and NPCRegistry.pendingSpawn ~= nil
        and nowMs() >= (NPCRegistry.pendingSpawn.deadline or 0) then
        -- The engine accepted a request but never delivered a bindable body.
        -- Close the request permanently for this server run; retrying here is
        -- what previously produced one new hostile zombie per game tick.
        NPCRegistry.spawnPending = false
        NPCRegistry.pendingSpawn = nil
        NPCRegistry.spawnBlocked = true
    end
    if entry == nil or entry.zombie == nil then
        bindExisting()
    end
    if entry.zombie ~= nil and not bodyExists(entry.zombie) then
        entry.zombie = nil
        entry.alive = false
        NPCRegistry.spawnBlocked = false
        NPCRegistry.spawnNextAt = nowMs() + 30000
    elseif entry.zombie ~= nil and type(entry.zombie.isDead) == "function" then
        local okDead, dead = pcall(function() return entry.zombie:isDead() end)
        if okDead and dead then
            entry.zombie = nil
            entry.alive = false
            NPCRegistry.spawnBlocked = false
            NPCRegistry.spawnNextAt = nowMs() + 30000
        end
    end
    return entry.zombie
end

function NPCRegistry.onZombieCreate(zombie)
    if zombie == nil or not NPCRegistry.spawnPending or NPCRegistry.pendingSpawn == nil then
        return false
    end
    local point = nil
    if type(zombie.getX) == "function" and type(zombie.getY) == "function"
        and type(zombie.getZ) == "function" then
        local ok, x, y, z = pcall(function()
            return zombie:getX(), zombie:getY(), zombie:getZ()
        end)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
            point = { x = x, y = y, z = z }
        end
    end
    -- Only claim a body created at the request point.  This prevents a normal
    -- population spawn from accidentally becoming Goblin while the request
    -- is pending.
    if point == nil or distanceSquared(point, NPCRegistry.pendingSpawn.point) > 25 then
        return false
    end
    NPCRegistry.load()
    local entry = NPCRegistry.entries[Config.npcId]
    if entry ~= nil and entry.zombie ~= nil then return false, "Goblin is already bound" end
    local prepared, detail = VanillaNpcAdapter.prepare(zombie, Config.npcId)
    if not prepared then return false, detail end
    entry.zombie = zombie
    entry.active = true
    entry.alive = true
    NPCRegistry.pendingSpawn = nil
    NPCRegistry.spawnPending = false
    NPCRegistry.spawnBlocked = true
    NPCRegistry.save()
    return true, "Goblin bound from OnZombieCreate"
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
    if NPCRegistry.spawnBlocked then
        return nil, "spawn disabled after one unbound-safe attempt"
    end
    if nowMs() < NPCRegistry.spawnNextAt then
        return nil, "spawn recovery cooldown"
    end
    local anchor = onlineAnchor()
    if anchor == nil then
        return nil, "waiting for an online player anchor"
    end
    local plannedPoint = VanillaNpcAdapter.spawnPoint(anchor)
    if plannedPoint == nil then
        return nil, "online player anchor has no safe spawn point"
    end
    NPCRegistry.spawnPending = true
    NPCRegistry.spawnBlocked = true
    NPCRegistry.pendingSpawn = {
        point = plannedPoint,
        deadline = nowMs() + 10000
    }
    local ok, detail, zombie, spawnPoint = VanillaNpcAdapter.spawnIndividual(
        anchor, entry.npc_id, Config.npcProgram
    )
    if not ok then
        NPCRegistry.spawnPending = false
        NPCRegistry.pendingSpawn = nil
        return nil, detail
    end
    -- OnZombieCreate may run synchronously inside the Java call.  Preserve
    -- that binding instead of replacing its cleared pending state below.
    if not NPCRegistry.spawnPending then
        return NPCRegistry.findGoblin(), detail
    end
    if zombie ~= nil then
        NPCRegistry.spawnPending = false
        NPCRegistry.pendingSpawn = nil
        entry.zombie = zombie
        entry.alive = true
        NPCRegistry.save()
        return zombie, detail
    end
    NPCRegistry.pendingSpawn = {
        point = spawnPoint or plannedPoint,
        deadline = nowMs() + 10000
    }
    NPCRegistry.spawnNextAt = nowMs() + 60000
    return nil, detail
end

function NPCRegistry.markRecovered(zombie)
    NPCRegistry.load()
    local entry = NPCRegistry.entries[Config.npcId]
    entry.zombie = zombie
    entry.active = true
    entry.alive = true
    NPCRegistry.spawnPending = false
    NPCRegistry.pendingSpawn = nil
    NPCRegistry.spawnBlocked = true
    NPCRegistry.save()
end

function NPCRegistry.markDead()
    NPCRegistry.load()
    local entry = NPCRegistry.entries[Config.npcId]
    entry.zombie = nil
    entry.alive = false
    NPCRegistry.spawnPending = false
    NPCRegistry.pendingSpawn = nil
    NPCRegistry.spawnBlocked = false
    NPCRegistry.spawnNextAt = nowMs() + 30000
    NPCRegistry.save()
end

return NPCRegistry

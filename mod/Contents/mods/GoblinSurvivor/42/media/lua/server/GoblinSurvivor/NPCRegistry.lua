local Config = require("GoblinSurvivor/Config")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")

local NPCRegistry = {
    entries = {},
    loaded = false,
    spawnPending = false,
    pendingSpawn = nil,
    spawnBlocked = false,
    spawnNextAt = 0,
    lastBindWarningAt = 0,
    spawnStatus = "idle",
    spawnAttempts = 0,
    spawnWindowStartedAt = 0,
    lastSpawnDetail = ""
}

local SPAWN_REQUEST_TTL_MS = 10000
local SPAWN_RETRY_MS = 60000
local SPAWN_DEATH_COOLDOWN_MS = 30000
local SPAWN_WINDOW_MS = 10 * 60 * 1000
local MAX_SPAWN_ATTEMPTS = 3

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] NPCRegistry: " .. tostring(message))
    end
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function setSpawnStatus(status, detail)
    NPCRegistry.spawnStatus = status
    NPCRegistry.lastSpawnDetail = detail or ""
end

local function prepareSpawnWindow(now)
    if NPCRegistry.spawnWindowStartedAt == 0
        or now - NPCRegistry.spawnWindowStartedAt >= SPAWN_WINDOW_MS then
        NPCRegistry.spawnWindowStartedAt = now
        NPCRegistry.spawnAttempts = 0
    end
end

local function scheduleRetry(status, detail, delay)
    local now = nowMs()
    prepareSpawnWindow(now)
    NPCRegistry.spawnPending = false
    NPCRegistry.pendingSpawn = nil
    if NPCRegistry.spawnAttempts >= MAX_SPAWN_ATTEMPTS then
        NPCRegistry.spawnBlocked = true
        NPCRegistry.spawnNextAt = 0
        setSpawnStatus("blocked", "spawn attempts exhausted for the bounded retry window")
        log("spawn blocked after " .. tostring(NPCRegistry.spawnAttempts)
            .. " bounded attempts: " .. tostring(detail))
        return
    end
    NPCRegistry.spawnBlocked = false
    NPCRegistry.spawnNextAt = now + (delay or SPAWN_RETRY_MS)
    setSpawnStatus(status, detail)
    log(tostring(detail) .. "; next bounded attempt is delayed")
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
        -- A candidate is identified by the selected framework's stable
        -- profile id.  It is not accepted until prepare() has re-applied the
        -- friendly/protected state and the adapter proves it.
        if NpcAdapter.isCandidate(zombie) then
            local prepared = NpcAdapter.prepare(zombie, Config.npcId)
            if not prepared or not NpcAdapter.isOwned(zombie) then
                local now = nowMs()
                if now - NPCRegistry.lastBindWarningAt >= 30000 then
                    log("found Goblin profile candidate but friendly bind failed")
                    NPCRegistry.lastBindWarningAt = now
                end
            else
                local entry = NPCRegistry.entries[Config.npcId]
                entry.zombie = zombie
                entry.active = true
                entry.alive = true
                NPCRegistry.spawnPending = false
                NPCRegistry.pendingSpawn = nil
                NPCRegistry.spawnBlocked = true
                NPCRegistry.spawnAttempts = 0
                NPCRegistry.spawnWindowStartedAt = 0
                setSpawnStatus("present", "friendly Goblin body bound")
                return zombie
            end
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
        engine = NpcAdapter.engineName(),
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
        -- Close this one request before allowing a delayed retry. Never retry
        -- from the tick that noticed the expiry; that was the source of the
        -- old one-new-hostile-zombie-per-tick failure mode.
        scheduleRetry("retry_wait", "bounded spawn request expired without a friendly Goblin body", SPAWN_RETRY_MS)
    end
    if entry == nil or entry.zombie == nil then
        bindExisting()
    end
    if entry.zombie ~= nil and not bodyExists(entry.zombie) then
        entry.zombie = nil
        entry.alive = false
        NPCRegistry.spawnBlocked = false
        NPCRegistry.spawnNextAt = nowMs() + SPAWN_DEATH_COOLDOWN_MS
        setSpawnStatus("retry_wait", "Goblin body unloaded; waiting before replacement")
    elseif entry.zombie ~= nil and type(entry.zombie.isDead) == "function" then
        local okDead, dead = pcall(function() return entry.zombie:isDead() end)
        if okDead and dead then
            entry.zombie = nil
            entry.alive = false
            NPCRegistry.spawnBlocked = false
            NPCRegistry.spawnNextAt = nowMs() + SPAWN_DEATH_COOLDOWN_MS
            setSpawnStatus("retry_wait", "Goblin body died; waiting before replacement")
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
    -- OnZombieCreate can fire before Bandits2 has finished building its brain.
    -- In that case the bounded registry scan below will bind it later; never
    -- claim an arbitrary normal zombie from this event.
    if not NpcAdapter.isCandidate(zombie)
        and not NpcAdapter.isEventCandidate(zombie) then
        return false, "not a Goblin profile candidate"
    end
    local prepared, detail = NpcAdapter.prepare(zombie, Config.npcId)
    if not prepared or not NpcAdapter.isOwned(zombie) then
        NpcAdapter.discard(zombie)
        return false, detail
    end
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
        return nil, NPCRegistry.lastSpawnDetail ~= "" and NPCRegistry.lastSpawnDetail
            or "spawn blocked after bounded attempts"
    end
    if nowMs() < NPCRegistry.spawnNextAt then
        setSpawnStatus("retry_wait", "spawn recovery cooldown")
        return nil, "spawn recovery cooldown"
    end
    local anchor = onlineAnchor()
    if anchor == nil then
        setSpawnStatus("waiting_anchor", "waiting for an online player anchor")
        return nil, "waiting for an online player anchor"
    end
    if not NpcAdapter.available() then
        log("spawn held: no friendly NPC adapter is available")
        setSpawnStatus("waiting_engine", "friendly NPC adapter is unavailable")
        return nil, "friendly NPC adapter is unavailable"
    end
    local plannedPoint = NpcAdapter.spawnPoint(anchor)
    if plannedPoint == nil then
        setSpawnStatus("waiting_anchor", "online player anchor has no safe spawn point")
        return nil, "online player anchor has no safe spawn point"
    end
    local now = nowMs()
    prepareSpawnWindow(now)
    if NPCRegistry.spawnAttempts >= MAX_SPAWN_ATTEMPTS then
        NPCRegistry.spawnBlocked = true
        setSpawnStatus("blocked", "spawn attempts exhausted for the bounded retry window")
        return nil, NPCRegistry.lastSpawnDetail
    end
    NPCRegistry.spawnAttempts = NPCRegistry.spawnAttempts + 1
    NPCRegistry.spawnPending = true
    NPCRegistry.spawnBlocked = true
    setSpawnStatus("request_pending", "spawn request " .. tostring(NPCRegistry.spawnAttempts)
        .. " of " .. tostring(MAX_SPAWN_ATTEMPTS))
    NPCRegistry.pendingSpawn = {
        point = plannedPoint,
        deadline = now + SPAWN_REQUEST_TTL_MS
    }
    local ok, detail, zombie, spawnPoint = NpcAdapter.spawnIndividual(
        anchor, entry.npc_id, Config.npcProgram
    )
    if not ok then
        scheduleRetry("retry_wait", detail, SPAWN_RETRY_MS)
        return nil, detail
    end
    -- OnZombieCreate may run synchronously inside the Java call.  Preserve
    -- that binding instead of replacing its cleared pending state below.
    if not NPCRegistry.spawnPending then
        return NPCRegistry.findGoblin(), detail
    end
    if zombie ~= nil and NpcAdapter.isOwned(zombie) then
        NPCRegistry.spawnPending = false
        NPCRegistry.pendingSpawn = nil
        NPCRegistry.spawnBlocked = true
        NPCRegistry.spawnAttempts = 0
        NPCRegistry.spawnWindowStartedAt = 0
        setSpawnStatus("present", "friendly Goblin body returned by spawn API")
        entry.zombie = zombie
        entry.alive = true
        NPCRegistry.save()
        return zombie, detail
    end
    if zombie ~= nil then
        NPCRegistry.spawnPending = false
        NPCRegistry.pendingSpawn = nil
        NpcAdapter.discard(zombie)
        local failure = "spawned body failed the friendly ownership proof"
        scheduleRetry("retry_wait", failure, SPAWN_RETRY_MS)
        return nil, failure
    end
    NPCRegistry.pendingSpawn = {
        point = spawnPoint or plannedPoint,
        deadline = nowMs() + 10000
    }
    NPCRegistry.spawnNextAt = nowMs() + SPAWN_RETRY_MS
    setSpawnStatus("request_pending", detail)
    return nil, detail
end

function NPCRegistry.spawnState()
    return {
        status = NPCRegistry.spawnStatus,
        pending = NPCRegistry.spawnPending == true,
        attempts = NPCRegistry.spawnAttempts,
        detail = NPCRegistry.lastSpawnDetail
    }
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
    NPCRegistry.spawnAttempts = 0
    NPCRegistry.spawnWindowStartedAt = 0
    setSpawnStatus("present", "Goblin body recovered")
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
    NPCRegistry.spawnNextAt = nowMs() + SPAWN_DEATH_COOLDOWN_MS
    setSpawnStatus("retry_wait", "Goblin death recorded; replacement is bounded and delayed")
    NPCRegistry.save()
end

return NPCRegistry

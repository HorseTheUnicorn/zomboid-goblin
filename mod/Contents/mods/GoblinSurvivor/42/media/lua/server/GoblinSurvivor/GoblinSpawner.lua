-- One friendly managed IsoZombie per connected player.
--
-- Spawning deliberately uses ONE engine path: addZombiesInOutfit(..., total=1).
-- No createRealZombieAlways/createRealZombieNow fallback, no manual coordinate
-- insertion, and no outfit id is used as identity.  Each Goblin is identified
-- by its owner and its own GoblinID/online id.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local Persistence = require("GoblinSurvivor/GoblinPersistence")

local Spawner = {
    store = nil,
    bodies = {},
    nextAttemptAt = {},
    attempts = {},
    lastDetail = {},
    lastClientSignature = nil
}
local nextMapAt = 0
local restoredBodies = setmetatable({}, { __mode = "k" })

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, first = pcall(member, object, ...)
    return ok, first
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function log(text)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(text)) end
end

local function username(player)
    local ok, value = call(player, "getUsername")
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

local function ownerKey(owner)
    if type(owner) ~= "string" or owner == "" then return nil end
    local key = string.lower(owner)
    key = string.gsub(key, "[^a-z0-9_%-]", "_")
    if key == "" then return nil end
    return key
end

function Spawner.npcIdForOwner(owner)
    local key = ownerKey(owner)
    if key == nil then return nil end
    return Config.npcId .. "." .. key
end

local function onlinePlayers()
    local result = {}
    if type(getOnlinePlayers) ~= "function" then return result end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return result end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    for index = 0, size - 1 do
        local okPlayer, player = call(list, "get", index)
        if okPlayer and player ~= nil and username(player) ~= nil then
            result[#result + 1] = player
        end
    end
    return result
end

local function currentCell()
    local worldClass = rawget(_G, "IsoWorld")
    local world = worldClass ~= nil and worldClass.instance or nil
    local cell = world ~= nil and world.currentCell or nil
    if cell ~= nil then return cell end
    if type(getCell) == "function" then
        local ok, value = pcall(getCell)
        if ok then return value end
    end
    return nil
end

local function eachZombie(callback)
    local cell = currentCell()
    if cell == nil then return end
    local okList, list = call(cell, "getZombieList")
    if not okList or list == nil then return end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    for index = 0, size - 1 do
        local okZombie, zombie = call(list, "get", index)
        if okZombie and zombie ~= nil then callback(zombie) end
    end
end

local function transmitStore()
    local modData = rawget(_G, "ModData")
    if modData ~= nil and type(modData.transmit) == "function" then
        pcall(modData.transmit, "GoblinCompanions")
    end
end

local function loadStore()
    if Spawner.store ~= nil then return Spawner.store end
    local modData = rawget(_G, "ModData")
    if modData ~= nil and type(modData.getOrCreate) == "function" then
        local ok, data = pcall(modData.getOrCreate, "GoblinCompanions")
        if ok and data ~= nil then Spawner.store = data end
    end
    -- Never silently replace a persistent store with a process-local table.
    if Spawner.store == nil then error("GoblinCompanions persistent ModData unavailable") end
    if type(Spawner.store.records) ~= "table" then Spawner.store.records = {} end
    Spawner.store.protocol = Config.protocol
    Spawner.store.npc_prefix = Config.npcId
    return Spawner.store
end

local function recordFor(owner, create)
    local store = loadStore()
    local key = ownerKey(owner)
    if key == nil then return nil end
    local record = store.records[key]
    if record == nil and create ~= false then
        record = {
            owner = owner,
            npc_id = Spawner.npcIdForOwner(owner),
            generation = 0,
            body_present = false,
            task = Constants.TASK.FOLLOW,
            task_payload = { owner = owner },
            base_set = false,
            last_death_at = 0,
            last_spawn_at = 0
        }
        store.records[key] = record
    end
    if record ~= nil then
        if type(record.name) ~= "string" then
            record.name = require("GoblinSurvivor/GoblinIdentity").name(owner,store.records)
        end
        record.owner = owner
        record.npc_id = Spawner.npcIdForOwner(owner)
        record.generation = tonumber(record.generation) or 0
        record.task = Constants.ALLOWED_TASKS[record.task] and record.task or Constants.TASK.FOLLOW
        if record.task == Constants.TASK.SPEAK or record.task == Constants.TASK.EQUIP then
            record.task = Constants.TASK.FOLLOW
            record.task_payload = { owner = owner }
        end
        if type(record.task_payload) ~= "table" then record.task_payload = { owner = owner } end
        record.body_present = record.body_present == true
        record.base_set = record.base_set == true
    end
    return record
end

local function bodyLive(body)
    return body ~= nil and Body.exists(body) and Body.isGoblin(body)
end

local function checkpoint(body, record)
    if not record or not bodyLive(body) then return end
    local point = Body.position(body)
    if point then record.position = { x = point.x, y = point.y, z = point.z } end
    record.saved_at = nowMs()
    Persistence.save(body,false)
end

local function savedSquare(record)
    local point, cell = record.position, currentCell()
    if type(point) ~= "table" or cell == nil then return nil end
    if type(point.x) ~= "number" or type(point.y) ~= "number" or type(point.z) ~= "number" then return nil end
    local ok, square = call(cell, "getGridSquare", math.floor(point.x), math.floor(point.y), math.floor(point.z))
    if not ok or square == nil then return nil end
    local freeOK, free = call(square, "isFree", false)
    return freeOK and free and square or nil
end

local function removeBody(body)
    if body == nil then return end
    require("GoblinSurvivor/GoblinPassenger").detach(body)
    Body.clearNativeTargets(body)
    call(body, "removeFromWorld")
    call(body, "removeFromSquare")
    call(body, "setSquare", nil)
end

local function freeSquareNear(player)
    local cell = currentCell()
    local point = Body.position(player)
    if cell == nil or point == nil then return nil end
    local x, y, z = math.floor(point.x), math.floor(point.y), math.floor(point.z)
    local start = math.max(2, math.floor(tonumber(Config.spawnOffsetTiles) or 4))
    for radius = start, start + 4 do
        local candidates = {
            { radius, 0 }, { -radius, 0 }, { 0, radius }, { 0, -radius },
            { radius, radius }, { -radius, radius }, { radius, -radius }, { -radius, -radius }
        }
        for _, delta in ipairs(candidates) do
            local okSq, square = call(cell, "getGridSquare", x + delta[1], y + delta[2], z)
            if okSq and square ~= nil then
                local okFree, isFree = call(square, "isFree", false)
                if not okFree or isFree == true then return square end
            end
        end
    end
    return nil
end

local function firstListItem(list)
    if list == nil then return nil end
    local okSize, size = call(list, "size")
    if okSize and tonumber(size) ~= nil and tonumber(size) > 0 then
        local okItem, item = call(list, "get", 0)
        if okItem then return item end
    end
    if type(list) == "table" then return list[1] end
    return nil
end

local function addZombiesFunction()
    local fn = nil
    local ok = pcall(function() fn = addZombiesInOutfit end)
    if ok and type(fn) == "function" then return fn end
    fn = rawget(_G, "addZombiesInOutfit")
    return type(fn) == "function" and fn or nil
end

local function createBody(square)
    local fn = addZombiesFunction()
    if fn == nil then return nil, "addZombiesInOutfit unavailable" end
    local okX, x = call(square, "getX")
    local okY, y = call(square, "getY")
    local okZ, z = call(square, "getZ")
    if not okX or not okY or not okZ then return nil, "spawn square unavailable" end

    -- B42 GlobalObject.addZombiesInOutfit overload:
    -- x,y,z,total,outfit,femaleChance,crawler,fallFront,fakeDead,
    -- knockedDown,invulnerable,sitting,health
    local ok, result = pcall(fn,
        math.floor(x), math.floor(y), math.floor(z), 1,
        Config.npcOutfit, 0, false, false, false, false, false, false, 1.0)
    if not ok then return nil, "addZombiesInOutfit failed: " .. tostring(result) end
    local body = firstListItem(result)
    if body == nil then return nil, "addZombiesInOutfit returned no body" end
    return body, "native body created"
end

local function applyRecord(body, record)
    local data = Body.data(body)
    if data == nil or record == nil then return false end
    if not Persistence.restore(body,record.npc_id) then return false end
    data.GoblinBaseSet = record.base_set == true
    data.GoblinBaseX = tonumber(record.base_x)
    data.GoblinBaseY = tonumber(record.base_y)
    data.GoblinBaseZ = tonumber(record.base_z)
    data.GoblinOwner = record.owner
    data.GoblinName = record.name
    data.GoblinID = record.npc_id
    local task = Constants.ALLOWED_TASKS[record.task] and record.task or Constants.TASK.FOLLOW
    local payload = type(record.task_payload) == "table" and record.task_payload or { owner = record.owner }
    -- Discovery runs repeatedly: do not reset sequence/deadlines or restart
    -- the task of an already recovered live body every server tick.
    if not restoredBodies[body] then
        -- Network vehicle IDs are session-local. Recover on foot after a reload;
        -- FOLLOW re-boards the owner's current vehicle when its area is loaded.
        if data.GoblinRide then
            require("GoblinSurvivor/GoblinPassenger").detach(body)
            data.GoblinRide=nil
        end
        if task=="ENTER_VEHICLE" or task=="EXIT_VEHICLE" then task="FOLLOW";payload={owner=record.owner} end
        Body.setTask(body, task, payload)
        restoredBodies[body] = true
        data.GoblinAutonomous = payload.autonomous == true
    end
    Body.applyInvariants(body)
    return true
end

local function discoverBodies()
    local best = {}
    local duplicates = {}
    eachZombie(function(zombie)
        if not Body.isGoblin(zombie) or not bodyLive(zombie) then return end
        local owner = Body.owner(zombie)
        local key = ownerKey(owner)
        if key == nil then
            duplicates[#duplicates + 1] = zombie
            return
        end
        local data = Body.data(zombie)
        local generation = data ~= nil and (tonumber(data.GoblinGeneration) or 0) or 0
        local record = recordFor(owner, true)
        if generation < record.generation then
            duplicates[#duplicates + 1] = zombie
            return
        end
        local existing = best[key]
        if existing == nil then
            best[key] = zombie
        else
            local existingData = Body.data(existing)
            local existingGeneration = existingData ~= nil
                and (tonumber(existingData.GoblinGeneration) or 0) or 0
            if generation > existingGeneration then
                duplicates[#duplicates + 1] = existing
                best[key] = zombie
            else
                duplicates[#duplicates + 1] = zombie
            end
        end
    end)

    for _, zombie in ipairs(duplicates) do
        log("DEDUP removing extra managed Goblin owner=" .. tostring(Body.owner(zombie)))
        removeBody(zombie)
    end

    Spawner.bodies = best
    for key, body in pairs(best) do
        local owner = Body.owner(body)
        local record = recordFor(owner, true)
        if record ~= nil then
            local data = Body.data(body)
            local generation = data ~= nil and (tonumber(data.GoblinGeneration) or 0) or 0
            record.generation = math.max(tonumber(record.generation) or 0, generation)
            record.body_present = true
            local okOnline, online = call(body, "getOnlineID")
            record.online_id = okOnline and type(online) == "number" and online >= 0 and online or nil
            if applyRecord(body, record) then checkpoint(body, record)
            else record.body_present=false;removeBody(body);Spawner.bodies[key]=nil end
        end
    end
end

function Spawner.load()
    loadStore()
    discoverBodies()
    transmitStore()
end

function Spawner.findForOwner(owner)
    local key = ownerKey(owner)
    if key == nil then return nil end
    local cached = Spawner.bodies[key]
    if bodyLive(cached) and string.lower(tostring(Body.owner(cached))) == string.lower(owner) then
        return cached
    end
    Spawner.bodies[key] = nil
    discoverBodies()
    cached = Spawner.bodies[key]
    return bodyLive(cached) and cached or nil
end

function Spawner.findForPlayer(player)
    local owner = username(player)
    return owner ~= nil and Spawner.findForOwner(owner) or nil
end

function Spawner.findByNpcId(npcId)
    if type(npcId) ~= "string" then return nil end
    for _, body in pairs(Spawner.bodies) do
        if bodyLive(body) and Body.npcId(body) == npcId then return body end
    end
    discoverBodies()
    for _, body in pairs(Spawner.bodies) do
        if bodyLive(body) and Body.npcId(body) == npcId then return body end
    end
    return nil
end

function Spawner.allBodies()
    discoverBodies()
    local result = {}
    for _, body in pairs(Spawner.bodies) do
        if bodyLive(body) then result[#result + 1] = body end
    end
    return result
end

function Spawner.onPlayerDeath(player)
    local owner=username(player)
    if not owner then return end
    local record=recordFor(owner,false)
    if record then record.owner_dead=true;transmitStore() end
end

local function rejoinNewLife(player,record,body)
    local _,hours=call(player,"getHoursSurvived")
    local newLife=record.owner_dead==true or (type(hours)=="number" and type(record.owner_hours)=="number" and hours+0.01<record.owner_hours)
    if not newLife then
        if type(hours)=="number" then record.owner_hours=hours end
        return
    end
    local point,near=Body.position(player),body and Body.position(body)
    local teleport=not near or Motion.distance(point,near)>30 or math.floor(point.z)~=math.floor(near.z)
    local destination=teleport and freeSquareNear(player)
    if teleport and not destination then return end -- retry once spawn squares load
    record.task,record.task_payload=Constants.TASK.FOLLOW,{owner=record.owner,rejoin_run=true}
    if destination then
        record.position={x=destination:getX(),y=destination:getY(),z=destination:getZ()}
        if body then
            local data=Body.data(body)
            data.GoblinRejoinSequence=(data.GoblinRejoinSequence or 0)+1
            data.GoblinRejoinPoint=record.position
            data.GoblinRejoinExpires=nowMs()+10000
            Motion.rejoin(body,data.GoblinRejoinPoint,data.GoblinRejoinSequence,data.GoblinRejoinExpires,nowMs())
        end
    end
    if body then require("GoblinSurvivor/GoblinBrain").setTask(body,record.task,record.task_payload) end
    record.owner_dead,record.owner_hours=false,hours
    log("OWNER_RESPAWN_REJOIN owner="..record.owner.." teleport="..tostring(teleport))
    transmitStore()
end

function Spawner.ensureForPlayer(player, force)
    if not Persistence.available() then return nil,"server Storm helper unavailable" end
    local owner = username(player)
    if owner == nil then return nil, "player username unavailable" end
    local key = ownerKey(owner)
    local record = recordFor(owner, true)
    local body = Spawner.findForOwner(owner)
    local _,dead=call(player,"isDead")
    if dead==true then
        record.owner_dead=true
        if body then Body.data(body).GoblinOwnerOnline=false end
        return body,"owner dead; awaiting new character"
    end
    rejoinNewLife(player,record,body)
    if body ~= nil then
        Body.data(body).GoblinOwnerOnline = true
        record.body_present = true
        if not applyRecord(body, record) then
            Spawner.lastDetail[key] = "persistent inventory could not be restored"
            return nil, Spawner.lastDetail[key]
        end
        Spawner.lastDetail[key] = "Goblin present"
        return body, "Goblin present"
    end

    local timestamp = nowMs()
    local respawnAt = (tonumber(record.last_death_at) or 0)
        + (tonumber(Config.respawnSeconds) or 15) * 1000
    if not force and timestamp < respawnAt then
        return nil, "waiting for respawn cooldown"
    end
    if not force and timestamp < (Spawner.nextAttemptAt[key] or 0) then
        return nil, Spawner.lastDetail[key] or "spawn retry pending"
    end

    local square = savedSquare(record)
    if square == nil and record.task == Constants.TASK.WAIT and record.position ~= nil then
        Spawner.lastDetail[key] = "waiting for saved square to load"
        return nil, Spawner.lastDetail[key]
    end
    square = square or freeSquareNear(player)
    if square == nil then
        Spawner.nextAttemptAt[key] = timestamp + 3000
        Spawner.lastDetail[key] = "no free square near player"
        return nil, Spawner.lastDetail[key]
    end

    Spawner.attempts[key] = (Spawner.attempts[key] or 0) + 1
    Spawner.nextAttemptAt[key] = timestamp + 3000
    local created, detail = createBody(square)
    if created == nil then
        Spawner.lastDetail[key] = detail
        log("SPAWN_FAILED owner=" .. owner .. " detail=" .. tostring(detail))
        return nil, detail
    end

    record.generation = (tonumber(record.generation) or 0) + 1
    record.last_spawn_at = timestamp
    record.last_death_at = 0
    record.body_present = true
    local marked, markDetail = Body.mark(created, record.generation, owner, record.npc_id)
    if not marked then
        removeBody(created)
        record.body_present = false
        Spawner.lastDetail[key] = markDetail
        transmitStore()
        return nil, markDetail
    end
    if not applyRecord(created, record) then
        removeBody(created)
        record.body_present=false
        return nil,"persistent inventory could not be restored"
    end
    Body.data(created).GoblinOwnerOnline = true
    Spawner.bodies[key] = created
    checkpoint(created, record)
    local okOnline, online = call(created, "getOnlineID")
    record.online_id = okOnline and type(online) == "number" and online >= 0 and online or nil
    Spawner.lastDetail[key] = "spawned"
    transmitStore()
    log("SPAWN owner=" .. owner .. " npc_id=" .. tostring(record.npc_id)
        .. " generation=" .. tostring(record.generation))
    return created, "spawned"
end

function Spawner.ensureAll(force)
    if not Config.enabled then return {} end
    local seenOwners = {}
    local result = {}
    for _, player in ipairs(onlinePlayers()) do
        local owner = username(player)
        local key = ownerKey(owner)
        if key ~= nil then
            seenOwners[key] = true
            local body = Spawner.ensureForPlayer(player, force == true)
            if body ~= nil then result[#result + 1] = body end
        end
    end

    -- Keep the same actor after disconnect and tick it while its cell is loaded.
    -- The idle scheduler may now choose work without an online owner. Unloaded
    -- cells are not simulated: never create loot or duplicate actors off-screen.
    for key, body in pairs(Spawner.bodies) do
        if not seenOwners[key] then
            local owner = Body.owner(body)
            local record = recordFor(owner, true)
            if record ~= nil then
                checkpoint(body, record)
                record.body_present = bodyLive(body)
            end
            Body.data(body).GoblinOwnerOnline = false
            if bodyLive(body) then result[#result + 1] = body end
        end
    end
    Spawner.syncClientState(false)
    return result
end

function Spawner.setTask(body, task, payload)
    if not Body.isGoblin(body) or Constants.ALLOWED_TASKS[task] ~= true then return false end
    local owner = Body.owner(body)
    local record = recordFor(owner, true)
    if record == nil then return false end
    record.task = task
    record.task_payload = type(payload) == "table" and payload or {}
    Body.setTask(body, task, record.task_payload)
    transmitStore()
    return true
end

function Spawner.setBaseForPlayer(player, clear)
    local owner = username(player)
    local point = Body.position(player)
    if owner == nil or point == nil then return false, "player position unavailable" end
    local record = recordFor(owner, true)
    record.base_set = not clear
    record.base_x, record.base_y, record.base_z = not clear and point.x or nil, not clear and point.y or nil, not clear and point.z or nil
    local body = Spawner.findForOwner(owner)
    if body ~= nil then
        local data = Body.data(body)
        if data ~= nil then
            data.GoblinBaseSet = record.base_set
            data.GoblinBaseX, data.GoblinBaseY, data.GoblinBaseZ = record.base_x, record.base_y, record.base_z
        end
    end
    transmitStore()
    log((clear and "BASE_CLEAR owner=" or "BASE_SET owner=") .. owner)
    return true, clear and "base cleared; loot will be dropped at your feet" or "base set to your current square"
end

function Spawner.baseForOwner(owner)
    local record = recordFor(owner, false)
    if record == nil or record.base_set ~= true then return nil end
    local x, y, z = tonumber(record.base_x), tonumber(record.base_y), tonumber(record.base_z)
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

function Spawner.onZombieCreate(zombie)
    if not Body.isGoblin(zombie) then return false end
    local owner = Body.owner(zombie)
    local key = ownerKey(owner)
    if key == nil then return false end
    local record = recordFor(owner, true)
    local data = Body.data(zombie)
    local generation = data ~= nil and (tonumber(data.GoblinGeneration) or 0) or 0
    if generation < (tonumber(record.generation) or 0) then
        removeBody(zombie)
        return true
    end
    local existing = Spawner.bodies[key]
    if bodyLive(existing) and existing ~= zombie then
        local existingData = Body.data(existing)
        local existingGeneration = existingData ~= nil
            and (tonumber(existingData.GoblinGeneration) or 0) or 0
        if existingGeneration >= generation then
            removeBody(zombie)
            return true
        end
        removeBody(existing)
    end
    record.generation = math.max(tonumber(record.generation) or 0, generation)
    record.body_present = true
    Spawner.bodies[key] = zombie
    if not applyRecord(zombie, record) then
        record.body_present = false
        Spawner.bodies[key] = nil
        removeBody(zombie)
        return false
    end
    Spawner.syncClientState(true)
    return true
end

function Spawner.onZombieDead(zombie)
    if not Body.isGoblin(zombie) then return false end
    local owner = Body.owner(zombie)
    local key = ownerKey(owner)
    local record = recordFor(owner, true)
    if record ~= nil then
        record.last_death_at = nowMs()
        record.body_present = false
        record.online_id = nil
        record.task = Constants.TASK.FOLLOW
        record.task_payload = { owner = owner }
    end
    if key ~= nil and Spawner.bodies[key] == zombie then Spawner.bodies[key] = nil end
    Spawner.nextAttemptAt[key or "?"] = nowMs() + (tonumber(Config.respawnSeconds) or 15) * 1000
    Spawner.syncClientState(true)
    log("DEATH owner=" .. tostring(owner) .. " respawn=true")
    return true
end

function Spawner.removeForPlayer(player)
    local owner = username(player)
    local key = ownerKey(owner)
    if key == nil then return false end
    local body = Spawner.findForOwner(owner)
    if body ~= nil then Persistence.save(body,true);removeBody(body) end
    Spawner.bodies[key] = nil
    local record = recordFor(owner, true)
    record.body_present = false
    record.online_id = nil
    Spawner.nextAttemptAt[key] = nowMs() + (tonumber(Config.respawnSeconds) or 15) * 1000
    Spawner.syncClientState(true)
    return body ~= nil
end

function Spawner.snapshotForOwner(owner)
    local record = recordFor(owner, true)
    local body = Spawner.findForOwner(owner)
    local snapshot = body ~= nil and Body.snapshot(body) or {
        npc_id = record.npc_id,
        owner = record.owner,
        name = record.name or Config.npcName,
        body_present = false,
        alive = true,
        owner_online = false,
        autonomous = record.task_payload and record.task_payload.autonomous == true,
        engine = "iso_zombie",
        friendly = true,
        task = record.task,
        base_set = record.base_set == true
    }
    local key = ownerKey(owner)
    snapshot.spawn_attempts = Spawner.attempts[key] or 0
    snapshot.spawn_detail = Spawner.lastDetail[key] or "not present"
    snapshot.generation = tonumber(record.generation) or 0
    snapshot.persisted = true
    return snapshot
end

function Spawner.snapshotAll()
    local result = {}
    local included = {}
    for _, player in ipairs(onlinePlayers()) do
        local owner = username(player)
        if owner ~= nil then
            result[#result + 1] = Spawner.snapshotForOwner(owner)
            result[#result].owner_online = true
            included[ownerKey(owner)] = true
        end
    end
    -- Qwen retains awareness of saved companions even without an active cell.
    for key, record in pairs(loadStore().records) do
        if not included[key] then
            local snapshot = Spawner.snapshotForOwner(record.owner)
            snapshot.owner_online = false
            result[#result + 1] = snapshot
        end
    end
    table.sort(result, function(a, b)
        return string.lower(tostring(a.owner)) < string.lower(tostring(b.owner))
    end)
    return result
end

function Spawner.snapshot()
    local all = Spawner.snapshotAll()
    if #all > 0 then return all[1] end
    return {
        npc_id = Config.npcId,
        name = Config.npcName,
        body_present = false,
        alive = false,
        engine = "iso_zombie",
        friendly = true,
        task = Constants.TASK.FOLLOW
    }
end

function Spawner.syncOwnerMarkers(timestamp)
    if timestamp < nextMapAt or type(sendServerCommand) ~= "function" then return end
    nextMapAt = timestamp + 1000
    for _, player in ipairs(onlinePlayers()) do
        local owner = username(player)
        local body, record = Spawner.findForOwner(owner), recordFor(owner,false)
        local point = body and Body.position(body) or (record and record.position)
        if record and point then
            sendServerCommand(player,"GoblinSurvivor","map",{owner=owner,npc_id=record.npc_id,
                name=record.name,x=point.x,y=point.y,z=point.z,body_present=body~=nil})
        end
    end
end

function Spawner.syncClientState(force)
    local store = loadStore()
    local companions = {}
    for _, snapshot in ipairs(Spawner.snapshotAll()) do
        local body=Spawner.findByNpcId(snapshot.npc_id)
        local transport=body and require("GoblinSurvivor/GoblinTransport").snapshot(body) or {}
        companions[#companions + 1] = {
            vehicle_id=transport.vehicle_id, vehicle_script=transport.vehicle_script,
            vehicle_seat=transport.vehicle_seat, vehicle_phase=transport.vehicle_phase,
            vehicle_exit=transport.vehicle_exit, vehicle_revision=transport.vehicle_revision,
            transport_active=body and Body.data(body).GoblinTransportActive==true,
            npc_id = snapshot.npc_id,
            owner = snapshot.owner,
            name = snapshot.name,
            body_present = snapshot.body_present == true,
            online_id = snapshot.online_id,
            outfit_id = snapshot.outfit_id,
            generation = snapshot.generation,
            task = snapshot.task,
            physical_state = snapshot.physical_state or Constants.PHYSICAL.IDLE,
            move_type = snapshot.move_type or Constants.MOVE_TYPE.IDLE,
            combat_state = snapshot.combat_state or Constants.COMBAT.NONE,
            action = snapshot.action or "",
            job_active = snapshot.job_active,
            job_tool = snapshot.job_tool,
            action_sequence = snapshot.action_sequence or 0,
            visual_asset = Config.npcVisualAsset,
            visual_item_type = Config.npcVisualItemType,
            movement_goal = snapshot.movement_goal,
            rejoin_run = snapshot.rejoin_run,
            rejoin_point = snapshot.rejoin_point,
            rejoin_sequence = snapshot.rejoin_sequence,
            rejoin_expires = snapshot.rejoin_expires,
            weapon_type = Config.weaponType,
            base_set = snapshot.base_set == true,
            friendly = true,
            owner_online = snapshot.owner_online
        }
    end
    store.companions = companions
    store.updated_at = nowMs()
    local parts = { tostring(#companions) }
    for _, item in ipairs(companions) do
        parts[#parts + 1] = table.concat({
            tostring(item.npc_id), tostring(item.owner), tostring(item.body_present),
            tostring(item.online_id or ""), tostring(item.generation or 0),
            tostring(item.task), tostring(item.physical_state), tostring(item.move_type),
            tostring(item.combat_state), tostring(item.action), tostring(item.action_sequence),
            tostring(item.job_active), tostring(item.job_tool),
            tostring(item.vehicle_id), tostring(item.vehicle_seat), tostring(item.vehicle_phase),
            tostring(item.vehicle_revision), tostring(item.transport_active),
            tostring(item.name), tostring(item.base_set), tostring(item.owner_online),
            tostring(item.rejoin_run), tostring(item.rejoin_sequence),
            tostring(item.movement_goal and math.floor(item.movement_goal.x * 2)),
            tostring(item.movement_goal and math.floor(item.movement_goal.y * 2)),
            tostring(item.movement_goal and item.movement_goal.z)
        }, "|")
    end
    local signature = table.concat(parts, ";")
    if force == true or signature ~= Spawner.lastClientSignature then
        Spawner.lastClientSignature = signature
        transmitStore()
    end
    return true
end

return Spawner

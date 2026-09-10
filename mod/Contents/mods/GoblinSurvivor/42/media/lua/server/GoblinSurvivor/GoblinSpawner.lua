-- Persistent single-body IsoZombie spawner.
--
-- VirtualZombieManager is the supported dedicated-server factory.  A spawn
-- reservation plus the GoblinNPC/GoblinID ModData identity prevents an
-- OnZombieCreate callback from claiming ordinary population zombies and keeps
-- restart/recovery bound to the same companion identity.
local Config = require("GoblinSurvivor/Config")
local Body = require("GoblinSurvivor/GoblinBody")
local Constants = require("GoblinSurvivor/Constants")

local Spawner = {
    body = nil,
    store = nil,
    pending = false,
    nextAttemptAt = 0,
    suppressedUntil = 0,
    attempts = 0,
    lastDetail = "not started",
    capabilityProbeLogged = false,
    livenessProbeBody = nil,
    lastClientStateSignature = nil,
    spawnReservationTimeoutMs = 15000
}

local currentCell

local function call(object, method, ...)
    if object == nil then return false, nil end
    -- Kahlua Java Class/Field proxies are not guaranteed to behave like
    -- ordinary Lua tables when a member is indexed.  Guard both lookup and
    -- invocation so a missing Java method cannot abort the server tick.
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or member == nil then return false, nil end
    local ok, first, second = pcall(member, object, ...)
    return ok, first, second
end

local function readMember(object, member)
    if object == nil then return nil, false end
    local ok, value = pcall(function() return object[member] end)
    return value, ok and value ~= nil
end

local function invoke(object, member, ...)
    local method, available = readMember(object, member)
    if not available then return false, nil, "member unavailable" end
    local ok, first, second = pcall(method, object, ...)
    if ok then return true, first, second end
    return false, first, second
end

local function memberType(object, member)
    local value, available = readMember(object, member)
    return available and type(value) or "nil"
end

-- Java-backed globals in Kahlua are not always visible through rawget(_G,
-- name), even though a direct global read resolves them.  Resolve the native
-- factory through both forms without reflection (reflection is rejected by a
-- normal dedicated server).
local function globalFunction(name)
    local value = nil
    local ok = pcall(function()
        if name == "addZombiesInOutfit" then
            value = addZombiesInOutfit
        elseif name == "createZombie" then
            value = createZombie
        end
    end)
    if ok and type(value) == "function" then return value, "direct" end
    local raw = rawget(_G, name)
    if type(raw) == "function" then return raw, "raw" end
    return nil, "none"
end

local function firstListItem(list)
    if list == nil then return nil end
    local okSize, size = call(list, "size")
    if okSize and type(size) == "number" and size > 0 then
        local okItem, item = call(list, "get", 0)
        if okItem then return item end
    end
    return nil
end

local function registerCreatedBody(body, square)
    if body == nil or square == nil then return false end
    local okX, x = call(square, "getX")
    local okY, y = call(square, "getY")
    local okZ, z = call(square, "getZ")
    if not okX or not okY or not okZ then return false end

    -- The coordinate creator returns an initialized IsoZombie on B42, but on
    -- the dedicated server it can omit the active-cell registration.  Keep
    -- the object in the same native cell/zombie collections used by the
    -- engine before the next population update can recycle it.
    call(body, "setX", x + 0.5)
    call(body, "setY", y + 0.5)
    call(body, "setZ", z)
    call(body, "setCurrent", square)
    call(body, "setCurrentSquare", square)
    call(body, "setMovingSquare", square)
    call(body, "setMovingSquareNow")
    call(body, "setSquare", square)
    -- `keepItReal` is a Java field on IsoZombie and is intentionally not
    -- assigned through Kahlua (that raises "attempted index of non-table" on
    -- dedicated B42).  The public liveness controls below are Lua-safe for a
    -- marker-owned body.  The normal addZombiesInOutfit path is used first so
    -- the engine owns the body lifecycle rather than requiring reflection.
    call(body, "setUseless", false)
    call(body, "makeInactive", false)
    call(body, "setCanWalk", true)
    if Config.protected then
        call(body, "setGodMod", true)
        call(body, "setInvulnerable", true)
        call(body, "setImmortal", true)
        call(body, "setHealth", 30.0)
    end

    -- createRealZombieNow normally owns the cell/zombie-list insertion.  Do
    -- not append the same Java proxy here: Kahlua can wrap one IsoZombie in
    -- multiple userdata values, making ArrayList:contains appear false and
    -- creating duplicate list entries.  Only ask the body to add itself when
    -- the native factory reported that it is not already in the world.
    local okBefore, inWorldBefore = call(body, "isExistInTheWorld")
    if not (okBefore and inWorldBefore == true) then
        call(body, "addToWorld")
    end

    local okCurrent, current = call(body, "getCurrentSquare")
    local okMoving, moving = call(body, "getMovingSquare")
    if okCurrent or okMoving then
        if (okCurrent and current ~= nil) or (okMoving and moving ~= nil) then
            return true
        end
        return false
    end
    if okBefore and inWorldBefore == false then return false end
    return true
end

currentCell = function()
    -- Match the engine's own world-cell lookup.  `getCell()` is available on
    -- some server callbacks, while IsoWorld.currentCell is the stable source
    -- during multiplayer startup and after a map reload.
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

local function log(message)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(message)) end
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function wallNowMs()
    local ok, value = pcall(os.time)
    if ok and type(value) == "number" then return value * 1000 end
    return nowMs()
end

local saveStore

local function loadStore()
    if Spawner.store ~= nil then return Spawner.store end
    local modData = rawget(_G, "ModData")
    if modData ~= nil and type(modData.getOrCreate) == "function" then
        local ok, data = pcall(modData.getOrCreate, "GoblinCompanion")
        if ok and data ~= nil then Spawner.store = data end
    end
    if Spawner.store == nil then Spawner.store = {} end
    Spawner.store.npc_id = Spawner.store.npc_id or Config.npcId
    Spawner.store.name = Spawner.store.name or Config.npcName
    Spawner.store.generation = tonumber(Spawner.store.generation) or 0
    Spawner.store.owner = type(Spawner.store.owner) == "string" and Spawner.store.owner or ""
    Spawner.store.last_death_at = tonumber(Spawner.store.last_death_at) or 0
    Spawner.store.last_spawn_at = tonumber(Spawner.store.last_spawn_at) or 0
    Spawner.store.task = Spawner.store.task or "FOLLOW"
    Spawner.store.persistent_outfit_id = tonumber(Spawner.store.persistent_outfit_id)
        or tonumber(Config.npcOutfitId)
    if type(Spawner.store.online_id) ~= "number"
        or Spawner.store.online_id < 0 then
        Spawner.store.online_id = nil
    end
    Spawner.store.body_present = Spawner.store.body_present == true
    if type(Spawner.store.task_payload) ~= "table" then
        Spawner.store.task_payload = {}
    end
    if type(Spawner.store.spawn_token) ~= "string" or Spawner.store.spawn_token == "" then
        Spawner.store.spawn_token = nil
    end
    Spawner.store.spawn_started_at = tonumber(Spawner.store.spawn_started_at)
    Spawner.store.spawn_generation = tonumber(Spawner.store.spawn_generation)
    return Spawner.store
end

local function clearSpawnReservation(store)
    if store == nil then return false end
    local hadReservation = store.spawn_token ~= nil
        or store.spawn_started_at ~= nil or store.spawn_generation ~= nil
    store.spawn_token = nil
    store.spawn_started_at = nil
    store.spawn_generation = nil
    return hadReservation
end

local function reservationActive(store)
    if store == nil or store.spawn_token == nil then return false end
    local startedAt = tonumber(store.spawn_started_at)
    local age = startedAt ~= nil and (wallNowMs() - startedAt) or math.huge
    if age >= 0 and age < (Spawner.spawnReservationTimeoutMs or 15000) then
        return true
    end
    clearSpawnReservation(store)
    saveStore()
    return false
end

saveStore = function()
    local modData = rawget(_G, "ModData")
    if modData ~= nil and type(modData.transmit) == "function" then
        pcall(modData.transmit, "GoblinCompanion")
    end
end

function Spawner.syncClientState(body, force)
    local store = loadStore()
    local data = body ~= nil and Body.data(body) or nil
    if body ~= nil and data == nil then return false end

    local onlineId = nil
    local persistentId = tonumber(store.persistent_outfit_id)
        or tonumber(Config.npcOutfitId)
    if body ~= nil then
        local okOnline, valueOnline = call(body, "getOnlineID")
        if okOnline and type(valueOnline) == "number" and valueOnline >= 0 then
            onlineId = valueOnline
        end
        local okPersistent, valuePersistent = call(body, "getPersistentOutfitID")
        if okPersistent and type(valuePersistent) == "number" and valuePersistent >= 0 then
            persistentId = valuePersistent
        end
    end

    store.online_id = onlineId
    store.persistent_outfit_id = persistentId
    store.body_present = body ~= nil and Body.exists(body) or false
    store.visual_asset = data ~= nil and data.GoblinMeshAsset or Config.npcVisualAsset
    store.visual_applied = data ~= nil and data.GoblinMeshApplied == true or false
    store.visual_item_type = Config.npcVisualItemType
    store.outfit_items = data ~= nil and data.GoblinOutfitItems
        or table.concat(Config.npcOutfitItems or {}, ",")
    store.weapon_type = data ~= nil and data.GoblinWeaponType or Config.weaponType
    store.task = data ~= nil and data.GoblinTask or (store.task or "FOLLOW")
    store.physical_state = data ~= nil and data.GoblinPhysicalState or "IDLE"
    store.move_type = data ~= nil and data.GoblinMoveType or "IDLE"
    store.combat_state = data ~= nil and data.GoblinCombatState or "NONE"
    store.recovery_stage = data ~= nil and (data.GoblinRecoveryStage or "") or ""
    store.state_sequence = data ~= nil and (tonumber(data.GoblinStateSequence) or 0)
        or (tonumber(store.state_sequence) or 0)
    store.task_sequence = data ~= nil and (tonumber(data.GoblinTaskSequence) or 0)
        or (tonumber(store.task_sequence) or 0)
    store.generation = tonumber(store.generation) or 0

    local signature = table.concat({
        tostring(store.body_present), tostring(store.online_id or "none"),
        tostring(store.persistent_outfit_id or "none"), tostring(store.generation),
        tostring(store.task), tostring(store.physical_state), tostring(store.move_type),
        tostring(store.combat_state), tostring(store.recovery_stage),
        tostring(store.state_sequence), tostring(store.task_sequence),
        tostring(store.visual_asset), tostring(store.visual_applied),
        tostring(store.outfit_items),
        tostring(store.weapon_type)
    }, "|")
    if force == true or signature ~= Spawner.lastClientStateSignature then
        Spawner.lastClientStateSignature = signature
        saveStore()
    end
    return true
end

local function eachZombie(callback)
    local cell = currentCell()
    if cell == nil then return end
    local okList, list = call(cell, "getZombieList")
    if not okList or list == nil then return end
    local okSize, size = call(list, "size")
    local count = okSize and tonumber(size) or 0
    if count == 0 and not okSize then
        local okLength, length = pcall(function() return #list end)
        if okLength and type(length) == "number" then count = length end
    end
    for index = 0, count - 1 do
        local okItem, zombie = call(list, "get", index)
        if not okItem then zombie = list[index + 1] end
        if zombie ~= nil then callback(zombie) end
    end
end

local function eachPlayer(callback)
    if type(getOnlinePlayers) ~= "function" then return end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return end
    local okSize, size = call(list, "size")
    local count = okSize and tonumber(size) or 0
    if count == 0 and not okSize then
        local okLength, length = pcall(function() return #list end)
        if okLength and type(length) == "number" then count = length end
    end
    for index = 0, count - 1 do
        local okItem, player = call(list, "get", index)
        if not okItem then player = list[index + 1] end
        if player ~= nil then callback(player) end
    end
end

local function username(player)
    local ok, value = call(player, "getUsername")
    return ok and type(value) == "string" and value or ""
end

local function ownerPlayer()
    local store = loadStore()
    local first = nil
    local found = nil
    eachPlayer(function(player)
        if first == nil then first = player end
        if store.owner ~= "" and string.lower(username(player)) == string.lower(store.owner) then
            found = player
        end
    end)
    if found ~= nil then return found end
    if store.owner == "" then
        if first ~= nil then
            store.owner = username(first)
            saveStore()
        end
        return first
    end
    -- Do not silently transfer ownership after a restart.  The owner must
    -- reconnect before a persisted Goblin is respawned.
    return nil
end

local function freeSquareNear(player)
    if player == nil then return nil end
    local cell = currentCell()
    if cell == nil then return nil end
    local okX, x = call(player, "getX")
    local okY, y = call(player, "getY")
    local okZ, z = call(player, "getZ")
    if not okX or not okY or not okZ then return nil end
    local baseX, baseY, floor = math.floor(x), math.floor(y), math.floor(z)
    local offset = tonumber(Config.spawnOffsetTiles) or 4
    local candidates = {
        { offset, offset }, { -offset, offset }, { offset, -offset }, { -offset, -offset },
        { offset, 0 }, { -offset, 0 }, { 0, offset }, { 0, -offset }
    }
    for _, delta in ipairs(candidates) do
        local okSquare, square = call(cell, "getGridSquare",
            baseX + delta[1], baseY + delta[2], floor)
        if okSquare and square ~= nil then
            local free = true
            local okFree, value = call(square, "isFree", false)
            if okFree then free = value == true end
            if free then return square end
        end
    end
    return nil
end

local function removeDuplicate(zombie)
    if zombie == nil then return false end
    call(zombie, "setTarget", nil)
    local managerClass = rawget(_G, "VirtualZombieManager")
    local manager = readMember(managerClass, "instance")
    local removed = false
    if manager ~= nil then
        -- `call` returns the pcall status followed by the Java return value.
        -- Most Build 42 removal methods are void, so a successful call with a
        -- nil return is still a successful removal.
        local okRemoved, result = call(manager, "removeZombieFromWorld", zombie)
        removed = okRemoved and (result == nil or result == true)
    end
    if not removed then
        local okFallback = call(zombie, "removeFromWorld")
        removed = okFallback == true
    end
    call(zombie, "removeFromSquare")
    call(zombie, "setSquare", nil)
    return removed
end

local function sameBody(left, right)
    if left == right then return true end
    if left == nil or right == nil then return false end
    local okLeft, leftId = call(left, "getID")
    local okRight, rightId = call(right, "getID")
    if okLeft and okRight and tonumber(leftId) ~= nil and tonumber(rightId) ~= nil then
        return tonumber(leftId) == tonumber(rightId)
    end
    local okLeftOnline, leftOnline = call(left, "getOnlineID")
    local okRightOnline, rightOnline = call(right, "getOnlineID")
    return okLeftOnline and okRightOnline
        and tonumber(leftOnline) ~= nil and tonumber(rightOnline) ~= nil
        and tonumber(leftOnline) >= 0 and tonumber(leftOnline) == tonumber(rightOnline)
end

local function bodyLive(body)
    if body == nil or not Body.exists(body) then return false end
    local okDead, dead = call(body, "isDead")
    if okDead and dead == true then return false end
    local okHealth, health = call(body, "getHealth")
    if okHealth and tonumber(health) ~= nil and tonumber(health) <= 0 then return false end
    return true
end

local function bodyGeneration(body)
    local data = Body.data(body)
    local generation = data ~= nil and tonumber(data.GoblinGeneration) or nil
    return generation or -1
end

local function bodySortKey(body)
    local okId, id = call(body, "getID")
    if okId and tonumber(id) ~= nil then
        return string.format("0:%020.0f", tonumber(id))
    end
    local okOnline, online = call(body, "getOnlineID")
    if okOnline and tonumber(online) ~= nil then
        return string.format("1:%020.0f", tonumber(online))
    end
    return "2:" .. tostring(body)
end

local function candidateBefore(left, right)
    local leftGeneration = bodyGeneration(left)
    local rightGeneration = bodyGeneration(right)
    if leftGeneration ~= rightGeneration then
        return leftGeneration > rightGeneration
    end
    return bodySortKey(left) < bodySortKey(right)
end

function Spawner.find()
    local store = loadStore()
    local cached = Spawner.body
    if cached ~= nil and not bodyLive(cached) and cached ~= Spawner.livenessProbeBody then
        local found = cached
        Spawner.livenessProbeBody = found
        local okExists, exists = call(found, "isExistInTheWorld")
        local okDead, dead = call(found, "isDead")
        local okHealth, health = call(found, "getHealth")
        local okUseless, useless = call(found, "isUseless")
        local okInactive, inactive = call(found, "isInactive")
        local okCurrent, current = call(found, "getCurrentSquare")
        local okMoving, moving = call(found, "getMovingSquare")
        log("BODY_LOST exists=" .. tostring(okExists and exists)
            .. " dead=" .. tostring(okDead and dead)
            .. " health=" .. tostring(okHealth and health)
            .. " useless=" .. tostring(okUseless and useless)
            .. " inactive=" .. tostring(okInactive and inactive)
            .. " current=" .. tostring(okCurrent and current ~= nil)
            .. " moving=" .. tostring(okMoving and moving ~= nil))
        -- A body that disappears without OnZombieDead is still a failed
        -- native registration (or a population recycle).  Treat it as a
        -- bounded recovery event so the next OnTick cannot immediately create
        -- another shell.  This also protects against a client-side callback
        -- clearing the pending flag before the server sees the loss.
        local timestamp = nowMs()
        store.last_death_at = timestamp
        store.online_id = nil
        store.body_present = false
        store.task = "FOLLOW"
        store.task_payload = {}
        clearSpawnReservation(store)
        Spawner.pending = false
        Spawner.nextAttemptAt = timestamp + (tonumber(Config.respawnSeconds) or 15) * 1000
        Spawner.lastDetail = "Goblin body lost; waiting for bounded recovery"
        saveStore()
    end

    -- A reconnect or script reload can expose more than one marked body for a
    -- short time.  Pick the newest persisted generation, then a stable native
    -- id for ties.  This makes the choice deterministic instead of depending
    -- on cell-list order, which is different on each client/session.
    local candidates = {}
    local function addCandidate(zombie)
        if not Body.isGoblin(zombie, Config.npcId) or not bodyLive(zombie) then return end
        for _, existing in ipairs(candidates) do
            if sameBody(existing, zombie) then return end
        end
        candidates[#candidates + 1] = zombie
    end
    if cached ~= nil then addCandidate(cached) end
    eachZombie(function(zombie)
        if Body.isGoblin(zombie, Config.npcId) then addCandidate(zombie) end
    end)

    if #candidates == 0 then
        Spawner.body = nil
        return nil
    end

    table.sort(candidates, candidateBefore)
    local winner = candidates[1]
    local expectedGeneration = tonumber(store.generation) or 0
    local winnerGeneration = bodyGeneration(winner)

    -- Do not resurrect an older body after the persisted generation has
    -- advanced.  Retire every stale candidate and let the bounded recovery
    -- path create exactly one replacement.
    if expectedGeneration > 0 and winnerGeneration >= 0
        and winnerGeneration < expectedGeneration then
        log("RECOVERY stale Goblin generation=" .. tostring(winnerGeneration)
            .. " expected=" .. tostring(expectedGeneration) .. " retired")
        for _, stale in ipairs(candidates) do
            removeDuplicate(stale)
        end
        Spawner.body = nil
        store.body_present = false
        store.last_death_at = nowMs()
        clearSpawnReservation(store)
        Spawner.nextAttemptAt = store.last_death_at
            + (tonumber(Config.respawnSeconds) or 15) * 1000
        saveStore()
        return nil
    end

    local stateChanged = false
    if winnerGeneration > expectedGeneration then
        store.generation = winnerGeneration
        stateChanged = true
    end
    if clearSpawnReservation(store) then stateChanged = true end
    if store.body_present ~= true then stateChanged = true end
    store.body_present = true
    if stateChanged then saveStore() end
    for index = 2, #candidates do
        local duplicate = candidates[index]
        local removed = removeDuplicate(duplicate)
        log("RECOVERY duplicate Goblin generation=" .. tostring(bodyGeneration(duplicate))
            .. " removed=" .. tostring(removed))
    end
    Spawner.body = winner
    return winner
end

local function createBody(square, player)
    local managerClass = rawget(_G, "VirtualZombieManager")
    local manager, managerAvailable = readMember(managerClass, "instance")
    local addZombies, addSource = globalFunction("addZombiesInOutfit")
    local choices, choicesAvailable = readMember(manager, "choices")
    local choicesSource = choicesAvailable and "direct" or "none"
    local _, clearAvailable = readMember(choices, "clear")
    local _, addAvailable = readMember(choices, "add")
    local _, alwaysAvailable = readMember(manager, "createRealZombieAlways")
    local _, nowAvailable = readMember(manager, "createRealZombieNow")
    if not Spawner.capabilityProbeLogged then
        Spawner.capabilityProbeLogged = true
        log("SPAWN API probe manager_class=" .. tostring(managerClass ~= nil)
            .. " manager=" .. tostring(managerAvailable)
            .. " choices=" .. tostring(choicesAvailable) .. "[" .. choicesSource .. "]"
            .. " clear=" .. tostring(clearAvailable) .. "(" .. memberType(choices, "clear") .. ")"
            .. " add=" .. tostring(addAvailable) .. "(" .. memberType(choices, "add") .. ")"
            .. " always=" .. tostring(alwaysAvailable) .. "(" .. memberType(manager, "createRealZombieAlways") .. ")"
            .. " now=" .. tostring(nowAvailable) .. "(" .. memberType(manager, "createRealZombieNow") .. ")"
            .. " addZombiesInOutfit=" .. tostring(type(addZombies))
            .. "[" .. tostring(addSource) .. "]")
    end


    if type(addZombies) == "function" then
        local okX, x = call(square, "getX")
        local okY, y = call(square, "getY")
        local okZ, z = call(square, "getZ")
        if okX and okY and okZ then
            local okAdd, resultOrError = pcall(addZombies,
                math.floor(x), math.floor(y), math.floor(z), 1, "Naked1", 0,
                false, false, false, false, false, false, 1)
            if okAdd then
                local addedBody = firstListItem(resultOrError)
                if addedBody ~= nil then
                    if registerCreatedBody(addedBody, square) then
                        return addedBody, "addZombiesInOutfit created IsoZombie"
                    end
                    log("SPAWN API addZombiesInOutfit returned an unregistered body")
                else
                    log("SPAWN API addZombiesInOutfit returned no body")
                end
            else
                log("SPAWN API addZombiesInOutfit failed error=" .. tostring(resultOrError))
            end
        end
    end
    if manager == nil then
        return nil, "VirtualZombieManager.createRealZombieAlways is unavailable"
    end
    local directions = rawget(_G, "IsoDirections")
    local direction = directions ~= nil and directions.S or nil
    if player ~= nil then
        local okDir, value = call(player, "getDir")
        if okDir and value ~= nil then direction = value end
    end

    -- The B42 Java API also exposes an outfit-id overload that does not rely
    -- on the Lua-visible `choices` field.  Prefer it before the coordinate
    -- overload: the latter creates a transient population shell which the
    -- manager is free to recycle a few seconds later.  Outfit id 0 is the
    -- ordinary engine default; Goblin's human outfit is applied immediately
    -- after the body is returned.
    if alwaysAvailable then
        local okAlways, bodyAlways, alwaysError = invoke(manager,
            "createRealZombieAlways", direction, false, 0)
        if okAlways and bodyAlways ~= nil then
            if registerCreatedBody(bodyAlways, square) then
                return bodyAlways, "VirtualZombieManager created persistent IsoZombie"
            end
            log("SPAWN API createRealZombieAlways(outfit) returned an unregistered body")
        else
            log("SPAWN API createRealZombieAlways(outfit) failed ok=" .. tostring(okAlways)
                .. " error=" .. tostring(alwaysError))
        end
    end

    local okCreate, body, createError = false, nil, nil
    if choices ~= nil and clearAvailable and addAvailable and alwaysAvailable then
        invoke(choices, "clear")
        local okAdd, _, addError = invoke(choices, "add", square)
        if okAdd then
            okCreate, body, createError = invoke(manager, "createRealZombieAlways", direction, false)
        else
            log("SPAWN API choices.add failed error=" .. tostring(addError))
        end
        invoke(choices, "clear")
    elseif choices ~= nil and alwaysAvailable then
        log("SPAWN API choices path unavailable; trying coordinate native factory")
    end
    if okCreate and body ~= nil then
        if registerCreatedBody(body, square) then
            return body, "VirtualZombieManager created IsoZombie"
        end
        log("SPAWN API createRealZombieAlways returned an unregistered body")
    end
    if alwaysAvailable and choices ~= nil then
        log("SPAWN API createRealZombieAlways failed ok=" .. tostring(okCreate)
            .. " error=" .. tostring(createError))
    end

    -- A few B42 point releases expose only the coordinate overload to Lua.
    -- It is still the native VirtualZombieManager factory and is used only
    -- for the one explicit spawn reservation (never for movement).
    if nowAvailable then
        local okX, x = call(square, "getX")
        local okY, y = call(square, "getY")
        local okZ, z = call(square, "getZ")
        if okX and okY and okZ then
            local okNow, bodyNow, nowError = invoke(manager, "createRealZombieNow",
                x + 0.5, y + 0.5, z)
            if okNow and bodyNow ~= nil then
                if registerCreatedBody(bodyNow, square) then
                    return bodyNow, "VirtualZombieManager created IsoZombie"
                end
                log("SPAWN API createRealZombieNow returned an unregistered body")
            end
            log("SPAWN API createRealZombieNow failed ok=" .. tostring(okNow)
                .. " error=" .. tostring(nowError))
        end
    end
    return nil, "VirtualZombieManager did not return an IsoZombie"
end

function Spawner.setOwner(name)
    local store = loadStore()
    if type(name) ~= "string" or name == "" or #name > 96
        or string.find(name, "^[A-Za-z0-9_%-]+$") == nil then return false end
    store.owner = name
    saveStore()
    return true
end

function Spawner.ownerName()
    local store = loadStore()
    if type(store.owner) == "string" and store.owner ~= "" then
        return store.owner
    end
    return nil
end

local function copyTaskPayload(payload)
    if type(payload) ~= "table" then return {} end
    local result = {}
    for key, value in pairs(payload) do
        if key == "x" or key == "y" or key == "z" then
            if type(value) == "number" and value == value
                and value ~= math.huge and value ~= -math.huge then
                result[key] = value
            end
        elseif key == "owner" or key == "text" or key == "loot_focus" then
            local maximum = key == "loot_focus" and 32 or 240
            if type(value) == "string" and #value <= maximum then result[key] = value end
        elseif key == "target" and type(value) == "table" then
            local target = {}
            for targetKey, targetValue in pairs(value) do
                if targetKey == "kind" or targetKey == "name" or targetKey == "label"
                    or targetKey == "player" then
                    if type(targetValue) == "string" and #targetValue <= 96 then
                        target[targetKey] = targetValue
                    end
                end
            end
            if target.kind ~= nil then result.target = target end
        elseif key == "item" and type(value) == "table" then
            local item = {}
            if type(value.name) == "string" and #value.name <= 96 then item.name = value.name end
            if type(value.count) == "number" and math.floor(value.count) == value.count
                and value.count >= 1 and value.count <= 10 then item.count = value.count end
            if type(value.category) == "string" and #value.category <= 64 then
                item.category = value.category
            end
            if item.name ~= nil then result.item = item end
        end
    end
    return result
end

function Spawner.setTask(task, payload)
    local store = loadStore()
    if type(task) ~= "string" or Constants.ALLOWED_TASKS[task] ~= true then return false end
    store.task = task
    store.task_payload = copyTaskPayload(payload)
    saveStore()
    return true
end

function Spawner.suppress(seconds)
    -- Developer `/goblin despawn` needs a quiet window so the normal recovery
    -- loop does not immediately recreate the body before a manual spawn test.
    -- This is process-local and therefore cannot erase the persisted identity.
    local duration = tonumber(seconds) or (tonumber(Config.respawnSeconds) or 15)
    if duration < 0 then duration = 0 end
    local store = loadStore()
    clearSpawnReservation(store)
    Spawner.suppressedUntil = nowMs() + duration * 1000
    Spawner.pending = false
    Spawner.nextAttemptAt = Spawner.suppressedUntil
    Spawner.lastDetail = "developer despawn suppression is active"
    saveStore()
end

local function beginSpawnReservation(store, timestamp)
    local nextGeneration = (tonumber(store.generation) or 0) + 1
    local startedAt = wallNowMs()
    store.spawn_generation = nextGeneration
    store.spawn_started_at = startedAt
    store.spawn_token = tostring(startedAt) .. ":"
        .. tostring(nextGeneration) .. ":" .. tostring((Spawner.attempts or 0) + 1)
    store.body_present = false
    store.last_spawn_attempt_at = timestamp
    saveStore()
    return nextGeneration
end

function Spawner.ensure(force)
    if not Config.enabled then return nil, "GoblinEnabled=false" end
    local store = loadStore()
    local body = Spawner.find()
    if body ~= nil then
        local timestamp = nowMs()
        local last = tonumber(Body.data(body).GoblinLastInvariantAt) or 0
        if timestamp - last >= 2000 then Body.applyInvariants(body, false) end
        Spawner.pending = false
        Spawner.suppressedUntil = 0
        Spawner.lastDetail = "Goblin body present"
        return body, Spawner.lastDetail
    end
    local timestamp = nowMs()
    if not force and timestamp < (Spawner.suppressedUntil or 0) then
        Spawner.lastDetail = "developer despawn suppression is active"
        return nil, Spawner.lastDetail
    end
    local respawnAt = (tonumber(store.last_death_at) or 0)
        + (tonumber(Config.respawnSeconds) or 15) * 1000
    if not force and timestamp < respawnAt then
        Spawner.lastDetail = "waiting for respawn cooldown"
        return nil, Spawner.lastDetail
    end
    if reservationActive(store) then
        Spawner.pending = true
        Spawner.nextAttemptAt = timestamp + 3000
        Spawner.lastDetail = "recovering an in-flight spawn reservation"
        return nil, Spawner.lastDetail
    end
    if Spawner.pending and timestamp < Spawner.nextAttemptAt then
        return nil, "Goblin spawn is pending"
    end
    local player = ownerPlayer()
    if player == nil then
        Spawner.lastDetail = "persisted owner is offline"
        return nil, Spawner.lastDetail
    end
    local square = freeSquareNear(player)
    if square == nil then
        Spawner.nextAttemptAt = timestamp + 3000
        Spawner.lastDetail = "no free spawn square near owner"
        return nil, Spawner.lastDetail
    end
    Spawner.pending = true
    Spawner.nextAttemptAt = timestamp + 3000
    Spawner.attempts = Spawner.attempts + 1
    local reservedGeneration = beginSpawnReservation(store, timestamp)
    local created, detail = createBody(square, player)
    if created == nil then
        clearSpawnReservation(store)
        saveStore()
        Spawner.pending = false
        Spawner.lastDetail = detail
        log("SPAWN failed detail=" .. tostring(detail))
        return nil, detail
    end
    store.generation = math.max(tonumber(store.generation) or 0, reservedGeneration)
    store.last_spawn_at = timestamp
    store.last_death_at = 0
    local marked, markDetail = Body.mark(created, store.generation, store.owner)
    if not marked then
        removeDuplicate(created)
        clearSpawnReservation(store)
        saveStore()
        Spawner.pending = false
        Spawner.lastDetail = markDetail
        return nil, markDetail
    end
    -- Capture the engine-assigned identity after the native factory has
    -- marked the body.  The persistent outfit id is our restart-safe fallback
    -- while the server has not assigned an online id yet.
    clearSpawnReservation(store)
    Spawner.syncClientState(created, true)
    -- Restore only the bounded task envelope saved by the authoritative
    -- brain.  If old/corrupt ModData contains an unsupported task, fall back
    -- to the safe default FOLLOW instead of reviving arbitrary state.
    local restoredTask = store.task
    local restoredPayload = store.task_payload
    if not Body.setTask(created, restoredTask, restoredPayload) then
        restoredTask = Constants.TASK.FOLLOW
        restoredPayload = {}
        store.task = restoredTask
        store.task_payload = restoredPayload
        Body.setTask(created, restoredTask, restoredPayload)
    end
    Spawner.body = created
    Spawner.pending = false
    Spawner.suppressedUntil = 0
    Spawner.lastDetail = detail
    saveStore()
    log("SPAWN id=" .. Config.npcId .. " generation=" .. tostring(store.generation)
        .. " owner=" .. tostring(store.owner))
    return created, detail
end

function Spawner.onZombieCreate(zombie)
    if not Body.isGoblin(zombie, Config.npcId) or not bodyLive(zombie) then return false end
    local store = loadStore()
    local generation = bodyGeneration(zombie)
    local expectedGeneration = tonumber(store.generation) or 0
    if expectedGeneration > 0 and generation >= 0 and generation < expectedGeneration then
        log("RECOVERY stale Goblin create generation=" .. tostring(generation)
            .. " expected=" .. tostring(expectedGeneration) .. " retired")
        removeDuplicate(zombie)
        return false
    end

    -- If another live body is already bound, reconcile both through the same
    -- deterministic generation rule used by the normal tick.  Never let an
    -- event callback replace a newer body merely because it fired later.
    if Spawner.body ~= nil and bodyLive(Spawner.body) and not sameBody(Spawner.body, zombie) then
        local winner = Spawner.find()
        return winner ~= nil and sameBody(winner, zombie)
    end
    Spawner.body = zombie
    Spawner.pending = false
    local stateChanged = store.body_present ~= true
    store.body_present = true
    if clearSpawnReservation(store) then stateChanged = true end
    if stateChanged then saveStore() end
    return true
end

function Spawner.onZombieDead(zombie)
    if not Body.isGoblin(zombie, Config.npcId) then return false end
    local store = loadStore()
    store.last_death_at = nowMs()
    store.online_id = nil
    store.body_present = false
    store.task = "FOLLOW"
    store.task_payload = {}
    clearSpawnReservation(store)
    Spawner.body = nil
    Spawner.pending = false
    Spawner.suppressedUntil = 0
    Spawner.lastDetail = "Goblin body died; waiting for bounded recovery"
    Spawner.syncClientState(nil, true)
    log("RECOVERY death generation=" .. tostring(store.generation))
    return true
end

function Spawner.snapshot()
    local store = loadStore()
    local body = Spawner.find()
    local snapshot = Body.snapshot(body)
    if snapshot == nil then
        snapshot = {
            npc_id = Config.npcId,
            name = Config.npcName,
            body_present = false,
            alive = false,
            entity_class = "IsoZombie",
            engine = "iso_zombie",
            humanized = false,
            owner = store.owner,
            task = store.task,
            generation = store.generation
        }
    end
    snapshot.generation = tonumber(store.generation) or 0
    snapshot.spawn_pending = Spawner.pending
    snapshot.spawn_attempts = Spawner.attempts
    snapshot.spawn_detail = Spawner.lastDetail
    return snapshot
end

function Spawner.load()
    local store = loadStore()
    if reservationActive(store) then
        Spawner.pending = true
        Spawner.nextAttemptAt = nowMs() + 3000
        Spawner.lastDetail = "recovering an in-flight spawn reservation"
    else
        Spawner.pending = false
    end
    Spawner.lastClientStateSignature = nil
end

return Spawner

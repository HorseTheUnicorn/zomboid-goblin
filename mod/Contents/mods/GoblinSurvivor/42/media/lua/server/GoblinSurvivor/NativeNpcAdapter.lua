-- Native Build 42 NPC body and behavior engine.
--
-- GoblinSurvivor creates a normal networked IsoZombie with a survivor
-- descriptor, then owns the small amount of behavior it needs: identity,
-- friendly filtering, navigation, bounded zombie combat, speech, and
-- persistence.  No external NPC framework is required.
local Config = require("GoblinSurvivor/Config")

local NativeAdapter = {}

local combatTargets = {}
local ownedBodies = {}
local spawnReservation = nil

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function functionExists(owner, name)
    if owner == nil or type(name) ~= "string" then return false end
    -- Java Class/Field proxies are not ordinary Lua tables. A raw index can
    -- throw before type() gets a chance to inspect it, so capability probes
    -- must be protected just like the calls they authorize.
    local ok, kind = pcall(function() return type(owner[name]) end)
    return ok and kind == "function"
end

local function nativeWorldCell()
    -- GlobalObject.createZombie() resolves through IsoWorld.instance.currentCell.
    -- Use that same cell when preparing the square so our preflight cannot
    -- validate one Java cell while the creator reads another.
    local worldClass = rawget(_G, "IsoWorld")
    local world = worldClass ~= nil and worldClass.instance or nil
    local currentCell = world ~= nil and world.currentCell or nil
    if currentCell ~= nil then return currentCell end
    if world ~= nil and functionExists(world, "getCell") then
        local okWorldCell, worldCell = pcall(world.getCell, world)
        if okWorldCell and worldCell ~= nil then return worldCell end
    end
    if type(getCell) == "function" then
        local okCell, cell = pcall(getCell)
        if okCell then return cell end
    end
    return nil
end

local function safeCall(object, method, ...)
    if object == nil or not functionExists(object, method) then
        return false
    end
    local ok = pcall(object[method], object, ...)
    return ok
end

local function position(object)
    if object == nil or not functionExists(object, "getX")
        or not functionExists(object, "getY") or not functionExists(object, "getZ") then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return object:getX(), object:getY(), object:getZ()
    end)
    if not ok or type(x) ~= "number" or type(y) ~= "number"
        or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function dataFor(body)
    if body == nil or not functionExists(body, "getModData") then
        return nil
    end
    local ok, data = pcall(function() return body:getModData() end)
    return ok and type(data) == "table" and data or nil
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] NativeNpcAdapter: " .. tostring(message))
    end
end

local function eachZombie(callback)
    if type(getCell) ~= "function" then return end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil or not functionExists(cell, "getZombieList") then
        return
    end
    local okList, zombies = pcall(function() return cell:getZombieList() end)
    if not okList or zombies == nil then return end
    local count = 0
    if type(zombies.size) == "function" then
        local okSize, size = pcall(function() return zombies:size() end)
        if not okSize or type(size) ~= "number" then return end
        count = size
    elseif type(zombies) == "table" then
        count = #zombies
    end
    for index = 0, count - 1 do
        local zombie = type(zombies.get) == "function"
            and zombies:get(index) or zombies[index + 1]
        if zombie ~= nil then callback(zombie) end
    end
end

local function bodyExists(body)
    if body == nil then return false end
    if not functionExists(body, "isExistInTheWorld") then return true end
    local ok, exists = pcall(function() return body:isExistInTheWorld() end)
    return not ok or exists == true
end

local function bodyDead(body)
    if body == nil or not functionExists(body, "isDead") then return false end
    local ok, dead = pcall(function() return body:isDead() end)
    return ok and dead == true
end

local function playerFor(label)
    if type(label) ~= "string" or label == ""
        or type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return nil end
    local count = type(players.size) == "function" and players:size() or #players
    local wanted = string.lower(label)
    for index = 0, count - 1 do
        local player = type(players.get) == "function"
            and players:get(index) or players[index + 1]
        if player ~= nil and functionExists(player, "getUsername") then
            local okName, username = pcall(function() return player:getUsername() end)
            if okName and type(username) == "string"
                and string.lower(username) == wanted then
                return player
            end
        end
    end
    return nil
end

local function liveTarget(target)
    if target == nil or position(target) == nil then return false end
    if functionExists(target, "isExistInTheWorld") then
        local ok, exists = pcall(function() return target:isExistInTheWorld() end)
        if ok and not exists then return false end
    end
    if functionExists(target, "isDead") then
        local ok, dead = pcall(function() return target:isDead() end)
        if ok and dead then return false end
    end
    if functionExists(target, "isPlayer") then
        local ok, isPlayer = pcall(function() return target:isPlayer() end)
        if ok and isPlayer then return false end
    end
    local data = dataFor(target)
    return data == nil or (data.goblin_owned ~= true and data.goblin_friendly ~= true)
end

local function nativeSpawnMode()
    local create = rawget(_G, "createZombie")
    local factory = rawget(_G, "SurvivorFactory")
    if type(create) == "function" and functionExists(factory, "CreateSurvivor") then
        return "createZombie"
    end
    if type(rawget(_G, "addZombiesInOutfit")) == "function" then
        return "addZombiesInOutfit"
    end
    return nil
end

local function dedicatedServerRuntime()
    -- This adapter is loaded from the server package. If a future runtime
    -- exposes the module in another context, only an explicit non-server
    -- result may opt into the synchronous createZombie path. In B42 MP the
    -- GlobalObject factory can block the server thread, so unknown must fail
    -- closed to the non-blocking population API below.
    if type(isServer) ~= "function" then return true end
    local ok, value = pcall(isServer)
    return not ok or value == true
end

local function factoryDescriptor()
    local factory = rawget(_G, "SurvivorFactory")
    if not functionExists(factory, "CreateSurvivor") then return nil end

    -- Friendly is a vanilla Build 42 descriptor type. If the enum is not
    -- exposed by this runtime, the documented no-argument factory remains a
    -- safe fallback and the adapter still enforces its own policy afterward.
    local survivorType = rawget(_G, "SurvivorType")
    if survivorType == nil then
        local okType, value = pcall(function() return factory.SurvivorType end)
        if okType then survivorType = value end
    end
    local friendlyType = survivorType ~= nil and survivorType.Friendly or nil
    -- This is the public Build 42 form used by the official forum example.
    -- The enum overload is only a fallback because some runtimes expose the
    -- enum table but reject it when called from a dedicated server.
    local ok, descriptor = pcall(factory.CreateSurvivor)
    if not ok or descriptor == nil then
        if friendlyType ~= nil then
            ok, descriptor = pcall(factory.CreateSurvivor, friendlyType)
        end
    end
    if not ok then return nil end
    if descriptor ~= nil and friendlyType ~= nil
        and functionExists(descriptor, "setType") then
        pcall(descriptor.setType, descriptor, friendlyType)
    end
    return descriptor
end

local function listFirst(value)
    if value == nil then return nil end
    if functionExists(value, "size") then
        if not functionExists(value, "get") then return nil end
        local okSize, size = pcall(function() return value:size() end)
        if not okSize or type(size) ~= "number" or size < 1 then return nil end
        local okFirst, first = pcall(function() return value:get(0) end)
        if okFirst then return first end
        return nil
    end
    if type(value) == "table" then
        return value[1]
    end
    -- A non-collection Java proxy is treated as a body and is validated by
    -- NativeAdapter.prepare before ownership is recorded.
    return value
end

local function reservationMatches(body, npcId)
    local reservation = spawnReservation
    if reservation == nil or reservation.npc_id ~= npcId
        or nowMs() > (reservation.expires_at or 0) then
        return false
    end
    local point = position(body)
    local radiusSquared = tonumber(reservation.radius_squared) or 9
    if point == nil or distanceSquared(point, reservation.point) > radiusSquared then
        return false
    end
    local data = dataFor(body)
    if data ~= nil and data.goblin_owned == true
        and data.goblin_npc_id ~= npcId then
        return false
    end
    return true
end

local function nearestUnmanagedZombie(spawnPoint, radius)
    local limitSquared = (tonumber(radius) or 0) ^ 2
    if spawnPoint == nil or limitSquared <= 0 then return nil, nil end
    local nearest, nearestDistance = nil, math.huge
    eachZombie(function(zombie)
        if not bodyDead(zombie) and bodyExists(zombie) then
            local data = dataFor(zombie)
            if data == nil or data.goblin_owned ~= true then
                local point = position(zombie)
                local distance = distanceSquared(point, spawnPoint)
                if point ~= nil and distance <= limitSquared
                    and distance < nearestDistance then
                    nearest = zombie
                    nearestDistance = distance
                end
            end
        end
    end)
    return nearest, nearestDistance
end

local function clearReservation(npcId)
    if spawnReservation == nil or npcId == nil
        or spawnReservation.npc_id == npcId then
        spawnReservation = nil
    end
end

local function removeBody(body)
    if body == nil then return false end
    combatTargets[body] = nil
    safeCall(body, "setTarget", nil)
    safeCall(body, "removeFromSquare")
    safeCall(body, "removeFromWorld")
    return true
end

local function setSafeBodyHooks(body, displayName, protectedBody, preserveTarget)
    if body == nil then return end
    if functionExists(body, "setNoDamage") then
        pcall(body.setNoDamage, body, protectedBody == true)
    end
    if functionExists(body, "setInvulnerable") then
        pcall(body.setInvulnerable, body, protectedBody == true)
    end
    if protectedBody then
        if functionExists(body, "setImmortal") then
            pcall(body.setImmortal, body, true)
        end
        if functionExists(body, "setImmortalTutorialZombie") then
            pcall(body.setImmortalTutorialZombie, body, true)
        end
        -- Protection is immortality/recovery, not invisibility. Normal
        -- zombies must still be able to perceive and attack Goblin for the
        -- survivor interaction gate, so never set this body-level opt-out.
        if functionExists(body, "setZombiesDontAttack") then
            pcall(body.setZombiesDontAttack, body, false)
        end
    elseif functionExists(body, "setZombiesDontAttack") then
        pcall(body.setZombiesDontAttack, body, false)
    end
    if not preserveTarget then
        safeCall(body, "setTarget", nil)
        safeCall(body, "clearAggroList")
    end
    if functionExists(body, "setDisplayName") then
        pcall(body.setDisplayName, body, displayName or Config.npcName)
    elseif functionExists(body, "setName") then
        pcall(body.setName, body, displayName or Config.npcName)
    end
end

local function movementMethod(body)
    if functionExists(body, "pathToLocationF") then return "pathToLocationF" end
    if functionExists(body, "pathToLocation") then return "pathToLocation" end
    return nil
end

local function clearNavigation(body)
    safeCall(body, "setTarget", nil)
    safeCall(body, "setThumpTarget", nil)
    safeCall(body, "setAttackTargetSquare", nil)
    safeCall(body, "setPath2", nil)
    safeCall(body, "setPathing", false)
    safeCall(body, "clearAggroList")
end

-- Shared physical-body invariant hook used by GSSurvivor.Survivorize() and
-- its cheap update-time checks. preserveTarget is required for survivor-vs-
-- zombie combat: invariant checks must not erase an intentional target.
function NativeAdapter.applySurvivorInvariants(body, profile, preserveTarget)
    if body == nil or type(profile) ~= "table" then return false end
    local protectedBody = profile.immortal == true
    setSafeBodyHooks(body, profile.displayName, protectedBody, preserveTarget)
    if not preserveTarget then clearNavigation(body) end
    safeCall(body, "setEatBodyTarget", nil, false)
    safeCall(body, "setThumpTarget", nil)
    safeCall(body, "setAttackTargetSquare", nil)
    safeCall(body, "setCrawler", false)
    safeCall(body, "setFakeDead", false)
    safeCall(body, "setReanimatedPlayer", false)
    safeCall(body, "setReanimatedForGrappleOnly", false)
    safeCall(body, "setCanWalk", true)
    safeCall(body, "setBite", false)
    safeCall(body, "setCantBite", true)
    safeCall(body, "setVoiceSoundName", "")
    safeCall(body, "setBiteSoundName", "")
    -- B42 exposes these sound fields on the Java class in documentation, but
    -- they are not writable through Kahlua on the dedicated server. Do not
    -- assign Java-backed fields; the capability-gated sound-name setters
    -- above are the supported suppression surface.
    if type(body.setVariable) == "function" then
        pcall(body.setVariable, body, "MovementSpeed",
            tonumber(profile.walkSpeed) or 0.70)
    end
    return true
end

local function pathTo(body, x, y, z)
    if body == nil then return false, "NPC body is missing" end
    if functionExists(body, "pathToLocationF") then
        local ok = pcall(body.pathToLocationF, body, x, y, z)
        if ok then return true, "native path request accepted" end
    end
    if functionExists(body, "pathToLocation") then
        local ok = pcall(body.pathToLocation, body,
            math.floor(x), math.floor(y), math.floor(z))
        if ok then return true, "native path request accepted" end
    end
    return false, "native movement API is unavailable"
end

local function nativeMove(body, task, targetPlayer, targetBody)
    local fleeing = task.mode == "RETREAT" or task.mode == "FLEE"
    if functionExists(body, "setRunning") then
        pcall(body.setRunning, body, fleeing)
    end
    if functionExists(body, "setSprinting") then
        pcall(body.setSprinting, body, false)
    end

    if targetPlayer ~= nil and functionExists(body, "pathToCharacter") then
        local ok = pcall(body.pathToCharacter, body, targetPlayer)
        -- Following a player must never leave that player as the body's
        -- hostile target. pathToCharacter is navigation, not ownership.
        safeCall(body, "setTarget", nil)
        if ok then return true, "native follow path accepted" end
    end
    if targetBody ~= nil and functionExists(body, "pathToCharacter") then
        local ok = pcall(body.pathToCharacter, body, targetBody)
        safeCall(body, "setTarget", nil)
        if ok then return true, "native squad path accepted" end
    end
    return pathTo(body, task.x, task.y, task.z)
end

local function ensureFriendlyState(body, npcId)
    local data = dataFor(body)
    if data == nil or data.goblin_npc_id ~= npcId
        or data.goblin_owned ~= true or data.goblin_friendly ~= true
        or data.goblin_hostile == true then
        return false
    end
    setSafeBodyHooks(body, data.goblin_display_name,
        data.goblin_protected == true)
    return true
end

local function inventoryFlags(body, data)
    -- Inventory inspection is deliberately cached. It is useful for the
    -- deterministic reflex layer, but it must not become a full inventory
    -- walk on every OnZombieUpdate callback.
    local timestamp = nowMs()
    if data ~= nil and data.goblin_inventory_probe_at ~= nil
        and timestamp - data.goblin_inventory_probe_at < 2000 then
        return data.goblin_weapon_ready == true,
            data.goblin_has_food == true,
            data.goblin_has_water == true,
            data.goblin_has_medical == true
    end

    local weaponReady, hasFood, hasWater, hasMedical = false, false, false, false
    local okInventory, inventory = false, nil
    if body ~= nil and functionExists(body, "getInventory") then
        okInventory, inventory = pcall(function() return body:getInventory() end)
    end
    if okInventory and inventory ~= nil then
        if functionExists(inventory, "getFirstCategory") then
            local okFood, food = pcall(function()
                return inventory:getFirstCategory("Food")
            end)
            hasFood = okFood and food ~= nil
            local okMedical, medical = pcall(function()
                return inventory:getFirstCategory("Medical")
            end)
            hasMedical = okMedical and medical ~= nil
        end
        if functionExists(inventory, "getFirstWaterFluidSources") then
            local okWater, water = pcall(function()
                return inventory:getFirstWaterFluidSources(false)
            end)
            hasWater = okWater and water ~= nil
        end
    end
    if functionExists(body, "getPrimaryHandItem") then
        local okItem, item = pcall(function() return body:getPrimaryHandItem() end)
        if okItem and item ~= nil then
            if functionExists(item, "isWeapon") then
                local okWeapon, value = pcall(function() return item:isWeapon() end)
                weaponReady = okWeapon and value == true
            elseif functionExists(item, "IsWeapon") then
                local okWeapon, value = pcall(function() return item:IsWeapon() end)
                weaponReady = okWeapon and value == true
            end
        end
    end
    if data ~= nil then
        data.goblin_inventory_probe_at = timestamp
        data.goblin_weapon_ready = weaponReady
        data.goblin_has_food = hasFood
        data.goblin_has_water = hasWater
        data.goblin_has_medical = hasMedical
    end
    return weaponReady, hasFood, hasWater, hasMedical
end

function NativeAdapter.available()
    return nativeSpawnMode() ~= nil
end

function NativeAdapter.engineName()
    return "native"
end

function NativeAdapter.capabilities()
    local mode = nativeSpawnMode()
    local ready = mode ~= nil
    return {
        available = ready,
        control_ready = ready,
        friendly = ready,
        spawnIndividual = ready,
        networkedBody = "ProjectZomboid/IsoZombie",
        movement = true,
        speech = true,
        restore = true,
        externalFramework = false,
        framework = "Project Zomboid",
        workshop_id = nil,
        program = "GoblinSurvivorNative",
        spawn_api = mode or "unavailable",
        combat = ready and "bounded_native_zombie_target" or "unavailable"
    }
end

function NativeAdapter.isCandidate(body, npcId)
    local requestedId = npcId or Config.npcId
    local data = dataFor(body)
    return data ~= nil
        and data.goblin_engine == NativeAdapter.engineName()
        and data.goblin_npc_id == requestedId
        and data.goblin_owned == true
end

-- During an immediate native spawn event there may not be mod-data on the
-- returned body yet. The short-lived reservation is the only event fallback;
-- a normal population zombie is never claimed without that reservation.
function NativeAdapter.isEventCandidate(body, npcId)
    local requestedId = npcId or Config.npcId
    if NativeAdapter.isCandidate(body, requestedId) then return true end
    return reservationMatches(body, requestedId)
end

function NativeAdapter.isFriendly(body, npcId)
    local requestedId = npcId or Config.npcId
    local data = dataFor(body)
    return data ~= nil
        and data.goblin_engine == NativeAdapter.engineName()
        and data.goblin_npc_id == requestedId
        and data.goblin_owned == true
        and data.goblin_friendly == true
        and data.goblin_hostile ~= true
end

function NativeAdapter.isOwned(body, npcId)
    return NativeAdapter.isFriendly(body, npcId)
end

function NativeAdapter.isForeignManaged(body, npcId)
    local requestedId = npcId or Config.npcId
    local data = dataFor(body)
    return data ~= nil
        and data.goblin_npc_id == requestedId
        and data.goblin_owned == true
        and data.goblin_engine ~= NativeAdapter.engineName()
end

function NativeAdapter.prepare(body, npcId, anchor, displayName, role)
    local requestedId = npcId or Config.npcId
    if not NativeAdapter.isCandidate(body, requestedId)
        and not NativeAdapter.isEventCandidate(body, requestedId) then
        return false, "body is not a reserved GoblinSurvivor native body"
    end
    local data = dataFor(body)
    if data == nil then return false, "NPC mod-data API is unavailable" end

    local profile = {
        id = requestedId,
        survivorId = requestedId,
        type = requestedId == Config.npcId and "GOBLIN" or "COMPANION",
        displayName = displayName or data.goblin_display_name or Config.npcName,
        role = role or data.goblin_role
            or (requestedId == Config.npcId and Config.npcRole or "companion"),
        immortal = requestedId == Config.npcId and Config.protected == true,
        infectionImmune = requestedId == Config.npcId and Config.protected == true,
        needsFood = requestedId ~= Config.npcId,
        needsWater = requestedId ~= Config.npcId,
        needsSleep = requestedId ~= Config.npcId,
        defaultGoal = requestedId == Config.npcId and "FOLLOW" or "IDLE",
        externalBrain = requestedId == Config.npcId and "GOBLIN" or "NONE",
        walkSpeed = 0.70
    }
    -- Keep conversion in exactly one public routine. The lazy require avoids
    -- a load-time cycle because GSSurvivor itself uses this adapter.
    local Survivor = require("GoblinSurvivor/GSSurvivor")
    local converted, conversionDetail = Survivor.Survivorize(body, profile)
    if not converted then return false, conversionDetail end
    data = dataFor(body)
    data.goblin_engine = NativeAdapter.engineName()
    data.goblin_native_spawned_at = data.goblin_native_spawned_at or nowMs()
    data.goblin_next_path_at = data.goblin_next_path_at or 0
    data.goblin_movement_api = movementMethod(body)
    combatTargets[body] = nil
    ownedBodies[requestedId] = body
    clearReservation(requestedId)
    if functionExists(body, "transmitModData") then
        pcall(body.transmitModData, body)
    end
    if not NativeAdapter.isFriendly(body, requestedId) then
        return false, "native body did not retain friendly ownership state"
    end
    return true, "native Project Zomboid body prepared"
end

local function usableSpawnSquare(square)
    if square == nil then return false end
    if functionExists(square, "canStand") then
        local ok, canStand = pcall(function() return square:canStand() end)
        if not ok or canStand ~= true then return false end
    end
    if functionExists(square, "isFree") then
        local ok, isFree = pcall(function() return square:isFree(true) end)
        if not ok or isFree ~= true then return false end
    end
    return true
end

local function nearbyFreeSquare(cell, center, radius)
    if cell == nil or center == nil or not functionExists(cell, "getGridSquare") then
        return nil
    end
    local maximum = math.max(1, math.min(tonumber(radius) or 12, 16))
    local centerX, centerY, centerZ = math.floor(center.x), math.floor(center.y), math.floor(center.z)
    -- Walk the perimeter of expanding squares so the first accepted result is
    -- close to the player but cannot be the player's occupied square.
    for distance = 1, maximum do
        for dx = -distance, distance do
            for dy = -distance, distance do
                if math.abs(dx) == distance or math.abs(dy) == distance then
                    local ok, square = pcall(function()
                        return cell:getGridSquare(centerX + dx, centerY + dy, centerZ)
                    end)
                    if ok and usableSpawnSquare(square) then return square end
                end
            end
        end
    end
    return nil
end

function NativeAdapter.spawnPoint(anchor, extraOffset)
    local point = position(anchor)
    if point == nil then return nil end
    local offset = tonumber(extraOffset) or tonumber(Config.npcSpawnOffsetTiles) or 16
    if offset < 8 then offset = 8 end

    -- A connected player exposes an already-streamed current square. Prefer
    -- a nearby square in that stream over a diagonal coordinate that may be
    -- valid in the world but absent from this server cell.
    local anchorSquare = nil
    if functionExists(anchor, "getCurrentSquare") then
        local okSquare, value = pcall(function() return anchor:getCurrentSquare() end)
        if okSquare then anchorSquare = value end
    end
    if anchorSquare == nil and functionExists(anchor, "getSquare") then
        local okSquare, value = pcall(function() return anchor:getSquare() end)
        if okSquare then anchorSquare = value end
    end
    local anchorSquarePoint = position(anchorSquare)
    local candidate = {
        x = math.floor(point.x + offset),
        y = math.floor(point.y + offset),
        z = math.floor(point.z)
    }

    -- The native creators resolve their coordinates through the server cell.
    -- A newly connected player can be visible to the network layer before the
    -- diagonal offset square is present in that cell, which produces the
    -- vanilla "No IsoSquare selected" warning.  Resolve/create the square
    -- before calling either native creator, then use the square's coordinates
    -- when the Java proxy exposes them.
    local cell = nativeWorldCell()
    if cell ~= nil then
            local searchCenter = anchorSquarePoint or point
            local freeSquare = nearbyFreeSquare(cell, searchCenter, offset)
            if freeSquare ~= nil then
                local resolvedFree = position(freeSquare)
                if resolvedFree ~= nil then
                    candidate.x = math.floor(resolvedFree.x)
                    candidate.y = math.floor(resolvedFree.y)
                    candidate.z = math.floor(resolvedFree.z)
                    log("using free streamed square for spawn at "
                        .. tostring(candidate.x) .. "," .. tostring(candidate.y)
                        .. "," .. tostring(candidate.z))
                    return candidate
                end
            end
            if anchorSquarePoint == nil and functionExists(cell, "getGridSquare") then
                local okAnchor, value = pcall(function()
                    return cell:getGridSquare(math.floor(point.x),
                        math.floor(point.y), math.floor(point.z))
                end)
                if okAnchor then
                    anchorSquare = value
                    anchorSquarePoint = position(anchorSquare)
                end
            end
            if anchorSquarePoint == nil
                and functionExists(cell, "getOrCreateGridSquare") then
                local okAnchor, value = pcall(function()
                    return cell:getOrCreateGridSquare(math.floor(point.x),
                        math.floor(point.y), math.floor(point.z))
                end)
                if okAnchor then
                    anchorSquare = value
                    anchorSquarePoint = position(anchorSquare)
                end
            end
            if anchorSquarePoint ~= nil and functionExists(cell, "getGridSquare") then
                local nearbyOffsets = {
                    { x = 1, y = 0 }, { x = -1, y = 0 },
                    { x = 0, y = 1 }, { x = 0, y = -1 },
                    { x = 2, y = 1 }, { x = 1, y = 2 }
                }
                for _, nearby in ipairs(nearbyOffsets) do
                    local nearbyX = math.floor(anchorSquarePoint.x + nearby.x)
                    local nearbyY = math.floor(anchorSquarePoint.y + nearby.y)
                    local okNearby, nearbySquare = pcall(function()
                        return cell:getGridSquare(nearbyX, nearbyY,
                            math.floor(anchorSquarePoint.z))
                    end)
                    if okNearby and nearbySquare ~= nil then
                        local canStand = true
                        if functionExists(nearbySquare, "canStand") then
                            local okStand, value = pcall(function()
                                return nearbySquare:canStand()
                            end)
                            canStand = okStand and value == true
                        end
                        if canStand then
                            local resolvedNearby = position(nearbySquare)
                            if resolvedNearby ~= nil then
                                candidate.x = math.floor(resolvedNearby.x)
                                candidate.y = math.floor(resolvedNearby.y)
                                candidate.z = math.floor(resolvedNearby.z)
                                return candidate
                            end
                        end
                    end
                end
                -- Never fall back to the player's occupied square. A failed
                -- free-square search is retried by the bounded registry once
                -- the client has streamed more of the surrounding cell.
                if usableSpawnSquare(anchorSquare) then
                    candidate.x = math.floor(anchorSquarePoint.x)
                    candidate.y = math.floor(anchorSquarePoint.y)
                    candidate.z = math.floor(anchorSquarePoint.z)
                    return candidate
                end
                log("no free streamed square is available around the player")
                return nil
            end
            local square = nil
            if functionExists(cell, "getGridSquare") then
                local okSquare, value = pcall(function()
                    return cell:getGridSquare(candidate.x, candidate.y, candidate.z)
                end)
                if okSquare then square = value end
            end
            if square == nil and functionExists(cell, "getOrCreateGridSquare") then
                local okSquare, value = pcall(function()
                    return cell:getOrCreateGridSquare(candidate.x, candidate.y, candidate.z)
                end)
                if okSquare then square = value end
            end
            if square ~= nil and usableSpawnSquare(square) then
                local resolved = position(square)
                if resolved ~= nil then
                    candidate.x = math.floor(resolved.x)
                    candidate.y = math.floor(resolved.y)
                    candidate.z = math.floor(resolved.z)
                end
            else
                log("spawn square is not loaded at " .. tostring(candidate.x)
                    .. "," .. tostring(candidate.y) .. "," .. tostring(candidate.z))
                return nil
            end
        end
    return candidate
end

local function spawnCellAndSquare(spawnPoint)
    local cell = nativeWorldCell()
    if cell == nil then return nil, nil end
    local square = nil
    if functionExists(cell, "getGridSquare") then
        local okSquare, value = pcall(function()
            return cell:getGridSquare(math.floor(spawnPoint.x),
                math.floor(spawnPoint.y), math.floor(spawnPoint.z))
        end)
        if okSquare then square = value end
    end
    if square == nil and functionExists(cell, "getOrCreateGridSquare") then
        local okSquare, value = pcall(function()
            return cell:getOrCreateGridSquare(math.floor(spawnPoint.x),
                math.floor(spawnPoint.y), math.floor(spawnPoint.z))
        end)
        if okSquare then square = value end
    end
    return cell, square
end

local function createNativeBody(spawnPoint, anchor)
    local mode = nativeSpawnMode()
    local descriptor = factoryDescriptor()
    local cell, square = spawnCellAndSquare(spawnPoint)

    log("native spawn probe: mode=" .. tostring(mode)
        .. ", descriptor=" .. tostring(descriptor ~= nil)
        .. ", cell=" .. tostring(cell ~= nil)
        .. ", square=" .. tostring(square ~= nil))

    if mode == "createZombie" and not dedicatedServerRuntime() then
        if descriptor ~= nil then
            local direction = nil
            if anchor ~= nil and functionExists(anchor, "getDir") then
                local okDir, value = pcall(function() return anchor:getDir() end)
                if okDir then direction = value end
            end
            if direction == nil then
                local directions = rawget(_G, "IsoDirections")
                direction = directions ~= nil and directions.S or nil
            end
            -- Use the selected free square, not the player's occupied
            -- floating coordinates. createZombie resolves the square from
            -- its coordinates and returns nil when the player is in the way.
            local spawnX = tonumber(spawnPoint.x) + 0.5
            local spawnY = tonumber(spawnPoint.y) + 0.5
            local spawnZ = tonumber(spawnPoint.z)
            log("createZombie request at " .. tostring(spawnX) .. ","
                .. tostring(spawnY) .. "," .. tostring(spawnZ)
                .. " direction=" .. tostring(direction))
            local ok, bodyOrError = pcall(createZombie, spawnX, spawnY,
                spawnZ, descriptor, 0, direction)
            if ok and bodyOrError ~= nil then return bodyOrError, "createZombie" end
            log("createZombie failed (ok=" .. tostring(ok) .. ", value="
                .. tostring(bodyOrError)
                .. "); trying the vanilla outfit spawn fallback")

            -- Some Build 42 server paths accept the same documented factory
            -- only with the vanilla descriptor. Keep the attempt bounded and
            -- still apply GoblinSurvivor ownership immediately afterward.
            local okVanilla, vanillaBody = pcall(createZombie, spawnX, spawnY,
                spawnZ, nil, 0, direction)
            if okVanilla and vanillaBody ~= nil then
                return vanillaBody, "createZombie-vanilla-descriptor"
            end
            log("createZombie vanilla-descriptor fallback failed (ok="
                .. tostring(okVanilla) .. ", value=" .. tostring(vanillaBody)
                .. ")")
        end
    elseif mode == "createZombie" then
        log("skipping synchronous createZombie on the dedicated B42 server")
    end

    local add = rawget(_G, "addZombiesInOutfit")
    if type(add) == "function" and not dedicatedServerRuntime() then
        -- The first overload is present in Build 42 and returns the created
        -- IsoZombie list. A survivor outfit is deliberately requested; the
        -- ownership and friendly policy are applied before the next tick.
        local ok, resultOrError = pcall(add, spawnPoint.x, spawnPoint.y, spawnPoint.z,
            1, "Survivor", 50)
        if ok then
            local body = listFirst(resultOrError)
            if body ~= nil then return body, "addZombiesInOutfit" end
            log("addZombiesInOutfit returned no body (value="
                .. tostring(resultOrError) .. ")")
        else
            log("addZombiesInOutfit failed (" .. tostring(resultOrError) .. ")")
        end
    elseif type(add) == "function" then
        log("skipping synchronous addZombiesInOutfit on the dedicated B42 server")
    end

    -- The point overload can reject a freshly streamed square even when the
    -- surrounding chunk is ready. The documented area overload asks the
    -- engine to choose a valid square in that same small, reserved area and
    -- returns the created IsoZombie list.
    local addArea = rawget(_G, "addZombiesInOutfitArea")
    if type(addArea) == "function" and not dedicatedServerRuntime() then
        local radius = 2
        local ok, resultOrError = pcall(addArea,
            spawnPoint.x - radius, spawnPoint.y - radius,
            spawnPoint.x + radius, spawnPoint.y + radius,
            spawnPoint.z, 1, nil, nil)
        if ok then
            local body = listFirst(resultOrError)
            if body ~= nil then return body, "addZombiesInOutfitArea" end
            log("addZombiesInOutfitArea returned no body (value="
                .. tostring(resultOrError) .. ")")
        else
            log("addZombiesInOutfitArea failed (" .. tostring(resultOrError) .. ")")
        end
    elseif type(addArea) == "function" then
        log("skipping synchronous addZombiesInOutfitArea on the dedicated B42 server")
    end

    -- Build 42 exposes the vanilla VirtualZombieManager as a native
    -- networked IsoZombie factory.  Its choices-based overload performs the
    -- complete engine registration path: square placement, zombie-list
    -- membership, network id allocation, and the OnZombieCreate event.  This
    -- is the only supported dedicated-server body path currently verified.
    local managerClass = rawget(_G, "VirtualZombieManager")
    local manager = managerClass ~= nil and managerClass.instance or nil
    local managerChoices = manager ~= nil and manager.choices or nil
    log("real-zombie choice probe: manager=" .. tostring(manager ~= nil)
        .. ", choices=" .. tostring(managerChoices ~= nil)
        .. ", square=" .. tostring(square ~= nil)
        .. ", clear_type=" .. tostring(managerChoices ~= nil
            and type(managerChoices.clear) or "nil")
        .. ", add_type=" .. tostring(managerChoices ~= nil
            and type(managerChoices.add) or "nil"))
    if manager ~= nil and managerChoices ~= nil and square ~= nil
        and functionExists(managerChoices, "clear")
        and functionExists(managerChoices, "add") then
        local directions = rawget(_G, "IsoDirections")
        local direction = nil
        if anchor ~= nil and functionExists(anchor, "getDir") then
            local okDir, value = pcall(function() return anchor:getDir() end)
            if okDir then direction = value end
        end
        if direction == nil and directions ~= nil then direction = directions.S end
        pcall(managerChoices.clear, managerChoices)
        local okChoice, choiceError = pcall(managerChoices.add,
            managerChoices, square)
        if okChoice and functionExists(manager, "createRealZombieAlways") then
            local ok, bodyOrError = pcall(manager.createRealZombieAlways,
                manager, direction, false)
            pcall(managerChoices.clear, managerChoices)
            if ok and bodyOrError ~= nil then
                return bodyOrError, "createRealZombieAlways"
            end
            log("createRealZombieAlways failed (ok=" .. tostring(ok)
                .. ", value=" .. tostring(bodyOrError) .. ")")
        else
            pcall(managerChoices.clear, managerChoices)
            log("createRealZombieAlways choice setup failed (ok="
                .. tostring(okChoice) .. ", value=" .. tostring(choiceError)
                .. ")")
        end
    else
        log("createRealZombieAlways choice setup unavailable")
    end

    -- Do not call coordinate-based VirtualZombieManager creators on the
    -- dedicated B42 server after the choices-based path fails: those methods
    -- can block the same dedicated B42 Lua thread during multiplayer startup.
    if dedicatedServerRuntime() then
        return nil, "dedicated networked real-zombie factory returned no body"
    end

    if manager ~= nil and functionExists(manager, "createRealZombie") then
        local ok, bodyOrError = pcall(manager.createRealZombie, manager,
            spawnPoint.x + 0.5, spawnPoint.y + 0.5, spawnPoint.z)
        if ok and bodyOrError ~= nil then
            return bodyOrError, "createRealZombie"
        end
        log("createRealZombie failed (ok=" .. tostring(ok) .. ", value="
            .. tostring(bodyOrError) .. ")")
    end
    if manager ~= nil and functionExists(manager, "createRealZombieNow") then
        local ok, bodyOrError = pcall(manager.createRealZombieNow, manager,
            spawnPoint.x + 0.5, spawnPoint.y + 0.5, spawnPoint.z)
        if ok and bodyOrError ~= nil then
            return bodyOrError, "createRealZombieNow"
        end
        log("createRealZombieNow failed (ok=" .. tostring(ok) .. ", value="
            .. tostring(bodyOrError) .. ")")
    elseif managerClass == nil then
        log("VirtualZombieManager is unavailable in this Lua runtime")
    else
        log("VirtualZombieManager native real-zombie creators are unavailable")
    end

    -- If the public creators decline a freshly streamed square, use an
    -- already-existing native body only inside this explicit spawn
    -- reservation. This is a controlled takeover, not a world-wide scan:
    -- the body must be alive, unmanaged, and within the reserved 15-tile
    -- radius around the connected player.
    local adopted, adoptedDistance = nearestUnmanagedZombie(spawnPoint, 15)
    if adopted ~= nil then
        log("adopting nearby native zombie for managed body at distance "
            .. tostring(math.sqrt(adoptedDistance)))
        return adopted, "adopt-nearby-native-zombie"
    end
    return nil, "native body creation API returned no body"
end

function NativeAdapter.spawnIndividual(anchor, npcId, _program, displayName, role, extraOffset)
    if not NativeAdapter.available() then
        return false, "native Project Zomboid NPC API is unavailable", nil
    end
    local requestedId = npcId or Config.npcId
    local spawnPoint = NativeAdapter.spawnPoint(anchor, extraOffset)
    if spawnPoint == nil then
        return false, "online player anchor has no spawn point", nil
    end

    spawnReservation = {
        npc_id = requestedId,
        point = spawnPoint,
        radius_squared = 225,
        expires_at = nowMs() + 15000
    }
    local body, mode = createNativeBody(spawnPoint, anchor)
    if body == nil then
        clearReservation(requestedId)
        return false, mode or "native body creation failed", nil, spawnPoint
    end
    local prepared, detail = NativeAdapter.prepare(
        body, requestedId, anchor, displayName, role
    )
    if not prepared then
        clearReservation(requestedId)
        removeBody(body)
        return false, detail, nil, spawnPoint
    end
    clearReservation(requestedId)
    return true, detail .. " via " .. tostring(mode), body, spawnPoint
end

function NativeAdapter.getBrain(body)
    return dataFor(body)
end

function NativeAdapter.say(body, text, npcId)
    if not NativeAdapter.isOwned(body, npcId) then
        return false, "friendly native NPC speech contract is unavailable"
    end
    if type(text) ~= "string" or #text < 1 or #text > 240 then
        return false, "NPC speech is malformed"
    end
    if functionExists(body, "addLineChatElement") then
        local ok = pcall(body.addLineChatElement, body, text, 0.1, 0.8, 0.1)
        if ok then return true, "speech accepted by native body" end
    end
    return false, "native body chat-line API is unavailable"
end

local function modeFor(data)
    if data ~= nil and data.goblin_combat == true then return "HUNT" end
    local task = data ~= nil and data.goblin_task or nil
    if type(task) == "table" then
        local mode = string.upper(tostring(task.mode or ""))
        if mode == "FOLLOW" or mode == "FOLLOW_GOBLIN"
            or type(task.target_player) == "string"
            or type(task.target_npc_id) == "string" then
            return "PARTY"
        end
    end
    return "ROAM"
end

function NativeAdapter.status(body, npcId)
    if not NativeAdapter.isOwned(body, npcId) then
        return {
            mode = "SAFE",
            task = nil,
            target_player = nil,
            target_npc_id = nil,
            friendly = false,
            protected = false,
            needs_disabled = false,
            weapon_ready = false,
            has_food = false,
            has_water = false,
            has_medical = false,
            movement_ready = false
        }
    end
    local data = dataFor(body)
    local task = data ~= nil and data.goblin_task or nil
    local weaponReady, hasFood, hasWater, hasMedical = inventoryFlags(body, data)
    return {
        mode = modeFor(data),
        task = type(task) == "table" and task.mode or nil,
        target_player = type(task) == "table" and task.target_player or nil,
        target_npc_id = type(task) == "table" and task.target_npc_id or nil,
        friendly = NativeAdapter.isFriendly(body, npcId),
        protected = data ~= nil and data.goblin_protected == true,
        needs_disabled = data ~= nil and data.goblin_needs_disabled == true,
        weapon_ready = weaponReady,
        has_food = hasFood,
        has_water = hasWater,
        has_medical = hasMedical,
        movement_ready = data ~= nil and data.goblin_movement_api ~= nil
    }
end

function NativeAdapter.setTasks(body, tasks, npcId)
    if not NativeAdapter.isOwned(body, npcId) or type(tasks) ~= "table" then
        return false, "friendly native NPC task contract is unavailable"
    end
    local task = tasks[1]
    if type(task) ~= "table"
        or (task.action ~= "GoTo" and task.action ~= "Move"
            and task.action ~= "Follow" and task.action ~= "ReturnHome")
        or type(task.x) ~= "number" or type(task.y) ~= "number"
        or type(task.z) ~= "number" then
        return false, "native NPC task is malformed"
    end
    local data = dataFor(body)
    if data == nil then return false, "NPC mod-data API is unavailable" end
    combatTargets[body] = nil
    data.goblin_combat = false
    data.goblin_task = {
        action = task.action,
        mode = task.mode or "MOVE_TO",
        x = task.x,
        y = task.y,
        z = task.z,
        target_player = task.target_player,
        target_npc_id = task.target_npc_id,
        follow_distance = task.follow_distance
    }
    data.goblin_next_path_at = 0
    clearNavigation(body)
    local targetPlayer = type(task.target_player) == "string"
        and playerFor(task.target_player) or nil
    local targetBody = type(task.target_npc_id) == "string"
        and ownedBodies[task.target_npc_id] or nil
    return nativeMove(body, data.goblin_task, targetPlayer, targetBody)
end

function NativeAdapter.clearTasks(body, npcId)
    if not NativeAdapter.isOwned(body, npcId) then
        return false, "friendly native NPC task contract is unavailable"
    end
    local data = dataFor(body)
    if data ~= nil then
        data.goblin_task = nil
        data.goblin_combat = false
        data.goblin_next_path_at = nil
    end
    combatTargets[body] = nil
    clearNavigation(body)
    if data ~= nil then
        setSafeBodyHooks(body, data.goblin_display_name,
            data.goblin_protected == true)
    end
    return true, "tasks cleared"
end

function NativeAdapter.setCombatTarget(body, target, npcId)
    if not NativeAdapter.isOwned(body, npcId) then
        return false, "friendly native NPC combat contract is unavailable"
    end
    if not liveTarget(target) then
        return false, "combat target is not a live hostile zombie"
    end
    local data = dataFor(body)
    if data == nil then return false, "NPC mod-data API is unavailable" end
    data.goblin_task = nil
    data.goblin_combat = true
    data.goblin_next_path_at = 0
    combatTargets[body] = target
    safeCall(body, "clearAggroList")
    local targeted = safeCall(body, "setTarget", target)
    local moved = false
    if functionExists(body, "pathToCharacter") then
        moved = pcall(body.pathToCharacter, body, target)
    end
    if not moved then
        local point = position(target)
        if point ~= nil then moved = pathTo(body, point.x, point.y, point.z) end
    end
    if targeted or moved then
        return true, "bounded native zombie combat target accepted"
    end
    return false, "native combat movement API is unavailable"
end

function NativeAdapter.tick(body, npcId)
    if not NativeAdapter.isOwned(body, npcId) then return false end
    if not ensureFriendlyState(body, npcId) then return false end

    local data = dataFor(body)
    -- FriendlySurvivor owns idle navigation and reasserts it from the server
    -- OnTick callback. Do not clear that active path here; command-created
    -- tasks and combat targets still use this adapter's normal path handling.
    if data ~= nil and data.goblin_friendly_survivor == true
        and data.goblin_combat ~= true
        and type(data.goblin_task) ~= "table" then
        return true
    end
    local combatTarget = combatTargets[body]
    if data ~= nil and data.goblin_combat == true and liveTarget(combatTarget) then
        local targeted = safeCall(body, "setTarget", combatTarget)
        local nextAt = tonumber(data.goblin_next_path_at) or 0
        if nowMs() >= nextAt then
            local moved = false
            if functionExists(body, "pathToCharacter") then
                moved = pcall(body.pathToCharacter, body, combatTarget)
            end
            if not moved then
                local point = position(combatTarget)
                if point ~= nil then moved = pathTo(body, point.x, point.y, point.z) end
            end
            data.goblin_next_path_at = nowMs() + 500
            return targeted or moved
        end
        return targeted
    end

    if data ~= nil and data.goblin_combat == true then
        data.goblin_combat = false
        data.goblin_next_path_at = nil
        combatTargets[body] = nil
    end
    clearNavigation(body)

    local task = data ~= nil and data.goblin_task or nil
    if type(task) ~= "table" then return true end
    local targetPlayer = nil
    if type(task.target_player) == "string" and task.target_player ~= "" then
        targetPlayer = playerFor(task.target_player)
        local targetPoint = position(targetPlayer)
        if targetPoint == nil then
            data.goblin_task = nil
            data.goblin_next_path_at = nil
            return false
        end
        task.x, task.y, task.z = targetPoint.x, targetPoint.y, targetPoint.z
    end
    local targetBody = nil
    if type(task.target_npc_id) == "string" and task.target_npc_id ~= "" then
        targetBody = ownedBodies[task.target_npc_id]
        if not NativeAdapter.isOwned(targetBody, task.target_npc_id) then
            targetBody = nil
        end
        local targetPoint = position(targetBody)
        if targetPoint == nil then
            data.goblin_task = nil
            data.goblin_next_path_at = nil
            return false
        end
        task.x, task.y, task.z = targetPoint.x, targetPoint.y, targetPoint.z
    end

    local nextAt = tonumber(data.goblin_next_path_at) or 0
    if nowMs() >= nextAt then
        local ok = nativeMove(body, task, targetPlayer, targetBody)
        data.goblin_next_path_at = nowMs() + 1000
        return ok
    end
    return true
end

function NativeAdapter.discard(body, npcId)
    if not NativeAdapter.isCandidate(body, npcId) then return false end
    local requestedId = npcId or Config.npcId
    if ownedBodies[requestedId] == body then ownedBodies[requestedId] = nil end
    return removeBody(body)
end

function NativeAdapter.removeForeign(body, npcId)
    if not NativeAdapter.isForeignManaged(body, npcId) then return false end
    local requestedId = npcId or Config.npcId
    if ownedBodies[requestedId] == body then ownedBodies[requestedId] = nil end
    log("removed a stale foreign-managed body for " .. tostring(requestedId))
    return removeBody(body)
end

return NativeAdapter

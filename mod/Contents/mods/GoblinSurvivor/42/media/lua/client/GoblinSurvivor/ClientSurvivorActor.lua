-- Client-side renderer for the server-authoritative human survivor slice.
--
-- IsoSurvivor is intentionally created only in the client runtime. It is not
-- sent through the vanilla zombie packet stream and it never becomes an
-- IsoZombie. Every client receives the same bounded position snapshot and
-- maintains its own visual object.
local Protocol = require("GoblinSurvivor/ClientSurvivorProtocol")

local Client = {
    actors = {},
    motion = {},
    nextCreateAt = {},
    lastSequence = {},
    generations = {},
    lastSpeechSequence = {},
    pendingSpeech = {},
    states = {},
    mapMarkers = {},
    mapFailureLogged = false,
    lastState = nil,
    nextRequestAt = 0,
    requestIntervalMs = 3000,
    started = false,
    lastDiagnosticsAt = 0,
    nextZombieDiagnosticsAt = 0,
    nextNameLabelDiagnosticsAt = 0,
    nameLabelFailureLogged = false
}

-- Server snapshots arrive at a deliberately conservative cadence.  Applying
-- each packet as a teleport makes the human model stutter and also resets the
-- engine's previous-position fields, so B42 never sees a continuous walk.
-- Keep a short visual-only interpolation window between authoritative points.
-- Large corrections and floor changes still snap so a stale packet cannot drag
-- an actor through the map.
local MOTION_DURATION_MS = 560
local MOTION_MIN_DURATION_MS = 220
local MOTION_MAX_DURATION_MS = 700
local WALK_SPEED_TILES_PER_SECOND = 1.4
local RUN_SPEED_TILES_PER_SECOND = 2.8
local MOTION_SNAP_DISTANCE = 6.0
local MOTION_FLOOR_EPSILON = 0.1

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] ClientSurvivorActor: " .. tostring(message))
    end
end

local function call(object, method, ...)
    if object == nil then return false, nil end
    -- Kahlua exposes java.lang.Class values as a special object. Looking up
    -- a method on one of those values outside pcall raises instead of
    -- returning nil (unlike ordinary Java userdata), so protect both the
    -- lookup and the invocation.
    local okMethod, fn = pcall(function() return object[method] end)
    if not okMethod or type(fn) ~= "function" then return false, nil end
    local ok, value = pcall(fn, object, ...)
    return ok, value
end

local function listRemove(list, object)
    if list == nil or type(list.remove) ~= "function" then return false end
    local ok, removed = pcall(list.remove, list, object)
    return ok and removed == true
end

local function listAddOnce(list, object)
    if list == nil or type(list.add) ~= "function" then return false end
    if type(list.contains) == "function" then
        local okContains, contains = pcall(list.contains, list, object)
        if okContains and contains == true then return true end
    end
    local ok, added = pcall(list.add, list, object)
    return ok and (added == true or added == nil)
end

local function cell()
    if type(getCell) ~= "function" then return nil end
    local ok, value = pcall(getCell)
    return ok and value or nil
end

local function localZombieDiagnostics(now)
    if now < Client.nextZombieDiagnosticsAt then return end
    Client.nextZombieDiagnosticsAt = now + 5000
    local worldCell = cell()
    if worldCell == nil then
        log("local zombie diagnostics: cell unavailable")
        return
    end
    local okList, zombies = call(worldCell, "getZombieList")
    if not okList or zombies == nil then
        log("local zombie diagnostics: zombie list unavailable")
        return
    end
    local okSize, size = call(zombies, "size")
    if not okSize or type(size) ~= "number" then
        log("local zombie diagnostics: zombie list size unavailable")
        return
    end
    local playerX, playerY = nil, nil
    if type(getPlayer) == "function" then
        local okPlayer, player = pcall(getPlayer)
        if okPlayer and player ~= nil then
            local okX, x = call(player, "getX")
            local okY, y = call(player, "getY")
            if okX and type(x) == "number" then playerX = x end
            if okY and type(y) == "number" then playerY = y end
        end
    end
    local fixtureCount = 0
    local fixtures = {}
    local nearby = {}
    for index = 0, size - 1 do
        local okZombie, zombie = call(zombies, "get", index)
        if okZombie and zombie ~= nil then
            local okData, data = call(zombie, "getModData")
            local marker = nil
            local actorId = nil
            if okData and data ~= nil then
                local okMarker, markerValue = call(data, "rawget", "goblin_debug_combat_fixture")
                local okActor, actorValue = call(data, "rawget", "goblin_debug_combat_actor")
                if okMarker then marker = markerValue end
                if okActor then actorId = actorValue end
            end
            if marker == true then
                fixtureCount = fixtureCount + 1
                local okId, id = call(zombie, "getID")
                local okOnlineId, onlineId = call(zombie, "getOnlineID")
                local okX, x = call(zombie, "getX")
                local okY, y = call(zombie, "getY")
                local okDead, dead = call(zombie, "isDead")
                table.insert(fixtures, "id=" .. tostring(okId and id or "?")
                    .. " online=" .. tostring(okOnlineId and onlineId or "?")
                    .. " actor=" .. tostring(actorId)
                    .. " x=" .. tostring(okX and x or "?")
                    .. " y=" .. tostring(okY and y or "?")
                    .. " dead=" .. tostring(okDead and dead or false))
            end
            if playerX ~= nil and playerY ~= nil then
                local okX, x = call(zombie, "getX")
                local okY, y = call(zombie, "getY")
                if okX and okY and type(x) == "number" and type(y) == "number" then
                    local distance = math.sqrt((x - playerX) * (x - playerX)
                        + (y - playerY) * (y - playerY))
                    if distance <= 12 then
                        local okId, id = call(zombie, "getID")
                        local okOnlineId, onlineId = call(zombie, "getOnlineID")
                        table.insert(nearby, {
                            distance = distance,
                            text = "id=" .. tostring(okId and id or "?")
                                .. " online=" .. tostring(okOnlineId and onlineId or "?")
                                .. " x=" .. tostring(x)
                                .. " y=" .. tostring(y)
                                .. " d=" .. string.format("%.1f", distance)
                                .. " marked=" .. tostring(marker == true)
                        })
                    end
                end
            end
        end
    end
    table.sort(nearby, function(left, right)
        return left.distance < right.distance
    end)
    local nearbyText = {}
    for index = 1, math.min(#nearby, 8) do
        table.insert(nearbyText, nearby[index].text)
    end
    log("local zombie diagnostics: list=" .. tostring(size)
        .. " marked_fixtures=" .. tostring(fixtureCount)
        .. " player=" .. tostring(playerX) .. "," .. tostring(playerY)
        .. " nearby=" .. tostring(#nearby)
        .. (#nearbyText > 0 and " [" .. table.concat(nearbyText, "; ") .. "]" or "")
        .. (#fixtures > 0 and " fixtures=[" .. table.concat(fixtures, "; ") .. "]" or ""))
end

local function squareFor(worldCell, x, y, z)
    if worldCell == nil then return nil end
    local ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
    if type(worldCell.getGridSquare) == "function" then
        local ok, square = pcall(worldCell.getGridSquare, worldCell, ix, iy, iz)
        if ok and square ~= nil then return square end
    end
    if type(worldCell.getOrCreateGridSquare) == "function" then
        local ok, square = pcall(worldCell.getOrCreateGridSquare, worldCell, ix, iy, iz)
        if ok then return square end
    end
    return nil
end

local function actorPosition(actor)
    local okX, x = call(actor, "getX")
    local okY, y = call(actor, "getY")
    local okZ, z = call(actor, "getZ")
    if not okX or not okY or not okZ
        or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return x, y, z
end

local function updateWorldPosition(actor, x, y, z)
    local worldCell = cell()
    local square = squareFor(worldCell, x, y, z)
    if square == nil then return false end

    local okCurrent, currentSquare = call(actor, "getCurrentSquare")
    if okCurrent and currentSquare ~= nil and currentSquare ~= square then
        call(actor, "removeFromSquare")
    end

    local okMovingSquare, movingSquare = call(actor, "getMovingSquare")
    if not okMovingSquare or movingSquare ~= square then
        local attached = call(actor, "setMovingSquare", square)
        if not attached then
            local okMoving, movingObjects = call(square, "getMovingObjects")
            if okMoving then listAddOnce(movingObjects, actor) end
        end
    end
    call(actor, "setCurrentSquare", square)
    call(actor, "ensureVisualRegistration")
    return true
end

local function setRenderedPosition(actor, x, y, z, previousX, previousY, previousZ)
    -- Set the previous fields first.  This is the small but important
    -- distinction from the old snapshot path, which wrote Lx/Ly/Lz to the
    -- destination and thereby made every update look stationary to animation.
    call(actor, "setLx", previousX)
    call(actor, "setLy", previousY)
    call(actor, "setLz", previousZ)
    call(actor, "setX", x)
    call(actor, "setY", y)
    call(actor, "setZ", z)
    updateWorldPosition(actor, x, y, z)
end

local function navigationIsMoving(state)
    if state.movement_blocked == true then return false end
    local navigation = state.navigation_status
    return navigation == "moving"
        or navigation == "group_return"
        or navigation == "returning"
        or navigation == "vehicle_approach"
        or navigation == "vehicle_driving"
end

local function motionDurationMs(distance, state)
    if not navigationIsMoving(state) or distance <= 0.001 then
        return MOTION_DURATION_MS
    end
    -- Match the server's authoritative travel speed instead of using one
    -- fixed interpolation window for both walking and running.  This keeps a
    -- run from arriving early and then visibly braking at every snapshot,
    -- while the clamps absorb packet jitter and short route corrections.
    local speed = state.running == true
        and RUN_SPEED_TILES_PER_SECOND
        or WALK_SPEED_TILES_PER_SECOND
    local duration = math.floor(distance / speed * 1000 + 0.5)
    return math.max(MOTION_MIN_DURATION_MS,
        math.min(MOTION_MAX_DURATION_MS, duration))
end

local function setMotionTarget(id, actor, state, snap)
    local now = Protocol.nowMs()
    local currentX, currentY, currentZ = actorPosition(actor)
    if currentX == nil then
        currentX, currentY, currentZ = state.x, state.y, state.z
        snap = true
    end

    local dx = state.x - currentX
    local dy = state.y - currentY
    local distance = math.sqrt(dx * dx + dy * dy)
    if math.abs(state.z - currentZ) > MOTION_FLOOR_EPSILON
        or distance > MOTION_SNAP_DISTANCE then
        snap = true
    end

    local motion = {
        fromX = currentX,
        fromY = currentY,
        fromZ = currentZ,
        targetX = state.x,
        targetY = state.y,
        targetZ = state.z,
        startedAt = now,
        durationMs = motionDurationMs(distance, state),
        done = false
    }
    if snap then
        setRenderedPosition(actor, state.x, state.y, state.z,
            state.x, state.y, state.z)
        motion.fromX, motion.fromY, motion.fromZ = state.x, state.y, state.z
        motion.done = true
    end
    Client.motion[id] = motion
end

local function advanceMotion(id, actor, now)
    local motion = Client.motion[id]
    if motion == nil or motion.done then return false end

    local currentX, currentY, currentZ = actorPosition(actor)
    if currentX == nil then return false end
    local elapsed = math.max(0, now - motion.startedAt)
    local duration = math.max(1, motion.durationMs or MOTION_DURATION_MS)
    local progress = math.min(1.0, elapsed / duration)
    -- Linear interpolation keeps the survivor's ground speed stable.  The
    -- next packet rebases from the currently rendered point, so there is no
    -- visible snap when the authoritative route changes direction.
    local x = motion.fromX + (motion.targetX - motion.fromX) * progress
    local y = motion.fromY + (motion.targetY - motion.fromY) * progress
    local z = motion.fromZ + (motion.targetZ - motion.fromZ) * progress
    setRenderedPosition(actor, x, y, z, currentX, currentY, currentZ)
    if progress >= 1.0 then
        setRenderedPosition(actor, motion.targetX, motion.targetY, motion.targetZ,
            x, y, z)
        motion.done = true
    end
    return true
end

local function descriptor()
    local factory = rawget(_G, "SurvivorFactory")
    if factory ~= nil and type(factory.CreateSurvivor) == "function" then
        local ok, value = pcall(factory.CreateSurvivor)
        if ok and value ~= nil then return value end
    end
    if type(getPlayer) == "function" then
        local okPlayer, player = pcall(getPlayer)
        if okPlayer and player ~= nil and type(player.getDescriptor) == "function" then
            local okDescriptor, value = pcall(player.getDescriptor, player)
            if okDescriptor and value ~= nil then return value end
        end
    end
    return nil
end

local function applyHumanVisual(actor, state)
    local profile = state.profile or {}
    if type(profile.sex) == "string" then
        call(actor, "setFemale", string.lower(profile.sex) == "female")
    end
    local human = nil
    local okHuman, value = call(actor, "getHumanVisual")
    if okHuman then human = value end
    if human == nil then
        local okDescriptor, desc = call(actor, "getDescriptor")
        if okDescriptor and desc ~= nil then
            local okVisual, visual = call(desc, "getHumanVisual")
            if okVisual then human = visual end
        end
    end
    if human == nil then return false end
    call(human, "removeDirt")
    call(human, "removeBlood")
    local colorFactory = rawget(_G, "ImmutableColor")
    if colorFactory ~= nil and type(colorFactory.new) == "function"
        and type(profile.hairColor) == "table" then
        local okColor, hairColor = pcall(colorFactory.new,
            tonumber(profile.hairColor.r) or 0.18,
            tonumber(profile.hairColor.g) or 0.12,
            tonumber(profile.hairColor.b) or 0.08)
        if okColor and hairColor ~= nil then
            call(human, "setHairColor", hairColor)
            call(human, "setBeardColor", hairColor)
        end
    end
    if type(profile.hair) == "string" and profile.hair ~= "" then
        call(human, "setHairModel", profile.hair)
    end
    if type(profile.beard) == "string" then
        call(human, "setBeardModel", profile.beard == "none" and nil or profile.beard)
    end
    return true
end

local function modelManager()
    local managerClass = rawget(_G, "ModelManager")
    if managerClass == nil then return nil end
    local ok, manager = pcall(function() return managerClass.instance end)
    return ok and manager or nil
end

local function registerInWorld(actor, worldCell, square)
    -- IsoSurvivor is a legacy single-player class in B42. Keep it out of the
    -- cell update collections (its old update path expects BodyDamage), but
    -- use the moving-square API so the renderer sees it through the same list
    -- and bookkeeping used by normal characters.
    if square ~= nil then
        local attached = call(actor, "setMovingSquare", square)
        if not attached then
            local okMoving, movingObjects = call(square, "getMovingObjects")
            if okMoving then listAddOnce(movingObjects, actor) end
        end
    end
    call(actor, "setCurrentSquare", square)
    -- The B42 FBO renderer traverses IsoCell.objectList, not just movingSquares.
    -- HumanSurvivor overrides all three vanilla simulation update phases.
    call(actor, "registerVisualObject")

    -- IsoGameCharacter construction does not automatically create a model
    -- slot for an actor that is kept out of IsoCell's update loop. Register it
    -- explicitly so IsoSprite.hasActiveModel() and renderActiveModel() have a
    -- real human ModelInstance to draw.
    local manager = modelManager()
    if manager ~= nil then
        local okAdd = call(manager, "Add", actor)
        if not okAdd then
            log("ModelManager.Add failed for client-side actor")
        end
    else
        -- Kahlua cannot reliably read ModelManager.instance on this B42
        -- build. Let the Java actor call the same singleton directly, then
        -- retain the uncull fallback for a runtime with a missing manager.
        local okJavaModel, javaModelReady = call(actor, "ensureVisualModel")
        if not okJavaModel or javaModelReady ~= true then
            local okUncull = call(actor, "setSceneCulled", false)
            if not okUncull then log("setSceneCulled failed for client-side actor") end
        end
    end
end

local function squareCoordinates(square)
    if square == nil then return "nil" end
    local okX, x = call(square, "getX")
    local okY, y = call(square, "getY")
    local okZ, z = call(square, "getZ")
    if not okX or not okY or not okZ then return tostring(square) end
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function actorDiagnostics(actor)
    local okVisual, visual = call(actor, "visualDiagnostics")
    local okWeapon, weapon = call(actor, "getFirearmType")
    local okWeaponReady, weaponReady = call(actor, "hasReadyFirearm")
    local okGodMode, godMode = call(actor, "isGodMode")
    local okSprite, sprite = call(actor, "getSprite")
    local okLegs, legs = call(actor, "getLegsSprite")
    local okActive, active = false, false
    if legs ~= nil then okActive, active = call(legs, "hasActiveModel") end
    local okModel, model = call(actor, "getModelInstance")
    local okRender, doRender = call(actor, "getDoRender")
    local okInvisible, invisible = call(actor, "isSpriteInvisible")
    local okAlphaZero, alphaZero = call(actor, "isAlphaZero")
    local okCurrent, current = call(actor, "getCurrentSquare")
    local okMovingSquare, movingSquare = call(actor, "getMovingSquare")
    local inMovingList = false
    if current ~= nil then
        local okObjects, objects = call(current, "getMovingObjects")
        if okObjects and objects ~= nil and type(objects.contains) == "function" then
            local okContains, contains = pcall(objects.contains, objects, actor)
            inMovingList = okContains and contains == true
        end
    end
    local manager = modelManager()
    local okManaged, managed = false, false
    if manager ~= nil then okManaged, managed = call(manager, "ContainsChar", actor) end
    if not okManaged then okManaged, managed = call(actor, "visualModelManaged") end
    return "sprite=" .. tostring(okSprite and sprite ~= nil)
        .. " legs=" .. tostring(okLegs and legs ~= nil)
        .. " activeModel=" .. (okActive and tostring(active) or "unavailable")
        .. " model=" .. tostring(okModel and model ~= nil)
        .. " doRender=" .. (okRender and tostring(doRender) or "unavailable")
        .. " invisible=" .. (okInvisible and tostring(invisible) or "unavailable")
        .. " alphaZero=" .. (okAlphaZero and tostring(alphaZero) or "unavailable")
        .. " current=" .. squareCoordinates(okCurrent and current or nil)
        .. " moving=" .. squareCoordinates(okMovingSquare and movingSquare or nil)
        .. " inMovingList=" .. tostring(inMovingList)
        .. " modelManager=" .. (okManaged and tostring(managed) or "unavailable")
        .. " firearm=" .. (okWeapon and tostring(weapon) or "unavailable")
        .. " weaponReady=" .. (okWeaponReady and tostring(weaponReady) or "unavailable")
        .. " godMode=" .. (okGodMode and tostring(godMode) or "unavailable")
        .. " javaVisual=" .. (okVisual and tostring(visual) or "unavailable")
end

local function detachFromUpdateCollections(actor, worldCell)
    if worldCell == nil then return end
    -- IsoGameCharacter's constructor adds non-zero-position instances to the
    -- cell object list even though IsoSurvivor itself has no BodyDamage. Remove
    -- that automatic registration before the next client update tick.
    local okObjects, objectList = call(worldCell, "getObjectList")
    if okObjects then listRemove(objectList, actor) end
    local okAdds, addList = call(worldCell, "getAddList")
    if okAdds then listRemove(addList, actor) end
end

local function displayVanillaChat(author, text)
    if type(author) ~= "string" or author == ""
        or type(text) ~= "string" or text == "" then return false end
    -- ChatManager is client-side in B42.  Storm performs the Java call so
    -- Kahlua never has to dispatch methods on the unexposed Java instance.
    local display = rawget(_G, "displayGoblinChatMessage")
    if type(display) ~= "function" then return false end
    local ok, shown = pcall(display, author, text)
    return ok and shown == true
end

local function displaySpeech(actor, text, author, chatAlreadyDisplayed)
    local overhead = false
    if actor ~= nil then
        overhead = call(actor, "addLineChatElement", text, 0.1, 0.8, 0.1)
        if not overhead then
            overhead = call(actor, "Say", text)
        end
    end
    local chat = chatAlreadyDisplayed == true
        or displayVanillaChat(author or "Goblin", text)
    return overhead or chat
end

local function applyRequestedOutfit(actor, state)
    local profile = state.profile or {}
    local outfit = profile.outfit
    if type(outfit) ~= "table" then return true end
    local ok, worn = call(actor, "applyOutfit",
        outfit.top, outfit.outer, outfit.pants,
        outfit.shoes, outfit.head, outfit.back)
    if not ok then
        log("could not apply randomized outfit for client-side actor '"
            .. tostring(state.actor_id) .. "'")
        return false
    end
    if type(worn) == "number" and worn < 3 then
        log("randomized outfit for '" .. tostring(state.actor_id)
            .. "' only equipped " .. tostring(worn) .. " item(s)")
    end
    return true
end

local function equipRequestedFirearm(actor, state)
    local profile = state.profile or {}
    if type(profile.weapon) ~= "string" or profile.weapon == "" then
        -- The server's current roster contract gives every managed human a
        -- rifle. Keep the client adapter compatible with an older snapshot
        -- by using the same bounded default rather than creating an unarmed
        -- visual actor.
        profile.weapon = "Base.AssaultRifle2"
    end
    local ok, ready = call(actor, "ensureFirearm")
    if not ok or ready ~= true then
        log("could not equip requested firearm for client-side actor '"
            .. tostring(state.actor_id) .. "'")
        return false
    end
    return true
end

local function equipRequestedWeapon(actor, state)
    if string.upper(tostring(state.combat_mode or "HUNT")) == "MELEE" then
        local ok, ready = call(actor, "ensureMeleeWeapon")
        if not ok or ready ~= true then
            log("could not equip melee weapon for client-side actor '"
                .. tostring(state.actor_id) .. "'")
            return false
        end
        return true
    end
    return equipRequestedFirearm(actor, state)
end

local function applyCombatPose(actor, state)
    local melee = string.upper(tostring(state.combat_mode or "HUNT")) == "MELEE"
    local attacking = melee and (
        state.combat_status == "melee_attack"
        or state.combat_status == "melee_kill"
        or state.combat_status == "melee_attempt_failed")
    -- HumanSurvivor owns the animation-variable boundary.  Lua only mirrors
    -- the server's bounded combat status and never chooses a target or hit.
    call(actor, "setMeleeAttackPose", attacking)
    if not attacking then
        local firearmFiring = state.combat_status == "firearm_attack"
            or state.combat_status == "firearm_kill"
            or state.combat_status == "firearm_attempt_failed"
        local firearmAiming = state.combat_status == "aiming"
            or firearmFiring
        local posed = call(actor, "setFirearmPose", firearmAiming, firearmFiring)
        if not posed then
            -- Compatibility fallback for a stale loaded jar; the rebuilt jar
            -- above is the authoritative path and enters B42's ranged state.
            call(actor, "setVariable", "isAiming", firearmAiming)
            call(actor, "setVariable", "isAttacking", firearmFiring)
        end
    end
end

local function currentWorldMap()
    local map = rawget(_G, "ISWorldMap_instance")
    if map == nil then
        local mapClass = rawget(_G, "ISWorldMap")
        if mapClass ~= nil then map = mapClass.instance end
    end
    if map == nil or map.mapAPI == nil then return nil end
    local okVisible, visible = call(map, "isVisible")
    if not okVisible or visible ~= true then return nil end
    return map
end

local function removeMapMarker(id)
    -- Player markers are drawn directly during the map UI pass below, so
    -- there is no persistent WorldMapSymbol object to remove.  Clearing the
    -- bookkeeping entry is enough; the square disappears on the next frame.
    Client.mapMarkers[id] = nil
end

local function clearMapMarkers()
    Client.mapMarkers = {}
end

local function mapMarkerColor(id, state)
    if id == "goblin.primary" then return 0.20, 1.00, 0.25 end
    local colors = {
        medic = { 0.35, 0.85, 1.00 },
        guard = { 1.00, 0.35, 0.30 },
        hauler = { 1.00, 0.72, 0.20 },
        farmer = { 0.45, 1.00, 0.35 },
        builder = { 1.00, 0.55, 0.20 },
        scout = { 0.80, 0.45, 1.00 }
    }
    local color = colors[string.lower(tostring(state and state.role or ""))]
        or { 0.95, 0.95, 0.95 }
    return color[1], color[2], color[3]
end

local function updateMapMarkers(force)
    local map = currentWorldMap()
    if map == nil then
        clearMapMarkers()
        return false
    end

    local mapApi = map.mapAPI
    local mapSurface = map.javaObject
    if mapApi == nil or mapSurface == nil then
        if not Client.mapFailureLogged then
            Client.mapFailureLogged = true
            log("world-map draw surface is unavailable; survivor markers deferred")
        end
        return false
    end

    -- UIWorldMap:renderPlayer() draws the vanilla player marker as a 6x6
    -- white square tinted by DrawTextureScaledColor with a nil texture.  Use
    -- that same draw path so survivor markers look like players instead of
    -- lootable-map gun symbols.  This must run during OnPostUIDraw because
    -- DrawTextureScaledColor is an immediate UI draw, not a retained marker.
    local squareSize = 6
    local halfSquare = squareSize / 2

    local live = {}
    for id, actor in pairs(Client.actors) do
        local state = Client.states[id]
        local alive = state == nil or (state.alive ~= false and state.body_present ~= false)
        if alive then
            local okX, x = call(actor, "getX")
            local okY, y = call(actor, "getY")
            if okX and okY and type(x) == "number" and type(y) == "number" then
                local okUiX, uiX = call(mapApi, "worldToUIX", x, y)
                local okUiY, uiY = call(mapApi, "worldToUIY", x, y)
                if okUiX and okUiY and type(uiX) == "number" and type(uiY) == "number"
                    and uiX == uiX and uiY == uiY
                    and uiX ~= math.huge and uiX ~= -math.huge
                    and uiY ~= math.huge and uiY ~= -math.huge then
                    local r, g, b = mapMarkerColor(id, state)
                    local okDraw = call(mapSurface, "DrawTextureScaledColor", nil,
                        math.floor(uiX - halfSquare), math.floor(uiY - halfSquare),
                        squareSize, squareSize, r, g, b, 1.0)
                    if okDraw then
                        Client.mapMarkers[id] = true
                    elseif not Client.mapFailureLogged then
                        Client.mapFailureLogged = true
                        log("could not draw player-style survivor map square")
                    end
                    live[id] = true
                end
            end
        end
    end
    for id, _ in pairs(Client.mapMarkers) do
        if not live[id] then removeMapMarker(id) end
    end
    return true
end

local function finiteScreenNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function nameLabelText(state)
    if state == nil or type(state.display_name) ~= "string"
        or state.display_name == "" then
        return nil
    end
    -- Snapshot validation already bounds this field. Strip line breaks here
    -- as a second guard because a name label must stay a single UI line.
    local text = string.gsub(state.display_name, "[\r\n\t]", " ")
    if #text > Protocol.maxDisplayName then
        text = string.sub(text, 1, Protocol.maxDisplayName)
    end
    return text ~= "" and text or nil
end

local function projectNameLabel(actor, textManager)
    if type(isoToScreenX) ~= "function" or type(isoToScreenY) ~= "function" then
        return nil
    end
    local x, y, z = actorPosition(actor)
    if x == nil then return nil end

    -- isoToScreen* follows the same player-index convention used by the
    -- vanilla world UI. Subtracting the split-screen viewport origin keeps
    -- this correct if a local test later uses more than one player view.
    local playerIndex = 0
    local okX, screenX = pcall(isoToScreenX, playerIndex, x, y, z)
    local okY, groundY = pcall(isoToScreenY, playerIndex, x, y, z)
    if not okX or not okY
        or not finiteScreenNumber(screenX)
        or not finiteScreenNumber(groundY) then
        return nil
    end

    local screenLeft, screenTop = 0, 0
    if type(getPlayerScreenLeft) == "function" then
        local ok, value = pcall(getPlayerScreenLeft, playerIndex)
        if ok and finiteScreenNumber(value) then screenLeft = value end
    end
    if type(getPlayerScreenTop) == "function" then
        local ok, value = pcall(getPlayerScreenTop, playerIndex)
        if ok and finiteScreenNumber(value) then screenTop = value end
    end

    local zoom = 1.0
    if type(getCore) == "function" then
        local okCore, core = pcall(getCore)
        if okCore and core ~= nil then
            local okZoom, value = call(core, "getZoom", playerIndex)
            if okZoom and finiteScreenNumber(value) and value > 0.05 then
                zoom = value
            end
        end
    end

    local fontHeight = 16
    if textManager ~= nil and UIFont ~= nil and UIFont.Small ~= nil then
        local okHeight, value = call(textManager, "getFontHeight", UIFont.Small)
        if okHeight and finiteScreenNumber(value) and value > 0 then
            fontHeight = value
        end
    end

    -- Anchor to the actor's ground point and lift by a zoom-aware amount so
    -- the text remains above the head at every camera zoom. The extra font
    -- height prevents the baseline from touching the model's hair.
    local headOffset = math.max(80, 140 / zoom) + fontHeight
    return screenX - screenLeft, groundY - screenTop - headOffset
end

local function drawSurvivorNameLabels()
    if type(getTextManager) ~= "function" or UIFont == nil
        or UIFont.Small == nil then
        if not Client.nameLabelFailureLogged then
            Client.nameLabelFailureLogged = true
            log("survivor name labels deferred: text manager is unavailable")
        end
        return false
    end

    local okManager, textManager = pcall(getTextManager)
    if not okManager or textManager == nil then
        if not Client.nameLabelFailureLogged then
            Client.nameLabelFailureLogged = true
            log("survivor name labels deferred: text manager lookup failed")
        end
        return false
    end

    local screenWidth, screenHeight = nil, nil
    if type(getCore) == "function" then
        local okCore, core = pcall(getCore)
        if okCore and core ~= nil then
            local okWidth, width = call(core, "getScreenWidth")
            local okHeight, height = call(core, "getScreenHeight")
            if okWidth and finiteScreenNumber(width) then screenWidth = width end
            if okHeight and finiteScreenNumber(height) then screenHeight = height end
        end
    end

    local drawn = 0
    local actorCount = 0
    for id, actor in pairs(Client.actors) do
        actorCount = actorCount + 1
        local state = Client.states[id]
        local alive = state ~= nil
            and state.alive ~= false
            and state.body_present ~= false
        local text = alive and nameLabelText(state) or nil
        if text ~= nil then
            local screenX, screenY = projectNameLabel(actor, textManager)
            if screenX ~= nil and screenY ~= nil then
                local onScreen = true
                local edge = 48
                if screenWidth ~= nil and (screenX < -edge or screenX > screenWidth + edge) then
                    onScreen = false
                end
                if screenHeight ~= nil and (screenY < -edge or screenY > screenHeight + edge) then
                    onScreen = false
                end
                if onScreen then
                    local red, green, blue = mapMarkerColor(id, state)
                    -- A small black drop shadow keeps the label readable over
                    -- grass, roofs, and the survivor's own hair.
                    call(textManager, "DrawStringCentre", UIFont.Small,
                        screenX + 1, screenY + 1, text, 0, 0, 0, 0.9)
                    call(textManager, "DrawStringCentre", UIFont.Small,
                        screenX, screenY, text, red, green, blue, 1.0)
                    drawn = drawn + 1
                end
            end
        end
    end

    local now = Protocol.nowMs()
    if now >= Client.nextNameLabelDiagnosticsAt then
        Client.nextNameLabelDiagnosticsAt = now + 5000
        log("survivor name labels: drawn=" .. tostring(drawn)
            .. " actors=" .. tostring(actorCount))
    end
    return true
end

local function runtimeClassName(actor)
    local okClass, runtimeClass = call(actor, "getClass")
    if not okClass or runtimeClass == nil then return nil end
    -- Kahlua represents java.lang.Class as a special value whose getName
    -- lookup raises even inside pcall. Its string form still contains the
    -- fully-qualified runtime class and is safe to use for diagnostics.
    return tostring(runtimeClass)
end

local function removeActor(id)
    local actor = Client.actors[id]
    Client.motion[id] = nil
    if actor == nil then return false end
    local manager = modelManager()
    if manager ~= nil then call(manager, "Remove", actor) end
    -- The custom Java body is registered in IsoCell.objectList explicitly for
    -- rendering. removeFromWorld() does not reliably remove that manual
    -- visual registration, so use the symmetric lifecycle hook before the
    -- actor is forgotten or recreated for a new generation.
    call(actor, "unregisterVisualObject")
    local okSquare, square = call(actor, "getCurrentSquare")
    if okSquare and square ~= nil then
        local okMoving, movingObjects = call(square, "getMovingObjects")
        if okMoving then listRemove(movingObjects, actor) end
    end
    call(actor, "removeFromSquare")
    call(actor, "removeFromWorld")
    Client.actors[id] = nil
    return true
end

local function createActor(state)
    local class = { new = rawget(_G, "createGoblinHumanSurvivor") }
    local desc = descriptor()
    local worldCell = cell()
    if class == nil or type(class.new) ~= "function" then
        return nil, "HumanSurvivor.new is unavailable; launch the client with GoblinSurvivor Storm loaded"
    end
    if desc == nil then return nil, "SurvivorFactory descriptor is unavailable" end
    if worldCell == nil then return nil, "client world cell is unavailable" end

    local ok, actor = pcall(class.new, desc, worldCell,
        math.floor(state.x), math.floor(state.y), math.floor(state.z))
    if not ok or actor == nil then
        return nil, "HumanSurvivor.new failed: " .. tostring(actor)
    end

    detachFromUpdateCollections(actor, worldCell)

    local square = squareFor(worldCell, state.x, state.y, state.z)
    call(actor, "setAlphaAndTarget", 1.0)
    call(actor, "setDoRender", true)
    call(actor, "setInvisible", false)
    call(actor, "setVisibleToNPCs", true)
    call(actor, "setDisplayName", state.display_name)
    call(actor, "setName", state.display_name)
    call(actor, "setDir", rawget(_G, "IsoDirections")
        and rawget(_G, "IsoDirections").S or nil)
    local okData, data = call(actor, "getModData")
    if okData and type(data) == "table" then
        data.goblin_client_survivor = true
        data.goblin_actor_id = state.actor_id
        data.goblin_entity_class = Protocol.entityClass
    end
    applyHumanVisual(actor, state)
    applyRequestedOutfit(actor, state)
    if state.actor_id == "goblin.primary" then call(actor, "forceGoblinAppearance") end
    if state.god_mode ~= false then call(actor, "ensureGodMode") end
    equipRequestedWeapon(actor, state)
    applyCombatPose(actor, state)
    registerInWorld(actor, worldCell, square)
    log("client-side actor '" .. tostring(state.actor_id) .. "' render state: "
        .. actorDiagnostics(actor))
    local pending = Client.pendingSpeech[state.actor_id]
    if pending ~= nil then
        Client.pendingSpeech[state.actor_id] = nil
        displaySpeech(actor, pending.text, pending.author, pending.chat_displayed)
    end
    return actor
end

local function applyState(state)
    local id = state.actor_id
    local previousSequence = Client.lastSequence[id] or 0
    if state.sequence <= previousSequence then return true end
    local pending = Client.states[id]
    if pending ~= nil and state.sequence < pending.sequence then return true end
    Client.states[id] = state
    Client.lastState = state

    local actor = Client.actors[id]
    local created = false
    if state.alive == false or state.body_present == false then
        Client.lastSequence[id] = state.sequence
        Client.nextCreateAt[id] = nil
        if actor ~= nil then
            removeActor(id)
            log("removed absent client-side actor '" .. tostring(id) .. "'"
                .. " generation=" .. tostring(state.body_generation or 0))
        end
        Client.states[id] = nil
        removeMapMarker(id)
        Client.generations[id] = state.body_generation or Client.generations[id] or 0
        return true
    end
    local generation = state.body_generation or 0
    if actor ~= nil and Client.generations[id] ~= nil
        and generation > 0 and Client.generations[id] ~= generation then
        removeActor(id)
        actor = nil
        log("recreating client-side actor '" .. tostring(id)
            .. "' for body generation " .. tostring(generation))
    end
    if actor == nil then
        local now = Protocol.nowMs()
        if now < (Client.nextCreateAt[id] or 0) then return false end
        Client.nextCreateAt[id] = now + 1000
        local createdActor, detail = createActor(state)
        if createdActor == nil then
            log("could not create " .. Protocol.entityClass .. ": " .. tostring(detail))
            return false
        end
        Client.actors[id] = createdActor
        Client.nextCreateAt[id] = nil
        actor = createdActor
        created = true
        local okZombie, isZombie = call(actor, "isZombie")
        log("created Java human survivor actor '" .. tostring(id)
            .. "' java_class=" .. tostring(runtimeClassName(actor))
            .. " isZombie=" .. (okZombie and tostring(isZombie) or "unavailable"))
    end

    Client.lastSequence[id] = state.sequence
    Client.generations[id] = generation
    equipRequestedWeapon(actor, state)
    if state.god_mode ~= false then call(actor, "ensureGodMode") end

    call(actor, "setAlphaAndTarget", 1.0)
    call(actor, "setDoRender", true)
    call(actor, "setInvisible", false)
    setMotionTarget(id, actor, state, created)
    local moving = navigationIsMoving(state)
    call(actor, "setMovementMode", moving, state.running == true)
    call(actor, "setTraversalPose", state.navigation_status == "jumping",
        state.running == true)
    applyCombatPose(actor, state)
    local now = Protocol.nowMs()
    if now >= Client.lastDiagnosticsAt then
        Client.lastDiagnosticsAt = now + 5000
        log("client-side actor '" .. tostring(id) .. "' render state: "
            .. actorDiagnostics(actor))
    end
    return true
end

local function requestSnapshot()
    if type(sendClientCommand) ~= "function" then return false end
    local ok = pcall(sendClientCommand, Protocol.module,
        Protocol.requestCommand, { protocol = Protocol.version })
    return ok
end

local function showSpeech(value)
    local previous = Client.lastSpeechSequence[value.actor_id] or 0
    if value.speech_sequence <= previous then return false end
    Client.lastSpeechSequence[value.actor_id] = value.speech_sequence
    local actor = Client.actors[value.actor_id]
    if actor == nil then
        local chatDisplayed = displayVanillaChat(value.author or "Goblin", value.text)
        value.chat_displayed = chatDisplayed == true
        Client.pendingSpeech[value.actor_id] = value
        return chatDisplayed
    end
    local ok = displaySpeech(actor, value.text, value.author)
    if ok then
        log("displayed speech for client-side actor '" .. tostring(value.actor_id) .. "'")
    else
        log("could not display speech for client-side actor '" .. tostring(value.actor_id) .. "'")
    end
    return ok
end

local function onServerCommand(module, command, args)
    if module ~= Protocol.module then return end
    if command == Protocol.speechCommand then
        if not Protocol.validSpeech(args) then
            log("rejected malformed client-survivor speech packet")
            return
        end
        showSpeech(args)
        return
    end
    if command ~= Protocol.stateCommand then return end
    if not Protocol.validSnapshot(args) then
        log("rejected malformed client-survivor state packet")
        return
    end
    applyState(args)
end

if Events and Events.OnServerCommand
    and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(onServerCommand)
end

if Events and Events.OnGameStart
    and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(function()
        for id, _ in pairs(Client.actors) do removeActor(id) end
        Client.actors = {}
        Client.motion = {}
        Client.nextCreateAt = {}
        Client.lastSequence = {}
        Client.generations = {}
        Client.lastSpeechSequence = {}
        Client.pendingSpeech = {}
        Client.states = {}
        clearMapMarkers()
        Client.mapFailureLogged = false
        Client.lastState = nil
        Client.nextRequestAt = 0
        Client.nextZombieDiagnosticsAt = 0
        Client.nextNameLabelDiagnosticsAt = 0
        Client.nameLabelFailureLogged = false
        requestSnapshot()
    end)
end

if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(function()
        local now = Protocol.nowMs()
        if now >= Client.nextRequestAt then
            if requestSnapshot() then
                Client.nextRequestAt = now + Client.requestIntervalMs
            else
                Client.nextRequestAt = now + 1000
            end
        end
        -- Retry every pending roster member after transient creation failures.
        -- Successfully applied sequences are ignored by applyState.
        for _, state in pairs(Client.states) do applyState(state) end
        localZombieDiagnostics(now)
        for id, actor in pairs(Client.actors) do
            -- Render motion is intentionally client-side.  The server remains
            -- authoritative for the target point, while this short bridge
            -- makes the body travel there at frame cadence instead of snapping
            -- at the network snapshot cadence.
            advanceMotion(id, actor, now)
            call(actor, "ensureVisualRegistration")
            local ok, detail = call(actor, "tickVisual")
            if not ok and not Client.visualFailureLogged then
                Client.visualFailureLogged = true
                log("visual tick failed for " .. tostring(id) .. ": " .. tostring(detail))
            end
        end
    end)
end

if Events and Events.OnPostUIDraw and type(Events.OnPostUIDraw.Add) == "function" then
    -- The world map can pause the simulation.  More importantly, the
    -- player-style square is an immediate draw, so it must be issued during
    -- the UI pass every frame rather than from the simulation tick.
    Events.OnPostUIDraw.Add(function()
        updateMapMarkers()
        drawSurvivorNameLabels()
    end)
end

Client.started = true
return Client

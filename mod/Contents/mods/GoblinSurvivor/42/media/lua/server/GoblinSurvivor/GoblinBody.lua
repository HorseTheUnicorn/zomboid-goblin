-- The only module that touches the physical Goblin IsoZombie.
--
-- This is deliberately small.  It owns the body invariants and the stable
-- identity; task selection and path updates live in GoblinBrain.lua and
-- GoblinMovement.lua.  No third-party NPC API, IsoSurvivor, teleport loop, or native
-- climb state is used here.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")

local Body = {}

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, first, second = pcall(member, object, ...)
    return ok, first, second
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function dataFor(body)
    local ok, data = call(body, "getModData")
    if ok and data ~= nil then return data end
    return nil
end

local function transmit(body)
    -- IsoZombie is a moving object, not a square-owned IsoObject. Calling
    -- IsoObject:transmitModData() on it sends an ObjectModData packet with an
    -- invalid square/object index. Companion state is persisted/transmitted
    -- through the GoblinCompanion GlobalModData envelope instead.
end

local function setVariable(body, name, value)
    call(body, "setVariable", name, value)
end

local function setIfAvailable(body, method, value)
    call(body, method, value)
end

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] " .. tostring(message))
    end
end

local function clippedString(value, maximum)
    if type(value) ~= "string" then return "unknown" end
    value = string.gsub(value, "[%c]", " ")
    return string.sub(value, 1, maximum or 96)
end

local function findInventoryItem(inventory, fullType)
    if inventory == nil or type(fullType) ~= "string" then return nil end
    local okItems, items = call(inventory, "getItems")
    if not okItems or items == nil then return nil end
    local count = type(items.size) == "function" and items:size() or #items
    for index = 0, count - 1 do
        local item = type(items.get) == "function" and items:get(index) or items[index + 1]
        if item ~= nil then
            local okType, itemType = call(item, "getFullType")
            if okType and itemType == fullType then return item end
        end
    end
    return nil
end

local function configuredOutfitFingerprint()
    local items = Config.npcOutfitItems
    if type(items) ~= "table" then return "" end
    local values = {}
    for index = 1, #items do
        values[index] = tostring(items[index])
    end
    return table.concat(values, ",")
end

local function resolveWornItem(inventory, fullType)
    if inventory == nil or type(fullType) ~= "string" then
        return nil, tostring(fullType) .. ":inventory-unavailable"
    end
    local item = findInventoryItem(inventory, fullType)
    if item == nil then
        local okAdd, added = call(inventory, "AddItem", fullType)
        if okAdd then item = added end
    end
    if item == nil and type(instanceItem) == "function" then
        local okInstance, instance = pcall(instanceItem, fullType)
        if okInstance then item = instance end
    end
    if item == nil then
        return nil, tostring(fullType) .. ":not-registered"
    end
    local okLocation, location = call(item, "getBodyLocation")
    if not okLocation or location == nil then
        return nil, tostring(fullType) .. ":no-body-location"
    end
    return { fullType = fullType, item = item, location = location }
end

local function applyConfiguredOutfit(body, inventory)
    local requested = Config.npcOutfitItems
    if type(requested) ~= "table" or #requested == 0 then
        return 0, 0, "no configured clothing items", false
    end

    -- Resolve the packaged full-body mesh and every requested item before
    -- clearing the named outfit.  The mesh is inserted first so the native
    -- clothing renderer has a real fullsuit visual to bind; the explicit
    -- shirt/hat/shoes/trousers then remain the visible accessory layers.
    local resolved = {}
    local missing = {}
    local visualType = Config.npcVisualItemType
    if type(visualType) == "string" and visualType ~= "" then
        local visualEntry, visualError = resolveWornItem(inventory, visualType)
        if visualEntry ~= nil then
            visualEntry.isMesh = true
            resolved[#resolved + 1] = visualEntry
        else
            missing[#missing + 1] = visualError
        end
    end
    for index = 1, #requested do
        local fullType = requested[index]
        local entry, itemError = resolveWornItem(inventory, fullType)
        if entry ~= nil then
            resolved[#resolved + 1] = entry
        else
            missing[#missing + 1] = itemError
        end
    end

    if #resolved == 0 then
        return 0, #requested, table.concat(missing, ","), false
    end

    local okWornItems, wornItems = call(body, "getWornItems")
    if okWornItems and wornItems ~= nil then call(wornItems, "clear") end

    local applied = 0
    local meshApplied = false
    for index = 1, #resolved do
        local entry = resolved[index]
        local okWorn, wornResult = call(body, "setWornItem", entry.location, entry.item)
        if okWorn and (wornResult == nil or wornResult == true) then
            if entry.isMesh then
                meshApplied = true
            else
                applied = applied + 1
            end
        else
            missing[#missing + 1] = tostring(entry.fullType) .. ":set-worn-failed"
        end
    end
    return applied, #requested, table.concat(missing, ","), meshApplied
end

function Body.data(body)
    return dataFor(body)
end

function Body.position(body)
    local okX, x = call(body, "getX")
    local okY, y = call(body, "getY")
    local okZ, z = call(body, "getZ")
    if not okX or not okY or not okZ
        or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

function Body.exists(body)
    if body == nil then return false end
    local okDead, dead = call(body, "isDead")
    if okDead and dead == true then return false end
    if Body.position(body) == nil then return false end

    -- A native factory returns the IsoZombie before it has been inserted into
    -- its moving square.  Keep a freshly marked body alive during that short
    -- hand-off; otherwise the first invariant tick sees nil squares and the
    -- spawner retires the perfectly valid companion before the engine can
    -- register it for replication.
    local data = dataFor(body)
    local spawnedAt = data ~= nil and tonumber(data.GoblinSpawnedAt) or nil
    local spawnGrace = spawnedAt ~= nil and (nowMs() - spawnedAt) <= 5000

    -- Native zombies live in IsoCell.zombieList and the square's
    -- movingObjects list. Their IsoObject.square membership is populated by
    -- the engine update path, so isExistInTheWorld() may be false while the
    -- current/moving squares are valid.
    local okCurrent, current = call(body, "getCurrentSquare")
    local okMoving, moving = call(body, "getMovingSquare")
    if okCurrent or okMoving then
        if (okCurrent and current ~= nil) or (okMoving and moving ~= nil) then
            return true
        end
        if spawnGrace then return true end
        local okExists, exists = call(body, "isExistInTheWorld")
        if okExists then return exists == true end
        return false
    end
    local okExists, exists = call(body, "isExistInTheWorld")
    if okExists then return exists == true end
    return true
end

function Body.isGoblin(body, npcId)
    local data = dataFor(body)
    local requested = npcId or Config.npcId
    return data ~= nil
        and data.GoblinNPC == true
        and data.GoblinID == requested
        and data.goblin_owned == true
end

local function clearZombieTargets(body)
    -- These calls are capability-gated because the server and client expose
    -- slightly different IsoZombie surfaces across B42 point releases.
    call(body, "setTarget", nil)
    call(body, "setThumpTarget", nil)
    call(body, "setAttackTargetSquare", nil)
    call(body, "setEatBodyTarget", nil, false)
    call(body, "clearAggroList")
end

-- Keep the hostile IsoZombie fields empty even on ticks where the brain has
-- no work to do.  The engine's population update may repopulate these fields
-- after an invariant pass, so the Goblin update path clears them again.
function Body.clearNativeTargets(body)
    if body == nil then return false end
    clearZombieTargets(body)
    return true
end

local function applyHumanVisual(body, data)
    -- A Survivor outfit gives the IsoZombie a human mesh/gear on runtimes that
    -- expose the named-outfit method.  The call is one-shot (spawn/restore or
    -- an explicit appearance change), never a per-tick animation override.
    local before = tostring(data.GoblinVisualFingerprint or "")
    local fingerprint = tostring(Config.npcOutfit) .. "|" .. tostring(Config.npcOutfitId)
        .. "|" .. tostring(Config.npcVisualAsset) .. "|items="
        .. configuredOutfitFingerprint()
    -- Keep retrying until the real clothing item has been worn.  A server can
    -- invoke the spawn callback before item scripts/textures finish loading;
    -- caching a failed fingerprint would otherwise leave the companion on the
    -- fallback Survivor shell for the rest of the session.
    local hasOutfitItems = type(Config.npcOutfitItems) == "table" and #Config.npcOutfitItems > 0
    local outfitSatisfied = not hasOutfitItems or data.GoblinOutfitApplied == true
    local meshSatisfied = type(Config.npcVisualItemType) ~= "string"
        or Config.npcVisualItemType == "" or data.GoblinMeshApplied == true
    if before == fingerprint and data.GoblinVisualDirty ~= true
        and outfitSatisfied and meshSatisfied then return end

    -- Build 42's survivor shell is an IsoZombie flag, not a client-side
    -- animation override.  Set it before dressing so the body receives the
    -- human visual/attachment path used by ordinary player survivors.
    call(body, "setAsSurvivor")
    local okOutfit = call(body, "dressInNamedOutfit", Config.npcOutfit)
    if not okOutfit then
        -- Persistent outfit IDs are the supported fallback on runtimes that
        -- do not expose the named-outfit helper.  Keep the ID in ModData as
        -- an additional identity hint even when the named outfit succeeds.
        local okPersistent = call(body, "dressInPersistentOutfitID", Config.npcOutfitId)
        if not okPersistent then
            -- Some point releases expose a generic setter instead. It is
            -- still a guarded, one-time visual operation.
            call(body, "setOutfit", Config.npcOutfit)
        end
    end
    setIfAvailable(body, "setFemaleEtc", false)
    setIfAvailable(body, "setSkeleton", false)
    setIfAvailable(body, "setCrawler", false)
    setIfAvailable(body, "setFakeDead", false)
    setIfAvailable(body, "setReanimatedPlayer", false)
    setIfAvailable(body, "setReanimatedForGrappleOnly", false)
    setIfAvailable(body, "setDisplayName", Config.npcName)
    if type(body.setName) == "function" then call(body, "setName", Config.npcName) end
    -- Keep the persistent ID in the engine as an additional restart-stable
    -- identity hint.  The named Survivor outfit remains authoritative so a
    -- stale ID cannot turn the companion back into a zombie mesh.
    call(body, "setPersistentOutfitID", Config.npcOutfitId)
    data.GoblinOutfitId = Config.npcOutfitId
    data.GoblinVisualFingerprint = fingerprint
    data.GoblinVisualDirty = false

    local outfitItems = Config.npcOutfitItems
    if type(outfitItems) == "table" and #outfitItems > 0 then
        -- The requested vanilla pieces are the visible accessory outfit. The
        -- packaged Mystery Rig fullsuit is resolved in the same pass, so the
        -- networked body keeps its custom mesh instead of falling back to a
        -- stock zombie shell.
        local okInventory, inventory = call(body, "getInventory")
        local applied, total, detail, meshApplied = 0, #outfitItems,
            "inventory unavailable", false
        if okInventory and inventory ~= nil then
            applied, total, detail, meshApplied = applyConfiguredOutfit(body, inventory)
        end
        data.GoblinOutfitItems = table.concat(outfitItems, ",")
        data.GoblinOutfitItemsApplied = applied
        data.GoblinOutfitItemCount = total
        data.GoblinOutfitApplied = applied == total and total > 0
        data.GoblinMeshAsset = Config.npcVisualAsset
        data.GoblinMeshApplied = meshApplied == true
        if data.GoblinOutfitApplied and data.GoblinMeshApplied then
            data.GoblinMeshApplyError = nil
        else
            data.GoblinMeshApplyError = detail
        end
        if data.GoblinOutfitApplied then
            log("OUTFIT_APPLY id=" .. Config.npcId .. " items="
                .. data.GoblinOutfitItems)
        else
            log("OUTFIT_APPLY_FAILED id=" .. Config.npcId .. " applied="
                .. tostring(applied) .. "/" .. tostring(total) .. " detail=" .. tostring(detail))
        end
        if data.GoblinMeshApplied then
            log("MESH_APPLY id=" .. Config.npcId .. " asset=" .. tostring(Config.npcVisualAsset))
        else
            log("MESH_APPLY_FAILED id=" .. Config.npcId .. " asset="
                .. tostring(Config.npcVisualAsset) .. " detail=" .. tostring(detail))
        end
    else
        -- The supplied Mystery Rig remains a supported fallback when a
        -- deployment intentionally clears npcOutfitItems.  It uses the normal
        -- inventory/worn-item path and ordinary clothing replication.
        local meshApplied = false
        local okInventory, inventory = call(body, "getInventory")
        if okInventory and inventory ~= nil then
            local item = findInventoryItem(inventory, Config.npcVisualItemType)
            if item == nil then
                local okAdd, added = call(inventory, "AddItem", Config.npcVisualItemType)
                if okAdd then item = added end
            end
            if item ~= nil then
                local okLocation, location = call(item, "getBodyLocation")
                if okLocation and location ~= nil then
                    local okWorn, wornResult = call(body, "setWornItem", location, item)
                    meshApplied = okWorn and (wornResult == nil or wornResult == true)
                    if not meshApplied then
                        data.GoblinMeshApplyError = "setWornItem rejected Mystery Rig clothing"
                    end
                else
                    data.GoblinMeshApplyError = "Mystery Rig item has no body location"
                end
            else
                data.GoblinMeshApplyError = "Mystery Rig clothing item is not registered"
            end
        else
            data.GoblinMeshApplyError = "inventory is unavailable for Mystery Rig clothing"
        end
        data.GoblinMeshAsset = Config.npcVisualAsset
        data.GoblinMeshApplied = meshApplied
        data.GoblinOutfitApplied = meshApplied
        if meshApplied then
            data.GoblinMeshApplyError = nil
            log("MESH_APPLY id=" .. Config.npcId .. " asset=" .. tostring(Config.npcVisualAsset))
        else
            log("MESH_APPLY_FAILED id=" .. Config.npcId .. " detail="
                .. tostring(data.GoblinMeshApplyError))
        end
    end
    call(body, "resetModel")
    call(body, "resetModelNextFrame")
    log("ANIMATION_CHANGE id=" .. Config.npcId .. " outfit=" .. tostring(Config.npcOutfit))
end

function Body.applyInvariants(body, preserveTarget)
    if body == nil then return false end
    local data = dataFor(body)
    if data == nil then return false end

    -- Identity variables are mirrored into the animation graph.  The custom
    -- nodes are conditional on GoblinNPC=true, so ordinary zombies remain on
    -- the vanilla Zombie_* graph.
    setVariable(body, "GoblinNPC", true)
    setVariable(body, "GoblinID", Config.npcId)
    setVariable(body, "GoblinHumanized", true)
    setVariable(body, "GoblinTask", data.GoblinTask or Constants.TASK.FOLLOW)
    setVariable(body, "GoblinMoveType", data.GoblinMoveType or Constants.MOVE_TYPE.IDLE)
    setVariable(body, "GoblinCombatState", data.GoblinCombatState or Constants.COMBAT.NONE)
    -- Physical state is separate from the high-level task and is also an
    -- animation-graph input for the bounded hit/recovery nodes.  Mirroring it
    -- here means a restored body cannot briefly enter a zombie hit state while
    -- its persisted ModData is still being reapplied.
    setVariable(body, "GoblinPhysicalState", data.GoblinPhysicalState or Constants.PHYSICAL.IDLE)
    setVariable(body, "GoblinRecoveryStage", data.GoblinRecoveryStage or "")
    setVariable(body, "bMoving", data.GoblinPhysicalState == Constants.PHYSICAL.PATHING
        or data.GoblinPhysicalState == Constants.PHYSICAL.WALKING
        or data.GoblinPhysicalState == Constants.PHYSICAL.RUNNING)
    setVariable(body, "MovementSpeed", tonumber(data.GoblinMovementSpeed) or 0.70)

    -- The animation graph reads walkType/speedType in addition to the custom
    -- Goblin variables; leaving the zombie's default walk type in place
    -- strands it in GenericDefaultState even when the Bob_* nodes are loaded.
    local running = data.GoblinMoveType == Constants.MOVE_TYPE.RUN
    setIfAvailable(body, "setWalkType", running and "sprint" or "Walk")
    call(body, "setSpeedTypeFromWalkType")
    setIfAvailable(body, "setRunning", running)
    setIfAvailable(body, "setSprinting", false)

    setIfAvailable(body, "setCanWalk", true)
    -- Build 42 exposes no generic setCantBite setter on IsoZombie; no teeth
    -- is the native, replicated way to keep this body from biting.
    setIfAvailable(body, "setNoTeeth", true)
    setIfAvailable(body, "setBite", false)
    setIfAvailable(body, "setCantBite", true)
    setIfAvailable(body, "setVoiceSoundName", "")
    setIfAvailable(body, "setBiteSoundName", "")
    -- Protection controls damage/immortality below, but friendly identity must
    -- always disable vanilla zombie target selection.  Otherwise a deliberately
    -- vulnerable Goblin could still bite a player between brain updates.
    setIfAvailable(body, "setZombiesDontAttack", true)
    if Config.protected then
        -- A real zombie created by the B42 population manager can be marked
        -- useless/inactive or carry a near-zero network health value before
        -- the first managed tick. Keep the one marker-owned shell eligible
        -- for native updates and inside the safe packet range.
        setIfAvailable(body, "setUseless", false)
        setIfAvailable(body, "makeInactive", false)
        setIfAvailable(body, "setGodMod", true)
        setIfAvailable(body, "setInvulnerable", true)
        setIfAvailable(body, "setNoDamage", true)
        setIfAvailable(body, "setImmortal", true)
        setIfAvailable(body, "setImmortalTutorialZombie", true)
    end
    if not preserveTarget then clearZombieTargets(body) end
    applyHumanVisual(body, data)
    -- The configured Machete is the default held item, not a combat-only
    -- fabrication.  The call is idempotent and retried on later invariant
    -- passes if item scripts are still loading during server startup.
    local weaponReady, weaponDetail = Body.ensureWeapon(body)
    if not weaponReady then
        data.GoblinLastWeaponError = weaponDetail
    else
        data.GoblinLastWeaponError = nil
    end
    if data.GoblinCombatState ~= Constants.COMBAT.ATTACKING then
        Body.setCombatPose(body, false)
    end
    data.GoblinLastInvariantAt = nowMs()
    return true
end

function Body.auditAnimation(body)
    -- Build 42 does not expose a universal "selected AnimSet node" callback,
    -- so use the read-only state/animation diagnostics it does expose.  A
    -- mismatch is logged only when the diagnostic signature changes; normal
    -- idle/walk/run frames never produce per-tick log spam.
    if not Body.isGoblin(body) then return false end
    local data = dataFor(body)
    if data == nil then return false end
    local timestamp = nowMs()
    if timestamp - (tonumber(data.GoblinLastAnimationAuditAt) or 0) < 1000 then
        return false
    end
    data.GoblinLastAnimationAuditAt = timestamp

    local okPz, pzState = call(body, "getCurrentStateName")
    local okAnimation, animationState = call(body, "getAnimationStateName")
    local okDebug, animationDebug = call(body, "getAnimationDebug")
    pzState = okPz and clippedString(pzState) or "unknown"
    animationState = okAnimation and clippedString(animationState) or "unknown"
    animationDebug = okDebug and clippedString(animationDebug, 160) or "unknown"

    local searchable = string.lower(animationState .. " " .. animationDebug)
    local looksZombie = string.find(searchable, "zombie", 1, true) ~= nil
        or string.find(searchable, "lunge", 1, true) ~= nil
        or string.find(searchable, "bite", 1, true) ~= nil
        or string.find(searchable, "crawl", 1, true) ~= nil
        or string.find(searchable, "fakedead", 1, true) ~= nil
    if not looksZombie then return true end

    local target = nil
    local okTarget, targetValue = call(body, "getTarget")
    if okTarget then target = targetValue end
    local distance = "unknown"
    local point = Body.position(body)
    local targetPoint = Body.position(target)
    if point ~= nil and targetPoint ~= nil then
        distance = string.format("%.2f", math.sqrt(
            (point.x - targetPoint.x) ^ 2 + (point.y - targetPoint.y) ^ 2
                + (point.z - targetPoint.z) ^ 2
        ))
    end
    local pathfinder = "unavailable"
    local okBehavior, behavior = call(body, "getPathFindBehavior2")
    if okBehavior and behavior ~= nil then
        local okCancelled, cancelled = call(behavior, "getIsCancelled")
        pathfinder = okCancelled and (cancelled and "cancelled" or "active") or "present"
    end
    local mismatch = table.concat({
        pzState, animationState, animationDebug, tostring(data.GoblinMoveType),
        tostring(data.GoblinTask), tostring(data.GoblinPhysicalState), pathfinder,
        target ~= nil and "target" or "none", distance
    }, "|")
    if mismatch ~= data.GoblinLastAnimationMismatch then
        data.GoblinLastAnimationMismatch = mismatch
        log("ANIMATION_CHANGE id=" .. Config.npcId
            .. " reason=zombie_node_selected"
            .. " current_pz_state=" .. pzState
            .. " current_animation_state=" .. animationState
            .. " animation_debug=" .. animationDebug
            .. " GoblinNPC=true GoblinMoveType=" .. tostring(data.GoblinMoveType)
            .. " task=" .. tostring(data.GoblinTask)
            .. " physical_state=" .. tostring(data.GoblinPhysicalState)
            .. " pathfinder=" .. pathfinder
            .. " target=" .. (target ~= nil and "present" or "none")
            .. " distance=" .. distance
            .. " network=server-authoritative")
    end
    return false
end

function Body.mark(body, generation, owner)
    local data = dataFor(body)
    if data == nil then return false, "IsoZombie ModData is unavailable" end
    data.GoblinNPC = true
    data.GoblinID = Config.npcId
    data.goblin_owned = true
    data.goblin_friendly = true
    data.goblin_engine = "iso_zombie"
    data.GoblinHumanized = true
    data.GoblinSpawnedAt = nowMs()
    data.GoblinGeneration = tonumber(generation) or 0
    data.GoblinOwner = owner
    data.GoblinTask = data.GoblinTask or Constants.TASK.FOLLOW
    data.GoblinMoveType = Constants.MOVE_TYPE.IDLE
    data.GoblinCombatState = Constants.COMBAT.NONE
    data.GoblinPhysicalState = Constants.PHYSICAL.IDLE
    data.GoblinStateSequence = tonumber(data.GoblinStateSequence) or 0
    data.GoblinLastInvariantAt = 0
    Body.applyInvariants(body, false)
    transmit(body)
    return true, "IsoZombie marked as Goblin"
end

function Body.setPhysicalState(body, physical, moveType, combatState)
    if not Body.isGoblin(body) then return false end
    local data = dataFor(body)
    if data == nil or Constants.PHYSICAL[physical] == nil then return false end
    local changed = data.GoblinPhysicalState ~= physical
        or data.GoblinMoveType ~= (moveType or data.GoblinMoveType)
        or data.GoblinCombatState ~= (combatState or data.GoblinCombatState)
    data.GoblinPhysicalState = physical
    data.GoblinMoveType = moveType or data.GoblinMoveType
    data.GoblinCombatState = combatState or data.GoblinCombatState
    setVariable(body, "GoblinMoveType", data.GoblinMoveType)
    setVariable(body, "GoblinCombatState", data.GoblinCombatState)
    setVariable(body, "GoblinPhysicalState", data.GoblinPhysicalState)
    setVariable(body, "GoblinRecoveryStage", data.GoblinRecoveryStage or "")
    setVariable(body, "bMoving", physical == Constants.PHYSICAL.PATHING
        or physical == Constants.PHYSICAL.WALKING
        or physical == Constants.PHYSICAL.RUNNING)
    if changed then
        data.GoblinStateSequence = (tonumber(data.GoblinStateSequence) or 0) + 1
        data.GoblinStateChangedAt = nowMs()
        log("STATE_CHANGE id=" .. Config.npcId .. " physical=" .. tostring(physical)
            .. " move=" .. tostring(data.GoblinMoveType)
            .. " combat=" .. tostring(data.GoblinCombatState))
        if physical == Constants.PHYSICAL.HIT then
            data.GoblinRecoveryStage = "hit"
            setVariable(body, "GoblinRecoveryStage", "hit")
            log("HIT id=" .. Config.npcId)
        elseif physical == Constants.PHYSICAL.RECOVERING then
            data.GoblinRecoveryStage = data.GoblinRecoveryStage or "recovering"
            setVariable(body, "GoblinRecoveryStage", data.GoblinRecoveryStage)
            log("RECOVERY id=" .. Config.npcId .. " state=recovering")
        end
        transmit(body)
    end
    return true
end

function Body.setTask(body, task, payload)
    if not Body.isGoblin(body) or not Constants.ALLOWED_TASKS[task] then return false end
    local data = dataFor(body)
    if data == nil then return false end
    data.GoblinTask = task
    data.GoblinTaskPayload = payload
    data.GoblinTaskSequence = (tonumber(data.GoblinTaskSequence) or 0) + 1
    setVariable(body, "GoblinTask", task)
    transmit(body)
    return true
end

function Body.setCombatPose(body, active)
    if not Body.isGoblin(body) then return false end
    local enabled = active == true
    -- These are the player-melee animation variables, not the zombie bite
    -- target/attack fields.  Explicitly clearing the native target every time
    -- keeps an IsoZombie body out of the lunge/bite state machine.
    call(body, "setTarget", nil)
    call(body, "setAttackTargetSquare", nil)
    setVariable(body, "NoLungeAttack", true)
    setVariable(body, "NoLungeTarget", true)
    setVariable(body, "isAiming", false)
    setVariable(body, "isAttacking", enabled)
    setVariable(body, "isMelee", enabled)
    setVariable(body, "AttackAnim", enabled)
    setVariable(body, "initiateAttack", enabled)
    setVariable(body, "BlockMovement", enabled)
    call(body, "setIsAiming", false)
    setIfAvailable(body, "setPerformingAttackAnimation", enabled)
    return true
end

function Body.faceTarget(body, target)
    if not Body.isGoblin(body) or target == nil then return false end
    local actor, other = Body.position(body), Body.position(target)
    if actor == nil or other == nil then return false end
    local dx, dy = other.x - actor.x, other.y - actor.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return false end
    local ok, result = call(body, "setForwardDirection", dx / length, dy / length)
    return ok and (result == nil or result == true)
end

function Body.observeHealth(body, timestamp)
    if not Body.isGoblin(body) then return "not_goblin" end
    local bodyData = dataFor(body)
    if bodyData == nil then return "unknown" end
    local okHealth, health = call(body, "getHealth")
    if not okHealth or type(health) ~= "number" or health ~= health then
        return "unknown"
    end
    local now = timestamp or nowMs()
    local previous = tonumber(bodyData.GoblinLastHealth)
    bodyData.GoblinLastHealth = health
    if previous ~= nil and health < previous - 0.001 then
        bodyData.GoblinLastDamageAt = now
        bodyData.GoblinRecoveryUntil = now
            + (tonumber(Config.recoverySeconds) or 0.8) * 1000
        bodyData.GoblinRecoveryStage = "hit"
        Body.setCombatPose(body, false)
        Body.setPhysicalState(body, Constants.PHYSICAL.HIT, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.HIT)
        transmit(body)
        return "hit"
    end
    local recoveryUntil = tonumber(bodyData.GoblinRecoveryUntil)
    if recoveryUntil ~= nil then
        if now < recoveryUntil then
            local pulse = (tonumber(Config.recoveryHitPulseSeconds) or 0.15) * 1000
            if now - (tonumber(bodyData.GoblinLastDamageAt) or now) >= pulse then
                bodyData.GoblinRecoveryStage = "recovering"
                Body.setPhysicalState(body, Constants.PHYSICAL.RECOVERING,
                    Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
            end
            return "recovering"
        end
        bodyData.GoblinRecoveryUntil = nil
        bodyData.GoblinRecoveryStage = nil
        bodyData.GoblinLastRecoveredAt = now
        transmit(body)
        return "recovered"
    end
    return "stable"
end

function Body.ensureWeapon(body, requestedType)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local weaponType = requestedType or Config.weaponType
    if type(weaponType) ~= "string" or weaponType ~= Config.weaponType then
        return false, "only the configured preferred weapon is permitted"
    end
    local data = dataFor(body)
    local okInventory, inventory = call(body, "getInventory")
    if not okInventory or inventory == nil then return false, "inventory is unavailable" end

    local item = nil
    local okPrimary, primary = call(body, "getPrimaryHandItem")
    if okPrimary and primary ~= nil then
        local okType, fullType = call(primary, "getFullType")
        if okType and fullType == weaponType then item = primary end
    end
    if item == nil then
        -- Reuse a persisted copy before creating anything.  This keeps the
        -- companion's inventory stable across restore and avoids accumulating
        -- duplicate machetes when another item was left in the primary hand.
        item = findInventoryItem(inventory, weaponType)
    end
    if item == nil then
        local okAdd, added = call(inventory, "AddItem", weaponType)
        if okAdd then item = added end
    end
    if item == nil then return false, "could not create the preferred weapon" end
    local okSecondary, secondary = call(body, "getSecondaryHandItem")
    local changed = primary ~= item or (okSecondary and secondary ~= nil)
        or data.GoblinWeaponType ~= weaponType or data.GoblinWeaponReady ~= true
    if changed then
        call(body, "setPrimaryHandItem", item)
        call(body, "setSecondaryHandItem", nil)
        data.GoblinWeaponType = weaponType
        data.GoblinWeaponReady = true
        transmit(body)
    end
    return true, "preferred weapon equipped", item
end

function Body.say(body, text)
    if not Body.isGoblin(body) or type(text) ~= "string" or #text < 1 or #text > 240 then
        return false, "speech is invalid"
    end
    local ok = call(body, "addLineChatElement", text, 0.1, 0.8, 0.1)
    if ok then return true, "speech displayed" end
    return false, "chat-line API is unavailable"
end

function Body.snapshot(body)
    if not Body.isGoblin(body) then return nil end
    local data = dataFor(body)
    local point = Body.position(body)
    return {
        npc_id = Config.npcId,
        name = Config.npcName,
        body_present = Body.exists(body),
        alive = Body.exists(body),
        entity_class = "IsoZombie",
        engine = "iso_zombie",
        humanized = data.GoblinHumanized == true,
        outfit_id = data.GoblinOutfitId,
        outfit_items = data.GoblinOutfitItems,
        outfit_items_applied = tonumber(data.GoblinOutfitItemsApplied) or 0,
        outfit_item_count = tonumber(data.GoblinOutfitItemCount) or 0,
        weapon_type = data.GoblinWeaponType,
        weapon_ready = data.GoblinWeaponReady == true,
        weapon_error = data.GoblinLastWeaponError,
        visual_asset = data.GoblinMeshAsset,
        visual_asset_applied = data.GoblinMeshApplied == true,
        health = tonumber(data.GoblinLastHealth),
        damage_at = tonumber(data.GoblinLastDamageAt),
        melee_attacks = tonumber(data.GoblinMeleeAttacks) or 0,
        melee_kills = tonumber(data.GoblinMeleeKills) or 0,
        combat_error = data.GoblinLastCombatError,
        loot_status = data.GoblinLootStatus,
        loot_count = tonumber(data.GoblinLootCount) or 0,
        owner = data.GoblinOwner,
        task = data.GoblinTask,
        physical_state = data.GoblinPhysicalState,
        move_type = data.GoblinMoveType,
        combat_state = data.GoblinCombatState,
        state_sequence = data.GoblinStateSequence,
        position = point
    }
end

return Body

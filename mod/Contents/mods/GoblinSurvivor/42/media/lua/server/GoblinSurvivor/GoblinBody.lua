-- Managed IsoZombie body used by every player's Goblin companion.
--
-- Project Zomboid still owns the moving-object lifecycle.  We mark a normal
-- IsoZombie, suppress hostile zombie behavior, and apply one skinned full-body
-- ClothingItem for Goblin.  No random survivor wardrobe is allowed.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")

local Body = {}
local VISUAL_GUID = "6bd4b657-5e6c-4b17-9b53-3f6bb6d4f3d1"

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
    return 0
end

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] " .. tostring(message))
    end
end

local function setVariable(body, name, value)
    call(body, "setVariable", name, value)
end

local function findInventoryItem(inventory, fullType)
    if inventory == nil or type(fullType) ~= "string" then return nil end
    local okItems, items = call(inventory, "getItems")
    if not okItems or items == nil then return nil end
    local okSize, size = call(items, "size")
    size = okSize and tonumber(size) or 0
    for index = 0, size - 1 do
        local okItem, item = call(items, "get", index)
        if okItem and item ~= nil then
            local okType, itemType = call(item, "getFullType")
            if okType and itemType == fullType then return item end
        end
    end
    return nil
end

local function ensureInventoryItem(inventory, fullType)
    local item = findInventoryItem(inventory, fullType)
    if item ~= nil then return item end
    local okAdd, added = call(inventory, "AddItem", fullType)
    if okAdd then return added end
    return nil
end

local function clearItemVisuals(body)
    call(body, "clearWornItems")
    local okVisuals, visuals = call(body, "getItemVisuals")
    if okVisuals and visuals ~= nil then call(visuals, "clear") end
end

local function applyVisual(body, data)
    if data.GoblinVisualApplied == true and data.GoblinVisualDirty ~= true then
        return true
    end

    local timestamp = nowMs()
    if timestamp > 0 and timestamp < (tonumber(data.GoblinNextVisualAttemptAt) or 0) then
        return false
    end
    data.GoblinNextVisualAttemptAt = timestamp + 2000

    -- setAsSurvivor is needed for the human visual/model path, but it must be
    -- done once only.  Repeating it makes Build 42 regenerate survivor looks.
    if data.GoblinVisualPrepared ~= true then
        call(body, "setDressInRandomOutfit", false)
        call(body, "setAsSurvivor")
        call(body, "setDressInRandomOutfit", false)
        call(body, "setFemaleEtc", false)
        call(body, "setSkeleton", false)
        call(body, "setCrawler", false)
        call(body, "setFakeDead", false)
        clearItemVisuals(body)
        data.GoblinVisualPrepared = true
    end

    -- dressInClothingItem takes the ClothingItem GUID.  This directly drives
    -- Goblin_MysteryBody.xml -> Goblin_PZ_MysteryRig -> textureChoices.
    local customOk = call(body, "dressInClothingItem", VISUAL_GUID)
    data.GoblinMeshAsset = Config.npcVisualAsset
    data.GoblinMeshApplied = customOk == true
    data.GoblinOutfitApplied = customOk == true
    data.GoblinVisualApplied = customOk == true
    data.GoblinVisualDirty = customOk ~= true
    data.GoblinVisualError = customOk and nil or "dressInClothingItem failed"

    if customOk then
        call(body, "resetModel")
        call(body, "resetModelNextFrame")
        log("MESH_APPLY owner=" .. tostring(data.GoblinOwner)
            .. " npc_id=" .. tostring(data.GoblinID)
            .. " asset=" .. tostring(Config.npcVisualAsset)
            .. " method=clothing-guid")
        return true
    end

    log("MESH_APPLY_FAILED owner=" .. tostring(data.GoblinOwner)
        .. " detail=" .. tostring(data.GoblinVisualError))
    return false
end

function Body.data(body)
    local ok, data = call(body, "getModData")
    return ok and data or nil
end

function Body.position(object)
    if object == nil then return nil end
    local okX, x = call(object, "getX")
    local okY, y = call(object, "getY")
    local okZ, z = call(object, "getZ")
    if not okX or not okY or not okZ
        or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

function Body.exists(body)
    if body == nil or Body.position(body) == nil then return false end
    local okDead, dead = call(body, "isDead")
    if okDead and dead == true then return false end
    local okHealth, health = call(body, "getHealth")
    if okHealth and tonumber(health) ~= nil and tonumber(health) <= 0 then return false end
    local okCurrent, square = call(body, "getCurrentSquare")
    if okCurrent then return square ~= nil end
    local okExists, exists = call(body, "isExistInTheWorld")
    return not okExists or exists == true
end

function Body.isGoblin(body)
    local data = Body.data(body)
    if data == nil or data.GoblinNPC ~= true or data.goblin_owned ~= true then return false end
    local id = tostring(data.GoblinID or "")
    return id == Config.npcId or string.sub(id, 1, #Config.npcId + 1) == Config.npcId .. "."
end

function Body.owner(body)
    local data = Body.data(body)
    return data ~= nil and data.GoblinOwner or nil
end

function Body.npcId(body)
    local data = Body.data(body)
    return data ~= nil and data.GoblinID or nil
end

function Body.clearNativeTargets(body)
    if body == nil then return false end
    call(body, "setTarget", nil)
    call(body, "setThumpTarget", nil)
    call(body, "setAttackTargetSquare", nil)
    call(body, "setEatBodyTarget", nil, false)
    call(body, "clearAggroList")
    setVariable(body, "NoLungeTarget", true)
    setVariable(body, "NoLungeAttack", true)
    return true
end

function Body.mark(body, generation, owner, npcId)
    local data = Body.data(body)
    if data == nil then return false, "IsoZombie ModData unavailable" end
    if type(owner) ~= "string" or owner == "" then return false, "owner is missing" end

    data.GoblinNPC = true
    data.goblin_owned = true
    data.goblin_friendly = true
    data.GoblinID = npcId or (Config.npcId .. "." .. string.lower(owner))
    data.GoblinOwner = owner
    data.GoblinGeneration = tonumber(generation) or 1
    data.GoblinSpawnedAt = nowMs()
    data.GoblinTask = Constants.TASK.FOLLOW
    data.GoblinTaskPayload = { owner = owner }
    data.GoblinPhysicalState = Constants.PHYSICAL.IDLE
    data.GoblinMoveType = Constants.MOVE_TYPE.IDLE
    data.GoblinCombatState = Constants.COMBAT.NONE
    data.GoblinHumanized = true
    data.GoblinVisualDirty = true
    data.GoblinVisualPrepared = false
    data.GoblinVisualApplied = false
    data.GoblinStateSequence = 0
    data.GoblinTaskSequence = 0

    call(body, "setDressInRandomOutfit", false)
    Body.applyInvariants(body)
    return true, "Goblin body marked"
end

function Body.setTask(body, task, payload)
    if not Body.isGoblin(body) or Constants.ALLOWED_TASKS[task] ~= true then return false end
    local data = Body.data(body)
    if data == nil then return false end
    data.GoblinTask = task
    data.GoblinTaskPayload = type(payload) == "table" and payload or {}
    data.GoblinTaskSequence = (tonumber(data.GoblinTaskSequence) or 0) + 1
    setVariable(body, "GoblinTask", task)
    return true
end

function Body.setPhysicalState(body, physical, moveType, combatState)
    if not Body.isGoblin(body) then return false end
    local data = Body.data(body)
    if data == nil then return false end
    local move = moveType or data.GoblinMoveType or Constants.MOVE_TYPE.IDLE
    data.GoblinPhysicalState = physical
    data.GoblinMoveType = move
    data.GoblinCombatState = combatState or data.GoblinCombatState or Constants.COMBAT.NONE
    data.GoblinStateSequence = (tonumber(data.GoblinStateSequence) or 0) + 1

    local moving = move ~= Constants.MOVE_TYPE.IDLE
    local running = move == Constants.MOVE_TYPE.RUN
    setVariable(body, "GoblinNPC", true)
    setVariable(body, "GoblinPhysicalState", physical)
    setVariable(body, "GoblinMoveType", move)
    setVariable(body, "GoblinCombatState", data.GoblinCombatState)
    setVariable(body, "bMoving", moving)
    call(body, "setRunning", running)
    call(body, "setSprinting", false)
    call(body, "setWalkType", running and "sprint" or "Walk")
    call(body, "setSpeedTypeFromWalkType")
    return true
end

function Body.applyInvariants(body)
    if not Body.isGoblin(body) then return false end
    local data = Body.data(body)
    if data == nil then return false end

    Body.clearNativeTargets(body)
    call(body, "setNoTeeth", true)
    call(body, "setCanWalk", true)
    call(body, "setCrawler", false)
    call(body, "setFakeDead", false)
    call(body, "setSkeleton", false)
    call(body, "setZombiesDontAttack", true)
    call(body, "setDressInRandomOutfit", false)
    call(body, "setSpeedMod", 1.0)
    call(body, "setTurnAlertedValues", -5, 5)
    call(body, "setVoiceSoundName", "")
    call(body, "setBiteSoundName", "")
    setVariable(body, "Bandit", true)
    setVariable(body, "GoblinNPC", true)
    setVariable(body, "GoblinID", tostring(data.GoblinID))
    setVariable(body, "NoLungeTarget", true)
    setVariable(body, "NoLungeAttack", true)
    setVariable(body, "ZombieHitReaction", "Chainsaw")

    local move = data.GoblinMoveType or Constants.MOVE_TYPE.IDLE
    Body.setPhysicalState(body, data.GoblinPhysicalState or Constants.PHYSICAL.IDLE,
        move, data.GoblinCombatState or Constants.COMBAT.NONE)

    if Config.protected then
        call(body, "setGodMod", true)
        call(body, "setInvulnerable", true)
        call(body, "setNoDamage", true)
        call(body, "setImmortal", true)
    end

    applyVisual(body, data)
    Body.ensureWeapon(body)
    return true
end

function Body.ensureWeapon(body, requestedType)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local weaponType = requestedType or Config.weaponType
    if weaponType ~= Config.weaponType then return false, "unsupported weapon" end
    local okInventory, inventory = call(body, "getInventory")
    if not okInventory or inventory == nil then return false, "inventory unavailable" end
    local item = findInventoryItem(inventory, weaponType)
    if item == nil then item = ensureInventoryItem(inventory, weaponType) end
    if item == nil then return false, "preferred weapon unavailable" end
    call(body, "setPrimaryHandItem", item)
    call(body, "setSecondaryHandItem", nil)
    local data = Body.data(body)
    if data ~= nil then
        data.GoblinWeaponType = weaponType
        data.GoblinWeaponReady = true
    end
    return true, "preferred weapon equipped", item
end

function Body.setCombatPose(body, active)
    if not Body.isGoblin(body) then return false end
    Body.clearNativeTargets(body)
    local enabled = active == true
    setVariable(body, "isAttacking", enabled)
    setVariable(body, "isMelee", enabled)
    setVariable(body, "AttackAnim", enabled)
    setVariable(body, "initiateAttack", enabled)
    call(body, "setPerformingAttackAnimation", enabled)
    return true
end

function Body.faceTarget(body, target)
    local a, b = Body.position(body), Body.position(target)
    if a == nil or b == nil then return false end
    local dx, dy = b.x - a.x, b.y - a.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return false end
    local ok = call(body, "setForwardDirection", dx / length, dy / length)
    return ok == true
end

function Body.say(body, text)
    if not Body.isGoblin(body) or type(text) ~= "string" or #text < 1 or #text > 240 then
        return false, "speech is invalid"
    end
    local ok = call(body, "addLineChatElement", text, 0.1, 0.8, 0.1)
    if ok then return true, "speech displayed" end
    local okSay = call(body, "Say", text)
    return okSay == true, okSay and "speech displayed" or "speech API unavailable"
end

function Body.snapshot(body)
    if not Body.isGoblin(body) then return nil end
    local data = Body.data(body)
    local okOnline, onlineId = call(body, "getOnlineID")
    if not okOnline or type(onlineId) ~= "number" or onlineId < 0 then onlineId = nil end
    return {
        npc_id = data.GoblinID,
        owner = data.GoblinOwner,
        name = Config.npcName,
        body_present = Body.exists(body),
        alive = Body.exists(body),
        online_id = onlineId,
        generation = tonumber(data.GoblinGeneration) or 0,
        engine = "iso_zombie",
        humanized = true,
        friendly = true,
        task = data.GoblinTask,
        physical_state = data.GoblinPhysicalState,
        move_type = data.GoblinMoveType,
        combat_state = data.GoblinCombatState,
        visual_asset = Config.npcVisualAsset,
        visual_asset_applied = data.GoblinVisualApplied == true,
        visual_error = data.GoblinVisualError,
        weapon_type = data.GoblinWeaponType,
        weapon_ready = data.GoblinWeaponReady == true,
        loot_count = tonumber(data.GoblinLootCount) or 0,
        loot_status = data.GoblinLootStatus,
        base_set = data.GoblinBaseSet == true,
        base_x = tonumber(data.GoblinBaseX),
        base_y = tonumber(data.GoblinBaseY),
        base_z = tonumber(data.GoblinBaseZ),
        position = Body.position(body)
    }
end

return Body

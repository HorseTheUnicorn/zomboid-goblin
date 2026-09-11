local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Appearance = require("GoblinSurvivor/GoblinAppearance")

local Body = {}
local WARDROBE = {
    "GoblinSurvivor.Goblin_MysteryBody",
    "Base.Shirt_Priest",
    "Base.Trousers_Black",
    "Base.Hat_Beret",
    "Base.Shoes_BlackBoots"
}
local PISTOL = "Base.Pistol3"
local nextEquipmentAt = setmetatable({}, { __mode = "k" })

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

local function log(text)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(text)) end
end

local function setVariable(body, name, value)
    call(body, "setVariable", name, value)
end

local function inventory(body)
    local ok, value = call(body, "getInventory")
    return ok and value or nil
end

local function findInventoryItem(container, fullType)
    if container == nil then return nil end
    local okItems, items = call(container, "getItems")
    if not okItems or items == nil then return nil end
    local okSize, size = call(items, "size")
    size = okSize and tonumber(size) or 0
    for i = 0, size - 1 do
        local okItem, item = call(items, "get", i)
        if okItem and item ~= nil then
            local okType, itemType = call(item, "getFullType")
            if okType and itemType == fullType then return item end
        end
    end
    return nil
end

local function ensureInventoryItem(container, fullType)
    local item = findInventoryItem(container, fullType)
    if item ~= nil then return item end
    local ok, added = call(container, "AddItem", fullType)
    return ok and added or nil
end

local function wornTypes(body)
    local result = {}
    local okWorn, worn = call(body, "getWornItems")
    if not okWorn or worn == nil then return result end
    local okSize, size = call(worn, "size")
    size = okSize and tonumber(size) or 0
    for i = 0, size - 1 do
        local okEntry, entry = call(worn, "get", i)
        if okEntry and entry ~= nil then
            local okItem, item = call(entry, "getItem")
            if okItem and item ~= nil then
                local okType, itemType = call(item, "getFullType")
                if okType and type(itemType) == "string" then result[itemType] = true end
            end
        end
    end
    return result
end

local function wardrobeComplete(body)
    local worn = wornTypes(body)
    for _, fullType in ipairs(WARDROBE) do
        if worn[fullType] ~= true then return false end
    end
    return true
end

local function wearItem(body, item, fullType)
    if item == nil then return false end
    local okLocation, location = call(item, "getBodyLocation")
    if okLocation and location ~= nil then
        local okWear = select(1, call(body, "setWornItem", location, item))
        if okWear then return true end
    end
    -- Build 42 keeps these compatibility helpers; use them as a fallback if
    -- Kahlua doesn't expose ItemBodyLocation cleanly for a particular item.
    if fullType == "Base.Hat_Beret" then return select(1, call(body, "setClothingItem_Head", item)) end
    if fullType == "Base.Shirt_Priest" then return select(1, call(body, "setClothingItem_Torso", item)) end
    if fullType == "Base.Trousers_Black" then return select(1, call(body, "setClothingItem_Legs", item)) end
    if fullType == "Base.Shoes_BlackBoots" then return select(1, call(body, "setClothingItem_Feet", item)) end
    return false
end

local function applyWardrobe(body, data)
    if wardrobeComplete(body) then
        data.GoblinVisualApplied, data.GoblinVisualError = Appearance.apply(body, nowMs())
        data.GoblinVisualAsset = Config.npcVisualAsset
        return data.GoblinVisualApplied
    end

    if data.GoblinVisualPrepared ~= true then
        call(body, "setDressInRandomOutfit", false)
        call(body, "setDressInRandomOutfit", false)
        call(body, "setFemaleEtc", false)
        call(body, "setSkeleton", false)
        call(body, "setCrawler", false)
        call(body, "setFakeDead", false)
        data.GoblinVisualPrepared = true
    end

    call(body, "clearWornItems")
    local inv = inventory(body)
    if inv == nil then
        data.GoblinVisualApplied = false
        data.GoblinVisualError = "inventory unavailable"
        return false
    end

    local applied = 0
    for _, fullType in ipairs(WARDROBE) do
        local item = ensureInventoryItem(inv, fullType)
        if wearItem(body, item, fullType) then applied = applied + 1 end
    end
    call(body, "onWornItemsChanged")
    call(body, "resetModel")
    call(body, "resetModelNextFrame")

    local ok = wardrobeComplete(body)
    data.GoblinVisualApplied = ok
    data.GoblinVisualError = ok and nil or ("wardrobe applied " .. tostring(applied) .. "/" .. tostring(#WARDROBE))
    data.GoblinVisualAsset = Config.npcVisualAsset
    if ok then data.GoblinVisualApplied, data.GoblinVisualError = Appearance.apply(body, nowMs()) end
    if ok and data.GoblinWardrobeLogged ~= true then
        data.GoblinWardrobeLogged = true
        log("WARDROBE_APPLIED owner=" .. tostring(data.GoblinOwner)
            .. " outfit=PriestShirt,BlackTrousers,Beret,BlackBoots")
    end
    return ok
end

local function refillPistol(item)
    if item == nil then return end
    local okMax, maxAmmo = call(item, "getMaxAmmo")
    maxAmmo = okMax and tonumber(maxAmmo) or 15
    if maxAmmo == nil or maxAmmo < 1 then maxAmmo = 15 end
    call(item, "setContainsClip", true)
    call(item, "setCurrentAmmoCount", math.floor(maxAmmo))
    call(item, "setRoundChambered", true)
    call(item, "setSpentRoundChambered", false)
    call(item, "setSpentRoundCount", 0)
    call(item, "setJammed", false)
    local okConditionMax, conditionMax = call(item, "getConditionMax")
    if okConditionMax and tonumber(conditionMax) then call(item, "setCondition", tonumber(conditionMax)) end
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
    if not okX or not okY or not okZ or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
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
    return true
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
    data.GoblinVisualPrepared = false
    data.GoblinVisualApplied = false
    data.GoblinAutonomyEnabled = true
    data.GoblinAutonomous = false
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

function Body.ensureWeapon(body, requestedType)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local inv = inventory(body)
    if inv == nil then return false, "inventory unavailable" end
    local item = findInventoryItem(inv, PISTOL)
    if item == nil then item = ensureInventoryItem(inv, PISTOL) end
    if item == nil then return false, "D-E pistol unavailable" end
    refillPistol(item)
    call(body, "setPrimaryHandItem", item)
    call(body, "setSecondaryHandItem", nil)
    call(body, "resetEquippedHandsModels")
    local data = Body.data(body)
    if data ~= nil then
        data.GoblinWeaponType = PISTOL
        data.GoblinWeaponReady = true
        data.GoblinInfiniteAmmo = true
    end
    return true, "D-E pistol equipped with unlimited ammo", item
end

function Body.refillWeapon(body)
    local inv = inventory(body)
    if inv == nil then return false end
    local item = findInventoryItem(inv, PISTOL)
    if item == nil then return false end
    refillPistol(item)
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
    setVariable(body, "GoblinNPC", true)
    setVariable(body, "GoblinID", tostring(data.GoblinID))
    setVariable(body, "NoLungeTarget", true)
    setVariable(body, "NoLungeAttack", true)
    setVariable(body, "ZombieHitReaction", "Chainsaw")
    if Config.protected then
        call(body, "setGodMod", true)
        call(body, "setInvulnerable", true)
        call(body, "setNoDamage", true)
        call(body, "setImmortal", true)
    end
    local timestamp = nowMs()
    if timestamp >= (nextEquipmentAt[body] or 0) then
        nextEquipmentAt[body] = timestamp + 2000
        applyWardrobe(body, data)
        Body.ensureWeapon(body)
    end
    local move = data.GoblinMoveType or Constants.MOVE_TYPE.IDLE
    Body.setPhysicalState(body, data.GoblinPhysicalState or Constants.PHYSICAL.IDLE, move,
        data.GoblinCombatState or Constants.COMBAT.NONE)
    return true
end

function Body.setCombatPose(body, active)
    if not Body.isGoblin(body) then return false end
    Body.clearNativeTargets(body)
    local enabled = active == true
    setVariable(body, "isAttacking", enabled)
    setVariable(body, "isMelee", false)
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
    return select(1, call(body, "setForwardDirection", dx / length, dy / length))
end

function Body.say(body, text)
    if not Body.isGoblin(body) or type(text) ~= "string" or #text < 1 or #text > 240 then return false, "speech is invalid" end
    local ok = select(1, call(body, "addLineChatElement", text, 0.1, 0.8, 0.1))
    if ok then return true, "speech displayed" end
    local okSay = select(1, call(body, "Say", text))
    return okSay, okSay and "speech displayed" or "speech API unavailable"
end

function Body.snapshot(body)
    if not Body.isGoblin(body) then return nil end
    local data = Body.data(body)
    local okOnline, onlineId = call(body, "getOnlineID")
    if not okOnline or type(onlineId) ~= "number" or onlineId < 0 then onlineId = nil end
    return {
        npc_id = data.GoblinID,
        owner = data.GoblinOwner,
        owner_online = data.GoblinOwnerOnline ~= false,
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
        movement_goal = data.GoblinMovementGoal,
        visual_asset_applied = data.GoblinVisualApplied == true,
        visual_error = data.GoblinVisualError,
        wardrobe = WARDROBE,
        weapon_type = PISTOL,
        weapon_ready = data.GoblinWeaponReady == true,
        infinite_ammo = true,
        autonomous = data.GoblinAutonomous == true,
        last_autonomy_action = data.GoblinLastAutonomyAction,
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

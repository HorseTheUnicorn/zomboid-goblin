-- Narrow combat/tuning layer on top of Astra's working spawn/movement foundation.
-- It deliberately does not touch GoblinSpawner: one persistent spawned body stays
-- exactly as the current main branch creates it.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Movement = require("GoblinSurvivor/GoblinMovement")
local Brain = require("GoblinSurvivor/GoblinBrain")

local Defense = {
    installed = false,
    states = setmetatable({}, { __mode = "k" })
}

local WEAPON = "Base.DoubleBarrelShotgun"
local FOLLOW_DISTANCE = 1
local SHOTGUN_RANGE = 12
local SHOT_COOLDOWN_MS = 800
local SHOT_DAMAGE = 8.0

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

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    return (a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2
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

local function refillShotgun(item)
    if item == nil then return false end
    local okMax, maxAmmo = call(item, "getMaxAmmo")
    maxAmmo = okMax and tonumber(maxAmmo) or 2
    if maxAmmo == nil or maxAmmo < 1 then maxAmmo = 2 end
    -- Double-barrel shotguns do not use a detachable magazine. Keep the two
    -- internal shell slots/chamber ready and repair wear/jams deterministically.
    call(item, "setCurrentAmmoCount", math.floor(maxAmmo))
    call(item, "setRoundChambered", true)
    call(item, "setSpentRoundChambered", false)
    call(item, "setSpentRoundCount", 0)
    call(item, "setJammed", false)
    local okConditionMax, conditionMax = call(item, "getConditionMax")
    if okConditionMax and tonumber(conditionMax) then call(item, "setCondition", tonumber(conditionMax)) end
    return true
end

local function nearestThreat(body)
    local origin = Body.position(body)
    if origin == nil or type(getCell) ~= "function" then return nil end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil then return nil end
    local okList, list = call(cell, "getZombieList")
    if not okList or list == nil then return nil end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    local radius = tonumber(Config.combatRadius) or 20
    local best, bestDistance = nil, radius * radius
    for i = 0, size - 1 do
        local okZombie, candidate = call(list, "get", i)
        if okZombie and candidate ~= nil and candidate ~= body and not Body.isGoblin(candidate) then
            local okDead, dead = call(candidate, "isDead")
            local point = Body.position(candidate)
            if point ~= nil and not (okDead and dead == true) then
                local d = distanceSquared(origin, point)
                if d < bestDistance then
                    best, bestDistance = candidate, d
                end
            end
        end
    end
    return best
end

local function targetIsAlive(target)
    if target == nil or Body.isGoblin(target) then return false end
    local okDead, dead = call(target, "isDead")
    if okDead and dead == true then return false end
    local okHealth, health = call(target, "getHealth")
    if okHealth and tonumber(health) ~= nil and tonumber(health) <= 0 then return false end
    return Body.position(target) ~= nil
end

local function engage(body, target, timestamp)
    local state = Defense.states[body]
    if state == nil or state.target ~= target then
        state = { target = target, nextAttackAt = 0, lastGoal = nil }
        Defense.states[body] = state
    end

    local actor, victim = Body.position(body), Body.position(target)
    if actor == nil or victim == nil then return false, "combat position unavailable" end
    local gap2 = distanceSquared(actor, victim)
    if gap2 > SHOTGUN_RANGE * SHOTGUN_RANGE then
        local needsGoal = state.lastGoal == nil or distanceSquared(state.lastGoal, victim) > 1.0
        if needsGoal or Movement.snapshot(body) == nil then
            Movement.command(body, Constants.TASK.MOVE_TO, { x = victim.x, y = victim.y, z = victim.z })
            state.lastGoal = { x = victim.x, y = victim.y, z = victim.z }
        else
            Movement.update(body, timestamp)
        end
        Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT,
            gap2 >= (tonumber(Config.followRunDistance) or 9)^2 and Constants.MOVE_TYPE.RUN or Constants.MOVE_TYPE.WALK,
            Constants.COMBAT.READY)
        return true, "closing to double-barrel range"
    end

    Movement.clear(body)
    Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.READY)
    if timestamp < (state.nextAttackAt or 0) then return true, "shotgun cooldown" end

    local equipped, detail, shotgun = Body.ensureWeapon(body)
    if not equipped or shotgun == nil then return false, detail end
    Body.refillWeapon(body)
    Body.faceTarget(body, target)
    Body.setCombatPose(body, true)
    Body.setPhysicalState(body, Constants.PHYSICAL.ATTACKING, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.ATTACKING)
    state.nextAttackAt = timestamp + SHOT_COOLDOWN_MS

    local fired = select(1, call(target, "Hit", shotgun, body, SHOT_DAMAGE, false, 1.0, false))
    Body.refillWeapon(body)
    Body.setCombatPose(body, false)
    if not fired then return false, "double-barrel Hit failed" end

    local data = Body.data(body)
    if data ~= nil then
        data.GoblinShotsFired = (tonumber(data.GoblinShotsFired) or 0) + 1
        local dead = not targetIsAlive(target)
        if dead then data.GoblinKills = (tonumber(data.GoblinKills) or 0) + 1 end
    end
    print("[GoblinSurvivor] SHOTGUN_FIRE weapon=" .. WEAPON
        .. " infinite_ammo=true owner=" .. tostring(Body.owner(body)))
    return true, "fired double-barrel shotgun"
end

local function installWeaponOverride()
    function Body.ensureWeapon(body, requestedType)
        if not Body.isGoblin(body) then return false, "body is not Goblin" end
        local inv = inventory(body)
        if inv == nil then return false, "inventory unavailable" end
        local item = findInventoryItem(inv, WEAPON)
        if item == nil then item = ensureInventoryItem(inv, WEAPON) end
        if item == nil then return false, "double-barrel shotgun unavailable" end
        refillShotgun(item)
        -- Build 42 exposes unlimited ammo directly on IsoGameCharacter. Keep
        -- the explicit refill too so server-authoritative direct hits never
        -- strand the gun between replication updates.
        call(body, "setUnlimitedAmmo", true)
        call(body, "setPrimaryHandItem", item)
        call(body, "setSecondaryHandItem", item)
        call(body, "setUseHandWeapon", item)
        call(body, "resetEquippedHandsModels")
        local data = Body.data(body)
        if data ~= nil then
            data.GoblinWeaponType = WEAPON
            data.GoblinWeaponReady = true
            data.GoblinInfiniteAmmo = true
        end
        return true, "double-barrel shotgun equipped with unlimited ammo", item
    end

    function Body.refillWeapon(body)
        local inv = inventory(body)
        if inv == nil then return false end
        local item = findInventoryItem(inv, WEAPON)
        if item == nil then return false end
        call(body, "setUnlimitedAmmo", true)
        return refillShotgun(item)
    end

    local originalSnapshot = Body.snapshot
    function Body.snapshot(body)
        local result = originalSnapshot(body)
        if result ~= nil then
            result.weapon_type = WEAPON
            result.weapon_ready = Body.data(body) ~= nil and Body.data(body).GoblinWeaponReady == true
            result.infinite_ammo = true
            result.kills = Body.data(body) ~= nil and (tonumber(Body.data(body).GoblinKills) or 0) or 0
        end
        return result
    end
end

local function installBrainOverride()
    local originalUpdate = Brain.update
    function Brain.update(body, timestamp)
        if not Body.isGoblin(body) then return originalUpdate(body, timestamp) end
        local data = Body.data(body)
        local task = data ~= nil and (data.GoblinTask or Constants.TASK.FOLLOW) or Constants.TASK.FOLLOW
        local now = timestamp or nowMs()

        -- While following, Goblin is a bodyguard: nearby ordinary zombies are
        -- automatically engaged, then normal follow resumes. Explicit ATTACK
        -- uses the same loop and returns to FOLLOW when the area is clear.
        if task == Constants.TASK.FOLLOW or task == Constants.TASK.ATTACK then
            local state = Defense.states[body]
            local target = state ~= nil and state.target or nil
            if not targetIsAlive(target) then target = nearestThreat(body) end
            if target ~= nil then return engage(body, target, now) end
            Defense.states[body] = nil
            Body.setCombatPose(body, false)
            if task == Constants.TASK.ATTACK then
                Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
                return true, "area clear; following owner"
            end
        end
        return originalUpdate(body, now)
    end
end

local function applyTuning()
    -- Product behavior requested by the owner. Locomotion also enforces one
    -- tile on both server and client so an old config.ini cannot widen it.
    Config.followPreferredDistance = FOLLOW_DISTANCE
    Config.followWalkDistance = math.max(2, tonumber(Config.followWalkDistance) or 2)
    Config.weaponType = WEAPON
    Config.rangedRange = SHOTGUN_RANGE
    Config.rangedCooldownSeconds = SHOT_COOLDOWN_MS / 1000
end

function Defense.install()
    if Defense.installed then return true end
    Defense.installed = true
    applyTuning()

    local originalRefresh = Config.refresh
    Config.refresh = function(...)
        local result = originalRefresh(...)
        applyTuning()
        return result
    end

    installWeaponOverride()
    installBrainOverride()
    print("[GoblinSurvivor] DEFENSE_READY follow=1tile weapon=" .. WEAPON .. " infinite_ammo=true auto_kill=true")
    return true
end

return Defense

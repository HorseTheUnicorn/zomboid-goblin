-- Narrow combat/tuning layer on top of Astra's working spawn/movement foundation.
-- It deliberately does not touch GoblinSpawner: one persistent spawned body stays
-- exactly as the current main branch creates it.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Movement = require("GoblinSurvivor/GoblinMovement")
local Brain = require("GoblinSurvivor/GoblinBrain")
local World = require("GoblinSurvivor/GoblinWorld")

local Defense = {
    installed = false,
    states = setmetatable({}, { __mode = "k" })
}

local WEAPON = "Base.DoubleBarrelShotgun"
local FOLLOW_DISTANCE = 3.0
local SHOTGUN_RANGE = 12
local SHOT_COOLDOWN_MS = 1200
local SHOT_WINDUP_MS = 400
local SHOT_DAMAGE = 8.0
local OWNER_DEFENSE_RADIUS = 5

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

local function nearestThreat(body, origin, radius)
    if origin == nil or type(getCell) ~= "function" then return nil end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil then return nil end
    local okList, list = call(cell, "getZombieList")
    if not okList or list == nil then return nil end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    local best, bestDistance = nil, radius * radius
    for i = 0, size - 1 do
        local okZombie, candidate = call(list, "get", i)
        if okZombie and candidate ~= nil and candidate ~= body and not Body.isGoblin(candidate) then
            local okDead, dead = call(candidate, "isDead")
            local point = Body.position(candidate)
            local _, health = call(candidate, "getHealth")
            if point ~= nil and math.floor(point.z) == math.floor(origin.z) and not (okDead and dead == true)
                and not (type(health)=="number" and health<=0) then
                local d = distanceSquared(origin, point)
                if d <= bestDistance then
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

local function engage(body, target, timestamp, allowChase)
    local state = Defense.states[body]
    if state == nil or state.target ~= target then
        state = { target = target, nextAttackAt = 0, lastGoal = nil,
            taskSequence=Body.data(body).GoblinTaskSequence }
        Defense.states[body] = state
    end

    local actor, victim = Body.position(body), Body.position(target)
    if actor == nil or victim == nil then return false, "combat position unavailable" end
    local visible, result = pcall(function()
        return tostring(LosUtil.lineClear(getCell(),math.floor(actor.x),math.floor(actor.y),math.floor(actor.z),
            math.floor(victim.x),math.floor(victim.y),math.floor(victim.z),false))
    end)
    if not visible then return false, "could not check the line of fire" end
    local blocked=result~="Clear"
    local gap2 = distanceSquared(actor, victim)
    if blocked or gap2 > SHOTGUN_RANGE * SHOTGUN_RANGE then
        state.fireAt=nil
        Body.setCombatPose(body,false)
        if not allowChase then
            Defense.states[body] = nil
            return false, "following owner; no clear shot in range"
        end
        state.approachAt=state.approachAt or timestamp
        if timestamp-state.approachAt>=45000 then return false,"could not reach a clear firing position; clear a path and try again" end
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
        return true, blocked and "approaching the zombie for a clear shot" or "closing to double-barrel range"
    end
    state.approachAt=nil

    Movement.clear(body)
    Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.READY)
    local equipped, detail, shotgun = Body.ensureWeapon(body)
    if not equipped or shotgun == nil then return false, detail end
    Body.faceTarget(body, target)
    if not state.fireAt then
        if timestamp < (state.nextAttackAt or 0) then
            Body.setCombatPose(body, false)
            return true, "shotgun recovery"
        end
        Body.setCombatPose(body, true)
        local data = Body.data(body)
        data.GoblinActionSequence = (tonumber(data.GoblinActionSequence) or 0)+1
        state.fireAt = timestamp + SHOT_WINDUP_MS
        state.nextAttackAt = timestamp + SHOT_COOLDOWN_MS
        if type(sendServerCommand) == "function" then
            pcall(sendServerCommand,"GoblinSurvivor","combat",{
                npc_id=Body.npcId(body),generation=data.GoblinGeneration,
                sequence=data.GoblinActionSequence,x=victim.x,y=victim.y,
                windup_ms=SHOT_WINDUP_MS,duration_ms=850
            })
        end
        return true, "aiming double-barrel shotgun"
    end
    if timestamp < state.fireAt then return true, "aiming double-barrel shotgun" end
    -- Range, line-of-sight, owner leash and life are revalidated every update
    -- above, including this impact tick. No instant invisible damage on acquire.
    state.fireAt = nil
    Body.refillWeapon(body)
    Body.setPhysicalState(body, Constants.PHYSICAL.ATTACKING, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.ATTACKING)

    local _,before=call(target,"getHealth")
    local fired,damage = call(target, "Hit", shotgun, body, SHOT_DAMAGE, false, 1.0, false)
    local _,after=call(target,"getHealth")
    Body.refillWeapon(body)
    Body.setCombatPose(body, false)
    if not fired then return false, "double-barrel Hit failed" end
    if type(before)=="number" and type(after)=="number" and after>=before and targetIsAlive(target) then
        print("[GoblinSurvivor] SHOT_NO_DAMAGE owner="..tostring(Body.owner(body)).." hit_result="..tostring(damage))
        return false,"the shot did not damage that zombie"
    end

    local data = Body.data(body)
    if data ~= nil then
        data.GoblinShotsFired = (tonumber(data.GoblinShotsFired) or 0) + 1
        local dead = not targetIsAlive(target)
        if dead then data.GoblinKills = (tonumber(data.GoblinKills) or 0) + 1 end
    end
    print("[GoblinSurvivor] SHOTGUN_FIRE weapon=" .. WEAPON
        .. " infinite_ammo=true owner=" .. tostring(Body.owner(body))
        .. " health_before="..tostring(before).." health_after="..tostring(after).." hit_result="..tostring(damage))
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
        local previous=Defense.states[body]
        if previous and previous.taskSequence~=data.GoblinTaskSequence then
            Defense.states[body]=nil
            Body.setCombatPose(body,false)
        end
        -- Boarding/riding has priority over automatic defense. Explicit combat
        -- ordered aboard is queued until Transport performs a safe exit.
        if data and (data.GoblinRide or data.GoblinTransportActive
            or task=="ENTER_VEHICLE" or task=="EXIT_VEHICLE") then
            Defense.states[body]=nil
            Body.setCombatPose(body,false)
            return originalUpdate(body,now)
        end
        local automatic = task == Constants.TASK.FOLLOW or data.GoblinAutonomous == true

        -- Automatic defense is centered on the PLAYER, not Goblin. Recompute
        -- this every tick so moving owners and escaping targets cannot extend
        -- the leash. An explicit ATTACK is the only online radius override.
        local origin, radius = Body.position(body), tonumber(Config.combatRadius) or 20
        if automatic then
            origin, radius = nil, OWNER_DEFENSE_RADIUS
            for _, player in ipairs(World.values(getOnlinePlayers())) do
                if string.lower(player:getUsername()) == string.lower(Body.owner(body)) then
                    if select(2,call(player,"getVehicle")) then return originalUpdate(body,now) end
                    origin = Body.position(player)
                    break
                end
            end
            if origin == nil then
                Defense.states[body] = nil
                Body.setCombatPose(body, false)
                return originalUpdate(body, now)
            end
        end

        -- While following, Goblin is a bodyguard: nearby ordinary zombies are
        -- automatically engaged, then normal follow resumes. Explicit ATTACK
        -- uses the same loop and returns to FOLLOW when the area is clear.
        if automatic or task == Constants.TASK.ATTACK then
            local state = Defense.states[body]
            local target = state ~= nil and state.target or nil
            local point = target and Body.position(target)
            if not targetIsAlive(target) or (automatic and
                (not point or math.floor(point.z) ~= math.floor(origin.z) or distanceSquared(point,origin) > radius*radius)) then
                target = nearestThreat(body, origin, radius)
            end
            if target ~= nil then
                local engaged, detail = engage(body, target, now, task == Constants.TASK.ATTACK)
                if engaged then return engaged, detail end
                if task == Constants.TASK.ATTACK then
                    Defense.states[body]=nil
                    Body.setCombatPose(body,false)
                    Brain.setTask(body,Constants.TASK.FOLLOW,{owner=Body.owner(body)})
                    Body.say(body,"Comrade, "..tostring(detail).."; returning to you.")
                    print("[GoblinSurvivor] ATTACK_FAILED owner="..tostring(Body.owner(body)).." detail="..tostring(detail))
                    return false,detail
                end
            end
            Defense.states[body] = nil
            Body.setCombatPose(body, false)
            if task == Constants.TASK.ATTACK then
                Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
                Body.say(body,"Comrade, no live zombie remains in my search range; returning to you.")
                return true, "no live zombie in search range; following owner"
            end
        end
        return originalUpdate(body, now)
    end
end

local function applyTuning()
    -- Locomotion enforces the same three tiles on the simulation-owning client.
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
    print("[GoblinSurvivor] DEFENSE_READY follow=" .. FOLLOW_DISTANCE .. "tiles weapon=" .. WEAPON .. " infinite_ammo=true defense=5tiles_from_owner")
    return true
end

return Defense

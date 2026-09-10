-- Deterministic Goblin task controller.
--
-- Qwen may select a high-level action, but this module owns task validation,
-- target resolution, physical-state transitions, and recovery.  It never
-- accepts coordinates or animation names from the model; debug commands may
-- supply a bounded numeric location through the explicit server command path.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Movement = require("GoblinSurvivor/GoblinMovement")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
local Loot = require("GoblinSurvivor/GoblinLoot")

local Brain = { combat = setmetatable({}, { __mode = "k" }) }

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, first = pcall(member, object, ...)
    return ok, first
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

local function numeric(value)
    return type(value) == "number" and value == value and value ~= math.huge
        and value ~= -math.huge
end

local function data(body)
    return Body.data(body)
end

local function payloadEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local aItem, bItem = a.item, b.item
    local itemEqual = aItem == bItem
    if type(aItem) == "table" or type(bItem) == "table" then
        itemEqual = type(aItem) == "table" and type(bItem) == "table"
            and aItem.name == bItem.name and aItem.count == bItem.count
    end
    local aTarget, bTarget = a.target, b.target
    local targetEqual = aTarget == bTarget
    if type(aTarget) == "table" or type(bTarget) == "table" then
        targetEqual = type(aTarget) == "table" and type(bTarget) == "table"
            and aTarget.kind == bTarget.kind and aTarget.name == bTarget.name
            and aTarget.label == bTarget.label and aTarget.player == bTarget.player
    end
    return a.x == b.x and a.y == b.y and a.z == b.z and a.owner == b.owner
        and a.text == b.text and a.loot_focus == b.loot_focus and targetEqual and itemEqual
end

local function playerFor(name)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return nil end
    local count = type(list.size) == "function" and list:size() or #list
    local wanted = type(name) == "string" and string.lower(name) or nil
    for index = 0, count - 1 do
        local player = type(list.get) == "function" and list:get(index) or list[index + 1]
        if player ~= nil then
            local okName, username = call(player, "getUsername")
            if wanted == nil then return player end
            if okName and type(username) == "string" and string.lower(username) == wanted then
                return player
            end
        end
    end
    return nil
end

local function position(object)
    return Body.position(object)
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2
end

local function nearestThreat(body)
    local origin = position(body)
    if origin == nil or type(getCell) ~= "function" then return nil end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil then return nil end
    local okList, list = call(cell, "getZombieList")
    if not okList or list == nil then return nil end
    local count = type(list.size) == "function" and list:size() or #list
    local radius = tonumber(Config.combatRadius) or 16
    local closest, closestDistance = nil, radius * radius
    for index = 0, count - 1 do
        local candidate = type(list.get) == "function" and list:get(index) or list[index + 1]
        if candidate ~= nil and candidate ~= body then
            local candidateData = Body.data(candidate)
            local okDead, dead = call(candidate, "isDead")
            local okPlayer, isPlayer = call(candidate, "isPlayer")
            local targetPoint = position(candidate)
            if targetPoint ~= nil and not (okDead and dead == true)
                and not (okPlayer and isPlayer == true)
                and not (candidateData ~= nil and candidateData.GoblinNPC == true) then
                local d = distanceSquared(origin, targetPoint)
                if d < closestDistance then closest, closestDistance = candidate, d end
            end
        end
    end
    return closest
end

local function liveTarget(target)
    if target == nil or not Body.exists(target) then return false end
    local okDead, dead = call(target, "isDead")
    if okDead and dead == true then return false end
    local okPlayer, isPlayer = call(target, "isPlayer")
    return not (okPlayer and isPlayer == true)
end

local function targetWithinCombatRadius(body, target)
    local actor, victim = position(body), position(target)
    local radius = tonumber(Config.combatRadius) or 16
    return actor ~= nil and victim ~= nil
        and distanceSquared(actor, victim) <= radius * radius
end

local function clearAttack(body)
    local bodyData = data(body)
    local hadTarget = bodyData ~= nil and bodyData.GoblinCombatTarget ~= nil
    Brain.combat[body] = nil
    Body.setCombatPose(body, false)
    Movement.clear(body)
    call(body, "setTarget", nil)
    call(body, "setAttackTargetSquare", nil)
    call(body, "setVariable", "GoblinCombatState", Constants.COMBAT.NONE)
    if bodyData ~= nil then
        bodyData.GoblinCombatTarget = nil
        bodyData.GoblinCombatTargetSeenAt = nil
    end
    if hadTarget then log("TARGET_CHANGE id=" .. Config.npcId .. " target=none") end
end

local function applyMeleeHit(body, state, timestamp)
    if state.impactApplied then return true, "melee impact already applied" end
    state.impactApplied = true
    local target = state.target
    if not liveTarget(target) then return false, "combat target disappeared before impact" end
    local actor, victim = position(body), position(target)
    local range = tonumber(Config.meleeRange) or 2.25
    if actor == nil or victim == nil or distanceSquared(actor, victim) > (range + 0.75) ^ 2 then
        return false, "combat target moved out of melee range"
    end
    local equipped, equipDetail, weapon = Body.ensureWeapon(body)
    if not equipped or weapon == nil then
        return false, equipDetail or "preferred weapon is unavailable at impact"
    end
    if type(target.Hit) ~= "function" then
        return false, "IsoZombie target Hit() API is unavailable"
    end
    -- Hit() is the normal server-authoritative weapon path.  It applies the
    -- real item's damage/death rules and is deliberately the only health
    -- mutation route in this controller.
    local ok, errorValue = pcall(target.Hit, target, weapon, body, 1.0, false, 1.0, false)
    local bodyData = data(body)
    if not ok then
        if bodyData ~= nil then
            bodyData.GoblinLastCombatError = tostring(errorValue)
            bodyData.GoblinCombatAvailable = false
        end
        return false, "target.Hit failed: " .. tostring(errorValue)
    end
    if bodyData ~= nil then
        bodyData.GoblinLastCombatError = nil
        bodyData.GoblinCombatAvailable = true
        bodyData.GoblinMeleeAttacks = (tonumber(bodyData.GoblinMeleeAttacks) or 0) + 1
        bodyData.GoblinLastCombatAt = timestamp
        bodyData.GoblinLastCombatResult = "hit"
    end
    local okDead, dead = call(target, "isDead")
    if okDead and dead == true and not state.killCounted then
        state.killCounted = true
        if bodyData ~= nil then
            bodyData.GoblinMeleeKills = (tonumber(bodyData.GoblinMeleeKills) or 0) + 1
        end
        log("KILL id=" .. Config.npcId .. " weapon=" .. tostring(Config.weaponType))
    end
    log("MELEE_HIT id=" .. Config.npcId .. " weapon=" .. tostring(Config.weaponType))
    return true, "server-authoritative melee hit applied"
end

local function finishCombatPose(body, state)
    Body.setCombatPose(body, false)
    state.poseUntil = nil
    state.impactAt = nil
    state.impactApplied = false
    if liveTarget(state.target) then
        Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.READY)
    else
        clearAttack(body)
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
    end
end

local function executeAttack(body, timestamp)
    -- Combat is bounded to a nearby ordinary zombie and uses the real item
    -- Hit() path.  We never assign the IsoZombie native hostile target, bite,
    -- lunge, or eat-body fields.
    local now = timestamp or nowMs()
    local state = Brain.combat[body]
    if state ~= nil and not liveTarget(state.target) then
        Body.setCombatPose(body, false)
        state = nil
        Brain.combat[body] = nil
    end
    if state == nil then
        local target = nearestThreat(body)
        if target == nil then
            clearAttack(body)
            Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
                Constants.COMBAT.NONE)
            return false, "no nearby hostile zombie"
        end
        state = {
            target = target,
            targetSeenAt = now,
            nextAttackAt = 0,
            poseUntil = nil,
            impactAt = nil,
            impactApplied = false,
            killCounted = false
        }
        Brain.combat[body] = state
        local bodyData = data(body)
        if bodyData ~= nil then
            bodyData.GoblinCombatTarget = "nearby_hostile"
            bodyData.GoblinCombatTargetSeenAt = now
        end
        log("TARGET_CHANGE id=" .. Config.npcId .. " target=nearby_hostile")
    elseif now - (state.targetSeenAt or 0)
        >= (tonumber(Config.combatTargetRefreshSeconds) or 0.5) * 1000 then
        -- Refresh the bounded semantic target periodically.  A zombie that
        -- leaves the combat radius is dropped instead of turning ATTACK into
        -- an unbounded chase; a newly nearer zombie may replace it without
        -- ever touching IsoZombie's native hostile target field.
        local replacement = nearestThreat(body)
        state.targetSeenAt = now
        if replacement ~= nil and replacement ~= state.target then
            state.target = replacement
            state.impactApplied = false
            state.killCounted = false
            local bodyData = data(body)
            if bodyData ~= nil then bodyData.GoblinCombatTargetSeenAt = now end
            log("TARGET_CHANGE id=" .. Config.npcId .. " target=nearby_hostile")
        elseif not targetWithinCombatRadius(body, state.target) then
            clearAttack(body)
            Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
                Constants.COMBAT.NONE)
            return false, "no nearby hostile zombie"
        end
    end

    local equipped, equipDetail = Body.ensureWeapon(body)
    if not equipped then
        clearAttack(body)
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
        return false, equipDetail or "preferred weapon is unavailable"
    end
    local actor, victim = position(body), position(state.target)
    if actor == nil or victim == nil then
        clearAttack(body)
        return false, "combat positions are unavailable"
    end
    local gap = math.sqrt(distanceSquared(actor, victim))
    local range = tonumber(Config.meleeRange) or 2.25
    if gap > range then
        if state.poseUntil ~= nil then finishCombatPose(body, state) end
        local started, startDetail = Movement.commandCombat(body, state.target)
        local updated, updateDetail = Movement.updateCombat(body, now)
        if updated == false and updateDetail ~= nil then
            local bodyData = data(body)
            if bodyData ~= nil then bodyData.GoblinLastMovementError = updateDetail end
        end
        return started or updated, updateDetail or startDetail or "closing on combat target"
    end

    local movement = Movement.snapshot(body)
    if movement ~= nil and movement.task == Constants.TASK.ATTACK then
        Movement.clear(body)
    end
    if state.poseUntil ~= nil then
        Body.setPhysicalState(body, Constants.PHYSICAL.ATTACKING, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.ATTACKING)
        if now >= (state.impactAt or math.huge) and not state.impactApplied then
            local hit, detail = applyMeleeHit(body, state, now)
            if not hit then
                local bodyData = data(body)
                if bodyData ~= nil then
                    bodyData.GoblinLastCombatResult = "miss"
                    bodyData.GoblinLastCombatError = detail
                end
                log("MELEE_MISS id=" .. Config.npcId .. " detail=" .. tostring(detail))
            end
        end
        if now >= (state.poseUntil or math.huge) then finishCombatPose(body, state) end
        return true, "melee pose active"
    end
    if now < (state.nextAttackAt or 0) then
        Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.READY)
        return true, "melee cooldown active"
    end
    Body.faceTarget(body, state.target)
    Body.setCombatPose(body, true)
    Body.setPhysicalState(body, Constants.PHYSICAL.ATTACKING, Constants.MOVE_TYPE.IDLE,
        Constants.COMBAT.ATTACKING)
    state.poseUntil = now + (tonumber(Config.meleePoseSeconds) or 0.7) * 1000
    state.impactAt = now + (tonumber(Config.meleeImpactDelaySeconds) or 0.325) * 1000
    state.impactApplied = false
    state.nextAttackAt = now + (tonumber(Config.meleeCooldownSeconds) or 1.0) * 1000
    log("ATTACK id=" .. Config.npcId .. " weapon=" .. tostring(Config.weaponType)
        .. " range=" .. tostring(range))
    return true, "melee attack pose started"
end

function Brain.setTask(body, task, payload)
    if not Body.isGoblin(body) then return false, "Goblin body is not present" end
    if not Constants.ALLOWED_TASKS[task] then return false, "unsupported Goblin task" end
    payload = type(payload) == "table" and payload or {}
    if task == Constants.TASK.MOVE_TO or task == Constants.TASK.GUARD then
        if not numeric(payload.x) or not numeric(payload.y) or not numeric(payload.z) then
            return false, "movement target is invalid"
        end
    end
    if task == Constants.TASK.FOLLOW or task == Constants.TASK.RETURN_TO_OWNER then
        if payload.owner ~= nil and (type(payload.owner) ~= "string" or #payload.owner > 96) then
            return false, "owner target is invalid"
        end
        if payload.owner ~= nil
            and string.find(payload.owner, "^[A-Za-z0-9_%-]+$") == nil then
            return false, "owner target is invalid"
        end
        if payload.owner ~= nil then
            -- An explicit owner change must resolve to a currently connected
            -- player.  This prevents a high-level semantic label from
            -- silently replacing the persisted owner with an offline name;
            -- the no-payload form continues to use the saved owner during
            -- reconnect/restart recovery.
            if playerFor(payload.owner) == nil then return false, "owner is offline" end
            Spawner.setOwner(payload.owner)
        end
    end
    if task == Constants.TASK.EQUIP then
        local requested = type(payload.item) == "table" and payload.item.name or nil
        if requested ~= Config.weaponType then
            return false, "only the configured preferred weapon is permitted"
        end
    end
    if task == Constants.TASK.LOOT and payload.loot_focus ~= nil then
        local focus = string.lower(tostring(payload.loot_focus))
        if focus ~= "food" and focus ~= "medical" and focus ~= "tools"
            and focus ~= "ammo" and focus ~= "surprise" then
            return false, "unsupported loot focus"
        end
        payload.loot_focus = focus
    end
    local bodyData = data(body)
    if bodyData == nil then return false, "Goblin ModData is unavailable" end
    local changed = bodyData.GoblinTask ~= task
        or not payloadEqual(bodyData.GoblinTaskPayload, payload)
    if not changed then return true, "task already active" end
    if not Body.setTask(body, task, payload) then return false, "task could not be stored" end
    if not Spawner.setTask(task, payload) then return false, "task could not be persisted" end
    log("TASK_CHANGE id=" .. Config.npcId .. " task=" .. tostring(task))
    if task ~= Constants.TASK.ATTACK and Brain.combat[body] ~= nil then
        Body.setCombatPose(body, false)
        Brain.combat[body] = nil
    end
    if task == Constants.TASK.EQUIP then
        -- Stop any previous follow/path goal before changing the held item.
        -- A task switch must never leave PathFindBehavior2 moving the body
        -- while the physical state says EQUIP/IDLE.
        Movement.clear(body)
        local requested = type(payload.item) == "table" and payload.item.name or nil
        local ok, detail = Body.ensureWeapon(body, requested)
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
        return ok, detail
    end
    if task == Constants.TASK.SPEAK then
        Movement.clear(body)
        local ok, detail = Body.say(body, payload.text)
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
        return ok, detail
    end
    if task == Constants.TASK.ATTACK then
        Movement.clear(body)
        return executeAttack(body, nowMs())
    end
    if task == Constants.TASK.LOOT then
        Movement.clear(body)
        Body.setPhysicalState(body, Constants.PHYSICAL.LOOTING, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
        return Loot.scan(body, payload, nowMs())
    end
    return Movement.command(body, task, payload)
end

function Brain.execute(message, body)
    if not Body.isGoblin(body) then return false, "Goblin body is not present" end
    if type(message) ~= "table" or type(message.action) ~= "string" then
        return false, "Goblin command is malformed"
    end
    local action = string.upper(message.action)
    if action == "SAY" then
        return Brain.setTask(body, Constants.TASK.SPEAK, { text = message.text })
    end
    if action == "EQUIP" then
        local item = type(message.item) == "table" and message.item or nil
        return Brain.setTask(body, Constants.TASK.EQUIP, { item = item })
    end
    if action == "WAIT" or action == "NOOP" or action == "HOLD_POSITION"
        or action == "REST" then
        return Brain.setTask(body, Constants.TASK.WAIT, {})
    end
    if action == "FOLLOW" or action == "REGROUP" or action == "RETURN_TO_BASE"
        or action == "RETURN" then
        local owner = type(message.owner) == "string" and message.owner or nil
        return Brain.setTask(body, Constants.TASK.FOLLOW, { owner = owner })
    end
    if action == "ATTACK" then
        return Brain.setTask(body, Constants.TASK.ATTACK, {})
    end
    if action == "LOOT" or action == "LOOT_AREA" or action == "SCAVENGE" then
        return Brain.setTask(body, Constants.TASK.LOOT, {
            loot_focus = type(message.loot_focus) == "string" and message.loot_focus or nil,
            target = type(message.target) == "table" and message.target or nil
        })
    end
    if action == "MOVE_TO" or action == "GUARD" then
        -- Only developer commands carry exact coordinates.  Qwen-originated
        -- semantic targets are resolved by the Python/server bridge to FOLLOW
        -- or WAIT before they reach this method.
        return Brain.setTask(body, action, {
            x = message.x, y = message.y, z = message.z,
            owner = message.owner
        })
    end
    return false, "unsupported Goblin command"
end

function Brain.update(body, timestamp)
    if not Body.isGoblin(body) then return false end
    local bodyData = data(body)
    if bodyData == nil then return false end
    local task = bodyData.GoblinTask or Constants.TASK.FOLLOW
    local payload = bodyData.GoblinTaskPayload or {}
    local healthState = Body.observeHealth(body, timestamp or nowMs())
    if healthState == "hit" or healthState == "recovering" then return true end
    if healthState == "recovered" then
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
    end
    if task == Constants.TASK.ATTACK then
        return executeAttack(body, timestamp or nowMs())
    end
    if task == Constants.TASK.EQUIP then
        Movement.clear(body)
        local requested = type(payload.item) == "table" and payload.item.name or nil
        Body.ensureWeapon(body, requested)
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
        return true
    end
    if task == Constants.TASK.SPEAK or task == Constants.TASK.WAIT then
        Movement.clear(body)
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
        return true
    end
    if task == Constants.TASK.LOOT then
        Movement.clear(body)
        Body.setPhysicalState(body, Constants.PHYSICAL.LOOTING, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
        local ok, detail = Loot.scan(body, payload, timestamp or nowMs())
        if not ok then bodyData.GoblinLastLootError = detail end
        return ok
    end
    local movement = Movement.snapshot(body)
    if movement ~= nil and movement.task == task and movement.complete == true then
        return true
    end
    if movement == nil or movement.task ~= task then
        Movement.command(body, task, payload)
    end
    local ok, detail = Movement.update(body, timestamp or nowMs())
    if ok == false and detail ~= nil then
        local state = Body.data(body)
        if state ~= nil then state.GoblinLastMovementError = detail end
    end
    return ok ~= false
end

function Brain.snapshot(body)
    local result = Body.snapshot(body)
    if result == nil then return nil end
    local movement = Movement.snapshot(body)
    if movement ~= nil then result.movement = movement end
    return result
end

return Brain

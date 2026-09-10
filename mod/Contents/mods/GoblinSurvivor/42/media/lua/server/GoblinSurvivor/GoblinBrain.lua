-- Deterministic per-body Goblin task controller.
-- Qwen chooses semantic actions; this file resolves actual PZ work.
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

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

local function log(body, text)
    if type(print) == "function" then
        print("[GoblinSurvivor] " .. tostring(text)
            .. " owner=" .. tostring(Body.owner(body))
            .. " npc_id=" .. tostring(Body.npcId(body)))
    end
end

local function playerForOwner(body)
    local owner = Body.owner(body)
    if type(owner) ~= "string" or type(getOnlinePlayers) ~= "function" then return nil end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return nil end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    for i = 0, size - 1 do
        local okPlayer, player = call(list, "get", i)
        if okPlayer and player ~= nil then
            local okName, name = call(player, "getUsername")
            if okName and type(name) == "string" and string.lower(name) == string.lower(owner) then return player end
        end
    end
    return nil
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    return (a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2
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
                if d < bestDistance then best, bestDistance = candidate, d end
            end
        end
    end
    return best
end

local function executeAttack(body, timestamp)
    local now = timestamp or nowMs()
    local state = Brain.combat[body]
    if state == nil or state.target == nil or not Body.exists(state.target) or Body.isGoblin(state.target) then
        local target = nearestThreat(body)
        if target == nil then
            Brain.combat[body] = nil
            Body.setCombatPose(body, false)
            Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
            return true, "no hostile nearby; returning to owner"
        end
        state = { target = target, nextAttackAt = 0 }
        Brain.combat[body] = state
    end

    local actor, victim = Body.position(body), Body.position(state.target)
    if actor == nil or victim == nil then return false, "combat position unavailable" end
    local range = tonumber(Config.rangedRange) or 16
    local gap2 = distanceSquared(actor, victim)

    if gap2 > range * range then
        Movement.command(body, Constants.TASK.MOVE_TO, { x = victim.x, y = victim.y, z = victim.z })
        Movement.update(body, now)
        Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT,
            gap2 >= (tonumber(Config.followRunDistance) or 9)^2 and Constants.MOVE_TYPE.RUN or Constants.MOVE_TYPE.WALK,
            Constants.COMBAT.READY)
        return true, "closing to pistol range"
    end

    Movement.clear(body)
    Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.READY)
    if now < (state.nextAttackAt or 0) then return true, "shot cooldown" end

    local equipped, detail, pistol = Body.ensureWeapon(body)
    if not equipped or pistol == nil then return false, detail end
    Body.refillWeapon(body)
    Body.faceTarget(body, state.target)
    Body.setCombatPose(body, true)
    Body.setPhysicalState(body, Constants.PHYSICAL.ATTACKING, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.ATTACKING)
    state.nextAttackAt = now + (tonumber(Config.rangedCooldownSeconds) or 0.55) * 1000

    local fired = false
    if type(state.target.Hit) == "function" then
        local ok = pcall(state.target.Hit, state.target, pistol, body, 1.75, false, 1.0, false)
        fired = ok == true
    end
    Body.refillWeapon(body)
    Body.setCombatPose(body, false)
    if fired then
        local data = Body.data(body)
        if data ~= nil then data.GoblinShotsFired = (tonumber(data.GoblinShotsFired) or 0) + 1 end
        log(body, "PISTOL_FIRE weapon=Base.Pistol3 infinite_ammo=true")
        return true, "fired D-E pistol"
    end
    return false, "pistol Hit failed"
end

local function setTaskInternal(body, task, payload)
    if not Body.isGoblin(body) then return false, "Goblin body is not present" end
    if Constants.ALLOWED_TASKS[task] ~= true then return false, "unsupported task" end
    payload = type(payload) == "table" and payload or {}
    if task ~= Constants.TASK.ATTACK then
        Brain.combat[body] = nil
        Body.setCombatPose(body, false)
    end
    if not Spawner.setTask(body, task, payload) then return false, "task could not be persisted" end

    if task == Constants.TASK.WAIT then
        Movement.clear(body)
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
        return true, "waiting"
    end
    if task == Constants.TASK.SPEAK then
        Movement.clear(body)
        return Body.say(body, payload.text)
    end
    if task == Constants.TASK.EQUIP then
        Movement.clear(body)
        return Body.ensureWeapon(body)
    end
    if task == Constants.TASK.SET_BASE then
        Movement.clear(body)
        local player = playerForOwner(body)
        if player == nil then return false, "owner is offline" end
        local ok, detail = Spawner.setBaseForPlayer(player)
        if ok then
            Spawner.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
            Body.say(body, "Base noted. The revolution now has an address.")
        end
        return ok, detail
    end
    if task == Constants.TASK.LOOT then
        Movement.clear(body)
        local data = Body.data(body)
        if data ~= nil then data.GoblinLootPhase = "collect" end
        Body.setPhysicalState(body, Constants.PHYSICAL.LOOTING, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
        return true, "loot cycle started"
    end
    if task == Constants.TASK.ATTACK then
        Movement.clear(body)
        return executeAttack(body, nowMs())
    end
    return Movement.command(body, task, payload)
end

function Brain.setTask(body, task, payload)
    local ok, detail = setTaskInternal(body, task, payload)
    if ok then log(body, "TASK_CHANGE task=" .. tostring(task)) end
    return ok, detail
end

function Brain.execute(message, body)
    if not Body.isGoblin(body) then return false, "Goblin body is not present" end
    if type(message) ~= "table" or type(message.action) ~= "string" then return false, "malformed Goblin command" end
    local action = string.upper(message.action)
    if action == "SAY" then return Brain.setTask(body, Constants.TASK.SPEAK, { text = message.text }) end
    if action == "EQUIP" then return Brain.setTask(body, Constants.TASK.EQUIP, {}) end
    if action == "WAIT" or action == "NOOP" or action == "HOLD_POSITION" or action == "REST" then return Brain.setTask(body, Constants.TASK.WAIT, {}) end
    if action == "FOLLOW" or action == "FOLLOW_GOBLIN" or action == "REGROUP" or action == "HELP" or action == "DEFEND_PLAYER" then
        return Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
    end
    if action == "SET_BASE" or action == "REMEMBER_BASE" or action == "SECURE_BASE" then return Brain.setTask(body, Constants.TASK.SET_BASE, {}) end
    if action == "RETURN_TO_BASE" or action == "GO_HOME" or action == "RETURN" then return Brain.setTask(body, Constants.TASK.RETURN_TO_BASE, {}) end
    if action == "LOOT" or action == "LOOT_AREA" or action == "SCAVENGE" or action == "SEARCH" then
        return Brain.setTask(body, Constants.TASK.LOOT, { loot_focus = type(message.loot_focus) == "string" and message.loot_focus or "surprise" })
    end
    if action == "ATTACK" or action == "DEFEND_AREA" or action == "CLEAR_BUILDING" then return Brain.setTask(body, Constants.TASK.ATTACK, {}) end
    if action == "MOVE_TO" and type(message.x) == "number" and type(message.y) == "number" and type(message.z) == "number" then
        return Brain.setTask(body, Constants.TASK.MOVE_TO, { x = message.x, y = message.y, z = message.z })
    end
    return false, "unsupported Goblin action"
end

local function updateLoot(body, payload, timestamp)
    local data = Body.data(body)
    if data == nil then return false end
    if (data.GoblinLootPhase or "collect") == "collect" then
        Body.setPhysicalState(body, Constants.PHYSICAL.LOOTING, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
        local ok, detail, moved = Loot.collect(body, payload, timestamp)
        if not ok then return false, detail end
        if (tonumber(moved) or 0) <= 0 and not Loot.hasCargo(body) then
            Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
            return true, "nothing useful found; following owner"
        end
        if data.GoblinBaseSet == true then
            data.GoblinLootPhase = "return"
            Spawner.setTask(body, Constants.TASK.RETURN_TO_BASE, { from_loot = true, autonomous = payload.autonomous == true })
            Movement.command(body, Constants.TASK.RETURN_TO_BASE, {})
            return true, "loot collected; returning to base"
        end
        Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
        return true, "loot collected; base not set"
    end
    return true, "loot cycle active"
end

local function updateReturnToBase(body, payload, timestamp)
    local ok, detail = Movement.update(body, timestamp)
    if not ok and detail ~= "idle" then return false, detail end
    local data = Body.data(body)
    local base = data ~= nil and data.GoblinBaseSet == true and {
        x = tonumber(data.GoblinBaseX), y = tonumber(data.GoblinBaseY), z = tonumber(data.GoblinBaseZ)
    } or nil
    local point = Body.position(body)
    if base == nil or point == nil or base.x == nil or base.y == nil or base.z == nil then return false, "base unavailable" end
    if distanceSquared(point, base) <= 2.25 then
        local delivered, deliveryDetail = Loot.deposit(body)
        if data ~= nil then data.GoblinLootPhase = nil end
        Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
        if delivered then Body.say(body, "Supplies redistributed to the collective. Mostly yours, comrade.") end
        return true, deliveryDetail
    end
    return true, "returning to base"
end

function Brain.update(body, timestamp)
    if not Body.isGoblin(body) then return false end
    Body.applyInvariants(body)
    local data = Body.data(body)
    if data == nil then return false end
    local task = data.GoblinTask or Constants.TASK.FOLLOW
    local payload = type(data.GoblinTaskPayload) == "table" and data.GoblinTaskPayload or {}
    local now = timestamp or nowMs()
    if task == Constants.TASK.WAIT or task == Constants.TASK.SPEAK or task == Constants.TASK.EQUIP then return true end
    if task == Constants.TASK.LOOT then return updateLoot(body, payload, now) end
    if task == Constants.TASK.RETURN_TO_BASE then
        if Movement.snapshot(body) == nil then Movement.command(body, task, payload) end
        return updateReturnToBase(body, payload, now)
    end
    if task == Constants.TASK.ATTACK then return executeAttack(body, now) end
    if task == Constants.TASK.SET_BASE then
        local player = playerForOwner(body)
        if player == nil then return false end
        Spawner.setBaseForPlayer(player)
        Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
        return true
    end
    local movement = Movement.snapshot(body)
    if movement == nil or movement.task ~= task then Movement.command(body, task, payload) end
    return Movement.update(body, now)
end

function Brain.snapshot(body)
    local result = Body.snapshot(body)
    if result == nil then return nil end
    result.movement = Movement.snapshot(body)
    return result
end

return Brain

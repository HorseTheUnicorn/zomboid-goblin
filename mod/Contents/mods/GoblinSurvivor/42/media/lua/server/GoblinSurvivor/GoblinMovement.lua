-- Deterministic movement controller for the single Goblin IsoZombie.
--
-- PathFindBehavior2 owns path calculation and collision handling.  This file
-- only starts/cancels goals, selects walk/run hysteresis, and translates the
-- native result into Goblin physical states.  It never steps coordinates and
-- deliberately does not enter fence/window climb states; the first stable
-- companion can route around those obstacles.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Spawner = require("GoblinSurvivor/GoblinSpawner")

local Movement = { active = setmetatable({}, { __mode = "k" }) }

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

local function players()
    if type(getOnlinePlayers) ~= "function" then return {} end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return {} end
    local count = type(list.size) == "function" and list:size() or #list
    local result = {}
    for index = 0, count - 1 do
        local player = type(list.get) == "function" and list:get(index) or list[index + 1]
        if player ~= nil then result[#result + 1] = player end
    end
    return result
end

local function username(player)
    local ok, value = call(player, "getUsername")
    return ok and type(value) == "string" and value or ""
end

local function findPlayer(name)
    if type(name) ~= "string" or name == "" then return nil end
    local wanted = string.lower(name)
    for _, player in ipairs(players()) do
        if string.lower(username(player)) == wanted then return player end
    end
    return nil
end

local function point(object)
    return Body.position(object)
end

local function distance(a, b)
    if a == nil or b == nil then return math.huge end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function angleOf(y, x)
    -- Kahlua/Build 42 point releases do not all expose math.atan2.  Keep the
    -- follow ring deterministic without relying on the optional two-argument
    -- math.atan overload either.
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if y > 0 then return math.pi / 2 end
    if y < 0 then return -math.pi / 2 end
    return 0
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function behaviour(body)
    local ok, result = call(body, "getPathFindBehavior2")
    return ok and result or nil
end

local function cancel(body, record)
    local behavior = behaviour(body)
    call(behavior, "cancel")
    -- reset() is present on Build 42's PathFindBehavior2 and clears any
    -- retained goal/result state before a later retry.  Keep it capability
    -- gated for point releases that only expose cancel().
    call(behavior, "reset")
    call(body, "setPath2", nil)
    call(body, "setPathing", false)
    if record ~= nil then
        record.goal = nil
        record.startedAt = 0
    end
end

local function setMoveMode(body, moveType)
    local data = Body.data(body)
    if data ~= nil then data.GoblinMoveType = moveType end
    call(body, "setRunning", moveType == Constants.MOVE_TYPE.RUN)
    call(body, "setSprinting", false)
    Body.setPhysicalState(body,
        moveType == Constants.MOVE_TYPE.RUN and Constants.PHYSICAL.RUNNING
            or Constants.PHYSICAL.WALKING,
        moveType)
end

local function desiredMoveType(record, gap)
    local prior = record.moveType or Constants.MOVE_TYPE.IDLE
    local hysteresis = tonumber(Config.followHysteresis) or 1.5
    local preferred = tonumber(Config.followPreferredDistance) or 3
    local walkDistance = tonumber(Config.followWalkDistance) or (preferred + 1)
    local runDistance = tonumber(Config.followRunDistance) or (walkDistance + 5)
    if prior == Constants.MOVE_TYPE.RUN then
        if gap >= runDistance - hysteresis then
            return Constants.MOVE_TYPE.RUN
        end
        if gap >= walkDistance - hysteresis then
            return Constants.MOVE_TYPE.WALK
        end
        return Constants.MOVE_TYPE.IDLE
    end
    if prior == Constants.MOVE_TYPE.WALK then
        if gap >= runDistance + hysteresis then
            return Constants.MOVE_TYPE.RUN
        end
        if gap >= walkDistance - hysteresis then
            return Constants.MOVE_TYPE.WALK
        end
        return Constants.MOVE_TYPE.IDLE
    end
    if gap >= runDistance then return Constants.MOVE_TYPE.RUN end
    if gap >= walkDistance then return Constants.MOVE_TYPE.WALK end
    return Constants.MOVE_TYPE.IDLE
end

local function followGoal(body, player, recoveryAttempt)
    local actor = point(body)
    local leader = point(player)
    if actor == nil or leader == nil then return nil end
    -- Stop on a ring around the owner instead of asking PathFindBehavior2 to
    -- occupy the player's exact center.  Preserve the current radial direction
    -- and use a stable fallback so the target does not jump every repath.
    local dx, dy = actor.x - leader.x, actor.y - leader.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.01 then dx, dy, length = 1, 0, 1 end
    local radius = tonumber(Config.followPreferredDistance) or 3
    local attempt = math.max(0, tonumber(recoveryAttempt) or 0)
    -- A blocked follow route is retried on a small, deterministic ring of
    -- alternate points.  PathFindBehavior2 still owns every step and obstacle
    -- decision; the controller only changes the high-level destination.
    local baseAngle = angleOf(dy, dx)
    local angle = baseAngle + attempt * (math.pi / 2)
    radius = radius + math.min(attempt, 3) * 0.75
    return {
        x = leader.x + math.cos(angle) * radius,
        y = leader.y + math.sin(angle) * radius,
        z = leader.z
    }
end

local function resolveGoal(body, task, payload, recoveryAttempt)
    if task == Constants.TASK.FOLLOW or task == Constants.TASK.RETURN_TO_OWNER then
        local bodyData = Body.data(body)
        local ownerName = payload and payload.owner
            or (bodyData ~= nil and bodyData.GoblinOwner)
            or Spawner.ownerName()
        local player = findPlayer(ownerName)
        if player == nil and ownerName == nil then player = players()[1] end
        if player == nil then return nil, nil, "owner is offline" end
        local target = followGoal(body, player, recoveryAttempt)
        return target, player, target and "owner ring" or "owner position unavailable"
    end
    if task == Constants.TASK.MOVE_TO or task == Constants.TASK.GUARD then
        if payload == nil or type(payload.x) ~= "number"
            or type(payload.y) ~= "number" or type(payload.z) ~= "number" then
            return nil, nil, "movement target is missing"
        end
        return { x = payload.x, y = payload.y, z = payload.z }, nil, "explicit target"
    end
    return nil, nil, "task does not require movement"
end

local function resultNamed(result, name)
    local enum = rawget(_G, "BehaviorResult")
    return enum ~= nil and result == enum[name]
end

local function startPath(body, record, target, owner)
    local behavior = behaviour(body)
    if behavior == nil then
        return false, "PathFindBehavior2 is unavailable"
    end
    cancel(body, record)
    local ok
    -- Follow tasks resolve to a stable ring point around the owner.  Prefer
    -- that point over pathToCharacter so the companion never targets the
    -- player's exact center (which causes crowding and animation churn).
    if record.entityTarget ~= nil and type(behavior.pathToCharacter) == "function" then
        local okCall, result = pcall(behavior.pathToCharacter, behavior, record.entityTarget)
        ok = okCall and result ~= false
    elseif target ~= nil and type(behavior.pathToLocationF) == "function" then
        local okCall, result = pcall(behavior.pathToLocationF, behavior, target.x, target.y, target.z)
        ok = okCall and result ~= false
    elseif target ~= nil and type(behavior.pathToLocation) == "function" then
        local okCall, result = pcall(behavior.pathToLocation, behavior,
            math.floor(target.x), math.floor(target.y), math.floor(target.z))
        ok = okCall and result ~= false
    elseif owner ~= nil and type(behavior.pathToCharacter) == "function" then
        local okCall, result = pcall(behavior.pathToCharacter, behavior, owner)
        ok = okCall and result ~= false
    else
        ok = false
    end
    if not ok then return false, "PathFindBehavior2 rejected the goal" end
    if record.entityTarget ~= nil then
        -- `pathToCharacter` is a navigation request, not permission to enter
        -- IsoZombie's hostile target state.  Some Build 42 point releases
        -- mirror the character argument into that field, so clear it again
        -- immediately while retaining the native path behavior's goal.
        call(body, "setTarget", nil)
        call(body, "setAttackTargetSquare", nil)
    end
    call(body, "setPathing", true)
    record.goal = target
    record.startedAt = nowMs()
    record.lastProgressAt = record.startedAt
    record.lastDistance = distance(point(body), target)
    log("PATH_START id=" .. Config.npcId .. " task=" .. tostring(record.task)
        .. " move=" .. tostring(record.moveType))
    return true, "PathFindBehavior2 goal accepted"
end

function Movement.clear(body)
    local record = Movement.active[body]
    cancel(body, record)
    Movement.active[body] = nil
    if Body.isGoblin(body) then
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
    end
    return true
end

function Movement.command(body, task, payload)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    Movement.clear(body)
    local record = { task = task, payload = payload or {}, moveType = Constants.MOVE_TYPE.IDLE,
        nextRepathAt = 0, failedAt = 0, goal = nil, startedAt = 0,
        recoveryAttempts = 0, recoveryStage = "initial", lastProgressAt = 0,
        lastDistance = nil }
    Movement.active[body] = record
    if task == Constants.TASK.WAIT or task == Constants.TASK.SPEAK
        or task == Constants.TASK.EQUIP or task == Constants.TASK.ATTACK
        or task == Constants.TASK.LOOT then
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            task == Constants.TASK.ATTACK and Constants.COMBAT.READY or Constants.COMBAT.NONE)
        return true, "task does not start movement"
    end
    local target, owner, detail = resolveGoal(body, task, record.payload, 0)
    if target == nil then
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, Constants.MOVE_TYPE.IDLE)
        return false, detail
    end
    local gap = distance(point(body), target)
    if task == Constants.TASK.FOLLOW or task == Constants.TASK.RETURN_TO_OWNER then
        record.moveType = desiredMoveType(record, gap)
    else
        record.moveType = gap >= Config.followRunDistance
            and Constants.MOVE_TYPE.RUN or Constants.MOVE_TYPE.WALK
    end
    if record.moveType == Constants.MOVE_TYPE.IDLE then
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE)
        return true, "already inside preferred distance"
    end
    setMoveMode(body, record.moveType)
    Body.setPhysicalState(body, Constants.PHYSICAL.PATHING, record.moveType)
    return startPath(body, record, target, owner)
end

function Movement.commandCombat(body, target)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    if target == nil or not Body.exists(target) then
        return false, "combat target is unavailable"
    end
    local existing = Movement.active[body]
    if existing ~= nil and existing.task == Constants.TASK.ATTACK
        and existing.entityTarget == target then
        return true, "combat path already active"
    end
    Movement.clear(body)
    local record = {
        task = Constants.TASK.ATTACK,
        payload = {},
        entityTarget = target,
        moveType = Constants.MOVE_TYPE.IDLE,
        nextRepathAt = 0,
        failedAt = 0,
        goal = nil,
        startedAt = 0,
        recoveryAttempts = 0,
        recoveryStage = "combat-approach",
        lastProgressAt = 0,
        lastDistance = nil
    }
    Movement.active[body] = record
    local targetPoint = point(target)
    local gap = distance(point(body), targetPoint)
    if gap <= (tonumber(Config.meleeRange) or 2.25) then
        Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.READY)
        return true, "combat target is in melee range"
    end
    record.moveType = gap >= (tonumber(Config.followRunDistance) or 9)
        and Constants.MOVE_TYPE.RUN or Constants.MOVE_TYPE.WALK
    setMoveMode(body, record.moveType)
    Body.setPhysicalState(body, Constants.PHYSICAL.PATHING, record.moveType,
        Constants.COMBAT.READY)
    local started, detail = startPath(body, record, targetPoint, nil)
    if not started then
        record.recoveryAttempts = 1
        record.recoveryStage = "combat-approach-blocked"
        record.nextRepathAt = nowMs() + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
            Constants.COMBAT.READY)
        return false, detail
    end
    return true, "PathFindBehavior2 combat approach accepted"
end

function Movement.updateCombat(body, timestamp)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local record = Movement.active[body]
    if record == nil or record.task ~= Constants.TASK.ATTACK then
        return false, "combat path is not active"
    end
    local target = record.entityTarget
    if target == nil or not Body.exists(target) then
        Movement.clear(body)
        return false, "combat target is unavailable"
    end
    local now = timestamp or nowMs()
    if (record.recoveryAttempts or 0) > (tonumber(Config.maxRecoveryAttempts) or 3) then
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
            Constants.COMBAT.READY)
        return false, "combat path recovery attempts exhausted"
    end
    local targetPoint = point(target)
    local gap = distance(point(body), targetPoint)
    if gap <= (tonumber(Config.meleeRange) or 2.25) then
        cancel(body, record)
        Movement.active[body] = nil
        Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.READY)
        return true, "combat target reached"
    end
    if now < (record.nextRepathAt or 0) then
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
            Constants.COMBAT.READY)
        return false, "combat approach is waiting for recovery retry"
    end
    if record.goal == nil then
        local started, detail = startPath(body, record, targetPoint, nil)
        if not started then
            record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
            record.recoveryStage = "combat-approach-retry"
            record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
            Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
                Constants.COMBAT.READY)
            return false, detail
        end
        Body.setPhysicalState(body, Constants.PHYSICAL.PATHING, record.moveType,
            Constants.COMBAT.READY)
        return true
    end
    local behavior = behaviour(body)
    if behavior == nil then
        record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
        record.recoveryStage = "combat-pathfinder-unavailable"
        record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
        record.goal = nil
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
            Constants.COMBAT.READY)
        return false, "PathFindBehavior2 is unavailable"
    end
    local ok, result = call(behavior, "update")
    if not ok then
        cancel(body, record)
        record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
        record.recoveryStage = "combat-path-update-failed"
        record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
            Constants.COMBAT.READY)
        return false, "PathFindBehavior2 combat update failed"
    end
    local currentDistance = distance(point(body), targetPoint)
    if record.lastDistance == nil or currentDistance < record.lastDistance - 0.05 then
        record.lastDistance = currentDistance
        record.lastProgressAt = now
        record.recoveryStage = "combat-approach"
    elseif now - (record.lastProgressAt or now) >=
        (tonumber(Config.stuckTimeoutSeconds) or 8) * 1000 then
        cancel(body, record)
        record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
        record.recoveryStage = "combat-approach-stuck"
        record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
            Constants.COMBAT.READY)
        return false, "combat approach made no native path progress"
    end
    if resultNamed(result, "Succeeded") then
        cancel(body, record)
        -- Keep the attack record alive with a fresh goal so a moving target is
        -- reacquired on the next brain tick without ever assigning a zombie
        -- native hostile target.
        -- `cancel()` clears the native behavior, so retaining the old goal
        -- would make the next update call `update()` on an already-complete
        -- path and strand a target that moved just outside melee range.
        -- Clearing it forces the bounded restart branch below to ask
        -- PathFindBehavior2 for a fresh native goal.
        record.goal = nil
        record.nextRepathAt = now
        record.recoveryStage = "combat-approach-reached"
        Body.setPhysicalState(body, Constants.PHYSICAL.COMBAT, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.READY)
        log("PATH_COMPLETE id=" .. Config.npcId .. " task=ATTACK")
        return true, "combat path reached its native goal"
    end
    if resultNamed(result, "Failed") then
        cancel(body, record)
        record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
        record.recoveryStage = "combat-path-failed"
        record.failedAt = now
        record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
            Constants.COMBAT.READY)
        log("PATH_FAILED id=" .. Config.npcId .. " task=ATTACK detail=combat approach")
        return false, "PathFindBehavior2 reported combat failure"
    end
    record.nextRepathAt = now + 250
    Body.setPhysicalState(body, Constants.PHYSICAL.PATHING, record.moveType,
        Constants.COMBAT.READY)
    return true
end

function Movement.update(body, timestamp)
    if not Body.isGoblin(body) then return false end
    local record = Movement.active[body]
    if record == nil then return false end
    local task = record.task
    if task == Constants.TASK.WAIT or task == Constants.TASK.SPEAK
        or task == Constants.TASK.EQUIP or task == Constants.TASK.ATTACK
        or task == Constants.TASK.LOOT then
        return true
    end
    local target, owner, detail = resolveGoal(body, task, record.payload,
        record.recoveryAttempts or 0)
    if target == nil then
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, Constants.MOVE_TYPE.IDLE)
        return false, detail
    end
    local gap = distance(point(body), target)
    local desired = (task == Constants.TASK.FOLLOW or task == Constants.TASK.RETURN_TO_OWNER)
        and desiredMoveType(record, gap) or record.moveType
    if desired == Constants.MOVE_TYPE.IDLE then
        Movement.clear(body)
        return true
    end
    if desired ~= record.moveType then
        record.moveType = desired
        setMoveMode(body, desired)
        record.nextRepathAt = 0
    end
    local now = timestamp or nowMs()
    if now < (record.nextRepathAt or 0) then return true end
    if (record.recoveryAttempts or 0) > (tonumber(Config.maxRecoveryAttempts) or 3) then
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType,
            Constants.COMBAT.NONE)
        return false, "native path recovery attempts exhausted"
    end
    if record.goal == nil then
        local retryTarget, retryOwner, retryDetail = resolveGoal(body, task, record.payload,
            record.recoveryAttempts or 0)
        if retryTarget == nil then
            Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType)
            record.nextRepathAt = now + Config.blockedRetrySeconds * 1000
            return false, retryDetail
        end
        local started, startDetail = startPath(body, record, retryTarget, retryOwner)
        if not started then
            record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
            record.recoveryStage = "path-retry-failed"
            Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType)
            record.nextRepathAt = now + Config.blockedRetrySeconds * 1000
            return false, startDetail
        end
        record.recoveryStage = "path-retry"
        Body.setPhysicalState(body, Constants.PHYSICAL.PATHING, record.moveType)
        return true
    end
    local behavior = behaviour(body)
    if behavior == nil then
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType)
        return false, "PathFindBehavior2 is unavailable"
    end
    local ok, result = call(behavior, "update")
    if not ok then
        record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
        record.recoveryStage = "path-update-failed"
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType)
        record.nextRepathAt = now + Config.blockedRetrySeconds * 1000
        return false, "PathFindBehavior2 update failed"
    end
    local currentDistance = distance(point(body), record.goal)
    if record.lastDistance == nil or currentDistance < record.lastDistance - 0.05 then
        record.lastDistance = currentDistance
        record.lastProgressAt = now
        record.recoveryStage = "pathing"
    elseif now - (record.lastProgressAt or now) >=
        (tonumber(Config.stuckTimeoutSeconds) or 8) * 1000 then
        cancel(body, record)
        record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
        record.recoveryStage = "stuck-retry"
        record.failedAt = now
        record.nextRepathAt = now + Config.blockedRetrySeconds * 1000
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType)
        log("RECOVERY id=" .. Config.npcId .. " stage=stuck-retry attempt="
            .. tostring(record.recoveryAttempts))
        return false, "native path made no progress"
    end
    if resultNamed(result, "Succeeded") then
        cancel(body, record)
        record.recoveryAttempts = 0
        record.recoveryStage = "complete"
        record.nextRepathAt = now + Config.repathSeconds * 1000
        -- Follow/return tasks remain active after reaching their ring point.
        -- The native behavior has just been cancelled, therefore the old
        -- destination must not be treated as an active path on the next tick.
        -- MOVE_TO/GUARD mark themselves complete and will not consume this
        -- field, but clearing it is safe for every task.
        record.goal = nil
        record.complete = task ~= Constants.TASK.FOLLOW
            and task ~= Constants.TASK.RETURN_TO_OWNER
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE)
        log("PATH_COMPLETE id=" .. Config.npcId .. " task=" .. tostring(task))
        return true
    end
    if resultNamed(result, "Failed") then
        cancel(body, record)
        record.recoveryAttempts = (record.recoveryAttempts or 0) + 1
        record.recoveryStage = "path-failed"
        record.nextRepathAt = now + Config.blockedRetrySeconds * 1000
        record.failedAt = now
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, record.moveType)
        log("PATH_FAILED id=" .. Config.npcId .. " task=" .. tostring(task)
            .. " detail=" .. tostring(detail))
        return false, "PathFindBehavior2 reported failure"
    end
    record.nextRepathAt = now + 250
    Body.setPhysicalState(body, Constants.PHYSICAL.PATHING, record.moveType)
    return true
end

function Movement.snapshot(body)
    local record = Movement.active[body]
    if record == nil then return nil end
    return {
        task = record.task,
        move_type = record.moveType,
        goal = record.goal,
        complete = record.complete == true,
        entity_target_active = record.entityTarget ~= nil,
        recovery_attempts = record.recoveryAttempts or 0,
        recovery_stage = record.recoveryStage,
        last_progress_at = record.lastProgressAt,
        next_repath_at = record.nextRepathAt,
        started_at = record.startedAt,
        failed_at = record.failedAt
    }
end

return Movement

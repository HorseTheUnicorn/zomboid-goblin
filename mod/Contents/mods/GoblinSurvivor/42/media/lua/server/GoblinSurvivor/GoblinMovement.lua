-- Native PathFindBehavior2 movement for any managed Goblin body.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")

local Movement = { active = setmetatable({}, { __mode = "k" }) }

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
    return os.time() * 1000
end

local function log(body, message)
    if type(print) == "function" then
        print("[GoblinSurvivor] " .. tostring(message)
            .. " owner=" .. tostring(Body.owner(body)))
    end
end

local function players()
    local result = {}
    if type(getOnlinePlayers) ~= "function" then return result end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return result end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    for index = 0, size - 1 do
        local okPlayer, player = call(list, "get", index)
        if okPlayer and player ~= nil then result[#result + 1] = player end
    end
    return result
end

local function username(player)
    local ok, name = call(player, "getUsername")
    return ok and type(name) == "string" and name or ""
end

local function findOwner(body)
    local owner = Body.owner(body)
    if type(owner) ~= "string" then return nil end
    local wanted = string.lower(owner)
    for _, player in ipairs(players()) do
        if string.lower(username(player)) == wanted then return player end
    end
    return nil
end

local function distance(a, b)
    if a == nil or b == nil then return math.huge end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function behaviour(body)
    local ok, value = call(body, "getPathFindBehavior2")
    return ok and value or nil
end

local function cancel(body)
    local b = behaviour(body)
    call(b, "cancel")
    call(b, "reset")
    call(body, "setPath2", nil)
    call(body, "setPathing", false)
end

local function resultNamed(result, name)
    local enum = rawget(_G, "BehaviorResult")
    return enum ~= nil and result == enum[name]
end

local function ownerRing(body, player)
    local actor, leader = Body.position(body), Body.position(player)
    if actor == nil or leader == nil then return nil end
    local dx, dy = actor.x - leader.x, actor.y - leader.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.01 then dx, dy, length = 1, 0, 1 end
    local radius = tonumber(Config.followPreferredDistance) or 3
    return {
        x = leader.x + dx / length * radius,
        y = leader.y + dy / length * radius,
        z = leader.z
    }
end

local function taskTarget(body, task, payload)
    if task == Constants.TASK.FOLLOW then
        local player = findOwner(body)
        if player == nil then return nil, "owner offline" end
        return ownerRing(body, player), "owner"
    end
    if task == Constants.TASK.RETURN_TO_BASE then
        local data = Body.data(body)
        if data == nil or data.GoblinBaseSet ~= true then return nil, "base is not set" end
        return {
            x = tonumber(data.GoblinBaseX),
            y = tonumber(data.GoblinBaseY),
            z = tonumber(data.GoblinBaseZ)
        }, "base"
    end
    if task == Constants.TASK.MOVE_TO and type(payload) == "table"
        and type(payload.x) == "number" and type(payload.y) == "number"
        and type(payload.z) == "number" then
        return { x = payload.x, y = payload.y, z = payload.z }, "location"
    end
    return nil, "task has no movement target"
end

local function chooseMoveType(gap)
    if gap >= (tonumber(Config.followRunDistance) or 9) then return Constants.MOVE_TYPE.RUN end
    if gap >= (tonumber(Config.followWalkDistance) or 4) then return Constants.MOVE_TYPE.WALK end
    return Constants.MOVE_TYPE.IDLE
end

local function startPath(body, record, target)
    local b = behaviour(body)
    if b == nil then return false, "PathFindBehavior2 unavailable" end
    cancel(body)
    local ok = false
    if type(b.pathToLocationF) == "function" then
        local worked, result = pcall(b.pathToLocationF, b, target.x, target.y, target.z)
        ok = worked and result ~= false
    elseif type(b.pathToLocation) == "function" then
        local worked, result = pcall(b.pathToLocation, b,
            math.floor(target.x), math.floor(target.y), math.floor(target.z))
        ok = worked and result ~= false
    end
    if not ok then return false, "native pathfinder rejected target" end
    call(body, "setPathing", true)
    record.goal = target
    record.lastProgressAt = nowMs()
    record.lastDistance = distance(Body.position(body), target)
    record.nextRepathAt = nowMs() + (tonumber(Config.repathSeconds) or 1.25) * 1000
    log(body, "PATH_START task=" .. tostring(record.task))
    return true, "path started"
end

function Movement.clear(body)
    cancel(body)
    Movement.active[body] = nil
    if Body.isGoblin(body) then
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
    end
end

function Movement.command(body, task, payload)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    Movement.clear(body)
    if task ~= Constants.TASK.FOLLOW and task ~= Constants.TASK.RETURN_TO_BASE
        and task ~= Constants.TASK.MOVE_TO then
        return true, "task does not move"
    end
    local target, detail = taskTarget(body, task, payload or {})
    if target == nil or target.x == nil or target.y == nil or target.z == nil then
        Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, Constants.MOVE_TYPE.IDLE)
        return false, detail
    end
    local gap = distance(Body.position(body), target)
    local stopDistance = task == Constants.TASK.FOLLOW
        and (tonumber(Config.followPreferredDistance) or 3) or 1.5
    if gap <= stopDistance then
        return true, "arrived"
    end
    local moveType = chooseMoveType(gap)
    local record = {
        task = task,
        payload = payload or {},
        goal = nil,
        moveType = moveType,
        nextRepathAt = 0,
        lastProgressAt = nowMs(),
        lastDistance = gap,
        failures = 0,
        arrived = false
    }
    Movement.active[body] = record
    Body.setPhysicalState(body,
        task == Constants.TASK.RETURN_TO_BASE and Constants.PHYSICAL.RETURNING
            or Constants.PHYSICAL.PATHING,
        moveType, Constants.COMBAT.NONE)
    return startPath(body, record, target)
end

function Movement.update(body, timestamp)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local record = Movement.active[body]
    if record == nil then return true, "idle" end
    local now = timestamp or nowMs()
    local target, detail = taskTarget(body, record.task, record.payload)
    if target == nil then
        Movement.clear(body)
        return false, detail
    end

    local current = Body.position(body)
    local gap = distance(current, target)
    local stopDistance = record.task == Constants.TASK.FOLLOW
        and (tonumber(Config.followPreferredDistance) or 3) or 1.5
    if gap <= stopDistance then
        cancel(body)
        record.arrived = true
        Movement.active[body] = nil
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE,
            Constants.COMBAT.NONE)
        log(body, "PATH_COMPLETE task=" .. tostring(record.task))
        return true, "arrived"
    end

    local wantedMove = chooseMoveType(gap)
    if wantedMove ~= record.moveType then
        record.moveType = wantedMove
        Body.setPhysicalState(body,
            record.task == Constants.TASK.RETURN_TO_BASE and Constants.PHYSICAL.RETURNING
                or Constants.PHYSICAL.PATHING,
            wantedMove, Constants.COMBAT.NONE)
    end

    local movedTarget = record.goal == nil or distance(record.goal, target) > 1.5
    if movedTarget or now >= (record.nextRepathAt or 0) then
        local started, startDetail = startPath(body, record, target)
        if not started then
            record.failures = (record.failures or 0) + 1
            record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
            if record.failures > (tonumber(Config.maxRecoveryAttempts) or 3) then
                Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED,
                    Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
            end
            return false, startDetail
        end
    end

    local b = behaviour(body)
    if b == nil then return false, "PathFindBehavior2 unavailable" end
    local ok, result = call(b, "update")
    if not ok then
        record.goal = nil
        record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
        return false, "native path update failed"
    end

    local remaining = distance(Body.position(body), target)
    if remaining < (record.lastDistance or math.huge) - 0.05 then
        record.lastDistance = remaining
        record.lastProgressAt = now
        record.failures = 0
    elseif now - (record.lastProgressAt or now)
        >= (tonumber(Config.stuckTimeoutSeconds) or 8) * 1000 then
        cancel(body)
        record.goal = nil
        record.failures = (record.failures or 0) + 1
        record.lastProgressAt = now
        record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
        log(body, "PATH_RETRY stuck=true failures=" .. tostring(record.failures))
        return false, "path made no progress"
    end

    if resultNamed(result, "Failed") then
        cancel(body)
        record.goal = nil
        record.failures = (record.failures or 0) + 1
        record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 3) * 1000
        return false, "native pathfinder reported failure"
    end
    if resultNamed(result, "Succeeded") then
        record.goal = nil
        record.nextRepathAt = now
    end
    return true, "pathing"
end

function Movement.snapshot(body)
    local record = Movement.active[body]
    if record == nil then return nil end
    return {
        task = record.task,
        move_type = record.moveType,
        goal = record.goal,
        failures = record.failures or 0,
        arrived = record.arrived == true
    }
end

return Movement

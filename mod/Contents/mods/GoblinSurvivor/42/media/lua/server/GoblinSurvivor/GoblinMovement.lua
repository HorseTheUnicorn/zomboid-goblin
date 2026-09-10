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
    return 0
end

local function players()
    local result = {}
    if type(getOnlinePlayers) ~= "function" then return result end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return result end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    for i = 0, size - 1 do
        local okPlayer, player = call(list, "get", i)
        if okPlayer and player ~= nil then result[#result + 1] = player end
    end
    return result
end

local function username(player)
    local ok, value = call(player, "getUsername")
    return ok and type(value) == "string" and value or ""
end

local function findOwner(body)
    local wanted = string.lower(tostring(Body.owner(body) or ""))
    for _, player in ipairs(players()) do
        if string.lower(username(player)) == wanted then return player end
    end
    return nil
end

local function distance(a, b)
    if a == nil or b == nil then return math.huge end
    return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2)
end

local function ownerRing(body, player)
    local actor, leader = Body.position(body), Body.position(player)
    if actor == nil or leader == nil then return nil end
    local dx, dy = actor.x - leader.x, actor.y - leader.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.01 then dx, dy, length = 1, 0, 1 end
    local radius = tonumber(Config.followPreferredDistance) or 3
    return { x = leader.x + dx / length * radius, y = leader.y + dy / length * radius, z = leader.z }
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
        return { x = tonumber(data.GoblinBaseX), y = tonumber(data.GoblinBaseY), z = tonumber(data.GoblinBaseZ) }, "base"
    end
    if task == Constants.TASK.MOVE_TO and type(payload) == "table"
        and type(payload.x) == "number" and type(payload.y) == "number" and type(payload.z) == "number" then
        return { x = payload.x, y = payload.y, z = payload.z }, "location"
    end
    return nil, "task has no movement target"
end

local function chooseMoveType(gap)
    if gap >= (tonumber(Config.followRunDistance) or 9) then return Constants.MOVE_TYPE.RUN end
    if gap >= (tonumber(Config.followWalkDistance) or 4) then return Constants.MOVE_TYPE.WALK end
    return Constants.MOVE_TYPE.IDLE
end

local function stop(body)
    local okBehavior, behavior = call(body, "getPathFindBehavior2")
    if okBehavior and behavior ~= nil then
        call(behavior, "cancel")
        call(behavior, "reset")
    end
    call(body, "setPath2", nil)
    call(body, "setPathing", false)
end

local function kickPath(body, record, target)
    -- Match the route used by working Build 42 NPC mods: ask IsoZombie itself
    -- to path to the location and let the engine own PathFindBehavior2 updates.
    -- Manually driving behavior:update() from server Lua left the body frozen.
    local ok, result = call(body, "pathToLocationF", target.x, target.y, target.z)
    if not ok or result == false then return false, "IsoZombie pathToLocationF rejected target" end
    record.goal = { x = target.x, y = target.y, z = target.z }
    record.lastDistance = distance(Body.position(body), target)
    record.lastProgressAt = nowMs()
    record.nextRepathAt = nowMs() + (tonumber(Config.repathSeconds) or 1.25) * 1000
    call(body, "setPathing", true)
    return true, "path started"
end

function Movement.clear(body)
    stop(body)
    Movement.active[body] = nil
    if Body.isGoblin(body) then
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
    end
end

function Movement.command(body, task, payload)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    Movement.clear(body)
    if task ~= Constants.TASK.FOLLOW and task ~= Constants.TASK.RETURN_TO_BASE and task ~= Constants.TASK.MOVE_TO then
        return true, "task does not move"
    end
    local target, detail = taskTarget(body, task, payload or {})
    if target == nil or target.x == nil or target.y == nil or target.z == nil then return false, detail end
    local gap = distance(Body.position(body), target)
    local stopDistance = task == Constants.TASK.FOLLOW and (tonumber(Config.followPreferredDistance) or 3) or 1.5
    if gap <= stopDistance then return true, "arrived" end
    local moveType = chooseMoveType(gap)
    local record = {
        task = task,
        payload = payload or {},
        goal = nil,
        moveType = moveType,
        nextRepathAt = 0,
        lastProgressAt = nowMs(),
        lastDistance = gap,
        failures = 0
    }
    Movement.active[body] = record
    Body.setPhysicalState(body,
        task == Constants.TASK.RETURN_TO_BASE and Constants.PHYSICAL.RETURNING or Constants.PHYSICAL.PATHING,
        moveType, Constants.COMBAT.NONE)
    return kickPath(body, record, target)
end

function Movement.update(body, timestamp)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local record = Movement.active[body]
    if record == nil then return true, "idle" end
    local now = timestamp or nowMs()
    local target, detail = taskTarget(body, record.task, record.payload)
    if target == nil then Movement.clear(body) return false, detail end
    local gap = distance(Body.position(body), target)
    local stopDistance = record.task == Constants.TASK.FOLLOW and (tonumber(Config.followPreferredDistance) or 3) or 1.5
    if gap <= stopDistance then
        Movement.clear(body)
        return true, "arrived"
    end

    local wantedMove = chooseMoveType(gap)
    if wantedMove ~= record.moveType then
        record.moveType = wantedMove
        Body.setPhysicalState(body,
            record.task == Constants.TASK.RETURN_TO_BASE and Constants.PHYSICAL.RETURNING or Constants.PHYSICAL.PATHING,
            wantedMove, Constants.COMBAT.NONE)
    end

    if gap < (record.lastDistance or math.huge) - 0.05 then
        record.lastDistance = gap
        record.lastProgressAt = now
        record.failures = 0
    elseif now - (record.lastProgressAt or now) >= (tonumber(Config.stuckTimeoutSeconds) or 6) * 1000 then
        stop(body)
        record.failures = (record.failures or 0) + 1
        record.lastProgressAt = now
        record.nextRepathAt = now
    end

    local goalMoved = record.goal == nil or distance(record.goal, target) > 1.0
    if goalMoved or now >= (record.nextRepathAt or 0) then
        local ok, startDetail = kickPath(body, record, target)
        if not ok then
            record.failures = (record.failures or 0) + 1
            record.nextRepathAt = now + (tonumber(Config.blockedRetrySeconds) or 2) * 1000
            if record.failures > (tonumber(Config.maxRecoveryAttempts) or 4) then
                Body.setPhysicalState(body, Constants.PHYSICAL.BLOCKED, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
            end
            return false, startDetail
        end
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
        failures = record.failures or 0
    }
end

return Movement

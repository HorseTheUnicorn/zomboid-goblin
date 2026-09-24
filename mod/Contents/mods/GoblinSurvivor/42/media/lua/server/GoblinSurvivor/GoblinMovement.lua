local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local Access = require("GoblinSurvivor/GoblinAccess")

local Movement = { active = setmetatable({}, { __mode = "k" }) }

local function findOwner(body)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local wanted = string.lower(tostring(Body.owner(body) or ""))
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if string.lower(player:getUsername()) == wanted then return player end
    end
end

local function targetFor(body, record, timestamp)
    if record.task == Constants.TASK.FOLLOW then
        local owner = findOwner(body)
        if not owner then return nil, 0, "owner offline" end
        local target, gap, navigation = Motion.followGoal(body, owner, timestamp)
        if target then return target, gap, "pathing", owner, navigation end
        local key = navigation and navigation.goal_key
        local arrived = key == "arrived" or (type(key) == "string" and string.match(key,"^slot:%d+$"))
        return nil, gap, arrived and "arrived" or "follow position unavailable", owner, navigation
    end
    local target = record.payload
    if record.task == Constants.TASK.RETURN_TO_BASE then
        local data = Body.data(body)
        if not data or not data.GoblinBaseSet then return nil, 0, "base unavailable" end
        target = { x = data.GoblinBaseX, y = data.GoblinBaseY, z = data.GoblinBaseZ }
    end
    if not Motion.validPoint(target) then
        return nil, 0, "target unavailable"
    end
    local point = Body.position(body)
    if not Motion.validPoint(point) then return nil, 0, "position unavailable" end
    local gap = Motion.distance(point, target)
    local radius = record.payload.radius == nil and 1.5 or tonumber(record.payload.radius)
    if not radius or radius ~= radius or radius < 0 or radius > 10 then
        return nil, 0, "target unavailable"
    end
    if math.floor(point.z) == math.floor(target.z) and gap <= radius then
        return nil, gap, "arrived"
    end
    return target, gap, "pathing"
end

function Movement.clear(body)
    Motion.stop(body)
    Movement.active[body] = nil
    local data = Body.data(body)
    if data then data.GoblinMovementGoal = nil end
    if Body.isGoblin(body) then
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
    end
end

function Movement.command(body, task, payload, scope)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    Movement.clear(body)
    if task ~= Constants.TASK.FOLLOW then Motion.clearFollowSlot(body) end
    if task ~= Constants.TASK.FOLLOW and task ~= Constants.TASK.MOVE_TO and task ~= Constants.TASK.RETURN_TO_BASE then
        return true, "task does not move"
    end
    -- `scope` is runtime-only BuildingDef state.  It is intentionally kept
    -- outside the task payload so Body.setTask/ModData never serializes Java
    -- userdata.  House jobs pass it back on each movement command.
    Movement.active[body] = { task = task, payload = payload or {}, scope = scope }
    local ok, detail = Movement.update(body)
    if not ok and detail == "position unavailable" then
        return true, "movement queued; waiting for Goblin position"
    end
    if task == Constants.TASK.FOLLOW and not ok
        and (detail == "owner offline" or detail == "follow position unavailable") then
        return true, "follow queued; waiting for owner or world data"
    end
    return ok, detail
end

function Movement.update(body, timestamp)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local record = Movement.active[body]
    if not record then return true, "idle" end
    timestamp = timestamp or getTimestampMs()
    local target, gap, detail, owner, navigation = targetFor(body, record, timestamp)
    if not target then
        if record.task == Constants.TASK.FOLLOW or detail == "position unavailable" then
            if record.goal or record.moveType ~= Constants.MOVE_TYPE.IDLE then Motion.stop(body) end
            record.goal, record.moveType = nil, Constants.MOVE_TYPE.IDLE
            local data = Body.data(body)
            if data then data.GoblinMovementGoal = nil end
            Body.setPhysicalState(body,Constants.PHYSICAL.IDLE,Constants.MOVE_TYPE.IDLE,Constants.COMBAT.NONE)
            if record.task == Constants.TASK.FOLLOW and detail == "arrived" then
                record.payload.rejoin_run = nil
            end
            return detail == "arrived", detail
        end
        Movement.clear(body)
        return detail == "arrived", detail
    end
    -- Any destination outside its arrival radius must WALK at minimum.
    -- Previously short MOVE_TO goals were pathing with an IDLE animation.
    local move = Motion.moveType(target, gap, owner)
    if record.task==Constants.TASK.FOLLOW and record.payload.rejoin_run then move=Constants.MOVE_TYPE.RUN end
    record.goal, record.moveType = target, move
    local obstructionCleared = Access.update(body,target,timestamp,record.scope)
    Body.data(body).GoblinMovementGoal = { x = target.x, y = target.y, z = target.z }
    Body.setPhysicalState(body,
        record.task == Constants.TASK.RETURN_TO_BASE and Constants.PHYSICAL.RETURNING or Constants.PHYSICAL.PATHING,
        move, Constants.COMBAT.NONE)
    navigation = navigation or {
        goal_type = record.payload.approach_type or "location",
        goal_key = record.payload.goal_key,
        blacklist_kind = record.payload.blacklist_kind
    }
    navigation.obstruction_cleared = obstructionCleared == true
    record.navigation = navigation
    return Motion.drive(body, target, move, timestamp, navigation)
end

function Movement.snapshot(body)
    local record = Movement.active[body]
    if not record then return nil end
    return { task = record.task, move_type = record.moveType, goal = record.goal,
        navigation = Motion.snapshot(body) }
end

return Movement

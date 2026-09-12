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

local function targetFor(body, record)
    if record.task == Constants.TASK.FOLLOW then
        local owner = findOwner(body)
        if not owner then return nil, 0, "owner offline" end
        local target, gap = Motion.followGoal(body, owner)
        return target, gap, target and "pathing" or "arrived", owner
    end
    local target = record.payload
    if record.task == Constants.TASK.RETURN_TO_BASE then
        local data = Body.data(body)
        if not data or not data.GoblinBaseSet then return nil, 0, "base unavailable" end
        target = { x = data.GoblinBaseX, y = data.GoblinBaseY, z = data.GoblinBaseZ }
    end
    if type(target.x) ~= "number" or type(target.y) ~= "number" or type(target.z) ~= "number" then
        return nil, 0, "target unavailable"
    end
    local point = Body.position(body)
    local gap = Motion.distance(point, target)
    if point and math.floor(point.z) == math.floor(target.z) and gap <= (tonumber(record.payload.radius) or 1.5) then
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
    if task ~= Constants.TASK.FOLLOW and task ~= Constants.TASK.MOVE_TO and task ~= Constants.TASK.RETURN_TO_BASE then
        return true, "task does not move"
    end
    -- `scope` is runtime-only BuildingDef state.  It is intentionally kept
    -- outside the task payload so Body.setTask/ModData never serializes Java
    -- userdata.  House jobs pass it back on each movement command.
    Movement.active[body] = { task = task, payload = payload or {}, scope = scope }
    return Movement.update(body)
end

function Movement.update(body, timestamp)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local record = Movement.active[body]
    if not record then return true, "idle" end
    local target, gap, detail, owner = targetFor(body, record)
    if not target then
        if record.task==Constants.TASK.FOLLOW and detail=="arrived" then record.payload.rejoin_run=nil end
        Movement.clear(body)
        return detail == "arrived", detail
    end
    -- Any destination outside its arrival radius must WALK at minimum.
    -- Previously short MOVE_TO goals were pathing with an IDLE animation.
    local move = Motion.moveType(target, gap, owner)
    if record.task==Constants.TASK.FOLLOW and record.payload.rejoin_run then move=Constants.MOVE_TYPE.RUN end
    record.goal, record.moveType = target, move
    Access.update(body,target,timestamp or getTimestampMs(),record.scope)
    Body.data(body).GoblinMovementGoal = { x = target.x, y = target.y, z = target.z }
    Body.setPhysicalState(body,
        record.task == Constants.TASK.RETURN_TO_BASE and Constants.PHYSICAL.RETURNING or Constants.PHYSICAL.PATHING,
        move, Constants.COMBAT.NONE)
    return Motion.drive(body, target, move, timestamp or getTimestampMs())
end

function Movement.snapshot(body)
    local record = Movement.active[body]
    if not record then return nil end
    return { task = record.task, move_type = record.moveType, goal = record.goal }
end

return Movement

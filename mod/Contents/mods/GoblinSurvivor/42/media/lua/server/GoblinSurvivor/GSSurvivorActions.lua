-- Engine-independent action contracts.  Actions translate semantic goals
-- into bounded native adapter calls; callers never send raw movement commands.
local Combat = require("GoblinSurvivor/GSSurvivorCombat")

local Actions = {}

local DEFINITIONS = {
    Idle = { timeoutMs = 0 },
    Wait = { timeoutMs = 60000 },
    Move = { timeoutMs = 120000, repathMs = 1000 },
    GoTo = { timeoutMs = 120000, repathMs = 1000 },
    Follow = { timeoutMs = 0, repathMs = 1000 },
    FaceTarget = { timeoutMs = 10000 },
    MeleeAttack = { timeoutMs = 30000, repathMs = 500 },
    Aim = { timeoutMs = 15000 },
    Shoot = { timeoutMs = 30000 },
    Reload = { timeoutMs = 15000 },
    Speak = { timeoutMs = 10000 },
    OpenDoor = { timeoutMs = 10000 },
    ClimbFence = { timeoutMs = 15000 },
    GetUp = { timeoutMs = 10000 },
    Recover = { timeoutMs = 30000 },
    Equip = { timeoutMs = 10000 },
    Unequip = { timeoutMs = 10000 },
    Loot = { timeoutMs = 60000 },
    ReturnHome = { timeoutMs = 120000, repathMs = 1000 }
}

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function pointOf(entity)
    if entity == nil or type(entity.getX) ~= "function"
        or type(entity.getY) ~= "function" or type(entity.getZ) ~= "function" then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return entity:getX(), entity:getY(), entity:getZ()
    end)
    return ok and type(x) == "number" and type(y) == "number"
        and type(z) == "number" and { x = x, y = y, z = z } or nil
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

function Actions.IsKnown(action)
    return type(action) == "string" and DEFINITIONS[action] ~= nil
end

function Actions.Start(task, timestamp)
    if type(task) ~= "table" or not Actions.IsKnown(task.action) then
        return false, "unknown survivor action"
    end
    task.status = "running"
    task.startedAt = task.startedAt or timestamp or nowMs()
    task.lastUpdateAt = timestamp or nowMs()
    task.repathMs = tonumber(task.repathMs)
        or DEFINITIONS[task.action].repathMs or 1000
    task.timeoutMs = tonumber(task.timeoutMs)
        or DEFINITIONS[task.action].timeoutMs or 30000
    return true
end

local function targetPoint(task, context)
    if type(context) ~= "table" or type(context.resolveTarget) ~= "function" then
        return nil
    end
    local ok, point = pcall(context.resolveTarget, task)
    return ok and point or nil
end

function Actions.Update(entity, task, timestamp, adapter, context)
    timestamp = timestamp or nowMs()
    if type(task) ~= "table" or type(adapter) ~= "table" then
        return "failed", "action context is malformed"
    end
    if task.status ~= "running" then
        local ok, detail = Actions.Start(task, timestamp)
        if not ok then return "failed", detail end
    end
    task.lastUpdateAt = timestamp
    if task.timeoutMs > 0 and timestamp - task.startedAt >= task.timeoutMs then
        return "timeout", "survivor action timed out"
    end

    if task.action == "Idle" then return "running", nil end
    if task.action == "Wait" then
        local duration = tonumber(task.durationMs) or 1000
        return timestamp - task.startedAt >= duration and "complete" or "running", nil
    end
    if task.action == "Speak" then
        if task.spoken ~= true then
            if type(adapter.say) ~= "function" then return "failed", "speech unavailable" end
            local ok = adapter.say(entity, task.text, task.survivorId)
            if not ok then return "failed", "speech was rejected" end
            task.spoken = true
        end
        return "complete", nil
    end
    if task.action == "MeleeAttack" then
        if task.target == nil or type(adapter.setCombatTarget) ~= "function" then
            return "failed", "melee target is unavailable"
        end
        local ok, detail = Combat.attack(entity, task.target, adapter, task.survivorId)
        return ok and "running" or "failed", ok and nil or detail
    end
    if task.action == "GetUp" or task.action == "Recover" then
        if type(adapter.recover) == "function" then pcall(adapter.recover, entity) end
        return "complete", nil
    end
    if task.action == "Move" or task.action == "GoTo"
        or task.action == "Follow" or task.action == "ReturnHome" then
        local point = targetPoint(task, context)
        if point ~= nil then
            task.x, task.y, task.z = point.x, point.y, point.z
        end
        if type(task.x) ~= "number" or type(task.y) ~= "number"
            or type(task.z) ~= "number" then
            return "failed", "movement task has no resolved destination"
        end
        local current = pointOf(entity)
        local arrive = tonumber(task.followDistance) or 2
        if current ~= nil and distanceSquared(current, task) <= arrive * arrive then
            if type(adapter.clearTasks) == "function" then
                pcall(adapter.clearTasks, entity, task.survivorId)
            end
            return task.action == "Follow" and "running" or "complete", nil
        end
        if task.lastPathAt == nil or timestamp - task.lastPathAt >= task.repathMs then
            if type(adapter.setTasks) ~= "function" then
                return "failed", "movement adapter is unavailable"
            end
            local ok = adapter.setTasks(entity, { task }, task.survivorId)
            if not ok then return "failed", "native path request was rejected" end
            task.lastPathAt = timestamp
        end
        return "running", nil
    end
    -- The action is intentionally represented and timed out even when its
    -- exact B42 animation contract is not yet verified.
    return "running", nil
end

function Actions.Cancel(entity, task, adapter)
    if type(adapter) == "table" and type(adapter.clearTasks) == "function" then
        pcall(adapter.clearTasks, entity, task and task.survivorId)
    end
    if type(task) == "table" then task.status = "cancelled" end
    return true
end

return Actions

-- The server chooses destinations. Only the engine's current simulation owner
-- issues native path commands; other peers render replicated motion.
local Config = require("GoblinSurvivor/Config")
local Motion = { paths = setmetatable({}, { __mode = "k" }) }

local function call(object, method, ...)
    if object == nil then return false, nil end
    local ok, member = pcall(function() return object[method] end)
    if not ok or type(member) ~= "function" then return false, nil end
    return pcall(member, object, ...)
end

function Motion.controls(body)
    if type(isClient) == "function" and isClient() then
        local ok, remote = call(body, "isRemoteZombie")
        return ok and remote == false
    end
    if type(isServer) == "function" and isServer() then
        local ok, owner = call(body, "getOwner")
        return ok and owner == nil
    end
    return true
end

function Motion.position(body)
    local _, x = call(body, "getX")
    local _, y = call(body, "getY")
    local _, z = call(body, "getZ")
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { x = x, y = y, z = z }
end

function Motion.distance(a, b)
    if not a or not b then return math.huge end
    return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2)
end

function Motion.followGoal(body, owner)
    local actor, leader = Motion.position(body), Motion.position(owner)
    if not actor or not leader then return nil end
    local gap = Motion.distance(actor, leader)
    -- One-tile bodyguard spacing is a product behavior, not a soft config
    -- suggestion. Enforce it on both server and simulation-owning clients so
    -- an older config.ini with GoblinFollowDistance=3 cannot widen the gap.
    local preferred = 1
    if math.floor(actor.z) == math.floor(leader.z) and gap <= preferred then
        return nil, gap
    end
    -- Path to the owner square so stair/door routing remains valid; stop at
    -- the preferred radius using the live owner distance, measured only once.
    return leader, gap
end

function Motion.stop(body)
    if not Motion.controls(body) then Motion.paths[body] = nil return end
    local _, behavior = call(body, "getPathFindBehavior2")
    call(behavior, "cancel")
    call(body, "setPath2", nil)
    call(body, "setPathing", false)
    call(body, "setVariable", "bPathfind", false)
    call(body, "setVariable", "bMoving", false)
    call(body, "setVariable", "GoblinMoveType", "IDLE")
    call(body, "setRunning", false)
    call(body, "setSprinting", false)
    call(body, "setWalkType", "Walk")
    call(body, "setSpeedTypeFromWalkType")
    call(body, "setUseless", true)
    Motion.paths[body] = nil
end

function Motion.drive(body, goal, moveType, timestamp)
    if not Motion.controls(body) then
        Motion.paths[body] = nil
        return true, "delegated"
    end
    if not goal then
        Motion.stop(body)
        return true, "arrived"
    end
    call(body, "setUseless", false)
    call(body, "setRunning", moveType == "RUN")
    call(body, "setVariable", "GoblinMoveType", moveType)
    local path = Motion.paths[body]
    local point = Motion.position(body)
    if not point then return false, "position unavailable" end
    if not path then
        path = { point = point, progressAt = timestamp, nextPathAt = 0, failures = 0 }
        Motion.paths[body] = path
    end
    if Motion.distance(point, path.point) > 0.1 then
        path.point, path.progressAt, path.failures = point, timestamp, 0
    end
    local stuck = timestamp - path.progressAt >= Config.stuckTimeoutSeconds * 1000
    local moved = not path.goal or Motion.distance(goal, path.goal) >= 0.75
    if timestamp >= path.nextPathAt and (moved or stuck) then
        -- Respect the engine repath cooldown; a moving leader doesn't reset
        -- progress detection, so a frozen actor is still reported/retried.
        local ok, result = call(body, "pathToLocationF", goal.x, goal.y, goal.z)
        path.nextPathAt = timestamp + Config.repathSeconds * 1000
        if not ok or result == false then return false, "native path rejected" end
        path.goal = { x = goal.x, y = goal.y, z = goal.z }
        if stuck then
            path.failures = path.failures + 1
            path.progressAt = timestamp
            if path.failures == 1 then print("[GoblinSurvivor] MOVEMENT_BLOCKED native path retry") end
        end
    end
    return true, "pathing"
end

return Motion

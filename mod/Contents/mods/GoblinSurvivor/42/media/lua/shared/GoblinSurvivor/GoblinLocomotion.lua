-- Server-selected navigation. Only the current engine simulation owner issues
-- native path commands; other peers render replicated motion.
local Config = require("GoblinSurvivor/Config")
local Hands = require("GoblinSurvivor/GoblinHands")
local Motion = {
    paths = setmetatable({}, { __mode = "k" }),
    followSlots = setmetatable({}, { __mode = "k" }),
    memories = setmetatable({}, { __mode = "k" }),
    leaderSamples = setmetatable({}, { __mode = "k" })
}
local rejoined = setmetatable({}, { __mode = "k" })

local function call(object, method, ...)
    if object == nil then return false, nil end
    local ok, member = pcall(function() return object[method] end)
    if not ok or type(member) ~= "function" then return false, nil end
    return pcall(member, object, ...)
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function data(body)
    local _, value = call(body, "getModData")
    return value
end

local function pointKey(point)
    if type(point) ~= "table" then return nil end
    return table.concat({ math.floor(point.x or 0), math.floor(point.y or 0), math.floor(point.z or 0) }, ":")
end

local function memory(body, timestamp)
    local current = Motion.memories[body]
    if not current then
        current = { blocked_edges = {}, failed_targets = {}, failed_approaches = {} }
        Motion.memories[body] = current
    end
    timestamp = timestamp or nowMs()
    for _, entries in pairs(current) do
        for key, expires in pairs(entries) do if expires <= timestamp then entries[key] = nil end end
    end
    return current
end

local function memoryKind(kind)
    if kind == "edge" then return "blocked_edges" end
    if kind == "approach" then return "failed_approaches" end
    return "failed_targets"
end

function Motion.blacklist(body, point, reason, timestamp, kind)
    local key = type(point) == "string" and point or pointKey(point)
    if not key then return false end
    timestamp = timestamp or nowMs()
    memory(body, timestamp)[memoryKind(kind)][key] = timestamp
        + (tonumber(Config.navigationBlacklistSeconds) or 30) * 1000
    local md = data(body)
    if md then
        md.GoblinBlockedReason = tostring(reason or "native path made no progress")
        md.GoblinBlockedEdge = key
    end
    return true
end

function Motion.isBlacklisted(body, point, timestamp, kind)
    local key = type(point) == "string" and point or pointKey(point)
    return key ~= nil and memory(body, timestamp)[memoryKind(kind)][key] ~= nil
end

function Motion.clearBlacklistKind(body, kind)
    memory(body)[memoryKind(kind)] = {}
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

function Motion.simulationOwner(body)
    if type(isClient) == "function" and isClient() then
        local ok, remote = call(body, "isRemoteZombie")
        return ok and remote == false and "client" or "remote"
    end
    if type(isServer) == "function" and isServer() then
        local ok, owner = call(body, "getOwner")
        return ok and owner == nil and "server" or "client"
    end
    return "singleplayer"
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

local function squareAt(point)
    if type(getCell) ~= "function" or not point then return nil end
    local ok, cell = pcall(getCell)
    if not ok or not cell then return nil end
    return select(2, call(cell, "getGridSquare", math.floor(point.x), math.floor(point.y), math.floor(point.z)))
end

local function occupied(square, body, owner)
    local _, list = call(square, "getMovingObjects")
    local _, size = call(list, "size")
    for index = 0, (tonumber(size) or 0) - 1 do
        local _, value = call(list, "get", index)
        if value and value ~= body and value ~= owner then return true end
    end
    return false
end

local function doorway(square)
    local _, objects = call(square, "getObjects")
    local _, size = call(objects, "size")
    for index = 0, (tonumber(size) or 0) - 1 do
        local _, object = call(objects, "get", index)
        local _, isDoor = call(object, "isDoor")
        local _, isFrame = call(object, "isDoorFrame")
        if isDoor == true or isFrame == true then return true end
    end
    return false
end

local slotOffsets = {
    { 4, 0 }, { 3, 3 }, { 0, 4 }, { -3, 3 },
    { -4, 0 }, { -3, -3 }, { 0, -4 }, { 3, -3 }
}

local function leaderDirection(owner, leader, timestamp)
    local previous = Motion.leaderSamples[owner]
    Motion.leaderSamples[owner] = { x = leader.x, y = leader.y, at = timestamp }
    if not previous then return 0, 0 end
    local dx, dy = leader.x - previous.x, leader.y - previous.y
    if dx * dx + dy * dy < 0.01 then return 0, 0 end
    local length = math.sqrt(dx * dx + dy * dy)
    return dx / length, dy / length
end

local function stableFollowGoal(body, owner, actor, leader, timestamp)
    local current = Motion.followSlots[body]
    local moveX, moveY = leaderDirection(owner, leader, timestamp)
    local best, bestScore
    for index, offset in ipairs(slotOffsets) do
        local candidate = { x = math.floor(leader.x) + offset[1] + 0.5,
            y = math.floor(leader.y) + offset[2] + 0.5, z = math.floor(leader.z), slot = index }
        local square = squareAt(candidate)
        local freeOK, free = call(square, "isFree", false)
        local _, fire = call(square, "haveFire")
        if square and freeOK and free == true and fire ~= true and not occupied(square, body, owner)
            and not Motion.isBlacklisted(body, candidate, timestamp, "target") then
            local distance = (candidate.x-actor.x)^2 + (candidate.y-actor.y)^2
            local side = offset[1] * moveX + offset[2] * moveY
            local score = distance + (doorway(square) and 12 or 0) + math.max(0, side) * 2
            if current == index then score = score - 30 end
            if not bestScore or score < bestScore then best, bestScore = candidate, score end
        end
    end
    if best then Motion.followSlots[body] = best.slot end
    return best
end

function Motion.clearFollowSlot(body)
    Motion.followSlots[body] = nil
end

function Motion.followGoal(body, owner, timestamp)
    local _, dead = call(owner, "isDead")
    if dead == true then return nil end
    local actor, leader = Motion.position(body), Motion.position(owner)
    if not actor or not leader then return nil end
    timestamp = timestamp or nowMs()
    local gap = Motion.distance(actor, leader)
    if math.floor(actor.z) ~= math.floor(leader.z) or gap > 6 then
        return leader, gap, { goal_type = "character", follow_target = owner, goal_key = "character" }
    end
    local adjacent = math.abs(math.floor(actor.x)-math.floor(leader.x)) <= 1
        and math.abs(math.floor(actor.y)-math.floor(leader.y)) <= 1
    local needsClearance = adjacent or gap < 2.5
    if gap <= (tonumber(Config.followPreferredDistance) or 3) and not needsClearance then
        return nil, gap, { goal_type = "follow_slot", goal_key = "arrived" }
    end
    local slot = stableFollowGoal(body, owner, actor, leader, timestamp)
    if not slot then
        if gap <= (tonumber(Config.followPreferredDistance) or 3) then
            return nil, gap, { goal_type = "follow_slot", goal_key = "clearance-unavailable" }
        end
        return leader, gap, { goal_type = "character", follow_target = owner, goal_key = "character-fallback" }
    end
    local _, ownerRunning = call(owner, "isRunning")
    local _, ownerSprinting = call(owner, "isSprinting")
    if ownerRunning ~= true and ownerSprinting ~= true and not needsClearance
        and Motion.distance(actor, slot) <= 0.25 then
        return nil, gap, { goal_type = "follow_slot", slot = slot.slot, goal_key = "slot:" .. slot.slot }
    end
    return slot, gap, { goal_type = "follow_slot", slot = slot.slot, goal_key = "slot:" .. slot.slot }
end

function Motion.moveType(goal, gap, owner)
    if not goal then return "IDLE" end
    local _, running = call(owner, "isRunning")
    local _, sprinting = call(owner, "isSprinting")
    if running == true or sprinting == true or (gap or 0) >= Config.followRunDistance then return "RUN" end
    return "WALK"
end

local function setNavigation(body, path, state, reason, timestamp)
    local md = data(body)
    if not md then return end
    local owner = Motion.simulationOwner(body)
    local failures = path and path.failures or 0
    local goalKey = path and path.goalKey or nil
    local lastMovement = path and path.lastSuccessfulMovement or nil
    local changed = md.GoblinPathState ~= state
        or md.GoblinBlockedReason ~= reason
        or md.GoblinCurrentApproach ~= goalKey
        or md.GoblinNavigationSimulationOwner ~= owner
        or (tonumber(md.GoblinPathFailureCount) or 0) ~= failures
        or md.GoblinLastSuccessfulMovementAt ~= lastMovement
    md.GoblinPathState = state
    md.GoblinPathStartedAt = path and path.startedAt or nil
    md.GoblinLastProgressAt = path and path.progressAt or nil
    md.GoblinPathFailureCount = failures
    md.GoblinBlockedReason = reason
    if state ~= "blocked" then md.GoblinBlockedEdge = nil end
    md.GoblinCurrentApproach = goalKey
    md.GoblinNavigationGoalType = path and path.goalType or nil
    md.GoblinNavigationSimulationOwner = owner
    if changed then md.GoblinNavigationRevision = (tonumber(md.GoblinNavigationRevision) or 0) + 1 end
    md.GoblinLastSuccessfulMovementAt = lastMovement
    if timestamp then md.GoblinNavigationUpdatedAt = timestamp end
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
    setNavigation(body, nil, "idle", nil, nowMs())
end

function Motion.rejoin(body, point, sequence, expires, timestamp)
    if type(point) ~= "table" or type(sequence) ~= "number" or type(expires) ~= "number"
        or timestamp > expires or rejoined[body] == sequence or not Motion.controls(body) then return false end
    for _, key in ipairs({"x","y","z"}) do
        if type(point[key]) ~= "number" or point[key] ~= point[key] or math.abs(point[key]) > 1000000 then return false end
    end
    local square = getCell():getGridSquare(math.floor(point.x), math.floor(point.y), math.floor(point.z))
    if not square then return false end
    Motion.stop(body)
    local ok = call(body, "teleportTo", math.floor(point.x), math.floor(point.y), math.floor(point.z))
    if ok then rejoined[body] = sequence end
    return ok
end

local function nativePath(body, goal, options, coordinateOnly)
    if not coordinateOnly and options and options.goal_type == "character" and options.follow_target then
        local ok, result = call(body, "pathToCharacter", options.follow_target)
        if ok and result ~= false then return true, "character" end
    end
    local ok, result = call(body, "pathToLocationF", goal.x, goal.y, goal.z)
    return ok and result ~= false, coordinateOnly and "location-repath" or "location"
end

function Motion.drive(body, goal, moveType, timestamp, options)
    options = options or {}
    timestamp = timestamp or nowMs()
    if goal or Hands.travelling(body) then Hands.stow(body) end
    local _, vehicle = call(body, "getVehicle")
    if vehicle then Motion.stop(body); return true, "riding" end
    if not Motion.controls(body) then
        Motion.paths[body] = nil
        setNavigation(body, nil, "delegated", nil, timestamp)
        return true, "delegated"
    end
    if not goal then Motion.stop(body); return true, "arrived" end
    if Motion.isBlacklisted(body, goal, timestamp, options.blacklist_kind) then
        setNavigation(body, nil, "blocked", "temporarily blacklisted route", timestamp)
        return false, "temporarily blacklisted route"
    end

    call(body, "setRunning", false)
    call(body, "setSprinting", false)
    call(body, "setWalkType", moveType == "RUN" and "sprint" or "Walk")
    call(body, "setSpeedTypeFromWalkType")
    call(body, "setVariable", "GoblinMoveType", moveType)

    local point = Motion.position(body)
    if not point then return false, "position unavailable" end
    local goalKey = options.goal_key or pointKey(goal)
    local goalType = options.goal_type or "location"
    local path = Motion.paths[body]
    if not path or path.goalKey ~= goalKey or path.goalType ~= goalType then
        path = { point = point, progressAt = timestamp, startedAt = timestamp, nextPathAt = 0,
            failures = 0, goalKey = goalKey, goalType = goalType }
        Motion.paths[body] = path
    end
    if Motion.distance(point, path.point) > 0.1 then
        path.point, path.progressAt, path.failures = point, timestamp, 0
        path.lastSuccessfulMovement = timestamp
    end
    local stuck = timestamp - path.progressAt >= Config.stuckTimeoutSeconds * 1000
    local changed = not path.goal or Motion.distance(goal, path.goal) >= 0.75
    if options.obstruction_cleared then path.nextPathAt = 0; changed = true end
    if stuck and path.failures >= 1 then
        Motion.blacklist(body, goal, "no progress after native repath", timestamp, options.blacklist_kind)
        setNavigation(body, path, "blocked", "no progress after native repath", timestamp)
        Motion.paths[body] = nil
        return false, "no progress after native repath"
    end
    if timestamp >= path.nextPathAt and (not path.goal or changed or stuck) then
        call(body, "setUseless", false)
        -- A character-target path is preferred for a moving owner. If it
        -- makes no progress, the one allowed native repath uses the owner's
        -- current coordinates so Build 42 cannot keep retrying a stale
        -- character target indefinitely.
        local ok, route = nativePath(body, goal, options, stuck and path.failures == 0)
        path.nextPathAt = timestamp + Config.repathSeconds * 1000
        if not ok then
            Motion.blacklist(body, goal, "native path rejected", timestamp, options.blacklist_kind)
            setNavigation(body, path, "blocked", "native path rejected", timestamp)
            Motion.paths[body] = nil
            return false, "native path rejected"
        end
        path.route = route
        path.goal = { x = goal.x, y = goal.y, z = goal.z }
        if stuck then
            path.failures = path.failures + 1
            path.progressAt = timestamp
            print("[GoblinSurvivor] MOVEMENT_REPATH goal=" .. tostring(goalKey) .. " attempt=" .. path.failures)
        end
    end
    setNavigation(body, path, "pathing", nil, timestamp)
    return true, "pathing"
end

function Motion.snapshot(body, timestamp)
    local md = data(body) or {}
    timestamp = timestamp or nowMs()
    return {
        path_state = md.GoblinPathState or "idle",
        goal_type = md.GoblinNavigationGoalType,
        approach_target = md.GoblinCurrentApproach,
        progress_age_ms = md.GoblinLastProgressAt and math.max(0, timestamp-md.GoblinLastProgressAt) or nil,
        retry_count = tonumber(md.GoblinPathFailureCount) or 0,
        blocked_reason = md.GoblinBlockedReason,
        blocked_edge = md.GoblinBlockedEdge,
        simulation_owner = md.GoblinNavigationSimulationOwner or Motion.simulationOwner(body),
        last_successful_movement_at = md.GoblinLastSuccessfulMovementAt,
        revision = tonumber(md.GoblinNavigationRevision) or 0
    }
end

return Motion

-- Server-selected navigation. Only the current engine simulation owner issues
-- native path commands; other peers render replicated motion.
local Config = require("GoblinSurvivor/Config")
local Hands = require("GoblinSurvivor/GoblinHands")
local Motion = {
    paths = setmetatable({}, { __mode = "k" }),
    followSlots = setmetatable({}, { __mode = "k" }),
    followDetours = setmetatable({}, { __mode = "k" }),
    workDetours = setmetatable({}, { __mode = "k" }),
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

local function validCoordinate(value)
    return type(value) == "number" and value == value and math.abs(value) <= 1000000
end

function Motion.validPoint(point)
    return type(point) == "table" and validCoordinate(point.x)
        and validCoordinate(point.y) and validCoordinate(point.z)
end

local function pointKey(point)
    if not Motion.validPoint(point) then return nil end
    return table.concat({ math.floor(point.x), math.floor(point.y), math.floor(point.z) }, ":")
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
    local point = { x = x, y = y, z = z }
    return Motion.validPoint(point) and point or nil
end

function Motion.distance(a, b)
    if not Motion.validPoint(a) or not Motion.validPoint(b) then return math.huge end
    return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2)
end

local function squareAt(point)
    if type(getCell) ~= "function" or not point then return nil end
    local ok, cell = pcall(getCell)
    if not ok or not cell then return nil end
    return select(2, call(cell, "getGridSquare", math.floor(point.x), math.floor(point.y), math.floor(point.z)))
end

local function occupied(square, body, owner)
    local gotList, list = call(square, "getMovingObjects")
    local gotSize, size = call(list, "size")
    if not gotList or not list or not gotSize or type(size) ~= "number"
        or size ~= math.floor(size) or size < 0 or size > 10000 then return true end
    for index = 0, size - 1 do
        local gotValue, value = call(list, "get", index)
        if not gotValue or not value then return true end
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

local function edgeOpen(fromSquare, toSquare)
    local checked, blocked = call(fromSquare, "isBlockedTo", toSquare)
    return checked and blocked == false
end

local function localRouteClear(fromSquare, destination)
    local target = squareAt(destination)
    if not fromSquare or not target then return false end
    local _, x = call(fromSquare, "getX")
    local _, y = call(fromSquare, "getY")
    local _, z = call(fromSquare, "getZ")
    local _, targetX = call(target, "getX")
    local _, targetY = call(target, "getY")
    local _, targetZ = call(target, "getZ")
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number"
        or type(targetX) ~= "number" or type(targetY) ~= "number"
        or targetZ ~= z then return false end
    local current = fromSquare
    -- Follow slots are at most four tiles away. Walk the short grid line and
    -- reject a slot on the other side of a closed door, wall or window. This
    -- prevents a nominally valid slot from ending movement before Goblin ever
    -- reaches the blocking edge where GoblinAccess can open the door.
    for _ = 1, 12 do
        if x == targetX and y == targetY then return true end
        local stepX = targetX == x and 0 or (targetX > x and 1 or -1)
        local stepY = targetY == y and 0 or (targetY > y and 1 or -1)
        local nextSquare = squareAt({ x = x + stepX + 0.5, y = y + stepY + 0.5, z = z })
        if not nextSquare then return false end
        -- An unavailable/failed native edge check is not evidence of a clear
        -- route. Otherwise FOLLOW can settle on a slot behind an obstacle.
        if not edgeOpen(current, nextSquare) then return false end
        if stepX ~= 0 and stepY ~= 0 then
            local sideX = squareAt({ x = x + stepX + 0.5, y = y + 0.5, z = z })
            local sideY = squareAt({ x = x + 0.5, y = y + stepY + 0.5, z = z })
            local viaX = sideX and edgeOpen(current, sideX) and edgeOpen(sideX, nextSquare)
            local viaY = sideY and edgeOpen(current, sideY) and edgeOpen(sideY, nextSquare)
            if not viaX and not viaY then return false end
        end
        current, x, y = nextSquare, x + stepX, y + stepY
    end
    return false
end

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
        local fireOK, fire = call(square, "haveFire")
        if square and freeOK and free == true and fireOK and fire == false
            and not occupied(square, body, owner)
            and localRouteClear(square, leader)
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

-- The native character path can repeatedly select a blocked straight line
-- through furniture or a building. After its bounded repath has *actually*
-- failed, try one loaded, open-edge waypoint instead. The search is local,
-- same-floor, and never writes the actor's position or opens an object.
local function blockedFollowDetour(body, owner, actor, leader, timestamp, workRoute)
    if math.floor(actor.z) ~= math.floor(leader.z)
        or Motion.distance(actor, leader) > 32 then return nil end
    -- A work destination need not be a tile centre. Once its tile is reached,
    -- retain the requested final coordinate instead of circling its centre.
    if workRoute and math.floor(actor.x) == math.floor(leader.x)
        and math.floor(actor.y) == math.floor(leader.y)
        and localRouteClear(squareAt(actor), leader) then
        return { x = leader.x, y = leader.y, z = leader.z }
    end
    local leaderKey = pointKey(leader)
    local cache = workRoute and Motion.workDetours or Motion.followDetours
    local previous = cache[body]
    if previous and previous.leaderKey == leaderKey and timestamp < previous.expires then
        if not previous.waypoint then return nil end
        if Motion.distance(actor, previous.waypoint) > 0.45
            and not Motion.isBlacklisted(body, previous.waypoint, timestamp, "approach") then
            return previous.waypoint
        end
    end
    local x, y, z = math.floor(actor.x), math.floor(actor.y), math.floor(actor.z)
    local start = squareAt(actor)
    if not start then return nil end
    local targetX, targetY = math.floor(leader.x), math.floor(leader.y)
    local function heuristic(nx, ny)
        return math.abs(nx - targetX) + math.abs(ny - targetY)
    end
    local queue = { { square = start, x = x, y = y, cost = 0,
        estimate = heuristic(x, y) } }
    local bestCost = { [x .. ":" .. y] = 0 }
    local expanded = 0
    local waypoint
    local firstNeighborStatus = {}
    local offsets = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
    -- A yard fence can extend well beyond the twelve tiles around an actor.
    -- Keep the search finite, but allow it to reach a loaded gate/end before
    -- declaring the owner unreachable.
    while #queue > 0 and expanded < 1024 do
        -- Prefer a loaded route toward the leader. FIFO exploration spends
        -- its entire budget around the actor for a diagonal 15-tile gap.
        local best = 1
        for index = 2, #queue do
            local candidate, selected = queue[index], queue[best]
            local candidateScore = candidate.cost + candidate.estimate
            local selectedScore = selected.cost + selected.estimate
            if candidateScore < selectedScore or (candidateScore == selectedScore
                and candidate.estimate < selected.estimate) then best = index end
        end
        local node = table.remove(queue, best)
        expanded = expanded + 1
        local center = { x = node.x + 0.5, y = node.y + 0.5, z = z }
        if node.first and ((workRoute and node.x == targetX and node.y == targetY)
            or (not workRoute and Motion.distance(center, leader) <= 3))
            and localRouteClear(node.square, leader) then
            waypoint = node.first
            break
        end
        for _, offset in ipairs(offsets) do
            local nx, ny = node.x + offset[1], node.y + offset[2]
            local key = nx .. ":" .. ny
            local nextCost = node.cost + 1
            if (bestCost[key] == nil or nextCost < bestCost[key])
                and math.abs(nx - x) <= 24 and math.abs(ny - y) <= 24 then
                local nextSquare = squareAt({ x = nx + 0.5, y = ny + 0.5, z = z })
                local freeOK, free = call(nextSquare, "isFree", false)
                local fireOK, fire = call(nextSquare, "haveFire")
                local nextPoint = { x = nx + 0.5, y = ny + 0.5, z = z }
                local open = nextSquare and edgeOpen(node.square, nextSquare)
                local occupiedSquare = nextSquare and occupied(nextSquare, body, owner)
                -- A failed full FOLLOW target can still be the only open
                -- transit tile. Detour waypoints have their own failure
                -- memory so a prior target failure does not seal the exit.
                local blacklisted = Motion.isBlacklisted(body, nextPoint, timestamp, "approach")
                if expanded == 1 then
                    firstNeighborStatus[#firstNeighborStatus + 1] = key
                        .. ":" .. (not nextSquare and "unloaded"
                            or not freeOK and "free_error"
                            or free ~= true and "not_free"
                            or not fireOK and "fire_error"
                            or fire ~= false and "fire"
                            or not open and "edge_blocked"
                            or occupiedSquare and "occupied"
                            or blacklisted and "blacklisted" or "open")
                end
                if nextSquare and freeOK and free == true and fireOK and fire == false
                    and open and not occupiedSquare and not blacklisted then
                    -- A blocked edge is not a blocked square. Leave it unseen
                    -- so another approach can enter from an open side.
                    bestCost[key] = nextCost
                    queue[#queue + 1] = { square = nextSquare, x = nx, y = ny,
                        first = node.first or nextPoint, cost = nextCost,
                        estimate = heuristic(nx, ny) }
                end
            end
        end
    end
    if waypoint and (not previous or not previous.waypoint
        or pointKey(previous.waypoint) ~= pointKey(waypoint)) then
        local md = data(body) or {}
        print("[GoblinSurvivor] " .. (workRoute and "WORK_DETOUR" or "FOLLOW_DETOUR") .. " blocked_goal="
            .. tostring(md.GoblinNavigationGoalType) .. " from=" .. pointKey(actor)
            .. " waypoint=" .. pointKey(waypoint) .. " leader=" .. leaderKey)
    end
    local failedLogAt = previous and previous.leaderKey == leaderKey
        and previous.failedLogAt or 0
    if not waypoint and timestamp - failedLogAt >= 10000 then
        failedLogAt = timestamp
        print("[GoblinSurvivor] " .. (workRoute and "WORK_DETOUR_UNAVAILABLE" or "FOLLOW_DETOUR_UNAVAILABLE") .. " from=" .. pointKey(actor)
            .. " leader=" .. leaderKey .. " expanded=" .. expanded
            .. " frontier=" .. #queue
            .. (expanded == 1 and " neighbors=" .. table.concat(firstNeighborStatus, ",") or ""))
    end
    cache[body] = { leaderKey = leaderKey, waypoint = waypoint,
        expires = timestamp + (waypoint and 2000 or 5000), failedLogAt = failedLogAt }
    return waypoint
end

function Motion.clearFollowSlot(body)
    Motion.followSlots[body] = nil
    Motion.followDetours[body] = nil
end

function Motion.followGoal(body, owner, timestamp)
    local _, dead = call(owner, "isDead")
    if dead == true then return nil end
    local actor, leader = Motion.position(body), Motion.position(owner)
    if not actor or not leader then return nil end
    timestamp = timestamp or nowMs()
    local gap = Motion.distance(actor, leader)
    -- Replicated zombie positions and follow slots jitter around the desired
    -- radius. Do not chase another slot for a fraction of a tile when there
    -- is an unobstructed route to the owner.
    local _, ownerRunning = call(owner, "isRunning")
    local _, ownerSprinting = call(owner, "isSprinting")
    local arrivalDistance = tonumber(Config.followPreferredDistance) or 3
    if ownerRunning ~= true and ownerSprinting ~= true then
        arrivalDistance = arrivalDistance + 0.4
    end
    local md = data(body)
    local blockedFollow = Motion.isBlacklisted(body, leader, timestamp, "target")
        or (md and md.GoblinPathState == "blocked"
            and (md.GoblinNavigationGoalType == "character"
                or md.GoblinNavigationGoalType == "follow_slot"
                or md.GoblinNavigationGoalType == "follow_detour"))
    if blockedFollow and gap <= arrivalDistance
        and localRouteClear(squareAt(actor), leader) then blockedFollow = false end
    if blockedFollow then
        local detour = blockedFollowDetour(body, owner, actor, leader, timestamp)
        if detour then
            return detour, gap, { goal_type = "follow_detour",
                goal_key = "detour:" .. pointKey(detour),
                blacklist_kind = "approach" }
        end
    end
    if math.floor(actor.z) ~= math.floor(leader.z) or gap > 6 then
        return leader, gap, { goal_type = "character", follow_target = owner, goal_key = "character" }
    end
    local actorSquare, leaderSquare = squareAt(actor), squareAt(leader)
    -- Short-range following needs both streamed endpoints before selecting a
    -- slot or falling back to a character path. The normal spawn gap can be
    -- larger than the preferred follow distance; it still must wait here.
    if not actorSquare or not leaderSquare then
        return nil, gap, { goal_type = "follow_slot", goal_key = "squares-unavailable" }
    end
    local actorLocallyConnected = localRouteClear(actorSquare, leader)
    local adjacent = math.abs(math.floor(actor.x)-math.floor(leader.x)) <= 1
        and math.abs(math.floor(actor.y)-math.floor(leader.y)) <= 1
    local needsClearance = adjacent or gap < 2.5
    if gap <= arrivalDistance and not needsClearance
        and actorLocallyConnected then
        return nil, gap, { goal_type = "follow_slot", goal_key = "arrived" }
    end
    local slot = stableFollowGoal(body, owner, actor, leader, timestamp)
    if not slot then
        if gap <= arrivalDistance and actorLocallyConnected then
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
    local previousState = md.GoblinPathState
    local previousGoalType = md.GoblinNavigationGoalType
    local previousLastMovement = md.GoblinLastSuccessfulMovementAt
    local owner = Motion.simulationOwner(body)
    local failures = path and path.failures or 0
    local goalKey = path and path.goalKey or nil
    local lastMovement = path and path.lastSuccessfulMovement or previousLastMovement
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
    if state == "blocked" and previousState ~= "blocked" then
        local _, nativeState = call(body, "getCurrentStateName")
        local _, pathing = call(body, "isPathing")
        local _, pathVariable = call(body, "getVariableBoolean", "bPathfind")
        local _, movingVariable = call(body, "getVariableBoolean", "bMoving")
        local _, nativePath = call(body, "getPath2")
        local _, behavior = call(body, "getPathFindBehavior2")
        local _, shouldMove = call(behavior, "shouldBeMoving")
        local _, collided = call(body, "isCollidedThisFrame")
        local _, useless = call(body, "isUseless")
        local _, canWalk = call(body, "isCanWalk")
        local _, targetX = call(behavior, "getTargetX")
        local _, targetY = call(behavior, "getTargetY")
        local _, targetZ = call(behavior, "getTargetZ")
        local _, animating = call(body, "isAnimationUpdatingThisFrame")
        local _, turning = call(behavior, "isTurningToObstacle")
        local _, animationState = call(body, "getAnimationStateName")
        local _, actionState = call(body, "getCurrentActionContextStateName")
        local _, animationMove = call(body, "getVariableString", "GoblinMoveType")
        local _, animationAction = call(body, "getVariableString", "GoblinAction")
        local deferredLength
        if Vector2 then
            local made, vector = pcall(function() return Vector2.new() end)
            if made and vector then
                local read = call(body, "getDeferredMovement", vector)
                if read then _, deferredLength = call(vector, "getLength") end
            end
        end
        print("[GoblinSurvivor] NAV_BLOCKED task=" .. tostring(md.GoblinNavigationTask or md.GoblinTask)
            .. " goal_type=" .. tostring(path and path.goalType or previousGoalType)
            .. " approach=" .. tostring(goalKey or md.GoblinBlockedEdge)
            .. " progress_age_ms=" .. tostring(path and timestamp and path.progressAt
                and timestamp - path.progressAt)
            .. " retries=" .. tostring(failures)
            .. " reason=" .. tostring(reason)
            .. " simulation_owner=" .. tostring(owner)
            .. " last_movement_at=" .. tostring(lastMovement or previousLastMovement)
            .. " native_state=" .. tostring(nativeState)
            .. " pathing=" .. tostring(pathing)
            .. " bPathfind=" .. tostring(pathVariable)
            .. " bMoving=" .. tostring(movingVariable)
            .. " has_path2=" .. tostring(nativePath ~= nil)
            .. " should_move=" .. tostring(shouldMove)
            .. " collided=" .. tostring(collided)
            .. " useless=" .. tostring(useless)
            .. " can_walk=" .. tostring(canWalk)
            .. " animation_update=" .. tostring(animating)
            .. " deferred_length=" .. tostring(deferredLength)
            .. " turning_to_obstacle=" .. tostring(turning)
            .. " animation_state=" .. tostring(animationState)
            .. " action_state=" .. tostring(actionState)
            .. " animation_move=" .. tostring(animationMove)
            .. " animation_action=" .. tostring(animationAction)
            .. " native_target=" .. tostring(targetX) .. ":" .. tostring(targetY)
                .. ":" .. tostring(targetZ))
    end
end

local function cancelNativeRoute(body)
    local _, behavior = call(body, "getPathFindBehavior2")
    call(behavior, "cancel")
    call(body, "setPath2", nil)
    call(body, "setPathing", false)
    call(body, "setVariable", "bPathfind", false)
    call(body, "setVariable", "bMoving", false)
end

function Motion.stop(body)
    Motion.workDetours[body] = nil
    if not Motion.controls(body) then
        Motion.paths[body], Motion.followDetours[body] = nil, nil
        return
    end
    cancelNativeRoute(body)
    call(body, "setVariable", "GoblinMoveType", "IDLE")
    call(body, "setRunning", false)
    call(body, "setSprinting", false)
    call(body, "setWalkType", "Walk")
    call(body, "setSpeedTypeFromWalkType")
    call(body, "setUseless", true)
    Motion.paths[body] = nil
    Motion.followDetours[body] = nil
    setNavigation(body, nil, "idle", nil, nowMs())
end

function Motion.rejoin(body, point, sequence, expires, timestamp)
    if type(point) ~= "table" or type(sequence) ~= "number" or type(expires) ~= "number"
        or timestamp > expires or rejoined[body] == sequence then return false end
    for _, key in ipairs({"x","y","z"}) do
        if type(point[key]) ~= "number" or point[key] ~= point[key] or math.abs(point[key]) > 1000000 then return false end
    end
    local square = getCell():getGridSquare(math.floor(point.x), math.floor(point.y), math.floor(point.z))
    if not square then return false end
    local controlled = Motion.controls(body)
    if not controlled and not (type(isServer) == "function" and isServer()
        and type(goblinServerRejoin) == "function") then return false end
    Motion.stop(body)
    local x,y,z=math.floor(point.x),math.floor(point.y),math.floor(point.z)
    local ok
    if controlled then
        ok=call(body,"teleportTo",x,y,z)
    else
        local called,result=pcall(goblinServerRejoin,body,x,y,z)
        ok=called and result==true
    end
    -- The Lua call may return successfully even when native authority has not
    -- moved the actor. Keep the sequence retryable until position agrees.
    local arrived = ok and Motion.position(body)
    ok = arrived and math.floor(arrived.x) == x and math.floor(arrived.y) == y
        and math.floor(arrived.z) == z or false
    if ok then rejoined[body] = sequence end
    return ok
end

local function nativePath(body, goal, options, coordinateOnly)
    -- Installed IsoZombie.pathToCharacter/pathToLocationF may silently return
    -- (void) during allowRepathDelay in walking/pathfinding states. Lua cannot
    -- access that Java field in the live client. For the one bounded stuck
    -- retry, submit directly to the same native PathFindBehavior2 used by the
    -- wrapper, then enter its native state so update() services the route.
    if coordinateOnly then
        local _, current = call(body, "getCurrentStateName")
        if current == "PathFindState" then
            -- PathFindBehavior2.cancel() only sets isCancel. Native
            -- PathFindState.exit cancels the queued request, resets the finder
            -- to notrunning and drops Path2. Re-entering the same state skips
            -- that cleanup, leaving a stalled request alive across retries.
            local exited, idle = pcall(function() return ZombieIdleState.instance() end)
            if not exited or not idle or not call(body, "changeState", idle) then
                return false, "native pathfinder reset unavailable"
            end
        end
        local _, behavior = call(body, "getPathFindBehavior2")
        local submitted = call(behavior, "pathToLocationF", goal.x, goal.y, goal.z)
        local state = PathFindState
        local ok, instance = false, nil
        if state then ok, instance = pcall(function() return state.instance() end) end
        if not submitted or not ok or not instance then
            return false, "native pathfinder recovery unavailable"
        end
        call(body, "setVariable", "bPathfind", true)
        call(body, "setVariable", "bMoving", false)
        if not call(body, "changeState", instance) then
            return false, "native pathfinder state unavailable"
        end
        print("[GoblinSurvivor] NAV_NATIVE_REPATH goal=" .. pointKey(goal))
        return true, "location-repath"
    end
    if not coordinateOnly and options and options.goal_type == "character" and options.follow_target then
        local ok, result = call(body, "pathToCharacter", options.follow_target)
        if ok and result ~= false then return true, "character" end
    end
    local ok, result = call(body, "pathToLocationF", goal.x, goal.y, goal.z)
    return ok and result ~= false, coordinateOnly and "location-repath" or "location"
end

local function leaveNativeIdleForPath(body)
    -- B42's ZombieIdleState.execute zeros movex/movey every update. A native
    -- path request can set bMoving/bPathfind while leaving the state machine in
    -- ZombieIdleState, so an accepted route alone does not make Goblin move.
    local checked, state = call(body, "getCurrentStateName")
    if not checked or state ~= "ZombieIdleState" then return end
    local _, pathfind = call(body, "getVariableBoolean", "bPathfind")
    local nativeState
    if pathfind == true then nativeState = PathFindState else nativeState = WalkTowardState end
    if not nativeState then return end
    local ok, instance = pcall(function() return nativeState.instance() end)
    if ok and instance then
        local entered = call(body, "changeState", instance)
        if entered then
            print("[GoblinSurvivor] NAV_IDLE_RECOVERY state="
                ..(pathfind == true and "PathFindState" or "WalkTowardState"))
        end
    end
end

function Motion.drive(body, goal, moveType, timestamp, options)
    options = options or {}
    timestamp = timestamp or nowMs()
    if type(options.current_task) == "string" then
        local md = data(body)
        if md then md.GoblinNavigationTask = options.current_task end
    end
    if goal and not Motion.validPoint(goal) then return false, "invalid destination" end
    if goal or Hands.travelling(body) then Hands.stow(body) end
    local _, vehicle = call(body, "getVehicle")
    if vehicle then Motion.stop(body); return true, "riding" end
    if not Motion.controls(body) then
        Motion.paths[body] = nil
        setNavigation(body, nil, "delegated", nil, timestamp)
        return true, "delegated"
    end
    if not goal then Motion.stop(body); return true, "arrived" end
    -- Work orders use coordinate goals too. Previously only FOLLOW consumed
    -- the loaded-edge detour search; a work goal kept retrying the same wall
    -- after each blacklist expired. Keep its exact destination, but service
    -- it via open-edge waypoints on the native simulation owner.
    if not options.goal_type or options.goal_type == "location" then
        local saved = Motion.workDetours[body]
        local blocked = Motion.isBlacklisted(body, goal, timestamp, options.blacklist_kind)
        if blocked or (saved and saved.leaderKey == pointKey(goal)) then
            local actor = Motion.position(body)
            if actor and Motion.distance(actor, goal) > 0.01 then
                local waypoint = blockedFollowDetour(body, nil, actor, goal, timestamp, true)
                if waypoint then
                    goal = waypoint
                    options = { goal_type = "work_detour", goal_key = "work-detour:" .. pointKey(waypoint),
                        blacklist_kind = "approach", obstruction_cleared = options.obstruction_cleared }
                end
            else
                Motion.workDetours[body] = nil
            end
        elseif saved then
            Motion.workDetours[body] = nil
        end
    end
    if Motion.isBlacklisted(body, goal, timestamp, options.blacklist_kind) then
        local md = data(body)
        local reason = md and md.GoblinPathState == "blocked"
            and md.GoblinBlockedEdge == pointKey(goal) and md.GoblinBlockedReason
            or "temporarily blacklisted route"
        setNavigation(body, nil, "blocked", reason, timestamp)
        return false, "temporarily blacklisted route"
    end

    -- ZombieIdleState can issue its own random wander path while an IsoZombie
    -- is non-useless. Keep that native idle timer away from zero only while
    -- Goblin has a managed destination; do not interfere with access/combat
    -- states or change the body position.
    local _, nativeState = call(body, "getCurrentStateName")
    if nativeState == "ZombieIdleState" then
        call(body, "setStateEventDelayTimer", 1000)
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
        path.interruptedRecovery = nil
        path.lastSuccessfulMovement = timestamp
    end
    local stuck = timestamp - path.progressAt >= Config.stuckTimeoutSeconds * 1000
    local changed = not path.goal or Motion.distance(goal, path.goal) >= 0.75
    -- The native zombie AI can discard our route and enter Idle/FaceTarget
    -- while the server still owns a managed job. A void IsoZombie.pathTo*
    -- call may then be throttled by allowRepathDelay, so recover through the
    -- behavior itself once the normal repath cooldown has elapsed.
    local interrupted = path.goal ~= nil and timestamp - path.progressAt >= 1000
        and not path.interruptedRecovery
        and (nativeState == "ZombieIdleState" or nativeState == "ZombieFaceTargetState")
        and timestamp >= path.nextPathAt
    if options.obstruction_cleared then path.nextPathAt = 0; changed = true end
    if stuck and path.failures >= 1 then
        Motion.blacklist(body, goal, "no progress after native repath", timestamp, options.blacklist_kind)
        setNavigation(body, path, "blocked", "no progress after native repath", timestamp)
        -- The native PathFindState can keep servicing its old Path2 even after
        -- Lua abandons this approach. Cancel it before trying another goal.
        cancelNativeRoute(body)
        Motion.paths[body] = nil
        return false, "no progress after native repath"
    end
    if timestamp >= path.nextPathAt and (not path.goal or changed or stuck or interrupted) then
        call(body, "setUseless", false)
        -- A character-target path is preferred for a moving owner. If it
        -- makes no progress, the one allowed native repath uses the owner's
        -- current coordinates so Build 42 cannot keep retrying a stale
        -- character target indefinitely.
        local ok, route = nativePath(body, goal, options,
            (stuck and path.failures == 0) or interrupted)
        path.nextPathAt = timestamp + Config.repathSeconds * 1000
        if not ok then
            Motion.blacklist(body, goal, "native path rejected", timestamp, options.blacklist_kind)
            setNavigation(body, path, "blocked", "native path rejected", timestamp)
            cancelNativeRoute(body)
            Motion.paths[body] = nil
            return false, "native path rejected"
        end
        path.route = route
        path.goal = { x = goal.x, y = goal.y, z = goal.z }
        leaveNativeIdleForPath(body)
        if stuck then
            path.failures = path.failures + 1
            path.progressAt = timestamp
            print("[GoblinSurvivor] MOVEMENT_REPATH goal=" .. tostring(goalKey) .. " attempt=" .. path.failures)
        elseif interrupted then
            -- One direct native recovery per stationary route. Reissuing it
            -- every cooldown kept the same blocked target alive indefinitely.
            -- If it still makes no progress, blacklist this approach.
            path.interruptedRecovery = true
            path.failures = 1
            path.progressAt = timestamp
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
        current_task = md.GoblinNavigationTask or md.GoblinTask,
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

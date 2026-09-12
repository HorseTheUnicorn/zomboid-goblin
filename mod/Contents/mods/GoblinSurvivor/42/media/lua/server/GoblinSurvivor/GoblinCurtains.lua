-- Server-owned whole-house curtain work.
--
-- A close-curtains order is deliberately bound to the exact BuildingDef in
-- which the owner is standing when the order is prepared.  The BuildingDef,
-- rooms, and IsoCurtain userdata stay in this weak runtime table; only the
-- bounded room geometry and stable target ids are put in the task payload.
local World = require("GoblinSurvivor/GoblinWorld")
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local Movement = require("GoblinSurvivor/GoblinMovement")

local Curtains = { targets = setmetatable({}, { __mode = "k" }), sequence = 0 }
local call = World.call

local MAX_ROOMS = 128
local MAX_VOLUME = 250000
local MAX_TARGETS = 512
local TARGET_TIMEOUT = 45000

local function integer(value)
    return type(value) == "number" and value == math.floor(value) and value == value
end

local function pointOf(square)
    if not square then return nil end
    local okX, x = call(square, "getX")
    local okY, y = call(square, "getY")
    local okZ, z = call(square, "getZ")
    if not okX or not okY or not okZ or not integer(x) or not integer(y) or not integer(z) then return nil end
    return { x = x, y = y, z = z }
end

local function buildingDefOf(value)
    if not value then return nil end
    -- BuildingDef itself has getRooms; IsoBuilding has getDef.
    local memberOK, member = pcall(function() return value.getRooms end)
    if memberOK and type(member) == "function" then return value end
    local ok, definition = call(value, "getDef")
    return ok and definition or nil
end

local function roomDefOf(room)
    if not room then return nil end
    local ok, definition = call(room, "getRoomDef")
    return ok and definition or room
end

local function buildingOf(square)
    if not square then return nil end
    local okRoom, isoRoom = call(square, "getRoom")
    if okRoom and isoRoom then
        local room = roomDefOf(isoRoom)
        local okBuilding, building = call(room, "getBuilding")
        local definition = okBuilding and buildingDefOf(building) or nil
        if definition then return definition end
        okBuilding, building = call(isoRoom, "getBuilding")
        definition = okBuilding and buildingDefOf(building) or nil
        if definition then return definition end
    end
    -- Some 42.20 square wrappers expose the definition directly.  This is
    -- only a validation fallback; it never discovers a nearby house owner.
    local okBuilding, building = call(square, "getBuildingDef")
    if okBuilding and building then return buildingDefOf(building) or building end
    okBuilding, building = call(square, "getBuilding")
    return okBuilding and (buildingDefOf(building) or building) or nil
end

local function sameBuilding(square, building)
    return square ~= nil and building ~= nil and buildingOf(square) == building
end

local function roomBounds(room)
    local okX, x = call(room, "getX")
    local okY, y = call(room, "getY")
    local okX2, x2 = call(room, "getX2")
    local okY2, y2 = call(room, "getY2")
    local okZ, z = call(room, "getZ")
    if not (okX and okY and okX2 and okY2 and okZ)
        or not integer(x) or not integer(y) or not integer(x2) or not integer(y2) or not integer(z) then
        return nil
    end
    if x2 < x then x, x2 = x2, x end
    if y2 < y then y, y2 = y2, y end
    return { x = x, y = y, x2 = x2, y2 = y2, z = z }
end

local function captureScope(owner)
    local ownerPoint = Motion.position(owner)
    local ownerSquare = World.square(ownerPoint)
    if not ownerPoint or not ownerSquare then return nil, "stand inside a house first" end
    local okRoom, ownerIsoRoom = call(ownerSquare, "getRoom")
    if not okRoom or not ownerIsoRoom then return nil, "stand inside a house first" end
    local ownerRoom = roomDefOf(ownerIsoRoom)
    local okInside, inside = call(ownerIsoRoom, "isInside", math.floor(ownerPoint.x),
        math.floor(ownerPoint.y), math.floor(ownerPoint.z))
    if okInside and inside == false then return nil, "stand inside a house first" end
    local okBuilding, buildingValue = call(ownerRoom, "getBuilding")
    local building = okBuilding and buildingDefOf(buildingValue) or nil
    if not building then
        okBuilding, buildingValue = call(ownerIsoRoom, "getBuilding")
        building = okBuilding and buildingDefOf(buildingValue) or nil
    end
    if not building then return nil, "stand inside a house first" end
    local okStreamed, streamed = call(building, "isFullyStreamedIn")
    -- A partially streamed BuildingDef is still a valid exact house scope.
    -- Work the loaded rooms, then report an honest partial result instead of
    -- claiming that unloaded floors were inspected.
    local partiallyStreamed = okStreamed and streamed == false

    local rooms = World.values(select(2, call(building, "getRooms")))
    if #rooms < 1 or #rooms > MAX_ROOMS then return nil, "the owner's house is too large to inspect safely" end

    local result = { building = building, rooms = {}, bounds = nil,
        partiallyStreamed = partiallyStreamed }
    local volume = 0
    local ownerRoomValid = false
    for _, room in ipairs(rooms) do
        local okRoomBuilding, roomBuilding = call(room, "getBuilding")
        local bounds = roomBounds(room)
        -- A room that cannot prove ownership is not allowed to widen the
        -- scope.  This keeps adjacent/merged BuildingDefs out of the scan.
        if okRoomBuilding and roomBuilding == building and bounds then
            result.rooms[#result.rooms + 1] = bounds
            volume = volume + (bounds.x2 - bounds.x + 3) * (bounds.y2 - bounds.y + 3)
            if result.bounds == nil then
                result.bounds = { x = bounds.x - 1, y = bounds.y - 1,
                    x2 = bounds.x2 + 1, y2 = bounds.y2 + 1,
                    min_z = bounds.z, max_z = bounds.z }
            else
                result.bounds.x = math.min(result.bounds.x, bounds.x - 1)
                result.bounds.y = math.min(result.bounds.y, bounds.y - 1)
                result.bounds.x2 = math.max(result.bounds.x2, bounds.x2 + 1)
                result.bounds.y2 = math.max(result.bounds.y2, bounds.y2 + 1)
                result.bounds.min_z = math.min(result.bounds.min_z, bounds.z)
                result.bounds.max_z = math.max(result.bounds.max_z, bounds.z)
            end
            if room == ownerRoom then ownerRoomValid = true end
        end
    end
    if not ownerRoomValid or #result.rooms < 1 then return nil, "cannot prove the owner's exact house" end

    local okMin, minLevel = call(building, "getMinLevel")
    local okMax, maxLevel = call(building, "getMaxLevel")
    if okMin and integer(minLevel) then result.bounds.min_z = math.min(result.bounds.min_z, minLevel) end
    if okMax and integer(maxLevel) then result.bounds.max_z = math.max(result.bounds.max_z, maxLevel) end
    if result.bounds.max_z - result.bounds.min_z > 32 or volume > MAX_VOLUME then
        return nil, "the owner's house exceeds the safe inspection bound"
    end
    result.id = table.concat({ result.bounds.x, result.bounds.y, result.bounds.x2,
        result.bounds.y2, result.bounds.min_z, result.bounds.max_z }, ":")
    return result
end

local function inRoomPerimeter(scope, x, y, z)
    for _, room in ipairs(scope.rooms) do
        if z == room.z and x >= room.x - 1 and x <= room.x2 + 1
            and y >= room.y - 1 and y <= room.y2 + 1 then return true end
    end
    return false
end

local function targetKey(scope, square, index)
    local p = pointOf(square)
    return table.concat({ scope.id, p.x, p.y, p.z, tostring(index or 0) }, ":")
end

local function pointKey(point)
    return point and table.concat({ point.x, point.y, point.z }, ":") or nil
end

local function curtainObject(object)
    if type(instanceof) == "function" then
        local ok, value = pcall(instanceof, object, "IsoCurtain")
        return ok and value == true
    end
    return object ~= nil and object.kind == "IsoCurtain"
end

local function objectStillOnSquare(object, square)
    if not object or not square then return false end
    local gotSquare, objectSquare = call(object, "getSquare")
    if gotSquare and objectSquare ~= square then return false end
    for _, value in ipairs(World.values(select(2, call(square, "getObjects")))) do
        if value == object then return true end
    end
    return false
end

local function scan(scope, openOnly)
    local found, seen = {}, {}
    if type(getCell) ~= "function" then return found end
    local cell = getCell()
    if not cell then return found end
    for _, room in ipairs(scope.rooms) do
        for z = math.max(scope.bounds.min_z, room.z), math.min(scope.bounds.max_z, room.z) do
            for x = room.x - 1, room.x2 + 1 do
                for y = room.y - 1, room.y2 + 1 do
                    local square = cell:getGridSquare(x, y, z)
                    if square then
                        local objects = World.values(select(2, call(square, "getObjects")))
                        for index, object in ipairs(objects) do
                            if curtainObject(object) and not seen[object] then
                                local okOpen, opened = call(object, "IsOpen")
                                local opposite = select(2, call(object, "getOppositeSquare"))
                                local belongs = sameBuilding(square, scope.building)
                                    or sameBuilding(opposite, scope.building)
                                local p = pointOf(square)
                                if p and belongs and inRoomPerimeter(scope, p.x, p.y, p.z)
                                    and okOpen and (not openOnly or opened == true) then
                                    local key = targetKey(scope, square, index)
                                    found[#found + 1] = { object = object, square = square,
                                        opposite = opposite, key = key, point = p }
                                    seen[object] = true
                                    if #found >= MAX_TARGETS then
                                        scope.targetOverflow = true
                                        return found
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return found
end

local function approachSquare(object, body)
    local _, square = call(object, "getSquare")
    local point = Motion.position(body)
    if not square or not point or type(getCell) ~= "function" then return nil end
    local cell = getCell()
    if not cell then return nil end
    local best, score
    local opposite = select(2, call(object, "getOppositeSquare"))
    for dx = -1, 1 do for dy = -1, 1 do
        local candidate = cell:getGridSquare(square:getX() + dx, square:getY() + dy, square:getZ())
        local adjacent = select(2, call(object, "isAdjacentToSquare", candidate))
        local checked, blocked = call(square, "isBlockedTo", candidate)
        local free = select(2, call(candidate, "isFree", false))
        local validSide = candidate == opposite or adjacent == true
        if candidate and validSide and checked and not blocked and free == true then
            local distance = (candidate:getX() + 0.5 - point.x)^2
                + (candidate:getY() + 0.5 - point.y)^2
            if not score or distance < score then best, score = candidate, distance end
        end
    end end
    return best
end

local function chooseNext(body, scope, payload, job)
    job.skipped = job.skipped or {}
    job.skippedPoints = job.skippedPoints or {}
    local point = Motion.position(body)
    local open = scan(scope, true)
    if scope.targetOverflow then payload.target_overflow = true end
    local best, score
    for _, candidate in ipairs(open) do
        if not job.skipped[candidate.key] and not job.skippedPoints[pointKey(candidate.point)] then
            local distance = point and ((candidate.point.x + 0.5 - point.x)^2
                + (candidate.point.y + 0.5 - point.y)^2) or math.huge
            if not score or distance < score then best, score = candidate, distance end
        end
    end
    if not best then return nil end
    payload.target_id = best.key
    payload.target_point = { x = best.point.x, y = best.point.y, z = best.point.z }
    job.targetStartedAt = job.now or 0
    Curtains.targets[body].current = best
    Curtains.targets[body].known[best.key] = best.object
    return best
end

local function skipTarget(body, state, payload, job, target)
    job.skipped = job.skipped or {}
    job.skippedPoints = job.skippedPoints or {}
    job.skipped[target.key] = true
    job.skippedPoints[pointKey(target.point)] = true
    payload.skipped = (tonumber(payload.skipped) or 0) + 1
    payload.target_id = nil
    state.current = nil
    return chooseNext(body, state.scope, payload, job)
end

local function finishDetail(payload)
    local closed = tonumber(payload.completed) or 0
    local skipped = tonumber(payload.skipped) or 0
    if skipped > 0 then
        return true, false, string.format("closed %d curtain(s); skipped %d unreachable curtain(s)", closed, skipped)
    end
    if payload.partial_house == true then
        return true, false, string.format("closed %d curtain(s); skipped unloaded house areas", closed)
    end
    if payload.target_overflow == true then
        return true, false, string.format("closed %d curtain(s); house target bound reached", closed)
    end
    if closed == 0 then return true, true, "no open curtains in the owner's house" end
    return true, true, string.format("closed %d curtain(s) in the owner's house", closed)
end

function Curtains.prepare(body, owner, payload)
    if type(isServer) == "function" and not isServer() then return nil, "work must run on the game server" end
    local _, dead = call(owner, "isDead")
    if dead == true then return nil, "the owner must be alive and inside a house" end
    local scope, why = captureScope(owner)
    if not scope then return nil, why end
    Curtains.sequence = Curtains.sequence + 1
    local state = { id = Curtains.sequence, building = scope.building,
        scope = scope, known = {}, current = nil }
    Curtains.targets[body] = state
    local p = { anchor = Motion.position(owner), completed = 0, skipped = 0,
        house_id = scope.id, building_id = scope.id, bounds = scope.bounds,
        house_bounds = scope.bounds, curtain_id = state.id,
        partial_house = scope.partiallyStreamed == true }
    local job = { skipped = {}, now = getTimestampMs and getTimestampMs() or 0 }
    local first = chooseNext(body, scope, p, job)
    if not first then
        Curtains.targets[body] = nil
        return nil, "no open curtains in the owner's house"
    end
    return p, "going to close all open curtains in the owner's house"
end

function Curtains.update(body, payload, job, now)
    if type(payload) ~= "table" or type(job) ~= "table" then
        return true, false, "curtain job payload was lost; please order me again"
    end
    if type(isClient) == "function" and isClient() then return true, false, "server work is unavailable" end
    local state = Curtains.targets[body]
    if not state or not state.scope
        or state.scope.id ~= (payload.house_id or payload.building_id) then
        return true, false, "curtain house target was lost; please order me again"
    end
    job.now = now
    if (payload.completed or 0) > 0 and payload.target_id == nil then return finishDetail(payload) end
    local target = state.current
    if not target or target.key ~= payload.target_id then
        return true, false, "curtain target was lost; please order me again"
    end
    local square = target.square
    local cell = type(getCell) == "function" and getCell() or nil
    local unavailable = not square or not cell
    if not unavailable then
        local liveSquare = cell:getGridSquare(target.point.x, target.point.y, target.point.z)
        unavailable = liveSquare == nil
    end
    if unavailable then
        local nextTarget = skipTarget(body, state, payload, job, target)
        if not nextTarget then return finishDetail(payload) end
        target = nextTarget; square = target.square
    end
    if not objectStillOnSquare(target.object, square) then
        local nextTarget = skipTarget(body, state, payload, job, target)
        if not nextTarget then return finishDetail(payload) end
        target = nextTarget; square = target.square
    end
    local inspected, opened = call(target.object, "IsOpen")
    if not inspected then return true, false, "cannot inspect that curtain safely" end
    if opened ~= true then
        -- Another actor closing the exact object is safe to accept.  A missing
        -- object above is terminal and is never replaced by a coordinate hit.
        payload.target_id = nil
        state.current = nil
        local nextTarget = chooseNext(body, state.scope, payload, job)
        if not nextTarget then return finishDetail(payload) end
        target = nextTarget; square = target.square
    end

    if not job.targetStartedAt then job.targetStartedAt = now end
    if now - job.targetStartedAt > TARGET_TIMEOUT then
        local nextTarget = skipTarget(body, state, payload, job, target)
        if not nextTarget then return finishDetail(payload) end
        target = nextTarget; square = target.square
    end

    local inspectedAgain, stillOpen = call(target.object, "IsOpen")
    if not inspectedAgain then return true, false, "cannot inspect that curtain safely" end
    if stillOpen ~= true then
        payload.target_id = nil; state.current = nil
        local nextTarget = chooseNext(body, state.scope, payload, job)
        if not nextTarget then return finishDetail(payload) end
        target = nextTarget; square = target.square
    end
    local point = Motion.position(body)
    if not point then return true, false, "Goblin position is unavailable" end
    local goalSquare = approachSquare(target.object, body)
    if goalSquare and select(2, call(target.object, "canInteractWith", body)) == true then
        -- Guard the exact live object a final time.  Never issue a native
        -- toggle after a replacement object has appeared on this square.
        if not objectStillOnSquare(target.object, square) then
            local nextTarget = skipTarget(body, state, payload, job, target)
            if not nextTarget then return finishDetail(payload) end
            -- The final validation lost the exact object after reachability
            -- was established.  Do not fall through and toggle a newly
            -- selected/distant target in this same tick; re-enter through the
            -- normal validation path on the next server tick.
            return false, true, "curtain target changed; continuing safely"
        end
        Movement.clear(body)
        call(body, "faceThisObjectAlt", target.object)
        local ran = call(target.object, "ToggleDoor", body)
        local checked, remainsOpen = call(target.object, "IsOpen")
        if not ran or not checked or remainsOpen == true then
            return true, false, "the game refused to close that curtain"
        end
        payload.completed = (tonumber(payload.completed) or 0) + 1
        -- Scan after every close.  A newly opened curtain is eligible, but a
        -- replacement for the current exact object was never targeted here.
        state.current = nil
        payload.target_id = nil
        local nextTarget = chooseNext(body, state.scope, payload, job)
        if not nextTarget then return finishDetail(payload) end
        return false, true, "curtain closed; continuing through the owner's house"
    end
    if not goalSquare then return false, true, "no clear approach to that curtain yet" end
    local goal = { x = goalSquare:getX() + 0.5, y = goalSquare:getY() + 0.5,
        z = goalSquare:getZ(), radius = 0.25 }
    local active = Movement.active[body]
    if not active or not active.payload or active.payload.x ~= goal.x
        or active.payload.y ~= goal.y or active.payload.z ~= goal.z then
        Movement.command(body, "MOVE_TO", goal, state.scope)
    else
        Movement.update(body, now)
    end
    return false, true, "walking to close the owner's house curtains"
end

function Curtains.clear(body)
    Curtains.targets[body] = nil
end

return Curtains

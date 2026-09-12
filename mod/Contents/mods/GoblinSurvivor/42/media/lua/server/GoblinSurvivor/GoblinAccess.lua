-- Server-side door access and route-door lifecycle.
--
-- Opening is always performed through the native IsoDoor API.  A movement
-- scope may be supplied by a bounded house job; in that case only edges whose
-- two squares are either in that BuildingDef or outside are eligible.  Door
-- userdata and claims are runtime-only and are never copied into ModData.
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local Access = {
    nextAt = setmetatable({}, { __mode = "k" }),
    routes = setmetatable({}, { __mode = "k" }),
    claims = setmetatable({}, { __mode = "k" })
}

local function call(object, method, ...)
    if not object then return false end
    local ok, member = pcall(function() return object[method] end)
    if not ok or type(member) ~= "function" then return false end
    return pcall(member, object, ...)
end

local function result(object, method, ...)
    if not object then return false, nil end
    local ok, member = pcall(function() return object[method] end)
    if not ok or type(member) ~= "function" then return false, nil end
    local ran, value, second = pcall(member, object, ...)
    return ran, value, second
end

local function hasMethod(object, method)
    if not object then return false end
    local ok, member = pcall(function() return object[method] end)
    return ok and type(member) == "function"
end

local function isServer()
    return type(_G.isServer) ~= "function" or _G.isServer()
end

local function isClient()
    return type(_G.isClient) == "function" and _G.isClient()
end

local function opened(object)
    local ok, value = result(object, "isOpen")
    if ok then return value == true end
    ok, value = result(object, "IsOpen")
    return ok and value == true
end

local function squareAt(x, y, z)
    if type(getCell) ~= "function" then return nil end
    return getCell():getGridSquare(x, y, z)
end

local function squarePoint(square)
    if not square then return nil end
    local okX, x = result(square, "getX")
    local okY, y = result(square, "getY")
    local okZ, z = result(square, "getZ")
    if not okX or not okY or not okZ then return nil end
    return x, y, z
end

local function buildingDefOf(value)
    if not value then return nil end
    local memberOK, member = pcall(function() return value.getRooms end)
    if memberOK and type(member) == "function" then return value end
    local ok, definition = result(value, "getDef")
    return ok and definition or nil
end

local function roomDefOf(room)
    if not room then return nil end
    local ok, definition = result(room, "getRoomDef")
    return ok and definition or room
end

local function buildingOf(square)
    if not square then return nil end
    local ok, isoRoom = result(square, "getRoom")
    if ok and isoRoom then
        local room = roomDefOf(isoRoom)
        local got, building = result(room, "getBuilding")
        local definition = got and buildingDefOf(building) or nil
        if definition then return definition end
        got, building = result(isoRoom, "getBuilding")
        definition = got and buildingDefOf(building) or nil
        if definition then return definition end
    end
    local got, building = result(square, "getBuildingDef")
    if got and building then return buildingDefOf(building) or building end
    got, building = result(square, "getBuilding")
    return got and (buildingDefOf(building) or building) or nil
end

local function edgeSquares(edge)
    local here = squareAt(edge.x, edge.y, edge.z)
    local there = squareAt(edge.x + edge.dx, edge.y + edge.dy, edge.z)
    return here, there
end

local function edgeObject(edge, window)
    local here, there = edgeSquares(edge)
    if not here or not there then return nil end
    local _, object = result(here, window and "getWindowTo" or "getDoorTo", there)
    return object
end

local function validEdge(edge)
    if type(edge) ~= "table" then return false end
    for _, key in ipairs({ "x", "y", "z", "dx", "dy" }) do
        local value = edge[key]
        if type(value) ~= "number" or value ~= value or value ~= math.floor(value)
            or math.abs(value) > 10000000 then return false end
    end
    return math.abs(edge.dx) + math.abs(edge.dy) == 1
end

local function squareKey(square)
    local x, y, z = squarePoint(square)
    return x and table.concat({ x, y, z }, ":") or nil
end

function Access.canonicalEdge(edge)
    if not validEdge(edge) then return nil end
    local a = table.concat({ edge.x, edge.y, edge.z }, ":")
    local b = table.concat({ edge.x + edge.dx, edge.y + edge.dy, edge.z }, ":")
    if a > b then a, b = b, a end
    return a .. "|" .. b
end

local function scopeAllows(scope, here, there)
    if not scope or not scope.building then return true end
    local a, b = buildingOf(here), buildingOf(there)
    -- nil means an outside square.  A route can leave the selected house,
    -- but must never use a door between it and another BuildingDef.
    return (a == nil or a == scope.building) and (b == nil or b == scope.building)
end

local function canInteract(object, body)
    if not hasMethod(object, "canInteractWith") then return true end
    local ok, allowed = result(object, "canInteractWith", body)
    return ok and allowed == true
end

function Access.blockReason(object, window)
    if not object then return "target is no longer present" end
    local ok, isOpen = result(object, window and "IsOpen" or "isOpen")
    if not ok then ok, isOpen = result(object, "IsOpen") end
    if not ok then return "cannot inspect this target safely" end
    if isOpen then return "already open" end
    for _, method in ipairs({ "isLocked", "isBarricaded", "isDestroyed", window and "isPermaLocked" or "isLockedByKey" }) do
        local checked, blocked = result(object, method)
        if not checked then return "cannot inspect this target safely" end
        if blocked then
            if method == "isBarricaded" then return "barricaded; remove the barricade first" end
            if method == "isDestroyed" then return "destroyed; it cannot be opened" end
            return "locked; unlock it first"
        end
    end
    return nil
end

function Access.open(body, object, window)
    if isClient() or not isServer() then return false end
    if Access.blockReason(object, window) then return false end
    if not canInteract(object, body) then return false end
    local toggled = call(object, window and "ToggleWindow" or "ToggleDoor", body)
    local checked, isOpen = result(object, window and "IsOpen" or "isOpen")
    if not checked then checked, isOpen = result(object, "IsOpen") end
    return toggled and checked and isOpen == true
end

local function closeNative(body, object)
    if not object or isClient() or not isServer() or not opened(object) then return false end
    if not canInteract(object, body) then return false end
    local toggled = call(object, "ToggleDoor", body)
    local checked, isOpen = result(object, "isOpen")
    if not checked then checked, isOpen = result(object, "IsOpen") end
    return toggled and checked and isOpen == false
end

function Access.prepare(owner, window, now)
    local point = Motion.position(owner)
    local _, dead = result(owner, "isDead")
    if not point or dead == true then return nil, "owner must be present to identify the target" end
    local best, bestDistance
    -- Resolve the nearest edge beside the speaking player, never model-supplied
    -- coordinates or another player's door. Keep this search on the same floor.
    for x = math.floor(point.x) - 3, math.floor(point.x) + 3 do
        for y = math.floor(point.y) - 3, math.floor(point.y) + 3 do
            for _, delta in ipairs({ { 1, 0 }, { 0, 1 } }) do
                local edge = { x = x, y = y, z = math.floor(point.z), dx = delta[1], dy = delta[2] }
                local distance = (x + 0.5 + delta[1] * 0.5 - point.x)^2
                    + (y + 0.5 + delta[2] * 0.5 - point.y)^2
                if distance <= 9 and (not bestDistance or distance < bestDistance)
                    and edgeObject(edge, window) then best, bestDistance = edge, distance end
            end
        end
    end
    local kind = window and "window" or "door"
    if not best then return nil, "no " .. kind .. " within three tiles of you on this floor" end
    local reason = Access.blockReason(edgeObject(best, window), window)
    if reason then return nil, kind .. " is " .. reason end
    return { edge = best, window = window == true, started_at = now },
        "going to open the nearest " .. kind .. " beside you"
end

function Access.perform(body, payload, now)
    if isClient() or not isServer() then return true, false, "server work is unavailable" end
    local edge = payload and payload.edge
    local kind = payload and payload.window and "window" or "door"
    if not validEdge(edge) then return true, false, "opening target is invalid; please order me again" end
    local object = edgeObject(edge, payload.window)
    local reason = Access.blockReason(object, payload.window)
    if reason == "already open" then return true, true, kind .. " is open" end
    if reason then return true, false, kind .. " is " .. reason end
    if now - (tonumber(payload.started_at) or now) > 45000 then
        return true, false, "cannot reach that " .. kind .. "; clear a path and try again"
    end
    local point = Motion.position(body)
    if not point then return true, false, "cannot reach the " .. kind .. " from here" end
    local bx, by, bz = math.floor(point.x), math.floor(point.y), math.floor(point.z)
    if bz == edge.z and ((bx == edge.x and by == edge.y)
        or (bx == edge.x + edge.dx and by == edge.y + edge.dy)) then
        local openedNow = Access.open(body, object, payload.window)
        if openedNow then print("[GoblinSurvivor] OPEN_ORDER_DONE kind=" .. kind) end
        return true, openedNow, openedNow and kind .. " opened" or "could not open the " .. kind
    end
    local a = { x = edge.x + 0.5, y = edge.y + 0.5, z = edge.z, radius = 0.25 }
    local b = { x = a.x + edge.dx, y = a.y + edge.dy, z = edge.z, radius = 0.25 }
    local goal = Motion.distance(point, a) <= Motion.distance(point, b) and a or b
    local Movement = require("GoblinSurvivor/GoblinMovement")
    local active = Movement.active[body]
    if not active or active.payload.x ~= goal.x or active.payload.y ~= goal.y then
        Movement.command(body, "MOVE_TO", goal)
    else Movement.update(body, now) end
    return false, true, "walking to open the " .. kind
end

local function nextPathSquare(body, here)
    local _, behavior = result(body, "getPathFindBehavior2")
    if not behavior then return nil end
    local setOK, isSet = result(behavior, "pathNextIsSet")
    local xOK, x = result(behavior, "pathNextX")
    local yOK, y = result(behavior, "pathNextY")
    if not setOK or isSet ~= true or not xOK or not yOK
        or type(x) ~= "number" or type(y) ~= "number" then return nil end
    if math.abs(x - here:getX()) + math.abs(y - here:getY()) ~= 1 then return nil end
    return squareAt(x, y, here:getZ())
end

local function currentSquare(body)
    local point = Motion.position(body)
    if not point then return nil end
    return squareAt(math.floor(point.x), math.floor(point.y), math.floor(point.z))
end

local function movingObjects(square)
    local resultList = {}
    local seen = {}
    local function add(list)
        if not list then return end
        local okSize, size = result(list, "size")
        for i = 0, (okSize and tonumber(size) or 0) - 1 do
            local okValue, value = result(list, "get", i)
            if okValue and value and not seen[value] then seen[value] = true; resultList[#resultList + 1] = value end
        end
    end
    add(select(2, result(square, "getMovingObjects")))
    return resultList
end

local function actorNear(body, edge)
    local here, there = edgeSquares(edge)
    local candidates = {}
    for _, square in ipairs({ here, there }) do
        if square then
            for _, object in ipairs(movingObjects(square)) do candidates[#candidates + 1] = object end
            for dx = -1, 1 do for dy = -1, 1 do
                local neighbor = squareAt(square:getX() + dx, square:getY() + dy, square:getZ())
                for _, object in ipairs(movingObjects(neighbor)) do candidates[#candidates + 1] = object end
            end end
        end
    end
    if type(getOnlinePlayers) == "function" then
        local ok, players = pcall(getOnlinePlayers)
        if ok and players then
            local okSize, size = result(players, "size")
            for i = 0, (okSize and tonumber(size) or 0) - 1 do
                local got, player = result(players, "get", i)
                if got and player then candidates[#candidates + 1] = player end
            end
        end
    end
    local sideA, sideB = edge.x, edge.y
    local otherX, otherY = edge.x + edge.dx, edge.y + edge.dy
    for _, object in ipairs(candidates) do
        if object ~= body then
            local point = Motion.position(object)
            if point and math.floor(point.z) == edge.z then
                local nearA = math.abs(point.x - (sideA + 0.5)) <= 1.25
                    and math.abs(point.y - (sideB + 0.5)) <= 1.25
                local nearB = math.abs(point.x - (otherX + 0.5)) <= 1.25
                    and math.abs(point.y - (otherY + 0.5)) <= 1.25
                if nearA or nearB then return true end
            end
        end
    end
    return false
end

local function routeFor(body, scope)
    local route = Access.routes[body]
    if not route then
        route = { scope = scope, lastSquare = nil, pendingCross = nil,
            opened = setmetatable({}, { __mode = "k" }), pending = {} }
        -- Keep the human-readable name used by diagnostics/tests while the
        -- table itself remains runtime-only (no userdata in ModData).
        route.Goblinopened = route.opened
        route.exteriorTraversed = {}
        route.interiorGoblinOpened = {}
        Access.routes[body] = route
    elseif scope then
        route.scope = scope
    end
    return route
end

local function registerDoor(body, edge, object, scope, now, fromSquare, wasOpen)
    if not scope or not object then return end
    local route = routeFor(body, scope)
    local key = Access.canonicalEdge(edge)
    local existing = route.opened[object]
    -- Access.update runs on a cooldown while the Goblin waits on the near
    -- side.  Do not overwrite the original wasOpen provenance on each tick;
    -- otherwise a door opened by Goblin would look initially open and would
    -- not be restored after a slow crossing.
    if existing and existing.key == key and route.pendingCross == existing and not existing.crossed then
        return
    end
    local nativeExteriorOK, nativeExterior = result(object, "isExterior")
    local exterior = nativeExteriorOK and nativeExterior == true or (function()
            local a, b = edgeSquares(edge)
            return buildingOf(a) == nil or buildingOf(b) == nil
        end)()
    route.opened[object] = { door = object, edge = { x = edge.x, y = edge.y, z = edge.z,
        dx = edge.dx, dy = edge.dy }, key = key, wasOpen = wasOpen == true,
        exterior = exterior, closeAfterCross = exterior or wasOpen ~= true,
        from = squareKey(fromSquare), crossed = false }
    route.pendingCross = route.opened[object]
end

local function observeCrossing(body, route, now)
    local square = currentSquare(body)
    if not square then return end
    local currentKey = squareKey(square)
    local pending = route.pendingCross
    if pending and pending.from ~= currentKey then
        local a, b = edgeSquares(pending.edge)
        local aKey, bKey = squareKey(a), squareKey(b)
        if currentKey == aKey or currentKey == bKey then
            pending.crossed = true
            route.pendingCross = nil
            if pending.closeAfterCross then
                if pending.exterior then route.exteriorTraversed[pending.door] = pending
                else route.interiorGoblinOpened[pending.door] = pending end
                route.pending[#route.pending + 1] = { door = pending.door, edge = pending.edge,
                    expires = now + 5000 }
            end
        end
    end
    route.lastSquare = currentKey
end

local function processPending(body, route, now)
    local keep = {}
    for _, item in ipairs(route.pending) do
        local door = item.door
        if now <= item.expires then
            local here, there = edgeSquares(item.edge)
            local exact = edgeObject(item.edge, false) == door
            local point = Motion.position(body)
            local adjacent = point and ((math.abs(point.x - (item.edge.x + 0.5)) <= 1.1
                and math.abs(point.y - (item.edge.y + 0.5)) <= 1.1)
                or (math.abs(point.x - (item.edge.x + item.edge.dx + 0.5)) <= 1.1
                and math.abs(point.y - (item.edge.y + item.edge.dy + 0.5)) <= 1.1))
            if not exact or not opened(door) then
                -- Removed/replaced/closed doors are never re-targeted.
            elseif adjacent and not actorNear(body, item.edge)
                and not (select(2, result(door, "isObstructed")) == true) then
                local claim = Access.claims[door]
                if claim and claim.body ~= body and claim.expires > now then
                    keep[#keep + 1] = item
                else
                    Access.claims[door] = { body = body, expires = now + 1500 }
                    if not closeNative(body, door) then keep[#keep + 1] = item end
                    if Access.claims[door] and Access.claims[door].body == body then Access.claims[door] = nil end
                end
            else
                keep[#keep + 1] = item
            end
        end
    end
    route.pending = keep
end

function Access.update(body, goal, now, scope, pendingOnly)
    if not isServer() or isClient() then return false end
    now = now or (type(getTimestampMs) == "function" and getTimestampMs() or 0)
    local route = routeFor(body, scope)
    observeCrossing(body, route, now)
    processPending(body, route, now)
    if pendingOnly or not goal then return false end
    if now < (Access.nextAt[body] or 0) then return false end
    Access.nextAt[body] = now + 500
    local here = currentSquare(body)
    if not here then return false end
    local nextSquare = nextPathSquare(body, here)
    local choices = {}
    if nextSquare then choices[#choices + 1] = { square = nextSquare, along = 1000 } end
    if #choices == 0 then
        local point = Motion.position(body)
        local dx, dy = goal.x - point.x, goal.y - point.y
        for _, delta in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local candidate = squareAt(here:getX() + delta[1], here:getY() + delta[2], here:getZ())
            local along = dx * delta[1] + dy * delta[2]
            if candidate and along > 0.25 and scopeAllows(scope, here, candidate) then
                choices[#choices + 1] = { square = candidate, along = along }
            end
        end
        table.sort(choices, function(a, b) return a.along > b.along end)
    end
    for _, choice in ipairs(choices) do
        if scopeAllows(scope, here, choice.square) then
            local edge = { x = here:getX(), y = here:getY(), z = here:getZ(),
                dx = choice.square:getX() - here:getX(), dy = choice.square:getY() - here:getY() }
            local object = select(2, result(here, "getDoorTo", choice.square))
            if object then
                local wasOpen = opened(object)
                if wasOpen then
                    registerDoor(body, edge, object, scope, now, here, true)
                    return true
                end
                if Access.open(body, object, false) then
                    registerDoor(body, edge, object, scope, now, here, false)
                    return true
                end
            end
        end
    end
    -- A path-next square is authoritative when it names a door (this is what
    -- makes an L-shaped corridor work).  If that edge has no door, retain a
    -- conservative final-direction fallback rather than getting stuck on an
    -- unrelated ordinary floor square.
    if nextSquare then
        local point = Motion.position(body)
        local dx, dy = goal.x - point.x, goal.y - point.y
        local fallback = {}
        for _, delta in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local candidate = squareAt(here:getX() + delta[1], here:getY() + delta[2], here:getZ())
            local along = dx * delta[1] + dy * delta[2]
            if candidate and candidate ~= nextSquare and along > 0.25
                and scopeAllows(scope, here, candidate) then
                fallback[#fallback + 1] = { square = candidate, along = along }
            end
        end
        table.sort(fallback, function(a, b) return a.along > b.along end)
        for _, choice in ipairs(fallback) do
            local edge = { x = here:getX(), y = here:getY(), z = here:getZ(),
                dx = choice.square:getX() - here:getX(), dy = choice.square:getY() - here:getY() }
            local object = select(2, result(here, "getDoorTo", choice.square))
            local wasOpen = object and opened(object)
            if object and (wasOpen or Access.open(body, object, false)) then
                registerDoor(body, edge, object, scope, now, here, wasOpen == true)
                return true
            end
        end
    end
    return false
end

function Access.tick(body, now)
    if not Access.routes[body] then return false end
    return Access.update(body, nil, now, nil, true)
end

function Access.clear(body)
    Access.routes[body] = nil
    Access.nextAt[body] = nil
end

return Access

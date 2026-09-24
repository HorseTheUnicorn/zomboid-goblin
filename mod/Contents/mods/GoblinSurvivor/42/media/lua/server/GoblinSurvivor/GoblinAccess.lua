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
    claims = setmetatable({}, { __mode = "k" }),
    approaches = setmetatable({}, { __mode = "k" })
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

-- PathFindBehavior2 exposes pathNext* as public fields in the exact installed
-- Build 42 runtime. Keep method support for older builds and test doubles.
local function fieldOrMethod(object, name)
    if not object then return false, nil end
    local ok, member = pcall(function() return object[name] end)
    if not ok then return false, nil end
    if type(member) == "function" then return pcall(member, object) end
    return member ~= nil, member
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

local function markAccessChanged(body)
    local ok, data = result(body, "getModData")
    if not ok or type(data) ~= "table" then return false end
    data.GoblinAccessRevision = (tonumber(data.GoblinAccessRevision) or 0) + 1
    return true
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

local function roomOf(square)
    local ok, room = result(square, "getRoom")
    return ok and roomDefOf(room) or nil
end

local function roomBounds(room)
    local okX, x = result(room, "getX")
    local okY, y = result(room, "getY")
    local okX2, x2 = result(room, "getX2")
    local okY2, y2 = result(room, "getY2")
    local okZ, z = result(room, "getZ")
    if not okX or not okY or not okX2 or not okY2 or not okZ then return nil end
    for _, value in ipairs({ x, y, x2, y2, z }) do
        if type(value) ~= "number" or value ~= value or value ~= math.floor(value) then return nil end
    end
    if x2 < x then x, x2 = x2, x end
    if y2 < y then y, y2 = y2, y end
    return { x = x, y = y, x2 = x2, y2 = y2, min_z = z, max_z = z }
end

local function expandBounds(bounds, room)
    local value = roomBounds(room)
    if not value then return bounds end
    if not bounds then
        return { x = value.x - 1, y = value.y - 1, x2 = value.x2 + 1,
            y2 = value.y2 + 1, min_z = value.min_z, max_z = value.max_z }
    end
    bounds.x = math.min(bounds.x, value.x - 1)
    bounds.y = math.min(bounds.y, value.y - 1)
    bounds.x2 = math.max(bounds.x2, value.x2 + 1)
    bounds.y2 = math.max(bounds.y2, value.y2 + 1)
    bounds.min_z = math.min(bounds.min_z, value.min_z)
    bounds.max_z = math.max(bounds.max_z, value.max_z)
    return bounds
end

local function nearestRoomAndBuilding(point, radius)
    local bestRoom, bestBuilding, bestDistance
    for x = math.floor(point.x) - radius, math.floor(point.x) + radius do
        for y = math.floor(point.y) - radius, math.floor(point.y) + radius do
            local square = squareAt(x, y, math.floor(point.z))
            local room = roomOf(square)
            local building = room and buildingOf(square) or nil
            local distance = (x + 0.5 - point.x)^2 + (y + 0.5 - point.y)^2
            if room and building and (not bestDistance or distance < bestDistance) then
                bestRoom, bestBuilding, bestDistance = room, building, distance
            end
        end
    end
    return bestRoom, bestBuilding
end

local function collectionValues(object, method)
    local values = {}
    local okList, list = result(object, method)
    if not okList or not list then return values end
    local okSize, size = result(list, "size")
    for index = 0, (okSize and tonumber(size) or 0) - 1 do
        local okValue, value = result(list, "get", index)
        if okValue and value then values[#values + 1] = value end
    end
    return values
end

-- Resolve a bounded semantic search scope from the authenticated owner's live
-- location. Engine objects remain prepare-time only; the chosen task payload
-- persists just the final cardinal edge and re-resolves it before mutation.
function Access.resolveTargetScope(owner, kind)
    local point = Motion.position(owner)
    if not point then return nil, "owner location is unavailable" end
    kind = string.upper(tostring(kind or "BUILDING"))
    if kind == "YARD" then
        local radius = 12
        return { bounds = { x = math.floor(point.x) - radius, y = math.floor(point.y) - radius,
            x2 = math.floor(point.x) + radius, y2 = math.floor(point.y) + radius,
            min_z = math.floor(point.z), max_z = math.floor(point.z) }, max_distance_squared = radius * radius }
    end
    if kind ~= "BUILDING" and kind ~= "ROOM" then return {}, nil end
    local square = squareAt(math.floor(point.x), math.floor(point.y), math.floor(point.z))
    local room, building = roomOf(square), buildingOf(square)
    if not room or not building then room, building = nearestRoomAndBuilding(point, 12) end
    if not room or not building then return nil, "no loaded " .. string.lower(kind) .. " is near the owner" end
    if kind == "ROOM" then
        local bounds = expandBounds(nil, room)
        if not bounds then return nil, "the target room has invalid bounds" end
        return { bounds = bounds, target_room = room, target_building = building }, nil
    end
    local rooms = collectionValues(building, "getRooms")
    if #rooms < 1 or #rooms > 128 then return nil, "the target building is too large to inspect safely" end
    local bounds, volume = nil, 0
    for _, value in ipairs(rooms) do
        local roomBuilding = select(2, result(value, "getBuilding"))
        roomBuilding = buildingDefOf(roomBuilding) or roomBuilding
        local rb = roomBuilding == building and roomBounds(value) or nil
        if rb then
            bounds = expandBounds(bounds, value)
            volume = volume + (rb.x2 - rb.x + 3) * (rb.y2 - rb.y + 3)
        end
    end
    if not bounds or volume > 250000 or bounds.max_z - bounds.min_z > 32 then
        return nil, "the target building exceeds the safe inspection bound"
    end
    return { bounds = bounds, target_building = building }, nil
end

local function edgeSquares(edge)
    local here = squareAt(edge.x, edge.y, edge.z)
    local there = squareAt(edge.x + edge.dx, edge.y + edge.dy, edge.z)
    return here, there
end

local function listValues(object, method)
    local values = {}
    local okList, list = result(object, method)
    if not okList or not list then return values end
    local okSize, size = result(list, "size")
    for index = 0, (okSize and tonumber(size) or 0) - 1 do
        local okValue, value = result(list, "get", index)
        if okValue and value then values[#values + 1] = value end
    end
    return values
end

local function thumpableDoorMatches(object, here, there)
    local okDoor, isDoor = result(object, "isDoor")
    if not okDoor or isDoor ~= true then return false end
    local okSquare, square = result(object, "getSquare")
    local okNorth, north = result(object, "getNorth")
    local hx, hy, hz = squarePoint(here)
    local tx, ty, tz = squarePoint(there)
    local ox, oy, oz
    if okSquare then ox, oy, oz = squarePoint(square) end
    if not okNorth or not hx or not tx or not ox or hz ~= tz or hz ~= oz then return false end
    local otherX, otherY = north == true and ox or ox - 1, north == true and oy - 1 or oy
    return (hx == ox and hy == oy and tx == otherX and ty == otherY)
        or (tx == ox and ty == oy and hx == otherX and hy == otherY)
end

local function doorBetween(here, there)
    if not here or not there then return nil end
    local okDoor, door = result(here, "getDoorTo", there)
    if okDoor and door then return door end
    -- Build 42 can report an IsoThumpable/player-built door only from the
    -- square that stores the object, which may be the far side of this edge.
    okDoor, door = result(there, "getDoorTo", here)
    if okDoor and door then return door end
    -- Keep a final representation-independent fallback for player-built
    -- wooden/metal doors and gates. Vanilla stores these as IsoThumpable
    -- special objects, with getNorth() identifying their exact square edge.
    local seen = {}
    for _, square in ipairs({ here, there }) do
        for _, method in ipairs({ "getSpecialObjects", "getObjects" }) do
            for _, object in ipairs(listValues(square, method)) do
                if not seen[object] then
                    seen[object] = true
                    if thumpableDoorMatches(object, here, there) then return object end
                end
            end
        end
    end
    return nil
end

local function edgeObject(edge, window)
    local here, there = edgeSquares(edge)
    if not here or not there then return nil end
    if not window then return doorBetween(here, there) end
    local _, object = result(here, "getWindowTo", there)
    if object then return object end
    return select(2, result(there, "getWindowTo", here))
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

local function staticResult(name, ...)
    local class = rawget(_G, "IsoDoor")
    if not class then return false, nil end
    local ok, member = pcall(function() return class[name] end)
    if not ok or type(member) ~= "function" then return false, nil end
    return pcall(member, ...)
end

local function doorGroup(object)
    local group, seen = {}, {}
    local function add(value)
        if value and not seen[value] then seen[value] = true; group[#group + 1] = value end
    end
    add(object)
    local okDouble, doubleIndex = staticResult("getDoubleDoorIndex", object)
    if okDouble and tonumber(doubleIndex) and tonumber(doubleIndex) ~= -1 then
        for index = 1, 4 do add(select(2, staticResult("getDoubleDoorObject", object, index))) end
        return group
    end
    local okGarage, garageIndex = staticResult("getGarageDoorIndex", object)
    if not okGarage or not tonumber(garageIndex) or tonumber(garageIndex) == -1 then return group end
    local current = object
    for _ = 1, 16 do
        current = select(2, staticResult("getGarageDoorPrev", current))
        if not current or seen[current] then break end
        add(current)
    end
    current = object
    for _ = 1, 16 do
        current = select(2, staticResult("getGarageDoorNext", current))
        if not current or seen[current] then break end
        add(current)
    end
    return group
end

local doorLocked, matchingDoorKey

local function canUnlockFromInside(body, object)
    -- Installed ISLockDoor:isValid permits a keyless unlock from a
    -- non-exterior square. Require this actor to stand on the actual door
    -- edge so a different indoor room cannot authorize a remote unlock.
    -- ISLockDoor rejects CustomLock without the matching key, even indoors.
    -- Key authorization is handled separately by the caller.
    local _,lockData=result(object,"getModData")
    if lockData and lockData.CustomLock then return false end
    local flags = rawget(_G, "IsoFlagType")
    local exterior = flags and flags.exterior
    local okHere, here = result(body, "getCurrentSquare")
    local okDoor, square = result(object, "getSquare")
    local okNorth, north = result(object, "getNorth")
    if not exterior or not okHere or not here or not okDoor or not square or not okNorth then return false end
    local hx, hy, hz = squarePoint(here)
    local ox, oy, oz = squarePoint(square)
    if not hx or not ox or hz ~= oz then return false end
    local otherX, otherY = north == true and ox or ox - 1,
        north == true and oy - 1 or oy
    if not ((hx == ox and hy == oy) or (hx == otherX and hy == otherY)) then return false end
    local checked, outside = result(here, "has", exterior)
    return checked and outside == false
end

local function specialLockReason(object,body)
    -- Installed ISPadlockAction/ISPadlockByCodeAction transfer real lock/key
    -- items. Ordinary ISLockDoor authorization cannot substitute for either.
    if select(2,result(object,"isLockedByPadlock"))==true then
        if #doorGroup(object)~=1 or not require("GoblinSurvivor/GoblinPadlocks").key(body,object) then
            return "padlocked; a real matching padlock key and single gate are required"
        end
    end
    local checked,code=result(object,"getLockedByCode")
    if checked and tonumber(code) and tonumber(code)~=0 then
        return "combination locked; an authorized code-removal action is required"
    end
end

local function unlockDoor(object, body)
    -- Match the installed ISLockDoor validity boundary: a key-locked door may
    -- be changed only when this actor's real inventory contains the matching
    -- key ID. A crowbar or permanent toolkit never becomes an invented
    -- lock-pick mechanic. Keep the player-free state/sync adapter because the
    -- installed actor-taking door toggle has an unsafe IsoPlayer tail cast.
    if not doorLocked(object) then return true end
    if not matchingDoorKey(body, object) and not canUnlockFromInside(body, object) then return false end
    local group=doorGroup(object)
    -- Preflight all panels before the first mutation, not halfway through a
    -- double/garage door after one panel has already been unlocked.
    for _,member in ipairs(group) do if specialLockReason(member,body) then return false end end
    if select(2,result(object,"isLockedByPadlock"))==true
        and not require("GoblinSurvivor/GoblinPadlocks").remove(body,object) then return false end
    for _, member in ipairs(group) do
        local changed = false
        local ok, value = result(member, "isLocked")
        if ok and value == true then
            local set = call(member, "setLocked", false)
            if not set then set = call(member, "setIsLocked", false) end
            changed = set or changed
        end
        ok, value = result(member, "isLockedByKey")
        if ok and value == true then changed = call(member, "setLockedByKey", false) or changed end
        if changed then call(member, "syncIsoObject", false, 0, nil, nil) end
    end
    return true
end

local function safehouseAllows(body, object)
    local class = rawget(_G, "SafeHouse")
    if not class then return true end
    local gotSquare, square = result(object, "getSquare")
    if not gotSquare or not square then return false end
    local okMember, member = pcall(function() return class.getSafeHouse end)
    if not okMember or type(member) ~= "function" then return false end
    local okSafehouse, safehouse = pcall(member, square)
    if not okSafehouse then return false end
    if not safehouse then return true end
    local _, data = result(body, "getModData")
    local owner = data and data.GoblinOwner
    if type(owner) ~= "string" or owner == "" then return false end
    local checked, allowed = result(safehouse, "playerAllowed", owner)
    return checked and allowed == true
end

local function toggleDoorWithoutPlayer(body, object, wantOpen)
    if opened(object) == wantOpen then return true end
    local toggled = false
    local okDouble, doubleIndex = staticResult("getDoubleDoorIndex", object)
    if okDouble and tonumber(doubleIndex) and tonumber(doubleIndex) ~= -1 then
        toggled = select(1, staticResult("toggleDoubleDoor", object, true))
    else
        local okGarage, garageIndex = staticResult("getGarageDoorIndex", object)
        if okGarage and tonumber(garageIndex) and tonumber(garageIndex) ~= -1 then
            toggled = select(1, staticResult("toggleGarageDoor", object, true))
        elseif hasMethod(object, "ToggleDoorSilent") then
            toggled = call(object, "ToggleDoorSilent")
            if toggled then call(object, "syncIsoObject", false, 0, nil, nil) end
        else
            -- Test doubles and older runtimes may not expose the player-free
            -- entrypoint. Reconcile solely from observed state because the
            -- installed ToggleDoor mutates/syncs before its trailing player cast.
            call(object, "ToggleDoor", body)
            toggled = opened(object) == wantOpen
        end
    end
    return toggled and opened(object) == wantOpen
end

function Access.blockReason(object, window, allowUnlock, actor)
    if not object then return "target is no longer present" end
    local ok, isOpen = result(object, window and "IsOpen" or "isOpen")
    if not ok then ok, isOpen = result(object, "IsOpen") end
    if not ok then return "cannot inspect this target safely" end
    if isOpen then return "already open" end
    if not window then
        local special=specialLockReason(object,actor)
        if special then return special end
    end
    for _, method in ipairs({ "isLocked", "isBarricaded", "isDestroyed", window and "isPermaLocked" or "isLockedByKey" }) do
        local checked, blocked = result(object, method)
        if not checked then return "cannot inspect this target safely" end
        if blocked and not (allowUnlock == true and window ~= true
            and (method == "isLocked" or method == "isLockedByKey")
            and (matchingDoorKey(actor, object) ~= nil
                or canUnlockFromInside(actor, object))) then
            if method == "isBarricaded" then return "barricaded; remove the barricade first" end
            if method == "isDestroyed" then return "destroyed; it cannot be opened" end
            return "locked; unlock it first"
        end
    end
    return nil
end

function Access.open(body, object, window)
    if isClient() or not isServer() then return false, "server authority unavailable" end
    local reason = Access.blockReason(object, window, not window, body)
    if reason then return false, reason end
    if not safehouseAllows(body, object) then return false, "safehouse access denied" end
    -- IsoThumpable:canInteractWith rejects a locked player-built door. Apply
    -- the managed all-tools unlock first, then retain its native interaction
    -- check for every non-lock restriction. Safehouse authorization must stay
    -- before this mutation so another player's lock is never changed.
    if not window and not unlockDoor(object, body) then return false, "door unlock failed" end
    if not canInteract(object, body) then return false, "native interaction denied" end
    local toggled
    if window then toggled = call(object, "ToggleWindow", body)
    else toggled = toggleDoorWithoutPlayer(body, object, true) end
    local checked, isOpen = result(object, window and "IsOpen" or "isOpen")
    if not checked then checked, isOpen = result(object, "IsOpen") end
    local openedNow = toggled and checked and isOpen == true
    if openedNow then markAccessChanged(body) end
    return openedNow, openedNow and nil or "native toggle did not open"
end

local function closeNative(body, object)
    if not object or isClient() or not isServer() or not opened(object) then return false end
    if not canInteract(object, body) then return false end
    local toggled = toggleDoorWithoutPlayer(body, object, false)
    local checked, isOpen = result(object, "isOpen")
    if not checked then checked, isOpen = result(object, "IsOpen") end
    return toggled and checked and isOpen == false
end

doorLocked=function(object)
    for _,method in ipairs({"isLocked","isLockedByKey","isLockedByPadlock"}) do
        local checked,value=result(object,method)
        if checked and value==true then return true end
    end
    local checked,code=result(object,"getLockedByCode")
    return checked and tonumber(code) and tonumber(code)~=0 or false
end

matchingDoorKey=function(body, object)
    if not body or not object then return nil end
    local okKey, keyId = result(object, "checkKeyId")
    if not okKey or type(keyId) ~= "number" or keyId < 0 then
        okKey, keyId = result(object, "getKeyId")
    end
    if not okKey or type(keyId) ~= "number" or keyId < 0 then return nil end
    local okInventory, inventory = result(body, "getInventory")
    if not okInventory or not inventory then return nil end
    local checked, key = result(inventory, "haveThisKeyId", keyId)
    return checked and key or nil
end

function Access.prepare(owner, window, now, options)
    options=type(options)=="table" and options or {}
    local point = Motion.position(owner)
    local _, dead = result(owner, "isDead")
    if not point or dead == true then return nil, "owner must be present to identify the target" end
    local best, bestScore, bestPriority, nearestBlocked, nearestBlockedDistance
    local ranked=options.all_routes==true and {} or nil
    -- Resolve the nearest edge beside the speaking player, never model-supplied
    -- coordinates or another player's door. Keep this search on the same floor.
    local bounds = options.bounds or { x = math.floor(point.x) - 3, y = math.floor(point.y) - 3,
        x2 = math.floor(point.x) + 3, y2 = math.floor(point.y) + 3,
        min_z = math.floor(point.z), max_z = math.floor(point.z) }
    local z = math.floor(point.z)
    for x = bounds.x, bounds.x2 do
        for y = bounds.y, bounds.y2 do
            for _, delta in ipairs({ { 1, 0 }, { 0, 1 } }) do
                local edge = { x = x, y = y, z = z, dx = delta[1], dy = delta[2] }
                local distance = (x + 0.5 + delta[1] * 0.5 - point.x)^2
                    + (y + 0.5 + delta[2] * 0.5 - point.y)^2
                local object=edgeObject(edge,window)
                local here, there = edgeSquares(edge)
                local scopeMatches = true
                if options.target_room then
                    scopeMatches = (roomOf(here) == options.target_room) ~= (roomOf(there) == options.target_room)
                elseif options.target_building then
                    scopeMatches = (buildingOf(here) == options.target_building)
                        ~= (buildingOf(there) == options.target_building)
                end
                local limit=options.max_distance_squared and tonumber(options.max_distance_squared)
                local within=options.max_distance_squared ~= nil
                    and limit ~= nil and limit >= 0 and distance <= limit
                    or options.max_distance_squared == nil
                        and (options.bounds ~= nil or distance <= 9)
                if within and scopeMatches and object then
                    local reason=Access.blockReason(object,window,not window,options.actor)
                    local eligible=reason==nil or (reason=="already open" and options.include_open==true)
                    if eligible then
                        local priority
                        if reason=="already open" then priority=1
                        elseif window then priority=5
                        elseif doorLocked(object) and matchingDoorKey(options.actor,object) then priority=3
                        elseif doorLocked(object) then priority=7
                        else priority=2 end
                        local score=priority*100000+distance
                        if ranked then
                            ranked[#ranked+1]={edge=edge,window=window==true,started_at=now,
                                priority=priority,score=score}
                            table.sort(ranked,function(a,b) return a.score<b.score end)
                            if #ranked>12 then table.remove(ranked) end
                        end
                        if not bestScore or score<bestScore then
                            best,bestScore,bestPriority=edge,score,priority
                        end
                    elseif not nearestBlockedDistance or distance<nearestBlockedDistance then
                        nearestBlocked,nearestBlockedDistance=reason,distance
                    end
                end
            end
        end
    end
    local kind = window and "window" or "door"
    if not best then
        if nearestBlocked then return nil,kind.." is "..nearestBlocked end
        return nil, "no eligible " .. kind .. " is loaded in the target scope"
    end
    return { edge = best, window = window == true, started_at = now, priority=bestPriority },
        "going to open the nearest " .. kind .. " beside you",ranked
end

local function hoppableBetween(edge)
    local here,there=edgeSquares(edge)
    if not here or not there then return nil end
    local ok,object=result(here,"getHoppableTo",there)
    if ok and object then return object end
    ok,object=result(there,"getHoppableTo",here)
    return ok and object or nil
end

local function nativeLowFenceEdge(edge)
    local here,there=edgeSquares(edge)
    local directions=rawget(_G,"IsoDirections")
    if not here or not there or not directions then return false end
    local forward=edge.dx==1 and directions.E or directions.S
    local reverse=edge.dx==1 and directions.W or directions.N
    if not forward or not reverse then return false end
    local checked,allowed=result(here,"isPlayerAbleToHopWallTo",forward,there)
    if checked and allowed==true then return true end
    checked,allowed=result(there,"isPlayerAbleToHopWallTo",reverse,here)
    return checked and allowed==true
end

function Access.prepareFence(owner,now,options)
    options=type(options)=="table" and options or {}
    local point=Motion.position(owner)
    if not point then return nil,"owner must be present to identify the target" end
    local best,bestDistance
    local bounds=options.bounds or {x=math.floor(point.x)-3,y=math.floor(point.y)-3,
        x2=math.floor(point.x)+3,y2=math.floor(point.y)+3}
    for x=bounds.x,bounds.x2 do
        for y=bounds.y,bounds.y2 do
            for _,delta in ipairs({{1,0},{0,1}}) do
                local edge={x=x,y=y,z=math.floor(point.z),dx=delta[1],dy=delta[2]}
                local object=hoppableBetween(edge)
                local checkedTall,tall=result(object,"isTallHoppable")
                local distance=(x+0.5+delta[1]*0.5-point.x)^2
                    +(y+0.5+delta[2]*0.5-point.y)^2
                local within=distance<=tonumber(options.max_distance_squared or 9)
                if object and checkedTall and tall==false and within and nativeLowFenceEdge(edge)
                    and (not bestDistance or distance<bestDistance) then
                    best,bestDistance=edge,distance
                end
            end
        end
    end
    if not best then return nil,"no climbable low fence within three tiles of you on this floor" end
    return {edge=best,fence=true,started_at=now,priority=6},"going to cross the nearest low fence"
end

local function edgeSide(point,edge)
    if not point or math.floor(point.z)~=edge.z then return nil end
    local x,y=math.floor(point.x),math.floor(point.y)
    if x==edge.x and y==edge.y then return 1 end
    if x==edge.x+edge.dx and y==edge.y+edge.dy then return 2 end
    return nil
end

local function approachEdge(body,edge,now,runtime)
    if type(runtime)~="table" then
        runtime=Access.approaches[body]
        if type(runtime)~="table" then runtime={};Access.approaches[body]=runtime end
    end
    local point=Motion.position(body)
    if not point then return false,"cannot resolve Goblin position",true end
    local side=edgeSide(point,edge)
    if side then return true,side end
    local key=Access.canonicalEdge(edge)
    if runtime.fence_approach_edge~=key then
        runtime.fence_approach_edge=key
        runtime.fence_approach_started_at=now
        runtime.fence_approach_side=nil
        runtime.fence_approach_switched=nil
        runtime.fence_approach_best=nil
        runtime.fence_approach_progress_at=nil
    end
    if now-(runtime.fence_approach_started_at or now)>30000 then
        require("GoblinSurvivor/GoblinMovement").clear(body)
        return false,"could not reach the low-fence edge",true
    end
    local a={x=edge.x+0.5,y=edge.y+0.5,z=edge.z,radius=0.25}
    local b={x=a.x+edge.dx,y=a.y+edge.dy,z=edge.z,radius=0.25}
    if not runtime.fence_approach_side then
        runtime.fence_approach_side=Motion.distance(point,a)<=Motion.distance(point,b) and 1 or 2
    end
    local goal=runtime.fence_approach_side==1 and a or b
    local distance=Motion.distance(point,goal)
    if not runtime.fence_approach_best or distance<runtime.fence_approach_best-0.20 then
        runtime.fence_approach_best=distance
        runtime.fence_approach_progress_at=now
    elseif now-(runtime.fence_approach_progress_at or now)>=6000
        and runtime.fence_approach_switched~=true then
        require("GoblinSurvivor/GoblinMovement").clear(body)
        runtime.fence_approach_side=runtime.fence_approach_side==1 and 2 or 1
        runtime.fence_approach_switched=true
        runtime.fence_approach_best=nil
        runtime.fence_approach_progress_at=now
        goal=runtime.fence_approach_side==1 and a or b
    end
    local Movement=require("GoblinSurvivor/GoblinMovement")
    local active=Movement.active[body]
    if not active or active.payload.x~=goal.x or active.payload.y~=goal.y then
        Movement.command(body,"MOVE_TO",goal)
    else Movement.update(body,now) end
    return false,"walking to the access edge"
end

function Access.performFence(body,payload,runtime,now)
    local edge=payload and payload.edge
    if not validEdge(edge) then return true,false,"fence target changed","TARGET_CHANGED" end
    local fence=hoppableBetween(edge)
    if not fence then return true,false,"fence is no longer loaded","TARGET_UNLOADED" end
    local Policy=require("GoblinSurvivor/GoblinAccessPolicy")
    local allowed,code,detail=Policy.access(body,fence)
    if not allowed then return true,false,detail,code end
    local point=Motion.position(body)
    local side=edgeSide(point,edge)
    if runtime.fence_from then
        if side and side~=runtime.fence_from then return true,true,"crossed the low fence","COMPLETE" end
        if now-(runtime.fence_at or now)>5000 then
            return true,false,"native fence climb did not cross the edge","BLOCKED"
        end
        return false,true,"climbing the low fence","WORKING"
    end
    local adjacent,from,terminal=approachEdge(body,edge,now,runtime)
    if not adjacent then
        if terminal then return true,false,from,"NO_PATH" end
        return false,true,from,"MOVING_TO_TARGET"
    end
    local dx,dy=edge.dx,edge.dy
    if from==2 then dx,dy=-dx,-dy end
    local name=dx==1 and "E" or dx==-1 and "W" or dy==1 and "S" or "N"
    local directions=rawget(_G,"IsoDirections")
    local direction=directions and directions[name]
    if not direction then return true,false,"native fence direction is unavailable","UNSUPPORTED" end
    -- Build 42's climbOverFence returns void and silently exits when this
    -- exact native precondition fails. Check it before reporting WORKING.
    local here,there=edgeSquares(edge)
    local fromSquare,toSquare=from==1 and here or there,from==1 and there or here
    local hasCurrent,current=result(body,"getCurrentSquare")
    if not hasCurrent then
        return true,false,"native current-square check is unavailable","UNSUPPORTED"
    end
    if current~=fromSquare then
        return true,false,"Goblin is not on the fence approach square","BLOCKED"
    end
    local windowClass=rawget(_G,"IsoWindow")
    local helper=windowClass and windowClass.canClimbThroughHelper
    if type(helper)~="function" then
        return true,false,"native fence passage check is unavailable","UNSUPPORTED"
    end
    local checked,canPass=pcall(helper,body,fromSquare,toSquare,dy~=0)
    if not checked then
        return true,false,"native fence passage check failed","ENGINE_ERROR"
    end
    if canPass~=true then
        return true,false,"native fence passage is blocked from this side","BLOCKED"
    end
    local checked,canHop=result(fromSquare,"isPlayerAbleToHopWallTo",direction,toSquare)
    if not checked then
        return true,false,"native low-fence hop check is unavailable","UNSUPPORTED"
    end
    if canHop~=true then
        return true,false,"native low-fence climb is blocked from this side","BLOCKED"
    end
    local invoked=call(body,"climbOverFence",direction)
    if not invoked then return true,false,"native IsoGameCharacter fence climb failed","ENGINE_ERROR" end
    runtime.fence_from=from;runtime.fence_at=now
    return false,true,"climbing the low fence","WORKING"
end

function Access.prepareBreachWindow(owner,now,options)
    options=type(options)=="table" and options or {}
    local point=Motion.position(owner)
    if not point then return nil,"owner must be present to identify the target" end
    local best,bestDistance
    local bounds=options.bounds or {x=math.floor(point.x)-3,y=math.floor(point.y)-3,
        x2=math.floor(point.x)+3,y2=math.floor(point.y)+3}
    local z=math.floor(point.z)
    for x=bounds.x,bounds.x2 do
        for y=bounds.y,bounds.y2 do
            for _,delta in ipairs({{1,0},{0,1}}) do
                local edge={x=x,y=y,z=z,dx=delta[1],dy=delta[2]}
                local object=edgeObject(edge,true)
                local distance=(x+0.5+delta[1]*0.5-point.x)^2
                    +(y+0.5+delta[2]*0.5-point.y)^2
                local smashed=object and select(2,result(object,"isSmashed"))==true
                local barricaded=object and select(2,result(object,"isBarricaded"))==true
                local destroyed=object and select(2,result(object,"isDestroyed"))==true
                local here,there=edgeSquares(edge)
                local scopeMatches=true
                if options.target_room then
                    scopeMatches=(roomOf(here)==options.target_room)~=(roomOf(there)==options.target_room)
                elseif options.target_building then
                    scopeMatches=(buildingOf(here)==options.target_building)
                        ~=(buildingOf(there)==options.target_building)
                end
                local limit=options.max_distance_squared and tonumber(options.max_distance_squared)
                local within=options.max_distance_squared ~= nil
                    and limit ~= nil and limit >= 0 and distance <= limit
                    or options.max_distance_squared == nil
                        and (options.bounds ~= nil or distance <= 9)
                if object and scopeMatches and not smashed and not barricaded and not destroyed and within
                    and (not bestDistance or distance<bestDistance) then
                    best,bestDistance=edge,distance
                end
            end
        end
    end
    if not best then return nil,"no eligible window breach target within three tiles" end
    return {edge=best,window=true,breach=true,started_at=now,priority=8},
        "going to the explicitly authorized window breach"
end

function Access.performBreachWindow(body,payload,runtime,now)
    local edge=payload and payload.edge
    if not validEdge(edge) then return true,false,"window target changed","TARGET_CHANGED" end
    local object=edgeObject(edge,true)
    if not object then return true,false,"window is no longer loaded","TARGET_UNLOADED" end
    if select(2,result(object,"isSmashed"))==true then return true,true,"window is breached","COMPLETE" end
    local Policy=require("GoblinSurvivor/GoblinAccessPolicy")
    local allowed,code,detail=Policy.breach(body,object,payload.target_kind,payload)
    if not allowed then return true,false,detail,code end
    local adjacent,status,terminal=approachEdge(body,edge,now)
    if not adjacent then
        if terminal then return true,false,status,"NO_PATH" end
        return false,true,status,"MOVING_TO_TARGET"
    end
    local tool=require("GoblinSurvivor/GoblinTools").ensure(body,"Base.Crowbar")
    if not tool then return true,false,"reserved crowbar is unavailable","MISSING_TOOL" end
    local invoked=call(object,"smashWindow")
    local smashed=select(2,result(object,"isSmashed"))==true
    if not invoked or not smashed then return true,false,"native window breach failed","ENGINE_ERROR" end
    call(object,"syncIsoObject",false,0,nil,nil)
    markAccessChanged(body)
    return true,true,"window breached by explicit order","COMPLETE"
end

local function approachRuntime(body, runtime, edge)
    local state = runtime
    if type(state) ~= "table" then
        state = Access.approaches[body]
        if type(state) ~= "table" then state = {}; Access.approaches[body] = state end
    end
    local key = Access.canonicalEdge(edge)
    if state.access_approach_edge ~= key then
        state.access_approach_edge = key
        state.access_approach_side = nil
        state.access_approach_switched = nil
        state.access_approach_best = nil
        state.access_approach_progress_at = nil
    end
    return state
end

local function clearApproach(body, runtime)
    Access.approaches[body] = nil
    if type(runtime) ~= "table" then return end
    for _, key in ipairs({ "access_approach_edge", "access_approach_side",
        "access_approach_switched", "access_approach_best", "access_approach_progress_at" }) do
        runtime[key] = nil
    end
end

function Access.perform(body, payload, now, runtime)
    if isClient() or not isServer() then return true, false, "server work is unavailable" end
    local edge = payload and payload.edge
    local kind = payload and payload.window and "window" or "door"
    if not validEdge(edge) then return true, false, "opening target is invalid; please order me again" end
    local object = edgeObject(edge, payload.window)
    local reason = Access.blockReason(object, payload.window, not payload.window, body)
    if reason == "already open" then clearApproach(body, runtime); return true, true, kind .. " is open" end
    if reason then clearApproach(body, runtime); return true, false, kind .. " is " .. reason end
    if now - (tonumber(payload.started_at) or now) > 45000 then
        clearApproach(body, runtime)
        return true, false, "cannot reach that " .. kind .. "; clear a path and try again"
    end
    local point = Motion.position(body)
    if not point then clearApproach(body, runtime); return true, false, "cannot reach the " .. kind .. " from here" end
    local bx, by, bz = math.floor(point.x), math.floor(point.y), math.floor(point.z)
    if bz == edge.z and ((bx == edge.x and by == edge.y)
        or (bx == edge.x + edge.dx and by == edge.y + edge.dy)) then
        local openedNow = Access.open(body, object, payload.window)
        if openedNow then print("[GoblinSurvivor] OPEN_ORDER_DONE kind=" .. kind) end
        clearApproach(body, runtime)
        return true, openedNow, openedNow and kind .. " opened" or "could not open the " .. kind
    end
    local a = { x = edge.x + 0.5, y = edge.y + 0.5, z = edge.z, radius = 0.25 }
    local b = { x = a.x + edge.dx, y = a.y + edge.dy, z = edge.z, radius = 0.25 }
    local state = approachRuntime(body, runtime, edge)
    if state.access_approach_side == nil then
        state.access_approach_side = Motion.distance(point, a) <= Motion.distance(point, b) and 1 or 2
    end
    local goal = state.access_approach_side == 1 and a or b
    local distance = Motion.distance(point, goal)
    if state.access_approach_best == nil or distance < state.access_approach_best - 0.20 then
        state.access_approach_best = distance
        state.access_approach_progress_at = now
    elseif now - (tonumber(state.access_approach_progress_at) or now) >= 6000
        and state.access_approach_switched ~= true then
        -- The nearer side can itself be behind a wall. After six seconds with
        -- no material progress, try the other exact side once. This remains a
        -- native path request; completion still requires real adjacency and an
        -- observed open state.
        require("GoblinSurvivor/GoblinMovement").clear(body)
        state.access_approach_side = state.access_approach_side == 1 and 2 or 1
        state.access_approach_switched = true
        state.access_approach_best = nil
        state.access_approach_progress_at = now
        goal = state.access_approach_side == 1 and a or b
    end
    local Movement = require("GoblinSurvivor/GoblinMovement")
    local active = Movement.active[body]
    if not active or active.payload.x ~= goal.x or active.payload.y ~= goal.y then
        Movement.command(body, "MOVE_TO", goal)
    else Movement.update(body, now) end
    return false, true, "walking to open the " .. kind
end

function Access.clearApproach(body)
    clearApproach(body, nil)
end

local function nextPathSquare(body, here)
    local _, behavior = result(body, "getPathFindBehavior2")
    if not behavior then return nil end
    local setOK, isSet = fieldOrMethod(behavior, "pathNextIsSet")
    local xOK, x = fieldOrMethod(behavior, "pathNextX")
    local yOK, y = fieldOrMethod(behavior, "pathNextY")
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
            opened = setmetatable({}, { __mode = "k" }), pending = {},
            closedAfterCross = setmetatable({}, { __mode = "k" }) }
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
    for door, item in pairs(route.closedAfterCross) do
        local a, b = edgeSquares(item.edge)
        if currentKey ~= squareKey(a) and currentKey ~= squareKey(b) then
            route.closedAfterCross[door] = nil
        end
    end
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
                    if not closeNative(body, door) then keep[#keep + 1] = item
                    else route.closedAfterCross[door] = item end
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
    local point = Motion.position(body)
    local seenSquares = {}
    local function addChoice(candidate, nativeNext)
        if not candidate or seenSquares[candidate] or not scopeAllows(scope, here, candidate) then return end
        local object = doorBetween(here, candidate)
        -- A door just closed behind this actor remains adjacent until the
        -- actor leaves the far square. Do not immediately reopen it merely
        -- because the comprehensive adjacent-edge scan can still see it.
        -- A new/reversed task may legitimately need that same door before the
        -- actor can leave either adjacent square, though. In that case the
        -- native next step or a strictly goalward edge must override the
        -- suppression; otherwise Goblin walks forever into the closed door.
        if not object then return end
        local cx, cy = candidate:getX() + 0.5, candidate:getY() + 0.5
        local midpointX = (here:getX() + candidate:getX()) * 0.5 + 0.5
        local midpointY = (here:getY() + candidate:getY()) * 0.5 + 0.5
        local proximity = point and ((point.x - midpointX)^2 + (point.y - midpointY)^2) or 4
        local remaining = (goal.x - cx)^2 + (goal.y - cy)^2
        local currentRemaining = (goal.x - (here:getX() + 0.5))^2
            + (goal.y - (here:getY() + 0.5))^2
        if route.closedAfterCross[object] and not nativeNext
            and remaining >= currentRemaining then return end
        seenSquares[candidate] = true
        choices[#choices + 1] = { square = candidate, object = object,
            score = nativeNext and -1000000 or proximity * 100 + remaining }
    end
    -- The replicated server PathFindBehavior2 is authoritative when present.
    -- With a client simulation owner it is often unset, so also inspect every
    -- exact adjacent edge. Proximity makes the door the actor is physically
    -- walking into win without assuming that every useful route is goalward.
    addChoice(nextSquare, true)
    for _, delta in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        addChoice(squareAt(here:getX() + delta[1], here:getY() + delta[2], here:getZ()), false)
    end
    table.sort(choices, function(a, b) return a.score < b.score end)
    for _, choice in ipairs(choices) do
        local edge = { x = here:getX(), y = here:getY(), z = here:getZ(),
            dx = choice.square:getX() - here:getX(), dy = choice.square:getY() - here:getY() }
        local object = choice.object
        local wasOpen = opened(object)
        if wasOpen then
            registerDoor(body, edge, object, scope, now, here, true)
            return false
        end
        local openedNow, reason = Access.open(body, object, false)
        if openedNow then
            registerDoor(body, edge, object, scope, now, here, false)
            return true
        end
        local key = Access.canonicalEdge(edge)
        local previous = Access.lastFailure and Access.lastFailure[body]
        if not previous or previous.edge ~= key or previous.reason ~= reason
            or now - previous.at >= 30000 then
            Access.lastFailure = Access.lastFailure or setmetatable({}, { __mode = "k" })
            Access.lastFailure[body] = { edge = key, reason = reason, at = now }
            print("[GoblinSurvivor] DOOR_ACCESS_BLOCKED edge=" .. tostring(key)
                .. " reason=" .. tostring(reason))
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
    Access.approaches[body] = nil
end

return Access

-- Single-tile wooden-furniture scrapping. Vanilla's moveables scrap rules
-- decide eligibility and salvage; no planks are minted.
--
-- Two modes:
--  * explicit ("dismantle furniture"): the one piece beside the owner, inside
--    the owner's saved base.
--  * salvage: Goblin finds empty wooden furniture himself in nearby *other*
--    buildings (never the saved base, never any safehouse, never player-built
--    IsoThumpables), scraps it and picks up what it drops. Free will and the
--    idle chore loop use this when the base is short of planks.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Tools = require("GoblinSurvivor/GoblinTools")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
local Config = require("GoblinSurvivor/Config")

local Dismantle = { targets = setmetatable({}, { __mode = "k" }) }
local call = World.call

local function online(owner)
    if type(getOnlinePlayers) ~= "function" then return false end
    for _, player in ipairs(World.values(getOnlinePlayers())) do
        if select(2, call(player, "getUsername")) == owner then return true end
    end
    return false
end

local function propsFor(object)
    local class = rawget(_G, "ISMoveableSpriteProps")
    if not class then
        local ok = pcall(require, "Moveables/ISMoveableSpriteProps")
        if ok then class = rawget(_G, "ISMoveableSpriteProps") end
    end
    if not class or type(class.fromObject) ~= "function" then return nil end
    local ok, props = pcall(class.fromObject, object)
    return ok and props or nil
end

local function eligible(body, object, square, scope)
    if scope and not Curtains.belongsToScope(scope, square) then return nil end
    if not Policy.access(body, object) then return nil end
    local checked, empty = call(object, "isObjectNoContainerOrEmpty")
    if not checked or empty ~= true then return nil end
    for _, kind in ipairs({"isDoor", "isWindow", "isFloor", "isHoppable"}) do
        if select(2, call(object, kind)) == true then return nil end
    end
    if type(instanceof) == "function" and instanceof(object, "IsoThumpable") then return nil end
    local props = propsFor(object)
    if not props or props.canScrap ~= true or props.material ~= "Wood"
        or props.isMultiSprite == true or props.customItem
        or props.material2 or props.material3 then return nil end
    local _, index = call(object, "getObjectIndex")
    local _, sprite = call(object, "getSprite")
    local _, name = call(sprite, "getName")
    if type(index) ~= "number" or index < 0 or type(name) ~= "string" or name == "" then return nil end
    return { object = object, square = square, props = props, index = index, sprite = name }
end

local function objectExists(target)
    local square = target.square
    if World.square(World.point(square)) ~= square then return nil end
    local checked, objects = call(square, "getObjects")
    if not checked or not objects then return nil end
    for _, object in ipairs(World.values(objects)) do
        if object == target.object then return true end
    end
    return false
end

local function present(target)
    if objectExists(target) ~= true then return false end
    local _, sprite = call(target.object, "getSprite")
    local _, name = call(sprite, "getName")
    local _, index = call(target.object, "getObjectIndex")
    return name == target.sprite and index == target.index
end

local function countNewItems(square, before)
    local found = {}
    for _, worldObject in ipairs(World.values(select(2, call(square, "getWorldObjects")))) do
        local _, item = call(worldObject, "getItem")
        if item and not before[item] then
            local kind = World.fullType(item)
            if type(kind) == "string" then found[kind] = (found[kind] or 0) + 1 end
        end
    end
    return found
end

local function worldItems(square)
    local result = {}
    for _, object in ipairs(World.values(select(2, call(square, "getWorldObjects")))) do
        local _, item = call(object, "getItem")
        if item then result[item] = true end
    end
    return result
end


local function anySafehouse(square)
    local class = rawget(_G, "SafeHouse")
    if not class then return false end
    local okMember, member = pcall(function() return class.getSafeHouse end)
    if not okMember or type(member) ~= "function" then return true end
    local ok, safehouse = pcall(member, square)
    return not ok or safehouse ~= nil
end

local function baseScope(body)
    local data = Body.data(body)
    if not data or data.GoblinBaseSet ~= true then return nil, nil end
    local anchor = { x = data.GoblinBaseX, y = data.GoblinBaseY, z = data.GoblinBaseZ }
    return Curtains.scopeAt(anchor), anchor
end

-- True when salvaging this square could touch the owner's home or anyone's
-- claimed property. Unknown answers count as protected.
local function protectedSquare(body, square)
    if not square or anySafehouse(square) then return true end
    local checked, room = call(square, "getRoom")
    if not checked or not room then return true end -- indoor furnishings only
    local scope, anchor = baseScope(body)
    if anchor then
        if scope and Curtains.belongsToScope(scope, square) then return true end
        local point = World.point(square)
        local radius = tonumber(Config.salvageBaseBuffer) or 6
        if (point.x - anchor.x)^2 + (point.y - anchor.y)^2 <= radius * radius then return true end
    end
    return false
end
Dismantle.protectedSquare = protectedSquare

-- Nearest salvageable furniture around Goblin, or nil.
function Dismantle.findSalvage(body)
    local origin = Body.position(body)
    if not Support.validPoint(origin) then return nil end
    local radius = math.floor(tonumber(Config.salvageRadius) or 24)
    local best
    for dx = -radius, radius do for dy = -radius, radius do
        if dx * dx + dy * dy <= radius * radius then
            local square = World.square({x=math.floor(origin.x)+dx, y=math.floor(origin.y)+dy,
                z=math.floor(origin.z)})
            if square and not protectedSquare(body, square) then
                for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                    local target = eligible(body, object, square, nil)
                    if target then
                        local point = World.point(square)
                        target.distance = (point.x-origin.x)^2 + (point.y-origin.y)^2
                        if not best or target.distance < best.distance then best = target end
                    end
                end
            end
        end
    end end
    return best
end

local function prepareSalvage(body, owner, request)
    local ownerName = owner and select(2, call(owner, "getUsername"))
    if not ownerName or not online(ownerName) then
        return nil, "salvaging only happens while the owner is online"
    end
    local target = Dismantle.findSalvage(body)
    if not target then return nil, "no empty wooden furniture to salvage nearby (outside the base)" end
    if not Tools.ensure(body, "Base.Hammer") or not Tools.ensure(body, "Base.Saw") then
        return nil, "the reusable hammer and saw are unavailable"
    end
    local checked, result = call(target.props, "canScrapObject", body)
    if not checked or not result or result.canScrap ~= true then
        return nil, "the installed moveables rules do not allow scrapping that furniture"
    end
    local point = World.point(target.square)
    local payload = { salvage = true, autonomous = request.autonomous == true,
        anchor = { x = math.floor(point.x), y = math.floor(point.y), z = point.z },
        x = math.floor(point.x), y = math.floor(point.y), z = point.z,
        index = target.index, sprite = target.sprite, owner = ownerName }
    Dismantle.targets[body] = target
    return payload, "found furniture to salvage for materials"
end

function Dismantle.prepare(body, owner, request)
    if type(request) == "table" and request.salvage == true then
        return prepareSalvage(body, owner, request)
    end
    if type(request) ~= "table" or request.explicit_owner_order ~= true
        or request.autonomous == true then
        return nil, "dismantling requires an explicit order from the online owner"
    end
    if not owner or not online(select(2, call(owner, "getUsername"))) then
        return nil, "the owner must be online to order dismantling"
    end
    local data, ownerPoint = Body.data(body), Body.position(owner)
    if not data or data.GoblinBaseSet ~= true or not Support.validPoint(ownerPoint) then
        return nil, "set a base and stand inside it near the chosen furniture"
    end
    local anchor = { x = data.GoblinBaseX, y = data.GoblinBaseY, z = data.GoblinBaseZ }
    local scope = Curtains.scopeAt(anchor)
    local ownerSquare = World.square(ownerPoint)
    if not scope or not ownerSquare or not Curtains.belongsToScope(scope, ownerSquare) then
        return nil, "stand inside your saved base near the chosen furniture"
    end
    local candidates = {}
    for dx = -1, 1 do for dy = -1, 1 do
        local square = World.square({x=math.floor(ownerPoint.x)+dx,
            y=math.floor(ownerPoint.y)+dy,z=math.floor(ownerPoint.z)})
        if square then
            for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                local target = eligible(body, object, square, scope)
                if target then
                    local point = World.point(square)
                    target.distance = (point.x-ownerPoint.x)^2 + (point.y-ownerPoint.y)^2
                    candidates[#candidates+1] = target
                end
            end
        end
    end end
    table.sort(candidates, function(a,b) return a.distance < b.distance end)
    local target = candidates[1]
    if not target then return nil, "no empty, single-tile wooden furniture is within one tile" end
    if candidates[2] and candidates[2].distance - target.distance < 0.25 then
        return nil, "more than one wooden furniture target is equally close; stand beside just one"
    end
    if not Tools.ensure(body, "Base.Hammer") or not Tools.ensure(body, "Base.Saw") then
        return nil, "the reusable hammer and saw are unavailable"
    end
    local checked, result = call(target.props, "canScrapObject", body)
    if not checked or not result or result.canScrap ~= true then
        return nil, "the installed moveables rules do not allow scrapping this furniture"
    end
    local point = World.point(target.square)
    local payload = { anchor=anchor, x=math.floor(point.x), y=math.floor(point.y), z=point.z,
        index=target.index, sprite=target.sprite, base=anchor, building_id=scope.id,
        owner=select(2, call(owner, "getUsername")) }
    Dismantle.targets[body] = target
    return payload, "selected nearby wooden furniture for dismantling"
end

function Dismantle.update(body, payload, runtime, now)
    local target = Dismantle.targets[body]
    -- Never reacquire a destructible object by coordinates after a restart.
    if not target then return true, false, "dismantle target was lost; order it again", "INTERRUPTED" end
    if not online(payload.owner) then return true, false, "owner logged out; dismantling stopped", "INTERRUPTED" end
    local scope
    local function stillAllowed()
        if payload.salvage == true then return not protectedSquare(body, target.square) end
        return Curtains.belongsToScope(scope, target.square)
    end
    if payload.salvage ~= true then
        scope = Curtains.scopeAt(payload.base)
        if not scope or scope.id ~= payload.building_id then
            return true, false, "base house changed or unloaded", "TARGET_UNLOADED"
        end
    end
    if not present(target) or not stillAllowed() then
        return true, false, payload.salvage and "furniture changed or is now protected"
            or "furniture changed or left the base", "TARGET_CHANGED"
    end
    if not Policy.access(body, target.object) then
        return true, false, "safehouse permission no longer allows dismantling", "PERMISSION_DENIED"
    end
    local hammer, saw = Tools.ensure(body, "Base.Hammer"), Tools.ensure(body, "Base.Saw")
    if not hammer or not saw then return true, false, "hammer or saw unavailable", "MISSING_TOOL" end
    local checked, result = call(target.props, "canScrapObject", body)
    if not checked or not result or result.canScrap ~= true then
        return true, false, "native scrap eligibility changed", "BLOCKED"
    end
    local _, duration = call(target.props, "getScrapActionTime", body)
    duration = tonumber(duration)
    duration = duration and math.max(3000, math.min(30000, duration * 16.67)) or 10000
    call(body, "setPrimaryHandItem", hammer)
    call(body, "setSecondaryHandItem", saw)
    if not Support.work(body, runtime, target.square, now, duration, "BUILD", "dismantling selected furniture") then
        return false
    end
    if not present(target) or not Policy.access(body, target.object) or not stillAllowed() then
        return true, false, "furniture or permission changed before dismantling", "TARGET_CHANGED"
    end
    checked, result = call(target.props, "canScrapObject", body)
    if not checked or not result or result.canScrap ~= true then
        return true, false, "native scrap eligibility changed", "BLOCKED"
    end
    local before = worldItems(target.square)
    local worked = pcall(target.props.scrapObject, target.props, body)
    local stillThere = objectExists(target)
    Dismantle.targets[body] = nil
    if stillThere == nil then
        return true, false, "world visibility was lost after native dismantling; outcome uncertain; do not retry", "ENGINE_ERROR"
    end
    local removed = stillThere == false
    if not worked then
        return true, false, removed and "furniture was removed but salvage is uncertain; do not retry"
            or "native dismantling failed without removing the furniture", "ENGINE_ERROR"
    end
    if not removed then return true, false, "native dismantling left the furniture in place", "ENGINE_ERROR" end
    local salvage = countNewItems(target.square, before)
    local pieces = 0
    for _, count in pairs(salvage) do pieces = pieces + count end
    local data = Body.data(body)
    data.GoblinWorkCompleted = (data.GoblinWorkCompleted or 0) + 1
    if payload.salvage == true then
        local collected, planks = Dismantle.collect(body, target.square, before)
        return true, true, "salvaged furniture: "..pieces.." item(s) dropped, picked up "..collected
            .." ("..planks.." plank(s))", "COMPLETE"
    end
    return true, true, "furniture dismantled; native scrap produced "..pieces.." item(s)", "COMPLETE"
end

-- Pick up what the scrap dropped (real items through the audited pickup
-- path). Anything that does not fit stays on the floor.
function Dismantle.collect(body, square, before)
    local ok, Transfer = pcall(require, "GoblinSurvivor/GoblinTransfer")
    if not ok then return 0, 0 end
    local collected, planks = 0, 0
    for _, worldObject in ipairs(World.values(select(2, call(square, "getWorldObjects")))) do
        local _, item = call(worldObject, "getItem")
        if item and not before[item] then
            local moved = Transfer.pickup(body, { square = square, world = worldObject, item = item })
            if moved then
                collected = collected + 1
                if World.fullType(item) == "Base.Plank" then planks = planks + 1 end
            end
        end
    end
    return collected, planks
end

function Dismantle.clear(body)
    Dismantle.targets[body] = nil
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

return Dismantle

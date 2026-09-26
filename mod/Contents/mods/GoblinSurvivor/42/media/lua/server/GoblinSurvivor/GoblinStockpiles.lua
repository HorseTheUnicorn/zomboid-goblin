-- Exact-item stock thresholds for assigned base containers. This module is
-- intentionally read-only after configuration: it does not fetch or mint items.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
local Spawner = require("GoblinSurvivor/GoblinSpawner")

local Stockpiles = { sequence = 0 }
local call = World.call

local function coordinate(value)
    return type(value) == "number" and value == math.floor(value)
        and math.abs(value) <= 10000000
end

local function validItem(fullType)
    if type(fullType) ~= "string" or not string.match(fullType, "^[%w_]+%.[%w_]+$") then
        return false
    end
    local manager = rawget(_G, "ScriptManager")
    local checked, script = call(manager and manager.instance, "FindItem", fullType)
    if not checked or not script then return false end
    local okName, name = call(script, "getFullName")
    local okObsolete, obsolete = call(script, "getObsolete")
    return okName and name == fullType and okObsolete and obsolete == false
end

local function identity(object)
    local _, sprite = call(object, "getSprite")
    local _, name = call(sprite, "getName")
    local _, index = call(object, "getObjectIndex")
    return type(name) == "string" and name ~= "" and type(index) == "number"
        and index >= 0
end

local function candidates(body, point, scope)
    local found = {}
    for dx = -1, 1 do for dy = -1, 1 do
        local square = World.square({x=math.floor(point.x)+dx,y=math.floor(point.y)+dy,
            z=math.floor(point.z)})
        if square and Curtains.belongsToScope(scope, square) then
            for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                local _, container = call(object, "getContainer")
                if container and World.containerAccessible(body,object) and identity(object) and Policy.access(body, object) then
                    local p = World.point(square)
                    found[#found+1] = { object=object, square=square, container=container,
                        distance=(p.x-point.x)^2+(p.y-point.y)^2 }
                end
            end
        end
    end end
    table.sort(found, function(a,b) return a.distance < b.distance end)
    if not found[1] then return nil, "no eligible base container is within one tile" end
    if found[2] and found[2].distance - found[1].distance < 0.25 then
        return nil, "more than one container is equally close; stand beside one"
    end
    return found[1]
end

local function newId(owner, object)
    Stockpiles.sequence = Stockpiles.sequence + 1
    local now = type(getTimestampMs) == "function" and getTimestampMs() or os.time()*1000
    return table.concat({"goblin-storage", tostring(owner), tostring(now),
        tostring(Stockpiles.sequence), tostring(object)}, ":")
end

function Stockpiles.assign(body, owner, fullType, minimum)
    if not Body.isGoblin(body) or Body.owner(body) ~= select(2, call(owner, "getUsername")) then
        return false, "only this Goblin's online owner may set a stockpile rule"
    end
    if not validItem(fullType) then return false, "item must be an exact enabled installed full type" end
    minimum = tonumber(minimum)
    if not minimum or minimum ~= math.floor(minimum) or minimum < 1 or minimum > 1000 then
        return false, "stockpile minimum must be an integer from 1 to 1000"
    end
    local base = Spawner.baseForOwner(Body.owner(body))
    local point = Body.position(owner)
    if not base or not point then return false, "set a base and stand by its container" end
    local scope = Curtains.scopeAt(base)
    local ownerSquare = World.square(point)
    if not scope or not ownerSquare or not Curtains.belongsToScope(scope, ownerSquare) then
        return false, "stand inside your saved base"
    end
    local target, why = candidates(body, point, scope)
    if not target then return false, why end
    local checked, metadata = call(target.object, "getModData")
    if not checked or type(metadata) ~= "table" then return false, "container identity cannot be saved" end
    if metadata.GoblinStorageOwner and metadata.GoblinStorageOwner ~= Body.owner(body) then
        return false, "this container is assigned to another player"
    end
    local oldId, oldOwner = metadata.GoblinStorageID, metadata.GoblinStorageOwner
    metadata.GoblinStorageID = oldId or newId(Body.owner(body), target.object)
    metadata.GoblinStorageOwner = Body.owner(body)
    local pointTarget = World.point(target.square)
    local targetRecord = {x=math.floor(pointTarget.x),y=math.floor(pointTarget.y),
        z=math.floor(pointTarget.z),id=metadata.GoblinStorageID,building_id=scope.id}
    local ok, stored, detail = pcall(Spawner.setStockpileRuleForOwner, Body.owner(body),
        fullType, minimum, targetRecord)
    if not ok or stored ~= true then
        metadata.GoblinStorageID, metadata.GoblinStorageOwner = oldId, oldOwner
        return false, ok and detail or "persistent stockpile store unavailable"
    end
    call(target.object, "transmitModData")
    return true, detail
end

local function resolve(scope, body, rule)
    local target = type(rule) == "table" and rule.target
    if type(target) ~= "table" or type(target.id) ~= "string"
        or not coordinate(target.x) or not coordinate(target.y)
        or not coordinate(target.z) or target.building_id ~= scope.id then
        return nil, "TARGET_CHANGED"
    end
    local square = World.square(target)
    if not square then return nil, "TARGET_UNLOADED" end
    if not Curtains.belongsToScope(scope, square) then return nil, "TARGET_CHANGED" end
    if not Policy.access(body, {getSquare=function() return square end}) then
        return nil, "PERMISSION_DENIED"
    end
    local loaded, objects = call(square, "getObjects")
    local sized, size = call(objects, "size")
    if not loaded or not objects or not sized or type(size) ~= "number" then
        return nil, "TARGET_UNLOADED"
    end
    for _, object in ipairs(World.values(objects)) do
        local _, metadata = call(object, "getModData")
        if type(metadata) == "table" and metadata.GoblinStorageID == target.id
            and metadata.GoblinStorageOwner == Body.owner(body) then
            local _, container = call(object, "getContainer")
            if not World.containerAccessible(body,object) or not container or not Policy.access(body, object) then
                return nil, "BLOCKED"
            end
            return container, nil, square, object
        end
    end
    return nil, "TARGET_CHANGED"
end

function Stockpiles.target(scope, body, fullType)
    if not validItem(fullType) then return nil, "UNSUPPORTED" end
    local loadedRules, rules = pcall(Spawner.stockpileRulesForOwner, Body.owner(body))
    if not loadedRules or type(rules) ~= "table" then return nil, "TARGET_UNLOADED" end
    local rule = rules[fullType]
    if type(rule) ~= "table" or rule.item ~= fullType
        or type(rule.minimum) ~= "number" or rule.minimum ~= math.floor(rule.minimum)
        or rule.minimum < 1 or rule.minimum > 1000 then
        return nil, "NO_TARGET"
    end
    local container, code, square, object = resolve(scope, body, rule)
    if not container then return nil, code end
    return {container=container,square=square,object=object,
        minimum=rule.minimum,item=fullType,id=rule.target.id}
end

function Stockpiles.scan(scope, body)
    local loadedRules, rules = pcall(Spawner.stockpileRulesForOwner, Body.owner(body))
    if not loadedRules then return {status="UNKNOWN",reason="persistent stockpile rules unavailable"} end
    if type(rules) ~= "table" then return {status="NOT_CONFIGURED"} end
    local configured = false
    for _ in pairs(rules) do configured = true; break end
    if not configured then return {status="NOT_CONFIGURED"} end
    local report = {status="OK",items={}}
    local count = 0
    for fullType, rule in pairs(rules) do
        count = count + 1
        if count > 16 then return {status="UNKNOWN",reason="stockpile rule limit exceeded"} end
        local validRule = type(fullType) == "string" and validItem(fullType)
            and type(rule) == "table" and rule.item == fullType
            and type(rule.minimum) == "number" and rule.minimum == math.floor(rule.minimum)
            and rule.minimum >= 1 and rule.minimum <= 1000
        local container, failure
        if validRule then container, failure = resolve(scope, body, rule)
        else failure = "TARGET_CHANGED" end
        local row = {item=tostring(fullType),minimum=validRule and rule.minimum or nil,
            status=failure or "OK"}
        if container then
            local checked, items = call(container, "getItems")
            local sized, size = call(items, "size")
            if not checked or not items or not sized or type(size) ~= "number"
                or size ~= math.floor(size) or size < 0 or size > 10000 then
                row.status = "TARGET_UNLOADED"
            else
                local actual = 0
                for index = 0, size-1 do
                    local itemLoaded, item = call(items, "get", index)
                    if not itemLoaded or not item then
                        row.status = "TARGET_UNLOADED"
                        break
                    end
                    if World.fullType(item) == fullType then actual = actual + 1 end
                end
                if row.status ~= "TARGET_UNLOADED" then
                    row.current = actual
                    row.shortage = math.max(0, rule.minimum-actual)
                    if row.shortage > 0 then row.status = "MISSING" end
                end
            end
        end
        if row.status == "MISSING" and report.status == "OK" then report.status = "MISSING" end
        if row.status ~= "OK" and row.status ~= "MISSING" then report.status = "UNKNOWN" end
        report.items[#report.items+1] = row
    end
    table.sort(report.items,function(a,b) return a.item < b.item end)
    return report
end

return Stockpiles

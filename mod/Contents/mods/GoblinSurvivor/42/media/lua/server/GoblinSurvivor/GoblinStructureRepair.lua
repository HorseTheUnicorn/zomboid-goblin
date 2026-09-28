-- REPAIR_STRUCTURE: native moveable repair of damaged objects in the saved base.
--
-- Eligibility, tools, part list, action time and success chance all come from
-- the installed ISMoveableSpriteProps/ISMoveableDefinitions for the live
-- object and its current damage factor. Parts are real items gathered from the
-- Goblin inventory or authorized base containers; vanilla consumes them before
-- the skill roll, and so do we. The one deliberate deviation from
-- ISMoveableSpriteProps.repairObject: part consumption uses the audited
-- server-custody path (no actor-inventory packet), because Build 42 rejects
-- inventory packets addressed to the square-less managed IsoZombie.
-- Smashed windows with glass still in the frame are cleared with the native
-- IsoWindow.removeBrokenGlass + sync (ISRemoveBrokenGlass.complete).
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Tools = require("GoblinSurvivor/GoblinTools")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")

local Repair = { targets = setmetatable({}, { __mode = "k" }) }
local call = World.call
local MAX_SCAN_SQUARES = 4096
local MAX_TARGETS = 16
local TARGET_TIMEOUT = 60000
local SUPPLY_TIMEOUT = 90000
local TOOLKIT = {}
for _, kind in ipairs(Tools.types or {}) do TOOLKIT[kind] = true end

local function online(name)
    if type(getOnlinePlayers) ~= "function" then return false end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return false end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return true end
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

local function definitions()
    local class = rawget(_G, "ISMoveableDefinitions")
    if not class or type(class.getInstance) ~= "function" then return nil end
    local ok, instance = pcall(class.getInstance)
    return ok and instance or nil
end

local function healthFraction(object)
    local okHealth, health = call(object, "getHealth")
    local okMax, maximum = call(object, "getMaxHealth")
    if not okHealth or not okMax or type(health) ~= "number" or type(maximum) ~= "number"
        or maximum <= 0 then return nil end
    return health / maximum, health, maximum
end

local function objectKey(square, index)
    local p = World.point(square)
    return math.floor(p.x)..":"..math.floor(p.y)..":"..math.floor(p.z)..":"..tostring(index)
end

local function spriteName(object)
    local _, sprite = call(object, "getSprite")
    local _, name = call(sprite, "getName")
    return name
end

-- Objects whose health the native repair would restore.
local function members(props, object)
    local result = {}
    if props.isMultiSprite then
        local ok, grid = pcall(props.getSpriteGridInfo, props, select(2, call(object, "getSquare")), true)
        if not ok or type(grid) ~= "table" or #grid == 0 then return nil end
        for _, member in ipairs(grid) do
            if not member.object or not member.square then return nil end
            result[#result+1] = member.object
        end
        return result
    end
    local ok, extra = pcall(props.getAdditionalObjects, props, object)
    if ok and type(extra) == "table" and #extra > 0 then
        for _, other in ipairs(extra) do result[#result+1] = other end
        return result
    end
    return { object }
end

local function repairable(body, object, square, scope)
    if not Curtains.belongsToScope(scope, square) or not Policy.access(body, object) then return nil end
    local fraction = healthFraction(object)
    if not fraction or fraction > 0.95 or fraction < 0.20 then return nil end
    local props = propsFor(object)
    if not props then return nil end
    local ok, result = pcall(props.canRepairObject, props, body)
    if not ok or type(result) ~= "table" or result.craftValid ~= true then return nil end
    local _, index = call(object, "getObjectIndex")
    if type(index) ~= "number" or index < 0 then return nil end
    return { kind="repair", object=object, square=square, props=props, index=index,
        sprite=spriteName(object), key=objectKey(square, index), fraction=fraction }
end

local function glassTarget(body, object, square, scope)
    if type(instanceof) ~= "function" or not instanceof(object, "IsoWindow") then return nil end
    if not Curtains.belongsToScope(scope, square) or not Policy.access(body, object) then return nil end
    local _, smashed = call(object, "isSmashed")
    local _, removed = call(object, "isGlassRemoved")
    if smashed ~= true or removed ~= false then return nil end
    local _, index = call(object, "getObjectIndex")
    if type(index) ~= "number" or index < 0 then return nil end
    return { kind="glass", object=object, square=square, index=index, sprite=spriteName(object),
        key=objectKey(square, index) }
end

function Repair.scan(body, scope, skipped)
    local found, seen, scanned = {}, {}, 0
    for _, room in ipairs(scope.rooms or {}) do
        for x = room.x - 1, room.x2 + 1 do for y = room.y - 1, room.y2 + 1 do
            local k = x..":"..y..":"..room.z
            if not seen[k] then
                seen[k] = true
                scanned = scanned + 1
                if scanned > MAX_SCAN_SQUARES then return found, false end
                local square = World.square({ x=x, y=y, z=room.z })
                if square then
                    for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                        local target = glassTarget(body, object, square, scope)
                            or repairable(body, object, square, scope)
                        if target and not (skipped and skipped[target.key]) then
                            found[#found+1] = target
                        end
                    end
                end
            end
        end end
    end
    return found, true
end

local function present(target)
    local square = target.square
    if World.square(World.point(square)) ~= square then return false end
    for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
        if object == target.object then
            return select(2, call(object, "getObjectIndex")) == target.index
                and spriteName(object) == target.sprite
        end
    end
    return false
end

-- Required parts plus the first optional group that can be satisfied.
local function partPlan(body, target, anchor)
    local ok, parts = pcall(target.props.getAllRepairParts, target.props)
    if not ok or type(parts) ~= "table" then return nil, "native repair parts unavailable" end
    local required, optional = {}, {}
    for _, part in ipairs(parts) do
        if type(part.itemType) ~= "string" or type(part.amount) ~= "number" then
            return nil, "native repair part definition is malformed"
        end
        if part.required then required[#required+1] = part else optional[#optional+1] = part end
    end
    local function available(part)
        if string.sub(part.itemType, 1, 4) == "Tag." then return 0 end
        local count = 0
        for _, item in ipairs(World.items(World.inventory(body))) do
            if World.fullType(item) == part.itemType and not Tools.reserved(item) then count = count + 1 end
        end
        for _, source in ipairs(World.sources(anchor, 8, function(item)
            return World.fullType(item) == part.itemType and not Tools.reserved(item) end, body)) do
            count = count + 1
            if count >= part.amount then break end
        end
        return count
    end
    local plan = {}
    for _, part in ipairs(required) do plan[#plan+1] = part end
    if optional[1] then
        local chosen
        for _, part in ipairs(optional) do
            if available(part) >= part.amount then chosen = part; break end
        end
        plan[#plan+1] = chosen or optional[1]
    end
    return plan
end

local function carriedCount(body, itemType)
    local count = 0
    for _, item in ipairs(World.items(World.inventory(body))) do
        if World.fullType(item) == itemType and not Tools.reserved(item) then count = count + 1 end
    end
    return count
end

-- Walk to one real nearby part and take it. Unlike Support.supply this does
-- not stop at the first carried copy, because repairs need exact amounts.
local function gatherOne(body, runtime, anchor, itemType, now)
    runtime.supplySkipped = runtime.supplySkipped or {}
    if not runtime.supply or runtime.supply.kind ~= itemType then
        runtime.supply = nil
        if now < (runtime.nextSupplyScan or 0) then return false end
        runtime.supplySearch = runtime.supplySearch or {}
        local found, done = World.search(anchor, World.range(), function(item)
            return World.fullType(item) == itemType and not Tools.reserved(item)
                and not runtime.supplySkipped[item] end, body, runtime.supplySearch, 3000)
        if not done then return false end
        runtime.supplySearch = nil
        runtime.nextSupplyScan = now + 10000
        if found[1] then
            found[1].kind = itemType
            runtime.supply, runtime.supplyAt = found[1], now
        end
    end
    local source = runtime.supply
    if not source then
        Support.status(body, "no "..itemType.." around here; I will scavenge some myself.")
        return false
    end
    Body.data(body).GoblinAction = ""
    runtime.readyAt = nil
    if World.approach(body, source.square, now) then
        if not World.take(body, source) then runtime.supplySkipped[source.item] = true end
        runtime.supply, runtime.nextSupplyScan = nil, 0
    elseif now - (runtime.supplyAt or now) > 30000 then
        runtime.supplySkipped[source.item] = true
        runtime.supply = nil
    end
    return false
end

local function ensureTools(body, target)
    local defs = definitions()
    local def = defs and defs.getRepairDefinition and defs.getRepairDefinition(target.props.material)
    if not def then return false, "native repair definition unavailable" end
    for _, group in ipairs({ def.tools or {}, def.tools2 or {} }) do
        for _, kind in ipairs(group) do
            if TOOLKIT[kind] then Tools.ensure(body, kind) end
        end
    end
    local okTool, tool = pcall(target.props.hasRepairTool, target.props, body)
    local okTool2, tool2 = pcall(target.props.hasRepairTool, target.props, body, true)
    if not okTool or not tool or not okTool2 or not tool2 then
        return false, "the "..tostring(target.props.material).." repair tools are unavailable"
    end
    if type(tool) ~= "boolean" then call(body, "setPrimaryHandItem", tool) end
    if type(tool2) ~= "boolean" then call(body, "setSecondaryHandItem", tool2) end
    return true
end

-- Remove exactly the native repair parts from Goblin custody.
local function consume(body, plan)
    local selected, drains = {}, {}
    for _, part in ipairs(plan) do
        local manager = rawget(_G, "ScriptManager")
        local _, script = call(manager and manager.instance, "FindItem", part.itemType)
        local drainable = script and type(instanceof) == "function"
            and instanceof(script, "DrainableComboItem")
        local count = 0
        for _, item in ipairs(World.items(World.inventory(body))) do
            if World.fullType(item) == part.itemType and not Tools.reserved(item) then
                if drainable then
                    local _, uses = call(item, "getCurrentUses")
                    if type(uses) == "number" and uses >= part.amount then
                        drains[#drains+1] = { item=item, amount=part.amount }; count = part.amount; break
                    end
                elseif count < part.amount then
                    selected[#selected+1] = item; count = count + 1
                end
            end
        end
        if count < part.amount then return nil, part.itemType end
    end
    if not World.reserve(body, selected) then return nil, "reservation" end
    for _, drain in ipairs(drains) do
        for _ = 1, drain.amount do call(drain.item, "Use") end
    end
    return { removed=#selected, drained=#drains }
end

function Repair.prepare(body, owner, request)
    if type(request) ~= "table" or request.explicit_owner_order ~= true or request.autonomous == true then
        return nil, "structure repair requires an explicit order from the online owner"
    end
    local ownerName = select(2, call(owner, "getUsername"))
    if ownerName ~= Body.owner(body) or not online(ownerName) then
        return nil, "the owning player must be online"
    end
    local data = Body.data(body)
    if not data or data.GoblinBaseSet ~= true then return nil, "set a base first" end
    local anchor = { x=data.GoblinBaseX, y=data.GoblinBaseY, z=data.GoblinBaseZ }
    if not Support.validPoint(anchor) then return nil, "saved base position is invalid" end
    local scope = Curtains.scopeAt(anchor)
    if not scope then return nil, "saved base house is unavailable" end
    local found = Repair.scan(body, scope, {})
    if not found[1] then return nil, "no damaged object in the base is eligible for native repair" end
    return { anchor=anchor, building_id=scope.id, owner=ownerName, repaired=0, failed=0,
        glass=0, attempts=0 }, "found "..#found.." structure(s) to repair or clear"
end

function Repair.update(body, payload, runtime, now)
    runtime.skipped = runtime.skipped or {}
    if not online(payload.owner) then
        return true, false, "owner logged out; repairs stopped", "INTERRUPTED"
    end
    local scope = Curtains.scopeAt(payload.anchor)
    if not scope or scope.id ~= payload.building_id then
        return true, false, "base house changed or unloaded", "TARGET_UNLOADED"
    end
    local function summary()
        return string.format("%d repaired, %d attempt(s) failed the skill roll, %d window(s) cleared of glass",
            payload.repaired or 0, payload.failed or 0, payload.glass or 0)
    end
    local target = runtime.target
    if target and (not present(target) or not Policy.access(body, target.object)
        or not Curtains.belongsToScope(scope, target.square)) then
        runtime.skipped[target.key] = true
        runtime.target, runtime.readyAt, runtime.supply = nil, nil, nil
        target = nil
    end
    if not target then
        if (payload.attempts or 0) >= MAX_TARGETS then
            return true, (payload.repaired or 0) + (payload.glass or 0) > 0,
                summary().."; repair limit reached for this order",
                ((payload.repaired or 0) + (payload.glass or 0) > 0) and "COMPLETE" or "BLOCKED"
        end
        local found = Repair.scan(body, scope, runtime.skipped)
        local here = Body.position(body)
        table.sort(found, function(a, b)
            local pa, pb = World.point(a.square), World.point(b.square)
            return (pa.x-here.x)^2+(pa.y-here.y)^2 < (pb.x-here.x)^2+(pb.y-here.y)^2
        end)
        target = found[1]
        if not target then
            local worked = (payload.repaired or 0) + (payload.glass or 0)
            if worked > 0 or (payload.failed or 0) > 0 then
                return true, worked > 0, summary(), worked > 0 and "COMPLETE" or "BLOCKED"
            end
            if runtime.lastMissing then
                return true, false, "repairs need "..runtime.lastMissing.." in my supplies or near the base",
                    "MISSING_MATERIAL"
            end
            return true, false, "no eligible damaged structures remain", "NO_TARGET"
        end
        runtime.target, runtime.targetAt, runtime.readyAt = target, now, nil
    end
    if now - (runtime.targetAt or now) > TARGET_TIMEOUT + SUPPLY_TIMEOUT then
        runtime.skipped[target.key] = true
        runtime.target = nil
        return false
    end
    if target.kind == "glass" then
        if not Support.work(body, runtime, target.square, now, 2500, "BUILD", "clearing broken glass") then
            return false
        end
        runtime.readyAt = nil
        local ok = call(target.object, "removeBrokenGlass")
        local _, removed = call(target.object, "isGlassRemoved")
        runtime.target = nil
        if not ok or removed ~= true then
            runtime.skipped[target.key] = true
            return true, false, "native glass removal did not change the window", "ENGINE_ERROR"
        end
        call(target.object, "sync")
        payload.glass = (payload.glass or 0) + 1
        payload.attempts = (payload.attempts or 0) + 1
        print("[GoblinSurvivor] STRUCTURE_REPAIR kind=glass owner="..tostring(payload.owner)
            .." key="..target.key)
        return false
    end
    -- Native object repair.
    local toolsOK, toolWhy = ensureTools(body, target)
    if not toolsOK then
        runtime.skipped[target.key] = true
        runtime.target = nil
        runtime.lastMissing = toolWhy
        return false
    end
    local point = World.point(target.square)
    local plan, why = partPlan(body, target, point)
    if not plan then runtime.skipped[target.key] = true; runtime.target = nil; return false end
    for _, part in ipairs(plan) do
        if string.sub(part.itemType, 1, 4) ~= "Tag." and carriedCount(body, part.itemType) < part.amount then
            runtime.lastMissing = part.itemType
            -- Conjure Goblin's own repair parts before touching base stock.
            local Provision = require("GoblinSurvivor/GoblinProvision")
            if Provision.enabled() and Provision.ensure(body, part.itemType, part.amount,
                "structure repair", function(item)
                    return World.fullType(item) == part.itemType and not Tools.reserved(item) end) then
                return false
            end
            gatherOne(body, runtime, point, part.itemType, now)
            if now - (runtime.targetAt or now) > SUPPLY_TIMEOUT then
                runtime.skipped[target.key] = true
                runtime.target = nil
            end
            return false
        end
    end
    local okParts, hasParts = pcall(target.props.hasRepairParts, target.props, body)
    if not okParts or not hasParts then
        runtime.lastMissing = "native repair parts"
        runtime.skipped[target.key] = true
        runtime.target = nil
        return false
    end
    local okTime, duration = pcall(target.props.getRepairActionTime, target.props, body)
    duration = okTime and tonumber(duration) or nil
    duration = duration and math.max(3000, math.min(30000, duration * 16.67)) or 8000
    if not Support.work(body, runtime, target.square, now, duration, "BUILD", "repairing a damaged structure") then
        return false
    end
    runtime.readyAt = nil
    if not present(target) or not Policy.access(body, target.object) then
        runtime.skipped[target.key] = true; runtime.target = nil
        return false
    end
    local objects = members(target.props, target.object)
    if not objects then
        runtime.skipped[target.key] = true; runtime.target = nil
        return false
    end
    local okChance, chance = pcall(target.props.getRepairSkillChance, target.props, body)
    chance = okChance and tonumber(chance) or nil
    if not chance then
        runtime.skipped[target.key] = true; runtime.target = nil
        return true, false, "native repair chance unavailable; no materials used", "ENGINE_ERROR"
    end
    local used, missing = consume(body, plan)
    if not used then
        runtime.lastMissing = missing
        runtime.skipped[target.key] = true; runtime.target = nil
        return false
    end
    payload.attempts = (payload.attempts or 0) + 1
    runtime.target = nil
    local roll = type(ZombRand) == "function" and (ZombRand(100) + 1) or 1
    if roll > chance then
        payload.failed = (payload.failed or 0) + 1
        runtime.skipped[target.key] = true
        print("[GoblinSurvivor] STRUCTURE_REPAIR kind=object result=skill_fail owner="
            ..tostring(payload.owner).." key="..target.key.." chance="..tostring(chance))
        return false
    end
    for _, object in ipairs(objects) do
        local _, maximum = call(object, "getMaxHealth")
        call(object, "setHealth", maximum)
    end
    call(target.object, "sync")
    local fraction = healthFraction(target.object)
    if not fraction or fraction < 0.999 then
        return true, false, "materials were used but native health did not change; inspect before retrying",
            "ENGINE_ERROR"
    end
    payload.repaired = (payload.repaired or 0) + 1
    print("[GoblinSurvivor] STRUCTURE_REPAIR kind=object result=repaired owner="
        ..tostring(payload.owner).." key="..target.key.." material="..tostring(target.props.material))
    return false
end

function Repair.clear(body)
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

return Repair

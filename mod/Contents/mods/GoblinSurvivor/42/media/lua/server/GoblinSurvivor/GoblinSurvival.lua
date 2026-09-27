-- Milestone 5 survival adapters that map onto installed native operations.
--
-- CHOP_WOOD  : ISChopTreeAction's server path, IsoTree.WeaponHit(actor, axe)
--              repeated until the tree leaves the square; the engine drops
--              the logs. Uses the reserved toolkit axe only.
-- TREAT_PLAYER: ISApplyBandage.complete for the online owner: a real bandage
--              item from Goblin custody or nearby storage, BodyDamage
--              SetBandaged + syncBodyPart. Bleeding parts first.
-- Cooking, tailoring, fishing, trapping and foraging stay unregistered until a
-- managed-IsoZombie native path is verified; see docs/V2_STATUS.md.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Tools = require("GoblinSurvivor/GoblinTools")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Transfer = require("GoblinSurvivor/GoblinTransfer")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")

local Survival = {}
local call = World.call

local function playerFor(name)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return nil end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return player end
    end
    return nil
end

local function ownerOrder(body, owner, request)
    if type(request) ~= "table" or request.explicit_owner_order ~= true or request.autonomous == true then
        return nil, "this job requires an explicit order from the online owner"
    end
    local name = select(2, call(owner, "getUsername"))
    if name ~= Body.owner(body) or not playerFor(name) then return nil, "the owning player must be online" end
    return name
end

local function isTree(object)
    return type(instanceof) == "function" and instanceof(object, "IsoTree")
end

local function objectIndex(object)
    local ok, index = call(object, "getObjectIndex")
    return ok and type(index) == "number" and index or -1
end

-- ------------------------------------------------------------ CHOP_WOOD

Survival.Chop = {}

local function nearestTree(body, center, radius, skipped)
    local best, bestDistance
    for dx = -radius, radius do for dy = -radius, radius do
        local square = World.square({ x=center.x+dx, y=center.y+dy, z=center.z })
        if square then
            for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                if isTree(object) and objectIndex(object) >= 0 and not skipped[object]
                    and Policy.access(body, object) then
                    local d = dx*dx + dy*dy
                    if not best or d < bestDistance then best, bestDistance = { tree=object, square=square }, d end
                end
            end
        end
    end end
    return best
end

function Survival.Chop.prepare(body, owner, request)
    local name, why = ownerOrder(body, owner, request)
    if not name then return nil, why end
    local point = Body.position(owner)
    if not Support.validPoint(point) then return nil, "owner position unavailable" end
    local count = tonumber(request.count) or 1
    if count ~= math.floor(count) or count < 1 or count > 5 then return nil, "chop 1 to 5 trees per order" end
    local anchor = { x=math.floor(point.x), y=math.floor(point.y), z=math.floor(point.z) }
    if not nearestTree(body, anchor, 8, {}) then return nil, "no tree within eight tiles of you" end
    if not Tools.ensure(body, "Base.Axe") then return nil, "the reusable axe is unavailable" end
    return { owner=name, anchor=anchor, count=count, felled=0, hits=0 },
        "felling "..count.." nearby tree(s); the logs stay where they fall"
end

function Survival.Chop.update(body, payload, runtime, now)
    runtime.skipped = runtime.skipped or {}
    if not playerFor(payload.owner) then return true, false, "owner logged out; chopping stopped", "INTERRUPTED" end
    if (payload.felled or 0) >= payload.count then
        return true, true, "felled "..payload.felled.." tree(s)", "COMPLETE"
    end
    local target = runtime.target
    if target and (objectIndex(target.tree) < 0) then
        payload.felled = (payload.felled or 0) + 1
        print("[GoblinSurvivor] CHOP_WOOD felled owner="..tostring(payload.owner).." hits="..tostring(runtime.hits))
        runtime.target, runtime.hits, runtime.readyAt = nil, 0, nil
        return false
    end
    if not target then
        target = nearestTree(body, payload.anchor, 8, runtime.skipped)
        if not target then
            local felled = payload.felled or 0
            return true, felled > 0, "felled "..felled.." tree(s); no more trees nearby",
                felled > 0 and "COMPLETE" or "NO_TARGET"
        end
        runtime.target, runtime.targetAt, runtime.hits = target, now, 0
    end
    local axe = Tools.ensure(body, "Base.Axe")
    if not axe then return true, false, "the reusable axe is unavailable", "MISSING_TOOL" end
    local broken = select(2, call(axe, "isBroken"))
    if broken == true then return true, false, "the axe is broken", "MISSING_TOOL" end
    call(body, "setPrimaryHandItem", axe)
    if not Support.work(body, runtime, target.square, now, 1500, "BUILD", "chopping a tree") then
        if now - (runtime.targetAt or now) > 45000 then
            runtime.skipped[target.tree] = true
            runtime.target = nil
        end
        return false
    end
    runtime.readyAt = nil
    if not Policy.access(body, target.tree) then
        runtime.skipped[target.tree] = true; runtime.target = nil
        return false
    end
    local before = select(2, call(target.tree, "getHealth"))
    local ok = call(target.tree, "WeaponHit", body, axe)
    if not ok then return true, false, "the engine rejected the axe hit", "ENGINE_ERROR" end
    runtime.hits = (runtime.hits or 0) + 1
    payload.hits = (payload.hits or 0) + 1
    local after = select(2, call(target.tree, "getHealth"))
    if objectIndex(target.tree) >= 0 and type(before) == "number" and type(after) == "number"
        and after >= before and runtime.hits >= 5 then
        runtime.skipped[target.tree] = true; runtime.target = nil
        return true, false, "axe hits are not damaging the tree for this actor", "UNSUPPORTED"
    end
    if runtime.hits > 200 then
        runtime.skipped[target.tree] = true; runtime.target = nil
    end
    return false
end

function Survival.Chop.clear(body)
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

-- --------------------------------------------------------- TREAT_PLAYER

Survival.Treat = {}

local function bandagePower(item)
    local ok, power = call(item, "getBandagePower")
    if ok and type(power) == "number" and power > 0 then return power end
    return nil
end

local function woundedParts(player)
    local damage = select(2, call(player, "getBodyDamage"))
    local parts = World.values(select(2, call(damage, "getBodyParts")))
    local list = {}
    for _, part in ipairs(parts) do
        local bandaged = select(2, call(part, "bandaged")) == true
        if not bandaged then
            local bleeding = (tonumber(select(2, call(part, "getBleedingTime"))) or 0) > 0
            local wound = select(2, call(part, "scratched")) == true or select(2, call(part, "isCut")) == true
                or select(2, call(part, "deepWounded")) == true or select(2, call(part, "bitten")) == true
            if bleeding or wound then
                list[#list+1] = { part=part, bleeding=bleeding }
            end
        end
    end
    table.sort(list, function(a, b) return a.bleeding and not b.bleeding end)
    return list, damage
end

local function carriedBandage(body)
    local best, bestPower
    for _, item in ipairs(World.items(World.inventory(body))) do
        local power = bandagePower(item)
        local kind = World.fullType(item) or ""
        if power and not Transfer.protected(body, item) and not string.find(kind, "Dirty", 1, true) then
            if not best or power > bestPower then best, bestPower = item, power end
        end
    end
    return best
end

function Survival.Treat.prepare(body, owner, request)
    local name, why = ownerOrder(body, owner, request)
    if not name then return nil, why end
    local wounds = woundedParts(owner)
    if not wounds[1] then return nil, "you have no unbandaged wounds" end
    return { owner=name, anchor=Body.position(owner), treated=0 },
        "coming to bandage "..#wounds.." wound(s)"
end

function Survival.Treat.update(body, payload, runtime, now)
    local player = playerFor(payload.owner)
    if not player then return true, false, "owner logged out", "INTERRUPTED" end
    local wounds, damage = woundedParts(player)
    local wound = wounds[1]
    if not wound then
        return true, true, "bandaged "..(payload.treated or 0).." wound(s)", "COMPLETE"
    end
    local bandage = carriedBandage(body)
    if not bandage then
        local center = Body.position(body)
        local source = runtime.source
        if not source then
            for _, candidate in ipairs(World.sources(center, 8, function(item)
                return bandagePower(item) ~= nil and not string.find(World.fullType(item) or "", "Dirty", 1, true)
            end, body)) do
                if not (runtime.skippedItems and runtime.skippedItems[candidate.item]) then source = candidate; break end
            end
            runtime.source, runtime.sourceAt = source, now
        end
        if not source then
            return true, (payload.treated or 0) > 0, "bandaged "..(payload.treated or 0)
                .." wound(s); no clean bandages nearby", "MISSING_MATERIAL"
        end
        if World.approach(body, source.square, now) then
            runtime.source = nil
            if not Transfer.pickup(body, source) then
                runtime.skippedItems = runtime.skippedItems or {}
                runtime.skippedItems[source.item] = true
            end
        elseif now - (runtime.sourceAt or now) > 30000 then
            runtime.skippedItems = runtime.skippedItems or {}
            runtime.skippedItems[source.item] = true
            runtime.source = nil
        end
        return false
    end
    local square = select(2, call(player, "getCurrentSquare"))
    -- Not equipped: a held item counts as protected equipment for custody checks.
    if not Support.work(body, runtime, square, now, 3000, "CRAFT", "bandaging you") then return false end
    runtime.readyAt = nil
    local manipulating = select(2, call(wound.part, "manipulatingUsername"))
    if type(manipulating) == "string" and manipulating ~= "" then
        return true, false, "someone else is treating that wound", "BLOCKED"
    end
    local index = select(2, call(wound.part, "getIndex"))
    if type(index) ~= "number" then return true, false, "wound location unreadable", "ENGINE_ERROR" end
    local level = 0
    local perks = rawget(_G, "Perks")
    if perks and perks.Doctor then level = tonumber(select(2, call(body, "getPerkLevel", perks.Doctor))) or 0 end
    local life = (type(ZombRandFloat) == "function" and ZombRandFloat((level + 1) * 0.5, (level + 1) * 1.0)
        or (level + 1) * 0.5) + (bandagePower(bandage) or 0)
    local alcoholic = select(2, call(bandage, "isAlcoholic")) == true
    local kind = World.fullType(bandage)
    local infected = select(2, call(bandage, "isInfected")) == true
    if not Transfer.detach(body, bandage) then
        return true, false, "could not take the bandage out of my supplies", "ENGINE_ERROR"
    end
    local ok = call(damage, "SetBandaged", index, true, life, alcoholic, kind)
    if not ok or select(2, call(wound.part, "bandaged")) ~= true then
        -- Nothing was applied: return the bandage to custody.
        call(World.inventory(body), "AddItem", bandage)
        return true, false, "the bandage did not stay on", "ENGINE_ERROR"
    end
    if infected then call(wound.part, "SetInfected", true) end
    call(wound.part, "setManipulatingUsername", nil)
    if type(syncBodyPart) == "function" then pcall(syncBodyPart, wound.part, 0xc001966b8e) end
    payload.treated = (payload.treated or 0) + 1
    print("[GoblinSurvivor] TREAT_PLAYER owner="..tostring(payload.owner).." part="..tostring(index)
        .." bandage="..tostring(kind))
    return false
end

function Survival.Treat.clear(body)
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

return Survival

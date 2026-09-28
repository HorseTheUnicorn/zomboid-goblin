-- Conjured supplies for Goblin's own work.
--
-- Goblin may create installed items (parts, planks, nails, seeds, water,
-- bandages, fuel cans, recipe ingredients, food) straight into his own
-- inventory when a job he is doing needs them. They exist only to be consumed
-- or installed by that job. Every conjured item carries GoblinConjured in its
-- modData and is quarantined: GoblinTransfer, loot delivery, stockpiling and
-- sorting refuse to move it into a container, onto the floor or into a
-- player's inventory, crafted outputs made from conjured inputs inherit the
-- mark, and conjured items are destroyed if Goblin dies.
local Config = require("GoblinSurvivor/Config")
local World = require("GoblinSurvivor/GoblinWorld")

local Provision = { recent = setmetatable({}, { __mode = "k" }), MAX_PER_CALL = 20 }
local call = World.call

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

function Provision.enabled()
    return Config.provisionEnabled ~= false
end

function Provision.isConjured(item)
    local ok, data = call(item, "getModData")
    return ok and type(data) == "table" and data.GoblinConjured == true
end

function Provision.taint(item, purpose)
    local ok, data = call(item, "getModData")
    if ok and type(data) == "table" then
        data.GoblinConjured = true
        data.GoblinConjuredFor = data.GoblinConjuredFor or purpose
        return true
    end
    return false
end

-- Exact enabled, non-obsolete installed full type only.
function Provision.validType(fullType)
    if type(fullType) ~= "string" or not string.match(fullType, "^[%w_]+%.[%w_]+$") then return false end
    local manager = rawget(_G, "ScriptManager")
    local checked, script = call(manager and manager.instance, "FindItem", fullType)
    if not checked or not script then return false end
    local okName, name = call(script, "getFullName")
    local okObsolete, obsolete = call(script, "getObsolete")
    return okName and name == fullType and (not okObsolete or obsolete ~= true)
end

local function instantiate(fullType)
    local factory = rawget(_G, "instanceItem")
    if type(factory) == "function" then
        local ok, item = pcall(factory, fullType)
        if ok and item then return item end
    end
    local legacy = rawget(_G, "InventoryItemFactory")
    if legacy and type(legacy.CreateItem) == "function" then
        local ok, item = pcall(legacy.CreateItem, fullType)
        if ok and item then return item end
    end
    return nil
end

-- Rolling one-minute budget per Goblin so a stuck job cannot flood the save.
local function budget(body, count)
    local now = nowMs()
    local state = Provision.recent[body]
    if not state or now - state.since >= 60000 then state = { since = now, used = 0 } end
    Provision.recent[body] = state
    local limit = tonumber(Config.provisionPerMinute) or 60
    if state.used + count > limit then return false end
    state.used = state.used + count
    return true
end

-- Create count items of fullType in Goblin's own inventory for purpose.
-- Returns the list of created items, or nil plus a reason.
function Provision.create(body, fullType, count, purpose)
    if not Provision.enabled() then return nil, "conjuring is disabled on this server" end
    count = tonumber(count) or 1
    if count ~= math.floor(count) or count < 1 or count > Provision.MAX_PER_CALL then
        return nil, "conjure 1 to "..Provision.MAX_PER_CALL.." items at a time"
    end
    if not Provision.validType(fullType) then return nil, "not an installed item: "..tostring(fullType) end
    if not budget(body, count) then return nil, "conjuring limit reached; wait a minute" end
    local inventory = World.inventory(body)
    if not inventory then return nil, "Goblin inventory unavailable" end
    local created = {}
    for _ = 1, count do
        local item = instantiate(fullType)
        if not item then break end
        Provision.taint(item, purpose)
        -- Server-side custody only: the managed actor inventory has no packet
        -- address, and conjured items never become visible world objects.
        local ok, value = call(inventory, "AddItem", item)
        if not ok or value ~= item or World.containsExact(inventory, item) ~= true then break end
        created[#created+1] = item
    end
    if type(print) == "function" then
        print("[GoblinSurvivor] PROVISION item="..tostring(fullType).." count="..#created
            .." purpose="..tostring(purpose))
    end
    if #created == 0 then return nil, "the engine could not create "..fullType end
    return created
end

-- Fill a conjured fluid container (water for farming, petrol for refuelling).
function Provision.fill(item, fluidName)
    if not Provision.isConjured(item) then return false end
    local fluid = select(2, call(item, "getFluidContainer"))
    local Fluid = rawget(_G, "Fluid")
    local kind = Fluid and Fluid[fluidName]
    if not fluid or not kind then return false end
    local capacity = tonumber(select(2, call(fluid, "getCapacity"))) or 0
    local amount = tonumber(select(2, call(fluid, "getAmount"))) or 0
    if capacity <= 0 then return false end
    if amount < capacity then call(fluid, "addFluid", kind, capacity - amount) end
    return (tonumber(select(2, call(fluid, "getAmount"))) or 0) > amount or amount >= capacity
end

-- Conjure one fluid container already filled with fluidName.
function Provision.fluid(body, fullType, fluidName, purpose)
    local created, why = Provision.create(body, fullType, 1, purpose)
    if not created then return nil, why end
    Provision.fill(created[1], fluidName)
    return created[1]
end

-- Count carried items accepted by predicate; conjure fullType for the rest.
function Provision.ensure(body, fullType, need, purpose, predicate)
    predicate = predicate or function(item) return World.fullType(item) == fullType end
    local have = 0
    for _, item in ipairs(World.items(World.inventory(body))) do
        if predicate(item) then have = have + 1 end
    end
    if have >= need then return true end
    local created, why = Provision.create(body, fullType, math.min(Provision.MAX_PER_CALL, need - have), purpose)
    return created ~= nil, why
end

-- Destroy every conjured item Goblin carries (death, despawn).
function Provision.purge(body)
    local inventory = World.inventory(body)
    local removed = 0
    for _, item in ipairs(World.items(inventory)) do
        if Provision.isConjured(item) then
            local ok = call(inventory, "DoRemoveItem", item)
            if not ok then call(inventory, "Remove", item) end
            removed = removed + 1
        end
    end
    return removed
end

return Provision

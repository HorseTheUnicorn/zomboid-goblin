-- Semantic storage categories for owner-assigned base containers.
--
-- Categories are derived only from the installed item definition
-- (InventoryItem.getDisplayCategory, then getCategory). Unknown or ambiguous
-- items return nil and stay where they are. Assignments are persisted as
-- primitive records (container marker ID, square, BuildingDef scope ID).
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
local Spawner = require("GoblinSurvivor/GoblinSpawner")

local Storage = { sequence = 0, MAX_ASSIGNMENTS = 24 }
local call = World.call

-- Special buckets: INBOX is a drop box the Goblin empties while sorting;
-- OVERFLOW accepts any sortable item when its own category is full.
Storage.CATEGORIES = {
    FOOD=true, WATER=true, MEDICAL=true, TOOLS=true, WEAPONS=true, AMMO=true,
    MATERIALS=true, CLOTHING=true, BOOKS=true, ELECTRONICS=true, FARMING=true,
    COOKING=true, SURVIVAL=true, VEHICLE=true, MISC=true, INBOX=true, OVERFLOW=true
}

local ALIASES = {
    FOODS="FOOD", MEDS="MEDICAL", MEDICINE="MEDICAL", TOOL="TOOLS", WEAPON="WEAPONS",
    GUNS="WEAPONS", BULLETS="AMMO", MATERIAL="MATERIALS", BUILDING="MATERIALS",
    CLOTHES="CLOTHING", BOOK="BOOKS", LITERATURE="BOOKS", ELECTRONIC="ELECTRONICS",
    GARDENING="FARMING", SEEDS="FARMING", KITCHEN="COOKING", CAMPING="SURVIVAL",
    MECHANICS="VEHICLE", CAR="VEHICLE", JUNK="MISC", OTHER="MISC", DROPBOX="INBOX",
    UNSORTED="INBOX", SPARE="OVERFLOW"
}

-- Installed Build 42.20.4 display categories (reference/pz-items.json).
local DISPLAY = {
    Food="FOOD", Water="WATER", WaterContainer="WATER",
    FirstAid="MEDICAL", Bandage="MEDICAL",
    Tool="TOOLS", ToolWeapon="TOOLS", LightSource="TOOLS", FireSource="TOOLS",
    Weapon="WEAPONS", WeaponCrafted="WEAPONS", WeaponPart="WEAPONS", BrokenWeapon="WEAPONS",
    Ammo="AMMO", Explosives="AMMO",
    Material="MATERIALS", MaterialWeapon="MATERIALS", RecipeResource="MATERIALS", Paint="MATERIALS",
    Clothing="CLOTHING", Accessory="CLOTHING", ProtectiveGear="CLOTHING", Bag="CLOTHING",
    Appearance="CLOTHING",
    Literature="BOOKS", SkillBook="BOOKS", Cartography="BOOKS",
    Electronics="ELECTRONICS", Communications="ELECTRONICS",
    Gardening="FARMING", GardeningWeapon="FARMING",
    Cooking="COOKING", CookingWeapon="COOKING",
    Camping="SURVIVAL", Fishing="SURVIVAL", FishingWeapon="SURVIVAL", Trapping="SURVIVAL",
    VehicleMaintenance="VEHICLE", Tuning="VEHICLE",
    Household="MISC", HouseholdWeapon="MISC", Junk="MISC", JunkWeapon="MISC",
    Memento="MISC", Entertainment="MISC", Instrument="MISC", InstrumentWeapon="MISC",
    Sports="MISC", SportsWeapon="MISC", Container="MISC", Furniture="MISC",
    AnimalPart="MISC", AnimalPartWeapon="MISC"
}
-- Keys/locks, body-attached, debug and corpse items are never moved by sorting.
local NEVER = {
    Security=true, Wound=true, ZedDmg=true, Hidden=true, Amputation=true, Prosthesis=true,
    Surgery=true, Corpse=true, Bug=true, MaleBody=true, Ears=true, Tail=true, Eye=true
}
local LEGACY = { Food="FOOD", Weapon="WEAPONS", Clothing="CLOTHING", Literature="BOOKS" }

function Storage.normalize(name)
    if type(name) ~= "string" then return nil end
    local key = string.upper((string.gsub(name, "[^%a]", "")))
    key = ALIASES[key] or key
    return Storage.CATEGORIES[key] and key or nil
end

function Storage.category(item)
    local okDisplay, display = call(item, "getDisplayCategory")
    if okDisplay and type(display) == "string" and display ~= "" then
        if NEVER[display] then return nil end
        if DISPLAY[display] then return DISPLAY[display] end
    end
    local okLegacy, legacy = call(item, "getCategory")
    if okLegacy and type(legacy) == "string" and LEGACY[legacy] then return LEGACY[legacy] end
    return nil
end

local function coordinate(value)
    return type(value) == "number" and value == math.floor(value) and math.abs(value) <= 10000000
end

local function identity(object)
    local _, sprite = call(object, "getSprite")
    local _, name = call(sprite, "getName")
    local _, index = call(object, "getObjectIndex")
    return type(name) == "string" and name ~= "" and type(index) == "number" and index >= 0
end

local function newId(owner, object)
    Storage.sequence = Storage.sequence + 1
    local now = type(getTimestampMs) == "function" and getTimestampMs() or os.time() * 1000
    return table.concat({ "goblin-storage", tostring(owner), tostring(now),
        tostring(Storage.sequence), tostring(object) }, ":")
end

-- The single closest accessible container within one tile of point.
local function nearestContainer(body, point, scope)
    local found = {}
    for dx = -1, 1 do for dy = -1, 1 do
        local square = World.square({ x=math.floor(point.x)+dx, y=math.floor(point.y)+dy,
            z=math.floor(point.z) })
        if square and Curtains.belongsToScope(scope, square) then
            for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                local _, container = call(object, "getContainer")
                if container and identity(object) and World.containerAccessible(body, object)
                    and Policy.access(body, object) then
                    local p = World.point(square)
                    found[#found+1] = { object=object, square=square, container=container,
                        distance=(p.x-point.x)^2 + (p.y-point.y)^2 }
                end
            end
        end
    end end
    table.sort(found, function(a, b) return a.distance < b.distance end)
    if not found[1] then return nil, "no eligible base container is within one tile" end
    if found[2] and found[2].distance - found[1].distance < 0.25 then
        return nil, "more than one container is equally close; stand beside one"
    end
    return found[1]
end

local function ownerContext(body, owner)
    if not Body.isGoblin(body) or Body.owner(body) ~= select(2, call(owner, "getUsername")) then
        return nil, "only this Goblin's online owner may assign storage"
    end
    local base = Spawner.baseForOwner(Body.owner(body))
    local point = Body.position(owner)
    if not base or not point then return nil, "set a base and stand by its container" end
    local scope = Curtains.scopeAt(base)
    local square = World.square(point)
    if not scope or not square or not Curtains.belongsToScope(scope, square) then
        return nil, "stand inside your saved base"
    end
    return { base=base, point=point, scope=scope }
end

function Storage.assign(body, owner, categoryName)
    local category = Storage.normalize(categoryName)
    if not category then return false, "unknown storage category" end
    local context, why = ownerContext(body, owner)
    if not context then return false, why end
    local target
    target, why = nearestContainer(body, context.point, context.scope)
    if not target then return false, why end
    local checked, metadata = call(target.object, "getModData")
    if not checked or type(metadata) ~= "table" then return false, "container identity cannot be saved" end
    if metadata.GoblinStorageOwner and metadata.GoblinStorageOwner ~= Body.owner(body) then
        return false, "this container is assigned to another player"
    end
    local oldId, oldOwner, oldCategory = metadata.GoblinStorageID, metadata.GoblinStorageOwner,
        metadata.GoblinStorageCategory
    metadata.GoblinStorageID = oldId or newId(Body.owner(body), target.object)
    metadata.GoblinStorageOwner = Body.owner(body)
    metadata.GoblinStorageCategory = category
    local p = World.point(target.square)
    local record = { id=metadata.GoblinStorageID, category=category, x=math.floor(p.x),
        y=math.floor(p.y), z=math.floor(p.z), building_id=context.scope.id }
    local ok, stored, detail = pcall(Spawner.setStorageAssignmentForOwner, Body.owner(body), record)
    if not ok or stored ~= true then
        metadata.GoblinStorageID, metadata.GoblinStorageOwner = oldId, oldOwner
        metadata.GoblinStorageCategory = oldCategory
        return false, ok and detail or "persistent storage store unavailable"
    end
    call(target.object, "transmitModData")
    return true, "container assigned to "..category
end

function Storage.unassign(body, owner)
    local context, why = ownerContext(body, owner)
    if not context then return false, why end
    local target
    target, why = nearestContainer(body, context.point, context.scope)
    if not target then return false, why end
    local _, metadata = call(target.object, "getModData")
    if type(metadata) ~= "table" or metadata.GoblinStorageOwner ~= Body.owner(body)
        or type(metadata.GoblinStorageID) ~= "string" then
        return false, "this container has no storage category of yours"
    end
    local ok, removed = pcall(Spawner.clearStorageAssignmentForOwner, Body.owner(body),
        metadata.GoblinStorageID)
    if not ok or removed ~= true then return false, "persistent storage store unavailable" end
    metadata.GoblinStorageCategory = nil
    call(target.object, "transmitModData")
    return true, "storage category removed"
end

-- Resolve one persisted assignment to its live container, or nil + code.
function Storage.resolve(body, scope, record)
    if type(record) ~= "table" or type(record.id) ~= "string" or not coordinate(record.x)
        or not coordinate(record.y) or not coordinate(record.z)
        or record.building_id ~= scope.id or not Storage.CATEGORIES[record.category] then
        return nil, "TARGET_CHANGED"
    end
    local square = World.square(record)
    if not square then return nil, "TARGET_UNLOADED" end
    if not Curtains.belongsToScope(scope, square) then return nil, "TARGET_CHANGED" end
    for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
        local _, metadata = call(object, "getModData")
        if type(metadata) == "table" and metadata.GoblinStorageID == record.id
            and metadata.GoblinStorageOwner == Body.owner(body) then
            local _, container = call(object, "getContainer")
            if not container or not World.containerAccessible(body, object)
                or not Policy.access(body, object) then
                return nil, "BLOCKED"
            end
            return { id=record.id, category=record.category, container=container,
                object=object, square=square }
        end
    end
    return nil, "TARGET_CHANGED"
end

-- All live assignments in the base scope, plus per-record failures.
function Storage.assignments(body, scope)
    local loaded, records = pcall(Spawner.storageAssignmentsForOwner, Body.owner(body))
    if not loaded or type(records) ~= "table" then return nil, "TARGET_UNLOADED" end
    local live, failures = {}, {}
    local ids = {}
    for id in pairs(records) do ids[#ids+1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local target, code = Storage.resolve(body, scope, records[id])
        if target then live[#live+1] = target else failures[#failures+1] = { id=id, code=code } end
    end
    return live, failures
end

-- Destination order for an item: same category first, then OVERFLOW.
function Storage.destinations(live, category)
    local primary, overflow = {}, {}
    for _, target in ipairs(live) do
        if target.category == category then primary[#primary+1] = target
        elseif target.category == "OVERFLOW" then overflow[#overflow+1] = target end
    end
    for _, target in ipairs(overflow) do primary[#primary+1] = target end
    return primary
end

function Storage.byId(live, id)
    for _, target in ipairs(live or {}) do if target.id == id then return target end end
    return nil
end

return Storage

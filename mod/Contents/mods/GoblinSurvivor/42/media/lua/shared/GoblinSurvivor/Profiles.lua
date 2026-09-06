-- Serializable survivor profiles.  A profile describes policy and appearance;
-- it is not an alternate physical entity type.
local Profiles = {}

local DEFAULT = {
    sex = "male",
    skinTone = "light",
    hair = "short",
    hairColor = { r = 0.18, g = 0.12, b = 0.08 },
    beard = "none",
    beardColor = { r = 0.18, g = 0.12, b = 0.08 },
    clothing = {},
    shoes = nil,
    backpack = nil,
    voice = "male",
    walkSpeed = 0.70,
    runSpeed = 1.00,
    immortal = false,
    infectionImmune = false,
    needsFood = true,
    needsWater = true,
    needsSleep = true,
    defaultGoal = "IDLE",
    externalBrain = "NONE",
    followDistance = 3,
    role = "companion",
    -- Every managed human uses the same verified B42 rifle contract.  The
    -- server reasserts this on every authority tick and the client adapter
    -- equips the matching local visual item from the snapshot profile.
    weapon = "Base.AssaultRifle2",
    weapon_policy = "unlimited_ammo",
    combat_policy = "hunt",
    god_mode = true
}

local DEFINITIONS = {
    ["goblin.primary"] = {
        type = "GOBLIN",
        displayName = "Goblin",
        immortal = true,
        infectionImmune = true,
        needsFood = false,
        needsWater = false,
        needsSleep = false,
        defaultGoal = "FOLLOW",
        externalBrain = "GOBLIN",
        weapon = "Base.AssaultRifle2",
        weapon_policy = "unlimited_ammo",
        combat_policy = "hunt",
        role = "companion"
    },
    ["dev.test.001"] = {
        type = "TEST",
        displayName = "Test Survivor",
        defaultGoal = "IDLE",
        externalBrain = "NONE",
        role = "test"
    },
    ["npc.sarah"] = {
        type = "COMPANION",
        displayName = "Sarah",
        sex = "female",
        hair = "long",
        hairColor = { r = 0.32, g = 0.16, b = 0.08 },
        role = "medic"
    },
    ["npc.bob"] = {
        type = "COMPANION",
        displayName = "Bob",
        sex = "male",
        hair = "short",
        hairColor = { r = 0.08, g = 0.06, b = 0.04 },
        beard = "short",
        role = "guard"
    },
    ["npc.dave"] = {
        type = "COMPANION",
        displayName = "Dave",
        sex = "male",
        hair = "short",
        hairColor = { r = 0.52, g = 0.30, b = 0.12 },
        role = "hauler"
    },
    ["npc.ellen"] = {
        type = "COMPANION",
        displayName = "Ellen",
        sex = "female",
        hair = "short",
        hairColor = { r = 0.12, g = 0.08, b = 0.04 },
        role = "farmer"
    },
    ["npc.mike"] = {
        type = "COMPANION",
        displayName = "Mike",
        sex = "male",
        hair = "short",
        hairColor = { r = 0.20, g = 0.10, b = 0.05 },
        beard = "short",
        role = "builder"
    },
    ["npc.june"] = {
        type = "COMPANION",
        displayName = "June",
        sex = "female",
        hair = "long",
        hairColor = { r = 0.42, g = 0.24, b = 0.10 },
        role = "scout"
    },
    ["npc.lee"] = {
        type = "COMPANION",
        displayName = "Lee",
        sex = "male",
        hair = "short",
        hairColor = { r = 0.04, g = 0.03, b = 0.02 },
        role = "medic"
    },
    ["npc.rosa"] = {
        type = "COMPANION",
        displayName = "Rosa",
        sex = "female",
        hair = "short",
        hairColor = { r = 0.08, g = 0.05, b = 0.03 },
        role = "mechanic"
    }
}

local MANAGED_IDS = {
    "npc.sarah", "npc.bob", "npc.dave", "npc.ellen",
    "npc.mike", "npc.june", "npc.lee", "npc.rosa"
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, nested in pairs(value) do result[key] = copy(nested) end
    return result
end

-- B42 item ids verified against the local installation.  The stable hash
-- determines a deterministic permutation of the catalog for managed IDs, so
-- the choice looks random while remaining identical on every client and
-- across body recreation.  Goblin deliberately has no hat so his required
-- Spike hairstyle remains visible.
local OUTFIT_CATALOG = {
    {
        top = "Base.Tshirt_ArmyGreen",
        outer = "Base.Jacket_ArmyOliveDrab",
        pants = "Base.Trousers_OliveDrab",
        shoes = "Base.Shoes_ArmyBoots",
        head = nil,
        back = "Base.Bag_ALICEpack_Army"
    },
    {
        top = "Base.Tshirt_WhiteLongSleeve",
        outer = "Base.Jacket_Padded_HuntingCamo",
        pants = "Base.Trousers_JeanBaggy",
        shoes = "Base.Shoes_HikingBoots",
        head = "Base.Hat_Beany",
        back = "Base.Bag_Satchel_Medical"
    },
    {
        top = "Base.Shirt_Lumberjack",
        outer = "Base.Vest_Hunting_Camo",
        pants = "Base.Trousers_Denim",
        shoes = "Base.Shoes_WorkBoots",
        head = "Base.Hat_BaseballCapBlue",
        back = "Base.Bag_WorkerBag"
    },
    {
        top = "Base.Tshirt_CamoGreen",
        outer = "Base.Jacket_ArmyCamoGreen",
        pants = "Base.Trousers_CamoGreen",
        shoes = "Base.Shoes_ArmyBoots",
        head = "Base.Hat_BonnieHat_CamoGreen",
        back = "Base.Bag_ALICEpack"
    },
    {
        top = "Base.Tshirt_PoloStripedTINT",
        outer = "Base.Jacket_LeatherBrown",
        pants = "Base.Trousers_Black",
        shoes = "Base.Shoes_RedTrainers",
        head = "Base.Hat_BaseballCapRed",
        back = "Base.Bag_Schoolbag"
    },
    {
        top = "Base.Tshirt_WhiteLongSleeve",
        outer = "Base.Jacket_CoatArmy",
        pants = "Base.Trousers_ArmyService",
        shoes = "Base.Shoes_WorkBoots",
        head = "Base.Hat_HardHat",
        back = "Base.Bag_ToolBag"
    },
    {
        top = "Base.Shirt_HawaiianRed",
        outer = "Base.Jacket_NavyBlue",
        pants = "Base.Shorts_LongDenim",
        shoes = "Base.Shoes_CowboyBoots",
        head = "Base.Hat_Cowboy",
        back = "Base.Bag_NormalHikingBag"
    },
    {
        top = "Base.Tshirt_HuntingCamo",
        outer = "Base.Jacket_HuntingCamo",
        pants = "Base.Trousers_HuntingCamo",
        shoes = "Base.Shoes_ArmyBootsDesert",
        head = "Base.Hat_BonnieHat_DesertCamo",
        back = "Base.Bag_ALICEpack_DesertCamo"
    },
    {
        top = "Base.Tshirt_ArmyGreen",
        outer = "Base.Jacket_ArmyCamoGreen",
        pants = "Base.Trousers_Denim",
        shoes = "Base.Shoes_HikingBoots",
        head = "Base.Hat_HardHat",
        back = "Base.Bag_WorkerBag"
    }
}

local function stableHash(id)
    local hash = 17
    local text = tostring(id or "")
    for index = 1, #text do
        hash = (hash * 31 + string.byte(text, index)) % 2147483647
    end
    return hash
end

local function randomizedOutfit(id)
    -- Reserve catalog entry 1 for Goblin: the unblocked head slot is part of
    -- his identity, not a cosmetic roll.  Sort the companion IDs by their
    -- stable hashes and assign the remaining catalog entries in that order;
    -- this is pseudo-random-looking but collision-free for the eight named
    -- companion slots.
    if id == "goblin.primary" then
        return copy(OUTFIT_CATALOG[1])
    end
    local ranked = {}
    for _, candidate in ipairs(MANAGED_IDS) do
        table.insert(ranked, {
            id = candidate,
            hash = stableHash(candidate)
        })
    end
    table.sort(ranked, function(left, right)
        if left.hash == right.hash then return left.id < right.id end
        return left.hash < right.hash
    end)
    for rank, candidate in ipairs(ranked) do
        if candidate.id == id then
            return copy(OUTFIT_CATALOG[rank + 1])
        end
    end
    local available = #OUTFIT_CATALOG - 1
    local index = (stableHash(id) % available) + 2
    return copy(OUTFIT_CATALOG[index])
end

function Profiles.forId(id, overrides)
    local result = copy(DEFAULT)
    local defined = DEFINITIONS[id]
    if defined ~= nil then
        for key, value in pairs(defined) do result[key] = copy(value) end
    end
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do result[key] = copy(value) end
    end
    if type(result.outfit) ~= "table" then
        result.outfit = randomizedOutfit(id)
    end
    -- Goblin's fixed identity survives saved profiles and recreation overrides.
    -- "Spike" is the exact B42 hairstyle identifier (not LibertySpikes).
    if id == "goblin.primary" then result.hair = "Spike" end
    result.id = id
    result.survivorId = id
    result.displayName = result.displayName or id
    return result
end

function Profiles.goblin()
    return Profiles.forId("goblin.primary")
end

function Profiles.test()
    return Profiles.forId("dev.test.001")
end

function Profiles.managedIds(count)
    local result = {}
    local limit = tonumber(count) or 0
    if limit < 0 then limit = 0 end
    if limit > #MANAGED_IDS then limit = #MANAGED_IDS end
    for index = 1, limit do
        result[index] = MANAGED_IDS[index]
    end
    return result
end

return Profiles

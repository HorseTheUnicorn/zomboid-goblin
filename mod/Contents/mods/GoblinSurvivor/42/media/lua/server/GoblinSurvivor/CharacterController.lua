local CharacterCatalog = require("GoblinSurvivor/CharacterCatalog")
local ClientBridge = require("GoblinSurvivor/ClientBridge")

local CharacterController = {
    -- This remains false until the disposable multiplayer feasibility gate
    -- proves that a deterministic server-owned or supported client body can
    -- create, own, and persist a survivor.
    available = false,
    characterState = "fresh",
    generation = nil
}

local validCharacterStates = {
    fresh = true,
    creation_pending = true,
    active = true,
    dead = true,
    recreate_required = true
}

local required = {
    name = true,
    gender = true,
    skin_tone = true,
    hair_style = true,
    hair_color = true,
    profession = true,
    traits = true,
    clothing = true,
    accessories = true
}

local function safeId(value)
    return type(value) == "string"
        and #value > 0
        and #value <= 64
        and not string.find(value, "[^a-z0-9%._:%-]")
end

local function hasOption(catalog, category, optionId)
    if type(catalog) ~= "table"
        or type(catalog.options) ~= "table"
        or type(category) ~= "string"
        or not safeId(optionId) then
        return false
    end
    local values = catalog.options[category]
    if type(values) ~= "table" then
        return false
    end
    for _, option in ipairs(values) do
        if type(option) == "table"
            and option.id == optionId
            and option.source == "vanilla" then
            return true
        end
    end
    return false
end

local function validateProposal(proposal, catalog)
    if type(proposal) ~= "table" or type(catalog) ~= "table" then
        return false
    end
    for key, _ in pairs(proposal) do
        if type(key) ~= "string" or key == "code" or key == "command"
            or key == "eval" or key == "exec" or key == "lua"
            or key == "shell" or key == "script" or key == "raw"
            or key == "raw_packet" or key == "packet" or key == "x"
            or key == "y" or key == "z" or key == "cell"
            or key == "chunk" or key == "teleport" then
            return false
        end
    end
    for key, _ in pairs(required) do
        if proposal[key] == nil then
            return false
        end
    end
    if proposal.name ~= "Goblin" then
        return false
    end
    for _, category in ipairs({"gender", "skin_tone", "hair_style", "hair_color", "profession"}) do
        if not hasOption(catalog, category, proposal[category]) then
            return false
        end
    end
    if type(proposal.traits) ~= "table" or #proposal.traits < 1 or #proposal.traits > 5 then
        return false
    end
    local seenTraits = {}
    for _, optionId in ipairs(proposal.traits) do
        if not hasOption(catalog, "trait", optionId) then
            return false
        end
        if seenTraits[optionId] then
            return false
        end
        seenTraits[optionId] = true
    end
    if type(proposal.clothing) ~= "table" or #proposal.clothing > 8 then
        return false
    end
    local clothingCount = 0
    for category, optionId in pairs(proposal.clothing) do
        if type(category) ~= "string"
            or not string.find(category, "^clothing_")
            or not hasOption(catalog, category, optionId) then
            return false
        end
        clothingCount = clothingCount + 1
    end
    if clothingCount < 1 then
        return false
    end
    if type(proposal.accessories) ~= "table" or #proposal.accessories > 8 then
        return false
    end
    local seenAccessories = {}
    for _, optionId in ipairs(proposal.accessories) do
        local found = false
        for category, _ in pairs(catalog.options) do
            if type(category) == "string" and string.find(category, "^accessory")
                and hasOption(catalog, category, optionId) then
                found = true
                break
            end
        end
        if not found then
            return false
        end
        if seenAccessories[optionId] then
            return false
        end
        seenAccessories[optionId] = true
    end
    for _, entry in ipairs({
        {key = "beard_style", category = "beard_style"},
        {key = "beard_color", category = "beard_color"},
        {key = "body_type", category = "body_type"}
    }) do
        if proposal[entry.key] ~= nil
            and not hasOption(catalog, entry.category, proposal[entry.key]) then
            return false
        end
    end
    if proposal.cosmetics ~= nil then
        if type(proposal.cosmetics) ~= "table" then
            return false
        end
        for category, optionId in pairs(proposal.cosmetics) do
            if type(category) ~= "string"
                or not string.find(category, "^cosmetic_")
                or not hasOption(catalog, category, optionId) then
                return false
            end
        end
    end
    return true
end

function CharacterController.state()
    local remote = ClientBridge.state()
    local remoteState = remote.character_state
    local remoteGeneration = remote.character_generation
    if type(remoteState) == "string" and validCharacterStates[remoteState] then
        CharacterController.characterState = remoteState
    end
    if type(remoteGeneration) == "number"
        and math.floor(remoteGeneration) == remoteGeneration
        and remoteGeneration >= 0 then
        CharacterController.generation = remoteGeneration
    end
    return {
        body_present = ClientBridge.bodyPresent(),
        client_control_ready = ClientBridge.clientControlReady(),
        character_state = CharacterController.characterState,
        character_generation = CharacterController.generation
    }
end

function CharacterController.apply(message)
    local catalog = CharacterCatalog.get()
    if not ClientBridge.clientControlReady() then
        return false, "native client control or exact mod parity is unavailable"
    end
    if type(message) ~= "table"
        or type(message.generation) ~= "number"
        or message.generation < 1
        or type(message.catalog_version) ~= "string"
        or type(catalog) ~= "table"
        or message.catalog_version ~= catalog.version
        or not validateProposal(message.proposal, catalog) then
        return false, "character command failed deterministic validation"
    end
    local sent, detail = ClientBridge.sendCharacterCreate(message)
    if not sent then
        return false, detail
    end
    CharacterController.available = true
    CharacterController.characterState = "creation_pending"
    CharacterController.generation = message.generation
    return true, detail
end

return CharacterController

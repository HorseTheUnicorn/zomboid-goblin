local Net = require("GoblinSurvivor/Net")
local CharacterCatalog = {
    cached = nil
}

-- Build 42 does not expose a stable, server-side character-creation catalog
-- through this scaffold.  A verified PZ adapter may provide this function
-- after the body feasibility gate passes.  No custom or mod-defined options
-- are accepted by the Python validator or the future adapter.
local function provider()
    local adapter = rawget(_G, "GoblinVanillaCatalogProvider")
    if type(adapter) ~= "table" or type(adapter.get) ~= "function" then
        return nil
    end
    return adapter.get()
end

local function validCategory(category)
    return type(category) == "string"
        and #category > 0
        and #category <= 64
        and string.find(category, "^[a-z][a-z0-9_:%-]*$") ~= nil
        and (
            category == "gender"
            or category == "skin_tone"
            or category == "hair_style"
            or category == "hair_color"
            or category == "beard_style"
            or category == "beard_color"
            or category == "profession"
            or category == "trait"
            or category == "body_type"
            or string.find(category, "^clothing_") ~= nil
            or string.find(category, "^accessory") ~= nil
            or string.find(category, "^cosmetic_") ~= nil
        )
end

local function validate(catalog)
    if type(catalog) ~= "table" or not Net.safeTable(catalog) then
        return false, "catalog is not a bounded table"
    end
    if type(catalog.version) ~= "string"
        or not Net.safeId(catalog.version, 64)
        or type(catalog.options) ~= "table" then
        return false, "catalog envelope is invalid"
    end
    local parsed = {}
    local required = {
        gender = false,
        skin_tone = false,
        hair_style = false,
        hair_color = false,
        profession = false,
        trait = false
    }
    local clothingCount = 0
    for category, values in pairs(catalog.options) do
        if not validCategory(category)
            or type(values) ~= "table"
            or #values < 1
            or #values > Net.maxCatalogItems then
            return false, "catalog option list is invalid"
        end
        local entries = {}
        local seen = {}
        for index = 1, #values do
            local option = values[index]
            if type(option) ~= "table"
                or not Net.safeTable(option)
                or type(option.id) ~= "string"
                or not Net.safeId(option.id, 64)
                or type(option.label) ~= "string"
                or not Net.safeText(option.label, 96, false)
                or option.source ~= "vanilla" then
                return false, "catalog contains a non-vanilla option"
            end
            for key, _ in pairs(option) do
                if key ~= "id" and key ~= "label" and key ~= "source" then
                    return false, "catalog option has an unexpected field"
                end
            end
            if seen[option.id] then
                return false, "catalog contains a duplicate option"
            end
            seen[option.id] = true
            table.insert(entries, {
                id = option.id,
                label = option.label,
                source = "vanilla"
            })
        end
        parsed[category] = entries
        if required[category] ~= nil then
            required[category] = true
        end
        if string.find(category, "^clothing_") then
            clothingCount = clothingCount + 1
        end
    end
    for _, present in pairs(required) do
        if not present then
            return false, "catalog is missing a required vanilla category"
        end
    end
    if clothingCount < 1 then
        return false, "catalog has no vanilla clothing category"
    end
    return {
        version = catalog.version,
        options = parsed
    }, nil
end

function CharacterCatalog.set(catalog)
    local parsed, reason = validate(catalog)
    if not parsed then
        return false, reason
    end
    CharacterCatalog.cached = parsed
    return true
end

function CharacterCatalog.clear()
    CharacterCatalog.cached = nil
end

function CharacterCatalog.get()
    local catalog = CharacterCatalog.cached or provider()
    if type(catalog) ~= "table" then
        return nil
    end
    local parsed = validate(catalog)
    if type(parsed) ~= "table" then
        return nil
    end
    if CharacterCatalog.cached == nil then
        CharacterCatalog.cached = parsed
    end
    return CharacterCatalog.cached
end

return CharacterCatalog

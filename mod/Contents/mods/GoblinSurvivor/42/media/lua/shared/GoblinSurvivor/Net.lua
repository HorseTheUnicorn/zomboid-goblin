-- Typed, bounded multiplayer messages for the Goblin body adapter.
-- This module is intentionally transport-only.  It never evaluates text or
-- forwards a Lua/table payload that has not passed the allowlist.
local Net = {
    module = "GoblinSurvivor",
    maxDepth = 5,
    maxKeys = 32768,
    maxString = 1024,
    maxCatalogItems = 256
}

local forbiddenKeys = {
    code = true,
    command = true,
    eval = true,
    exec = true,
    lua = true,
    shell = true,
    script = true,
    raw = true,
    raw_packet = true,
    packet = true,
    coordinates = true,
    coordinate = true,
    x = true,
    y = true,
    z = true,
    cell = true,
    chunk = true,
    teleport = true,
    path = true,
    file = true,
    filename = true,
    os = true,
    process = true
}

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function boundedText(value, maximum, allowEmpty)
    if type(value) ~= "string" or #value > (maximum or Net.maxString) then
        return false
    end
    if not allowEmpty and #value == 0 then
        return false
    end
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
            return false
        end
    end
    return true
end

function Net.safeText(value, maximum, allowEmpty)
    return boundedText(value, maximum, allowEmpty)
end

function Net.safeId(value, maximum)
    return boundedText(value, maximum or 64, false)
        and string.find(value, "^[a-z0-9][a-z0-9%._:%-]*$") ~= nil
end

function Net.safeNumber(value, minimum, maximum)
    if not finiteNumber(value) then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function safeValue(value, depth, budget)
    local valueType = type(value)
    if value == nil or valueType == "boolean" then
        return true, budget
    end
    if valueType == "number" then
        return finiteNumber(value), budget
    end
    if valueType == "string" then
        return boundedText(value, Net.maxString, true), budget
    end
    if valueType ~= "table" or depth > Net.maxDepth then
        return false, budget
    end
    for key, nested in pairs(value) do
        budget = budget + 1
        if budget > Net.maxKeys then
            return false, budget
        end
        local keyType = type(key)
        if keyType == "string" then
            if forbiddenKeys[string.lower(key)] then
                return false, budget
            end
        elseif keyType == "number" then
            if not finiteNumber(key) or math.floor(key) ~= key or key < 1 then
                return false, budget
            end
        else
            return false, budget
        end
        local ok
        ok, budget = safeValue(nested, depth + 1, budget)
        if not ok then
            return false, budget
        end
    end
    return true, budget
end

function Net.safeTable(value)
    local ok = safeValue(value, 0, 0)
    return ok == true
end

function Net.safeCommand(command)
    return type(command) == "string"
        and string.find(command, "^[a-z][a-z0-9_%-]*$") ~= nil
end

function Net.allowedKeys(value, allowed)
    if type(value) ~= "table" or type(allowed) ~= "table" or not Net.safeTable(value) then
        return false
    end
    for key, _ in pairs(value) do
        if type(key) ~= "string" or not allowed[string.lower(key)] then
            return false
        end
    end
    return true
end

local function validStringList(value, maximum, pattern)
    if type(value) ~= "table" or #value > maximum then
        return false
    end
    local seen = {}
    for index = 1, #value do
        local item = value[index]
        if not boundedText(item, 128, false) then
            return false
        end
        if pattern and string.find(item, pattern) == nil then
            return false
        end
        local folded = string.lower(item)
        if seen[folded] then
            return false
        end
        seen[folded] = true
    end
    return true
end

function Net.validManifest(value)
    if type(value) ~= "table" or not Net.safeTable(value) then
        return false
    end
    local expected = {
        game_build = true,
        mods = true,
        workshop_items = true,
        goblin_survivor_sha256 = true
    }
    for key, _ in pairs(value) do
        if type(key) ~= "string" or not expected[key] then
            return false
        end
    end
    if not boundedText(value.game_build, 64, false)
        or string.find(value.game_build, "^[A-Za-z0-9][A-Za-z0-9%._%+%- ]*$") == nil then
        return false
    end
    if not validStringList(value.mods, 4096, "^[A-Za-z0-9][A-Za-z0-9%._:%- ]*$") then
        return false
    end
    if not validStringList(value.workshop_items, 4096, "^[0-9][0-9]*$") then
        return false
    end
    if not boundedText(value.goblin_survivor_sha256, 64, false)
        or #value.goblin_survivor_sha256 ~= 64
        or string.find(value.goblin_survivor_sha256, "^[0-9a-f]+$") == nil then
        return false
    end
    return true
end

function Net.sameList(left, right)
    if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
        return false
    end
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

function Net.sendClient(command, args)
    if type(sendClientCommand) ~= "function"
        or not Net.safeCommand(command)
        or type(args) ~= "table"
        or not Net.safeTable(args) then
        return false
    end
    local ok = pcall(sendClientCommand, Net.module, command, args)
    return ok == true
end

function Net.sendServerToPlayer(player, command, args)
    if type(sendServerCommand) ~= "function"
        or player == nil
        or not Net.safeCommand(command)
        or type(args) ~= "table"
        or not Net.safeTable(args) then
        return false
    end
    local ok = pcall(sendServerCommand, player, Net.module, command, args)
    return ok == true
end

function Net.sendServerToClientId(clientId, command, args)
    if type(sendServerCommand) ~= "function"
        or not finiteNumber(clientId)
        or math.floor(clientId) ~= clientId
        or clientId < 0
        or not Net.safeCommand(command)
        or type(args) ~= "table"
        or not Net.safeTable(args) then
        return false
    end
    -- Build 42 exposes this overload to server Lua.  It is the only path used
    -- before a player object exists; it is not a raw packet API.
    local ok = pcall(sendServerCommand, Net.module, command, args, clientId)
    return ok == true
end

return Net

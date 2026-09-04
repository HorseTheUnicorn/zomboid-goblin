-- Bounded table and identifier helpers for server-local bridge validation.
local Net = { maxDepth = 5, maxKeys = 2048, maxString = 1024 }

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function boundedText(value, maximum, allowEmpty)
    if type(value) ~= "string" or #value > (maximum or Net.maxString)
        or (not allowEmpty and #value == 0) then return false end
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then return false end
    end
    return true
end

function Net.safeText(value, maximum, allowEmpty)
    return boundedText(value, maximum, allowEmpty)
end

function Net.safeId(value, maximum)
    return boundedText(value, maximum or 96, false)
        and string.find(value, "^[A-Za-z0-9][A-Za-z0-9%._:%-]*$") ~= nil
end

local function safeValue(value, depth, budget)
    local kind = type(value)
    if value == nil or kind == "boolean" then return true, budget end
    if kind == "number" then return finiteNumber(value), budget end
    if kind == "string" then return boundedText(value, Net.maxString, true), budget end
    if kind ~= "table" or depth > Net.maxDepth then return false, budget end
    for key, nested in pairs(value) do
        budget = budget + 1
        if budget > Net.maxKeys then return false, budget end
        if type(key) ~= "string" and type(key) ~= "number" then return false, budget end
        if type(key) == "number" and (not finiteNumber(key) or math.floor(key) ~= key or key < 1) then
            return false, budget
        end
        local ok
        ok, budget = safeValue(nested, depth + 1, budget)
        if not ok then return false, budget end
    end
    return true, budget
end

function Net.safeTable(value)
    local ok = safeValue(value, 0, 0)
    return ok == true
end

return Net

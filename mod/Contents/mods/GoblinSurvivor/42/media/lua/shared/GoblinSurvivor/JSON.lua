-- Small strict JSON codec for Build 42's mod Lua sandbox.
--
-- Build 42 does not expose io, lfs, or a JSON helper in the server Lua
-- globals.  The bridge only needs ordinary JSON objects/arrays, so keep the
-- codec local, bounded, and deliberately unable to execute input.

local JSON = {}

local DEFAULT_MAX_BYTES = 262144
local MAX_DEPTH = 16
local MAX_NODES = 20000

local function fail(message)
    error(message)
end

local function addPart(parts, state, value)
    state.size = state.size + #value
    if state.size > state.maxBytes then
        fail("JSON value exceeds the configured byte limit")
    end
    parts[#parts + 1] = value
end

local function escapeString(value, parts, state)
    if #value > state.maxBytes then
        fail("JSON string exceeds the configured byte limit")
    end
    addPart(parts, state, '"')
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte == 34 then
            addPart(parts, state, '\\"')
        elseif byte == 92 then
            addPart(parts, state, '\\\\')
        elseif byte == 8 then
            addPart(parts, state, '\\b')
        elseif byte == 12 then
            addPart(parts, state, '\\f')
        elseif byte == 10 then
            addPart(parts, state, '\\n')
        elseif byte == 13 then
            addPart(parts, state, '\\r')
        elseif byte == 9 then
            addPart(parts, state, '\\t')
        elseif byte < 32 then
            addPart(parts, state, string.format('\\u%04x', byte))
        else
            -- Preserve UTF-8 bytes.  JSON permits UTF-8 text directly.
            addPart(parts, state, string.char(byte))
        end
    end
    addPart(parts, state, '"')
end

local encodeValue

local function encodeTable(value, parts, state, depth)
    if depth > MAX_DEPTH then
        fail("JSON nesting is too deep")
    end
    if state.seen[value] then
        fail("JSON table contains a cycle")
    end
    state.seen[value] = true

    local count = 0
    local maxIndex = 0
    local isArray = true
    local keys = {}
    for key, _ in pairs(value) do
        count = count + 1
        state.nodes = state.nodes + 1
        if state.nodes > MAX_NODES then
            fail("JSON value contains too many nodes")
        end
        if type(key) == "number"
            and key >= 1
            and math.floor(key) == key then
            if key > maxIndex then
                maxIndex = key
            end
        else
            isArray = false
            if type(key) ~= "string" then
                fail("JSON object key is not a string")
            end
            keys[#keys + 1] = key
        end
    end

    if isArray and maxIndex ~= count then
        fail("JSON array is sparse")
    end

    if isArray then
        addPart(parts, state, "[")
        for index = 1, maxIndex do
            if value[index] == nil then
                fail("JSON array contains a null hole")
            end
            if index > 1 then
                addPart(parts, state, ",")
            end
            encodeValue(value[index], parts, state, depth + 1)
        end
        addPart(parts, state, "]")
    else
        for key, _ in pairs(value) do
            if type(key) == "number" then
                fail("JSON table mixes array and object keys")
            end
        end
        table.sort(keys)
        addPart(parts, state, "{")
        for index, key in ipairs(keys) do
            if index > 1 then
                addPart(parts, state, ",")
            end
            escapeString(key, parts, state)
            addPart(parts, state, ":")
            encodeValue(value[key], parts, state, depth + 1)
        end
        addPart(parts, state, "}")
    end

    state.seen[value] = nil
end

encodeValue = function(value, parts, state, depth)
    if depth > MAX_DEPTH then
        fail("JSON nesting is too deep")
    end
    local kind = type(value)
    if kind == "nil" then
        addPart(parts, state, "null")
    elseif kind == "string" then
        escapeString(value, parts, state)
    elseif kind == "boolean" then
        addPart(parts, state, value and "true" or "false")
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            fail("JSON number is not finite")
        end
        local encoded = string.format("%.17g", value)
        if string.find(encoded, "^[%+%-]?[%d%.eE]+$") == nil then
            fail("JSON number is invalid")
        end
        addPart(parts, state, encoded)
    elseif kind == "table" then
        encodeTable(value, parts, state, depth)
    else
        fail("JSON value has an unsupported Lua type")
    end
end

function JSON.encode(value, maxBytes)
    local state = {
        maxBytes = (type(maxBytes) == "number" and maxBytes > 0)
            and math.floor(maxBytes)
            or DEFAULT_MAX_BYTES,
        size = 0,
        nodes = 1,
        seen = {}
    }
    local parts = {}
    local ok, result = pcall(function()
        encodeValue(value, parts, state, 0)
        return table.concat(parts)
    end)
    if ok and type(result) == "string" and #result <= state.maxBytes then
        return result
    end
    return nil
end

local function utf8ForCodepoint(codepoint)
    if codepoint < 0 or codepoint > 1114111
        or (codepoint >= 55296 and codepoint <= 57343) then
        fail("JSON Unicode escape is invalid")
    end
    if codepoint <= 127 then
        return string.char(codepoint)
    elseif codepoint <= 2047 then
        return string.char(
            192 + math.floor(codepoint / 64),
            128 + (codepoint % 64)
        )
    elseif codepoint <= 65535 then
        return string.char(
            224 + math.floor(codepoint / 4096),
            128 + (math.floor(codepoint / 64) % 64),
            128 + (codepoint % 64)
        )
    end
    return string.char(
        240 + math.floor(codepoint / 262144),
        128 + (math.floor(codepoint / 4096) % 64),
        128 + (math.floor(codepoint / 64) % 64),
        128 + (codepoint % 64)
    )
end

local function decodeInternal(input, maxBytes)
    if type(input) ~= "string" or #input > maxBytes then
        fail("JSON input is invalid or too large")
    end

    local position = 1
    local length = #input
    local nodes = 0

    local function current()
        return string.sub(input, position, position)
    end

    local function skipWhitespace()
        while position <= length do
            local byte = string.byte(input, position)
            if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
                return
            end
            position = position + 1
        end
    end

    local function hexValue(byte)
        if byte >= 48 and byte <= 57 then
            return byte - 48
        elseif byte >= 65 and byte <= 70 then
            return byte - 55
        elseif byte >= 97 and byte <= 102 then
            return byte - 87
        end
        return nil
    end

    local function parseString()
        if current() ~= '"' then
            fail("JSON string expected")
        end
        position = position + 1
        local parts = {}
        local size = 0
        while position <= length do
            local byte = string.byte(input, position)
            if byte == 34 then
                position = position + 1
                local value = table.concat(parts)
                if #value > maxBytes then
                    fail("JSON string is too large")
                end
                return value
            end
            if byte < 32 then
                fail("JSON string contains a control character")
            end
            if byte == 92 then
                position = position + 1
                local escaped = string.sub(input, position, position)
                local replacement = {
                    ['"'] = '"',
                    ["\\"] = "\\",
                    ["/"] = "/",
                    b = "\b",
                    f = "\f",
                    n = "\n",
                    r = "\r",
                    t = "\t"
                }
                if replacement[escaped] ~= nil then
                    parts[#parts + 1] = replacement[escaped]
                    size = size + 1
                    position = position + 1
                elseif escaped == "u" then
                    local codepoint = 0
                    for _ = 1, 4 do
                        position = position + 1
                        local value = hexValue(string.byte(input, position))
                        if value == nil then
                            fail("JSON Unicode escape is invalid")
                        end
                        codepoint = codepoint * 16 + value
                    end
                    position = position + 1
                    local utf8 = utf8ForCodepoint(codepoint)
                    parts[#parts + 1] = utf8
                    size = size + #utf8
                else
                    fail("JSON escape is invalid")
                end
            else
                parts[#parts + 1] = string.char(byte)
                size = size + 1
                position = position + 1
            end
            if size > maxBytes then
                fail("JSON string is too large")
            end
        end
        fail("JSON string is unterminated")
    end

    local parseValue

    local function parseNumber()
        local start = position
        if current() == "-" then
            position = position + 1
        end
        if current() == "0" then
            position = position + 1
            if string.find(current(), "%d") ~= nil then
                fail("JSON number has a leading zero")
            end
        else
            if string.find(current(), "[1-9]") == nil then
                fail("JSON number is invalid")
            end
            while string.find(current(), "%d") ~= nil do
                position = position + 1
            end
        end
        if current() == "." then
            position = position + 1
            if string.find(current(), "%d") == nil then
                fail("JSON number fraction is invalid")
            end
            while string.find(current(), "%d") ~= nil do
                position = position + 1
            end
        end
        if current() == "e" or current() == "E" then
            position = position + 1
            if current() == "+" or current() == "-" then
                position = position + 1
            end
            if string.find(current(), "%d") == nil then
                fail("JSON number exponent is invalid")
            end
            while string.find(current(), "%d") ~= nil do
                position = position + 1
            end
        end
        local token = string.sub(input, start, position - 1)
        local number = tonumber(token)
        if number == nil or number ~= number
            or number == math.huge or number == -math.huge then
            fail("JSON number is invalid")
        end
        return number
    end

    local function parseArray(depth)
        if depth > MAX_DEPTH then
            fail("JSON nesting is too deep")
        end
        position = position + 1
        local result = {}
        skipWhitespace()
        if current() == "]" then
            position = position + 1
            return result
        end
        local index = 1
        while true do
            result[index] = parseValue(depth + 1)
            index = index + 1
            skipWhitespace()
            if current() == "]" then
                position = position + 1
                return result
            end
            if current() ~= "," then
                fail("JSON array separator is missing")
            end
            position = position + 1
            skipWhitespace()
        end
    end

    local function parseObject(depth)
        if depth > MAX_DEPTH then
            fail("JSON nesting is too deep")
        end
        position = position + 1
        local result = {}
        local keys = {}
        skipWhitespace()
        if current() == "}" then
            position = position + 1
            return result
        end
        while true do
            if current() ~= '"' then
                fail("JSON object key is missing")
            end
            local key = parseString()
            if keys[key] then
                fail("JSON object contains a duplicate key")
            end
            keys[key] = true
            skipWhitespace()
            if current() ~= ":" then
                fail("JSON object colon is missing")
            end
            position = position + 1
            skipWhitespace()
            result[key] = parseValue(depth + 1)
            skipWhitespace()
            if current() == "}" then
                position = position + 1
                return result
            end
            if current() ~= "," then
                fail("JSON object separator is missing")
            end
            position = position + 1
            skipWhitespace()
        end
    end

    parseValue = function(depth)
        nodes = nodes + 1
        if nodes > MAX_NODES then
            fail("JSON value contains too many nodes")
        end
        skipWhitespace()
        local character = current()
        if character == '"' then
            return parseString()
        elseif character == "{" then
            return parseObject(depth)
        elseif character == "[" then
            return parseArray(depth)
        elseif character == "-" or string.find(character, "%d") ~= nil then
            return parseNumber()
        elseif string.sub(input, position, position + 3) == "true" then
            position = position + 4
            return true
        elseif string.sub(input, position, position + 4) == "false" then
            position = position + 5
            return false
        elseif string.sub(input, position, position + 3) == "null" then
            position = position + 4
            return nil
        end
        fail("JSON value is invalid")
    end

    local result = parseValue(0)
    skipWhitespace()
    if position <= length then
        fail("JSON has trailing data")
    end
    return result
end

function JSON.decode(value, maxBytes)
    local limit = (type(maxBytes) == "number" and maxBytes > 0)
        and math.floor(maxBytes)
        or DEFAULT_MAX_BYTES
    local ok, result = pcall(decodeInternal, value, limit)
    if ok then
        return result
    end
    return nil
end

return JSON

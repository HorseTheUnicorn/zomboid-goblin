local Config = require("GoblinSurvivor/Config")
local EventLog = require("GoblinSurvivor/EventLog")

local ChatBridge = { started = false, lastAt = {} }

local function username(player)
    if player == nil or type(player.getUsername) ~= "function" then return nil end
    local ok, value = pcall(function() return player:getUsername() end)
    if not ok or type(value) ~= "string" or #value < 1 or #value > 96 then return nil end
    if string.find(value, "[^A-Za-z0-9_%-]", 1) ~= nil then return nil end
    return value
end

local function cleanText(value)
    if type(value) ~= "string" or #value < 1 or #value > 240 then return nil end
    value = string.gsub(value, "[%c]", " ")
    -- Keep exact map data out of the Qwen event context even if a player
    -- pastes a coordinate-like phrase into chat.
    value = string.gsub(value, "[xyzXYZ]%s*=%s*[-+]?%d+%.?%d*", "[redacted]")
    value = string.gsub(value, "(%-?%d+%.?%d*)%s*[,;]%s*(%-?%d+%.?%d*)%s*[,;]%s*(%-?%d+%.?%d*)", "[redacted]")
    return value
end

local function mentionsGoblin(value)
    local lower = string.lower(value)
    return string.find(lower, "goblin", 1, true) ~= nil
        or string.sub(lower, 1, 7) == "!goblin"
end

function ChatBridge.start()
    if ChatBridge.started then return end
    if Events == nil or Events.OnClientCommand == nil
        or type(Events.OnClientCommand.Add) ~= "function" then
        print("[GoblinSurvivor] ChatBridge unavailable: OnClientCommand is not exposed")
        return
    end
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module ~= "GoblinSurvivor" or command ~= "chat" or not Config.enabled then return end
        if type(args) ~= "table" then return end
        local speaker = username(player)
        local text = cleanText(args.text)
        if speaker == nil or text == nil or not mentionsGoblin(text) then return end
        local now = os.time()
        if ChatBridge.lastAt[speaker] ~= nil and now - ChatBridge.lastAt[speaker] < 2 then return end
        ChatBridge.lastAt[speaker] = now
        EventLog.emit("chat", { speaker = speaker, text = text })
    end)
    ChatBridge.started = true
end

return ChatBridge

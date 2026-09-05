local function localUsername()
    if type(getPlayer) ~= "function" then return nil end
    local ok, player = pcall(getPlayer)
    if not ok or player == nil or type(player.getUsername) ~= "function" then return nil end
    local okName, name = pcall(function() return player:getUsername() end)
    return okName and type(name) == "string" and name or nil
end

local function readMessage(message, method)
    if message == nil or type(message[method]) ~= "function" then return nil end
    local ok, value = pcall(message[method], message)
    return ok and type(value) == "string" and value or nil
end

local function onAddMessage(message, tabId)
    local speaker = readMessage(message, "getAuthor")
    local text = readMessage(message, "getText")
    local localName = localUsername()
    if speaker == nil or text == nil or localName == nil
        or string.lower(speaker) ~= string.lower(localName) then return end
    if #text < 1 or #text > 240 then return end
    local lower = string.lower(text)
    if string.sub(lower, 1, 4) == "/gss"
        or string.sub(lower, 1, 4) == "!gss" then
        if type(sendClientCommand) == "function" then
            pcall(sendClientCommand, "GoblinSurvivor", "gss", { text = text })
        end
        return
    end
    if string.find(lower, "goblin", 1, true) == nil
        and string.sub(lower, 1, 7) ~= "!goblin" then return end
    if type(sendClientCommand) ~= "function" then return end
    pcall(sendClientCommand, "GoblinSurvivor", "chat", {
        text = text,
        tab_id = type(tabId) == "number" and tabId or 0
    })
end

if Events and Events.OnAddMessage and type(Events.OnAddMessage.Add) == "function" then
    Events.OnAddMessage.Add(onAddMessage)
end

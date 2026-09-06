local function localUsername()
    if type(getPlayer) ~= "function" then return nil end
    local ok, player = pcall(getPlayer)
    if not ok or player == nil or type(player.getUsername) ~= "function" then return nil end
    local okName, name = pcall(function() return player:getUsername() end)
    return okName and type(name) == "string" and name or nil
end

local function isGssCommand(text)
    if type(text) ~= "string" or #text < 4 or #text > 240 then return false end
    local lower = string.lower(text)
    return string.sub(lower, 1, 4) == "/gss"
        and (#text == 4 or string.match(string.sub(text, 5, 5), "%s") ~= nil)
end

local function sendGssCommand(text)
    if type(sendClientCommand) ~= "function" then return false end
    local ok = pcall(sendClientCommand, "GoblinSurvivor", "gss", { text = text })
    return ok
end

-- Vanilla ISChat routes every slash-prefixed line through
-- SendCommandToServer before it becomes an OnAddMessage event. Intercept the
-- text-entry callback so /gss commands retain their in-game-chat origin and
-- reach the same server-side command validator as every other client command.
-- The server still adds source="in_game_chat"; this client hook cannot grant
-- that authority to bridge traffic or write survivor state directly.
local gssCommandHookInstalled = false
local function installGssCommandHook()
    if gssCommandHookInstalled then return true end
    if ISChat == nil or ISChat.instance == nil then return false end
    local textEntry = ISChat.instance.textEntry
    if textEntry == nil or type(textEntry.onCommandEntered) ~= "function" then
        return false
    end
    if textEntry.GoblinSurvivorGssCommandHook == true then
        gssCommandHookInstalled = true
        return true
    end
    local vanillaHandler = textEntry.onCommandEntered
    textEntry.onCommandEntered = function(...)
        local text = ISChat.instance.textEntry:getText()
        if isGssCommand(text) and sendGssCommand(text) then
            ISChat.instance:logChatCommand(text)
            ISChat.instance:unfocus()
            if type(doKeyPress) == "function" then doKeyPress(false) end
            ISChat.instance.timerTextEntry = 20
            return
        end
        return vanillaHandler(...)
    end
    textEntry.GoblinSurvivorGssCommandHook = true
    gssCommandHookInstalled = true
    return true
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
    if isGssCommand(text) or string.sub(lower, 1, 4) == "!gss" then
        sendGssCommand(text)
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

if Events and Events.OnGameStart and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(installGssCommandHook)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(installGssCommandHook)
end
installGssCommandHook()

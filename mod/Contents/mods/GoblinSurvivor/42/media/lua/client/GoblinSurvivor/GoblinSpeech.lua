-- Use the exposed ChatMessage API and vanilla chat UI, not ChatManager (which
-- Build 42 does not expose to Lua). This adds local NPC lines; it sends nothing
-- as the player and does not feed our reply back into the incoming-chat hook.
local Speech = { pending = {}, context = nil }

function Speech.observe(message, tabId)
    local ok, chat = pcall(function() return message:getChat() end)
    if ok and chat and type(tabId) == "number" then Speech.context = {chat=chat, tabId=tabId} end
end

local function context()
    if not ISChat or not ISChat.instance or not ISChat.instance.tabs then return nil end
    for _, tab in ipairs(ISChat.instance.tabs) do
        if Speech.context and tab.tabID == Speech.context.tabId then return Speech.context end
    end
    -- Handles unsolicited completion lines before the player sends any chat.
    for _, tab in ipairs(ISChat.instance.tabs) do
        local messages = tab.chatMessages or {}
        for i = #messages, 1, -1 do
            Speech.observe(messages[i], tab.tabID)
            if Speech.context then return Speech.context end
        end
    end
    return nil
end

function Speech.flush()
    if #Speech.pending == 0 then return true end
    local channel = context()
    if not channel or not ChatMessage then return false end
    local entry = Speech.pending[1]
    local ok = pcall(function()
        local message = ChatMessage.new(channel.chat, entry.text)
        message:setAuthor(entry.name)
        message:setShowInChat(true)
        message:setOverHeadSpeech(false)
        message:setShouldAttractZombies(false)
        message:setLocal(true)
        if not message:isShowAuthor() then message:setText(entry.name .. ": " .. entry.text) end
        ISChat.addLineInChat(message, channel.tabId)
    end)
    if ok then
        table.remove(Speech.pending, 1)
        print("[GoblinSurvivor] CHAT_LINE name=" .. entry.name .. " text=" .. entry.text)
    end
    return ok
end

function Speech.show(name, text)
    name = string.gsub(tostring(name or "Goblin"), "[<>%c]", "")
    text = string.gsub(tostring(text or ""), "[<>%c]", "")
    if #text == 0 then return false end
    Speech.pending[#Speech.pending + 1] = {name=name, text=text}
    if #Speech.pending > 32 then table.remove(Speech.pending, 1) end
    return Speech.flush()
end

return Speech

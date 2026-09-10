local Config = require("GoblinSurvivor/Config")
local EventLog = require("GoblinSurvivor/EventLog")
local Authority = require("GoblinSurvivor/Authority")
local EventHooks = require("GoblinSurvivor/EventHooks")
local Constants = require("GoblinSurvivor/Constants")
local Spawner = require("GoblinSurvivor/GoblinSpawner")

local ChatBridge = { started = false, lastAt = {} }

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

local function log(text)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(text)) end
end

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
    -- Keep exact map data out of Qwen context even if a player pastes it.
    value = string.gsub(value, "[xyzXYZ]%s*=%s*[-+]?%d+%.?%d*", "[redacted]")
    value = string.gsub(value, "(%-?%d+%.?%d*)%s*[,;]%s*(%-?%d+%.?%d*)%s*[,;]%s*(%-?%d+%.?%d*)", "[redacted]")
    return value
end

local function mentionsGoblin(value)
    local lower = string.lower(value)
    return string.find(lower, "goblin", 1, true) ~= nil
        or string.sub(lower, 1, 7) == "!goblin"
end

local function contains(lower, phrase)
    return string.find(lower, phrase, 1, true) ~= nil
end

-- Core commands should still work if Qwen or the host bridge is unavailable.
-- Qwen remains responsible for personality, conversation and ambiguous asks;
-- these obvious phrases are handled immediately by the game server.
local function directIntent(text)
    local lower = string.lower(text)
    if contains(lower, "follow me") or contains(lower, "come with me")
        or contains(lower, "come here") then
        return Constants.TASK.FOLLOW
    end
    if contains(lower, "stay here") or contains(lower, "wait here")
        or contains(lower, "hold position") or contains(lower, "stop here") then
        return Constants.TASK.WAIT
    end
    if contains(lower, "this is base") or contains(lower, "set base")
        or contains(lower, "make this base") or contains(lower, "home is here") then
        return Constants.TASK.SET_BASE
    end
    if contains(lower, "go home") or contains(lower, "go to base")
        or contains(lower, "return to base") or contains(lower, "take it home")
        or contains(lower, "bring it home") then
        return Constants.TASK.RETURN_TO_BASE
    end
    if contains(lower, "loot") or contains(lower, "scavenge")
        or contains(lower, "grab supplies") or contains(lower, "find supplies") then
        return Constants.TASK.LOOT
    end
    if contains(lower, "help me") or contains(lower, "defend me")
        or contains(lower, "fight") or contains(lower, "kill the zombies") then
        return Constants.TASK.ATTACK
    end
    return nil
end

local function applyDirect(player, speaker, task)
    if task == nil then return false, "none" end
    if task == Constants.TASK.SET_BASE then
        local ok, detail = Spawner.setBaseForPlayer(player)
        return ok == true, tostring(detail or "set base")
    end
    local body, detail = Spawner.ensureForPlayer(player, false)
    if body == nil then return false, tostring(detail or "Goblin unavailable") end
    local payload = { owner = speaker }
    local ok = Spawner.setTask(body, task, payload)
    return ok == true, ok and "task applied" or "task rejected"
end

function ChatBridge.start()
    if ChatBridge.started then return end
    if Events == nil or Events.OnClientCommand == nil then
        log("CHAT_BRIDGE unavailable: OnClientCommand is not exposed")
        return
    end

    local registered = EventHooks.install("server.chat_bridge", Events.OnClientCommand, function(module, command, player, args)
        if module ~= "GoblinSurvivor" or command ~= "chat" or not Config.enabled then return end
        if type(args) ~= "table" then return end
        local speaker = username(player)
        local text = cleanText(args.text)
        if speaker == nil or text == nil or not mentionsGoblin(text) then return end

        log("CHAT_RX speaker=" .. speaker .. " text=" .. text)

        local task = directIntent(text)
        local directApplied, directDetail = applyDirect(player, speaker, task)
        if task ~= nil then
            log("CHAT_DIRECT speaker=" .. speaker .. " task=" .. tostring(task)
                .. " applied=" .. tostring(directApplied)
                .. " detail=" .. tostring(directDetail))
        end

        -- Rate-limit only the external/Qwen event.  Deterministic direct
        -- commands above are never suppressed by this chatter throttle.
        local now = nowMs()
        local publishAllowed = true
        if now > 0 and ChatBridge.lastAt[speaker] ~= nil
            and now - ChatBridge.lastAt[speaker] < 2000 then
            publishAllowed = false
        end
        if not publishAllowed then return end
        ChatBridge.lastAt[speaker] = now

        local token = Authority.issue(player)
        local published = EventLog.emit("chat", {
            speaker = speaker,
            text = text,
            authorized = token ~= nil,
            authority_token = token,
            direct_action = task,
            direct_applied = directApplied
        })
        log("CHAT_EVENT speaker=" .. speaker .. " published=" .. tostring(published))
    end)
    if not registered then
        log("CHAT_BRIDGE hook registration failed")
        return
    end
    ChatBridge.started = true
    log("CHAT_BRIDGE ready")
end

return ChatBridge

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

local function mentionsGoblin(value, speaker)
    local lower = string.lower(value)
    local body = Spawner.findForOwner(speaker)
    local data = body and body:getModData()
    local name = data and data.GoblinName
    local first = type(name)=="string" and string.match(string.lower(name),"^%S+")
    if first and string.find(lower,first,1,true) then return true end
    return string.find(lower, "goblin", 1, true) ~= nil
        or string.sub(lower, 1, 7) == "!goblin"
end

local function contains(lower, phrase)
    return string.find(lower, phrase, 1, true) ~= nil
end

-- Core commands should still work if Qwen or the host bridge is unavailable.
-- Qwen remains responsible for personality, conversation and ambiguous asks;
-- these obvious phrases are handled immediately by the game server.
function ChatBridge.directIntent(text)
    local lower = string.lower(text)
    -- Don't turn questions about loot/building (or negated orders) into jobs.
    if contains(lower,"don't") or contains(lower,"do not") or contains(lower,"never ")
        or contains(lower," not ") then return nil end
    lower=string.gsub(lower,"^%s*goblin[%s,:!]*","")
    lower=string.gsub(lower,"^please%s+","")
    if string.match(lower,"^what%s") or string.match(lower,"^why%s") or string.match(lower,"^how%s")
        or string.match(lower,"^are%s") or string.match(lower,"^do%s") then return nil end
    if lower:match("%f[%a]disembark%f[%A]") or contains(lower,"get out of the car")
        or contains(lower,"get out of the vehicle") or contains(lower,"exit the vehicle")
        or contains(lower,"exit vehicle") or contains(lower,"get out of the truck")
        or lower:match("^get out[%p%s]*$") then return "EXIT_VEHICLE" end
    if lower:match("%f[%a]board%f[%A]") and not contains(lower,"board up")
        or contains(lower,"get in the car") or contains(lower,"get into the car")
        or contains(lower,"get in the vehicle") or contains(lower,"get into the vehicle")
        or contains(lower,"enter the vehicle") or contains(lower,"enter vehicle")
        or contains(lower,"get in the truck") or lower:match("^get in[%p%s]*$") then return "ENTER_VEHICLE" end
    -- Singular/plural and intervening words must still dispatch a real order.
    if (lower:match("%f[%a]kill%f[%A]") or lower:match("%f[%a]attack%f[%A]"))
        and (contains(lower,"zombie") or contains(lower,"zed")) then return Constants.TASK.ATTACK end
    local curtain=contains(lower,"curtain") or lower:match("%f[%a]blinds%f[%A]")
    if curtain and (lower:match("%f[%a]close%f[%A]") or lower:match("%f[%a]shut%f[%A]")
        or lower:match("%f[%a]draw%f[%A]")) then return Constants.TASK.CLOSE_CURTAINS end
    if not curtain and string.match(lower,"%f[%a]open%f[%A]") then
        if string.match(lower,"%f[%a]window%f[%A]") or contains(lower,"windows") then return Constants.TASK.OPEN_WINDOW end
        if string.match(lower,"%f[%a]door%f[%A]") or contains(lower,"doors") then return Constants.TASK.OPEN_DOOR end
    end
    if string.match(lower,"%f[%a]craft%f[%A]") or contains(lower,"saw logs") or contains(lower,"make planks") then
        return Constants.TASK.CRAFT
    end
    if string.match(lower,"%f[%a]repair%f[%A]") or string.match(lower,"%f[%a]fix%f[%A]") then
        if contains(lower,"car") or contains(lower,"vehicle") or contains(lower,"engine")
            or contains(lower,"truck") or contains(lower,"bodywork") then return Constants.TASK.REPAIR_VEHICLE end
    end
    if string.match(lower,"%f[%a]sow%f[%A]") or string.match(lower,"%f[%a]plant%f[%A]")
        or contains(lower,"plow") or contains(lower,"plough") or contains(lower,"dig a furrow")
        or string.match(lower,"%f[%a]harvest%f[%A]") or contains(lower,"tend the farm") or contains(lower,"tend the crops")
        or contains(lower,"water the crops") or contains(lower,"water the plants") or contains(lower,"water crops") then
        return Constants.TASK.FARM
    end
    if contains(lower, "follow me") or contains(lower, "come with me")
        or contains(lower, "come here") then
        return Constants.TASK.FOLLOW
    end
    if contains(lower, "stay here") or contains(lower, "wait here")
        or contains(lower, "hold position") or contains(lower, "stop here") then
        return Constants.TASK.WAIT
    end
    if contains(lower, "this is base") or contains(lower, "set base")
        or contains(lower, "this is our base")
        or contains(lower, "make this base") or contains(lower, "home is here") then
        return Constants.TASK.SET_BASE
    end
    if contains(lower, "secure the base") or contains(lower,"secure our base") or contains(lower,"secure base")
        or contains(lower, "fortify") or contains(lower, "board up") or contains(lower, "barricade") then return Constants.TASK.FORTIFY end
    if contains(lower, "build") then return Constants.TASK.BUILD end
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

local function applyDirect(player, speaker, task, text)
    if task == nil then return false, "none" end
    if task == Constants.TASK.SET_BASE then
        local ok, detail = Spawner.setBaseForPlayer(player)
        local body=Spawner.findForOwner(speaker)
        local reported=body and require("GoblinSurvivor/GoblinBody").say(body,"Comrade, "..tostring(detail)..".")
        return ok == true, tostring(detail or "set base"),reported==true
    end
    local body, detail = Spawner.ensureForPlayer(player, false)
    if body == nil then return false, tostring(detail or "Goblin unavailable") end
    local payload = { owner = speaker }
    local lower=string.lower(text or "")
    if task==Constants.TASK.CRAFT or task==Constants.TASK.FARM or task==Constants.TASK.REPAIR_VEHICLE then
        payload=ChatBridge.jobPayload(task,text)
    end
    if task == Constants.TASK.BUILD then
        payload.kind=contains(lower,"crate") and "crate" or contains(lower,"wall") and "wall" or contains(lower,"fence") and "fence" or nil
        payload.north=contains(lower,"north")
    end
    if task == Constants.TASK.LOOT then
        for _,focus in ipairs({"food","medical","tools","ammo"}) do if contains(lower,focus) then payload.loot_focus=focus end end
    end
    local ok,result = require("GoblinSurvivor/GoblinBrain").setTask(body, task, payload)
    -- A real server result, including refusal, is always visible immediately.
    local reported=require("GoblinSurvivor/GoblinBody").say(body,"Comrade, "..tostring(result)..".")
    return ok == true, result,reported==true
end

function ChatBridge.jobPayload(task,text)
    local lower=string.lower(text or "")
    if task==Constants.TASK.FARM then
        local job="tend"
        if lower:find("plow",1,true) or lower:find("plough",1,true) or lower:find("furrow",1,true) then job="plow"
        elseif lower:find("harvest",1,true) then job="harvest"
        elseif lower:find("water",1,true) then job="water"
        elseif lower:find("sow",1,true) or lower:find("plant",1,true) then job="sow" end
        local crop=lower:match("%f[%a]sow%s+(.+)") or lower:match("%f[%a]plant%s+(.+)")
        if crop then crop=crop:gsub("%s+seeds.*$",""):gsub("%s+please.*$",""):gsub("[%p]$","") end
        return {job=job,item=crop and {name=crop} or nil}
    end
    if task==Constants.TASK.REPAIR_VEHICLE then
        return {job=lower:find("engine",1,true) and "engine" or lower:find("bodywork",1,true) and "bodywork" or "all"}
    end
    local recipe=text:match("[Cc][Rr][Aa][Ff][Tt]%s+(.+)")
    if lower:find("saw logs",1,true) or lower:find("make planks",1,true) then recipe="SawLogs" end
    local count,name
    if recipe then count,name=recipe:match("^(%d+)%s+(.+)") end
    if name then recipe=name end
    if recipe then recipe=recipe:gsub("%s+please.*$",""):gsub("[%p]$","") end
    return {item={name=recipe,count=tonumber(count) or 1}}
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
        if speaker == nil or text == nil or not mentionsGoblin(text,speaker) then return end

        log("CHAT_RX speaker=" .. speaker .. " text=" .. text)

        local task = ChatBridge.directIntent(text)
        local directApplied, directDetail, directReported = applyDirect(player, speaker, task, text)
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
            direct_applied = directApplied,
            direct_detail = task and tostring(directDetail) or nil,
            direct_reported = directReported==true,
            addressed = true
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

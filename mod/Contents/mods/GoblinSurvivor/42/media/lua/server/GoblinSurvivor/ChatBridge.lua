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
    if (lower:match("^start%s+") or lower:match("^turn on%s+"))
        and (contains(lower,"car") or contains(lower,"vehicle") or contains(lower,"engine")
            or contains(lower,"truck")) then return Constants.TASK.START_VEHICLE end
    if lower:match("^unlock%s+")
        and (contains(lower,"car") or contains(lower,"vehicle") or contains(lower,"truck")) then
        return Constants.TASK.UNLOCK_VEHICLE
    end
    if lower:match("^chop%f[%A]") or lower:match("^cut%s+down%s+") or contains(lower,"fell a tree")
        or contains(lower,"fell the tree") then
        return Constants.TASK.CHOP_WOOD
    end
    if lower:match("^forage%f[%A]") or lower:match("^go%s+foraging") or lower:match("^gather%s+berries")
        or lower:match("^look%s+for%s+food%s+outside") then
        return Constants.TASK.FORAGE
    end
    if (lower:match("^check%f[%A]") or lower:match("^empty%f[%A]") or lower:match("^rebait%f[%A]")
        or lower:match("^bait%f[%A]") or lower:match("^set%f[%A]") or lower:match("^place%f[%A]")
        or lower:match("^put%s+down%f[%A]") or lower:match("^lay%f[%A]")) and contains(lower,"trap") then
        return Constants.TASK.CHECK_TRAPS
    end
    if contains(lower,"generator") or lower:match("^restore%s+power") or lower:match("^fix%s+.*power")
        or lower:match("^get%s+.*power") or lower:match("^turn%s+on%s+.*power") or contains(lower,"electricity") then
        return Constants.TASK.RESTORE_POWER
    end
    if lower:match("^cook%f[%A]") or lower:match("^make%s+dinner") or lower:match("^make%s+food")
        or lower:match("^make%s+.*soup") or lower:match("^make%s+.*stew") then
        return Constants.TASK.COOK
    end
    if lower:match("^bandage%s+me") or lower:match("^patch%s+me%s+up") or lower:match("^heal%s+me")
        or lower:match("^treat%s+my%s+wound") or contains(lower,"i'm bleeding") or contains(lower,"im bleeding") then
        return Constants.TASK.TREAT_PLAYER
    end
    local vehicleWord=contains(lower,"car") or contains(lower,"vehicle") or contains(lower,"truck")
        or lower:match("%f[%a]van%f[%A]") ~= nil
    if vehicleWord and (lower:match("^refuel%f[%A]") or lower:match("^fill%s+up") or lower:match("^gas%s+up")
        or lower:match("^fuel%s+up")) then
        return Constants.TASK.REFUEL_VEHICLE
    end
    if (vehicleWord or contains(lower,"battery")) and (lower:match("^service%f[%A]") or lower:match("^tune%s+up")
        or lower:match("^charge%f[%A]") or lower:match("^recharge%f[%A]")) then
        return Constants.TASK.VEHICLE_SERVICE
    end
    if vehicleWord and (lower:match("^inspect%f[%A]") or lower:match("^check%f[%A]")
        or lower:match("^look%s+over")) then
        return Constants.TASK.VEHICLE_INSPECT
    end
    if (lower:match("^change%s+") or lower:match("^replace%s+") or lower:match("^swap%s+"))
        and (contains(lower,"tire") or contains(lower,"tyre") or contains(lower,"flat")) then
        return Constants.TASK.CHANGE_TIRE
    end
    if (lower:match("^replace%s+") or lower:match("^swap%s+")) and contains(lower,"battery") then
        return Constants.TASK.REPLACE_PART
    end
    -- Singular/plural and intervening words must still dispatch a real order.
    if (lower:match("%f[%a]kill%f[%A]") or lower:match("%f[%a]attack%f[%A]"))
        and (contains(lower,"zombie") or contains(lower,"zed")) then return Constants.TASK.ATTACK end
    local curtain=contains(lower,"curtain") or lower:match("%f[%a]blinds%f[%A]")
    if curtain and (lower:match("%f[%a]close%f[%A]") or lower:match("%f[%a]shut%f[%A]")
        or lower:match("%f[%a]draw%f[%A]")) then return Constants.TASK.CLOSE_CURTAINS end
    if (contains(lower,"inspect") or contains(lower,"survey") or contains(lower,"check"))
        and (contains(lower,"base") or contains(lower,"house")) then
        return Constants.TASK.INSPECT_BASE
    end
    if (contains(lower,"maintain") or contains(lower,"maintenance"))
        and (contains(lower,"base") or contains(lower,"house")) then
        return Constants.TASK.MAINTAIN_BASE
    end
    if lower:match("^dismantle%s+[^%p]*furniture[%p%s]*$")
        or lower:match("^take%s+apart%s+[^%p]*furniture[%p%s]*$") then
        return Constants.TASK.DISMANTLE
    end
    if not curtain and string.match(lower,"%f[%a]open%f[%A]") then
        if string.match(lower,"%f[%a]window%f[%A]") or contains(lower,"windows") then return Constants.TASK.OPEN_WINDOW end
        if string.match(lower,"%f[%a]door%f[%A]") or contains(lower,"doors") then return Constants.TASK.OPEN_DOOR end
    end
    if lower:match("^access%s+") or contains(lower,"gain access")
        or contains(lower,"get into the building")
        or contains(lower,"get inside the building") then
        return "GAIN_ACCESS"
    end
    if string.match(lower,"%f[%a]craft%f[%A]") or contains(lower,"saw logs") or contains(lower,"make planks") then
        return Constants.TASK.CRAFT
    end
    if string.match(lower,"%f[%a]repair%f[%A]") or string.match(lower,"%f[%a]fix%f[%A]") then
        if contains(lower,"car") or contains(lower,"vehicle") or contains(lower,"engine")
            or contains(lower,"truck") or contains(lower,"bodywork") then return Constants.TASK.REPAIR_VEHICLE end
        if contains(lower,"base") or contains(lower,"house") or contains(lower,"wall")
            or contains(lower,"door") or contains(lower,"furniture") or contains(lower,"structure") then
            return Constants.TASK.REPAIR_STRUCTURE
        end
    end
    if (lower:match("^sort%f[%A]") or lower:match("^organi[sz]e%f[%A]") or contains(lower,"tidy up"))
        and (contains(lower,"storage") or contains(lower,"stuff") or contains(lower,"base")
            or contains(lower,"inbox") or contains(lower,"supplies") or contains(lower,"items")
            or lower:match("^sort[%p%s]*$") or lower:match("^sort%s+everything")) then
        return Constants.TASK.SORT_STORAGE
    end
    if lower:match("^bring%s+me%s+") or lower:match("^fetch%s+") or lower:match("^get%s+me%s+") then
        return Constants.TASK.FETCH_ITEM
    end
    if lower:match("^put%s+away") or lower:match("^put%s+your%s+stuff%s+away")
        or lower:match("^unload%f[%A]") or lower:match("^stash%s+") then
        return Constants.TASK.DELIVER
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
    if contains(lower,"fortify the base") or contains(lower,"fortify base") then
        return Constants.TASK.FORTIFY_BASE
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
    local payload = { owner = speaker, manual = task == Constants.TASK.FOLLOW }
    if task == Constants.TASK.DISMANTLE then payload.explicit_owner_order = true end
    if task == Constants.TASK.SORT_STORAGE or task == Constants.TASK.FETCH_ITEM
        or task == Constants.TASK.DELIVER or task == Constants.TASK.REPAIR_STRUCTURE then
        payload = ChatBridge.logisticsPayload(task, text)
    end
    if task == Constants.TASK.RESTORE_POWER then payload = { explicit_owner_order = true } end
    if task == Constants.TASK.CHOP_WOOD or task == Constants.TASK.TREAT_PLAYER then
        payload = { explicit_owner_order = true }
        local count = string.match(string.lower(text or ""), "(%d+)%s+trees?")
        if count then payload.count = math.max(1, math.min(5, tonumber(count))) end
    end
    if task == Constants.TASK.FORAGE or task == Constants.TASK.CHECK_TRAPS or task == Constants.TASK.COOK then
        payload = { explicit_owner_order = true }
        local count = tonumber(string.match(string.lower(text or ""), "(%d+)"))
        if count and task == Constants.TASK.FORAGE then payload.count = math.max(1, math.min(10, count)) end
        local lowered = string.lower(text or "")
        if task == Constants.TASK.COOK then
            if lowered:find("soup", 1, true) then payload.dish = "soup"
            elseif lowered:find("stew", 1, true) then payload.dish = "stew" end
            if count then payload.count = math.max(1, math.min(payload.dish and 6 or 5, count)) end
        end
        if task == Constants.TASK.CHECK_TRAPS and (lowered:match("^set%f[%A]") or lowered:match("^place%f[%A]")
            or lowered:match("^put%s+down%f[%A]") or lowered:match("^lay%f[%A]")) then
            payload.place = count and math.max(1, math.min(5, count)) or 2
        end
    end
    if task == Constants.TASK.REFUEL_VEHICLE or task == Constants.TASK.VEHICLE_SERVICE
        or task == Constants.TASK.VEHICLE_INSPECT or task == Constants.TASK.CHANGE_TIRE
        or task == Constants.TASK.REPLACE_PART then
        payload = { explicit_owner_order = true }
        if task == Constants.TASK.REPLACE_PART then payload.part = "Battery" end
        local lower = string.lower(text or "")
        for _, id in ipairs({ {"front left","TireFrontLeft"}, {"front right","TireFrontRight"},
            {"rear left","TireRearLeft"}, {"rear right","TireRearRight"},
            {"back left","TireRearLeft"}, {"back right","TireRearRight"} }) do
            if task == Constants.TASK.CHANGE_TIRE and contains(lower, id[1]) then payload.part = id[2] end
        end
    end
    local lower=string.lower(text or "")
    if task==Constants.TASK.CRAFT or task==Constants.TASK.FARM or task==Constants.TASK.REPAIR_VEHICLE then
        payload=ChatBridge.jobPayload(task,text)
    end
    if task=="GAIN_ACCESS" then
        payload=ChatBridge.accessPayload(text)
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

-- Natural-language logistics orders from the authenticated owner. The item or
-- category named here is still validated by the capability's prepare step.
function ChatBridge.logisticsPayload(task,text)
    local lower=string.lower(text or "")
    lower=string.gsub(lower,"^%s*goblin[%s,:!]*","")
    lower=string.gsub(lower,"^please%s+","")
    local payload={explicit_owner_order=true}
    if task==Constants.TASK.SORT_STORAGE then
        payload.all=contains(lower,"everything") or contains(lower," all") or contains(lower,"floor")
        return payload
    end
    if task==Constants.TASK.FETCH_ITEM then
        local rest=lower:match("^bring%s+me%s+(.+)") or lower:match("^fetch%s+(.+)") or lower:match("^get%s+me%s+(.+)") or ""
        rest=rest:gsub("%s+please.*$",""):gsub("[%p]+$","")
        local count,name=rest:match("^(%d+)%s+(.+)$")
        if not count then
            local words={some=3,a=1,an=1,one=1,two=2,three=3,four=4,five=5}
            local word,remainder=rest:match("^(%a+)%s+(.+)$")
            if word and words[word] then count,name=words[word],remainder end
        end
        name=name or rest
        name=name:gsub("^the%s+",""):gsub("^my%s+",""):gsub("^some%s+","")
        -- Preserve an exact Module.Type full name as typed.
        local exact=(text or ""):match("([%a%d_]+%.[%a%d_]+)")
        payload.item=exact or name:match("^(%S+)")
        payload.count=math.max(1,math.min(20,tonumber(count) or 1))
        return payload
    end
    if task==Constants.TASK.DELIVER then
        payload.allow_floor=contains(lower,"floor")
        local exact=(text or ""):match("([%a%d_]+%.[%a%d_]+)")
        if exact then payload.item=exact end
        return payload
    end
    return payload
end

function ChatBridge.accessPayload(text)
    local lower=string.lower(text or "")
    local kind=(contains(lower,"vehicle") or contains(lower,"car") or contains(lower,"truck")) and "VEHICLE"
        or contains(lower,"yard") and "YARD" or contains(lower,"room") and "ROOM"
        or contains(lower,"container") and "CONTAINER" or "BUILDING"
    -- Natural chat can select a semantic destination, but only the explicit
    -- authenticated debug command may authorize destructive breach work.
    return {target={kind=kind},allow_breach=false}
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

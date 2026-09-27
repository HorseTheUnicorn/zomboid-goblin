-- In-game command surface for each player's own Goblin.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
local Stockpiles = require("GoblinSurvivor/GoblinStockpiles")
local Storage = require("GoblinSurvivor/GoblinStorage")
local Goals = require("GoblinSurvivor/GoblinGoals")
local Brain = require("GoblinSurvivor/GoblinBrain")
local EventHooks = require("GoblinSurvivor/EventHooks")

local Commands = { started = false, lastAt = {} }

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, first = pcall(member, object, ...)
    return ok, first
end

local function playerName(player)
    local ok, name = call(player, "getUsername")
    return ok and type(name) == "string" and name or "?"
end

local function reply(player, text)
    local message = "[Goblin] " .. tostring(text)
    local ok = call(player, "Say", message)
    if not ok then call(player, "addLineChatElement", message) end
end

local function tokens(text)
    local result = {}
    for token in string.gmatch(text or "", "%S+") do result[#result + 1] = token end
    return result
end

local function ownBody(player, spawn)
    if spawn then return Spawner.ensureForPlayer(player, true) end
    local body = Spawner.findForPlayer(player)
    if body ~= nil then return body, "present" end
    return Spawner.ensureForPlayer(player, false)
end

local function usage(player)
    reply(player, "follow | wait | enter/exit/start/unlock vehicle | open door/window | access [building/room/yard/vehicle] | breach [building/room/yard] | close curtains | inspect/maintain base | track Item.FullType minimum | stockpile Base.Nails | storage CATEGORY/clear | sort [all] | fetch Item/category [count] | deliver [item/category] [floor] | repair base | vehicle inspect/service/refuel | install/remove/replace Part [Item] | change tire [Part] | chop [1-5] | bandage me | goal secure/organize/repair/vehicle/nails [every N] | goal list | cancel [goal] | dismantle furniture | loot | base [clear] | home | fortify | build crate/wall/fence | farm plow/sow/water/harvest/tend [crop] | craft recipe [1-10] | repair all/engine/bodywork | attack | state")
end

local function handle(player, rawText)
    local parts = tokens(rawText)
    if string.lower(parts[1] or "") == "/goblin" or string.lower(parts[1] or "") == "!goblin" then
        table.remove(parts, 1)
    end
    if string.lower(parts[1] or "") == "debug" then table.remove(parts, 1) end
    local command = string.lower(parts[1] or "")
    if command == "" then usage(player); return end

    if command == "spawn" then
        local body, detail = ownBody(player, true)
        reply(player, body ~= nil and "Your Goblin is present." or detail)
        return
    end
    if command == "base" or command == "setbase" or command == "homebase" then
        local clear = string.lower(parts[2] or "") == "clear"
        local ok, detail = Spawner.setBaseForPlayer(player, clear)
        local body = Spawner.findForPlayer(player)
        if ok and body ~= nil then Body.say(body, clear and "Deliveries at your boots, comrade." or "Base recorded, comrade. Try not to bourgeois it up.") end
        reply(player, detail)
        return
    end

    local body, detail = ownBody(player, false)
    if body == nil then reply(player, detail or "Your Goblin is not present."); return end
    if command=="track" then
        if not parts[2] or not parts[3] or parts[4] then
            reply(player,"use track Item.FullType minimum beside one container in your saved base")
            return
        end
        local ok,result=Stockpiles.assign(body,player,parts[2],parts[3])
        if type(print)=="function" then
            print("[GoblinSurvivor] STOCKPILE_RULE owner="..playerName(player)
                .." item="..tostring(parts[2]).." accepted="..tostring(ok)
                .." detail="..tostring(result))
        end
        reply(player,result)
        return
    end
    if command=="stockpile" then
        if not parts[2] or parts[3] then
            reply(player,"use stockpile Base.Nails after tracking it beside a base container")
            return
        end
        local ok,result=Brain.setTask(body,Constants.TASK.STOCKPILE,
            {item=parts[2],explicit_owner_order=true})
        if type(print)=="function" then
            print("[GoblinSurvivor] STOCKPILE_ORDER owner="..playerName(player)
                .." item="..tostring(parts[2]).." accepted="..tostring(ok)
                .." detail="..tostring(result))
        end
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="storage" then
        local arg=parts[2]
        if not arg or parts[3] then
            reply(player,"use storage FOOD|WATER|MEDICAL|TOOLS|WEAPONS|AMMO|MATERIALS|CLOTHING|BOOKS|ELECTRONICS|FARMING|COOKING|SURVIVAL|VEHICLE|MISC|INBOX|OVERFLOW, or storage clear, beside one base container")
            return
        end
        local ok,result
        if string.lower(arg)=="clear" then ok,result=Storage.unassign(body,player)
        else ok,result=Storage.assign(body,player,arg) end
        if type(print)=="function" then
            print("[GoblinSurvivor] STORAGE_ASSIGN owner="..playerName(player)
                .." category="..tostring(arg).." accepted="..tostring(ok).." detail="..tostring(result))
        end
        reply(player,result)
        return
    end
    if command=="sort" or command=="organize" or command=="organise" then
        local all=string.lower(parts[2] or "")=="all"
        local ok,result=Brain.setTask(body,Constants.TASK.SORT_STORAGE,{explicit_owner_order=true,all=all})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="fetch" or command=="bring" then
        local item=parts[2]
        if not item or (parts[3] and not tonumber(parts[3])) or parts[4] then
            reply(player,"use fetch Base.Nails 5, or fetch food 3")
            return
        end
        local ok,result=Brain.setTask(body,Constants.TASK.FETCH_ITEM,
            {explicit_owner_order=true,item=item,count=tonumber(parts[3]) or 1})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="deliver" or command=="unload" or command=="putaway" then
        local item,floor
        for index=2,#parts do
            if string.lower(parts[index])=="floor" then floor=true else item=item or parts[index] end
        end
        local ok,result=Brain.setTask(body,Constants.TASK.DELIVER,
            {explicit_owner_order=true,item=item,allow_floor=floor==true})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="goal" or command=="goals" then
        local arg=string.lower(parts[2] or "list")
        local now=type(getTimestampMs)=="function" and getTimestampMs() or 0
        if arg=="list" then reply(player,Goals.describe(playerName(player)));return end
        if arg=="cancel" then
            local ok,result=Goals.cancel(playerName(player),parts[3] or "all")
            reply(player,result);return
        end
        local interval=0
        if string.lower(parts[3] or "")=="every" then interval=tonumber(parts[4]) or -1 end
        local ok,result=Goals.add(playerName(player),arg,interval,now)
        reply(player,result)
        return
    end
    if command=="cancel" then
        -- Cancels standing goals only; "follow" stops the current job.
        local ok,result=Goals.cancel(playerName(player),parts[2] or "all")
        reply(player,result)
        return
    end
    if command=="chop" then
        local count=tonumber(parts[2]) or tonumber(parts[3]) or 1
        local ok,result=Brain.setTask(body,Constants.TASK.CHOP_WOOD,{explicit_owner_order=true,count=count})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="bandage" or command=="treat" or command=="medical" or command=="heal" then
        local ok,result=Brain.setTask(body,Constants.TASK.TREAT_PLAYER,{explicit_owner_order=true})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="vehicle" or command=="car" then
        local what=string.lower(parts[2] or "")
        local tasks={inspect=Constants.TASK.VEHICLE_INSPECT,check=Constants.TASK.VEHICLE_INSPECT,
            service=Constants.TASK.VEHICLE_SERVICE,refuel=Constants.TASK.REFUEL_VEHICLE,
            fuel=Constants.TASK.REFUEL_VEHICLE}
        if not tasks[what] or parts[3] then reply(player,"use vehicle inspect, vehicle service, or vehicle refuel");return end
        local ok,result=Brain.setTask(body,tasks[what],{explicit_owner_order=true})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="install" or command=="remove" or command=="replace" then
        local partId=parts[2]
        if not partId or parts[4] then reply(player,"use "..command.." PartId [Item.FullType], e.g. "..command.." Battery");return end
        local task=command=="install" and Constants.TASK.INSTALL_PART
            or command=="remove" and Constants.TASK.REMOVE_PART or Constants.TASK.REPLACE_PART
        local ok,result=Brain.setTask(body,task,{explicit_owner_order=true,part=partId,item=parts[3]})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if (command=="change" and string.lower(parts[2] or "")=="tire") or command=="tire" then
        local partId=command=="tire" and parts[2] or parts[3]
        local ok,result=Brain.setTask(body,Constants.TASK.CHANGE_TIRE,{explicit_owner_order=true,part=partId})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="repair" then
        local what=string.lower(parts[2] or "")
        if what=="base" or what=="house" or what=="structure" or what=="structures"
            or what=="walls" or what=="furniture" or what=="doors" then
            local ok,result=Brain.setTask(body,Constants.TASK.REPAIR_STRUCTURE,{explicit_owner_order=true})
            Body.say(body,"Comrade, "..tostring(result)..".")
            return
        end
    end
    if command=="enter" or command=="board" or command=="exit" or command=="disembark" then
        local entering=command=="enter" or command=="board"
        local ok,result=Brain.setTask(body,entering and "ENTER_VEHICLE" or "EXIT_VEHICLE",{})
        Body.say(body,"Comrade, "..tostring(result)..".");return
    end
    if command=="start" or command=="ignition" then
        local target=string.lower(parts[2] or "vehicle")
        if target~="vehicle" and target~="car" and target~="engine" then
            reply(player,"use start vehicle");return
        end
        local ok,result=Brain.setTask(body,Constants.TASK.START_VEHICLE,{})
        Body.say(body,"Comrade, "..tostring(result)..".");return
    end
    if command=="unlock" then
        local target=string.lower(parts[2] or "vehicle")
        if target~="vehicle" and target~="car" and target~="truck" then
            reply(player,"use unlock vehicle");return
        end
        local ok,result=Brain.setTask(body,Constants.TASK.UNLOCK_VEHICLE,{})
        Body.say(body,"Comrade, "..tostring(result)..".");return
    end
    if command=="close" then
        local kind=string.lower(parts[2] or "")
        if kind~="curtain" and kind~="curtains" and kind~="blinds" then reply(player,"use close curtains");return end
        local ok,result=Brain.setTask(body,Constants.TASK.CLOSE_CURTAINS,{})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="inspect" and string.lower(parts[2] or "") == "base" then
        local ok,result=Brain.setTask(body,Constants.TASK.INSPECT_BASE,{})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="maintain" and (parts[2] == nil or string.lower(parts[2]) == "base") then
        local ok,result=Brain.setTask(body,Constants.TASK.MAINTAIN_BASE,{})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="dismantle" then
        if string.lower(parts[2] or "") ~= "furniture" or parts[3] ~= nil then
            reply(player,"use dismantle furniture while standing beside one empty wooden object in your saved base")
            return
        end
        local ok,result=Brain.setTask(body,Constants.TASK.DISMANTLE,{explicit_owner_order=true})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="open" then
        local kind=string.lower(parts[2] or "door")
        if kind~="door" and kind~="window" then reply(player,"use open door or open window");return end
        local ok,result=Brain.setTask(body,kind=="window" and Constants.TASK.OPEN_WINDOW or Constants.TASK.OPEN_DOOR,{})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="access" or command=="breach" then
        local kind=string.upper(parts[2] or "BUILDING")
        local allowed={BUILDING=true,ROOM=true,YARD=true,VEHICLE=true,CONTAINER=true}
        if not allowed[kind] then reply(player,"use access building, room, yard, vehicle, or container");return end
        if command=="breach" and (kind=="VEHICLE" or kind=="CONTAINER") then
            reply(player,"vehicle/container breach is blocked; use a matching key or empty the container")
            return
        end
        local ok,result=Brain.setTask(body,"GAIN_ACCESS",{
            target={kind=kind},allow_breach=command=="breach"})
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command=="farm" or command=="craft" or command=="repair" then
        local task=command=="farm" and "FARM" or command=="craft" and "CRAFT" or "REPAIR_VEHICLE"
        local payload
        if task=="FARM" then payload={job=parts[2] or "tend",item=parts[3] and {name=parts[3]} or nil}
        elseif task=="CRAFT" then payload={item={name=parts[2],count=tonumber(parts[3]) or 1}}
        else payload={job=parts[2] or "all"} end
        local ok,result=Brain.setTask(body,task,payload)
        Body.say(body,"Comrade, "..tostring(result)..".")
        return
    end
    if command == "fortify" or command == "barricade" then
        local task = command == "fortify" and string.lower(parts[2] or "") == "base"
            and Constants.TASK.FORTIFY_BASE or Constants.TASK.FORTIFY
        local ok,result = Brain.setTask(body, task, {})
        Body.say(body,result)
        return
    end
    if command == "build" then
        local ok,result = Brain.setTask(body, Constants.TASK.BUILD, {kind=parts[2],north=parts[3]=="north"})
        Body.say(body,result)
        return
    end

    if command == "follow" or command == "come" or command == "regroup" then
        local ok, result = Brain.setTask(body, Constants.TASK.FOLLOW,
            { owner = playerName(player), manual = true })
        reply(player, ok and "Following you." or result)
        return
    end
    if command == "wait" or command == "stay" or command == "hold" then
        local ok, result = Brain.setTask(body, Constants.TASK.WAIT, {})
        reply(player, ok and "Holding here." or result)
        return
    end
    if command == "loot" or command == "scavenge" or command == "search" then
        local focus = string.lower(parts[2] or "surprise")
        local allowed = { food = true, medical = true, tools = true, ammo = true, surprise = true }
        if not allowed[focus] then reply(player, "loot focus must be food, medical, tools, ammo, or surprise"); return end
        local ok, result = Brain.setTask(body, Constants.TASK.LOOT, { loot_focus = focus })
        if ok then Body.say(body, "I shall seize useful property, comrade. Delivery to your base, or your boots if you have none.") end
        reply(player, ok and "Loot run started." or result)
        return
    end
    if command == "home" or command == "return" or command == "returntobase" then
        local ok, result = Brain.setTask(body, Constants.TASK.RETURN_TO_BASE, {})
        reply(player, ok and "Returning with supplies." or result)
        return
    end
    if command == "attack" or command == "defend" or command == "help" then
        local ok, result = Brain.setTask(body, Constants.TASK.ATTACK, {})
        reply(player, ok and "Engaging nearby zombies." or result)
        return
    end
    if command == "equip" then
        local ok, result = Brain.setTask(body, Constants.TASK.EQUIP,
            { item = { name = Config.weaponType, count = 1 } })
        reply(player, result)
        return
    end
    if command == "state" or command == "status" then
        local snapshot = Spawner.snapshotForOwner(playerName(player))
        reply(player, "id=" .. tostring(snapshot.npc_id)
            .. " task=" .. tostring(snapshot.task)
            .. " move=" .. tostring(snapshot.move_type)
            .. " base=" .. tostring(snapshot.base_set)
            .. " model=" .. tostring(snapshot.visual_asset_applied)
            .. " loot=" .. tostring(snapshot.loot_status))
        return
    end
    if command == "despawn" and Config.isAuthorizedPlayer(player) then
        Spawner.removeForPlayer(player)
        reply(player, "Your Goblin was despawned; its persistent record remains.")
        return
    end

    usage(player)
end

function Commands.start()
    if Commands.started then return true end
    if Events == nil or Events.OnClientCommand == nil then return false end
    local registered = EventHooks.install("server.goblin_commands", Events.OnClientCommand,
        function(module, command, player, args)
            if module ~= "GoblinSurvivor" or command ~= "debug" or not Config.enabled then return end
            local text = type(args) == "table" and args.text or nil
            if type(text) ~= "string" or #text < 1 or #text > 160 then return end
            local name = playerName(player)
            local now = os.time()
            if Commands.lastAt[name] ~= nil and now - Commands.lastAt[name] < 1 then return end
            Commands.lastAt[name] = now
            handle(player, text)
        end)
    Commands.started = registered == true
    return Commands.started
end

return Commands

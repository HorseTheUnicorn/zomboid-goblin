-- In-game command surface for each player's own Goblin.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
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
    reply(player, "spawn | follow | wait | loot [food|medical|tools|ammo|surprise] | base | home | attack | equip | state")
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
        local ok, detail = Spawner.setBaseForPlayer(player)
        local body = Spawner.findForPlayer(player)
        if ok and body ~= nil then Body.say(body, "Base recorded, comrade. Try not to bourgeois it up.") end
        reply(player, detail)
        return
    end

    local body, detail = ownBody(player, false)
    if body == nil then reply(player, detail or "Your Goblin is not present."); return end

    if command == "follow" or command == "come" or command == "regroup" then
        local ok, result = Brain.setTask(body, Constants.TASK.FOLLOW, { owner = playerName(player) })
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
        if ok then Body.say(body, "I shall seize useful property and return it to the collective. Meaning the base.") end
        reply(player, ok and "Loot run started." or result)
        return
    end
    if command == "home" or command == "return" or command == "returntobase" then
        local ok, result = Brain.setTask(body, Constants.TASK.RETURN_TO_BASE, {})
        reply(player, ok and "Returning to base." or result)
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

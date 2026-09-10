-- Developer-only in-game command surface.
--
-- These commands deliberately bypass Qwen so body, pathfinding, animation,
-- and multiplayer replication can be tested independently.  Only an admin,
-- moderator, or configured commander may invoke them.
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

local function log(message)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(message)) end
end

local function reply(player, message)
    local text = "[Goblin] " .. tostring(message)
    if not call(player, "Say", text) then call(player, "addLineChatElement", text) end
end

local function tokens(text)
    local result = {}
    for token in string.gmatch(text, "%S+") do result[#result + 1] = token end
    return result
end

local function finiteNumber(value)
    local number = tonumber(value)
    return number ~= nil and number == number and number ~= math.huge and number ~= -math.huge
end

local function parseTarget(parts)
    if not finiteNumber(parts[3]) or not finiteNumber(parts[4]) or not finiteNumber(parts[5]) then
        return nil
    end
    local x, y, z = tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5])
    if math.abs(x) > 1000000 or math.abs(y) > 1000000 or math.abs(z) > 32 then return nil end
    return { x = x, y = y, z = z }
end

local function teleportToOwner(body)
    local owner = nil
    local first = nil
    local wanted = Spawner.ownerName()
    if type(getOnlinePlayers) == "function" then
        local ok, list = pcall(getOnlinePlayers)
        if ok and list ~= nil then
            local count = type(list.size) == "function" and list:size() or #list
            for index = 0, count - 1 do
                local player = type(list.get) == "function" and list:get(index) or list[index + 1]
                if player ~= nil then
                    if first == nil then first = player end
                    local okName, valueName = call(player, "getUsername")
                    if wanted ~= nil and okName and type(valueName) == "string"
                        and string.lower(valueName) == string.lower(wanted) then
                        owner = player
                        break
                    end
                end
            end
        end
    end
    if owner == nil and wanted == nil then owner = first end
    if owner == nil then return false, "no online owner" end
    local okX, x = call(owner, "getX")
    local okY, y = call(owner, "getY")
    local okZ, z = call(owner, "getZ")
    if not okX or not okY or not okZ then return false, "owner position unavailable" end
    -- This operation is only an explicit debug/emergency command.  Ordinary
    -- FOLLOW recovery always remains PathFindBehavior2-driven.
    call(body, "setX", x + 3)
    call(body, "setY", y + 3)
    call(body, "setZ", z)
    local square = nil
    if type(getCell) == "function" then
        local okCell, cell = pcall(getCell)
        if okCell and cell ~= nil and type(cell.getGridSquare) == "function" then
            local okSquare, value = pcall(cell.getGridSquare, cell,
                math.floor(x + 3), math.floor(y + 3), math.floor(z))
            if okSquare then square = value end
        end
    end
    call(body, "setCurrentSquare", square)
    call(body, "setMovingSquare", square)
    log("EMERGENCY_TELEPORT id=" .. Config.npcId)
    return true, "debug teleport complete"
end

local function handle(player, rawText)
    local parts = tokens(rawText)
    -- Accept both `/goblin spawn` and the explicit `/goblin debug spawn`
    -- spelling used by the client relay.
    if string.lower(parts[2] or "") == "debug" then
        table.remove(parts, 2)
    end
    if #parts < 2 then
        reply(player, "spawn | despawn | follow [owner] | wait | move x y z | attack | loot [focus] | equip | state | animation | reset | teleport")
        return
    end
    local command = string.lower(parts[2])
    if command == "spawn" then
        local body, detail = Spawner.ensure(true)
        reply(player, body ~= nil and "spawned" or detail)
        return
    end
    local body = Spawner.find()
    if command == "despawn" then
        if body == nil then reply(player, "Goblin is not present"); return end
        call(body, "setTarget", nil)
        call(body, "removeFromWorld")
        call(body, "removeFromSquare")
        call(body, "setSquare", nil)
        Spawner.body = nil
        Spawner.suppress(Config.respawnSeconds)
        reply(player, "despawned; persistent identity retained")
        return
    end
    if command == "teleport" then
        if body == nil then reply(player, "Goblin is not present"); return end
        local ok, detail = teleportToOwner(body)
        reply(player, detail)
        return
    end
    if body == nil then reply(player, "Goblin body is not present"); return end
    if command == "follow" then
        local owner = parts[3]
        local ok, detail = Brain.setTask(body, Constants.TASK.FOLLOW, { owner = owner })
        reply(player, ok and "following owner" or detail)
        return
    end
    if command == "wait" or command == "hold" then
        local ok, detail = Brain.setTask(body, Constants.TASK.WAIT, {})
        reply(player, ok and "waiting" or detail)
        return
    end
    if command == "move" or command == "guard" then
        local target = parseTarget(parts)
        if target == nil then reply(player, "move requires finite x y z"); return end
        local task = command == "guard" and Constants.TASK.GUARD or Constants.TASK.MOVE_TO
        local ok, detail = Brain.setTask(body, task, target)
        reply(player, ok and (command .. " task accepted") or detail)
        return
    end
    if command == "attack" then
        local ok, detail = Brain.setTask(body, Constants.TASK.ATTACK, {})
        reply(player, detail)
        return
    end
    if command == "loot" or command == "scavenge" then
        local focus = parts[3]
        if focus ~= nil and not string.match(focus, "^[A-Za-z]+$") then
            reply(player, "loot focus must be a word")
            return
        end
        local ok, detail = Brain.setTask(body, Constants.TASK.LOOT, {
            loot_focus = focus
        })
        reply(player, ok and "loot scan task accepted" or detail)
        return
    end
    if command == "equip" then
        local ok, detail = Brain.setTask(body, Constants.TASK.EQUIP, {
            item = { name = Config.weaponType, count = 1 }
        })
        reply(player, detail)
        return
    end
    if command == "reset" then
        Body.applyInvariants(body, false)
        Brain.setTask(body, Constants.TASK.FOLLOW, {})
        reply(player, "state reset to FOLLOW")
        return
    end
    if command == "state" or command == "animation" then
        local snapshot = Spawner.snapshot()
        reply(player, "task=" .. tostring(snapshot.task)
            .. " physical=" .. tostring(snapshot.physical_state)
            .. " move=" .. tostring(snapshot.move_type)
            .. " combat=" .. tostring(snapshot.combat_state)
            .. " humanized=" .. tostring(snapshot.humanized)
            .. " weapon=" .. tostring(snapshot.weapon_ready))
        return
    end
    reply(player, "unknown command")
end

function Commands.start()
    if Commands.started then return true end
    if Events == nil or Events.OnClientCommand == nil then
        return false
    end
    local registered = EventHooks.install("server.debug_commands", Events.OnClientCommand, function(module, command, player, args)
        if module ~= "GoblinSurvivor" or command ~= "debug" or not Config.enabled then return end
        if not Config.isAuthorizedPlayer(player) then
            reply(player, "developer command denied")
            return
        end
        local text = type(args) == "table" and args.text or nil
        if type(text) ~= "string" or #text < 1 or #text > 160 then return end
        local okName, valueName = call(player, "getUsername")
        local name = okName and type(valueName) == "string" and valueName or "?"
        local now = os.time()
        if Commands.lastAt[name] ~= nil and now - Commands.lastAt[name] < 1 then return end
        Commands.lastAt[name] = now
        handle(player, text)
    end)
    if not registered then return false end
    Commands.started = true
    return true
end

return Commands

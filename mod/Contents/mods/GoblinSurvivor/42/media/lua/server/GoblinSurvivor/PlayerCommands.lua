-- Small, explicit in-game command surface for the client-survivor roster.
-- Every authenticated connected player may use these commands. They are
-- resolved on the server and then enter the same ClientSurvivorServer state
-- machine used by the bridge/Qwen controller; no client can write position
-- or body state directly.
local Config = require("GoblinSurvivor/Config")
local Protocol = require("GoblinSurvivor/ClientSurvivorProtocol")
local EventLog = require("GoblinSurvivor/EventLog")
local ClientSurvivorServer = require("GoblinSurvivor/ClientSurvivorServer")
local BaseManager = require("GoblinSurvivor/BaseManager")

local Commands = { started = false, lastAt = {} }
local COMMAND_COOLDOWN_SECONDS = 1

local JOBS = {
    loot = "LOOT",
    gather = "SCAVENGE",
    forage = "SCAVENGE",
    collect = "SCAVENGE",
    scavenge = "SCAVENGE",
    disassemble = "DISASSEMBLE",
    dismantle = "DISASSEMBLE",
    build = "BUILDER",
    builder = "BUILDER",
    guard = "GUARD",
    medic = "MEDIC",
    farmer = "FARMER",
    scout = "SCOUT",
    hauler = "HAULER"
}

local function playerName(player)
    if player == nil or type(player.getUsername) ~= "function" then return nil end
    local ok, name = pcall(player.getUsername, player)
    if not ok or type(name) ~= "string" or #name < 1 or #name > 96 then return nil end
    if string.find(name, "[^A-Za-z0-9_%-]", 1) ~= nil then return nil end
    return name
end

local function reply(player, message)
    if player == nil or type(message) ~= "string" then return end
    if type(player.addLineChatElement) == "function" then
        pcall(player.addLineChatElement, player,
            "[Goblin] " .. string.sub(message, 1, 220), 0.4, 0.9, 0.4)
    end
end

local function words(text)
    local result = {}
    if type(text) ~= "string" then return result end
    for value in string.gmatch(text, "%S+") do
        if #result >= 8 then break end
        table.insert(result, value)
    end
    return result
end

local function rosterSelection(selector)
    local statuses = ClientSurvivorServer.statusAll()
    local normalized = string.lower(tostring(selector or "all"))
    local result = {}
    for _, status in ipairs(statuses) do
        local id = status.npc_id
        local matches = normalized == "all"
            or normalized == "*"
            or string.lower(tostring(id)) == normalized
            or (normalized == "goblin" and id == Config.npcId)
            or string.lower(tostring(status.name or "")) == normalized
        if matches then table.insert(result, id) end
    end
    return result
end

local function executeForSelection(player, selector, action, fields)
    local ids = rosterSelection(selector)
    if #ids == 0 then return 0, "no matching survivor" end
    local speaker = playerName(player) or "player"
    local accepted = 0
    local detail = ""
    for _, npcId in ipairs(ids) do
        local message = {
            protocol = Protocol.version,
            npc_id = npcId,
            action = action,
            priority = 2,
            reason = "in-game command from " .. speaker,
            source = "in_game_chat"
        }
        for key, value in pairs(fields or {}) do message[key] = value end
        local ok, response = ClientSurvivorServer.execute(message)
        if ok then
            accepted = accepted + 1
            detail = response
        elseif detail == "" then
            detail = response
        end
    end
    return accepted, detail
end

local function statusLines(player)
    local statuses = ClientSurvivorServer.statusAll()
    if #statuses == 0 then
        reply(player, "survivor roster is still anchoring to the first player")
        return
    end
    reply(player, "roster: " .. tostring(#statuses)
        .. " human bodies; commands affect Goblin or all companions")
    for _, status in ipairs(statuses) do
        reply(player, tostring(status.name or status.npc_id)
            .. " job=" .. tostring(status.job or "none")
            .. " task=" .. tostring(status.task or "waiting")
            .. " phase=" .. tostring(status.expedition_phase or "none")
            .. " cargo=" .. tostring(status.cargo_count or 0)
            .. " movement=" .. tostring(status.movement_mode or "AUTO")
            .. (status.running == true and "(running)" or "")
            .. " weapon=" .. tostring(status.firearm_type or "none")
            .. " god=" .. tostring(status.god_mode == true))
    end
end

local function handle(player, text)
    local speaker = playerName(player)
    if speaker == nil or type(text) ~= "string" then return end
    if #text < 1 or #text > 240 then return end
    local now = Protocol.nowMs() / 1000
    if Commands.lastAt[speaker] ~= nil
        and now - Commands.lastAt[speaker] < COMMAND_COOLDOWN_SECONDS then return end
    Commands.lastAt[speaker] = now
    -- Keep the coordinator's durable chat memory aware of direct player
    -- orders too. The event contains only the bounded command text; the
    -- authoritative execution below still happens locally on this server.
    EventLog.emit("chat", {
        speaker = speaker,
        text = string.gsub(string.sub(text, 1, 240), "[^%w%s_/%-]", ""),
        authorized = true
    })
    if not ClientSurvivorServer.ensureForPlayer(player) then
        reply(player, "the human roster is waiting for a usable world position")
        return
    end
    local args = words(text)
    local command = string.lower(args[2] or "help")
    local selector = args[3] or "all"
    if command == "help" then
        reply(player, "/gss status | follow/join [all|id] | hold/leave [all|id]")
        reply(player, "/gss squad [all|id] | dismiss")
        reply(player, "/gss loot|gather|scavenge|disassemble|build|guard [all|id]")
        reply(player, "/gss cars [all|id] | cars off [all|id]")
        reply(player, "/gss run|walk|auto [all|id]")
        reply(player, "/gss base set [name] | base status | fortify [mike|id]")
        reply(player, "Goblin follows while you move and scavenges after you are idle")
        reply(player, "build is chat-authorized only and remains active until held or reassigned")
        reply(player, "/gss attack/melee [all|id] | home [all|id]")
        return
    end
    if command == "status" or command == "list" then
        statusLines(player)
        return
    end
    if command == "base" or command == "setbase" then
        local subcommand = string.lower(args[3] or "status")
        local requestedName = nil
        if command == "setbase" then
            subcommand = "set"
            requestedName = args[3]
        elseif subcommand == "set" or subcommand == "anchor" then
            requestedName = args[4]
        end
        if subcommand == "set" or subcommand == "anchor" then
            local anchored, detail = BaseManager.setFromPlayer(player, requestedName)
            reply(player, detail)
            return
        end
        if subcommand == "status" or subcommand == "show" then
            local base = BaseManager.snapshot()
            reply(player, "base '" .. tostring(base.name)
                .. "' anchored=" .. tostring(base.has_anchor == true)
                .. " guards=" .. tostring(base.assigned_guards or 0)
                .. "/" .. tostring(base.minimum_guards or 0))
            return
        end
        reply(player, "use /gss base set [name] or /gss base status")
        return
    end
    if command == "fortify" then
        if not BaseManager.hasAnchor() then
            reply(player, "set the base first with /gss base set")
            return
        end
        local fortifySelector = args[3] or "mike"
        local accepted, detail = executeForSelection(player, fortifySelector,
            "ASSIGN_JOB", { job = "BUILDER" })
        reply(player, tostring(accepted) .. " survivor(s) assigned base fortification: "
            .. tostring(detail))
        return
    end
    if command == "run" or command == "sprint"
        or command == "walk" or command == "auto" then
        local mode = (command == "run" or command == "sprint") and "RUN"
            or command == "walk" and "WALK" or "AUTO"
        local accepted, detail = executeForSelection(player, selector,
            "SET_MOVEMENT", { movement_mode = mode })
        reply(player, tostring(accepted) .. " survivor(s) movement set to "
            .. mode .. ": " .. tostring(detail))
        return
    end
    if command == "cars" or command == "vehicles" or command == "recover" then
        local enabled = true
        local vehicleSelector = args[3] or "all"
        if string.lower(vehicleSelector) == "off" then
            enabled = false
            vehicleSelector = args[4] or "all"
        end
        local accepted, detail = executeForSelection(player, vehicleSelector,
            "SET_VEHICLE_RECOVERY", { enabled = enabled })
        reply(player, tostring(accepted) .. " survivor(s) vehicle recovery "
            .. (enabled and "enabled" or "disabled") .. ": " .. tostring(detail))
        return
    end
    if command == "follow" or command == "regroup" then
        local accepted, detail = executeForSelection(player, selector, "FOLLOW", {
            target = { kind = "player", name = speaker }
        })
        reply(player, tostring(accepted) .. " survivor(s) following you: " .. tostring(detail))
        return
    end
    if command == "join" or command == "joinparty" then
        local accepted, detail = executeForSelection(player, selector, "JOIN_PARTY", {
            target = { kind = "player", name = speaker }
        })
        reply(player, tostring(accepted) .. " survivor(s) joined your party: " .. tostring(detail))
        return
    end
    if command == "hold" or command == "rest" then
        local accepted, detail = executeForSelection(player, selector, "HOLD_POSITION", {})
        reply(player, tostring(accepted) .. " survivor(s) holding position: " .. tostring(detail))
        return
    end
    if command == "leave" or command == "leaveparty" then
        local accepted, detail = executeForSelection(player, selector, "LEAVE_PARTY", {})
        reply(player, tostring(accepted) .. " survivor(s) left your party: " .. tostring(detail))
        return
    end
    if command == "attack" or command == "hunt" then
        local accepted, detail = executeForSelection(player, selector, "ATTACK", {
            target = { kind = "nearby_threat", name = "nearby hostile zombie" }
        })
        reply(player, tostring(accepted) .. " survivor(s) set to hunt zombies: " .. tostring(detail))
        return
    end
    if command == "melee" or command == "meleeattack" then
        local accepted, detail = executeForSelection(player, selector, "MELEE_ATTACK", {
            target = { kind = "nearby_threat", name = "nearby hostile zombie" }
        })
        reply(player, tostring(accepted) .. " survivor(s) set to melee zombies: " .. tostring(detail))
        return
    end
    if command == "home" or command == "return" then
        local accepted, detail = executeForSelection(player, selector, "GO_HOME", {
            target = { kind = "home_base", name = "home base" }
        })
        reply(player, tostring(accepted) .. " survivor(s) returning home: " .. tostring(detail))
        return
    end
    if command == "squad" or command == "formsquad" or command == "form" then
        local members = rosterSelection(selector)
        local companions = {}
        for _, npcId in ipairs(members) do
            if npcId ~= Config.npcId then table.insert(companions, npcId) end
        end
        if #companions == 0 then
            reply(player, "choose a companion or use /gss squad all")
            return
        end
        local accepted, detail = executeForSelection(player, "goblin", "FORM_SQUAD", {
            target = { kind = "squad", name = "goblin-party" },
            members = companions
        })
        reply(player, tostring(accepted) .. " squad leader(s) accepted; " .. tostring(detail))
        return
    end
    if command == "dismiss" or command == "dismisssquad" then
        local accepted, detail = executeForSelection(player, "goblin", "DISMISS_SQUAD", {})
        reply(player, tostring(accepted) .. " squad command(s) accepted; " .. tostring(detail))
        return
    end
    local job = JOBS[command]
    if job ~= nil then
        local accepted, detail = executeForSelection(player, selector, "ASSIGN_JOB", {
            job = job
        })
        reply(player, tostring(accepted) .. " survivor(s) assigned " .. job .. ": " .. tostring(detail))
        return
    end
    reply(player, "unknown /gss command; use /gss help")
end

function Commands.start()
    if Commands.started then return true end
    if not Config.enabled or Config.bodyMode ~= "client_survivor" then return false end
    if Events == nil or Events.OnClientCommand == nil
        or type(Events.OnClientCommand.Add) ~= "function" then return false end
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module ~= Protocol.module or command ~= "gss" then return end
        if type(args) ~= "table" then return end
        handle(player, args.text)
    end)
    Commands.started = true
    print("[GoblinSurvivor] in-game survivor commands enabled for all players")
    return true
end

return Commands

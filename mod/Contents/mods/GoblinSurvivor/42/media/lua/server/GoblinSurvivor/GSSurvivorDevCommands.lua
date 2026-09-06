-- Authorized local development commands. Disabled unless both development
-- mode and explicit test-command configuration are enabled.
local Config = require("GoblinSurvivor/Config")
local Survivor = require("GoblinSurvivor/GSSurvivor")
local Spawner = require("GoblinSurvivor/GSSurvivorSpawner")
local Registry = require("GoblinSurvivor/GSSurvivorRegistry")
local Identity = require("GoblinSurvivor/Identity")
local Perception = require("GoblinSurvivor/GSSurvivorPerception")
local Combat = require("GoblinSurvivor/GSSurvivorCombat")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")

local Commands = { started = false }

local function reply(player, message)
    if player == nil or type(message) ~= "string" then return end
    if type(player.addLineChatElement) == "function" then
        pcall(player.addLineChatElement, player,
            "[GSS] " .. string.sub(message, 1, 220), 0.4, 0.9, 0.4)
    end
end

local function words(text)
    local result = {}
    if type(text) ~= "string" then return result end
    for value in string.gmatch(text, "%S+") do table.insert(result, value) end
    return result
end

local function inspect(id)
    local body = Registry.body(id)
    if body == nil or not Identity.isManaged(body) then return nil end
    local snapshot = Survivor.snapshot(body)
    if snapshot == nil then return nil end
    return "id=" .. tostring(snapshot.survivor_id)
        .. " type=" .. tostring(snapshot.survivor_type)
        .. " generation=" .. tostring(snapshot.body_generation)
        .. " goal=" .. tostring(snapshot.goal)
        .. " task=" .. tostring(snapshot.task)
        .. " leader=" .. tostring(snapshot.leader)
end

local function handle(player, text)
    local args = words(text)
    if args[1] == nil then return end
    local command = string.lower(args[1])
    if command == "spawn" and string.lower(args[2] or "") == "test" then
        local body, detail = Spawner.spawnTest(player)
        reply(player, body and ("test survivor ready: " .. tostring(detail))
            or ("test survivor failed: " .. tostring(detail)))
        return
    end
    if command == "spawn" and string.lower(args[2] or "") == "goblin" then
        local GoblinNPC = require("GoblinSurvivor/GoblinNPC")
        local body, detail = GoblinNPC.spawnGoblin()
        reply(player, body and ("Goblin ready: " .. tostring(detail))
            or ("Goblin spawn pending/failed: " .. tostring(detail)))
        return
    end
    if command == "list" then
        local snapshots = Registry.snapshot()
        reply(player, "managed survivors=" .. tostring(#snapshots))
        for _, item in ipairs(snapshots) do
            reply(player, tostring(item.survivor_id) .. " " .. tostring(item.name)
                .. " " .. tostring(item.goal))
        end
        return
    end
    if command == "inspect" then
        reply(player, inspect(args[2]) or "survivor is not present")
        return
    end
    if command == "follow" and args[2] ~= nil and args[3] ~= nil then
        local ok, detail = Survivor.setGoal(args[2], "FOLLOW", args[3])
        reply(player, ok and ("follow goal accepted for " .. args[2])
            or ("follow failed: " .. tostring(detail)))
        return
    end
    if command == "hold" and args[2] ~= nil then
        local ok, detail = Survivor.setGoal(args[2], "HOLD")
        reply(player, ok and ("hold goal accepted for " .. args[2])
            or ("hold failed: " .. tostring(detail)))
        return
    end
    if command == "attacktest" and args[2] ~= nil then
        local body = Registry.body(args[2])
        local threat = body and Perception.nearestThreat(body, 32) or nil
        local ok, detail = Combat.attack(body, threat, NpcAdapter, args[2])
        reply(player, ok and "bounded attack test target accepted"
            or ("attack test failed: " .. tostring(detail)))
        return
    end
    reply(player, "commands: spawn test|goblin, list, inspect <id>, follow <id> <player>, hold <id>, attacktest <id>")
end

function Commands.start()
    if Commands.started then return true end
    if not Config.developmentMode or not Config.allowTestCommands then return false end
    if Events == nil or Events.OnClientCommand == nil
        or type(Events.OnClientCommand.Add) ~= "function" then return false end
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module ~= "GoblinSurvivor" or command ~= "gss" then return end
        if not Config.isAuthorizedPlayer(player) then return end
        if type(args) ~= "table" then return end
        handle(player, args.text)
    end)
    Commands.started = true
    print("[GoblinSurvivor] standalone survivor dev commands enabled")
    return true
end

return Commands

-- Server-authoritative state transport for the native friendly survivor.
--
-- PZ already replicates the position of a world IsoZombie through its normal
-- multiplayer entity stream. This packet carries only mod-owned identity and
-- controller state. It is deliberately low frequency so the controller never
-- turns an OnTick callback into a packet flood.
local Protocol = require("GoblinSurvivor/FriendlySurvivorProtocol")

local Network = {
    sequence = 0,
    lastBroadcastAt = 0,
    broadcastIntervalMs = 500,
    lastState = nil,
    started = false
}

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] FriendlySurvivorNetwork: " .. tostring(message))
    end
end

local function username(player)
    if player == nil or type(player.getUsername) ~= "function" then return nil end
    local ok, value = pcall(function() return player:getUsername() end)
    if not ok or not Protocol.safeText(value, Protocol.maxUsername, false) then
        return nil
    end
    return value
end

function Network.snapshot(body, target, distanceTiles, mode)
    local point = Protocol.position(body)
    if point == nil then return nil end
    Network.sequence = Network.sequence + 1
    return {
        protocol = Protocol.version,
        entity_id = "goblin.primary",
        entity_class = "IsoZombie",
        sequence = Network.sequence,
        x = point.x,
        y = point.y,
        z = point.z,
        target_username = username(target),
        distance_tiles = distanceTiles,
        mode = mode or "IDLE",
        server_timestamp_ms = Protocol.nowMs()
    }
end

function Network.publish(body, target, distanceTiles, mode, force)
    local now = Protocol.nowMs()
    if not force and now - Network.lastBroadcastAt < Network.broadcastIntervalMs then
        return false, "state packet is rate limited"
    end
    local state = Network.snapshot(body, target, distanceTiles, mode)
    if state == nil then return false, "body has no network position" end
    Network.lastState = state
    Network.lastBroadcastAt = now
    if type(sendServerCommand) ~= "function" then
        return false, "sendServerCommand is unavailable"
    end
    local ok, errorValue = pcall(sendServerCommand,
        Protocol.module, Protocol.stateCommand, state)
    if not ok then
        log("state broadcast failed: " .. tostring(errorValue))
        return false, "state broadcast failed"
    end
    return true, "state broadcast"
end

function Network.sendToPlayer(player)
    if player == nil or Network.lastState == nil
        or type(sendServerCommand) ~= "function" then
        return false
    end
    local ok = pcall(sendServerCommand, player, Protocol.module,
        Protocol.stateCommand, Network.lastState)
    return ok
end

function Network.onClientCommand(module, command, player, args)
    if module ~= Protocol.module or command ~= Protocol.requestCommand then
        return
    end
    if type(args) ~= "table" or args.protocol ~= Protocol.version then return end
    -- This is a read-only snapshot request. It has no gameplay authority and
    -- therefore does not share the command/action permission path.
    Network.sendToPlayer(player)
end

function Network.start()
    if Network.started then return true end
    if Events == nil or Events.OnClientCommand == nil
        or type(Events.OnClientCommand.Add) ~= "function" then
        log("OnClientCommand is unavailable; request/response sync disabled")
        return false
    end
    Events.OnClientCommand.Add(Network.onClientCommand)
    Network.started = true
    return true
end

function Network.lastSnapshot()
    return Network.lastState
end

return Network

-- Client half of the friendly-survivor state channel.
-- Movement is not applied here: the server's native IsoZombie replication is
-- the only movement authority. This module only caches the server snapshot.
local Protocol = require("GoblinSurvivor/FriendlySurvivorProtocol")

local Client = {
    lastState = nil,
    nextRequestAt = 0,
    requestIntervalMs = 5000
}

local function requestSnapshot()
    if type(sendClientCommand) ~= "function" then return false end
    local ok = pcall(sendClientCommand, Protocol.module,
        Protocol.requestCommand, { protocol = Protocol.version })
    return ok
end

local function onServerCommand(module, command, args)
    if module ~= Protocol.module or command ~= Protocol.stateCommand then return end
    if not Protocol.validSnapshot(args) then return end
    Client.lastState = args
    -- This is a read-only diagnostic/UI cache. It is never used to move the
    -- body and is not fed back to the server as an authority claim.
    _G.GoblinSurvivorFriendlyState = args
end

if Events and Events.OnServerCommand
    and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(onServerCommand)
end

if Events and Events.OnGameStart
    and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(function()
        Client.nextRequestAt = 0
        requestSnapshot()
    end)
end

if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(function()
        local now = Protocol.nowMs()
        if now >= Client.nextRequestAt then
            if requestSnapshot() then
                Client.nextRequestAt = now + Client.requestIntervalMs
            else
                Client.nextRequestAt = now + 1000
            end
        end
    end)
end

return Client

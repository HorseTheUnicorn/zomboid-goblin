-- Stable body-adapter boundary for the rest of GoblinSurvivor.
--
-- Bandits2 is the required NPC body/behavior engine. Only this boundary and
-- BanditsAdapter.lua know its names; the registry, command loop, telemetry,
-- and policy modules remain framework-agnostic.
local BanditsNpcAdapter = require("GoblinSurvivor/BanditsAdapter")

local NpcAdapter = {}

function NpcAdapter.engineName()
    return BanditsNpcAdapter.engineName()
end

function NpcAdapter.capabilities()
    local capabilities = BanditsNpcAdapter.capabilities()
    capabilities.selected_adapter = NpcAdapter.engineName()
    capabilities.control_ready = capabilities.available == true
        and capabilities.friendly == true
    return capabilities
end

function NpcAdapter.available()
    local capabilities = NpcAdapter.capabilities()
    return capabilities.available == true and capabilities.friendly == true
end

function NpcAdapter.spawnPoint(anchor)
    return BanditsNpcAdapter.spawnPoint(anchor)
end

function NpcAdapter.isCandidate(body)
    return BanditsNpcAdapter.isCandidate(body)
end

function NpcAdapter.isEventCandidate(body)
    return BanditsNpcAdapter.isEventCandidate(body)
end

function NpcAdapter.isFriendly(body)
    return BanditsNpcAdapter.isFriendly(body)
end

function NpcAdapter.isOwned(body)
    return BanditsNpcAdapter.isOwned(body) and NpcAdapter.isFriendly(body)
end

function NpcAdapter.prepare(body, npcId, anchor)
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable"
    end
    return BanditsNpcAdapter.prepare(body, npcId, anchor)
end

function NpcAdapter.spawnIndividual(anchor, npcId, program)
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable", nil
    end
    return BanditsNpcAdapter.spawnIndividual(anchor, npcId, program)
end

function NpcAdapter.getBrain(body)
    return BanditsNpcAdapter.getBrain(body)
end

function NpcAdapter.setTasks(body, tasks)
    return BanditsNpcAdapter.setTasks(body, tasks)
end

function NpcAdapter.clearTasks(body)
    return BanditsNpcAdapter.clearTasks(body)
end

function NpcAdapter.setCombatTarget(body, target)
    return BanditsNpcAdapter.setCombatTarget(body, target)
end

function NpcAdapter.tick(body)
    return BanditsNpcAdapter.tick(body)
end

function NpcAdapter.discard(body)
    return BanditsNpcAdapter.discard(body)
end

return NpcAdapter

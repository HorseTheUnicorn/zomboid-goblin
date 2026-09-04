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

function NpcAdapter.spawnPoint(anchor, extraOffset)
    return BanditsNpcAdapter.spawnPoint(anchor, extraOffset)
end

function NpcAdapter.isCandidate(body, npcId)
    return BanditsNpcAdapter.isCandidate(body, npcId)
end

function NpcAdapter.isEventCandidate(body, npcId)
    return BanditsNpcAdapter.isEventCandidate(body, npcId)
end

function NpcAdapter.isFriendly(body, npcId)
    return BanditsNpcAdapter.isFriendly(body, npcId)
end

function NpcAdapter.isOwned(body, npcId)
    return BanditsNpcAdapter.isOwned(body, npcId)
        and NpcAdapter.isFriendly(body, npcId)
end

function NpcAdapter.prepare(body, npcId, anchor, displayName, role)
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable"
    end
    return BanditsNpcAdapter.prepare(body, npcId, anchor, displayName, role)
end

function NpcAdapter.spawnIndividual(anchor, npcId, program, displayName, role, extraOffset)
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable", nil
    end
    return BanditsNpcAdapter.spawnIndividual(
        anchor, npcId, program, displayName, role, extraOffset
    )
end

function NpcAdapter.getBrain(body)
    return BanditsNpcAdapter.getBrain(body)
end

function NpcAdapter.say(body, text, npcId)
    return BanditsNpcAdapter.say(body, text, npcId)
end

function NpcAdapter.status(body, npcId)
    return BanditsNpcAdapter.status(body, npcId)
end

function NpcAdapter.setTasks(body, tasks, npcId)
    return BanditsNpcAdapter.setTasks(body, tasks, npcId)
end

function NpcAdapter.clearTasks(body, npcId)
    return BanditsNpcAdapter.clearTasks(body, npcId)
end

function NpcAdapter.setCombatTarget(body, target, npcId)
    return BanditsNpcAdapter.setCombatTarget(body, target, npcId)
end

function NpcAdapter.tick(body, npcId)
    return BanditsNpcAdapter.tick(body, npcId)
end

function NpcAdapter.discard(body, npcId)
    return BanditsNpcAdapter.discard(body, npcId)
end

return NpcAdapter

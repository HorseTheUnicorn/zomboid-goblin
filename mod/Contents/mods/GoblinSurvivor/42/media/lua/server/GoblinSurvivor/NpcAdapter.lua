-- Stable body-adapter boundary for the rest of GoblinSurvivor.
--
-- The native adapter owns the Build 42 body and behavior implementation. The
-- rest of the mod depends only on this narrow contract so the agent, command,
-- roster, and telemetry layers remain independent of PZ internals.
local NativeNpcAdapter = require("GoblinSurvivor/NativeNpcAdapter")

local NpcAdapter = {}

function NpcAdapter.engineName()
    return NativeNpcAdapter.engineName()
end

function NpcAdapter.capabilities()
    local capabilities = NativeNpcAdapter.capabilities()
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
    return NativeNpcAdapter.spawnPoint(anchor, extraOffset)
end

function NpcAdapter.isCandidate(body, npcId)
    return NativeNpcAdapter.isCandidate(body, npcId)
end

function NpcAdapter.isEventCandidate(body, npcId)
    return NativeNpcAdapter.isEventCandidate(body, npcId)
end

function NpcAdapter.isFriendly(body, npcId)
    return NativeNpcAdapter.isFriendly(body, npcId)
end

function NpcAdapter.isOwned(body, npcId)
    return NativeNpcAdapter.isOwned(body, npcId)
        and NpcAdapter.isFriendly(body, npcId)
end

function NpcAdapter.prepare(body, npcId, anchor, displayName, role)
    return NativeNpcAdapter.prepare(body, npcId, anchor, displayName, role)
end

function NpcAdapter.applySurvivorInvariants(body, profile, preserveTarget)
    return NativeNpcAdapter.applySurvivorInvariants(body, profile, preserveTarget)
end

function NpcAdapter.spawnIndividual(anchor, npcId, program, displayName, role, extraOffset)
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable", nil
    end
    return NativeNpcAdapter.spawnIndividual(
        anchor, npcId, program, displayName, role, extraOffset
    )
end

function NpcAdapter.getBrain(body)
    return NativeNpcAdapter.getBrain(body)
end

function NpcAdapter.say(body, text, npcId)
    return NativeNpcAdapter.say(body, text, npcId)
end

function NpcAdapter.status(body, npcId)
    return NativeNpcAdapter.status(body, npcId)
end

function NpcAdapter.setTasks(body, tasks, npcId)
    return NativeNpcAdapter.setTasks(body, tasks, npcId)
end

function NpcAdapter.clearTasks(body, npcId)
    return NativeNpcAdapter.clearTasks(body, npcId)
end

function NpcAdapter.setCombatTarget(body, target, npcId)
    return NativeNpcAdapter.setCombatTarget(body, target, npcId)
end

function NpcAdapter.tick(body, npcId)
    return NativeNpcAdapter.tick(body, npcId)
end

function NpcAdapter.discard(body, npcId)
    return NativeNpcAdapter.discard(body, npcId)
end

function NpcAdapter.removeForeign(body, npcId)
    return NativeNpcAdapter.removeForeign(body, npcId)
end

return NpcAdapter

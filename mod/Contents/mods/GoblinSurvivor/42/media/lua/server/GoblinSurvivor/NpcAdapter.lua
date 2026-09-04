-- Stable body-adapter boundary for the rest of GoblinSurvivor.
--
-- The shape of the standalone brain and its friendly/companion policy was
-- developed from the validated Bandits2 behavior, but the runtime body is
-- owned by this mod.  Keeping the implementation here avoids a second
-- Workshop dependency and lets joining clients download one Goblin package.
local StandaloneNpcAdapter = require("GoblinSurvivor/VanillaNpcAdapter")

local NpcAdapter = {}

function NpcAdapter.engineName()
    return "goblin-survivor"
end

function NpcAdapter.capabilities()
    local capabilities = StandaloneNpcAdapter.capabilities()
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
    return StandaloneNpcAdapter.spawnPoint(anchor)
end

function NpcAdapter.isCandidate(body)
    return StandaloneNpcAdapter.isCandidate(body)
end

function NpcAdapter.isEventCandidate(body)
    return StandaloneNpcAdapter.isEventCandidate(body)
end

function NpcAdapter.isFriendly(body)
    return StandaloneNpcAdapter.isFriendly(body)
end

function NpcAdapter.isOwned(body)
    return StandaloneNpcAdapter.isOwned(body) and NpcAdapter.isFriendly(body)
end

function NpcAdapter.prepare(body, npcId, anchor)
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable"
    end
    return StandaloneNpcAdapter.prepare(body, npcId, anchor)
end

function NpcAdapter.spawnIndividual(anchor, npcId, program)
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable", nil
    end
    return StandaloneNpcAdapter.spawnIndividual(anchor, npcId, program)
end

function NpcAdapter.getBrain(body)
    return StandaloneNpcAdapter.getBrain(body)
end

function NpcAdapter.setTasks(body, tasks)
    return StandaloneNpcAdapter.setTasks(body, tasks)
end

function NpcAdapter.clearTasks(body)
    return StandaloneNpcAdapter.clearTasks(body)
end

function NpcAdapter.setCombatTarget(body, target)
    return StandaloneNpcAdapter.setCombatTarget(body, target)
end

function NpcAdapter.tick(body)
    return StandaloneNpcAdapter.tick(body)
end

function NpcAdapter.discard(body)
    return StandaloneNpcAdapter.discard(body)
end

return NpcAdapter

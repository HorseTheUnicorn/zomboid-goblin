-- Stable body-adapter boundary for the rest of GoblinSurvivor.
--
-- Bandits2 is preferred because it supplies a survivor brain and an explicit
-- friendly/companion profile.  The older vanilla adapter remains available
-- as a dependency-free inspection fallback, but this selector never exposes
-- it as a controllable NPC because a normal IsoZombie has no verified
-- friendly relationship contract.
local BanditsAdapter = require("GoblinSurvivor/BanditsAdapter")
local VanillaNpcAdapter = require("GoblinSurvivor/VanillaNpcAdapter")

local NpcAdapter = {}

local function selected()
    if BanditsAdapter.available() then
        return BanditsAdapter
    end
    return VanillaNpcAdapter
end

function NpcAdapter.engineName()
    local adapter = selected()
    if type(adapter.engineName) == "function" then
        return adapter.engineName()
    end
    return "vanilla-zombie"
end

function NpcAdapter.capabilities()
    local adapter = selected()
    local capabilities = adapter.capabilities()
    capabilities.selected_adapter = NpcAdapter.engineName()
    -- The generic contract is intentionally stricter than the old vanilla
    -- spawn API.  No body is controllable until friendliness is proven.
    capabilities.control_ready = capabilities.available == true
        and capabilities.friendly == true
    return capabilities
end

function NpcAdapter.available()
    return NpcAdapter.capabilities().control_ready == true
end

function NpcAdapter.spawnPoint(anchor)
    return selected().spawnPoint(anchor)
end

function NpcAdapter.isCandidate(body)
    local adapter = selected()
    if type(adapter.isCandidate) == "function" then
        return adapter.isCandidate(body)
    end
    return adapter.isOwned(body)
end

function NpcAdapter.isFriendly(body)
    local adapter = selected()
    if type(adapter.isFriendly) == "function" then
        return adapter.isFriendly(body)
    end
    return false
end

function NpcAdapter.isOwned(body)
    local adapter = selected()
    return adapter.isOwned(body) and NpcAdapter.isFriendly(body)
end

function NpcAdapter.prepare(body, npcId, anchor)
    local adapter = selected()
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable"
    end
    return adapter.prepare(body, npcId, anchor)
end

function NpcAdapter.spawnIndividual(anchor, npcId, program)
    local adapter = selected()
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable", nil
    end
    return adapter.spawnIndividual(anchor, npcId, program)
end

function NpcAdapter.getBrain(body)
    local adapter = selected()
    return adapter.getBrain(body)
end

function NpcAdapter.setTasks(body, tasks)
    local adapter = selected()
    return adapter.setTasks(body, tasks)
end

function NpcAdapter.clearTasks(body)
    local adapter = selected()
    return adapter.clearTasks(body)
end

function NpcAdapter.tick(body)
    local adapter = selected()
    return adapter.tick(body)
end

return NpcAdapter

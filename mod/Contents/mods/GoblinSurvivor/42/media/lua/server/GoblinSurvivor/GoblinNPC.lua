local Config = require("GoblinSurvivor/Config")
local NPCRegistry = require("GoblinSurvivor/NPCRegistry")
local Protection = require("GoblinSurvivor/Protection")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")

local GoblinNPC = {}

function GoblinNPC.spawnGoblin()
    return NPCRegistry.spawnGoblin()
end

function GoblinNPC.findGoblin()
    return NPCRegistry.findGoblin()
end

function GoblinNPC.getGoblinState()
    local entry = NPCRegistry.get(Config.npcId)
    local zombie = NPCRegistry.findGoblin()
    local capabilities = NpcAdapter.capabilities()
    return {
        npc_id = Config.npcId,
        name = Config.npcName,
        alive = entry ~= nil and entry.alive == true and zombie ~= nil,
        active = entry ~= nil and entry.active == true,
        control_ready = zombie ~= nil and Protection.isProtected(zombie),
        npc_engine_ready = capabilities.control_ready == true,
        body_mode = zombie ~= nil and "npc" or "sensor_only",
        role = entry and entry.role or Config.npcRole
    }
end

function GoblinNPC.ensure()
    local zombie = NPCRegistry.findGoblin()
    if zombie ~= nil then
        Protection.apply(zombie)
        NpcAdapter.tick(zombie)
        return zombie, "present"
    end
    local spawned, detail = NPCRegistry.spawnGoblin()
    if spawned ~= nil then
        Protection.apply(spawned)
        NpcAdapter.tick(spawned)
    end
    return spawned, detail
end

function GoblinNPC.onZombieDeath(zombie)
    local current = NPCRegistry.findGoblin()
    if current == zombie then
        NPCRegistry.markDead()
    end
end

function GoblinNPC.onZombieUpdate(zombie)
    -- OnZombieUpdate runs close to the zombie AI update. Reasserting the
    -- standalone friendly target policy here closes the window in which a
    -- normal zombie could reacquire a player between slower command ticks.
    if zombie ~= nil and NpcAdapter.isOwned(zombie) then
        Protection.apply(zombie)
        NpcAdapter.tick(zombie)
    end
end

return GoblinNPC

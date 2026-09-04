local Config = require("GoblinSurvivor/Config")
local NPCRegistry = require("GoblinSurvivor/NPCRegistry")
local Protection = require("GoblinSurvivor/Protection")

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
    return {
        npc_id = Config.npcId,
        name = Config.npcName,
        alive = entry ~= nil and entry.alive == true and zombie ~= nil,
        active = entry ~= nil and entry.active == true,
        control_ready = zombie ~= nil and Protection.isProtected(zombie),
        npc_engine_ready = type(BanditBrain) == "table"
            and type(BanditServer) == "table"
            and type(BanditServer.Spawner) == "table",
        body_mode = zombie ~= nil and "npc" or "sensor_only",
        role = entry and entry.role or Config.npcRole
    }
end

function GoblinNPC.ensure()
    local zombie = NPCRegistry.findGoblin()
    if zombie ~= nil then
        Protection.apply(zombie)
        return zombie, "present"
    end
    local spawned, detail = NPCRegistry.spawnGoblin()
    return spawned, detail
end

function GoblinNPC.onZombieDeath(zombie)
    local current = NPCRegistry.findGoblin()
    if current == zombie then
        NPCRegistry.markDead()
    end
end

return GoblinNPC

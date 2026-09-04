local Config = require("GoblinSurvivor/Config")
local NPCRegistry = require("GoblinSurvivor/NPCRegistry")
local Protection = require("GoblinSurvivor/Protection")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")
local SquadManager = require("GoblinSurvivor/SquadManager")

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
    local spawn = NPCRegistry.spawnState()
    local status = NpcAdapter.status(zombie)
    local controlReady = zombie ~= nil
        and NpcAdapter.isOwned(zombie)
        and Protection.isProtected(zombie)
    return {
        npc_id = Config.npcId,
        name = Config.npcName,
        alive = entry ~= nil and entry.alive == true and zombie ~= nil,
        active = entry ~= nil and entry.active == true,
        control_ready = controlReady,
        npc_engine_ready = capabilities.control_ready == true,
        body_mode = controlReady and "npc" or "sensor_only",
        role = entry and entry.role or Config.npcRole,
        mode = status.mode,
        task = status.task,
        target_player = status.target_player,
        target_npc_id = status.target_npc_id,
        friendly = status.friendly,
        protected = status.protected,
        needs_disabled = status.needs_disabled,
        spawn_status = spawn.status,
        spawn_pending = spawn.pending,
        spawn_attempts = spawn.attempts
    }
end

function GoblinNPC.ensure()
    local zombie = NPCRegistry.findGoblin()
    if zombie ~= nil then
        Protection.apply(zombie)
        NpcAdapter.tick(zombie, Config.npcId)
        NPCRegistry.ensureManaged()
        SquadManager.tick()
        return zombie, "present"
    end
    local spawned, detail = NPCRegistry.spawnGoblin()
    if spawned ~= nil then
        Protection.apply(spawned)
        NpcAdapter.tick(spawned, Config.npcId)
        NPCRegistry.ensureManaged()
        SquadManager.tick()
    end
    return spawned, detail
end

function GoblinNPC.onZombieDeath(zombie)
    local entry, npcId = NPCRegistry.entryForBody(zombie)
    if entry ~= nil and entry.zombie == zombie then
        NPCRegistry.markDead(npcId)
    end
end

function GoblinNPC.onZombieUpdate(zombie)
    -- OnZombieUpdate runs close to the zombie AI update. Reasserting the
    -- Bandits2 friendly policy here closes the window in which a normal
    -- zombie could reacquire a player between slower command ticks.
    local entry, npcId = NPCRegistry.entryForBody(zombie)
    if zombie ~= nil and entry ~= nil and NpcAdapter.isOwned(zombie, npcId) then
        if npcId == Config.npcId then Protection.apply(zombie) end
        NpcAdapter.tick(zombie, npcId)
    end
end

return GoblinNPC

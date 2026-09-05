-- Thin synchronization boundary for the standalone survivor engine.
-- Native body movement remains normal PZ replication; this channel carries
-- semantic diagnostics and does not ask clients to move the body.
local Protocol = require("GoblinSurvivor/FriendlySurvivorProtocol")
local Network = require("GoblinSurvivor/FriendlySurvivorNetwork")
local Identity = require("GoblinSurvivor/Identity")

local Sync = { started = false, lastAt = {} }

function Sync.start()
    if Sync.started then return true end
    Network.start()
    Sync.started = true
    return true
end

function Sync.publish(entity, brain, status)
    if entity == nil or not Identity.isManaged(entity) then return false end
    local id = Identity.getId(entity)
    if id == nil then return false end
    local data = Identity.data(entity)
    local timestamp = Protocol.nowMs()
    local last = Sync.lastAt[id] or 0
    if timestamp - last < 500 then return false end
    Sync.lastAt[id] = timestamp
    -- FriendlySurvivorNetwork remains the compatibility transport while the
    -- wire envelope is migrated. It already validates bounded state and uses
    -- server-authoritative sendServerCommand.
    return Network.publish(entity, nil, nil,
        brain and brain.goal or "IDLE", false)
end

function Sync.snapshot(entity, brain)
    local data = Identity.data(entity)
    if data == nil or not Identity.isManaged(entity) then return nil end
    return {
        survivor_id = Identity.getId(entity),
        survivor_type = Identity.profileType(entity),
        body_generation = Identity.bodyGeneration(entity),
        body_present = true,
        goal = brain and brain.goal or "IDLE",
        task = brain and brain.taskQueue and brain.taskQueue[1]
            and brain.taskQueue[1].action or nil,
        entity_class = "ProjectZomboid/IsoZombie"
    }
end

return Sync

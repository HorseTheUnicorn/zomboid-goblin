local Config = require("GoblinSurvivor/Config")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")
local Perception = require("GoblinSurvivor/Perception")
local Protection = require("GoblinSurvivor/Protection")
local SquadManager = require("GoblinSurvivor/SquadManager")
local JobManager = require("GoblinSurvivor/JobManager")
local BaseManager = require("GoblinSurvivor/BaseManager")
local GuardManager = require("GoblinSurvivor/GuardManager")
local BuildManager = require("GoblinSurvivor/BuildManager")
local InventoryManager = require("GoblinSurvivor/InventoryManager")

local ActionExecutor = {}

local movementActions = {
    MOVE_TO = true, FOLLOW = true, FOLLOW_GOBLIN = true, SEARCH = true,
    SCAVENGE = true, LOOT_AREA = true, RETREAT = true, FLEE = true,
    GO_HOME = true, REGROUP = true, DEFEND_PLAYER = true, DEFEND_AREA = true,
    GUARD = true, PATROL = true, CLEAR_BUILDING = true, RETURN_TO_BASE = true
}

local function safeText(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
end

local function positionTask(point, action, target)
    local task = {
        action = "GoTo",
        mode = action,
        x = point.x,
        y = point.y,
        z = point.z
    }
    if action == "FOLLOW" and type(target) == "table" then
        task.target_player = target.player or target.name or target.label
    end
    return { task }
end

function ActionExecutor.execute(message, zombie)
    if type(message) ~= "table" or type(message.action) ~= "string" then
        return false, "NPC action is malformed"
    end
    if message.npc_id ~= Config.npcId then
        return false, "unknown NPC id"
    end
    if zombie == nil then
        return false, "Goblin NPC is not bound"
    end
    if not NpcAdapter.available() then
        return false, "friendly NPC adapter is unavailable"
    end
    Protection.apply(zombie)
    local action = message.action
    if action == "FORM_SQUAD" then
        return SquadManager.form(message)
    end
    if action == "DISMISS_SQUAD" then
        return SquadManager.dismiss(message)
    end
    if action == "ASSIGN_JOB" then
        return JobManager.assign(message)
    end
    if action == "SECURE_BASE" then
        return GuardManager.secure(message, zombie)
    end
    if action == "EAT" or action == "DRINK" or action == "BANDAGE" or action == "RELOAD" then
        return InventoryManager.execute(message)
    end
    if action == "CLAIM_REWARD" then
        return InventoryManager.execute(message)
    end
    if action == "NOOP" or action == "HOLD_POSITION" or action == "REST" then
        return NpcAdapter.clearTasks(zombie)
    end
    if action == "SAY" then
        if not safeText(message.text, 240) then return false, "SAY text is invalid" end
        if type(zombie.Say) ~= "function" then
            return false, "PZ NPC speech method is unavailable"
        end
        local ok = pcall(zombie.Say, zombie, message.text)
        return ok, ok and "speech accepted" or "NPC speech failed"
    end
    if action == "ATTACK" then
        local target = message.target
        local kind = type(target) == "table" and string.lower(tostring(target.kind)) or ""
        if kind ~= "nearby_threat" then
            return false, "ATTACK requires the nearby_threat semantic target"
        end
        local threat = Perception.nearestThreat(zombie)
        if threat == nil then return false, "no live hostile zombie is within the bounded combat radius" end
        return NpcAdapter.setCombatTarget(zombie, threat)
    end
    if movementActions[action] then
        local point, detail = Perception.resolveTarget(message.target, zombie)
        if point == nil then return false, detail end
        local ok, taskDetail = NpcAdapter.setTasks(
            zombie, positionTask(point, action, message.target)
        )
        return ok, taskDetail
    end
    if action == "BUILD" then return BuildManager.execute(message) end
    -- Combat, vehicles, and building work are implemented only after their
    -- exact server-side engine contract is verified.
    return false, "NPC action is not supported by the verified adapter"
end

return ActionExecutor

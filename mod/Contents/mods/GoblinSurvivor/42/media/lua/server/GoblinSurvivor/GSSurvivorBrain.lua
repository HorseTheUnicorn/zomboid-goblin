-- Deterministic survivor brain.  External AI may choose semantic goals later;
-- this module owns the local goal-to-task translation and safety fallback.
local Identity = require("GoblinSurvivor/Identity")
local Tasks = require("GoblinSurvivor/GSSurvivorTasks")
local Actions = require("GoblinSurvivor/GSSurvivorActions")

local Brain = {}

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function validGoal(goal)
    return type(goal) == "string" and #goal >= 1 and #goal <= 32
end

local function defaultState(profile)
    return {
        id = profile.id,
        type = profile.type or "COMPANION",
        role = profile.role or "companion",
        goal = profile.defaultGoal or "IDLE",
        taskQueue = {},
        leader = nil,
        squadId = nil,
        homeBase = nil,
        combatPolicy = "DEFEND",
        followPolicy = "KEEP_DISTANCE",
        lootPolicy = "NONE",
        threatCache = {},
        lastGoalChange = nowMs(),
        lastSeenPlayer = nil,
        lastSeenThreat = nil,
        externalBrain = profile.externalBrain or "NONE",
        lastUpdateAt = 0,
        lastError = nil,
        stuckRecoveries = 0
    }
end

local function saneQueue(value)
    if type(value) ~= "table" or #value > 32 then return false end
    for _, task in ipairs(value) do
        if type(task) ~= "table" or not Actions.IsKnown(task.action) then return false end
    end
    return true
end

function Brain.ensure(entity, profile)
    local data = Identity.data(entity)
    if data == nil or type(profile) ~= "table" then return nil end
    local brain = data.GSSurvivorBrain
    if type(brain) ~= "table" or not saneQueue(brain.taskQueue) then
        brain = defaultState(profile)
        data.GSSurvivorBrain = brain
    end
    brain.id = profile.id
    brain.type = profile.type or brain.type
    brain.role = profile.role or brain.role
    brain.externalBrain = profile.externalBrain or brain.externalBrain or "NONE"
    if not validGoal(brain.goal) then brain.goal = profile.defaultGoal or "IDLE" end
    if type(brain.taskQueue) ~= "table" then brain.taskQueue = {} end
    brain.task_queue = brain.taskQueue

    -- Import the pre-engine task representation once so existing bridge
    -- commands continue to work while all new tasks use the own queue.
    if #brain.taskQueue == 0 and type(data.goblin_task) == "table"
        and Actions.IsKnown(data.goblin_task.action) then
        Tasks.Add(brain, data.goblin_task)
    end
    return brain
end

function Brain.get(entity)
    local data = Identity.data(entity)
    return data ~= nil and data.GSSurvivorBrain or nil
end

function Brain.setGoal(entity, profile, goal, leader)
    local brain = Brain.ensure(entity, profile)
    if brain == nil or not validGoal(goal) then return false, "brain is unavailable" end
    Tasks.Clear(brain)
    Tasks.SetGoal(brain, goal)
    brain.leader = leader
    brain.lastGoalChange = nowMs()
    brain.lastError = nil
    return true, brain
end

function Brain.addTask(entity, profile, task)
    local brain = Brain.ensure(entity, profile)
    if brain == nil then return false, "brain is unavailable" end
    task.survivorId = profile.id
    return Tasks.Add(brain, task)
end

local function resolveTarget(task, perception)
    if type(task.target_player) == "string" and task.target_player ~= "" then
        local player = perception.playerByName(task.target_player)
        return perception.position(player)
    end
    if type(task.target_npc_id) == "string" and task.target_npc_id ~= "" then
        local body = perception.survivorById(task.target_npc_id)
        return perception.position(body)
    end
    if type(task.x) == "number" and type(task.y) == "number"
        and type(task.z) == "number" then
        return { x = task.x, y = task.y, z = task.z }
    end
    return nil
end

local function planDefault(entity, profile, brain, perception)
    if Tasks.HasTask(brain) then return true end
    local goal = string.upper(tostring(brain.goal or "IDLE"))
    if goal == "FOLLOW" or goal == "FOLLOW_PLAYER" or goal == "REGROUP" then
        if brain.leader == nil then
            local player = perception.nearestPlayer(entity, 30)
            if player ~= nil and type(player.getUsername) == "function" then
                local ok, username = pcall(function() return player:getUsername() end)
                if ok and type(username) == "string" then brain.leader = username end
            end
        end
        if brain.leader ~= nil then
            return Tasks.Add(brain, {
                action = "Follow",
                target_player = brain.leader,
                followDistance = tonumber(profile.followDistance) or 3,
                timeoutMs = 0,
                survivorId = profile.id
            })
        end
    end
    if goal == "HOLD" or goal == "IDLE" or goal == "GUARD" then
        return true
    end
    return Tasks.Add(brain, {
        action = "Idle", durationMs = 1000, survivorId = profile.id
    })
end

function Brain.update(entity, profile, adapter, perception, timestamp)
    timestamp = timestamp or nowMs()
    local brain = Brain.ensure(entity, profile)
    if brain == nil then return false, "brain state is corrupt" end
    brain.lastUpdateAt = timestamp
    planDefault(entity, profile, brain, perception)
    local task = Tasks.Peek(brain)
    if task == nil then return true, brain end
    local context = {
        resolveTarget = function(currentTask)
            return resolveTarget(currentTask, perception)
        end
    }
    local status, detail = Actions.Update(entity, task, timestamp, adapter, context)
    if status == "complete" or status == "timeout" or status == "failed" then
        Tasks.Pop(brain)
        if type(adapter.clearTasks) == "function" then
            pcall(adapter.clearTasks, entity, profile.id)
        end
        if status ~= "complete" then
            brain.lastError = detail or status
            brain.stuckRecoveries = (tonumber(brain.stuckRecoveries) or 0) + 1
            -- Safety fallback is always local and deterministic.
            Tasks.Clear(brain)
            brain.goal = "IDLE"
        end
    end
    local data = Identity.data(entity)
    if data ~= nil then
        data.goblin_goal = brain.goal
        data.gss_active_task = task.action
        data.gss_brain_last_update_at = timestamp
    end
    return true, brain
end

function Brain.snapshot(entity)
    local brain = Brain.get(entity)
    if type(brain) ~= "table" then return nil end
    return {
        id = brain.id,
        type = brain.type,
        role = brain.role,
        goal = brain.goal,
        task = brain.taskQueue and brain.taskQueue[1]
            and brain.taskQueue[1].action or nil,
        leader = brain.leader,
        squad_id = brain.squadId,
        external_brain = brain.externalBrain,
        last_error = brain.lastError,
        stuck_recoveries = tonumber(brain.stuckRecoveries) or 0
    }
end

return Brain

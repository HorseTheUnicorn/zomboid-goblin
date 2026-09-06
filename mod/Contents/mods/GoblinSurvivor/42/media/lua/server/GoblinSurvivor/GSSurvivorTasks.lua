-- Small serializable task queue owned by the GoblinSurvivor brain.
local Tasks = {}

local ALLOWED = {
    Idle = true, Wait = true, Move = true, GoTo = true, Follow = true,
    FaceTarget = true, MeleeAttack = true, Aim = true, Shoot = true,
    Reload = true, Speak = true, OpenDoor = true, ClimbFence = true,
    GetUp = true, Recover = true, Equip = true, Unequip = true, Loot = true,
    ReturnHome = true
}

local function queue(brain)
    if type(brain.taskQueue) ~= "table" then brain.taskQueue = {} end
    -- task_queue is the persisted snake_case spelling used by the runtime
    -- diagnostics; taskQueue remains the module-facing spelling.
    brain.task_queue = brain.taskQueue
    return brain.taskQueue
end

local function validTask(task)
    return type(task) == "table"
        and type(task.action) == "string"
        and ALLOWED[task.action] == true
end

function Tasks.Add(brain, task)
    if type(brain) ~= "table" or not validTask(task) then
        return false, "task is malformed"
    end
    local list = queue(brain)
    if #list >= 32 then return false, "survivor task queue is full" end
    local stored = {}
    for key, value in pairs(task) do
        if type(value) ~= "function" and type(value) ~= "userdata" then
            stored[key] = value
        end
    end
    stored.status = "queued"
    table.insert(list, stored)
    return true, stored
end

function Tasks.Peek(brain)
    if type(brain) ~= "table" then return nil end
    return queue(brain)[1]
end

function Tasks.Pop(brain)
    if type(brain) ~= "table" then return nil end
    return table.remove(queue(brain), 1)
end

function Tasks.Clear(brain)
    if type(brain) ~= "table" then return false end
    brain.taskQueue = {}
    brain.task_queue = brain.taskQueue
    return true
end

function Tasks.HasTask(brain)
    return type(brain) == "table" and #queue(brain) > 0
end

function Tasks.Count(brain)
    return type(brain) == "table" and #queue(brain) or 0
end

function Tasks.SetGoal(brain, goal)
    if type(brain) ~= "table" or type(goal) ~= "string" or #goal < 1 then
        return false
    end
    brain.goal = string.upper(goal)
    brain.lastGoalChange = os.time() * 1000
    return true
end

function Tasks.GetGoal(brain)
    return type(brain) == "table" and brain.goal or nil
end

return Tasks

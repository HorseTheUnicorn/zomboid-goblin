-- Milestone 8: persistent owner goals driven only by capability results.
--
-- A goal is an owner-issued standing order made of existing capability
-- steps (e.g. SECURE_BASE = INSPECT_BASE -> MAINTAIN_BASE -> CLOSE_CURTAINS).
-- Goals are primitive records in the owner's persistent Spawner record, so a
-- restart resumes the same step. Steps start only while the online owner is
-- idle and Goblin is following; owner movement (recall) or a nearby threat
-- (combat) interrupts the running step without counting a failure. Progress
-- and replanning are decided exclusively from the structured capability
-- result code, never from model text or elapsed time alone.
local Body = require("GoblinSurvivor/GoblinBody")
local Spawner = require("GoblinSurvivor/GoblinSpawner")

local Goals = { MAX_GOALS = 8, MAX_ATTEMPTS = 3 }

-- Only capabilities with owner-authorized prepare paths may appear here.
Goals.TEMPLATES = {
    SECURE_BASE = { steps = { "INSPECT_BASE", "MAINTAIN_BASE", "CLOSE_CURTAINS" }, priority = 4 },
    ORGANIZE_BASE = { steps = { "DELIVER", "SORT_STORAGE" }, priority = 2 },
    REPAIR_BASE = { steps = { "REPAIR_STRUCTURE" }, priority = 3 },
    VEHICLE_READY = { steps = { "VEHICLE_INSPECT", "VEHICLE_SERVICE" }, priority = 2 },
    STOCK_NAILS = { steps = { "STOCKPILE" }, priority = 1, payload = { item = "Base.Nails" } },
}
Goals.ALIASES = { SECURE = "SECURE_BASE", ORGANIZE = "ORGANIZE_BASE", SORT = "ORGANIZE_BASE",
    REPAIR = "REPAIR_BASE", VEHICLE = "VEHICLE_READY", CAR = "VEHICLE_READY", NAILS = "STOCK_NAILS" }

-- Replanning policy per standard result code.
local POLICY = {
    COMPLETE = "advance", NO_TARGET = "advance",
    MISSING_MATERIAL = "retry_long", WAITING_FOR_MATERIAL = "retry_long",
    NO_PATH = "retry", BLOCKED = "retry", TARGET_UNLOADED = "retry", TIMEOUT = "retry",
    LOCKED = "skip", UNSUPPORTED = "skip", PERMISSION_DENIED = "fail",
    INTERRUPTED = "resume", TARGET_CHANGED = "fail", ENGINE_ERROR = "fail",
}
local RETRY_MS = 120000
local RETRY_LONG_MS = 600000

local function log(text)
    if type(print) == "function" then print("[GoblinSurvivor] GOAL " .. tostring(text)) end
end

local function records(owner)
    local ok, list = pcall(Spawner.goalsForOwner, owner)
    if ok and type(list) == "table" then return list end
    return nil
end

local function save(owner, list)
    local ok, stored = pcall(Spawner.setGoalsForOwner, owner, list)
    return ok and stored == true
end

function Goals.normalize(name)
    if type(name) ~= "string" then return nil end
    local key = string.upper((string.gsub(name, "[^%a_]", "")))
    key = Goals.ALIASES[key] or key
    return Goals.TEMPLATES[key] and key or nil
end

function Goals.list(owner)
    return records(owner) or {}
end

-- Add (or re-arm) a goal. interval_minutes > 0 makes it a maintenance cycle.
function Goals.add(owner, name, intervalMinutes, now)
    local kind = Goals.normalize(name)
    if not kind then return false, "unknown goal; use secure, organize, repair, vehicle or nails" end
    local list = records(owner)
    if not list then return false, "persistent goal store unavailable" end
    intervalMinutes = tonumber(intervalMinutes) or 0
    if intervalMinutes ~= math.floor(intervalMinutes) or intervalMinutes < 0 or intervalMinutes > 1440
        or (intervalMinutes > 0 and intervalMinutes < 10) then
        return false, "repeat interval must be 10-1440 minutes"
    end
    local template = Goals.TEMPLATES[kind]
    for _, goal in ipairs(list) do
        if goal.kind == kind and goal.state ~= "DONE" and goal.state ~= "FAILED" then
            goal.interval_ms = intervalMinutes * 60000
            save(owner, list)
            return true, kind.." goal already active; repeat updated"
        end
    end
    if #list >= Goals.MAX_GOALS then
        -- Drop finished goals first.
        local kept = {}
        for _, goal in ipairs(list) do
            if goal.state ~= "DONE" and goal.state ~= "FAILED" and goal.state ~= "CANCELLED" then kept[#kept+1] = goal end
        end
        list = kept
        if #list >= Goals.MAX_GOALS then return false, "goal limit reached; cancel one first" end
    end
    local steps = {}
    for index, task in ipairs(template.steps) do
        steps[index] = { task = task, attempts = 0 }
    end
    list[#list+1] = { id = kind..":"..tostring(now or 0), kind = kind, priority = template.priority,
        state = "PENDING", step = 1, steps = steps, next_at = 0,
        interval_ms = intervalMinutes * 60000, created_at = now or 0, runs = 0 }
    if not save(owner, list) then return false, "persistent goal store unavailable" end
    log("ADDED owner="..tostring(owner).." kind="..kind.." interval_ms="..tostring(intervalMinutes * 60000))
    return true, "goal "..kind.." recorded"..(intervalMinutes > 0 and (" (every "..intervalMinutes.." min)") or "")
end

function Goals.cancel(owner, name)
    local list = records(owner)
    if not list then return false, "persistent goal store unavailable" end
    local kind = name and string.upper(name) ~= "ALL" and Goals.normalize(name) or nil
    local count = 0
    for _, goal in ipairs(list) do
        if (not kind or goal.kind == kind) and goal.state ~= "DONE" and goal.state ~= "FAILED"
            and goal.state ~= "CANCELLED" then
            goal.state = "CANCELLED"; count = count + 1
        end
    end
    save(owner, list)
    return count > 0, count > 0 and ("cancelled "..count.." goal(s)") or "no matching active goal"
end

function Goals.describe(owner)
    local parts = {}
    for _, goal in ipairs(Goals.list(owner)) do
        if goal.state ~= "CANCELLED" then
            local step = goal.steps[goal.step]
            parts[#parts+1] = string.format("%s:%s%s%s", goal.kind, goal.state,
                step and ("@"..step.task) or "", goal.last_code and ("("..goal.last_code..")") or "")
        end
    end
    return #parts > 0 and table.concat(parts, " ") or "no goals"
end

-- Highest-priority goal that is ready to run now.
function Goals.select(list, now)
    local best
    for _, goal in ipairs(list) do
        local ready = (goal.state == "PENDING" or goal.state == "WAITING") and (goal.next_at or 0) <= now
        if goal.state == "DONE" and (goal.interval_ms or 0) > 0 and (goal.next_at or 0) <= now then
            -- Maintenance cycle: re-arm from the first step.
            goal.state, goal.step = "PENDING", 1
            for _, step in ipairs(goal.steps) do step.attempts = 0 end
            ready = true
        end
        if ready and (not best or goal.priority > best.priority
            or (goal.priority == best.priority and (goal.created_at or 0) < (best.created_at or 0))) then
            best = goal
        end
    end
    return best
end

local function findActive(list, id)
    for _, goal in ipairs(list) do
        if goal.id == id and goal.state == "ACTIVE" then return goal end
    end
    return nil
end

-- Called by Autonomy each brain tick while the owner is online.
-- setTask is Brain.setTask (passed in to avoid a require cycle).
function Goals.tick(body, setTask, context, now)
    local data = Body.data(body)
    if not data then return false end
    local owner = Body.owner(body)
    local list = records(owner)
    if not list then return false end
    local activeId = data.GoblinGoalActive
    if activeId then
        local goal = findActive(list, activeId)
        if not goal or data.GoblinTaskPayload == nil or data.GoblinTaskPayload.goal_id ~= activeId then
            -- The owner replaced the job with another order: park the goal.
            if goal then goal.state = "WAITING"; goal.next_at = now; save(owner, list) end
            data.GoblinGoalActive = nil
            return false
        end
        if context.threat or context.recalled then
            goal.state, goal.next_at = "WAITING", now + 5000
            goal.last_code = context.threat and "INTERRUPTED_COMBAT" or "INTERRUPTED_RECALL"
            local step = goal.steps[goal.step]
            if step then step.attempts = math.max(0, (step.attempts or 1) - 1) end
            data.GoblinGoalActive = nil
            save(owner, list)
            log("INTERRUPT owner="..tostring(owner).." kind="..goal.kind.." reason="..goal.last_code)
            setTask(body, "FOLLOW", { owner = owner })
            return true
        end
        return true -- the step's capability is running
    end
    if not context.idle or context.threat or data.GoblinTask ~= "FOLLOW" then return false end
    local goal = Goals.select(list, now)
    if not goal then save(owner, list); return false end
    local step = goal.steps[goal.step]
    if not step then goal.state = "DONE"; save(owner, list); return false end
    local template = Goals.TEMPLATES[goal.kind] or {}
    local payload = { explicit_owner_order = true, goal_id = goal.id }
    for key, value in pairs(template.payload or {}) do payload[key] = value end
    local ok, detail = setTask(body, step.task, payload)
    if not ok then
        -- Preparation refusal is itself a deterministic result.
        Goals.onResult(body, step.task, { done = true, success = false,
            code = "NO_TARGET_PREPARE", detail = tostring(detail) }, now, goal.id)
        return false
    end
    goal.state = "ACTIVE"
    step.attempts = (step.attempts or 0) + 1
    data.GoblinGoalActive = goal.id
    save(owner, list)
    log("STEP owner="..tostring(owner).." kind="..goal.kind.." step="..step.task.." attempt="..step.attempts)
    return true
end

-- Called by Brain when a capability job reaches a terminal result.
function Goals.onResult(body, task, result, now, goalId)
    local data = Body.data(body)
    local owner = Body.owner(body)
    goalId = goalId or (data and data.GoblinGoalActive)
    if not goalId then return false end
    local list = records(owner)
    if not list then return false end
    local goal
    for _, candidate in ipairs(list) do if candidate.id == goalId then goal = candidate end end
    if data and data.GoblinGoalActive == goalId then data.GoblinGoalActive = nil end
    if not goal or goal.state == "CANCELLED" then return false end
    local step = goal.steps[goal.step]
    if not step or step.task ~= task then return false end
    local code = result.code
    local policy = POLICY[code]
    -- A step whose prepare refuses ("nothing to sort", "no vehicle nearby")
    -- is treated as nothing-to-do once, then as a retryable block.
    if code == "NO_TARGET_PREPARE" then policy = (step.attempts or 0) >= 1 and "retry" or "advance" end
    goal.last_code, goal.last_detail = code, string.sub(tostring(result.detail or ""), 1, 160)
    if policy == "advance" or policy == "skip" then
        goal.step = goal.step + 1
        goal.state = "PENDING"
        goal.next_at = now
        if not goal.steps[goal.step] then
            goal.runs = (goal.runs or 0) + 1
            goal.state = "DONE"
            goal.next_at = (goal.interval_ms or 0) > 0 and now + goal.interval_ms or 0
        end
    elseif policy == "resume" then
        goal.state, goal.next_at = "WAITING", now + 5000
        step.attempts = math.max(0, (step.attempts or 1) - 1)
    elseif policy == "retry" or policy == "retry_long" then
        if (step.attempts or 0) >= Goals.MAX_ATTEMPTS then
            goal.state = "FAILED"
        else
            goal.state = "WAITING"
            goal.next_at = now + (policy == "retry_long" and RETRY_LONG_MS or RETRY_MS)
        end
    else
        goal.state = "FAILED"
    end
    save(owner, list)
    log("RESULT owner="..tostring(owner).." kind="..goal.kind.." step="..task.." code="..tostring(code)
        .." state="..goal.state)
    return true
end

return Goals

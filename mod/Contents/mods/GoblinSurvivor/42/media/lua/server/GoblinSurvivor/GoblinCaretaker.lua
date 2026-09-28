-- Caretaker: the home upkeep Goblin does on his own, as the owner's
-- companion, with no orders -- and keeps doing while the owner is away.
--
-- Duties (checked against the real world, highest priority first):
--   power    : base generator missing/stopped/low on fuel/damaged -> RESTORE_POWER
--   farm     : living crops by the base needing water or ready  -> FARM tend
--   curtains : after dusk, open curtains in the base house       -> CLOSE_CURTAINS
--   traps    : traps near the base, every 12 game hours          -> CHECK_TRAPS
-- (Boarding windows, salvage and looting stay in GoblinAutonomy.)
--
-- Each duty has a game-hour check interval and backs off after a failure,
-- so an impossible duty never loops. Duty payloads carry caretaker=true,
-- which only this server module sets (never accepted from the network).
--
-- Catch-up: if Goblin's area was unloaded (nobody near) for several game
-- hours, the first tick back waters the base crops and tops up the base
-- generator at once, and he tells his owner what he did while they were gone.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")

local Caretaker = { state = setmetatable({}, { __mode = "k" }), CATCHUP_HOURS = 6,
    RADIUS = World.range and World.range() or 150, SEARCH_BUDGET = 12000, NONE_RECHECK_MS = 600000 }
local call = World.call

local function gameHours()
    if type(getGameTime) ~= "function" then return 0 end
    local ok, time = pcall(getGameTime)
    if not ok or not time then return 0 end
    local okHours, hours = pcall(time.getWorldAgeHours, time)
    return okHours and tonumber(hours) or 0
end

local function hourOfDay()
    if type(getGameTime) ~= "function" then return 12 end
    local ok, time = pcall(getGameTime)
    if not ok or not time then return 12 end
    local okHour, hour = pcall(time.getHour, time)
    return okHour and tonumber(hour) or 12
end

function Caretaker.base(body)
    local data = Body.data(body)
    if not data or data.GoblinBaseSet ~= true then return nil end
    local x, y, z = tonumber(data.GoblinBaseX), tonumber(data.GoblinBaseY), tonumber(data.GoblinBaseZ)
    if not x or not y or not z then return nil end
    return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

local function num(object, method)
    local ok, value = call(object, method)
    return ok and tonumber(value) or nil
end

local function gridPowerOn()
    local world = type(getWorld) == "function" and getWorld() or nil
    local ok, on = call(world, "isHydroPowerOn")
    return ok and on == true
end

-- Current needs of the homestead (also reported to Goblin's mind).
function Caretaker.survey(body, base, state, now)
    state = state or {}
    now = now or 0
    local report = { power = "unknown", farm = {}, traps = 0, open_curtains = 0 }
    local okP, Power = pcall(require, "GoblinSurvivor/GoblinPower")
    if okP then
        -- The wide generator search is spread over surveys; "none" is cached.
        local generator, searched = Power.knownGenerator(body), true
        if not generator and now >= (state.genNoneUntil or 0) then
            state.genSearch = state.genSearch or {}
            generator, searched = Power.findGenerator(body, base, Caretaker.RADIUS, state.genSearch,
                Caretaker.SEARCH_BUDGET)
            if searched then
                state.genSearch = nil
                if not generator then state.genNoneUntil = now + Caretaker.NONE_RECHECK_MS end
            end
        end
        if not searched then
            report.power = "checking"
        elseif generator then
            local fuel, maximum = num(generator, "getFuel") or 0, num(generator, "getMaxFuel") or 100
            local running = select(2, call(generator, "isActivated")) == true
            local condition = num(generator, "getCondition") or 100
            report.generator = { fuel_pct = maximum > 0 and math.floor(100 * fuel / maximum) or 0,
                running = running, condition = condition }
            report.power = (running and fuel > 0) and "generator" or "generator_down"
            report.power_needs_work = not running or fuel < maximum * 0.5 or condition < 70
        elseif gridPowerOn() then
            report.power = "grid"
        else
            report.power = "none"
            report.power_needs_work = true
        end
    end
    local okF, Farm = pcall(require, "GoblinSurvivor/GoblinFarming")
    if okF and type(Farm.needs) == "function" then report.farm = Farm.needs(base, Caretaker.RADIUS) end
    local okL, Life = pcall(require, "GoblinSurvivor/GoblinSurvivalLife")
    if okL and type(Life.trapsNear) == "function" then
        local ok, traps = pcall(Life.trapsNear, base)
        report.traps = ok and #traps or 0
    end
    local okC, Curtains = pcall(require, "GoblinSurvivor/GoblinCurtains")
    if okC then
        local scope = Curtains.scopeAt({ x = base.x + 0.5, y = base.y + 0.5, z = base.z })
        if scope and type(Curtains.openCount) == "function" then report.open_curtains = Curtains.openCount(scope) end
    end
    return report
end

-- Duty table: interval (game hours between checks), due(report, hour).
Caretaker.DUTIES = {
    { name = "power", task = "RESTORE_POWER", every = 1,
      due = function(r) return r.power_needs_work == true end },
    { name = "farm", task = "FARM", every = 2, payload = { job = "tend" },
      due = function(r) return (r.farm.water or 0) + (r.farm.harvest or 0) > 0 end },
    { name = "curtains", task = "CLOSE_CURTAINS", every = 3,
      due = function(r, hour) return (hour >= 20 or hour < 6) and (r.open_curtains or 0) > 0 end },
    { name = "traps", task = "CHECK_TRAPS", every = 12,
      due = function(r) return (r.traps or 0) > 0 end },
}
Caretaker.BACKOFF_HOURS = 3

local function stateFor(body)
    local state = Caretaker.state[body]
    if not state then state = { nextCheck = {}, backoff = {} }; Caretaker.state[body] = state end
    return state
end

-- A caretaker job finished: back off a failing duty.
function Caretaker.onResult(body, task, result)
    local state = Caretaker.state[body]
    if not state or type(result) ~= "table" then return end
    for _, duty in ipairs(Caretaker.DUTIES) do
        if duty.task == task and result.success ~= true then
            state.backoff[duty.name] = gameHours() + Caretaker.BACKOFF_HOURS
        end
    end
end

-- Choose and start the next due duty. Returns true when a job started.
function Caretaker.tick(body, setTask, now)
    local base = Caretaker.base(body)
    if not base then return false end
    local data = Body.data(body)
    local state = stateFor(body)
    local hours = gameHours()
    Caretaker.catchUp(body, base, hours)
    if now < (state.nextSurveyAt or 0) then return false end
    state.nextSurveyAt = now + 20000
    local ok, report = pcall(Caretaker.survey, body, base, state, now)
    if not ok or type(report) ~= "table" then return false end
    data.GoblinHomestead = {
        power = report.power, generator = report.generator, plants = report.farm.plants or 0,
        plants_need_water = report.farm.water or 0, plants_ready = report.farm.harvest or 0,
        traps = report.traps, open_curtains = report.open_curtains }
    local hour = hourOfDay()
    for _, duty in ipairs(Caretaker.DUTIES) do
        local ready = hours >= (state.nextCheck[duty.name] or 0) and hours >= (state.backoff[duty.name] or 0)
        if ready and duty.due(report, hour) then
            state.nextCheck[duty.name] = hours + duty.every
            local payload = { caretaker = true }
            for key, value in pairs(duty.payload or {}) do payload[key] = value end
            local started = setTask(body, duty.task, payload)
            print("[GoblinSurvivor] CARETAKER owner=" .. tostring(Body.owner(body)) .. " duty=" .. duty.name
                .. " started=" .. tostring(started == true))
            if started then
                data.GoblinLastAutonomyAction = "CARETAKER_" .. string.upper(duty.name)
                data.GoblinCaretakerTask = duty.task
                return true
            end
            state.backoff[duty.name] = hours + Caretaker.BACKOFF_HOURS
        end
    end
    return false
end

-- While nobody was near, Goblin kept the homestead going.
function Caretaker.catchUp(body, base, hours)
    local data = Body.data(body)
    local last = tonumber(data.GoblinCaretakerSeenHour)
    data.GoblinCaretakerSeenHour = hours
    if not last or hours - last < Caretaker.CATCHUP_HOURS then return nil end
    local done = {}
    local okF, Farm = pcall(require, "GoblinSurvivor/GoblinFarming")
    if okF and type(Farm.waterAll) == "function" then
        local watered = Farm.waterAll(base, Caretaker.RADIUS)
        if watered > 0 then done[#done + 1] = "watered " .. watered .. " plant(s)" end
    end
    local okP, Power = pcall(require, "GoblinSurvivor/GoblinPower")
    local okV, Provision = pcall(require, "GoblinSurvivor/GoblinProvision")
    if okP and okV and Provision.enabled() then
        local generator = Power.knownGenerator(body)
        if generator then
            local fuel, maximum = num(generator, "getFuel") or 0, num(generator, "getMaxFuel") or 100
            if fuel < maximum then
                call(generator, "setFuel", maximum)
                call(generator, "sync")
                done[#done + 1] = "refilled the generator"
            end
        end
    end
    local away = math.floor(hours - last)
    print("[GoblinSurvivor] CARETAKER_CATCHUP owner=" .. tostring(Body.owner(body)) .. " hours=" .. away
        .. " did=" .. table.concat(done, "; "))
    if #done > 0 then
        data.GoblinCaretakerReport = "While you were away (" .. away .. "h) I " .. table.concat(done, " and ") .. "."
    end
    return done
end

return Caretaker

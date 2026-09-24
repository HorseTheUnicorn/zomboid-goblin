-- Deterministic base-maintenance planner. Only the existing, material-backed
-- wooden-window barricade path may mutate the world at present. Other defects
-- remain explicit partial results until their native child adapters exist.
local Body = require("GoblinSurvivor/GoblinBody")
local Inspect = require("GoblinSurvivor/GoblinBaseInspect")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Work = require("GoblinSurvivor/GoblinWork")

local Maintain = {}

local function summary(report)
    return string.format("%d windows still need boards, %d damaged structures, %d broken windows, %d open exterior doors",
        report.unbarricaded_windows or 0, report.damaged_structures or 0,
        report.broken_windows or 0, report.open_exterior_doors or 0)
end

function Maintain.prepare(body, owner)
    local payload, why = Inspect.prepare(body, owner)
    if not payload then return nil, why end
    return payload, "base maintenance queued; I will inspect before any work"
end

function Maintain.update(body, payload, runtime, now)
    if runtime.phase == nil then
        runtime.inspection = runtime.inspection or {}
        local done, success, detail, code = Inspect.update(body, payload, runtime.inspection, now)
        if not done then return false end
        if not success then return true, false, detail, code end
        local report = Body.data(body).GoblinBaseReport
        if not report or report.building_id ~= payload.building_id or report.stale then
            return true, false, "base survey became stale", "TARGET_CHANGED"
        end
        if (report.unbarricaded_windows or 0) == 0 then
            return true, false, "inspection finished; no supported window work. "
                .. summary(report) .. "; other maintenance remains unimplemented", "UNSUPPORTED"
        end
        runtime.phase = "FORTIFY_WINDOWS"
        runtime.before = report.unbarricaded_windows
        return false
    end
    if runtime.phase ~= "FORTIFY_WINDOWS" then
        return true, false, "unknown maintenance phase; job stopped", "TARGET_CHANGED"
    end
    local workDone, workCode = Work.update(body, "FORTIFY_BASE", {}, now)
    if not workDone then return false end
    local scope = Curtains.scopeAt(payload.anchor)
    if not scope or scope.id ~= payload.building_id then
        return true, false, "base house changed or unloaded after work", "TARGET_UNLOADED"
    end
    local report, why, code = Inspect.scan(scope, body, now)
    if not report then return true, false, why, code end
    Body.data(body).GoblinBaseReport = report
    local boarded = math.max(0, (runtime.before or 0) - (report.unbarricaded_windows or 0))
    if workCode == "MISSING_MATERIAL" then
        return true, false, string.format("maintenance stopped for missing materials: %d windows fully boarded; %s",
            boarded, summary(report)), "MISSING_MATERIAL"
    end
    -- Never report whole-base success while stock thresholds, repairs, or
    -- partially streamed rooms lack a verified implementation/observation.
    return true, false, string.format("maintenance partial: %d windows boarded; %s; supply thresholds unconfigured",
        boarded, summary(report)), "UNSUPPORTED"
end

function Maintain.clear(body)
    Work.clear(body)
    Inspect.clear(body)
end

return Maintain

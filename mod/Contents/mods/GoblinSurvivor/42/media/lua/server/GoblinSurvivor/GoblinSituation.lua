-- Coarse situation report for Qwen's free-will thinking and conversation.
--
-- Everything here is a label, bucket or count: no coordinates, object IDs or
-- raw engine objects ever leave this module. It is attached to each online
-- companion in runtime.state (GoblinTelemetry) and rebuilt at most every
-- few seconds. A small per-Goblin event log (sequence-numbered) lets the
-- agent notice what just happened and remember it.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")

local Situation = { cache = setmetatable({}, { __mode = "k" }), events = {}, seq = {}, last = {} }
local call = World.call
local MAX_EVENTS = 16
local REBUILD_MS = 4000

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

local function num(object, method, ...)
    local ok, value = call(object, method, ...)
    if ok and type(value) == "number" and value == value then return value end
    return nil
end

local function bucket(value, low, high, names)
    if value == nil then return "unknown" end
    if value < low then return names[1] end
    if value < high then return names[2] end
    return names[3]
end

-- Record a notable event for a Goblin (npc id keyed so it survives rebinds).
function Situation.note(body, kind, text)
    local id = Body.npcId(body)
    if type(id) ~= "string" then return end
    local log = Situation.events[id] or {}
    Situation.seq[id] = (Situation.seq[id] or 0) + 1
    log[#log+1] = { seq = Situation.seq[id], kind = tostring(kind), text = string.sub(tostring(text), 1, 160),
        at = nowMs() }
    while #log > MAX_EVENTS do table.remove(log, 1) end
    Situation.events[id] = log
end

local function ownerPlayer(body)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return nil end
    local owner = string.lower(tostring(Body.owner(body)))
    for _, player in ipairs(World.values(players)) do
        local _, name = call(player, "getUsername")
        if type(name) == "string" and string.lower(name) == owner then return player end
    end
    return nil
end

local function stat(player, name, legacy)
    local stats = select(2, call(player, "getStats"))
    local enum = rawget(_G, "CharacterStat")
    if stats and enum and enum[name] then
        local value = num(stats, "get", enum[name])
        if value then return value end
    end
    return legacy and num(stats, legacy) or nil
end

local DIRECTIONS = { "east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east" }
local function direction(dx, dy)
    local angle = math.atan2 and math.atan2(dy, dx) or math.atan(dy, dx)
    local index = math.floor(((angle / (2 * math.pi)) * 8) + 0.5) % 8
    return DIRECTIONS[index + 1]
end

local function threats(body, point)
    local cell = type(getCell) == "function" and getCell() or nil
    local list = World.values(select(2, call(cell, "getZombieList")))
    local near, around, nearest, nearestD = 0, 0, nil, nil
    for _, zombie in ipairs(list) do
        if zombie ~= body and not Body.isGoblin(zombie) and select(2, call(zombie, "isDead")) ~= true then
            local p = Body.position(zombie)
            if p and math.floor(p.z) == math.floor(point.z) then
                local d = (p.x - point.x)^2 + (p.y - point.y)^2
                if d <= 100 then near = near + 1 end
                if d <= 900 then
                    around = around + 1
                    if not nearestD or d < nearestD then nearest, nearestD = p, d end
                end
            end
        end
    end
    local result = { within_10_tiles = near, within_30_tiles = around,
        level = near >= 8 and "horde" or near >= 3 and "several" or near >= 1 and "a few" or around > 0 and "distant" or "clear" }
    if nearest then result.nearest_direction = direction(nearest.x - point.x, nearest.y - point.y) end
    return result
end

local function place(point)
    local square = World.square(point)
    local room = select(2, call(square, "getRoom"))
    local def = room and (select(2, call(room, "getRoomDef")) or room)
    local name = def and select(2, call(def, "getName"))
    local outside = select(2, call(square, "isOutside"))
    return { room = type(name) == "string" and string.lower(name) or nil,
        outdoors = outside == true or (outside == nil and name == nil) }
end

local function ownerState(player, id)
    if not player then return { online = false } end
    local damage = select(2, call(player, "getBodyDamage"))
    local health = num(damage, "getOverallBodyHealth")
    local bleeding, wounds, bitten = 0, 0, 0
    for _, part in ipairs(World.values(select(2, call(damage, "getBodyParts")))) do
        if (num(part, "getBleedingTime") or 0) > 0 then bleeding = bleeding + 1 end
        if select(2, call(part, "bitten")) == true then bitten = bitten + 1 end
        if select(2, call(part, "bandaged")) ~= true and (select(2, call(part, "scratched")) == true
            or select(2, call(part, "isCut")) == true or select(2, call(part, "deepWounded")) == true
            or select(2, call(part, "bitten")) == true) then wounds = wounds + 1 end
    end
    local previous = Situation.last[id]
    Situation.last[id] = health
    return {
        online = true,
        health = bucket(health, 40, 80, { "badly hurt", "hurt", "healthy" }),
        health_drop = previous and health and previous - health >= 15 or false,
        bleeding_parts = bleeding,
        bitten_parts = bitten,
        unbandaged_wounds = wounds,
        hunger = bucket(stat(player, "HUNGER", "getHunger"), 0.25, 0.5, { "fed", "peckish", "hungry" }),
        thirst = bucket(stat(player, "THIRST", "getThirst"), 0.25, 0.5, { "fine", "thirsty", "parched" }),
        fatigue = bucket(stat(player, "FATIGUE", "getFatigue"), 0.4, 0.7, { "rested", "tired", "exhausted" }),
        panic = bucket(stat(player, "PANIC", "getPanic"), 20, 60, { "calm", "nervous", "panicking" }),
        in_vehicle = select(2, call(player, "getVehicle")) ~= nil,
    }
end

local function inventory(body)
    local ok, Storage = pcall(require, "GoblinSurvivor/GoblinStorage")
    local counts, total = {}, 0
    for _, item in ipairs(World.items(World.inventory(body))) do
        total = total + 1
        if ok then
            local category = Storage.category(item)
            if category then counts[string.lower(category)] = (counts[string.lower(category)] or 0) + 1 end
        end
    end
    return { carried_by_category = counts, total_items = total }
end

local function base(body)
    local data = Body.data(body) or {}
    if data.GoblinBaseSet ~= true then return { set = false } end
    local report = type(data.GoblinBaseReport) == "table" and data.GoblinBaseReport or {}
    local result = { set = true, windows_needing_boards = report.unbarricaded_windows,
        damaged_structures = report.damaged_structures, broken_windows = report.broken_windows,
        open_exterior_doors = report.open_exterior_doors, report_stale = report.stale == true }
    local okS, Stockpiles = pcall(require, "GoblinSurvivor/GoblinStockpiles")
    local okC, Curtains = pcall(require, "GoblinSurvivor/GoblinCurtains")
    if okS and okC then
        local scope = Curtains.scopeAt({ x = data.GoblinBaseX, y = data.GoblinBaseY, z = data.GoblinBaseZ })
        if scope then
            local okScan, scan = pcall(Stockpiles.scan, scope, body)
            if okScan and type(scan) == "table" and type(scan.items) == "table" then
                local short = {}
                for _, row in ipairs(scan.items) do
                    if (row.shortage or 0) > 0 then short[#short+1] = row.item.." short "..row.shortage end
                end
                result.stock_shortages = short
            end
        end
    end
    local bodyPoint, basePoint = Body.position(body), { x = data.GoblinBaseX, y = data.GoblinBaseY }
    if bodyPoint and basePoint.x then
        local d = math.sqrt((bodyPoint.x - basePoint.x)^2 + (bodyPoint.y - basePoint.y)^2)
        result.distance = d < 15 and "at base" or d < 80 and "nearby" or d < 300 and "a walk away" or "far"
    end
    return result
end

local function vehicle(point)
    local ok, Service = pcall(require, "GoblinSurvivor/GoblinVehicleService")
    if not ok then return nil end
    local found = Service.nearestVehicle(point)
    if not found then return nil end
    local okReport, report = pcall(Service.report, found)
    if not okReport then return nil end
    return { summary = Service.summary(report) }
end

local function nearbyGoblins(body, point)
    local ok, Spawner = pcall(require, "GoblinSurvivor/GoblinSpawner")
    if not ok or type(Spawner.allBodies) ~= "function" then return {} end
    local result = {}
    for _, other in ipairs(Spawner.allBodies() or {}) do
        if other ~= body and Body.isGoblin(other) then
            local p = Body.position(other)
            if p and math.floor(p.z) == math.floor(point.z) and (p.x - point.x)^2 + (p.y - point.y)^2 <= 144 then
                local data = Body.data(other) or {}
                result[#result+1] = { npc_id = Body.npcId(other), name = data.GoblinName, owner = Body.owner(other),
                    task = data.GoblinTask }
            end
        end
    end
    return result
end

function Situation.build(body)
    local now = nowMs()
    local cached = Situation.cache[body]
    if cached and now - cached.at < REBUILD_MS then return cached.value end
    local point = Body.position(body)
    if not point then return nil end
    local id = Body.npcId(body)
    if type(id) ~= "string" then return nil end
    local data = Body.data(body) or {}
    local gameTime = type(getGameTime) == "function" and getGameTime() or nil
    local climate = type(getClimateManager) == "function" and getClimateManager() or nil
    local hour = num(gameTime, "getHour")
    local rain = num(climate, "getRainIntensity")
    local player = ownerPlayer(body)
    local report = {
        time = { hour = hour, period = hour and (hour < 5 and "night" or hour < 8 and "dawn" or hour < 12 and "morning"
            or hour < 17 and "afternoon" or hour < 21 and "evening" or "night") or "unknown",
            day = num(gameTime, "getNightsSurvived") },
        weather = { rain = bucket(rain, 0.05, 0.5, { "dry", "drizzle", "pouring" }),
            fog = bucket(num(climate, "getFogIntensity"), 0.2, 0.6, { "clear", "hazy", "foggy" }),
            temperature = num(climate, "getTemperature") and math.floor(num(climate, "getTemperature") + 0.5) or nil },
        threats = threats(body, point),
        place = place(point),
        owner = ownerState(player, id),
        base = base(body),
        goblin = { task = data.GoblinTask, work_status = data.GoblinWorkStatus, kills = tonumber(data.GoblinKills) or 0,
            last_result = type(data.GoblinLastJobResult) == "table" and {
                task = data.GoblinLastJobResult.task, code = data.GoblinLastJobResult.code,
                detail = data.GoblinLastJobResult.detail } or nil,
            freewill = data.GoblinFreewillEnabled == true, freewill_job = data.GoblinFreewill == true },
        inventory = inventory(body),
        vehicle = vehicle(point),
        nearby_goblins = nearbyGoblins(body, point),
    }
    local okGoals, Goals = pcall(require, "GoblinSurvivor/GoblinGoals")
    if okGoals then report.goblin.goals = Goals.describe(Body.owner(body)) end
    if report.owner.health_drop then Situation.note(body, "owner_hurt", "owner took a bad hit") end
    local kills = report.goblin.kills
    local previousKills = Situation.last[id..":kills"]
    Situation.last[id..":kills"] = kills
    if previousKills and kills > previousKills then Situation.note(body, "kills", (kills - previousKills).." zombie(s) put down") end
    local previousLevel = Situation.last[id..":threat"]
    Situation.last[id..":threat"] = report.threats.level
    if report.threats.level == "horde" and previousLevel ~= "horde" then
        Situation.note(body, "horde", "a horde closed in"..(report.threats.nearest_direction
            and (" from the "..report.threats.nearest_direction) or ""))
    end
    report.events = {}
    for _, event in ipairs(Situation.events[id] or {}) do
        report.events[#report.events+1] = { seq = event.seq, kind = event.kind, text = event.text }
    end
    Situation.cache[body] = { at = now, value = report }
    return report
end

return Situation

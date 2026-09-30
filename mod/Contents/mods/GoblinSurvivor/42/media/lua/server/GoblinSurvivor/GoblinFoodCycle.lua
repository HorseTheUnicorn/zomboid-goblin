-- Autonomous, measured food restocking. This is a goal controller, not a new
-- engine action: all movement/custody/cooking runs through existing jobs.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Storage = require("GoblinSurvivor/GoblinStorage")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Transfer = require("GoblinSurvivor/GoblinTransfer")
local Config = require("GoblinSurvivor/Config")
local Food = { RETRY_MS = 600000, MAX_ROUNDS = 3 }
local call = World.call

-- Fail closed on missing native Food methods. A display category is not
-- evidence that something is edible. These are the installed vanilla APIs
-- used by inventory/eating/foraging code, including isbDangerousUncooked.
function Food.classify(item)
    if type(instanceof) ~= "function" or not instanceof(item, "Food") then return nil end
    local ok, hunger = call(item, "getHungerChange")
    if not ok or type(hunger) ~= "number" or hunger >= -0.01 then return nil end
    local poisonOK, poison = call(item, "getPoisonPower")
    local rottenOK, rotten = call(item, "isRotten")
    local burntOK, burnt = call(item, "isBurnt")
    local spiceOK, spice = call(item, "isSpice")
    if not poisonOK or type(poison) ~= "number" or poison > 0 or not rottenOK or rotten
        or not burntOK or burnt or not spiceOK or spice then return nil end
    local cookOK, cookable = call(item, "isCookable")
    local cookedOK, cooked = call(item, "isCooked")
    local dangerOK, dangerous = call(item, "isbDangerousUncooked")
    if not cookOK or not cookedOK or not dangerOK then return nil end
    if cookable and not cooked then return "raw" end
    if dangerous and not cooked then return nil end
    return "ready"
end

function Food.carried(body, kind)
    local ids = {}
    for _, item in ipairs(World.items(World.inventory(body))) do
        if Food.classify(item) == kind and Transfer.movable(body, item) then
            local id = Transfer.itemId(item)
            if id then ids[#ids+1] = id end
        end
    end
    return ids
end

local function destination(target)
    return target.category == "FOOD" or target.category == "OVERFLOW" or target.category == "INBOX"
end

function Food.scan(body)
    local report = { known=false, ready=0, raw=0,
        target=math.max(1, math.min(10, tonumber(Config.foodReserveItems) or 4)) }
    local data = Body.data(body) or {}
    if not data.GoblinBaseSet then report.reason="NO_BASE"; return report end
    local scope = Curtains.scopeAt({x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ})
    if not scope then report.reason="TARGET_UNLOADED"; return report end
    local live, failures = Storage.assignments(body, scope)
    -- Never infer a shortage from an unreadable or partially loaded registry.
    if not live or #(failures or {}) > 0 then report.reason="TARGET_UNLOADED"; return report end
    local destinations = 0
    report.ids = {}
    report.ready_ids = {}
    for _, target in ipairs(live) do
        if destination(target) then
            destinations = destinations + 1
            local readable, contents = call(target.container, "getItems")
            if not readable or not contents then report.reason="TARGET_UNLOADED"; return report end
            for _, item in ipairs(World.items(target.container)) do
                local kind, id = Food.classify(item), Transfer.itemId(item)
                if kind and id and not report.ids[id] then
                    report.ids[id] = target.id
                    report[kind] = report[kind] + 1
                    if kind == "ready" then report.ready_ids[id] = target.id end
                end
            end
        end
    end
    if destinations == 0 then report.reason="NO_FOOD_STORAGE"; return report end
    report.known, report.shortage = true, math.max(0, report.target-report.ready)
    return report
end

local function note(body, goal, text)
    goal.last_detail = text
    pcall(function() require("GoblinSurvivor/GoblinSituation").note(body,"survival",text) end)
    Body.say(body, "Comrade, "..text)
end

function Food.finish(body, goal, scan, now)
    goal.state, goal.last_code = "DONE", "VERIFIED_FOOD_STORED"
    goal.runs, goal.next_at = (goal.runs or 0)+1, now+Food.RETRY_MS
    goal.food.stored = scan.ready
    note(body,goal,"food reserve verified: "..scan.ready.." usable item(s) in base storage.")
end

function Food.block(body, goal, code, detail, now)
    goal.state, goal.last_code, goal.next_at = "WAITING", code, now+Food.RETRY_MS
    goal.food.rounds = 0
    note(body,goal,"food run blocked: "..tostring(detail)..". I will retry later.")
end

-- Re-evaluate after every job/interrupt, never advance on a spoken claim.
function Food.next(body, goal, now)
    goal.food = goal.food or { rounds=0 }
    local scan = Food.scan(body)
    if not scan.known then
        if scan.reason=="NO_FOOD_STORAGE" then
            note(body,goal,"no food storage. I will build a crate at our base.")
            return "PREPARE_FOOD_STORAGE",{food_cycle=true}
        end
        Food.block(body,goal,scan.reason,"base food storage is unavailable",now)
        return nil
    end
    if not goal.food.noticed and scan.shortage > 0 then
        goal.food.noticed = true
        note(body,goal,"food reserve is low. I will gather, cook when needed, and store supplies.")
    end
    local ready = Food.carried(body,"ready")
    if scan.shortage == 0 and #ready == 0 then
        Food.finish(body,goal,scan,now)
        return nil
    end
    if #ready > 0 then
        goal.food.delivery_ids = ready -- Deliver consumes its open ledger as it progresses.
        return "DELIVER", { item="FOOD", selected_ids=ready, food_cycle=true }
    end
    if (goal.food.rounds or 0) >= Food.MAX_ROUNDS then
        Food.block(body,goal,"WAITING_FOR_MATERIAL","not enough usable food found",now)
        return nil
    end
    -- Native cooking gathers only actual raw items, not fabricated supplies.
    local raw = function(item) return Food.classify(item) == "raw" end
    local data = Body.data(body)
    local home = {x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ}
    if (goal.food.avoid_cook_until or 0) <= now and
        (#Food.carried(body,"raw") > 0 or #World.sources(home,12,raw,body) > 0) then
        return "COOK", { count=math.min(5,math.max(1,scan.shortage)), food_only=true, food_cycle=true }
    end
    return "FORAGE", { count=math.min(10,math.max(1,scan.shortage)), food_only=true, food_cycle=true }
end

function Food.onResult(body,goal,task,result,now,payload)
    goal.food = goal.food or { rounds=0 }
    goal.last_code, goal.last_detail = result.code, tostring(result.detail or "")
    if result.code == "INTERRUPTED" then
        goal.state, goal.next_at = "WAITING", now+5000
        return
    end
    if result.success == true and result.code == "COMPLETE" then
        if task=="PREPARE_FOOD_STORAGE" and not Food.scan(body).known then
            Food.block(body,goal,"TARGET_CHANGED","new food storage could not be verified",now)
            return
        end
        if task == "DELIVER" then
            local scan = Food.scan(body)
            local delivered = 0
            local selected = goal.food.delivery_ids or {}
            for _, id in ipairs(selected) do
                if scan.ready_ids and scan.ready_ids[id]
                    and Transfer.findById(World.inventory(body),id) == false then delivered=delivered+1 end
            end
            -- The cargo must be present as usable food in real storage, and
            -- absent from the actor, even when the job reported COMPLETE.
            if not scan.known or delivered == 0 or delivered ~= #selected then
                Food.block(body,goal,"TARGET_CHANGED","food deposit could not be verified",now)
                return
            end
            goal.food.delivered = (goal.food.delivered or 0)+delivered
            if scan.shortage == 0 then Food.finish(body,goal,scan,now); return end
        end
        if task == "FORAGE" or task == "COOK" then goal.food.rounds=(goal.food.rounds or 0)+1 end
        goal.state, goal.next_at = "PENDING", now
        return
    end
    if task == "COOK" and result.code ~= "PERMISSION_DENIED" and result.code ~= "ENGINE_ERROR" then
        goal.food.avoid_cook_until = now+Food.RETRY_MS
        goal.food.rounds = (goal.food.rounds or 0)+1
        goal.state, goal.next_at = "PENDING", now+5000
        note(body,goal,"cooking is blocked. I will look for ready-to-eat forage instead.")
        return
    end
    -- A cold stove, poison-only forage, missing material or a blocked route
    -- is not a successful step. Back off rather than hammering the route.
    Food.block(body,goal,result.code or "ENGINE_ERROR",result.detail or "physical work failed",now)
end

return Food

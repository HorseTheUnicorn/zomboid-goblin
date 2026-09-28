-- Self-sufficient base: when a job needs a base and none is usable, the
-- Goblin claims the nearest house himself instead of asking the owner.
-- Never claims another player's safehouse.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")

local Claim = { RADIUS = 30, NEAR_BASE = 12 }

-- Jobs that work on the base house itself.
Claim.HOUSE_TASKS = { INSPECT_BASE = true, MAINTAIN_BASE = true, FORTIFY = true, FORTIFY_BASE = true,
    CLOSE_CURTAINS = true }
-- Jobs that only need some base to carry things to.
Claim.BASE_TASKS = { STOCKPILE = true, SORT_STORAGE = true, FETCH_ITEM = true, DELIVER = true,
    REPAIR_STRUCTURE = true, RETURN_TO_BASE = true }

local function call(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then return false, nil end
    return pcall(object[method], object, ...)
end

local function houseAt(point)
    local square = World.square(point)
    if not square then return false end
    local ok, room = call(square, "getRoom")
    if not ok or room == nil then return false end
    local Curtains = require("GoblinSurvivor/GoblinCurtains")
    local scoped, scope = pcall(Curtains.scopeAt, point)
    return scoped and scope ~= nil
end
Claim.houseAt = houseAt

local function allowed(body, point)
    local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
    local ok, permitted = pcall(Policy.access, body, { getSquare = function() return World.square(point) end })
    return ok and permitted == true
end

-- Nearest house square in growing rings around anchor (same floor).
function Claim.nearestHouse(body, anchor, radius)
    if not anchor then return nil end
    local ax, ay, z = math.floor(anchor.x), math.floor(anchor.y), math.floor(anchor.z or 0)
    for r = 0, radius or Claim.RADIUS do
        local best, bestDistance
        for dx = -r, r do
            for dy = -r, r do
                local distance = dx * dx + dy * dy
                if math.max(math.abs(dx), math.abs(dy)) == r and (not best or distance < bestDistance) then
                    local point = { x = ax + dx + 0.5, y = ay + dy + 0.5, z = z }
                    if houseAt(point) and allowed(body, point) then best, bestDistance = point, distance end
                end
            end
        end
        if best then return best end
    end
    return nil
end

-- Returns true when a usable base exists (claiming one if needed).
function Claim.ensure(body, task, owner)
    if not Claim.HOUSE_TASKS[task] and not Claim.BASE_TASKS[task] then return true end
    local data = Body.data(body)
    if not data then return false end
    local current = data.GoblinBaseSet == true and { x = tonumber(data.GoblinBaseX), y = tonumber(data.GoblinBaseY),
        z = tonumber(data.GoblinBaseZ) } or nil
    if current and current.x and current.y and current.z then
        if not Claim.HOUSE_TASKS[task] or houseAt(current) then return true end
        -- Base marked outdoors (a yard, a car park): use the house next to it.
        local point = Claim.nearestHouse(body, current, Claim.NEAR_BASE)
        if not point then return false end
        return Claim.set(body, point, "moved our base into the house next to it")
    end
    local anchor = owner and Body.position(owner) or Body.position(body)
    local point = Claim.nearestHouse(body, anchor, Claim.RADIUS)
        or (owner and Claim.nearestHouse(body, Body.position(body), Claim.RADIUS))
    if not point then return false end
    return Claim.set(body, point, "claimed the nearest house as our base")
end

function Claim.set(body, point, why)
    local Spawner = require("GoblinSurvivor/GoblinSpawner")
    local ok = Spawner.setBaseForOwnerAt(Body.owner(body), point)
    if ok then
        pcall(Body.say, body, "Comrade, I " .. why .. ".")
        print("[GoblinSurvivor] BASE_AUTO owner=" .. tostring(Body.owner(body)) .. " x=" .. math.floor(point.x)
            .. " y=" .. math.floor(point.y) .. " z=" .. math.floor(point.z))
    end
    return ok
end

return Claim

-- Disposable, read-only second-client witness for Milestone 4-6 live gates.
-- Stage into an ordinary no-Storm client's package with the flag file
-- Lua/goblin-m46-witness.flag (line 1: witness account). Every 5 seconds it
-- prints the item IDs inside Goblin-assigned storage containers within 12
-- tiles, loose floor item IDs, and the state of the nearest vehicle's fuel,
-- battery, tires and installed part item IDs. Compare these lines with the
-- server's SORT_/FETCH_/DELIVER_TRANSFER, STRUCTURE_REPAIR, VEHICLE_* logs.
-- It never mutates the world, inventories or the Goblin.
if not isClient() or isServer() then return end
local reader = getFileReader("goblin-m46-witness.flag", false)
if not reader then return end
local witness = reader:readLine(); reader:close()
local nextAt = 0
local RADIUS = 12

local function ids(container)
    local out = {}
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        out[#out+1] = item:getFullType() .. "#" .. tostring(item:getID())
    end
    table.sort(out)
    return table.concat(out, ",")
end

local function scanStorage(player)
    local cx, cy, cz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for dx = -RADIUS, RADIUS do for dy = -RADIUS, RADIUS do
        local square = getCell():getGridSquare(cx + dx, cy + dy, cz)
        if square then
            local objects = square:getObjects()
            for i = 0, objects:size() - 1 do
                local object = objects:get(i)
                local data = object:getModData()
                local container = object:getContainer()
                if container and data and data.GoblinStorageID then
                    print("[GoblinSurvivor] M46_WITNESS storage x=" .. square:getX() .. " y=" .. square:getY()
                        .. " category=" .. tostring(data.GoblinStorageCategory) .. " items=" .. ids(container))
                end
                if object.getHealth and object.getMaxHealth and object:getMaxHealth() > 0
                    and object:getHealth() < object:getMaxHealth() then
                    print("[GoblinSurvivor] M46_WITNESS damaged x=" .. square:getX() .. " y=" .. square:getY()
                        .. " health=" .. object:getHealth() .. "/" .. object:getMaxHealth())
                end
            end
            local world = square:getWorldObjects()
            for i = 0, world:size() - 1 do
                local item = world:get(i):getItem()
                if item then
                    print("[GoblinSurvivor] M46_WITNESS floor x=" .. square:getX() .. " y=" .. square:getY()
                        .. " item=" .. item:getFullType() .. "#" .. tostring(item:getID()))
                end
            end
        end
    end end
end

local function scanVehicle(player)
    local vehicles = getCell():getVehicles()
    local best, bestD
    local iterator = vehicles:iterator()
    while iterator:hasNext() do
        local v = iterator:next()
        local d = (v:getX() - player:getX())^2 + (v:getY() - player:getY())^2
        if not bestD or d < bestD then best, bestD = v, d end
    end
    if not best or bestD > RADIUS * RADIUS then return end
    local parts = {}
    for i = 0, best:getPartCount() - 1 do
        local part = best:getPartByIndex(i)
        local item = part:getInventoryItem()
        parts[#parts+1] = part:getId() .. "=" .. (item and (item:getFullType() .. "#" .. item:getID()) or "none")
            .. "@" .. tostring(part:getCondition()) .. ":" .. string.format("%.1f", part:getContainerContentAmount())
    end
    print("[GoblinSurvivor] M46_WITNESS vehicle id=" .. tostring(best:getId()) .. " battery="
        .. string.format("%.3f", best:getBatteryCharge()) .. " parts=" .. table.concat(parts, ";"))
end

Events.OnTick.Add(function()
    local player = getPlayer()
    if not player or player:getUsername() ~= witness then return end
    local now = getTimestampMs()
    if now < nextAt then return end
    nextAt = now + 5000
    scanStorage(player)
    scanVehicle(player)
end)

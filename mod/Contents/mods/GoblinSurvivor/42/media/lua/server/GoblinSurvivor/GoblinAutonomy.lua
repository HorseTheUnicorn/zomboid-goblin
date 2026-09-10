-- Autonomous helper behavior for each player's persistent Goblin.
-- Explicit player tasks still win.  When the owner has not moved for two
-- minutes Goblin cycles useful work: defend, barricade, craft, loot and return.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Brain = require("GoblinSurvivor/GoblinBrain")

local Autonomy = { owners = {} }

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, first, second = pcall(member, object, ...)
    return ok, first, second
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

local function log(body, text)
    if type(print) == "function" then
        print("[GoblinSurvivor] AUTONOMY owner=" .. tostring(Body.owner(body)) .. " " .. tostring(text))
    end
end

local function players()
    local result = {}
    if type(getOnlinePlayers) ~= "function" then return result end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return result end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    for i = 0, size - 1 do
        local okPlayer, player = call(list, "get", i)
        if okPlayer and player ~= nil then result[#result + 1] = player end
    end
    return result
end

local function username(player)
    local ok, value = call(player, "getUsername")
    return ok and type(value) == "string" and value or ""
end

local function ownerPlayer(body)
    local wanted = string.lower(tostring(Body.owner(body) or ""))
    for _, player in ipairs(players()) do
        if string.lower(username(player)) == wanted then return player end
    end
    return nil
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    return (a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2
end

local function playerMoved(record, point)
    if record.lastPoint == nil then return true end
    return distanceSquared(record.lastPoint, point) > 0.04
end

local function closestThreat(body)
    local origin = Body.position(body)
    if origin == nil or type(getCell) ~= "function" then return nil end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil then return nil end
    local okList, list = call(cell, "getZombieList")
    if not okList or list == nil then return nil end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    local best, bestD = nil, (tonumber(Config.combatRadius) or 20)^2
    for i = 0, size - 1 do
        local okZombie, zombie = call(list, "get", i)
        if okZombie and zombie ~= nil and zombie ~= body and not Body.isGoblin(zombie) then
            local okDead, dead = call(zombie, "isDead")
            local point = Body.position(zombie)
            if point ~= nil and not (okDead and dead == true) then
                local d = distanceSquared(origin, point)
                if d < bestD then best, bestD = zombie, d end
            end
        end
    end
    return best
end

local function inventory(body)
    local ok, inv = call(body, "getInventory")
    return ok and inv or nil
end

local function inventoryItem(body, fullType)
    local inv = inventory(body)
    if inv == nil then return nil end
    local okItems, items = call(inv, "getItems")
    if not okItems or items == nil then return nil end
    local okSize, size = call(items, "size")
    size = okSize and tonumber(size) or 0
    for i = 0, size - 1 do
        local okItem, item = call(items, "get", i)
        if okItem and item ~= nil then
            local okType, itemType = call(item, "getFullType")
            if okType and itemType == fullType then return item end
        end
    end
    return nil
end

local function workCenter(body, player)
    local data = Body.data(body)
    if data ~= nil and data.GoblinBaseSet == true then
        local x, y, z = tonumber(data.GoblinBaseX), tonumber(data.GoblinBaseY), tonumber(data.GoblinBaseZ)
        if x ~= nil and y ~= nil and z ~= nil then return { x = x, y = y, z = z } end
    end
    return Body.position(player)
end

local function barricadableObjectNear(body, player)
    local center = workCenter(body, player)
    if center == nil or type(getCell) ~= "function" then return nil end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil then return nil end
    local radius = math.floor(tonumber(Config.autonomyBarricadeRadius) or 8)
    for ring = 0, radius do
        for dx = -ring, ring do
            for _, dy in ipairs({ -ring, ring }) do
                local okSq, square = call(cell, "getGridSquare", math.floor(center.x) + dx, math.floor(center.y) + dy, math.floor(center.z))
                if okSq and square ~= nil then
                    local okObjects, objects = call(square, "getObjects")
                    local okSize, size = okObjects and call(objects, "size") or false, 0
                    size = okSize and tonumber(size) or 0
                    for i = 0, size - 1 do
                        local okObj, object = call(objects, "get", i)
                        if okObj and object ~= nil then
                            local okAllowed, allowed = call(object, "isBarricadeAllowed")
                            local okBarricaded, barricaded = call(object, "isBarricaded")
                            if okAllowed and allowed == true and (not okBarricaded or barricaded ~= true) then return object end
                        end
                    end
                end
            end
        end
        for dy = -ring + 1, ring - 1 do
            for _, dx in ipairs({ -ring, ring }) do
                local okSq, square = call(cell, "getGridSquare", math.floor(center.x) + dx, math.floor(center.y) + dy, math.floor(center.z))
                if okSq and square ~= nil then
                    local okObjects, objects = call(square, "getObjects")
                    local okSize, size = okObjects and call(objects, "size") or false, 0
                    size = okSize and tonumber(size) or 0
                    for i = 0, size - 1 do
                        local okObj, object = call(objects, "get", i)
                        if okObj and object ~= nil then
                            local okAllowed, allowed = call(object, "isBarricadeAllowed")
                            local okBarricaded, barricaded = call(object, "isBarricaded")
                            if okAllowed and allowed == true and (not okBarricaded or barricaded ~= true) then return object end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function tryBarricade(body, player)
    local target = barricadableObjectNear(body, player)
    if target == nil then return false, "no unbarricaded window/door nearby" end
    local plank = inventoryItem(body, "Base.Plank")
    if plank == nil then return false, "needs Base.Plank" end

    local barricadeClass = nil
    local okClass = pcall(function() barricadeClass = IsoBarricade end)
    if not okClass or barricadeClass == nil then return false, "IsoBarricade unavailable" end
    local fn = nil
    local okFn = pcall(function() fn = barricadeClass.AddBarricadeToObject end)
    if not okFn or type(fn) ~= "function" then return false, "AddBarricadeToObject unavailable" end
    local okAdd, barricade = pcall(fn, target, body)
    if not okAdd or barricade == nil then return false, "barricade create failed" end
    local okPlank = select(1, call(barricade, "addPlank", body, plank))
    if not okPlank then return false, "addPlank failed" end
    local okSquare, square = call(target, "getSquare")
    if okSquare and square ~= nil then
        call(square, "RecalcAllWithNeighbours", true)
        call(square, "setSquareChanged")
    end
    return true, "boarded a window/door"
end

local function usefulRecipeName(name)
    name = string.lower(tostring(name or ""))
    return string.find(name, "bandage", 1, true) ~= nil
        or string.find(name, "spear", 1, true) ~= nil
        or string.find(name, "wood", 1, true) ~= nil
        or string.find(name, "plank", 1, true) ~= nil
        or string.find(name, "crate", 1, true) ~= nil
        or string.find(name, "box", 1, true) ~= nil
        or string.find(name, "sheet rope", 1, true) ~= nil
end

local function tryCraft(body)
    local inv = inventory(body)
    if inv == nil then return false, "inventory unavailable" end
    local scriptManager, recipeManager, arrayList = nil, nil, nil
    local okClasses = pcall(function()
        scriptManager = ScriptManager.instance
        recipeManager = RecipeManager
        arrayList = ArrayList
    end)
    if not okClasses or scriptManager == nil or recipeManager == nil or arrayList == nil then
        return false, "crafting API unavailable"
    end
    local containers = nil
    local okList = pcall(function() containers = arrayList.new() end)
    if not okList or containers == nil then return false, "ArrayList unavailable" end
    call(containers, "add", inv)
    local okRecipes, recipes = call(scriptManager, "getAllRecipes")
    if not okRecipes or recipes == nil then return false, "recipe list unavailable" end
    local okSize, size = call(recipes, "size")
    size = okSize and tonumber(size) or 0
    local limit = math.min(size, 500)
    for i = 0, limit - 1 do
        local okRecipe, recipe = call(recipes, "get", i)
        if okRecipe and recipe ~= nil then
            local _, name = call(recipe, "getOriginalname")
            if name == nil then _, name = call(recipe, "getName") end
            if usefulRecipeName(name) then
                local isValid = false
                local okValid = pcall(function()
                    isValid = recipeManager.IsRecipeValid(recipe, body, nil, containers) == true
                end)
                if okValid and isValid then
                    local crafted = nil
                    local okCraft = pcall(function()
                        crafted = recipeManager.PerformMakeItem(recipe, nil, body, containers)
                    end)
                    if okCraft then return true, "crafted " .. tostring(name) end
                end
            end
        end
    end
    return false, "no useful valid recipe"
end

local function markAction(body, action, detail, timestamp)
    local data = Body.data(body)
    if data ~= nil then
        data.GoblinAutonomous = true
        data.GoblinLastAutonomyAction = action
        data.GoblinLastAutonomyDetail = detail
        data.GoblinLastAutonomyAt = timestamp
    end
    log(body, "action=" .. tostring(action) .. " detail=" .. tostring(detail))
end

local function returnToOwner(body)
    local data = Body.data(body)
    if data ~= nil and data.GoblinAutonomous == true then
        data.GoblinAutonomous = false
        data.GoblinLastAutonomyAction = "FOLLOW_OWNER"
        Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
    end
end

function Autonomy.update(body, timestamp)
    if Config.autonomyEnabled ~= true or not Body.isGoblin(body) then return false, "disabled" end
    local player = ownerPlayer(body)
    if player == nil then return false, "owner offline" end
    local point = Body.position(player)
    if point == nil then return false, "owner position unavailable" end
    local now = timestamp or nowMs()
    local owner = string.lower(tostring(Body.owner(body) or ""))
    local record = Autonomy.owners[owner]
    if record == nil then
        record = { lastPoint = point, lastActiveAt = now, nextDecisionAt = now }
        Autonomy.owners[owner] = record
        return false, "idle clock armed"
    end

    if playerMoved(record, point) then
        record.lastPoint = point
        record.lastActiveAt = now
        record.nextDecisionAt = now + 1000
        returnToOwner(body)
        return false, "owner active"
    end

    local data = Body.data(body)
    if data ~= nil then data.GoblinOwnerLastActiveAt = record.lastActiveAt end
    local idleMs = now - (record.lastActiveAt or now)
    if idleMs < (tonumber(Config.autonomyIdleSeconds) or 120) * 1000 then return false, "owner not idle long enough" end

    local task = data ~= nil and data.GoblinTask or Constants.TASK.FOLLOW
    if data ~= nil and data.GoblinAutonomous == true
        and task ~= Constants.TASK.FOLLOW and task ~= Constants.TASK.WAIT then
        return true, "autonomous task in progress"
    end
    if now < (record.nextDecisionAt or 0) then return true, "decision cooldown" end
    record.nextDecisionAt = now + (tonumber(Config.autonomyDecisionSeconds) or 8) * 1000

    if closestThreat(body) ~= nil then
        local ok, detail = Brain.setTask(body, Constants.TASK.ATTACK, { autonomous = true })
        if ok then markAction(body, "DEFEND", detail, now) end
        return ok, detail
    end

    local barricaded, barricadeDetail = tryBarricade(body, player)
    if barricaded then
        markAction(body, "BARRICADE", barricadeDetail, now)
        Body.say(body, "Another aperture seized for the people's defensive committee.")
        return true, barricadeDetail
    end

    local crafted, craftDetail = tryCraft(body)
    if crafted then
        markAction(body, "CRAFT", craftDetail, now)
        return true, craftDetail
    end

    local focus = string.find(tostring(barricadeDetail), "Plank", 1, true) and "surprise" or "surprise"
    local ok, detail = Brain.setTask(body, Constants.TASK.LOOT, { loot_focus = focus, autonomous = true })
    if ok then markAction(body, "LOOT", detail, now) end
    return ok, detail
end

return Autonomy

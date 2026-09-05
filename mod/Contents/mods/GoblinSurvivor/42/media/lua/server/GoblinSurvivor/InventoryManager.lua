local InventoryManager = {}

local function functionExists(owner, name)
    return owner ~= nil and type(owner[name]) == "function"
end

local function safeCall(owner, method, ...)
    if not functionExists(owner, method) then return false, nil end
    return pcall(owner[method], owner, ...)
end

local function inventoryOf(body)
    if body == nil then return nil end
    local ok, inventory = safeCall(body, "getInventory")
    return ok and inventory or nil
end

local function firstFood(inventory)
    if inventory == nil then return nil end
    if functionExists(inventory, "getFirstCategory") then
        local ok, item = safeCall(inventory, "getFirstCategory", "Food")
        if ok and item ~= nil then return item end
    end
    if functionExists(inventory, "getItems") then
        local ok, items = safeCall(inventory, "getItems")
        if ok and items ~= nil then
            local count = type(items.size) == "function" and items:size() or #items
            for index = 0, count - 1 do
                local item = type(items.get) == "function"
                    and items:get(index) or items[index + 1]
                if item ~= nil then
                    local isFood = false
                    if functionExists(item, "isFood") then
                        local okFood, value = safeCall(item, "isFood")
                        isFood = okFood and value == true
                    elseif functionExists(item, "IsFood") then
                        local okFood, value = safeCall(item, "IsFood")
                        isFood = okFood and value == true
                    end
                    if isFood then return item end
                end
            end
        end
    end
    return nil
end

local function firstWater(inventory)
    if inventory == nil or not functionExists(inventory, "getFirstWaterFluidSources") then
        return nil
    end
    local ok, item = safeCall(inventory, "getFirstWaterFluidSources", false)
    return ok and item or nil
end

local function firstMedical(inventory)
    if inventory == nil or not functionExists(inventory, "getFirstCategory") then
        return nil
    end
    local ok, item = safeCall(inventory, "getFirstCategory", "Medical")
    return ok and item or nil
end

local function actionName(args)
    return type(args) == "table" and string.upper(tostring(args.action or "")) or ""
end

function InventoryManager.execute(args, body)
    local action = actionName(args)
    if action ~= "EAT" and action ~= "DRINK" and action ~= "BANDAGE"
        and action ~= "RELOAD" then
        return false, "unsupported native inventory action"
    end
    if body == nil then return false, "NPC body is missing" end
    local inventory = inventoryOf(body)
    if inventory == nil then return false, "native NPC inventory is unavailable" end

    if action == "EAT" then
        local item = firstFood(inventory)
        if item == nil then return false, "no food is available in the NPC inventory" end
        if not functionExists(body, "Eat") then return false, "native Eat API is unavailable" end
        local ok, result = safeCall(body, "Eat", item)
        if ok and result ~= false then return true, "native Eat action accepted" end
        return false, "native Eat action failed"
    end

    if action == "DRINK" then
        local item = firstWater(inventory)
        if item == nil then return false, "no fresh water source is available" end
        if not functionExists(body, "DrinkFluid") then
            return false, "native DrinkFluid API is unavailable"
        end
        local ok, result = safeCall(body, "DrinkFluid", item)
        if ok and result ~= false then return true, "native DrinkFluid action accepted" end
        return false, "native DrinkFluid action failed"
    end

    if action == "BANDAGE" then
        if firstMedical(inventory) == nil then
            return false, "no medical item is available in the NPC inventory"
        end
        local okDamage, damage = safeCall(body, "getBodyDamage")
        if not okDamage or damage == nil
            or not functionExists(damage, "UseBandageOnMostNeededPart") then
            return false, "native body-damage bandage API is unavailable"
        end
        local ok, result = safeCall(damage, "UseBandageOnMostNeededPart")
        if ok and result ~= false then return true, "native bandage action accepted" end
        return false, "native bandage action failed"
    end

    -- Reloading requires a verified weapon/magazine pairing and is therefore
    -- intentionally fail-closed until the server-side weapon contract is
    -- added. The survival actions above do not invent item or weapon types.
    return false, "native reload contract is unavailable"
end

return InventoryManager

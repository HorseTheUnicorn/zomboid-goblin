-- IsoZombie renders ItemVisuals, not the inventory/WornItems list used by players.
-- Construct visuals from script item types; no OutfitManager Lua singleton or GUID lookup.
local Config = require("GoblinSurvivor/Config")
local Appearance = { cache = setmetatable({}, { __mode = "k" }) }

local function call(object, method, ...)
    if object == nil then return false, nil end
    local ok, member = pcall(function() return object[method] end)
    if not ok or type(member) ~= "function" then return false, nil end
    return pcall(member, object, ...)
end

function Appearance.apply(body, timestamp)
    local cached = Appearance.cache[body]
    if cached and timestamp < cached.nextCheck then return cached.ready, cached.detail end
    cached = cached or {}
    cached.nextCheck = timestamp + 2000
    Appearance.cache[body] = cached
    local ok, visuals = call(body, "getItemVisuals")
    if not ok or visuals == nil then return false, "ItemVisuals unavailable" end
    local required = { Config.npcVisualItemType }
    for _, itemType in ipairs(Config.npcOutfitItems) do required[#required + 1] = itemType end
    local present = {}
    local _, size = call(visuals, "size")
    for i = 0, (tonumber(size) or 0) - 1 do
        local _, visual = call(visuals, "get", i)
        local _, itemType = call(visual, "getItemType")
        if itemType then present[itemType] = true end
    end
    local changed, ready = false, true
    for _, itemType in ipairs(required) do
        if not present[itemType] then
            local visual
            local made = pcall(function()
                visual = ItemVisual.new()
                visual:setItemType(itemType)
            end)
            local assetOK, asset = call(visual, "getClothingItem")
            local loaded, assetReady = call(asset, "isReady")
            if not made or not assetOK or asset == nil or not loaded or not assetReady then
                ready = false
                cached.detail = "clothing asset not ready: " .. itemType
            else
                call(visual, "pickUninitializedValues", asset)
                local added = select(1, call(visuals, "add", visual))
                ready = ready and added
                changed = changed or added
                if not added then cached.detail = "ItemVisual add failed: " .. itemType end
            end
        end
    end
    if changed then
        -- A complete costume masks the vanilla body; suppress random survivor hair.
        local _, human = call(body, "getHumanVisual")
        call(human, "setHairModel", "")
        call(human, "setBeardModel", "")
        call(human, "removeBlood")
        call(body, "resetModelNextFrame")
    end
    cached.ready = ready
    if ready then cached.detail = nil end
    if cached.lastLogged ~= ready then
        cached.lastLogged = ready
        print("[GoblinSurvivor] VISUAL_" .. (ready and "APPLIED" or "PENDING")
            .. " asset=" .. Config.npcVisualAsset .. " detail=" .. tostring(cached.detail or "ItemVisuals verified"))
    end
    return ready, cached.detail
end

return Appearance

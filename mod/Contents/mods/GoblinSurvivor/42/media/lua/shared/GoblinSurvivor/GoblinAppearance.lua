-- Native human body/UVs and native uniform, with a separate native-bound head.
-- IsoZombie renders ItemVisuals, not the player's inventory/WornItems list.
local Config = require("GoblinSurvivor/Config")
local Appearance = { cache = setmetatable({}, { __mode = "k" }) }

local function call(object, method, ...)
    if object == nil then return false, nil end
    local ok, member = pcall(function() return object[method] end)
    if not ok or type(member) ~= "function" then return false, nil end
    return pcall(member, object, ...)
end

local function clean(visual)
    call(visual, "removeBlood")
    call(visual, "removeDirt")
    if BloodBodyPartType then
        for i = 0, BloodBodyPartType.MAX:index() - 1 do
            call(visual, "removeHole", i)
            call(visual, "removePatch", i)
        end
    end
end

function Appearance.isSpawnOutfit(body)
    -- Outfit itself is not Lua-exposed in B42. The character accessor handles
    -- both pending outfits and fully dressed actors without indexing it.
    local _,name=call(body,"getOutfitName")
    return name==Config.npcOutfit
end

function Appearance.apply(body, timestamp)
    local cached = Appearance.cache[body]
    if cached and timestamp < cached.nextCheck then return cached.ready, cached.detail end
    cached = cached or {}
    cached.nextCheck = timestamp + 2000
    Appearance.cache[body] = cached
    local ok, visuals = call(body, "getItemVisuals")
    if not ok or visuals == nil then return false, "ItemVisuals unavailable" end
    local _, size = call(visuals, "size")
    size = tonumber(size) or 0
    local byType = {}
    for i = 0, size - 1 do
        local _, visual = call(visuals, "get", i)
        local _, itemType = call(visual, "getItemType")
        if itemType then byType[itemType] = visual end
    end
    local desired = {}
    for _, itemType in ipairs(Config.npcOutfitItems) do desired[#desired+1] = itemType end
    desired[#desired+1] = Config.npcVisualItemType
    local prepared, ready = {}, true
    for _, itemType in ipairs(desired) do
        local visual = byType[itemType]
        if not visual then
            local made, result = pcall(function()
                local v = ItemVisual.new()
                v:setItemType(itemType)
                return v
            end)
            visual = made and result or nil
        end
        local _, asset = call(visual, "getClothingItem")
        local loaded, assetReady = call(asset, "isReady")
        if not loaded or assetReady ~= true then
            ready = false
            cached.detail = "clothing asset not ready: " .. itemType
            break
        end
        call(visual, "pickUninitializedValues", asset)
        call(visual, "setTextureChoice", 0)
        call(visual, "setHue", 0)
        if itemType == "Base.Hat_Beret" and ImmutableColor then
            call(visual, "setTint", ImmutableColor.new(0.15, 0.15, 0.15))
        end
        clean(visual)
        prepared[#prepared+1] = visual
    end
    local changed = false
    if ready then
        changed = size ~= #prepared
        if not changed then
            for i, visual in ipairs(prepared) do
                local _, current = call(visuals, "get", i-1)
                if current ~= visual then changed = true end
            end
        end
        if changed then
            -- Only replace once every required asset has loaded.
            ready = select(1, call(visuals, "clear"))
            for _, visual in ipairs(prepared) do
                ready = select(1, call(visuals, "add", visual)) and ready
            end
        end
        local _, human = call(body, "getHumanVisual")
        local _, skin = call(human, "getSkinTexture")
        if skin ~= Config.npcSkinTexture then
            ready = select(1, call(human, "setSkinTextureName", Config.npcSkinTexture)) and ready
            changed = true
        end
        for _, field in ipairs({"HairModel", "BeardModel"}) do
            local _, value = call(human, "get" .. field)
            if value ~= "" then
                call(human, "set" .. field, "")
                changed = true
            end
        end
        clean(human)
        if changed then call(body, "resetModelNextFrame") end
        if ready then cached.detail = nil else cached.detail = "native body/ItemVisual update failed" end
    end
    cached.ready = ready
    if not ready then cached.nextCheck=timestamp+100 end
    -- Newly identified carriers stay hidden while assets load, instead of
    -- displaying a temporary naked zombie. Never change ordinary zombies.
    if type(isClient)=="function" and isClient() then
        if not ready then
            call(body,"setDoRender",false); cached.hidden=true
        elseif cached.hidden then
            call(body,"setDoRender",true); cached.hidden=false
        end
    end
    if cached.lastLogged ~= ready then
        cached.lastLogged = ready
        print("[GoblinSurvivor] VISUAL_" .. (ready and "APPLIED" or "PENDING")
            .. " asset=" .. Config.npcVisualAsset .. " detail="
            .. tostring(cached.detail or "community skin, native uniform, native-bound head"))
    end
    return ready, cached.detail
end

return Appearance

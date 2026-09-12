-- PZ 42.20's equip event accepts IsoGameCharacter, but its fishing listener
-- assumes IsoPlayer. Keep the original listener and all real-player behavior;
-- only our companion's display-only equipment must not create a fishing UI.
local Compatibility = {}
local installed

function Compatibility.install()
    local fishing = rawget(_G,"Fishing")
    local handler = fishing and fishing.Handler
    if not handler or type(handler.handleFishing)~="function" then return false end
    if handler.handleFishing == installed then return true end
    local original = handler.handleFishing
    installed = function(character, ...)
        if character then
            local ok, data = pcall(function() return character:getModData() end)
            if ok and data and data.GoblinNPC == true then return end
            local marked, goblin = pcall(function() return character:getVariableBoolean("GoblinNPC") end)
            if marked and goblin == true then return end
        end
        return original(character, ...)
    end
    handler.handleFishing = installed
    return true
end

return Compatibility

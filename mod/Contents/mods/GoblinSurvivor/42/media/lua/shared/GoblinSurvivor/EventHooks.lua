-- Small, reload-safe event registrar owned by GoblinSurvivor.
--
-- Build 42 can evaluate a mounted mod more than once while a server/client
-- session is being reloaded.  A Lua-local `started` flag cannot see handlers
-- left behind by an earlier evaluation, so each hook gets a shared generation
-- and an optional native Remove pass.  If Remove is unavailable, the old
-- wrapper still becomes inert when the generation changes.
local Hooks = rawget(_G, "GoblinSurvivorEventHooks")
if type(Hooks) ~= "table" then
    Hooks = { callbacks = {}, generations = {} }
    rawset(_G, "GoblinSurvivorEventHooks", Hooks)
end

function Hooks.install(key, event, handler)
    if type(key) ~= "string" or key == "" or event == nil or type(handler) ~= "function" then
        return false
    end

    local generation = (tonumber(Hooks.generations[key]) or 0) + 1
    Hooks.generations[key] = generation

    local previous = Hooks.callbacks[key]
    if previous ~= nil then
        pcall(function()
            if event.Remove ~= nil then event.Remove(previous) end
        end)
    end

    local callback = function(...)
        if Hooks.generations[key] ~= generation then return end
        return handler(...)
    end
    local ok = pcall(function()
        if event.Add == nil then error("event Add is unavailable") end
        event.Add(callback)
    end)
    if not ok then return false end
    Hooks.callbacks[key] = callback
    return true
end

return Hooks

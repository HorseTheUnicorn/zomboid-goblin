-- Only companion vocals are silent. Never change global zombie sound volumes
-- or stop the whole emitter: footsteps, weapons and tools must remain audible.
local Audio = { prefix = "GoblinCompanion", cache = setmetatable({}, {__mode="k"}) }

local function call(object, method, ...)
    if object == nil then return false end
    local ok, member = pcall(function() return object[method] end)
    if not ok or type(member) ~= "function" then return false end
    return pcall(member, object, ...)
end

local function stopOldVoice(body, prefix)
    local _, emitter = call(body, "getEmitter")
    if not emitter or type(prefix) ~= "string" or prefix == Audio.prefix then return end
    -- A run/walk transition can leave the previous variant playing, so cover
    -- all voice choices on THIS actor's emitter, not just the current getter.
    for _, speed in ipairs({"", "Sprinter"}) do
        for _, kind in ipairs({"Voice", "Bite"}) do
            for _, choice in ipairs({"A", "B", "C"}) do
                call(emitter, "stopSoundByName", prefix .. speed .. kind .. choice)
            end
        end
    end
end

function Audio.silence(body)
    local _, data = call(body, "getModData")
    local _, marked = call(body, "getVariableBoolean", "GoblinNPC")
    if not marked and not (data and data.GoblinNPC == true) then return false end
    local _, descriptor = call(body, "getDescriptor")
    if not descriptor then return false end
    local cached = Audio.cache[body] or {}
    Audio.cache[body] = cached
    local _, prefix = call(descriptor, "getVoicePrefix")
    if cached.descriptor ~= descriptor then
        -- Descriptors can be shared by native outfits. Copy before changing
        -- the prefix so an ordinary zombie can never inherit Goblin's mute.
        local ok, private = pcall(function() return SurvivorDesc.new(descriptor) end)
        if not ok or not private or not call(body, "setDescriptor", private) then
            stopOldVoice(body, prefix)
            if not cached.warned then
                cached.warned = true
                print("[GoblinSurvivor] AUDIO_GUARD_FAILED private descriptor unavailable")
            end
            return false
        end
        descriptor, cached.descriptor = private, private
        stopOldVoice(body, prefix)
        _, prefix = call(descriptor, "getVoicePrefix")
    end
    if prefix ~= Audio.prefix then
        stopOldVoice(body, prefix)
        if not call(descriptor, "setVoicePrefix", Audio.prefix) then return false end
    end
    -- B42 builds vocal names from SurvivorDesc's prefix. Each possible result
    -- is a valid, zero-volume sound script, including sprinter/hurt variants.
    call(body, "setHurtSound", Audio.prefix .. "VoiceA")
    call(body, "setDoDeathSound", false)
    return true
end

return Audio

-- Applied by both the server and the simulation-owning client. The network
-- actor is an IsoZombie, but its targeting and hostile states are not its AI.
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local Audio = require("GoblinSurvivor/GoblinAudio")
local Guard = {}

local function call(body, method, ...)
    local ok, member = pcall(function() return body[method] end)
    if ok and type(member) == "function" then return pcall(member, body, ...) end
    return false
end

function Guard.apply(body)
    call(body, "setTarget", nil)
    call(body, "setThumpTarget", nil)
    call(body, "setAttackTargetSquare", nil)
    call(body, "setEatBodyTarget", nil, false)
    call(body, "clearAggroList")
    call(body, "setNoTeeth", true)
    call(body, "setCanWalk", true)
    call(body, "setCrawler", false)
    call(body, "setCanCrawlUnderVehicle", false)
    call(body, "setFakeDead", false)
    call(body, "setSkeleton", false)
    call(body, "setDressInRandomOutfit", false)
    call(body, "setZombiesDontAttack", true)
    -- bLunge, alerted and issitting are read-only native callbacks in B42.
    -- Clear targeting/state below, never try to overwrite those observations.
    for _, variable in ipairs({ "isAttacking", "AttackAnim", "initiateAttack", "isMelee" }) do
        call(body, "setVariable", variable, false)
    end
    call(body, "setVariable", "NoLungeTarget", true)
    call(body, "setVariable", "NoLungeAttack", true)
    call(body, "setVariable", "GoblinNPC", true)
    call(body, "setVariable", "GoblinHumanized", true)
    Audio.silence(body)
    local _, name = call(body, "getCurrentStateName")
    name = string.lower(tostring(name or ""))
    if string.find(name,"idle",1,true) then
        local _,pathing=call(body,"getVariableBoolean","bPathfind")
        local _,moving=call(body,"getVariableBoolean","bMoving")
        if pathing~=true and moving~=true then call(body,"setUseless",true) end
    end
    if string.find(name, "lunge", 1, true) or string.find(name, "attack", 1, true)
        or string.find(name, "eatbody", 1, true) or string.find(name, "thump", 1, true)
        or string.find(name, "turnalerted", 1, true) or string.find(name,"getdown",1,true)
        or string.find(name,"sitting",1,true) or string.find(name,"fakedead",1,true) then
        -- Only the simulator changes native state. All peers still get the
        -- human-only animation guard while a stale state packet is in flight.
        if not Motion.controls(body) then return false end
        Motion.stop(body)
        local ok = pcall(function() body:changeState(ZombieIdleState.instance()) end)
        if ok then return true end
    end
    return false
end

return Guard

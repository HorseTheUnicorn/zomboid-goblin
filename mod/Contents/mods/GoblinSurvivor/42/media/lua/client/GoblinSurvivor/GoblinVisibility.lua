-- Presentation only: an owner's loaded companion does not use zombie FOV fade.
-- Never reveal a carrier before its appearance is ready, or affect other actors.
local Visibility={bodies=setmetatable({}, {__mode="k"})}

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    return pcall(member, object, ...)
end

local function isLocalClientPlayer(viewer)
    if viewer == nil or type(isClient) ~= "function"
        or type(getNumActivePlayers) ~= "function"
        or type(getSpecificPlayer) ~= "function" then return false end
    local okClient, client = pcall(isClient)
    if not okClient or client ~= true then return false end
    local okCount, count = pcall(getNumActivePlayers)
    count = okCount and tonumber(count) or nil
    if count == nil or count < 1 then return false end
    for index = 0, count - 1 do
        local okPlayer, player = pcall(getSpecificPlayer, index)
        if okPlayer and player == viewer then return true end
    end
    return false
end

local function liveLoadedBody(body)
    local okSquare, square = call(body, "getSquare")
    if not okSquare or square == nil then return false end
    local okDead, dead = call(body, "isDead")
    return okDead and dead ~= true
end

function Visibility.owned(state,viewer)
    return type(state)=="table" and type(state.npc_id)=="string"
        and state.body_present~=false and type(state.owner)=="string" and viewer~=nil
        and string.lower(state.owner)==string.lower(viewer:getUsername())
end

function Visibility.track(body,state,ready,now,serverConfirmed)
    if ready~=true then Visibility.bodies[body]=nil;return end
    Visibility.bodies[body]={state=state,seen=now,confirmed=serverConfirmed~=false}
end

function Visibility.apply(body,state,viewer,index)
    if not Visibility.owned(state,viewer) or not body:getSquare() or body:isDead()
        or not body:getDoRender() or math.floor(body:getZ())~=math.floor(viewer:getZ()) then return false end
    body:setAlphaAndTarget(index,1.0)
    return true
end

function Visibility.update(now)
    if type(getNumActivePlayers)~="function" then return end
    for body,entry in pairs(Visibility.bodies) do
        if now-entry.seen>2000 then Visibility.bodies[body]=nil
        else
            for index=0,getNumActivePlayers()-1 do
                Visibility.apply(body,entry.state,getSpecificPlayer(index),index)
            end
        end
    end
end

-- IsoPlayer.updateInternal2 invokes OnPlayerUpdate before native LOS.  The
-- friendly bodies are still IsoZombie instances, so seed them into the
-- player's last-spotted stack during that narrow window.  This is deliberately
-- client-local and only touches confirmed, ready companion entries.
function Visibility.suppressScare(viewer,now)
    if not isLocalClientPlayer(viewer) or type(now) ~= "number" then return 0 end
    local okSpotted, spotted = call(viewer, "getLastSpotted")
    if not okSpotted or spotted == nil then return 0 end
    local added = 0
    for body,entry in pairs(Visibility.bodies) do
        local state = entry and entry.state
        local seen = entry and entry.seen
        if type(seen) ~= "number" or now-seen >= 2000 then
            Visibility.bodies[body] = nil
        elseif entry.confirmed ~= false and type(state) == "table"
            and type(state.npc_id) == "string" and state.npc_id ~= ""
            and state.body_present == true and liveLoadedBody(body) then
            local okContains, present = call(spotted, "contains", body)
            if okContains and present ~= true then
                local okAdd = call(spotted, "add", body)
                if okAdd then added = added + 1 end
            end
        end
    end
    return added
end

return Visibility

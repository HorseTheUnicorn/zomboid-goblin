-- Client hand items are presentation only. B42's climbThroughWindow calls
-- dropHeavyItems, which sends a PLAYER packet whenever either hand is nonempty
-- (even for a light item). Stow before pathing, not after the climb has begun.
local Hands={}
local function call(body,key,...)
    local ok,fn=pcall(function() return body[key] end)
    if ok and type(fn)=="function" then return pcall(fn,body,...) end
end
function Hands.stow(body)
    if not body or not isClient() then return end
    local _,primary=call(body,"getPrimaryHandItem")
    local _,secondary=call(body,"getSecondaryHandItem")
    if primary then call(body,"setPrimaryHandItem",nil) end
    if secondary then call(body,"setSecondaryHandItem",nil) end
    if primary or secondary then call(body,"resetEquippedHandsModels") end
end
function Hands.travelling(body,state)
    if state and ((state.move_type and state.move_type~="IDLE") or state.vehicle_id~=nil) then return true end
    local _,vehicle=call(body,"getVehicle")
    if vehicle then return true end
    local _,pathing=call(body,"getVariableBoolean","bPathfind")
    local _,moving=call(body,"getVariableBoolean","bMoving")
    local _,name=call(body,"getCurrentStateName")
    name=string.lower(tostring(name or ""))
    return pathing==true or moving==true or name:find("climb",1,true)~=nil
        or name:find("walktoward",1,true)~=nil or name:find("pathfind",1,true)~=nil
end
return Hands

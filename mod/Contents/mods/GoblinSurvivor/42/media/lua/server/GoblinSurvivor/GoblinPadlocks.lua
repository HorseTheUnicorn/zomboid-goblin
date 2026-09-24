-- Managed-actor adapter for installed ISPadlockAction's removal branch.
-- Do not invoke that player timed action or its player-container packets.
local Padlocks={failed=setmetatable({}, {__mode="k"})}

local function call(object,name,...)
    if not object then return false end
    local ok,fn=pcall(function() return object[name] end)
    if not ok or type(fn)~="function" then return false end
    return pcall(fn,object,...)
end

function Padlocks.key(body,target)
    if Padlocks.failed[target] then return nil end
    local _,id=call(target,"getKeyId")
    if type(id)~="number" or id<0 then return nil end
    local _,inventory=call(body,"getInventory")
    local _,key=call(inventory,"haveThisKeyId",id)
    if not key or select(2,call(key,"getKeyId"))~=id then return nil end
    local _,source=call(key,"getContainer")
    if select(2,call(source,"contains",key))~=true then return nil end
    return key,source,inventory,id
end

function Padlocks.remove(body,target)
    if type(isServer)~="function" or not isServer()
        or (type(isClient)=="function" and isClient()) then return false end
    local Body=require("GoblinSurvivor/GoblinBody")
    if not Body.isGoblin(body) then return false end
    if not require("GoblinSurvivor/GoblinAccessPolicy").access(body,target) then return false end
    local _,code=call(target,"getLockedByCode")
    if code~=nil and tonumber(code)~=0 then return false end
    if select(2,call(target,"isLockedByPadlock"))~=true then return false end
    local key,source,inventory,id=Padlocks.key(body,target)
    if not key or type(instanceItem)~="function" then return false end
    local ran,padlock=pcall(instanceItem,"Base.Padlock")
    if not ran or not padlock then return false end
    if not call(padlock,"setNumberOfKey",1) or not call(padlock,"setKeyId",id)
        or select(2,call(padlock,"getKeyId"))~=id then return false end
    -- Failed partial native mutations must never be replayed on subsequent
    -- navigation ticks. Keep this runtime-only, and require explicit recovery.
    Padlocks.failed[target]=true
    local function requireCall(object,name,...)
        local ok,value=call(object,name,...)
        if not ok then error("padlock native call failed: "..name) end
        return value
    end
    local ok=pcall(function()
        requireCall(inventory,"AddItem",padlock)
        assert(requireCall(inventory,"contains",padlock)==true)
        requireCall(source,"Remove",key)
        assert(requireCall(source,"contains",key)==false)
        requireCall(target,"setLockedByPadlock",false)
        requireCall(target,"setKeyId",-1)
        assert(requireCall(target,"isLockedByPadlock")==false)
        assert(requireCall(target,"getKeyId")==-1)
        requireCall(target,"sync")
    end)
    if not ok then
        -- Compensate a failed transfer before allowing any future job. Even
        -- successful compensation leaves the target latched to avoid loops.
        call(target,"setLockedByPadlock",true)
        call(target,"setKeyId",id)
        if select(2,call(source,"contains",key))==false then call(source,"AddItem",key) end
        if select(2,call(inventory,"contains",padlock))==true then call(inventory,"Remove",padlock) end
        call(target,"sync")
        print("[GoblinSurvivor] PADLOCK_ERROR native transfer failed; target halted")
        return false
    end
    Padlocks.failed[target]=nil
    print("[GoblinSurvivor] PADLOCK_REMOVED owner="..tostring(Body.owner(body))
        .." key_consumed=true padlock_returned=true")
    return true
end

return Padlocks

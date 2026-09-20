-- Server-side grief protection for access and breach decisions. This module
-- never mutates the world; callers must re-run it immediately before a native
-- mutation because targets and safehouse ownership can change while walking.
local Body=require("GoblinSurvivor/GoblinBody")
local Policy={}

local function call(object,method,...)
    if not object then return false,nil end
    local ok,member=pcall(function() return object[method] end)
    if not ok or type(member)~="function" then return false,nil end
    local ran,value,second=pcall(member,object,...)
    return ran,value,second
end

local function serverOnly()
    return (type(isServer)~="function" or isServer())
        and not (type(isClient)=="function" and isClient())
end

local function squareOf(target)
    local ok,square=call(target,"getSquare")
    return ok and square or nil
end

local function safehouseAllows(body,target)
    local class=rawget(_G,"SafeHouse")
    if not class then return true end
    local square=squareOf(target)
    if not square then return false end
    local okMember,member=pcall(function() return class.getSafeHouse end)
    if not okMember or type(member)~="function" then return false end
    local ok,safehouse=pcall(member,square)
    if not ok then return false end
    if not safehouse then return true end
    local owner=Body.owner(body)
    if type(owner)~="string" or owner=="" then return false end
    local checked,allowed=call(safehouse,"playerAllowed",owner)
    return checked and allowed==true
end

local function containsItems(target)
    local _,container=call(target,"getContainer")
    if not container then _,container=call(target,"getItemContainer") end
    if not container then return false end
    local _,items=call(container,"getItems")
    local checked,size=call(items,"size")
    return not checked or type(size)~="number" or size>0
end

function Policy.access(body,target)
    if not serverOnly() then return false,"PERMISSION_DENIED","access is server-authoritative" end
    if not Body.isGoblin(body) then return false,"PERMISSION_DENIED","actor is not a managed Goblin" end
    if not target or not squareOf(target) then return false,"TARGET_UNLOADED","access target is not loaded" end
    if not safehouseAllows(body,target) then
        return false,"PERMISSION_DENIED","another player's safehouse blocks this access"
    end
    return true,"COMPLETE","access policy allows the target"
end

function Policy.breach(body,target,targetKind,request)
    local allowed,code,detail=Policy.access(body,target)
    if not allowed then return false,code,detail end
    request=type(request)=="table" and request or {}
    if request.allow_breach~=true then
        return false,"PERMISSION_DENIED","destructive breach was not explicitly authorized"
    end
    if request.autonomous==true or request.offline==true then
        return false,"PERMISSION_DENIED","autonomous or offline work may not breach structures"
    end
    targetKind=string.upper(tostring(targetKind or ""))
    if targetKind=="VEHICLE" then
        return false,"UNSUPPORTED","vehicle ownership cannot be proven safely; use a matching key"
    end
    if targetKind=="CONTAINER" and containsItems(target) then
        return false,"PERMISSION_DENIED","a non-empty container may not be breached"
    end
    return true,"COMPLETE","explicit breach policy allows this target"
end

return Policy

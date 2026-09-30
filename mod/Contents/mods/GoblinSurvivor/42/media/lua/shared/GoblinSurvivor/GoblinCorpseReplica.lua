-- Client-only native relationship replay. The server owns pickup, contents,
-- movement orders and drop. Never directly create, delete, heal or move bodies.
local Replica={bound=setmetatable({}, {__mode="k"}),reported=setmetatable({}, {__mode="k"})}
-- Native pickup starts as BwdDrag; the player pickup animation subsequently
-- selects the head/legs orientation. Accept that initial relationship too.
local kinds={BwdDrag=true,BwdDragHead=true,BwdDragHeadOnFront=true,BwdDragLegs=true,BwdDragLegsOnFront=true}
local function value(object,key,...)
    if not object then return nil end
    local ok,fn=pcall(function() return object[key] end)
    if not ok or type(fn)~="function" then return nil end
    local called,result=pcall(fn,object,...)
    if called then return result end
end
local function invoke(object,key,...)
    if not object then return false end
    local ok,fn=pcall(function() return object[key] end)
    return ok and type(fn)=="function" and pcall(fn,object,...)
end
local function integer(n,min,max)
    return type(n)=="number" and n==math.floor(n) and n>=min and n<=max
end
local function outfitIdentity(n)
    if not integer(n,-2147483648,4294967295) then return nil end
    if n<0 then n=n+4294967296 end
    -- The fallen-hat bit is clothing state, not a new corpse identity.
    return n-(math.floor(n/32768)%2)*32768
end
local function valid(target,link)
    return target and value(target,"getOnlineID")==link.id
        and outfitIdentity(value(target,"getPersistentOutfitID"))==outfitIdentity(link.outfit)
        and value(target,"isReanimatedForGrappleOnly")==true
        and value(target,"isDead")==false
end
local function clear(body)
    local old=Replica.bound[body]
    if not old then return end
    -- Only release our exact native pair when the server withdraws the lease.
    -- BaseGrappleable is opaque to Kahlua; use exposed character lifecycle APIs.
    -- Native corpse/death packets finish the world change, as for player drops.
    if value(body,"getGrapplingTarget")==old.target then
        invoke(body,"LetGoOfGrappled","ServerReleased")
    elseif value(old.target,"getGrappledBy")==body then
        invoke(old.target,"GrapplerLetGo",body,"ServerReleased")
    end
    Replica.bound[body]=nil
end
function Replica.apply(body,state,confirmed,now)
    if type(isClient)~="function" or isClient()~=true then return false end
    local link=state and state.corpse_drag
    if confirmed==true and type(link)=="table" and integer(link.id,0,32767)
        and Replica.reported[body]~=link.id then
        Replica.reported[body]=link.id
        print("[GoblinSurvivor] CORPSE_REPLICA_LINK id="..link.id
            .." kind="..tostring(link.kind).." expires="..tostring(link.expires).." now="..tostring(now))
    end
    if confirmed~=true or not state or state.task~="MOVE_CORPSE" or state.body_present~=true
        or type(link)~="table" or not integer(link.id,0,32767)
        or not integer(link.outfit,-2147483648,4294967295)
        or not integer(link.expires,0,9007199254740991) or now>=link.expires
        or not integer(now,0,9007199254740991) or not kinds[link.kind] then
        clear(body);return false
    end
    local old=Replica.bound[body]
    local target=old and old.target
    if not valid(target,link) then
        clear(body)
        target=nil
        local list=value(type(getCell)=="function" and getCell(),"getZombieList")
        local count=tonumber(value(list,"size")) or 0
        for i=0,count-1 do local candidate=value(list,"get",i)
            if candidate~=body and valid(candidate,link) then target=candidate;break end
        end
    end
    if not target then return false end -- creation packet may arrive after roster
    local other=value(target,"getGrappledBy")
    local held=value(body,"getGrapplingTarget")
    if (other and other~=body) or (held and held~=target) then return false end
    if not other or not held then
        local was=value(target,"isBeingGrappled")
        Replica.bound[body]={target=target}
        -- Grappled establishes both sides through AcceptGrapple. The target is
        -- already the server-created grapple-only zombie; this creates nothing.
        if not invoke(target,"Grappled",body,value(body,"getPrimaryHandItem"),1,link.kind)
            or value(target,"getGrappledBy")~=body or value(body,"getGrapplingTarget")~=target then
            clear(body);return false
        end
        print("[GoblinSurvivor] CORPSE_REPLICA_BIND id="..link.id.." was_grappled="..tostring(was))
    end
    Replica.bound[body]={target=target}
    return true
end
return Replica

-- Bounded, server-owned work helpers. Never transfer items across a wall.
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Support={}

function Support.status(body,text)
    local data=Body.data(body)
    if data.GoblinWorkStatus==text then return end
    data.GoblinWorkStatus=text
    Body.say(body,"Comrade, "..text)
    print("[GoblinSurvivor] JOB owner="..Body.owner(body).." status="..text)
end

function Support.anchor(body,owner,atBase)
    local data=Body.data(body)
    if atBase and data.GoblinBaseSet then
        return {x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ}
    end
    return owner and Body.position(owner) or nil
end

function Support.validPoint(p)
    if type(p)~="table" then return false end
    for _,key in ipairs({"x","y","z"}) do
        local v=p[key]
        if type(v)~="number" or v~=v or math.abs(v)>10000000 then return false end
    end
    return true
end

-- Returns a carried matching item, conjures one (conjureType, for Goblin's
-- own crafting/repair/farming only), or walks to one real nearby source.
function Support.supply(body,job,anchor,predicate,now,label,conjureType)
    for _,item in ipairs(World.items(World.inventory(body))) do
        if predicate(item) then job.supply=nil;return item end
    end
    if type(conjureType)=="string" then
        local Provision=require("GoblinSurvivor/GoblinProvision")
        if Provision.enabled() then
            local created=Provision.create(body,conjureType,1,label)
            if created and created[1] and predicate(created[1]) then job.supply=nil;return created[1] end
        end
    end
    if not job.supply and now>=(job.nextSupplyScan or 0) then
        -- Self-sufficient: search nearest-first out to Goblin's full range
        -- (spread over ticks) instead of asking the owner to bring anything.
        job.supplySearch=job.supplySearch or {}
        local found,done=World.search(anchor,World.range(),function(item)
            return not job.skipped[item] and predicate(item)
        end,body,job.supplySearch,3000)
        if not done then
            Support.status(body,"looking further out for "..label)
            return nil
        end
        job.supplySearch=nil
        job.nextSupplyScan=now+15000
        if found[1] then job.supply=found[1];job.supplyAt=now end
    end
    local source=job.supply
    if not source then Support.status(body,"found no "..label.." anywhere near; I will scavenge for some later");return nil end
    Body.data(body).GoblinAction=""
    job.readyAt=nil
    if World.approach(body,source.square,now) then
        if not World.take(body,source) then job.skipped[source.item]=true end
        job.supply=nil;job.nextSupplyScan=0
    elseif now-job.supplyAt>30000 then
        job.skipped[source.item]=true;job.supply=nil
    end
    return nil
end

function Support.work(body,job,square,now,duration,animation,label)
    if not World.approach(body,square,now) then
        Body.data(body).GoblinAction="";job.readyAt=nil
        return false
    end
    Body.data(body).GoblinAction=animation
    job.readyAt=job.readyAt or now+duration
    Support.status(body,label)
    return now>=job.readyAt
end

return Support

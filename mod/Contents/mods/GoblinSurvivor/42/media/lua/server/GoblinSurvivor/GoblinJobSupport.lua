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

-- Returns a carried matching item, or walks to one real nearby source.
function Support.supply(body,job,anchor,predicate,now,label)
    for _,item in ipairs(World.items(World.inventory(body))) do
        if predicate(item) then job.supply=nil;return item end
    end
    if not job.supply and now>=(job.nextSupplyScan or 0) then
        job.nextSupplyScan=now+3000
        for _,source in ipairs(World.sources(anchor,8,predicate)) do
            if not job.skipped[source.item] then job.supply=source;job.supplyAt=now;break end
        end
    end
    local source=job.supply
    if not source then Support.status(body,"I need "..label.." in my supplies or near the job.");return nil end
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

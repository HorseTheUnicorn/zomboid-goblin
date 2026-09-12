-- Server-owned work: approach, gather, reserve materials, build, verify, sync.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Tools = require("GoblinSurvivor/GoblinTools")
local Work = {jobs=setmetatable({}, {__mode="k"})}
local call=World.call
Work.blueprints={
    crate={planks=3,nails=3,sprite="carpentry_01_16",northSprite="carpentry_01_16"},
    wall={planks=3,nails=3,sprite="carpentry_02_40",northSprite="carpentry_02_41"},
    fence={planks=2,nails=2,sprite="carpentry_02_16",northSprite="carpentry_02_17"}
}

function Work.clear(body)
    Work.jobs[body]=nil
    local data=Body.data(body)
    if data then data.GoblinAction="" end
end

function Work.windows(center, radius)
    local result={}
    for dx=-radius,radius do for dy=-radius,radius do
        local sq=World.square({x=center.x+dx,y=center.y+dy,z=center.z})
        if sq then for _,obj in ipairs(World.values(select(2,call(sq,"getObjects")))) do
            if instanceof(obj,"IsoWindow") then result[#result+1]=obj end
        end end
    end end
    return result
end

local function announce(body, text)
    local data=Body.data(body)
    if data.GoblinWorkStatus ~= text then
        data.GoblinWorkStatus=text
        print("[GoblinSurvivor] WORK owner="..Body.owner(body).." status="..text)
        Body.say(body,"Comrade, "..text)
    end
end

local function gather(body, requirements, job, now)
    local selected,missing=World.materials(body,requirements)
    if selected then job.supply=nil;job.missingSince=nil; return selected end
    job.missingSince=job.missingSince or now
    job.missing=missing
    if not job.supply then
        if now < (job.nextSupplyScan or 0) then return nil end
        job.nextSupplyScan=now+3000
        for _,source in ipairs(World.sources(Body.position(body),8,function(item) return World.fullType(item)==missing end)) do
            if not job.skipped[source.item] then job.supply=source; job.supplyAt=now; break end
        end
    end
    local source=job.supply
    if not source then announce(body,"I need "..missing.." nearby or in my supplies."); return nil end
    if World.approach(body,source.square,now) then
        if not World.take(body,source) then job.skipped[source.item]=true end
        job.supply=nil;job.nextSupplyScan=0
    elseif now-job.supplyAt>30000 then job.skipped[source.item]=true; job.supply=nil end
    return nil
end

local function barricade(body,target,materials)
    local _,existing=call(target,"getBarricadeForCharacter",body)
    local before=existing and existing:getNumPlanks() or 0
    if before>=4 then return false,"already boarded" end
    local plank
    for _,item in ipairs(materials) do if World.fullType(item)=="Base.Plank" then plank=item end end
    local barr=existing or IsoBarricade.AddBarricadeToObject(target,body)
    if not barr then return false,"barricade unavailable" end
    barr:addPlank(body,plank)
    if barr:getNumPlanks() ~= before+1 then return false,"plank was not added" end
    -- Network errors after the mutation must never refund already-used materials.
    if before==0 then call(barr,"transmitCompleteItemToClients")
    else call(barr,"sendObjectChange",IsoObjectChange.STATE) end
    return true
end

local function build(body,square,payload)
    local spec=Work.blueprints[payload.kind]
    if not spec or not square:isFree(false) then return false,"building square is occupied" end
    if payload.kind~="crate" and (square:getWall(payload.north==true) or square:getDoorOrWindow(payload.north==true)) then
        return false,"this edge already has a wall, door, or window"
    end
    local md={GoblinBuilt=true,GoblinOwner=Body.owner(body)}
    local object=IsoThumpable.new(getCell(),square,payload.north and spec.northSprite or spec.sprite,payload.north==true,md)
    object:setName("Goblin "..payload.kind)
    object:setMaxHealth(500); object:setHealth(500)
    object:setIsThumpable(true); object:setIsDismantable(true)
    object:setBreakSound("BreakObject")
    if payload.kind=="crate" then
        object:setIsContainer(true)
        object:setBlockAllTheSquare(true)
    elseif payload.kind=="fence" then object:setIsHoppable(true)
    else object:setCanBarricade(false) end
    square:AddSpecialObject(object)
    call(square,"RecalcAllWithNeighbours",true)
    call(object,"transmitCompleteItemToClients")
    return object:getObjectIndex()>=0
end

function Work.update(body,task,payload,now)
    local data,job=Body.data(body),Work.jobs[body]
    if not job then job={skipped={},nextScan=0}; Work.jobs[body]=job end
    if job.missingSince and now-job.missingSince>=90000 then
        announce(body,"I could not find "..tostring(job.missing).." in 90 seconds. Resuming follow; bring materials and order the work again.")
        return true
    end
    local target,square,spec
    if task=="FORTIFY" then
        if not data.GoblinBaseSet then announce(body,"mark our base first; resuming follow."); return true end
        if not job.target and now>=job.nextScan then
            job.nextScan=now+5000
            for _,window in ipairs(Work.windows({x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ},8)) do
                local _,barr=call(window,"getBarricadeForCharacter",body)
                if not job.skipped[window] and (not barr or barr:getNumPlanks()<4) then job.target=window;job.targetAt=now;break end
            end
            if not job.target then announce(body,"no more accessible windows need boards."); return true end
        end
        target=job.target
        if not target then return false end
        square=target:getSquare()
        spec={planks=1,nails=2}
    else
        spec=Work.blueprints[payload.kind]
        square=World.square(payload)
        if not spec or not square then announce(body,"the build site is unavailable."); return false end
    end
    if not square then Work.clear(body); return true end
    local hammer=Tools.ensure(body,"Base.Hammer")
    if not hammer then announce(body,"my hammer is unavailable; the tool kit could not load."); return false end
    local selected=gather(body,{["Base.Plank"]=spec.planks,["Base.Nails"]=spec.nails},job,now)
    if not selected then return false end
    if not World.approach(body,square,now) then
        data.GoblinAction=""; job.readyAt=nil
        if target and now-job.targetAt>45000 then job.skipped[target]=true;job.target=nil end
        return false
    end
    data.GoblinAction="BUILD"
    call(body,"setPrimaryHandItem",hammer); call(body,"setSecondaryHandItem",nil)
    job.readyAt=job.readyAt or now+4000
    if now<job.readyAt then return false end
    if not World.reserve(body,selected) then return false end
    local ok,success,reason
    if target then ok,success,reason=pcall(barricade,body,target,selected)
    else ok,success,reason=pcall(build,body,square,payload) end
    if not ok or not success then
        World.refund(body,selected)
        announce(body,"work paused: "..tostring(ok and reason or success))
        job.readyAt=now+5000
        return false
    end
    data.GoblinWorkCompleted=(data.GoblinWorkCompleted or 0)+1
    data.GoblinAction=""; job.readyAt=nil
    announce(body,target and "one plank secured; continuing fortification." or payload.kind.." built.")
    if not target then Work.clear(body); return true end
    job.targetAt=now
    if target:getBarricadeForCharacter(body):getNumPlanks()>=4 then job.target=nil end
    return false
end

return Work

-- Server-owned work: approach, gather, reserve materials, build, verify, sync.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Tools = require("GoblinSurvivor/GoblinTools")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
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

-- An indoor base is scoped to its exact BuildingDef, not a nearby radius that
-- may include another player's home.  Keep both the scan and target count bounded.
function Work.houseWindows(scope)
    local result, seenSquares, seenWindows = {}, {}, {}
    local scanned, unloaded = 0, 0
    for _, room in ipairs(scope.rooms) do
        for x = room.x - 1, room.x2 + 1 do for y = room.y - 1, room.y2 + 1 do
            local key = x .. ":" .. y .. ":" .. room.z
            if not seenSquares[key] then
                seenSquares[key] = true
                scanned = scanned + 1
                if scanned > 2048 then return nil, "base house exceeds the fortification scan limit" end
                local square = World.square({x=x,y=y,z=room.z})
                if not square then unloaded = unloaded + 1 end
                if square and Curtains.belongsToScope(scope,square) then
                    for _, object in ipairs(World.values(select(2,call(square,"getObjects")))) do
                        if instanceof(object,"IsoWindow") and not seenWindows[object] then
                            seenWindows[object] = true
                            result[#result + 1] = object
                            if #result > 512 then return nil, "base house has too many windows to fortify safely" end
                        end
                    end
                end
            end
        end end
    end
    return result, nil, unloaded
end

local function windowStillOnSquare(window,square)
    if not square or World.square(World.point(square)) ~= square then return false end
    for _, object in ipairs(World.values(select(2,call(square,"getObjects")))) do
        if object == window then return true end
    end
    return false
end

local function skippedCount(job)
    local count = 0
    for _ in pairs(job.skipped) do count = count + 1 end
    return count
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
    -- Goblin conjures his own planks/nails for any construction job.
    if job.conjure then
        local Provision=require("GoblinSurvivor/GoblinProvision")
        if Provision.enabled() then
            for kind,count in pairs(requirements) do Provision.ensure(body,kind,count,"construction") end
            selected,missing=World.materials(body,requirements)
            if selected then job.supply=nil;job.missingSince=nil; return selected end
        end
    end
    job.missingSince=job.missingSince or now
    job.missing=missing
    if not job.supply then
        if now < (job.nextSupplyScan or 0) then return nil end
        -- Nearest-first out to Goblin's range, spread over ticks.
        job.gatherSearch=job.gatherSearch or {center=Body.position(body)}
        local found,done=World.search(job.gatherSearch.center,World.range(),function(item)
            return World.fullType(item)==missing and not job.skipped[item] end,body,job.gatherSearch,3000)
        if not done then return nil end
        job.gatherSearch=nil
        job.nextSupplyScan=now+10000
        if found[1] then job.supply=found[1]; job.supplyAt=now end
    end
    local source=job.supply
    if not source then announce(body,"no "..missing.." around here; I will scavenge some myself."); return nil end
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

local function boardCount(body,target)
    local checked, barr = call(target,"getBarricadeForCharacter",body)
    if not checked then return nil end
    if not barr then return 0 end
    local ok, count = call(barr,"getNumPlanks")
    return ok and tonumber(count) or nil
end

local function objectCount(square)
    local ok, objects = call(square,"getObjects")
    if not ok then return nil end
    return #World.values(objects)
end

local function build(body,square,payload)
    local spec=Work.blueprints[payload.kind]
    if not spec or not square:isFree(false) then return false,"building square is occupied" end
    if payload.kind~="crate" and (square:getWall(payload.north==true) or square:getDoorOrWindow(payload.north==true)) then
        return false,"this edge already has a wall, door, or window"
    end
    local md={GoblinBuilt=true,GoblinOwner=Body.owner(body)}
    if payload.food_crate==true and payload.kind=="crate" then md.GoblinFoodCrate=true end
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
    job.conjure = true
    if job.missingSince and now-job.missingSince>=90000 then
        announce(body,"I could not find "..tostring(job.missing).." in 90 seconds. Resuming follow; bring materials and order the work again.")
        return true, "MISSING_MATERIAL"
    end
    local target,square,spec
    if task=="FORTIFY" or task=="FORTIFY_BASE" then
        if not data.GoblinBaseSet then announce(body,"mark our base first; resuming follow."); return true end
        if not job.target and now>=job.nextScan then
            job.nextScan=now+5000
            local base = {x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ}
            local baseSquare = World.square(base)
            if not baseSquare then announce(body,"base square unloaded; fortification paused."); return true end
            local scope = Curtains.scopeAt(base)
            if not scope and select(2,call(baseSquare,"getRoom")) then
                announce(body,"base house scope unavailable; fortification paused."); return true
            end
            local windows, scanError, unloaded
            if scope then windows,scanError,unloaded = Work.houseWindows(scope)
            else windows = Work.windows(base,8) end
            if not windows then announce(body,scanError); return true end
            job.scope = scope
            job.partial = (scope and scope.partiallyStreamed == true) or (unloaded or 0) > 0
            for _,window in ipairs(windows) do
                local _,barr=call(window,"getBarricadeForCharacter",body)
                local permitted = Policy.access(body,window)
                if not permitted then job.denied = (job.denied or 0) + 1 end
                if permitted and not job.skipped[window] and (not barr or barr:getNumPlanks()<4) then
                    job.target=window;job.targetAt=now;break
                end
            end
            if not job.target then
                local incomplete = job.partial or (job.denied or 0) > 0 or skippedCount(job) > 0
                announce(body,incomplete and "loaded accessible windows checked; some areas or targets remain unverified."
                    or "no more accessible windows need boards.")
                return true
            end
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
    if target and not windowStillOnSquare(target,square) then
        job.skipped[target] = true; job.target = nil
        announce(body,"window changed or unloaded; checking another target.")
        return false
    end
    if target and job.scope and not Curtains.belongsToScope(job.scope,square) then
        announce(body,"the window left our base scope; fortification stopped.")
        return true
    end
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
    local policyTarget = target or { getSquare = function() return square end }
    local permitted, _, policyDetail = Policy.access(body,policyTarget)
    if not permitted then announce(body,policyDetail); return true end
    local before = target and boardCount(body,target) or objectCount(square)
    if before == nil then
        announce(body,"cannot establish a safe pre-work state; materials were kept.")
        Work.clear(body)
        return true
    end
    if not World.reserve(body,selected) then return false end
    if target and not windowStillOnSquare(target,square) then
        World.refund(body,selected)
        job.skipped[target] = true; job.target = nil
        announce(body,"window changed before boarding; materials kept.")
        return false
    end
    if target and job.scope and not Curtains.belongsToScope(job.scope,square) then
        World.refund(body,selected)
        announce(body,"the window left our base scope; fortification stopped.")
        return true
    end
    permitted, _, policyDetail = Policy.access(body,policyTarget)
    if not permitted then
        World.refund(body,selected)
        announce(body,policyDetail)
        return true
    end
    local ok,success,reason
    if target then ok,success,reason=pcall(barricade,body,target,selected)
    else ok,success,reason=pcall(build,body,square,payload) end
    if not ok or not success then
        local after = target and boardCount(body,target) or objectCount(square)
        if after ~= nil and after == before then
            World.refund(body,selected)
            announce(body,"work stopped without a world change; materials returned: "..tostring(ok and reason or success))
        elseif after ~= nil and after > before then
            announce(body,"world changed, but completion was uncertain; materials were not duplicated. Inspect before retrying.")
        else
            announce(body,"work outcome could not be reconciled; materials were not duplicated. Inspect before retrying.")
        end
        Work.clear(body)
        return true
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

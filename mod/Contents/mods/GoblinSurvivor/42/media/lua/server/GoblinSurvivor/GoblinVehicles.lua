-- Stationary-vehicle maintenance, using native condition and fixing rules.
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Tools=require("GoblinSurvivor/GoblinTools")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local Vehicles={}
local call=World.call

local function safe(vehicle)
    if not vehicle then return false,"vehicle unloaded or removed" end
    local speedOK,speed=call(vehicle,"getCurrentSpeedKmHour")
    local engineOK,running=call(vehicle,"isEngineRunning")
    if not speedOK or not engineOK then return false,"vehicle state could not be checked" end
    if math.abs(speed)>0.1 or running then return false,"park the vehicle and switch its engine off first" end
    for seat=0,vehicle:getMaxPassengers()-1 do
        if vehicle:getCharacter(seat) then return false,"everyone must leave the vehicle before repairs" end
    end
    return true
end

function Vehicles.prepare(body,owner,payload)
    if type(goblinServerRepair)~="function" then return nil,"repairs need the updated server-side Storm adapter" end
    local point=Support.anchor(body,owner,false)
    if not point then return nil,"stand within five tiles of the vehicle to mark it" end
    local chosen,distance
    for _,vehicle in ipairs(World.values(select(2,call(getCell(),"getVehicles")))) do
        local p=Body.position(vehicle)
        local d=(p.x-point.x)^2+(p.y-point.y)^2
        if math.floor(p.z)==math.floor(point.z) and d<=25 and (not distance or d<distance) then chosen,distance=vehicle,d end
    end
    local ok,reason=safe(chosen)
    if not ok then return nil,reason end
    local mode=payload.job or "all"
    if mode~="all" and mode~="engine" and mode~="bodywork" then return nil,"repair mode must be engine, bodywork, or all" end
    return {vehicle_id=chosen:getId(),job=mode,anchor=point,completed=0},"vehicle repair queued; using real engine parts and repair supplies"
end

local function nextPart(vehicle,payload,job)
    if payload.job~="bodywork" then
        local engine=vehicle:getPartById("Engine")
        if engine and engine:getCondition()<100 and not job.skipped.Engine then return engine,"engine" end
    end
    if payload.job=="engine" or not FixingManager then return nil end
    for i=0,vehicle:getPartCount()-1 do
        local part=vehicle:getPartByIndex(i)
        local item=part:getInventoryItem()
        if item and part:getCondition()<100 and not job.skipped[part:getId()] then
            if #World.values(FixingManager.getFixes(item))>0 then return part,"bodywork" end
        end
    end
end

function Vehicles.update(body,payload,job,now)
    local vehicle=getVehicleById and getVehicleById(payload.vehicle_id)
    local ok,reason=safe(vehicle)
    if not ok then return true,false,reason end
    local p=Body.position(vehicle)
    if math.floor(p.z)~=math.floor(payload.anchor.z)
        or (p.x-payload.anchor.x)^2+(p.y-payload.anchor.y)^2>36 then return true,false,"the marked vehicle moved; issue a new repair order" end
    local part,mode=nextPart(vehicle,payload,job)
    if not part then return true,true,"repair pass finished; "..(payload.completed or 0).." successful repairs; missing/unrepairable parts need replacement" end
    if job.part~=part then job.part=part;job.readyAt=nil end
    local wrench=Tools.ensure(body,"Base.Wrench")
    if not wrench then return true,false,"the mechanic's wrench could not load" end
    local material,fixing,fixer
    if mode=="engine" then
        material=Support.supply(body,job,payload.anchor,function(i) return World.fullType(i)=="Base.EngineParts" end,now,"engine spare parts")
        if not material then return false end
    else
        local item=part:getInventoryItem()
        local needed
        for _,candidate in ipairs(World.values(FixingManager.getFixes(item))) do
            for _,option in ipairs(World.values(candidate:getFixers())) do
                if candidate:countUses(body,option,item)>=option:getNumberOfUse()
                    and (not candidate:getGlobalItem() or candidate:countUses(body,candidate:getGlobalItem(),item)>=candidate:getGlobalItem():getNumberOfUse()) then
                    fixing,fixer=candidate,option;break
                end
                if not needed then
                    needed=candidate:countUses(body,option,item)<option:getNumberOfUse() and option or candidate:getGlobalItem()
                end
            end
            if fixer then break end
        end
        if not fixer then
            if needed then
                local kind=needed:getFixerName()
                local full=kind:find("%.") and kind or "Base."..kind
                Support.supply(body,job,payload.anchor,function(i)
                    return not World.has(World.inventory(body),i) and World.fullType(i)==full
                end,now,"repair supplies for "..part:getId()..": "..full)
            else
                job.skipped[part:getId()]=true
                Support.status(body,"no repair recipe for "..part:getId().."; that part needs replacement")
            end
            return false
        end
    end
    local square=vehicle:getSquareForArea(part:getArea())
    if not square then return true,false,"the vehicle work area is inaccessible" end
    call(body,"setPrimaryHandItem",wrench);call(body,"setSecondaryHandItem",nil)
    if not Support.work(body,job,square,now,5000,"REPAIR","repairing "..part:getId()) then return false end
    if not vehicle:isInArea(part:getArea(),body) then
        job.readyAt=nil;return true,false,"I cannot reach the vehicle's work area"
    end
    local before=part:getCondition()
    if mode=="engine" then
        if not World.reserve(body,{material}) then return false end
        local skill=body:getPerkLevel(Perks.Mechanics)-vehicle:getScript():getEngineRepairLevel()
        local amount=math.max(1,math.min(5,1+skill/2))
        part:setCondition(math.min(100,before+amount))
        call(vehicle,"transmitPartCondition",part)
    else
        local item=part:getInventoryItem()
        if not goblinServerRepair(body,item,fixing,fixer) then return true,false,"repair supplies changed before the attempt" end
        part:setCondition(item:getCondition())
        part:doInventoryItemStats(item,part:getMechanicSkillInstaller())
        if part:isContainer() and not part:getItemContainer() then part:setContainerContentAmount(part:getContainerContentAmount()) end
        call(vehicle,"updatePartStats");call(vehicle,"updateBulletStats");call(vehicle,"transmitPartItem",part)
        job.skipped[part:getId()]=true -- One material-consuming attempt per part per order.
    end
    if part:getCondition()>before then payload.completed=(payload.completed or 0)+1
    else Support.status(body,"the repair attempt failed; supplies were used by the game's repair rules") end
    job.readyAt=nil;Body.data(body).GoblinAction=""
    return false
end

return Vehicles

-- Uses the native server plant system; seeds, water and harvests are real items.
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Tools=require("GoblinSurvivor/GoblinTools")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local Farm={modes={plow=true,sow=true,water=true,harvest=true,tend=true}}
local call=World.call
local function system() return SFarmingSystem and SFarmingSystem.instance end
local function properties() return farming_vegetableconf and farming_vegetableconf.props or {} end
local function normalize(s) return string.lower(tostring(s or "")):gsub("[^%a]",""):gsub("s$","") end

function Farm.crop(name)
    local wanted=normalize(name)
    for kind in pairs(properties()) do if normalize(kind)==wanted then return kind end end
    if wanted=="tomatoe" then return Farm.crop("tomato") end
    if wanted=="potatoe" then return Farm.crop("potato") end
end

function Farm.canPlow(square)
    if not square or not system() or system():getLuaObjectOnSquare(square) then return false end
    local ok,grave=call(square,"hasGrave")
    if not ok or grave then return false end
    local _,free=call(square,"isFree",false)
    local above=getSandboxOptions and getSandboxOptions():getOptionByName("PlaceDirtAboveground")
    if square:getZ()~=0 and not (above and above:getValue()==true) then return false end
    return free==true and ISShovelGroundCursor~=nil
        and ISShovelGroundCursor.GetDirtGravelSand(square)=="dirt"
end

function Farm.prepare(body,owner,payload)
    if not system() then return nil,"the native farming system is unavailable" end
    local mode=payload.job or "tend"
    if not Farm.modes[mode] then return nil,"choose plow, sow, water, harvest, or tend" end
    local crop=payload.item and Farm.crop(payload.item.name)
    if mode=="sow" and not crop then return nil,"name a crop to sow, for example: sow cabbage" end
    local anchor=Support.anchor(body,owner,mode~="plow")
    if not anchor then return nil,"stand near the farm or set a base first" end
    if mode=="plow" and not Farm.canPlow(World.square(anchor)) then
        return nil,"stand on an empty dirt tile to mark one new furrow"
    end
    return {job=mode,crop=crop,anchor=anchor,completed=0},"farm job queued: "..mode
end

function Farm.waterUses(item)
    local _,fluid=call(item,"getFluidContainer")
    local _,primary=call(fluid,"getPrimaryFluid")
    local _,kind=call(primary,"getFluidTypeString")
    local unit=ZomboidGlobals and tonumber(ZomboidGlobals.farmingFluidContainerMillilitresPerUse)
    if (kind=="Water" or kind=="TaintedWater") and unit and unit>0 then
        local _,amount=call(fluid,"getAmount")
        return math.max(0,math.floor((tonumber(amount) or 0)*1000/unit)),fluid,unit/1000
    end
    if select(2,call(item,"IsDrainable")) and select(2,call(item,"isWaterSource")) then
        return tonumber(select(2,call(item,"getCurrentUses"))) or 0
    end
    return 0
end

local function operation(plant,mode,crop)
    if not plant or (crop and mode~="sow" and plant.typeOfSeed~=crop) then return nil end
    if mode=="sow" then return plant.state=="plow" and "sow" or nil end
    if not plant:isAlive() then return nil end
    if (mode=="harvest" or mode=="tend") and plant.hasVegetable then return "harvest" end
    local props=properties()[plant.typeOfSeed] or {}
    local desired=math.min(100,tonumber(plant.waterNeeded) or tonumber(props.waterNeeded) or 80)
    if (mode=="water" or mode=="tend") and plant.state~="plow"
        and (tonumber(plant.waterLvl) or 0)<desired then return "water" end
end

local function target(payload,job)
    if payload.job=="plow" then return World.square(payload.anchor),"plow" end
    local best,action,dist
    for dx=-8,8 do for dy=-8,8 do
        local square=World.square({x=payload.anchor.x+dx,y=payload.anchor.y+dy,z=payload.anchor.z})
        if square then
            local plant=system():getLuaObjectOnSquare(square)
            local op=operation(plant,payload.job,payload.crop)
            local key=square:getX()..":"..square:getY()
            local d=dx*dx+dy*dy
            if op and not job.skipped[key] and (not dist or d<dist) then best,action,dist=square,op,d end
        end
    end end
    return best,action
end

function Farm.update(body,payload,job,now)
    if not system() then return true,false,"farming system became unavailable" end
    if not job.square then
        job.square,job.operation=target(payload,job);job.targetAt=now
        if not job.square then
            return true,true,"farm pass finished; "..tostring(payload.completed or 0).." operations completed"
        end
    end
    local square,op=job.square,job.operation
    if World.square(World.point(square))~=square then return true,false,"farm tile unloaded; job stopped" end
    local plant=system():getLuaObjectOnSquare(square)
    if op~="plow" and operation(plant,payload.job,payload.crop)~=op then
        job.square=nil;job.readyAt=nil;return false
    end
    local tool=Tools.ensure(body,op=="harvest" and (properties()[plant.typeOfSeed] or {}).scytheHarvest
        and "Base.Scythe" or "Base.HandShovel")
    if not tool then return true,false,"the farming tool could not load" end
    local supply
    if op=="sow" then
        local props=properties()[payload.crop]
        local accepted={}
        for _,kind in ipairs(props.seedTypes or {props.seedName}) do accepted[kind]=true end
        supply=Support.supply(body,job,payload.anchor,function(i) return accepted[World.fullType(i)]==true end,now,payload.crop.." seeds")
        if not supply then return false end
    elseif op=="water" then
        supply=Support.supply(body,job,payload.anchor,function(i) return Farm.waterUses(i)>0 end,now,"a container of water")
        if not supply then return false end
    end
    if now-job.targetAt>60000 and not World.reachable(body,square) then
        job.skipped[square:getX()..":"..square:getY()]=true;job.square=nil;job.readyAt=nil
        Support.status(body,"that farm tile is blocked; checking the next one.");return false
    end
    call(body,"setPrimaryHandItem",supply or tool);call(body,"setSecondaryHandItem",nil)
    if not Support.work(body,job,square,now,3000,"FARM","working the farm: "..op) then return false end
    -- Revalidate immediately before mutation; never replay a partially executed operation.
    job.readyAt=nil
    if op=="plow" then
        if not Farm.canPlow(square) then return true,false,"the marked dirt tile is no longer empty" end
        call(system(),"removeTallGrass",square)
        system():plow(square)
        if not system():getLuaObjectOnSquare(square) then return true,false,"the furrow was not created" end
    elseif op=="sow" then
        if not World.reserve(body,{supply}) then return true,false,"the seed moved before planting" end
        plant:seed(payload.crop,body:getPerkLevel(Perks.Farming))
        if plant.state~="seeded" then return true,false,"planting did not finish; inspect the plot before retrying" end
    elseif op=="water" then
        local uses,fluid,unit=Farm.waterUses(supply)
        if uses<1 then return false end
        if fluid then fluid:adjustAmount(fluid:getAmount()-unit)
        else supply:UseAndSync() end
        plant:water(nil,1)
    elseif op=="harvest" then
        if not plant.hasVegetable then job.square=nil;return false end
        system():harvest(plant,body)
        if plant.hasVegetable then return true,false,"harvest was not confirmed; job stopped" end
    end
    payload.completed=(payload.completed or 0)+1
    job.square=nil;Body.data(body).GoblinAction=""
    if op=="plow" then return true,true,"one furrow dug at your marked tile" end
    return false
end

return Farm

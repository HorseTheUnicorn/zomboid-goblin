local Config=require("GoblinSurvivor/Config")
local Body=require("GoblinSurvivor/GoblinBody")
local Brain=require("GoblinSurvivor/GoblinBrain")
local World=require("GoblinSurvivor/GoblinWorld")
local Work=require("GoblinSurvivor/GoblinWork")
local Loot=require("GoblinSurvivor/GoblinLoot")
local Autonomy={owners={}}

local function fortifySuppliesAvailable(body)
    if not require("GoblinSurvivor/GoblinTools").ensure(body,"Base.Hammer") then return false end
    local missing={["Base.Plank"]=1,["Base.Nails"]=2}
    local function count(item)
        local kind=World.fullType(item)
        if missing[kind] then missing[kind]=math.max(0,missing[kind]-1) end
    end
    for _,item in ipairs(World.items(World.inventory(body))) do count(item) end
    -- Match Work's loaded, nearby material search; no fabricated supplies.
    for _,source in ipairs(World.sources(Body.position(body),8,function(item)
        return (missing[World.fullType(item)] or 0)>0
    end)) do count(source.item) end
    for _,amount in pairs(missing) do if amount>0 then return false end end
    return true
end

function Autonomy.update(body,now)
    local player
    for _,candidate in ipairs(World.values(getOnlinePlayers())) do
        local _, dead = World.call(candidate,"isDead")
        if dead~=true and string.lower(candidate:getUsername())==string.lower(Body.owner(body)) then player=candidate;break end
    end
    local data=Body.data(body)
    local point=player and Body.position(player)
    if player and not point then return false end
    local record=Autonomy.owners[Body.owner(body)]
    if not record then
        record={activeAt=now,nextAt=now,online=false}
        Autonomy.owners[Body.owner(body)]=record
    end
    data.GoblinOwnerOnline=player~=nil
    data.GoblinOwnerIdleSeconds=player and math.max(0,(now-record.activeAt)/1000) or 0
    if data.GoblinRide or (player and select(2,World.call(player,"getVehicle"))) then
        record.activeAt=now
        if data.GoblinAutonomous then Brain.setTask(body,"FOLLOW",{owner=Body.owner(body)}) end
        return false
    end
    if player then
        local previous=record.point
        local moved=not record.online or not previous or
            (point.x-previous.x)^2+(point.y-previous.y)^2+(point.z-previous.z)^2>0.0025
        record.online=true
        if moved then
            record.point,record.activeAt=point,now
            data.GoblinOwnerIdleSeconds=0
            data.GoblinOwnerMovingUntil=now+500
        end
        -- Movement/reconnect cancels only independent work, before its next
        -- inventory/world mutation. Explicit orders (especially WAIT) survive.
        if now-record.activeAt<Config.autonomyIdleSeconds*1000 then
            if data.GoblinAutonomous then Brain.setTask(body,"FOLLOW",{owner=Body.owner(body)}) end
            return false
        end
    else
        record.online,record.point=false,nil
        data.GoblinOwnerMovingUntil=0
    end
    -- WAIT is explicit: it must survive idle timers and reconnects.
    if not Config.autonomyEnabled then return false end
    if data.GoblinTask~="FOLLOW" then return false end
    if now<record.nextAt then return false end
    record.nextAt=now+Config.autonomyDecisionSeconds*1000
    if data.GoblinBaseSet then
        local base={x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ}
        for _,window in ipairs(Work.windows(base,Config.autonomyBarricadeRadius)) do
            local barr=window:getBarricadeForCharacter(body)
            if not barr or barr:getNumPlanks()<4 then
                if fortifySuppliesAvailable(body) then
                    data.GoblinLastAutonomyAction="FORTIFY"
                    return Brain.setTask(body,"FORTIFY",{autonomous=true})
                end
                break -- Check nearby supplies once, not once per window.
            end
        end
    end
    if Loot.hasCargo(body) then
        -- Finish delivery first. Offline without a loaded destination, keep the
        -- actual cargo and patrol instead of becoming permanently motionless.
        if not Loot.deliveryTarget(body) then
            return Brain.setTask(body,"LOOT",{autonomous=true,patrol_only=true})
        end
        return Brain.setTask(body,"LOOT",{autonomous=true,deliver_only=true})
    end
    data.GoblinLastAutonomyAction="LOOT"
    return Brain.setTask(body,"LOOT",{loot_focus="surprise",autonomous=true})
end

return Autonomy

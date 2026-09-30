local Config=require("GoblinSurvivor/Config")
local Body=require("GoblinSurvivor/GoblinBody")
local Brain=require("GoblinSurvivor/GoblinBrain")
local World=require("GoblinSurvivor/GoblinWorld")
local Work=require("GoblinSurvivor/GoblinWork")
local Loot=require("GoblinSurvivor/GoblinLoot")
local Motion=require("GoblinSurvivor/GoblinLocomotion")
local Goals=require("GoblinSurvivor/GoblinGoals")
local Caretaker=require("GoblinSurvivor/GoblinCaretaker")
local Autonomy={owners={}}

local function fortifySuppliesAvailable(body)
    if not require("GoblinSurvivor/GoblinTools").ensure(body,"Base.Hammer") then return false end
    -- Goblin conjures his own planks and nails (GoblinProvision).
    if require("GoblinSurvivor/GoblinProvision").enabled() then return true end
    local missing={["Base.Plank"]=1,["Base.Nails"]=2}
    local function count(item)
        local kind=World.fullType(item)
        if missing[kind] then missing[kind]=math.max(0,missing[kind]-1) end
    end
    for _,item in ipairs(World.items(World.inventory(body))) do count(item) end
    -- Conjuring off: match Work's loaded, nearby material search.
    for _,source in ipairs(World.sources(Body.position(body),8,function(item)
        return (missing[World.fullType(item)] or 0)>0
    end,body)) do count(source.item) end
    for _,amount in pairs(missing) do if amount>0 then return false end end
    return true
end

local function threatNear(body,point)
    local ok,Defense=pcall(require,"GoblinSurvivor/GoblinDefense")
    if not ok or type(Defense)~="table" or type(Defense.nearestThreat)~="function" then return false end
    local found=Defense.nearestThreat(body,point,6)
    if found then return true end
    local own=Body.position(body)
    return own~=nil and Defense.nearestThreat(body,own,4)~=nil
end

function Autonomy.update(body,now)
    local player
    for _,candidate in ipairs(World.values(getOnlinePlayers())) do
        local _, dead = World.call(candidate,"isDead")
        if dead~=true and string.lower(candidate:getUsername())==string.lower(Body.owner(body)) then player=candidate;break end
    end
    local data=Body.data(body)
    -- A model reply or a no-op job is not physical progress. Otherwise a
    -- steady stream of speech/empty fortification orders can postpone the
    -- scripted idle fallback forever.
    local bodyPoint=Body.position(body)
    local point=player and Body.position(player)
    if player and not point then return false end
    local record=Autonomy.owners[Body.owner(body)]
    if not record then
        record={activeAt=now,nextAt=now,online=false}
        Autonomy.owners[Body.owner(body)]=record
    end
    if not record.progressAt then record.progressAt=now end
    if bodyPoint and (not record.progressPoint
        or Motion.distance(bodyPoint,record.progressPoint)>=0.75) then
        record.progressPoint,record.progressAt=bodyPoint,now
    end
    local completed=tonumber(data.GoblinWorkCompleted) or 0
    if completed>(record.workCompleted or 0) then record.progressAt=now end
    record.workCompleted=completed
    -- A direct FOLLOW order is player activity even when the player issued it
    -- from a chair or while standing still.  Give that order a fresh idle
    -- window instead of replacing it with autonomous looting on the next tick.
    local payload=type(data.GoblinTaskPayload)=="table" and data.GoblinTaskPayload or {}
    Goals.restoreActive(body) -- persistent payload survives a lost runtime active flag
    local sequence=tonumber(data.GoblinTaskSequence) or 0
    if player and data.GoblinTask=="FOLLOW" and payload.manual==true
        and record.manualSequence~=sequence then
        record.manualSequence=sequence
        record.activeAt=now
        record.nextAt=now
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
        local idle=now-record.activeAt>=Config.autonomyIdleSeconds*1000
        -- Free-will work (Qwen's own choice) yields to combat or recall too.
        if data.GoblinFreewill == true and data.GoblinTask ~= "FOLLOW" then
            local bodyPoint=Body.position(body)
            local far=bodyPoint~=nil and Motion.distance(bodyPoint,point)>(tonumber(Config.goalRecallDistance) or 15)
            if (not idle and far) or threatNear(body,point) then
                Brain.setTask(body,"FOLLOW",{owner=Body.owner(body)})
                data.GoblinFreewillInterrupted = far and "recall" or "combat"
                return false
            end
        end
        -- Owner goals: a running step yields to combat, or to recall when the
        -- owner walks away (moving around inside the work area is fine).
        if data.GoblinGoalActive then
            local bodyPoint=Body.position(body)
            local recalled=not idle and bodyPoint~=nil
                and Motion.distance(bodyPoint,point)>(tonumber(Config.goalRecallDistance) or 15)
            if Goals.tick(body,Brain.setTask,{idle=idle,recalled=recalled,threat=threatNear(body,point),
                food_enabled=Config.autonomyEnabled and Config.foodSurvivalEnabled and data.GoblinFreewillEnabled},now) then
                return true
            end
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
    -- The owner's idle timer can expire while a client-owned actor is still
    -- navigating back from a run. Finish the catch-up before taking an
    -- independent chore; otherwise LOOT cancels the only route home. Follow
    -- slots can sit beyond preferredDistance + 1 on diagonal/offset tiles,
    -- so use the follow planner's arrival verdict instead of a second,
    -- slightly narrower distance threshold that can strand Goblin forever.
    if player then
        local bodyPoint=Body.position(body)
        if not bodyPoint or math.floor(bodyPoint.z)~=math.floor(point.z) then return false end
        if Motion.distance(bodyPoint,point)>Config.followPreferredDistance then
            local followGoal,_,navigation=Motion.followGoal(body,player,now)
            local key=navigation and navigation.goal_key
            if followGoal or (key~="arrived" and not (type(key)=="string"
                and string.match(key,"^slot:%d+$"))) then return false end
        end
    end
    -- Standing owner goals take precedence over independent chores.
    if player and Config.foodSurvivalEnabled == true and data.GoblinFreewillEnabled == true
        and (record.foodScanAt or 0) <= now and not threatNear(body,point) then
        record.foodScanAt = now+30000
        Goals.ensureFood(body,now)
    end
    if player and Goals.tick(body,Brain.setTask,{idle=true,threat=threatNear(body,point),
        food_enabled=Config.foodSurvivalEnabled and data.GoblinFreewillEnabled},now) then
        return true
    end
    -- Tell the owner what got done while they were away.
    if player and type(data.GoblinCaretakerReport)=="string" then
        Body.say(body,"Comrade, "..data.GoblinCaretakerReport)
        data.GoblinCaretakerReport=nil
    end
    -- Home upkeep needs no orders and does not wait for free will: a stopped
    -- generator or thirsty crops are handled as soon as they are noticed,
    -- with or without the owner online.
    -- With the owner online he only does upkeep while they are within his
    -- roaming range of the base; beyond it he stays their companion.
    local roam=tonumber(Config.caretakerRoamRadius) or 500
    local home=Caretaker.base(body)
    -- No base yet: once the owner settles in a house, Goblin makes it home.
    if not home and player and (record.claimAt or 0)<=now then
        record.claimAt=now+300000
        local _,room=World.call(World.square(point),"getRoom")
        if room then
            pcall(require("GoblinSurvivor/GoblinBaseClaim").ensure,body,"INSPECT_BASE",player)
            home=Caretaker.base(body)
        end
    end
    local ownerHome=not player or (home~=nil and math.floor(point.z)==home.z
        and (point.x-home.x)^2+(point.y-home.y)^2<=roam*roam)
    if ownerHome and not (player and threatNear(body,point)) and Caretaker.tick(body,Brain.setTask,now) then
        return true
    end
    -- Owner away: stay within roaming range of home; beyond it, walk back
    -- instead of standing wherever the owner logged out.
    if not player then
        local here=Body.position(body)
        if home and here and (math.floor(here.z)~=home.z
            or (here.x-home.x)^2+(here.y-home.y)^2>roam*roam) then
            if (record.homeAt or 0)<=now then
                record.homeAt=now+60000
                data.GoblinLastAutonomyAction="GO_HOME"
                return Brain.setTask(body,"RETURN_TO_BASE",{owner=Body.owner(body),caretaker=true})
            end
            return false
        end
    end
    -- With free will on, give Qwen the first chance to choose Goblin's next
    -- job; scripted chores only fill in if it has been silent for a while,
    -- so Goblin is never left standing around.
    if data.GoblinFreewillEnabled == true then
        -- Give Qwen grace after real movement/work, but do not renew it for
        -- speech or an immediately completed empty job.
        local lastChoice=math.max(record.activeAt or 0,record.progressAt or 0)
        if now-lastChoice<(tonumber(Config.freewillGraceSeconds) or 60)*1000 then return false end
    end
    if now<record.nextAt then return false end
    record.nextAt=now+Config.autonomyDecisionSeconds*1000
    if data.GoblinBaseSet and now>=(record.fortifyNextAt or 0) then
        local base={x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ}
        -- Use the same exact house scope as Work.update, not other houses'
        -- windows in the surrounding radius that Work will never work on.
        local scope=require("GoblinSurvivor/GoblinCurtains").scopeAt(base)
        local windows=scope and Work.houseWindows(scope) or (not scope and Work.windows(base,Config.autonomyBarricadeRadius))
        for _,window in ipairs(windows or {}) do
            local barr=window:getBarricadeForCharacter(body)
            if not barr or barr:getNumPlanks()<4 then
                if fortifySuppliesAvailable(body) then
                    record.fortifyNextAt=now+300000
                    data.GoblinLastAutonomyAction="FORTIFY"
                    return Brain.setTask(body,"FORTIFY",{autonomous=true})
                end
                -- Short of planks: scrap empty wooden furniture in nearby
                -- non-base buildings instead of wandering off to loot.
                if player and Config.salvageEnabled ~= false then
                    local ok=Brain.setTask(body,"DISMANTLE",{salvage=true,autonomous=true})
                    if ok then data.GoblinLastAutonomyAction="SALVAGE";return true end
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
    if Loot.autonomousBlocked(body,now) then return false end
    data.GoblinLastAutonomyAction="LOOT"
    return Brain.setTask(body,"LOOT",{loot_focus="surprise",autonomous=true})
end

return Autonomy

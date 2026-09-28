local Config = require("GoblinSurvivor/Config")
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Explore = require("GoblinSurvivor/GoblinExplore")
local Tools = require("GoblinSurvivor/GoblinTools")
local Movement = require("GoblinSurvivor/GoblinMovement")
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local Loot = { jobs = setmetatable({}, {__mode="k"}),
    activity = setmetatable({}, {__mode="k"}),
    blockedUntil = setmetatable({}, {__mode="k"}) }
local call = World.call

local function protected(item)
    if Tools.reserved(item) then return true end
    -- Conjured supplies are for Goblin's own work; never delivered or dropped.
    if require("GoblinSurvivor/GoblinProvision").isConjured(item) then return true end
    local kind = World.fullType(item)
    if not kind or kind == Config.weaponType or kind == Config.npcVisualItemType then return true end
    for _, uniform in ipairs(Config.npcOutfitItems) do if kind == uniform then return true end end
    return false
end

local function removeActorItem(body, inventory, item)
    if World.containsExact(inventory,item) ~= true then return false end
    local characterOK, character = call(inventory,"getCharacter")
    if characterOK and character then
        local handsOK = call(character,"removeFromHands",item)
        if not handsOK then return false end
    end
    -- ItemContainer.Remove invokes InventoryItem.OnBeforeRemoveFromContainer.
    -- For Food, Build 42 updates age there and sends ItemStats; ContainerID.set
    -- cannot address this IsoZombie inventory because it has no world square.
    -- DoRemoveItem performs the native detach without that invalid callback;
    -- the destination's normal container/world packet is sent below.
    local removed = call(inventory,"DoRemoveItem",item)
    return removed and World.containsExact(inventory,item) == false
end

local function matches(item, focus, autonomous)
    if protected(item) then return false end
    -- Do not continuously pick up and redeliver a previous delivery pile.
    local _, metadata = call(item,"getModData")
    if metadata and metadata.GoblinDelivered == true then return false end
    if focus == "surprise" or not focus then return true end
    local kind = string.lower(World.fullType(item) or "")
    local _, category = call(item,"getDisplayCategory")
    category = string.lower(tostring(category or ""))
    local _, c = call(item,"getCategory")
    category = category .. string.lower(tostring(c or ""))
    if focus == "food" then return string.find(category,"food",1,true) ~= nil end
    if focus == "medical" then return string.find(category,"medical",1,true) ~= nil or string.find(kind,"bandage",1,true) ~= nil end
    if focus == "ammo" then return string.find(category,"ammo",1,true) ~= nil end
    if focus == "tools" then
        return string.find(category,"tool",1,true) ~= nil or string.find(category,"weapon",1,true) ~= nil
            or kind == "base.plank" or kind == "base.nails" or kind == "base.hammer"
    end
    return false
end

function Loot.clear(body) Loot.jobs[body]=nil end

function Loot.autonomousBlocked(body, now)
    return (Loot.blockedUntil[body] or 0) > now
end

function Loot.deliveryTarget(body)
    local data=Body.data(body)
    if data.GoblinBaseSet then
        return World.square({x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ}),"base"
    end
    for _,player in ipairs(World.values(getOnlinePlayers())) do
        local _, dead = call(player,"isDead")
        if dead~=true and string.lower(player:getUsername())==string.lower(Body.owner(body)) then
            return World.square(Body.position(player)),"player"
        end
    end
    return nil,"owner offline; keeping cargo"
end

function Loot.collect(body, payload, now)
    if not Body.isGoblin(body) then return false,"body unavailable",0,true end
    local data, job = Body.data(body), Loot.jobs[body]
    if not job then
        job={index=1,moved=0,started=now,skipped={},skippedSquares={}}
        Loot.jobs[body]=job
    end
    if payload.autonomous then
        local current=Body.position(body)
        if current then
            -- Keep this across individual LOOT jobs. A scan may complete and
            -- be requeued every few seconds without any physical movement.
            local activity=Loot.activity[body]
            if not activity or Motion.distance(current,activity.point)>=0.75 then
                activity={point=current,at=now}
                Loot.activity[body]=activity
            elseif now-activity.at>=30000 then
                -- Individual target blacklists cannot help when the actor is
                -- trapped in the same area and every successive target fails.
                -- End this chore, hand control back to FOLLOW, and avoid
                -- immediately selecting the same impossible scan again.
                local moved=job.moved
                local noProgress=now-activity.at
                activity.point,activity.at=current,now
                Loot.blockedUntil[body]=now+60000
                Loot.clear(body)
                Movement.clear(body)
                data.GoblinLootStatus="no reachable supplies; returning to owner"
                print("[GoblinSurvivor] LOOT_BLOCKED owner="..Body.owner(body)
                    .." no_progress_ms="..tostring(noProgress))
                return true,data.GoblinLootStatus,moved,true
            end
        end
    end
    if payload.autonomous and (job.explore or payload.patrol_only) then
        local finished, detail = Explore.update(body,payload,job,now)
        if finished then job.sources=nil end
        data.GoblinLootStatus=detail
        return true,detail,job.moved,false
    end
    if not job.sources then
        local center=Body.position(body)
        local anchor=payload.autonomous and Explore.anchor(body,payload)
        job.sources={}
        for _,source in ipairs(World.sources(center,Config.lootRadius,function(item)
            return not job.skipped[item] and matches(item,payload.loot_focus,payload.autonomous)
        end,body)) do
            if not job.skippedSquares[source.square]
                and (not anchor or Explore.within(World.point(source.square),anchor)) then
                job.sources[#job.sources+1]=source
            end
        end
        job.index,job.started=1,now
    end
    local source=job.sources[job.index]
    if not source or job.moved >= Config.lootMaxItemsPerTask then
        data.GoblinAction=""
        if payload.autonomous and job.moved==0 and not Loot.hasCargo(body) then
            local finished, detail=Explore.update(body,payload,job,now)
            if finished then job.sources=nil end
            data.GoblinLootStatus=detail
            return true,detail,0,false
        end
        Loot.clear(body)
        return true,"loot scan complete",job.moved,true
    end
    local atBase = payload.autonomous and data.GoblinBaseSet
        and source.square:getZ()==math.floor(data.GoblinBaseZ)
        and math.abs(source.square:getX()-data.GoblinBaseX)<3 and math.abs(source.square:getY()-data.GoblinBaseY)<3
    if atBase or now-job.started>30000 then
        job.skipped[source.item]=true
        job.skippedSquares[source.square]=true
        job.sources,job.index,job.started,job.readyAt=nil,1,now,nil
        Movement.clear(body)
        return true,"skipping base supplies or unreachable item",job.moved,false
    end
    -- On a dedicated server the native path is often owned by a client. The
    -- server's Movement.update() then reports delegation, not a failed path,
    -- even while the actor stays motionless at an inaccessible loot target.
    -- Observe replicated position and abandon that candidate before a whole
    -- 25-item scan can consume many minutes without physical work.
    local position=Body.position(body)
    if job.progressItem~=source.item then
        job.progressItem,job.progressPoint,job.progressAt=source.item,position,now
    elseif position and job.progressPoint then
        local delta=(position.x-job.progressPoint.x)^2+(position.y-job.progressPoint.y)^2
            +(position.z-job.progressPoint.z)^2
        if delta>=0.04 then
            job.progressPoint,job.progressAt=position,now
        elseif payload.autonomous and now-(job.progressAt or now)>=12000 then
            job.skipped[source.item]=true
            job.skippedSquares[source.square]=true
            job.sources,job.index,job.readyAt=nil,1,nil
            job.progressItem,job.progressPoint,job.progressAt=nil,nil,nil
            Movement.clear(body)
            local finished,exploreDetail=Explore.update(body,payload,job,now)
            if finished then job.sources=nil end
            data.GoblinLootStatus=exploreDetail
            return true,exploreDetail,job.moved,false
        end
    end
    local reached,detail=World.approach(body,source.square,now)
    data.GoblinLootStatus=detail
    if reached then
        data.GoblinAction="LOOT"
        job.readyAt=job.readyAt or now+1200
        if now>=job.readyAt then
            if World.take(body,source) then
                job.moved=job.moved+1
                data.GoblinLootCount=(data.GoblinLootCount or 0)+1
                print("[GoblinSurvivor] LOOT_COLLECT owner="..Body.owner(body).." item="..tostring(World.fullType(source.item)))
            end
            job.index,job.started,job.readyAt=job.index+1,now,nil
            data.GoblinAction=""
        end
    end
    return true,detail,job.moved,false
end

function Loot.hasCargo(body)
    for _, item in ipairs(World.items(World.inventory(body))) do
        if not protected(item) and World.fullType(item) ~= "Base.Hammer" then return true end
    end
    return false
end

function Loot.deposit(body)
    local data, inv=Body.data(body),World.inventory(body)
    local square,destination=Loot.deliveryTarget(body)
    if not square then return false,destination,0 end
    if not World.reachable(body,square) then return false,"delivery point not in reach",0 end
    local container
    for _, object in ipairs(destination=="base" and World.values(select(2,call(square,"getObjects"))) or {}) do
        local _, candidate=call(object,"getContainer")
        local _, locked=call(object,"isLocked")
        if candidate and not locked then container=candidate; break end
    end
    local moved, uncertain=0, false
    for _, item in ipairs(World.items(inv)) do
        if not protected(item) and World.fullType(item) ~= "Base.Hammer" then
            if removeActorItem(body,inv,item) then
                local _,metadata=call(item,"getModData")
                local wasDelivered=metadata and metadata.GoblinDelivered
                if metadata then metadata.GoblinDelivered=true end
                local ok,value=false,nil
                local roomOK,room=call(container,"hasRoomFor",body,item)
                if container and roomOK and room then
                    ok,value=call(container,"AddItem",item)
                    -- Build 42 returns the *existing* item when this container
                    -- already has the incoming ID. A non-nil return is not
                    -- proof that our exact cargo was deposited.
                    ok=ok and value==item and World.has(container,item)
                    if ok and type(sendAddItemToContainer)=="function" then
                        if not pcall(sendAddItemToContainer,container,item) then uncertain=true end
                    elseif ok then uncertain=true end
                else ok,value=call(square,"AddWorldInventoryItem",item,0.5,0.5,0) end
                if ok and value==item then
                    moved=moved+1
                else
                    if metadata then metadata.GoblinDelivered=wasDelivered end
                    local restored,returned=call(inv,"AddItem",item)
                    if not restored or returned~=item or not World.has(inv,item) then uncertain=true end
                end
            else
                uncertain=true
            end
        end
    end
    data.GoblinLootStatus=uncertain and "delivery state uncertain"
        or (moved>0 and "delivered" or "nothing delivered")
    print("[GoblinSurvivor] LOOT_DELIVER owner="..Body.owner(body).." destination="..destination.." moved="..moved)
    return not uncertain and not Loot.hasCargo(body),data.GoblinLootStatus,moved
end

return Loot

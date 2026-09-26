-- Non-destructive access to an actual nearby world container. No loot roll,
-- lock removal, inventory transfer, or player-only timed action occurs here.
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Policy=require("GoblinSurvivor/GoblinAccessPolicy")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local ContainerAccess={}
local sequence=0
local call=World.call

function ContainerAccess.prepare(body,owner,now)
    local point=Body.position(owner)
    if not point then return nil,"owner location is unavailable" end
    local selected,best
    for dx=-5,5 do for dy=-5,5 do
        if dx*dx+dy*dy<=25 then
            local square=World.square({x=math.floor(point.x)+dx,y=math.floor(point.y)+dy,z=point.z})
            if square then
                for _,object in ipairs(World.values(select(2,call(square,"getObjects")))) do
                    local _,container=call(object,"getContainer")
                    local _,index=call(object,"getObjectIndex")
                    if container and type(index)=="number" and index>=0
                        and Policy.access(body,object) and World.containerAccessible(body,object) then
                        local p=World.point(square)
                        local distance=(p.x-point.x)^2+(p.y-point.y)^2
                        if distance<=25 and (not best or distance<best) then
                            selected={object=object,point=p};best=distance
                        end
                    end
                end
            end
        end
    end end
    if not selected then return nil,"no natively accessible container within five tiles" end
    -- Persist a stable object marker, not an engine object or a fragile index.
    -- Replacement furniture at the same coordinates must not become the target.
    local ok,data=call(selected.object,"getModData")
    if not ok or type(data)~="table" then return nil,"container identity is unavailable" end
    if type(data.GoblinAccessContainerID)~="string" then
        sequence=sequence+1
        data.GoblinAccessContainerID=Body.owner(body)..":"..tostring(now)..":"..sequence
        call(selected.object,"transmitModData")
    end
    return {access_method="CONTAINER",target_kind="CONTAINER",anchor=point,
        container_point=selected.point,container_id=data.GoblinAccessContainerID,
        started_at=now},"walking to the accessible container"
end

function ContainerAccess.update(body,payload,runtime,now)
    if not Support.validPoint(payload.container_point) or type(payload.container_id)~="string" then
        return true,false,"saved container target is invalid","TARGET_CHANGED"
    end
    local square=World.square(payload.container_point)
    if not square then return true,false,"container area is not loaded","TARGET_UNLOADED" end
    local target
    for _,object in ipairs(World.values(select(2,call(square,"getObjects")))) do
        local _,data=call(object,"getModData")
        if type(data)=="table" and data.GoblinAccessContainerID==payload.container_id then
            if target then return true,false,"container identity is ambiguous","TARGET_CHANGED" end
            target=object
        end
    end
    if not target or not select(2,call(target,"getContainer")) then
        return true,false,"selected container was removed or replaced","TARGET_CHANGED"
    end
    local allowed,code,detail=Policy.access(body,target)
    if not allowed then return true,false,detail,code end
    if not World.containerAccessible(body,target) then
        return true,false,"container is locked to this Goblin or its lock state is unreadable","LOCKED"
    end
    if World.approach(body,square,now) then
        return true,true,"reached the natively accessible container; contents unchanged","COMPLETE"
    end
    runtime.approach_started_at=runtime.approach_started_at or now
    if now-runtime.approach_started_at>45000 then
        return true,false,"could not reach the selected container","NO_PATH"
    end
    return false,true,"walking to the accessible container","MOVING_TO_TARGET"
end

return ContainerAccess

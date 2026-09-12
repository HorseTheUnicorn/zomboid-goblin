local Body=require("GoblinSurvivor/GoblinBody")
local Movement=require("GoblinSurvivor/GoblinMovement")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local Jobs={active=setmetatable({}, {__mode="k"})}
local handlers={FARM=require("GoblinSurvivor/GoblinFarming"),CRAFT=require("GoblinSurvivor/GoblinCrafting"),
    REPAIR_VEHICLE=require("GoblinSurvivor/GoblinVehicles"),CLOSE_CURTAINS=require("GoblinSurvivor/GoblinCurtains")}

function Jobs.handles(task) return handlers[task]~=nil end
function Jobs.clear(body)
    local current=Jobs.active[body]
    -- Handler runtime state (BuildingDef/IsoCurtain references) is never
    -- persisted, and must be released when the order is replaced or ends.
    if current and current.task and handlers[current.task] and handlers[current.task].clear then
        handlers[current.task].clear(body)
    end
    Jobs.active[body]=nil
    local data=Body.data(body)
    if data then data.GoblinJobActive=false;data.GoblinAction="";data.GoblinJobProgress=nil end
end
function Jobs.prepare(body,owner,task,payload)
    if not isServer() or isClient() then return nil,"work must run on the game server" end
    if not owner then return nil,"the owner must be present to issue this job" end
    return handlers[task].prepare(body,owner,payload)
end
function Jobs.update(body,task,payload,now)
    if not isServer() or isClient() then return true,false,"server work is unavailable" end
    if not Support.validPoint(payload.anchor) then return true,false,"saved job has no valid work area; issue it again" end
    local job=Jobs.active[body]
    if not job then job={startedAt=now,skipped={},task=task};Jobs.active[body]=job end
    local data=Body.data(body)
    data.GoblinJobActive=true
    if now-job.startedAt>300000 then return true,false,"job stopped after five minutes; check materials and access, then retry" end
    local ran,done,ok,detail=pcall(handlers[task].update,body,payload,job,now)
    if not ran then
        print("[GoblinSurvivor] JOB_ERROR task="..task.." owner="..Body.owner(body).." detail="..tostring(done))
        return true,false,"the native job failed; I stopped to avoid repeating a partial operation"
    end
    data.GoblinJobProgress=tonumber(payload.completed) or 0
    if done then Movement.clear(body) end
    return done,ok,detail
end
return Jobs

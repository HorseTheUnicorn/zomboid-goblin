-- Disposable local test only; never include in a released package.
-- Uses the real selector and normal Brain/Jobs path against existing buildings.
-- Does not spawn obstructions, change locks, grant keys or force positions.
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-existing-building.flag",false)
if not reader then return end
local owner=reader:readLine();reader:close()
if owner~="m3witness_54" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Brain=require("GoblinSurvivor/GoblinBrain")
local Jobs=require("GoblinSurvivor/GoblinJobs")
local fired,active=false,nil
local originalUpdate=Jobs.update
local function log(text) print("[GoblinSurvivor] M3_EXISTING_BUILDING "..text) end
local function cleanup(reason)
    local t=active
    active=nil
    Jobs.update=originalUpdate
    if t then
        local ok,detail=pcall(Brain.setTask,t.body,"FOLLOW",{manual=true})
        log("cleanup="..tostring(ok).." reason="..reason.." detail="..tostring(detail))
    end
end
Jobs.update=function(body,task,payload,now)
    local result=originalUpdate(body,task,payload,now)
    local t=active
    if t and body==t.body and task=="GAIN_ACCESS" then
        local ok,err=pcall(function()
            if not t.lastLog or now-t.lastLog>=500 or result.done then
                t.lastLog=now
                local p=Body.position(body)
                local edge=payload.edge or {}
                log("code="..tostring(result.code).." x="..tostring(p and p.x)
                    .." y="..tostring(p and p.y).." z="..tostring(p and p.z)
                    .." edge_x="..tostring(edge.x).." edge_y="..tostring(edge.y)
                    .." dx="..tostring(edge.dx).." dy="..tostring(edge.dy)
                    .." destination="..tostring(payload.destination_side)
                    .." method="..tostring(payload.access_method)
                    .." done="..tostring(result.done).." success="..tostring(result.success)
                    .." detail="..tostring(result.detail))
            end
            if result.done then t.finished=true end
        end)
        if not ok then t.finished=true;log("observation_error="..tostring(err)) end
    end
    return result
end
Events.OnTick.Add(function()
    if active then
        if active.finished then cleanup("terminal")
        elseif getTimestampMs()-active.started>90000 then cleanup("PROBE_TIMEOUT") end
        return
    end
    if fired or not getCell() then return end
    for _,body in ipairs(World.values(getCell():getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner and body:getCurrentSquare()
            and not body:getVehicle() then
            fired=true
            active={body=body,started=getTimestampMs()}
            local ok,accepted,detail=pcall(Brain.setTask,body,"GAIN_ACCESS",{
                target={kind="BUILDING"},allow_breach=false})
            log("dispatch_ok="..tostring(ok).." accepted="..tostring(accepted)
                .." detail="..tostring(detail).." owner="..owner)
            if not ok or not accepted then cleanup("refused") end
            return
        end
    end
end)

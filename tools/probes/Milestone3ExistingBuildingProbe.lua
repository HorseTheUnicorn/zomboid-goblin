-- Disposable local test only; never include in a released package.
-- Uses the real selector and normal Brain/Jobs path against existing buildings.
-- Does not spawn obstructions, change locks, grant keys or force positions.
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-existing-building.flag",false)
if not reader then return end
local owner=reader:readLine()
local mode=reader:readLine()
local witness=reader:readLine();reader:close()
if owner~="m3witness_54" then return end
if mode~=nil and mode~="" and mode~="close-selected-door" then return end
if witness~=nil and witness~="" and witness~="m3path_61" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Brain=require("GoblinSurvivor/GoblinBrain")
local Jobs=require("GoblinSurvivor/GoblinJobs")
local fired,active,witnessReadyAt=false,nil,nil
local originalUpdate=Jobs.update
local function log(text) print("[GoblinSurvivor] M3_EXISTING_BUILDING "..text) end
local function cleanup(reason)
    local t=active
    active=nil
    Jobs.update=originalUpdate
    if t then
        if t.door and t.wasOpen~=nil then
            local restored,err=pcall(function()
                assert(t.door:getObjectIndex()>=0,"fixture door was removed")
                if t.door:isOpen()~=t.wasOpen then
                    t.door:ToggleDoorSilent()
                    t.door:syncIsoObject(false,0,nil,nil)
                end
                assert(t.door:isOpen()==t.wasOpen,"original door state not restored")
            end)
            log("fixture_restored="..tostring(restored).." detail="..tostring(err))
        end
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
                    .." door_open="..tostring(t.door and t.door:isOpen())
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
    if witness=="m3path_61" then
        local nearby={}
        for _,player in ipairs(World.values(getOnlinePlayers())) do
            local name=player:getUsername()
            if (name==owner or name==witness) and player:getZ()==0
                and math.abs(player:getX()-10779)<20 and math.abs(player:getY()-9767)<20 then
                nearby[name]=true
            end
        end
        if not nearby[owner] or not nearby[witness] then witnessReadyAt=nil;return end
        witnessReadyAt=witnessReadyAt or getTimestampMs()
        if getTimestampMs()-witnessReadyAt<20000 then return end
    end
    for _,body in ipairs(World.values(getCell():getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner and body:getCurrentSquare()
            and not body:getVehicle() then
            fired=true
            active={body=body,started=getTimestampMs()}
            local ok,accepted,detail=pcall(Brain.setTask,body,"GAIN_ACCESS",{
                target={kind="BUILDING"},allow_breach=false})
            log("dispatch_ok="..tostring(ok).." accepted="..tostring(accepted)
                .." detail="..tostring(detail).." owner="..owner)
            if not ok or not accepted then cleanup("refused")
            elseif mode=="close-selected-door" then
                -- Close only the selected ordinary doorway before its first job
                -- update. This measures revalidation/opening, not closed-route
                -- selection preference. Restore the original state afterward.
                local prepared,err=pcall(function()
                    local payload=Body.data(body).GoblinTaskPayload
                    assert(payload and payload.access_method=="DOOR","not a door route")
                    local edge=assert(payload.edge,"no selected edge")
                    local a=getCell():getGridSquare(edge.x,edge.y,edge.z)
                    local b=getCell():getGridSquare(edge.x+edge.dx,edge.y+edge.dy,edge.z)
                    local door=assert(a and b and a:getDoorTo(b),"selected door not loaded")
                    assert(instanceof(door,"IsoDoor"),"only an ordinary IsoDoor fixture is allowed")
                    assert(IsoDoor.getDoubleDoorIndex(door)==-1 and IsoDoor.getGarageDoorIndex(door)==-1,
                        "multi-panel door fixture is unsupported")
                    assert(not door:isLocked() and not door:isLockedByKey() and not door:isBarricaded(),
                        "locked or barricaded fixture refused")
                    active.door=door;active.wasOpen=door:isOpen()
                    if active.wasOpen then door:ToggleDoorSilent();door:syncIsoObject(false,0,nil,nil) end
                    assert(not door:isOpen(),"door fixture did not close")
                    log("fixture=closed_selected_door original_open="..tostring(active.wasOpen)
                        .." x="..edge.x.." y="..edge.y.." z="..edge.z)
                end)
                if not prepared then log("fixture_failed="..tostring(err));cleanup("fixture_failed") end
            end
            return
        end
    end
end)

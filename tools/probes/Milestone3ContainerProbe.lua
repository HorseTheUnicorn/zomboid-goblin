-- Disposable local server only. Normal task dispatch; no Goblin teleport,
-- container content, key, lock, or recipe mutation by this observer.
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-container.flag",false)
if not reader then return end
local owner=reader:readLine()
local mode=reader:readLine();reader:close()
if owner~="m3path_61" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Brain=require("GoblinSurvivor/GoblinBrain")
local Jobs=require("GoblinSurvivor/GoblinJobs")
local original=Jobs.update
local active,fired,ready=nil,false,nil
local function log(s) print("[GoblinSurvivor] M3_CONTAINER "..s) end
local function announce(payload,phase)
    if mode=="two-clients" then
        local p=payload.container_point
        sendServerCommand("GoblinM3Probe","container",{x=math.floor(p.x),y=math.floor(p.y),
            z=p.z,id=payload.container_id,phase=phase})
    end
end
local function contents(payload)
    local square=World.square(payload.container_point)
    assert(square,"container square unloaded")
    for _,object in ipairs(World.values(square:getObjects())) do
        if object:getModData().GoblinAccessContainerID==payload.container_id then
            local ids={};local items=object:getContainer():getItems()
            for i=0,items:size()-1 do ids[#ids+1]=tostring(items:get(i):getID()) end
            table.sort(ids)
            return table.concat(ids,",")
        end
    end
    error("selected container missing")
end
Jobs.update=function(body,task,payload,now)
    if mode=="resume" and not fired and task=="GAIN_ACCESS" and Body.owner(body)==owner
        and payload.access_method=="CONTAINER" then
        fired=true;active={body=body,started=getTimestampMs(),before=payload.m3_probe_contents}
        log("restored_payload="..tostring(type(payload.m3_probe_contents)=="string")
            .." target="..tostring(payload.container_id))
    end
    local t=active
    if t and body==t.body and task=="GAIN_ACCESS" and not t.before then
        local ok,value=pcall(contents,payload)
        t.before=ok and value or nil;t.readFailed=not ok
        log("target="..tostring(payload.container_id).." contents_read="..tostring(ok))
        log("initial_items="..tostring(value))
        announce(payload,"initial")
    end
    if t and mode=="hold-for-save" and body==t.body and task=="GAIN_ACCESS"
        and getTimestampMs()-t.started<180000 then
        if not t.held then
            t.held=true;payload.m3_probe_contents=t.before
            log("holding_for_save=true target="..tostring(payload.container_id))
        end
        return {done=false,success=true,code="WORKING",detail="local persistence fixture hold",progress=0}
    end
    local result=original(body,task,payload,now)
    if t and body==t.body and task=="GAIN_ACCESS" then
        if not t.last or now-t.last>=1000 or result.done then
            t.last=now;local p=Body.position(body)
            log("code="..tostring(result.code).." x="..p.x.." y="..p.y.." z="..p.z
                .." done="..tostring(result.done).." success="..tostring(result.success))
        end
        if result.done then
            local ok,value=pcall(contents,payload)
            log("terminal_contents_unchanged="..tostring(ok and not t.readFailed and value==t.before))
            announce(payload,"terminal")
            t.finished=true
        end
    end
    return result
end
Events.OnTick.Add(function()
    if active then
        local timeout=mode=="hold-for-save" and 185000 or 65000
        if active.finished or getTimestampMs()-active.started>timeout then
            local body=active.body;active=nil;Jobs.update=original
            log("cleanup=true");Brain.setTask(body,"FOLLOW",{manual=true})
        end
        return
    end
    if fired or mode=="resume" or not getCell() then return end
    if mode=="two-clients" then
        local nearby=false
        for _,player in ipairs(World.values(getOnlinePlayers())) do
            if player:getUsername()=="m3witness_54" and player:getZ()==0
                and math.abs(player:getX()-10779.5)<5 and math.abs(player:getY()-9765.5)<5 then nearby=true end
        end
        if not nearby then ready=nil;return end
    end
    for _,player in ipairs(World.values(getOnlinePlayers())) do
        if player:getUsername()==owner and math.abs(player:getX()-10779.5)<2
            and math.abs(player:getY()-9765.5)<2 then
            ready=ready or getTimestampMs()
            if getTimestampMs()-ready<15000 then return end
            for _,body in ipairs(World.values(getCell():getZombieList())) do
                if Body.isGoblin(body) and Body.owner(body)==owner then
                    fired=true;active={body=body,started=getTimestampMs()}
                    local ok,accepted,detail=pcall(Brain.setTask,body,"GAIN_ACCESS",{target={kind="CONTAINER"}})
                    log("dispatch="..tostring(ok).." accepted="..tostring(accepted).." detail="..tostring(detail))
                    if not ok or not accepted then active.finished=true end
                    return
                end
            end
        end
    end
end)

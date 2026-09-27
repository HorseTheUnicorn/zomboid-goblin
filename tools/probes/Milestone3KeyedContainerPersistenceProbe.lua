-- Disposable local server fixture. Proves a normal matching-key CONTAINER
-- GAIN_ACCESS task, its native crate/key/content identities and its lock state
-- survive an actual server save/restart before the managed IsoZombie resumes.
-- Never package this file with the released mod.
if _G.GOBLIN_M3_KEYED_PERSISTENCE_LOADED then return end
_G.GOBLIN_M3_KEYED_PERSISTENCE_LOADED=true
print("[GoblinSurvivor] M3_KEYED_PERSISTENCE probe_loaded=true server="
    ..tostring(type(isServer)=="function" and isServer())
    .." profile="..tostring(type(getServerName)=="function" and getServerName()))
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-keyed-persistence.flag",false)
if not reader then return end
local owner=reader:readLine();local witness=reader:readLine();local mode=reader:readLine();reader:close()
if owner~="m3path_61" or witness~="m3witness_54"
    or (mode~="hold-for-save" and mode~="resume") then return end
print("[GoblinSurvivor] M3_KEYED_PERSISTENCE enabled=true mode="..mode
    .." owner="..owner.." witness="..witness)
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Brain=require("GoblinSurvivor/GoblinBrain")
local Jobs=require("GoblinSurvivor/GoblinJobs")
local Persistence=require("GoblinSurvivor/GoblinPersistence")
local original=Jobs.update
local fixture,active,fired=nil,nil,false
local keyId=214660143
local function log(message) print("[GoblinSurvivor] M3_KEYED_PERSISTENCE "..message) end
local function witnessReady()
    for _,candidate in ipairs(World.values(getOnlinePlayers())) do
        if candidate:getUsername()==witness and candidate:getCurrentSquare() then return true end
    end
    return false
end
local function itemIds(container)
    local result={}
    for _,item in ipairs(World.items(container)) do result[#result+1]=tostring(item:getID()) end
    table.sort(result);return table.concat(result,",")
end
local function findKey(body,id,itemId)
    for _,item in ipairs(World.items(body:getInventory())) do
        if World.fullType(item)=="Base.KeyPadlock" and item:getKeyId()==id
            and (not itemId or tostring(item:getID())==tostring(itemId)) then return item end
    end
end
local function target(payload)
    local square=World.square(payload.container_point)
    if not square then return nil,nil end
    local found
    for _,object in ipairs(World.values(square:getObjects())) do
        local data=object:getModData()
        if data.GoblinAccessContainerID==payload.container_id then
            if found then return nil,square end
            found=object
        end
    end
    return found,square
end
local function notify(t,phase)
    sendServerCommand("GoblinM3Probe","keyed-persistence",{
        x=t.square:getX(),y=t.square:getY(),z=t.square:getZ(),id=t.payload.container_id,
        phase=phase,items=t.contents,key_id=keyId,key_item_id=t.keyItemId})
end
local function cleanup(reason)
    local t=fixture;fixture=nil;active=nil;Jobs.update=original
    if not t then log("cleanup=true reason="..tostring(reason).." no_fixture=true");return end
    local ok,err=pcall(function()
        local key=t.key or findKey(t.body,keyId,t.keyItemId)
        if key then t.body:getInventory():Remove(key) end
        assert(not findKey(t.body,keyId,t.keyItemId),"fixture key remains")
        if t.crate and t.crate:getObjectIndex()>=0 then
            t.square:transmitRemoveItemFromSquare(t.crate)
        end
        assert(not t.crate or t.crate:getObjectIndex()<0,"fixture crate remains")
        Brain.setTask(t.body,"FOLLOW",{manual=true})
    end)
    log("cleanup="..tostring(ok).." reason="..tostring(reason)
        ..(ok and "" or " error="..tostring(err)))
end
local function onlyFixtureSquare(t,callback)
    local saved=World.square
    World.square=function(point)
        if point and math.floor(point.x)==t.square:getX()
            and math.floor(point.y)==t.square:getY() and math.floor(point.z)==t.square:getZ() then
            return t.square
        end
        return nil
    end
    local ok,a,b=pcall(callback);World.square=saved
    if not ok then error(a) end
    return a,b
end
local function chooseSquare(body,player)
    -- Choose through an actual short walkable route from Goblin, not merely a
    -- geometrically nearby tile that may sit across an exterior wall.
    local start=World.square(Body.position(body));if not start then return nil end
    local queue={{square=start,depth=0}};local seen={}
    seen[start:getX()..":"..start:getY()..":"..start:getZ()]=true
    local best,bestDepth
    local index=1
    while index<=#queue do
        local node=queue[index]
        if node.depth>0 then
            local hasContainer=false
            for _,object in ipairs(World.values(node.square:getObjects())) do
                if select(2,World.call(object,"getContainer")) then hasContainer=true;break end
            end
            if not hasContainer and (not bestDepth or node.depth>bestDepth) then
                best,bestDepth=node.square,node.depth
            end
        end
        if node.depth<3 then
            for _,offset in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
                local nextSquare=World.square({x=node.square:getX()+offset[1],
                    y=node.square:getY()+offset[2],z=node.square:getZ()})
                if nextSquare then
                    local key=nextSquare:getX()..":"..nextSquare:getY()..":"..nextSquare:getZ()
                    local freeOK,free=World.call(nextSquare,"isFree",false)
                    local blockedOK,blocked=World.call(node.square,"isBlockedTo",nextSquare)
                    if not seen[key] and freeOK and free==true and blockedOK and blocked==false then
                        seen[key]=true;queue[#queue+1]={square=nextSquare,depth=node.depth+1}
                    end
                end
            end
        end
        index=index+1
    end
    return best,bestDepth and bestDepth*bestDepth or nil
end
local function createFixture(body,player)
    local square,separation=chooseSquare(body,player)
    assert(square,"no empty loaded fixture square")
    assert(not body:getInventory():haveThisKeyId(keyId),"fixture key collision")
    local t={body=body,square=square,started=getTimestampMs()};fixture=t
    t.crate=IsoThumpable.new(getCell(),square,"carpentry_01_16",false,{})
    t.crate:setIsContainer(true)
    local container=t.crate:getContainer();assert(container,"native container missing")
    local nail=container:AddItem("Base.Nails");assert(nail,"fixture content unavailable")
    t.contents=itemIds(container);assert(t.contents~="","fixture content missing")
    t.crate:getModData().GoblinM3KeyedPersistence=true
    -- Registration must precede lock setters that emit SyncThumpable packets.
    square:AddSpecialObject(t.crate);t.crate:transmitCompleteItemToClients()
    t.crate:setKeyId(keyId);t.crate:setLockedByPadlock(true)
    t.key=body:getInventory():AddItem("Base.KeyPadlock");assert(t.key,"fixture key unavailable")
    t.key:setKeyId(keyId);t.keyItemId=tostring(t.key:getID())
    assert(t.crate:isLockedToCharacter(body)==false,"native matching key rejected")
    local accepted,detail=onlyFixtureSquare(t,function()
        return Brain.setTask(body,"GAIN_ACCESS",{target={kind="CONTAINER"}})
    end)
    assert(accepted,"normal task refused fixture: "..tostring(detail))
    local payload=Body.data(body).GoblinTaskPayload
    assert(payload and payload.access_method=="CONTAINER","container task payload missing")
    assert(math.floor(payload.container_point.x)==square:getX()
        and math.floor(payload.container_point.y)==square:getY(),"normal task selected another container")
    payload.m3_keyed_persistence=true;payload.m3_probe_contents=t.contents
    payload.m3_probe_key_id=keyId;payload.m3_probe_key_item_id=t.keyItemId
    t.payload=payload;active=t
    local saved,status=Persistence.save(body,true)
    assert(saved,"fixture key inventory checkpoint failed: "..tostring(status))
    notify(t,"hold-ready")
    log("holding_for_save=true target="..payload.container_id
        .." items="..t.contents.." key_item_id="..t.keyItemId
        .." locked=true actor_access=true inventory_checkpoint="..tostring(status)
        .." separation_d2="..tostring(separation))
end
local function restoreFixture(body,payload)
    local crate,square=target(payload)
    assert(crate and crate:getContainer(),"saved keyed container target missing")
    local key=findKey(body,payload.m3_probe_key_id,payload.m3_probe_key_item_id)
    assert(key,"saved matching key identity missing")
    local t={body=body,payload=payload,crate=crate,square=square,key=key,
        keyItemId=tostring(key:getID()),contents=payload.m3_probe_contents,
        started=getTimestampMs()}
    fixture=t;active=t
    assert(itemIds(crate:getContainer())==t.contents,"saved content identity changed")
    assert(crate:isLockedByPadlock() and crate:getKeyId()==payload.m3_probe_key_id,
        "saved padlock state changed")
    assert(crate:isLockedToCharacter(body)==false,"saved matching key no longer grants access")
    notify(t,"resume-ready")
    log("restored_payload=true target="..payload.container_id
        .." contents_unchanged=true locked=true key_retained=true key_identity=true")
end
Jobs.update=function(body,task,payload,now)
    if mode=="resume" and not active and task=="GAIN_ACCESS" and Body.owner(body)==owner
        and payload.m3_keyed_persistence==true then
        if not witnessReady() then
            return {done=false,success=true,code="WORKING",
                detail="waiting for two-client persistence observation",progress=0}
        end
        fired=true
        local ok,err=pcall(restoreFixture,body,payload)
        if not ok then log("resume_failed="..tostring(err));return original(body,task,payload,now) end
    end
    local t=active
    if t and body==t.body and task=="GAIN_ACCESS"
        and payload.container_id==t.payload.container_id then
        if mode=="hold-for-save" then
            return {done=false,success=true,code="WORKING",
                detail="local keyed persistence fixture hold",progress=0}
        end
        local result=original(body,task,payload,now)
        if not t.lastLog or now-t.lastLog>=500 or result.done then
            t.lastLog=now;local p=Body.position(body)
            log("code="..tostring(result.code).." x="..p.x.." y="..p.y.." z="..p.z
                .." locked="..tostring(t.crate:isLockedByPadlock())
                .." key_retained="..tostring(findKey(body,keyId,t.keyItemId)~=nil))
        end
        if result.done and not t.finishedAt then
            local unchanged=itemIds(t.crate:getContainer())==t.contents
            local success=result.success and unchanged and t.crate:isLockedByPadlock()
                and findKey(body,keyId,t.keyItemId)~=nil
            log("terminal="..tostring(result.code).." success="..tostring(success)
                .." result_success="..tostring(result.success)
                .." contents_unchanged="..tostring(unchanged)
                .." locked="..tostring(t.crate:isLockedByPadlock())
                .." key_retained="..tostring(findKey(body,keyId,t.keyItemId)~=nil))
            notify(t,"resume-terminal");t.finishedAt=getTimestampMs()
        end
        return result
    end
    return original(body,task,payload,now)
end
Events.OnTick.Add(function()
    if fixture then
        local now=getTimestampMs()
        if fixture.finishedAt and now-fixture.finishedAt>=5000 then cleanup("complete")
        elseif now-fixture.started>180000 then cleanup("timeout") end
        return
    end
    if fired or mode=="resume" or not getCell() then return end
    local player,witnessPlayer
    for _,candidate in ipairs(World.values(getOnlinePlayers())) do
        if candidate:getUsername()==owner then player=candidate end
        if candidate:getUsername()==witness then witnessPlayer=candidate end
    end
    if not player or not witnessPlayer or not player:getCurrentSquare()
        or not witnessPlayer:getCurrentSquare() then return end
    for _,body in ipairs(World.values(getCell():getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner and body:getCurrentSquare()
            and not body:getVehicle() then
            fired=true
            local ok,err=pcall(createFixture,body,player)
            if not ok then log("setup_failed="..tostring(err));cleanup("setup-failed") end
            return
        end
    end
end)

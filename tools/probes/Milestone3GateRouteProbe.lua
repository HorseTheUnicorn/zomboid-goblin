-- Disposable local server fixture. Exercises the normal
-- Brain -> GAIN_ACCESS -> native padlock transfer -> physical gate crossing
-- route. Three temporary blocking squares prevent the actor from walking
-- around the freestanding test gate. Never package this file with the mod.
if _G.GOBLIN_M3_GATE_ROUTE_LOADED then return end
_G.GOBLIN_M3_GATE_ROUTE_LOADED=true
if not isServer() or getServerName()~="goblin-local" then return end
print("[GoblinSurvivor] M3_GATE_ROUTE probe_entry=true")
local reader=getFileReader("goblin-m3-gate-route.flag",false)
if not reader then return end
local owner=reader:readLine();local witness=reader:readLine();reader:close()
if owner~="m3path_61" or witness~="m3witness_54" then return end
print("[GoblinSurvivor] M3_GATE_ROUTE probe_loaded=true owner="..owner.." witness="..witness)

local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Brain=require("GoblinSurvivor/GoblinBrain")
local Access=require("GoblinSurvivor/GoblinAccess")
local Jobs=require("GoblinSurvivor/GoblinJobs")
local originalUpdate=Jobs.update
local ready={}
local active,fired=nil,false
local lockId=214660151
local function log(message) print("[GoblinSurvivor] M3_GATE_ROUTE "..message) end

Events.OnClientCommand.Add(function(module,command,player,args)
    if module~="GoblinM3Probe" or command~="gate-route-ready" or not player then return end
    local account=player:getUsername()
    if account==owner or account==witness then
        ready[account]=true;log("client_ready="..account)
    end
end)

local function fixtureItem(body,item)
    if not item then return false end
    local fullType=World.fullType(item)
    return (fullType=="Base.KeyPadlock" or fullType=="Base.Padlock")
        and item:getKeyId()==lockId
end

local function removeObject(square,object)
    if object and object:getObjectIndex()>=0 then square:transmitRemoveItemFromSquare(object) end
end

local function cleanup(reason)
    local t=active;active=nil;Jobs.update=originalUpdate
    if not t then log("cleanup=true reason="..tostring(reason).." no_fixture=true");return end
    local ok,err=pcall(function()
        for _,item in ipairs(World.items(t.body:getInventory())) do
            if not t.inventoryBefore[item] and fixtureItem(t.body,item) then
                t.body:getInventory():Remove(item)
            end
        end
        removeObject(t.gateSquare,t.gate)
        for _,entry in ipairs(t.blockers) do removeObject(entry.square,entry.object) end
        assert(not t.gate or t.gate:getObjectIndex()<0,"fixture gate remains")
        for _,entry in ipairs(t.blockers) do
            assert(entry.object:getObjectIndex()<0,"fixture blocker remains")
        end
        Brain.setTask(t.body,"FOLLOW",{manual=true})
    end)
    log("cleanup="..tostring(ok).." reason="..tostring(reason)
        ..(ok and "" or " error="..tostring(err)))
end

local function notify(t,phase,success)
    sendServerCommand("GoblinM3Probe","gate-route",{
        phase=phase,success=success==true,id=t.marker,owner=owner,
        x=t.gateSquare:getX(),y=t.gateSquare:getY(),z=t.gateSquare:getZ(),
        from_x=t.center:getX(),from_y=t.center:getY(),
        to_x=t.destination:getX(),to_y=t.destination:getY(),key_id=lockId})
end

local function noEdgeObject(a,b)
    return not a:getDoorTo(b) and not a:getWindowTo(b) and not a:getHoppableTo(b)
end

local function validCenter(body,ownerPlayer)
    local center=body:getCurrentSquare()
    if not center or center:getZ()~=0 or center:getRoom() then return nil end
    local ownerSquare=ownerPlayer:getCurrentSquare()
    if not ownerSquare or ownerSquare:getZ()~=center:getZ() then return nil end
    local dx=ownerPlayer:getX()-body:getX();local dy=ownerPlayer:getY()-body:getY()
    if dx*dx+dy*dy>25 then return nil end
    local neighbors={
        north=getCell():getGridSquare(center:getX(),center:getY()-1,center:getZ()),
        south=getCell():getGridSquare(center:getX(),center:getY()+1,center:getZ()),
        west=getCell():getGridSquare(center:getX()-1,center:getY(),center:getZ()),
        east=getCell():getGridSquare(center:getX()+1,center:getY(),center:getZ())}
    for _,square in pairs(neighbors) do
        if not square or not square:isFree(false) or not noEdgeObject(center,square) then return nil end
    end
    return center,neighbors
end

local function addBlocker(square,marker)
    local object=IsoThumpable.new(getCell(),square,"carpentry_02_80",false,{})
    object:setBlockAllTheSquare(true)
    object:getModData().GoblinM3GateRouteBlocker=marker
    square:AddSpecialObject(object);object:transmitCompleteItemToClients()
    return {square=square,object=object}
end

local function createFixture(body,player)
    local center,neighbors=validCenter(body,player)
    assert(center and neighbors,"actor is not on a clear outdoor fixture square")
    assert(not body:getInventory():haveThisKeyId(lockId),"fixture key collision")
    local t={body=body,center=center,destination=neighbors.north,gateSquare=center,
        marker=owner..":"..tostring(getTimestampMs()),blockers={},inventoryBefore={},
        started=getTimestampMs()}
    active=t
    for _,item in ipairs(World.items(body:getInventory())) do t.inventoryBefore[item]=true end

    -- The gate is on the north edge of the actor's current square. Blocking
    -- east/south/west leaves the north gate as the only physical exit.
    t.blockers[#t.blockers+1]=addBlocker(neighbors.east,t.marker)
    t.blockers[#t.blockers+1]=addBlocker(neighbors.south,t.marker)
    t.blockers[#t.blockers+1]=addBlocker(neighbors.west,t.marker)
    t.gate=IsoThumpable.new(getCell(),center,"fixtures_doors_01_0",
        "fixtures_doors_01_1",true,{})
    t.gate:setIsDoor(true)
    t.gate:getModData().GoblinM3GateRouteID=t.marker
    -- Registration must precede lock setters that emit SyncThumpable packets.
    center:AddSpecialObject(t.gate);t.gate:transmitCompleteItemToClients()
    t.gate:setKeyId(lockId);t.gate:setLockedByPadlock(true)
    t.key=body:getInventory():AddItem("Base.KeyPadlock");assert(t.key,"fixture key unavailable")
    t.key:setKeyId(lockId);t.keyItemId=tostring(t.key:getID())

    local edge={x=center:getX(),y=center:getY()-1,z=center:getZ(),dx=0,dy=1}
    local originalScope=Access.resolveTargetScope
    Access.resolveTargetScope=function()
        return {bounds={x=edge.x,y=edge.y,x2=edge.x,y2=edge.y,
            min_z=edge.z,max_z=edge.z}}
    end
    local ok,accepted,detail=pcall(Brain.setTask,body,"GAIN_ACCESS",{target={kind="YARD"}})
    Access.resolveTargetScope=originalScope
    assert(ok,"normal route dispatch threw: "..tostring(accepted))
    assert(accepted,"normal route refused fixture: "..tostring(detail))
    local payload=Body.data(body).GoblinTaskPayload
    assert(payload and payload.access_method=="DOOR","normal task did not select gate")
    assert(payload.edge.x==edge.x and payload.edge.y==edge.y
        and payload.edge.dx==0 and payload.edge.dy==1,"normal task selected another edge")
    t.payload=payload
    notify(t,"ready",false)
    log("accepted=true marker="..t.marker.." key_item_id="..t.keyItemId
        .." from_x="..center:getX().." from_y="..center:getY()
        .." to_x="..neighbors.north:getX().." to_y="..neighbors.north:getY()
        .." locked=true blockers=3")
end

Jobs.update=function(body,task,payload,now)
    local result=originalUpdate(body,task,payload,now)
    local t=active
    if not t or body~=t.body or task~="GAIN_ACCESS" or payload~=t.payload then return result end
    if not t.lastLog or now-t.lastLog>=500 or result.done then
        t.lastLog=now
        log("code="..tostring(result.code).." x="..tostring(body:getX())
            .." y="..tostring(body:getY()).." open="..tostring(t.gate:IsOpen())
            .." padlocked="..tostring(t.gate:isLockedByPadlock()))
    end
    if result.done and not t.finishedAt then
        local outputs=0
        for _,item in ipairs(World.items(body:getInventory())) do
            if not t.inventoryBefore[item] and World.fullType(item)=="Base.Padlock"
                and item:getKeyId()==lockId then outputs=outputs+1 end
        end
        local crossed=body:getCurrentSquare()==t.destination
        local keyConsumed=not body:getInventory():contains(t.key)
        local success=result.success==true and result.code=="COMPLETE" and crossed
            and t.gate:IsOpen() and not t.gate:isLockedByPadlock()
            and t.gate:getKeyId()==-1 and keyConsumed and outputs==1
        log("terminal="..tostring(result.code).." success="..tostring(success)
            .." result_success="..tostring(result.success).." crossed="..tostring(crossed)
            .." open="..tostring(t.gate:IsOpen())
            .." padlocked="..tostring(t.gate:isLockedByPadlock())
            .." key_id="..tostring(t.gate:getKeyId())
            .." key_consumed="..tostring(keyConsumed).." returned_padlocks="..outputs)
        notify(t,"terminal",success);t.finishedAt=getTimestampMs()
    end
    return result
end

Events.OnTick.Add(function()
    if active then
        local now=getTimestampMs()
        if active.finishedAt and now-active.finishedAt>=10000 then cleanup("complete")
        elseif now-active.started>120000 then cleanup("timeout") end
        return
    end
    if fired or not ready[owner] or not ready[witness] or not getCell() then return end
    local player,witnessPlayer
    for _,candidate in ipairs(World.values(getOnlinePlayers())) do
        if candidate:getUsername()==owner then player=candidate end
        if candidate:getUsername()==witness then witnessPlayer=candidate end
    end
    if not player or not witnessPlayer or not player:getCurrentSquare()
        or not witnessPlayer:getCurrentSquare() then return end
    local ownerDx,ownerDy=player:getX()-10784.5,player:getY()-9774.5
    local witnessDx,witnessDy=witnessPlayer:getX()-10786.5,witnessPlayer:getY()-9774.5
    if ownerDx*ownerDx+ownerDy*ownerDy>16
        or witnessDx*witnessDx+witnessDy*witnessDy>16 then return end
    for _,body in ipairs(World.values(getCell():getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner and body:getCurrentSquare()
            and not body:getVehicle() and validCenter(body,player) then
            fired=true
            local ok,err=pcall(createFixture,body,player)
            if not ok then log("setup_failed="..tostring(err));cleanup("setup-failed") end
            return
        end
    end
end)

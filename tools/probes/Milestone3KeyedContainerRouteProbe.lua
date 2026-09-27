-- Disposable local test: normal GAIN_ACCESS against an actual keyed container.
-- Not part of GoblinSurvivor. Creates/removes only its own crate and key.
if _G.GOBLIN_M3_KEYED_ROUTE_LOADED then return end
_G.GOBLIN_M3_KEYED_ROUTE_LOADED=true
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-keyed-container-route.flag",false)
if not reader then return end
local owner=reader:readLine();local witness=reader:readLine();reader:close()
if owner~="m3path_61" or witness~="m3witness_54" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Policy=require("GoblinSurvivor/GoblinAccessPolicy")
local Access=require("GoblinSurvivor/GoblinContainerAccess")
local Brain=require("GoblinSurvivor/GoblinBrain")
local Jobs=require("GoblinSurvivor/GoblinJobs")
local original=Jobs.update
local fixture,active,fired=nil,nil,false
local function log(s) print("[GoblinSurvivor] M3_KEYED_CONTAINER "..s) end
log("probe_loaded owner="..owner.." witness="..witness)
local function notify(payload,phase)
    sendServerCommand("GoblinM3Probe","container",{x=math.floor(payload.container_point.x),
        y=math.floor(payload.container_point.y),z=payload.container_point.z,
        id=payload.container_id,phase=phase})
end
local function contents(target)
    local ids={}
    for _,item in ipairs(World.items(target:getContainer())) do ids[#ids+1]=tostring(item:getID()) end
    table.sort(ids);return table.concat(ids,",")
end
local function cleanup(reason)
    local t=fixture;fixture=nil;active=nil;Jobs.update=original
    if not t then return end
    if t.key and t.body then
        local ok=pcall(function() t.body:getInventory():Remove(t.key) end)
        log("key_cleanup="..tostring(ok and not t.body:getInventory():contains(t.key)))
    end
    if t.crate and t.square and t.crate:getObjectIndex()>=0 then
        local ok=pcall(function()
            t.square:transmitRemoveItemFromSquare(t.crate)
            assert(t.crate:getObjectIndex()<0,"fixture crate remains")
        end)
        log("crate_cleanup="..tostring(ok))
    end
    if t.body then pcall(Brain.setTask,t.body,"FOLLOW",{manual=true}) end
    log("cleanup="..tostring(reason))
end
local function closestAccessible(body,point)
    local best=math.huge
    for dx=-5,5 do for dy=-5,5 do
        if dx*dx+dy*dy<=25 then
            local square=World.square({x=math.floor(point.x)+dx,y=math.floor(point.y)+dy,z=point.z})
            if square then for _,object in ipairs(World.values(square:getObjects())) do
                if select(2,World.call(object,"getContainer")) and Policy.access(body,object)
                    and World.containerAccessible(body,object) then
                    local p=World.point(square);local d=(p.x-point.x)^2+(p.y-point.y)^2
                    if d<best then best=d end
                end
            end end
        end
    end end
    return best
end
local function createFixture(body,player)
    local p=Body.position(player);local best=closestAccessible(body,p)
    local square,distance
    -- Prefer the owner's occupied tile when it has no container. The player
    -- fixture deliberately stands on an otherwise empty floor tile, making
    -- this temporary crate unambiguously nearer than house furniture while
    -- still leaving Goblin to traverse the normal route from his own body.
    local origin=World.square({x=math.floor(p.x),y=math.floor(p.y),z=p.z})
    if origin then
        local hasContainer=false
        for _,object in ipairs(World.values(origin:getObjects())) do
            if select(2,World.call(object,"getContainer")) then hasContainer=true;break end
        end
        if not hasContainer then
            local q=World.point(origin)
            square=origin;distance=(q.x-p.x)^2+(q.y-p.y)^2
        end
    end
    for dx=-5,5 do for dy=-5,5 do
        if dx*dx+dy*dy<=25 then
            local candidate=World.square({x=math.floor(p.x)+dx,y=math.floor(p.y)+dy,z=p.z})
            if candidate then
                local hasContainer=false
                for _,object in ipairs(World.values(candidate:getObjects())) do
                    if select(2,World.call(object,"getContainer")) then hasContainer=true;break end
                end
                local freeOK,free=World.call(candidate,"isFree",false)
                local q=World.point(candidate);local d=(q.x-p.x)^2+(q.y-p.y)^2
                if not square and not hasContainer and freeOK and free==true and d<best
                    and (not distance or d<distance) then
                    square,distance=candidate,d
                end
            end
        end
    end end
    if not square then return nil,"no empty square closer than existing containers" end
    local t={body=body,square=square}
    fixture=t
    local ok,err=pcall(function()
        t.crate=IsoThumpable.new(getCell(),square,"carpentry_01_16",false,{})
        t.crate:setIsContainer(true)
        assert(t.crate:getContainer(),"native container missing")
        local id=214660131
        assert(not body:getInventory():haveThisKeyId(id),"fixture key collision")
        -- Register and transmit the object before setters that emit
        -- SyncThumpable packets. Sending those while getObjectIndex() is -1
        -- makes Build 42 clients reject the packet before the full object
        -- arrives.
        square:AddSpecialObject(t.crate);t.crate:transmitCompleteItemToClients()
        t.crate:setKeyId(id);t.crate:setLockedByPadlock(true)
        t.key=body:getInventory():AddItem("Base.KeyPadlock")
        assert(t.key,"Base.KeyPadlock unavailable");t.key:setKeyId(id)
        assert(t.crate:isLockedToCharacter(body)==false,"native matching key rejected")
        local payload,detail=Access.prepare(body,player,getTimestampMs())
        assert(payload and payload.container_id,"container prepare failed: "..tostring(detail))
        assert(math.floor(payload.container_point.x)==square:getX()
            and math.floor(payload.container_point.y)==square:getY(),"selector chose another container")
        t.payload=payload;t.before=contents(t.crate)
        assert(t.before=="","fixture crate not empty")
        local accepted,reply=Brain.setTask(body,"GAIN_ACCESS",{target={kind="CONTAINER"}})
        assert(accepted,reply)
        local saved=Body.data(body).GoblinTaskPayload
        assert(saved and saved.container_id==payload.container_id,"normal task selected another container")
        t.payload=saved;t.started=getTimestampMs();active=t
        log("accepted=true target="..saved.container_id.." x="..square:getX().." y="..square:getY()
            .." start_x="..p.x.." start_y="..p.y.." d2="..distance)
        notify(saved,"initial")
    end)
    if not ok then cleanup("setup_failed="..tostring(err));return false end
    return true
end
Jobs.update=function(body,task,payload,now)
    local result=original(body,task,payload,now)
    local t=active
    if t and body==t.body and task=="GAIN_ACCESS" and payload.container_id==t.payload.container_id then
        if not t.lastLog or now-t.lastLog>=500 or result.done then
            t.lastLog=now;local p=Body.position(body)
            log("code="..tostring(result.code).." x="..p.x.." y="..p.y.." z="..p.z
                .." locked="..tostring(t.crate:isLockedByPadlock())
                .." actor_access="..tostring(t.crate:isLockedToCharacter(body)==false)
                .." key_retained="..tostring(body:getInventory():contains(t.key)))
        end
        if result.done then
            local unchanged=contents(t.crate)==t.before
            local success=result.success and unchanged and t.crate:isLockedByPadlock()
                and body:getInventory():contains(t.key)
            log("terminal="..tostring(result.code).." success="..tostring(success)
                .." result_success="..tostring(result.success).." contents_unchanged="..tostring(unchanged)
                .." locked="..tostring(t.crate:isLockedByPadlock())
                .." key_retained="..tostring(body:getInventory():contains(t.key)))
            notify(payload,"terminal")
            t.finished=true
        end
    end
    return result
end
Events.OnTick.Add(function()
    if fixture then
        if fixture.finished or getTimestampMs()-fixture.started>65000 then cleanup("terminal_or_timeout") end
        return
    end
    if fired or not getCell() then return end
    local players=World.values(getOnlinePlayers());local p,w;local online={}
    for _,player in ipairs(players) do
        local pos=Body.position(player)
        local username=tostring(player:getUsername())
        online[#online+1]=username.."@"..tostring(pos and (pos.x..":"..pos.y..":"..pos.z) or "no_position")
        if username==owner then p=player end
        if username==witness then w=player end
        if pos and username==owner and math.abs(pos.x-10779.5)<2 and math.abs(pos.y-9765.5)<2 then p=player end
    end
    local near=w and w:getZ()==0 and math.abs(w:getX()-10779.5)<5 and math.abs(w:getY()-9765.5)<5
    local now=getTimestampMs()
    if not _G.GOBLIN_M3_KEYED_ROUTE_DIAGNOSTIC or now-_G.GOBLIN_M3_KEYED_ROUTE_DIAGNOSTIC>=5000 then
        _G.GOBLIN_M3_KEYED_ROUTE_DIAGNOSTIC=now
        log("readiness owner="..tostring(p and (p:getX()..":"..p:getY()..":"..p:getZ()))
            .." witness="..tostring(w and (w:getX()..":"..w:getY()..":"..w:getZ()))
            .." witness_near="..tostring(near).." online="..table.concat(online,"|"))
    end
    if not p or not near or math.abs(p:getX()-10779.5)>=2 or math.abs(p:getY()-9765.5)>=2 then return end
    for _,body in ipairs(World.values(getCell():getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner and body:getCurrentSquare() and not body:getVehicle() then
            fired=true;createFixture(body,p);return
        end
    end
end)

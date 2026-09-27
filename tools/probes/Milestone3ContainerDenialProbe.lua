-- Disposable local server fixture. Proves normal CONTAINER GAIN_ACCESS
-- refuses a real registered container when the managed IsoZombie has no
-- matching padlock key or the container has a combination lock. Never package
-- this file with the released mod.
if _G.GOBLIN_M3_CONTAINER_DENIAL_LOADED then return end
_G.GOBLIN_M3_CONTAINER_DENIAL_LOADED=true
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-container-denial.flag",false)
if not reader then return end
local owner=reader:readLine();local witness=reader:readLine();reader:close()
if owner~="m3path_61" or witness~="m3witness_54" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Brain=require("GoblinSurvivor/GoblinBrain")
local fired,fixture=false,nil
local function log(message) print("[GoblinSurvivor] M3_CONTAINER_DENIAL "..message) end
local function itemIds(container)
    local result={}
    for _,item in ipairs(World.items(container)) do result[#result+1]=tostring(item:getID()) end
    table.sort(result);return table.concat(result,",")
end
local function inventoryIds(body)
    return itemIds(body:getInventory())
end
local function notify(t,phase)
    sendServerCommand("GoblinM3Probe","container-denial",{
        x=t.square:getX(),y=t.square:getY(),z=t.square:getZ(),id=t.marker,
        phase=phase,items=t.contents})
end
local function cleanup(reason)
    local t=fixture;fixture=nil
    if not t then return end
    local ok,err=pcall(function()
        if t.crate and t.crate:getObjectIndex()>=0 then
            t.square:transmitRemoveItemFromSquare(t.crate)
        end
        assert(not t.crate or t.crate:getObjectIndex()<0,"fixture crate remains")
    end)
    log("cleanup="..tostring(ok).." reason="..tostring(reason)
        ..(ok and "" or " error="..tostring(err)))
end
local function onlyFixtureSquare(t,callback)
    local original=World.square
    World.square=function(point)
        if point and math.floor(point.x)==t.square:getX()
            and math.floor(point.y)==t.square:getY() and point.z==t.square:getZ() then
            return t.square
        end
        return nil
    end
    local ok,a,b=pcall(callback)
    World.square=original
    if not ok then error(a) end
    return a,b
end
local function assertNormalRefusal(t,mode)
    local body=t.body
    local beforeInventory=inventoryIds(body)
    local beforeContents=itemIds(t.crate:getContainer())
    local data=Body.data(body)
    local beforeTask,beforePayload=data.GoblinTask,data.GoblinTaskPayload
    local accepted,detail=onlyFixtureSquare(t,function()
        return Brain.setTask(body,"GAIN_ACCESS",{target={kind="CONTAINER"}})
    end)
    assert(not accepted,"normal task unexpectedly accepted "..mode)
    assert(type(detail)=="string" and string.find(detail,"no natively accessible container",1,true),
        "unexpected refusal detail: "..tostring(detail))
    assert(data.GoblinTask==beforeTask and data.GoblinTaskPayload==beforePayload,
        "refused task changed the active task")
    assert(inventoryIds(body)==beforeInventory,"refused task changed Goblin inventory")
    assert(itemIds(t.crate:getContainer())==beforeContents,"refused task changed contents")
    if mode=="missing-key" then
        assert(t.crate:isLockedByPadlock() and t.crate:getKeyId()==t.keyId,
            "missing-key refusal changed padlock")
        assert(not body:getInventory():haveThisKeyId(t.keyId),"fixture key appeared")
    else
        assert(t.crate:getLockedByCode()==t.code,"code refusal changed combination")
    end
    log("phase="..mode.." accepted=false detail="..detail
        .." contents_unchanged=true inventory_unchanged=true lock_unchanged=true")
end
local function findFixtureSquare(player)
    local p=Body.position(player)
    for radius=0,4 do
        for dx=-radius,radius do for dy=-radius,radius do
            if math.max(math.abs(dx),math.abs(dy))==radius then
                local square=World.square({x=math.floor(p.x)+dx,y=math.floor(p.y)+dy,z=p.z})
                if square then
                    local hasContainer=false
                    for _,object in ipairs(World.values(square:getObjects())) do
                        if select(2,World.call(object,"getContainer")) then hasContainer=true;break end
                    end
                    if not hasContainer then return square end
                end
            end
        end end
    end
end
local function createFixture(body,player)
    local square=findFixtureSquare(player)
    assert(square,"no empty loaded fixture square")
    local t={body=body,square=square,keyId=214660137,code=7419,
        marker="m3-denial-"..tostring(getTimestampMs()),phase="settle-missing",
        phaseAt=getTimestampMs()}
    fixture=t
    assert(not body:getInventory():haveThisKeyId(t.keyId),"fixture key collision")
    t.crate=IsoThumpable.new(getCell(),square,"carpentry_01_16",false,{})
    t.crate:setIsContainer(true)
    local container=t.crate:getContainer();assert(container,"native container missing")
    local nail=container:AddItem("Base.Nails");assert(nail,"fixture content unavailable")
    t.contents=itemIds(container);assert(t.contents~="","fixture content missing")
    t.crate:getModData().GoblinContainerDenialID=t.marker
    -- Register before setters emit SyncThumpable packets. An index -1 packet
    -- is a broken fixture, not evidence about Goblin access.
    square:AddSpecialObject(t.crate);t.crate:transmitCompleteItemToClients()
    t.crate:setKeyId(t.keyId);t.crate:setLockedByPadlock(true)
    assert(t.crate:isLockedToCharacter(body),"native missing-key check allowed actor")
    notify(t,"missing-key-ready")
    log("fixture_ready=true x="..square:getX().." y="..square:getY()
        .." z="..square:getZ().." contents="..t.contents)
end
Events.OnTick.Add(function()
    local t=fixture
    if t then
        local now=getTimestampMs()
        local ok,err=pcall(function()
            if t.phase=="settle-missing" and now-t.phaseAt>=3000 then
                assertNormalRefusal(t,"missing-key")
                notify(t,"missing-key-terminal")
                t.phase="settle-code";t.phaseAt=now
            elseif t.phase=="settle-code" and now-t.phaseAt>=3000 then
                t.crate:setLockedByPadlock(false);t.crate:setKeyId(-1)
                t.crate:setLockedByCode(t.code)
                assert(t.crate:isLockedToCharacter(t.body),"native code check allowed actor")
                notify(t,"code-ready")
                t.phase="dispatch-code";t.phaseAt=now
            elseif t.phase=="dispatch-code" and now-t.phaseAt>=3000 then
                assertNormalRefusal(t,"code-lock")
                notify(t,"code-terminal")
                t.phase="finish";t.phaseAt=now
            elseif t.phase=="finish" and now-t.phaseAt>=3000 then
                cleanup("complete")
            elseif now-t.started>30000 then
                error("probe timeout")
            end
        end)
        if not ok then log("failed="..tostring(err));cleanup("failed") end
        return
    end
    if fired or not getCell() then return end
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
            if not ok then log("setup_failed="..tostring(err));cleanup("setup-failed")
            else fixture.started=getTimestampMs() end
            return
        end
    end
end)

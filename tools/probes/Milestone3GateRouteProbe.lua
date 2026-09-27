-- Disposable local fixture. Exercises Brain -> registry -> padlock transfer
-- and attempts movement through a synthetic gate. The current fixture is a
-- freestanding gate in open ground, so native pathfinding may route around it;
-- its route result is NOT physical access acceptance. Use a wall-framed doorway
-- or enclosed fixture for that. Never package with the released mod.
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-gate-route.flag",false)
if not reader then return end
local owner=reader:readLine();reader:close()
if owner~="rejoinfang_74" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Brain=require("GoblinSurvivor/GoblinBrain")
local Access=require("GoblinSurvivor/GoblinAccess")
local Jobs=require("GoblinSurvivor/GoblinJobs")
local fired=false
local active
local originalUpdate=Jobs.update
local function log(s) print("[GoblinSurvivor] M3_GATE_ROUTE "..s) end
local function cleanup()
    local t=active
    Jobs.update=originalUpdate
    if not t then return end
    active=nil
    local ok,err=pcall(function()
        Brain.setTask(t.body,"WAIT",{})
        for _,item in ipairs(World.items(t.body:getInventory())) do
            if item==t.key or (item:getFullType()=="Base.Padlock" and item:getKeyId()==t.id) then
                t.body:getInventory():Remove(item)
            end
        end
        if t.gate and t.gate:getObjectIndex()>=0 then t.square:transmitRemoveItemFromSquare(t.gate) end
        assert(not t.gate or t.gate:getObjectIndex()<0)
        Brain.setTask(t.body,"FOLLOW",{})
    end)
    log("cleanup="..tostring(ok)..(ok and "" or " error="..tostring(err)))
end
Jobs.update=function(body,task,payload,now)
    local result=originalUpdate(body,task,payload,now)
    local t=active
    if t and body==t.body and task=="GAIN_ACCESS" then
        local observed,observationError=pcall(function()
        if not t.lastLog or now-t.lastLog>=500 or result.done then
            t.lastLog=now
            local p=Body.position(body)
            log("code="..result.code.." x="..p.x.." y="..p.y.." z="..p.z
                .." open="..tostring(t.gate:IsOpen()).." locked="..tostring(t.gate:isLockedByPadlock()))
        end
        if result.done then
            local outputs=0
            for _,item in ipairs(World.items(body:getInventory())) do
                if item:getFullType()=="Base.Padlock" and item:getKeyId()==t.id then outputs=outputs+1 end
            end
            t.finished=true
            log("terminal="..result.code.." success="..tostring(result.success)
                .." key_consumed="..tostring(not body:getInventory():contains(t.key))
                .." returned_padlocks="..outputs.." detail="..tostring(result.detail))
        end
        end)
        if not observed then
            t.finished=true
            log("observation_failed="..tostring(observationError))
        end
    end
    return result
end
Events.OnTick.Add(function()
    if active then
        if active.finished or getTimestampMs()-active.started>90000 then
            if not active.finished then log("terminal=PROBE_TIMEOUT") end
            cleanup()
        end
        return
    end
    if fired or not getCell() then return end
    for _,body in ipairs(World.values(getCell():getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner and body:getCurrentSquare() and not body:getVehicle() then
            fired=true
            local p=Body.position(body)
            local square,north
            for _,offset in ipairs({{3,0,false},{0,3,true},{-3,0,false},{0,-3,true}}) do
                local s=getCell():getGridSquare(math.floor(p.x)+offset[1],math.floor(p.y)+offset[2],math.floor(p.z))
                local other=s and getCell():getGridSquare(s:getX()-(offset[3] and 0 or 1),s:getY()-(offset[3] and 1 or 0),s:getZ())
                if s and other and s:isFree(false) and other:isFree(false)
                    and not s:getDoorTo(other) and not s:getWindowTo(other) then square=s;north=offset[3];break end
            end
            if not square then log("refused=no_free_fixture_edge");Jobs.update=originalUpdate;return end
            local id=214660124
            if body:getInventory():haveThisKeyId(id) then log("refused=fixture_key_collision");Jobs.update=originalUpdate;return end
            active={body=body,square=square,id=id,started=getTimestampMs()}
            local originalScope=Access.resolveTargetScope
            local ok,err=pcall(function()
                local t=active
                t.gate=IsoThumpable.new(getCell(),square,"fixtures_doors_01_0","fixtures_doors_01_1",north,{})
                t.gate:setIsDoor(true)
                -- Register the gate before lock setters emit SyncThumpable
                -- packets. Build 42 rejects a lock packet whose object still
                -- has index -1, which invalidates the fixture rather than the
                -- Goblin access route being tested.
                square:AddSpecialObject(t.gate);t.gate:transmitCompleteItemToClients()
                t.gate:setKeyId(id);t.gate:setLockedByPadlock(true)
                t.key=body:getInventory():AddItem("Base.KeyPadlock");assert(t.key);t.key:setKeyId(id)
                local x,y=square:getX()-(north and 0 or 1),square:getY()-(north and 1 or 0)
                Access.resolveTargetScope=function() return {bounds={x=x,y=y,x2=x,y2=y}} end
                local accepted,detail=Brain.setTask(body,"GAIN_ACCESS",{target={kind="YARD"}})
                Access.resolveTargetScope=originalScope
                assert(accepted,detail)
                local payload=Body.data(body).GoblinTaskPayload
                assert(payload and payload.edge and payload.edge.x==x and payload.edge.y==y,"wrong fixture route selected")
                log("accepted=true start_x="..p.x.." start_y="..p.y.." edge_x="..x.." edge_y="..y.." north="..tostring(north))
            end)
            Access.resolveTargetScope=originalScope
            if not ok then log("setup_failed="..tostring(err));cleanup() end
            return
        end
    end
end)

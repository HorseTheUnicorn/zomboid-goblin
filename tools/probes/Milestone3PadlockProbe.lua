-- Disposable native compatibility probe, never part of the published mod.
-- This is NOT a movement, persistence, or second-client replication test.
if not isServer() or type(getServerName)~="function" or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-padlock-probe.flag",false)
if not reader then return end
local owner=reader:readLine();reader:close()
if owner~="rejoinfang_74" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Padlocks=require("GoblinSurvivor/GoblinPadlocks")
local fired=false
local function log(s) print("[GoblinSurvivor] M3_PADLOCK_PROBE "..s) end
Events.OnTick.Add(function()
    if fired or not getCell() then return end
    for _,body in ipairs(World.values(getCell():getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner and body:getCurrentSquare()
            and not body:getVehicle() then
            fired=true
            local inventory=body:getInventory()
            local id=214660123
            if inventory:haveThisKeyId(id) then log("refused=fixture_key_collision");return end
            local square=body:getCurrentSquare()
            local gate,key
            local before={}
            for _,item in ipairs(World.items(inventory)) do before[item]=true end
            local ok,err=pcall(function()
                -- Same native constructor/registration sequence as ISWoodenDoor.
                gate=IsoThumpable.new(getCell(),square,"fixtures_doors_01_0","fixtures_doors_01_1",true,{})
                gate:setIsDoor(true)
                gate:setKeyId(id)
                gate:setLockedByPadlock(true)
                square:AddSpecialObject(gate)
                gate:transmitCompleteItemToClients()
                key=inventory:AddItem("Base.KeyPadlock")
                assert(key,"fixture key creation failed");key:setKeyId(id)
                log("before locked="..tostring(gate:isLockedByPadlock()).." key="..tostring(key:getID()))
                local removed=Padlocks.remove(body,gate)
                local outputs=0
                for _,item in ipairs(World.items(inventory)) do
                    if not before[item] and item:getFullType()=="Base.Padlock" and item:getKeyId()==id then
                        outputs=outputs+1
                        assert(item:getNumberOfKey()==1,"incorrect returned key count")
                    end
                end
                local consumed=not inventory:contains(key)
                log("after success="..tostring(removed).." locked="..tostring(gate:isLockedByPadlock())
                    .." key_id="..tostring(gate:getKeyId()).." key_consumed="..tostring(consumed)
                    .." returned_padlocks="..tostring(outputs))
                assert(removed and not gate:isLockedByPadlock() and gate:getKeyId()==-1 and consumed and outputs==1)
                assert(not Padlocks.remove(body,gate),"duplicate removal accepted")
                log("native_result=PASS movement=NOT_TESTED replication=NOT_TESTED persistence=NOT_TESTED")
            end)
            if not ok then log("native_result=FAIL error="..tostring(err)) end
            local cleaned,cleanupError=pcall(function()
                for _,item in ipairs(World.items(inventory)) do
                    if not before[item] and (item==key or (item:getFullType()=="Base.Padlock" and item:getKeyId()==id)) then
                        inventory:Remove(item)
                    end
                end
                if gate and gate:getObjectIndex()>=0 then square:transmitRemoveItemFromSquare(gate) end
                if gate then assert(gate:getObjectIndex()<0,"fixture gate still in world") end
            end)
            log("cleanup="..tostring(cleaned)..(cleaned and "" or " error="..tostring(cleanupError)))
            return
        end
    end
end)

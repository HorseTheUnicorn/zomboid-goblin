-- Native compatibility only, not movement/replication/persistence acceptance.
-- Disposable unregistered fixture; never changes existing furniture or locks.
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-container-key.flag",false)
if not reader then return end
local owner=reader:readLine();reader:close()
if owner~="m3path_61" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local fired=false
local function log(s) print("[GoblinSurvivor] M3_CONTAINER_KEY "..s) end
Events.OnTick.Add(function()
    if fired or not getCell() then return end
    for _,body in ipairs(World.values(getCell():getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner and body:getCurrentSquare() then
            fired=true
            local inventory=body:getInventory()
            local id=214660127
            if inventory:haveThisKeyId(id) then log("refused=fixture_key_collision");return end
            local key,crate
            local ok,err=pcall(function()
                -- Installed ISWoodenContainer's native constructor, without
                -- registering furniture or consuming construction materials.
                crate=IsoThumpable.new(getCell(),body:getCurrentSquare(),"carpentry_01_16",false,{})
                crate:setIsContainer(true)
                assert(crate:getContainer(),"native container missing")
                crate:setKeyId(id);crate:setLockedByPadlock(true)
                assert(crate:isLockedToCharacter(body)==true,"missing-key native result")
                assert(not World.containerAccessible(body,crate),"missing-key adapter result")
                key=inventory:AddItem("Base.KeyPadlock");assert(key,"installed item unavailable")
                key:setKeyId(id)
                assert(crate:isLockedToCharacter(body)==false,"matching-key native result")
                assert(World.containerAccessible(body,crate),"matching-key adapter result")
                assert(inventory:contains(key) and crate:isLockedByPadlock(),"access changed lock/key")
                crate:setLockedByCode(1234)
                assert(crate:isLockedToCharacter(body)==true,"code native result")
                assert(not World.containerAccessible(body,crate),"code adapter result")
                log("native_result=PASS missing_key=denied matching_key=allowed code=denied key_retained=true lock_retained=true")
            end)
            if not ok then log("native_result=FAIL error="..tostring(err)) end
            local cleaned,cleanupError=pcall(function()
                if key then inventory:Remove(key);assert(not inventory:contains(key)) end
                if crate then assert(crate:getObjectIndex()<0,"fixture unexpectedly registered") end
            end)
            log("cleanup="..tostring(cleaned)..(cleaned and "" or " error="..tostring(cleanupError)))
            return
        end
    end
end)

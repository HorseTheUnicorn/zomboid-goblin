-- Disposable no-Storm client observer. Never package with the released mod.
-- The explicit local flag permits placement of the TEST PLAYER only.
-- Observes actual streamed door/Goblin state; it never mutates either.
if not isClient() or isServer() then return end
local reader=getFileReader("goblin-m3-door-witness.flag",false)
if not reader then return end
local account=reader:readLine()
local placeOwner=reader:readLine()=="place-owner-outside";reader:close()
if account~="m3path_61" and account~="m3witness_54" then return end
local started,placed,lastLog,lastState=nil,false,0,nil
Events.OnTick.Add(function()
    local player=getPlayer()
    if not player or player:getUsername()~=account or not player:getCurrentSquare() then return end
    local now=getTimestampMs()
    started=started or now
    if not placed then
        placed=true
        if account=="m3path_61" or placeOwner then
            -- Installed vanilla DebugContextMenu/ISAdminMessage uses this API.
            player:teleportTo(account=="m3path_61" and 10782.5 or 10784.5,9774.5,0)
            print("[GoblinSurvivor] M3_DOOR_WITNESS placed_test_player="..account)
        end
    end
    if now-started>180000 or now-lastLog<500 then return end
    lastLog=now
    local a=getCell():getGridSquare(10779,9767,0)
    local b=getCell():getGridSquare(10779,9768,0)
    local door=a and b and a:getDoorTo(b)
    local state=door and (tostring(door:isOpen()).." locked="..tostring(door:isLocked())
        .." key_locked="..tostring(door:isLockedByKey())) or "unloaded"
    if state~=lastState then
        lastState=state
        print("[GoblinSurvivor] M3_DOOR_WITNESS account="..account.." timestamp="..now
            .." door_open="..state.." player_x="..player:getX().." player_y="..player:getY())
    end
    local zombies=getCell():getZombieList()
    for i=0,zombies:size()-1 do
        local body=zombies:get(i)
        local data=body:getModData()
        if data.GoblinNPC==true and data.GoblinOwner=="m3witness_54" then
            print("[GoblinSurvivor] M3_DOOR_WITNESS account="..account.." timestamp="..now
                .." goblin_x="..body:getX().." goblin_y="..body:getY().." goblin_z="..body:getZ())
            break
        end
    end
end)

-- Flag-gated disposable client fixture; places only the test PLAYER.
if not isClient() or isServer() then return end
local reader=getFileReader("goblin-m3-container.flag",false)
if not reader then return end
local owner=reader:readLine();reader:close()
if owner~="m3path_61" and owner~="m3witness_54" then return end
local Client=require("GoblinSurvivor/GoblinClient")
local placed,started,last,observed=false,nil,0,nil
Events.OnServerCommand.Add(function(module,command,args)
    if module=="GoblinM3Probe" and command=="container" then
        observed=args
        started=started or getTimestampMs()
    end
end)
Events.OnTick.Add(function()
    local player=getPlayer()
    if player and player:getUsername()==owner and player:getCurrentSquare() then
        local now=getTimestampMs()
        if not placed then
            placed=true
            player:teleportTo(owner=="m3path_61" and 10779.5 or 10780.5,9765.5,0)
            print("[GoblinSurvivor] M3_CONTAINER placed_test_player="..owner)
        end
        if not observed or not started or now-started>180000 or now-last<1000 then return end
        last=now
        local square=getCell():getGridSquare(observed.x,observed.y,observed.z)
        if square then
            local objects=square:getObjects()
            for i=0,objects:size()-1 do
                local object=objects:get(i)
                if object:getModData().GoblinAccessContainerID==observed.id and object:getContainer() then
                    local ids={};local items=object:getContainer():getItems()
                    for j=0,items:size()-1 do ids[#ids+1]=tostring(items:get(j):getID()) end
                    table.sort(ids)
                    print("[GoblinSurvivor] M3_CONTAINER_CLIENT account="..owner.." phase="..observed.phase
                        .." target="..observed.id.." items="..table.concat(ids,","))
                end
            end
        end
        local bodies=getCell():getZombieList()
        for i=0,bodies:size()-1 do
            local body=bodies:get(i)
            local roster=Client.statesByOnline[body:getOnlineID()]
            if roster and roster.npc_id=="goblin.primary.m3path_61" then
                print("[GoblinSurvivor] M3_CONTAINER_CLIENT account="..owner.." t="..now
                    .." online="..body:getOnlineID().." x="..body:getX().." y="..body:getY()
                    .." z="..body:getZ().." outfit="..body:getPersistentOutfitID()
                    .." roster_outfit="..tostring(roster.outfit_id))
            end
        end
    end
end)

-- Disposable ordinary-client observer for Milestone3ContainerDenialProbe.lua.
if not isClient() or isServer() then return end
local reader=getFileReader("goblin-m3-container-denial.flag",false)
if not reader then return end
local account=reader:readLine();reader:close()
if account~="m3path_61" and account~="m3witness_54" then return end
local observations={}
Events.OnServerCommand.Add(function(module,command,args)
    if module=="GoblinM3Probe" and command=="container-denial" then
        observations[#observations+1]={payload=args,received=getTimestampMs()}
    end
end)
Events.OnTick.Add(function()
    local player=getPlayer()
    if not player or player:getUsername()~=account then return end
    for index=#observations,1,-1 do
        local observation=observations[index]
        local args=observation.payload
        local square=getCell():getGridSquare(args.x,args.y,args.z)
        local found
        if square then
            local objects=square:getObjects()
            for i=0,objects:size()-1 do
                local object=objects:get(i)
                if object:getModData().GoblinContainerDenialID==args.id then found=object;break end
            end
        end
        if found and found:getContainer() then
            local ids={};local items=found:getContainer():getItems()
            for i=0,items:size()-1 do ids[#ids+1]=tostring(items:get(i):getID()) end
            table.sort(ids)
            local padlockOK,padlocked=pcall(function() return found:isLockedByPadlock() end)
            local codeOK,code=pcall(function() return found:getLockedByCode() end)
            print("[GoblinSurvivor] M3_CONTAINER_DENIAL_CLIENT account="..account
                .." phase="..tostring(args.phase).." items="..table.concat(ids,",")
                .." expected_items="..tostring(args.items)
                .." padlocked="..tostring(padlockOK and padlocked)
                .." code="..tostring(codeOK and code))
            table.remove(observations,index)
        elseif getTimestampMs()-observation.received>5000 then
            print("[GoblinSurvivor] M3_CONTAINER_DENIAL_CLIENT account="..account
                .." phase="..tostring(args.phase).." target_missing=true")
            table.remove(observations,index)
        end
    end
end)

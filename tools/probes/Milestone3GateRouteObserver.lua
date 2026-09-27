-- Disposable ordinary-client observer for the two-client gate route probe.
-- It places only each test player in the known local open-ground test area.
if not isClient() or isServer() then return end
local reader=getFileReader("goblin-m3-gate-route.flag",false)
if not reader then return end
local owner=reader:readLine();local witness=reader:readLine();reader:close()
local playerAccount
local observations={}
local placed,lastReady,receivedAny=false,0,false

Events.OnServerCommand.Add(function(module,command,args)
    if module=="GoblinM3Probe" and command=="gate-route" then
        receivedAny=true
        observations[#observations+1]={payload=args,received=getTimestampMs()}
    end
end)

local function findGate(args)
    local square=getCell():getGridSquare(args.x,args.y,args.z)
    if not square then return nil end
    local seen={}
    local fallback
    for _,objects in ipairs({square:getObjects(),square:getSpecialObjects()}) do
        for index=0,objects:size()-1 do
            local object=objects:get(index)
            if not seen[object] then
                seen[object]=true
                if object:getModData().GoblinM3GateRouteID==args.id then
                    return object,"marker"
                end
                -- transmitCompleteItemToClients() replicates the native door,
                -- but arbitrary fixture modData is not guaranteed to accompany
                -- the initial object packet. The square was verified to have no
                -- pre-existing edge object before creation, so the exact-square
                -- native door signature is an unambiguous fallback on clients.
                if instanceof(object,"IsoThumpable") and object:isDoor() then
                    fallback=object
                end
            end
        end
    end
    if fallback then return fallback,"native-door" end
end

local function findGoblin(args)
    -- Server modData (GoblinNPC/GoblinOwner) never reaches clients, so the
    -- earlier lookup always failed and every phase logged target_missing.
    -- Match the native online ID the server sends, then the Goblin mod's
    -- client-side GoblinID animation variable as a fallback.
    local zombies=getCell():getZombieList()
    local wanted="dev.survivor.001."..tostring(args.owner)
    for index=0,zombies:size()-1 do
        local body=zombies:get(index)
        if type(args.online_id)=="number" and args.online_id>=0 and body:getOnlineID()==args.online_id then
            return body,"online_id"
        end
        if body:getVariableBoolean("GoblinNPC") and body:GetVariable("GoblinID")==wanted then
            return body,"goblin_id"
        end
    end
end

Events.OnTick.Add(function()
    local player=getPlayer()
    if not player or not player:getCurrentSquare() then return end
    local account=player:getUsername()
    if account~=owner and account~=witness then return end
    playerAccount=playerAccount or account
    if account~=playerAccount then return end
    if not placed then
        placed=true
        player:teleportTo(playerAccount==owner and 10784.5 or 10786.5,9774.5,0)
        print("[GoblinSurvivor] M3_GATE_ROUTE_CLIENT account="..playerAccount.." placed=true")
    end
    local now=getTimestampMs()
    if not receivedAny and now-lastReady>=3000 then
        lastReady=now
        sendClientCommand("GoblinM3Probe","gate-route-ready",{})
        print("[GoblinSurvivor] M3_GATE_ROUTE_CLIENT account="..playerAccount.." ready_sent=true")
    end
    for index=#observations,1,-1 do
        local observation=observations[index];local args=observation.payload
        local gate,identifiedBy=findGate(args);local body,bodyBy=findGoblin(args)
        if gate and body then
            local bx,by=math.floor(body:getX()),math.floor(body:getY())
            local side=bx==args.from_x and by==args.from_y and "from"
                or bx==args.to_x and by==args.to_y and "to" or "other"
            local open=gate:IsOpen();local padlocked=gate:isLockedByPadlock()
            local expected=args.phase=="ready"
                and side=="from" and open==false and padlocked==true
                or args.phase=="terminal" and args.success==true
                    and side=="to" and open==true and padlocked==false
            if expected or now-observation.received>8000 then
                print("[GoblinSurvivor] M3_GATE_ROUTE_CLIENT account="..playerAccount
                    .." phase="..tostring(args.phase).." marker="..tostring(args.id)
                    .." side="..side.." open="..tostring(open)
                    .." padlocked="..tostring(padlocked)
                    .." key_id="..tostring(gate:getKeyId())
                    .." identified_by="..tostring(identifiedBy)
                    .." goblin_by="..tostring(bodyBy)
                    .." expected="..tostring(expected))
                table.remove(observations,index)
            end
        elseif now-observation.received>8000 then
            print("[GoblinSurvivor] M3_GATE_ROUTE_CLIENT account="..playerAccount
                .." phase="..tostring(args.phase).." target_missing=true"
                .." gate_found="..tostring(gate~=nil).." goblin_found="..tostring(body~=nil))
            table.remove(observations,index)
        end
    end
end)

-- Read-only disposable server probe. Never include in the released package.
-- No provisioning, repairs, task changes or item mutation occurs here.
if not isServer() or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m3-toolkit.flag",false)
if not reader then return end
local owner=reader:readLine();reader:close()
if owner~="m3witness_54" and owner~="m3path_61" then return end
local Body=require("GoblinSurvivor/GoblinBody")
local Tools=require("GoblinSurvivor/GoblinTools")
local started,last,first,finished=nil,0,nil,false
local function snapshot(body)
    local counts,identities={},{}
    local items=body:getInventory():getItems()
    for i=0,items:size()-1 do
        local item=items:get(i)
        if Tools.reserved(item) then
            local kind=item:getFullType()
            counts[kind]=(counts[kind] or 0)+1
            identities[item:getID()]=kind
        end
    end
    local complete=true
    for _,kind in ipairs(Tools.types) do
        if counts[kind]~=1 then complete=false end
        print("[GoblinSurvivor] M3_TOOLKIT owner="..owner.." type="..kind
            .." reserved_count="..tostring(counts[kind] or 0))
    end
    return complete,identities
end
Events.OnTick.Add(function()
    if finished or not getCell() then return end
    local now=getTimestampMs()
    if started and now-started<30000 then return end
    if now-last<1000 then return end
    last=now
    local bodies=getCell():getZombieList()
    for i=0,bodies:size()-1 do
        local body=bodies:get(i)
        if Body.isGoblin(body) and Body.owner(body)==owner then
            local ok,complete,identities=pcall(snapshot,body)
            if not ok then
                finished=true
                print("[GoblinSurvivor] M3_TOOLKIT error="..tostring(complete))
                return
            end
            if not started then
                started=now;first=identities
                print("[GoblinSurvivor] M3_TOOLKIT phase=initial complete="..tostring(complete))
            else
                local stable=true
                for id,kind in pairs(first) do if identities[id]~=kind then stable=false end end
                for id,kind in pairs(identities) do if first[id]~=kind then stable=false end end
                finished=true
                print("[GoblinSurvivor] M3_TOOLKIT phase=final complete="..tostring(complete)
                    .." reserved_identity_stable="..tostring(stable).." elapsed_ms="..(now-started))
            end
            return
        end
    end
end)

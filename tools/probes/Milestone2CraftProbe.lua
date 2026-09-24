-- Disposable server test only. Never package this under the released mod.
-- Opt in with Lua/goblin-m2-craft-probe.flag containing the exact test owner.
if not isServer() or type(getServerName)~="function" or getServerName()~="goblin-local" then return end
local reader=getFileReader("goblin-m2-craft-probe.flag",false)
if not reader then return end
local owner=reader:readLine();reader:close()
if owner~="rejoinfang_74" then return end

local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Brain=require("GoblinSurvivor/GoblinBrain")
local Jobs=require("GoblinSurvivor/GoblinJobs")
local Cap=require("GoblinSurvivor/GoblinCapabilities")
local fired=false
local target
local originalUpdate=Jobs.update
local function count(body,fullType)
    local n=0
    for _,item in ipairs(World.items(World.inventory(body))) do
        if World.fullType(item)==fullType then n=n+1 end
    end
    return n
end
local function log(text) print("[GoblinSurvivor] M2_CRAFT_PROBE "..text) end

Jobs.update=function(body,task,payload,now)
    local result=originalUpdate(body,task,payload,now)
    if body==target and task=="CRAFT" then
        log("code="..result.code.." done="..tostring(result.done)
            .." logs="..count(body,"Base.Log").." planks="..count(body,"Base.Plank"))
        if result.done then
            -- Check the registry's duplicate-tick boundary before Brain clears
            -- the task or delivers its outputs. This is not a second command.
            local logs,planks=count(body,"Base.Log"),count(body,"Base.Plank")
            local duplicate=Cap.update(task,body,payload,now)
            log("terminal_repeat="..duplicate.code
                .." inventory_unchanged="..tostring(logs==count(body,"Base.Log")
                    and planks==count(body,"Base.Plank")))
            target=nil;Jobs.update=originalUpdate
        end
    end
    return result
end

Events.OnTick.Add(function()
    if fired then return end
    local cell=getCell()
    if not cell then return end
    for _,body in ipairs(World.values(cell:getZombieList())) do
        if Body.isGoblin(body) and Body.owner(body)==owner then
            local player
            for _,candidate in ipairs(World.values(getOnlinePlayers())) do
                if candidate:getUsername()==owner then player=candidate end
            end
            if not player or not body:getCurrentSquare() or body:getVehicle() then return end
            fired=true
            local logs,planks=count(body,"Base.Log"),count(body,"Base.Plank")
            log("before logs="..logs.." planks="..planks)
            if logs~=0 or planks~=0 then
                log("refused=nonempty_test_material_inventory");Jobs.update=originalUpdate;return
            end
            local added=World.inventory(body):AddItem("Base.Log")
            if not added then log("refused=seed_failed");Jobs.update=originalUpdate;return end
            log("seeded Base.Log id="..tostring(added:getID()))
            target=body
            local accepted,detail=Brain.setTask(body,"CRAFT",{item={name="SawLogs",count=1}})
            log("accepted="..tostring(accepted).." detail="..tostring(detail))
            if not accepted then target=nil;Jobs.update=originalUpdate end
            return
        end
    end
end)

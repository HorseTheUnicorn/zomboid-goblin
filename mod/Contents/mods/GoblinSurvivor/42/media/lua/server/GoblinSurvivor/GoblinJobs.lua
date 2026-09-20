local Body=require("GoblinSurvivor/GoblinBody")
local Movement=require("GoblinSurvivor/GoblinMovement")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local Capabilities=require("GoblinSurvivor/GoblinCapabilities")

local Jobs={active=Capabilities.active}
local definitions={
    FARM={handler=require("GoblinSurvivor/GoblinFarming"),destructive=true,
        requirements={reusable_tools={"Base.HandShovel","Base.Scythe"},
            consumables={"installed crop seed types when sowing","real water when watering"}}},
    CRAFT={handler=require("GoblinSurvivor/GoblinCrafting"),destructive=true,
        requirements={recipe="exact installed hand-crafting recipe",
            consumables={"native recipe inputs"},reusable_tools={"installed keep-input tools"}}},
    REPAIR_VEHICLE={handler=require("GoblinSurvivor/GoblinVehicles"),destructive=true,
        requirements={reusable_tools={"Base.Wrench"},
            consumables={"Base.EngineParts or installed fixing inputs"}}},
    CLOSE_CURTAINS={handler=require("GoblinSurvivor/GoblinCurtains"),destructive=false,
        requirements={target="owner's bounded loaded house",consumables={}}},
    GAIN_ACCESS={handler=require("GoblinSurvivor/GoblinGainAccess"),destructive=true,
        requirements={target_kinds={"BUILDING","ROOM","YARD","VEHICLE","CONTAINER"},
            reusable_tools={"Base.Crowbar"},
            available_but_unrouted_tools={"Base.BoltCutters"},
            policy="least-destructive route; breach requires explicit online authorization",
            consumables={}}}
}

local function serverReady()
    return type(isServer)=="function" and isServer()
        and not (type(isClient)=="function" and isClient())
end

for task,item in pairs(definitions) do
    local handler=item.handler
    Capabilities.register(task,{
        destructive=item.destructive,offline_allowed=false,owner_required=true,timeout_ms=300000,
        requirements=item.requirements,
        can_prepare=function(body,owner)
            if not serverReady() then return false,"work must run on the game server" end
            if not Body.isGoblin(body) then return false,"Goblin body is not present" end
            if not owner then return false,"the owner must be present to issue this job" end
            return true
        end,
        prepare=function(body,owner,payload) return handler.prepare(body,owner,payload) end,
        update=function(body,payload,runtime,now)
            local done,success,detail,code=handler.update(body,payload,runtime,now)
            return Capabilities.fromLegacy(done,success,detail,code)
        end,
        cancel=function(body) if type(handler.clear)=="function" then handler.clear(body) end end,
        snapshot=function(_,runtime)
            local skipped=0
            if type(runtime.skipped)=="table" then for _ in pairs(runtime.skipped) do skipped=skipped+1 end end
            return {completed=tonumber(runtime.completed) or 0,skipped_count=skipped}
        end
    })
end
if type(print)=="function" then
    print("[GoblinSurvivor] CAPABILITY_REGISTRY_READY count=5 tasks=CLOSE_CURTAINS,CRAFT,FARM,GAIN_ACCESS,REPAIR_VEHICLE")
end

function Jobs.handles(task) return Capabilities.handles(task) end

function Jobs.clear(body,nextTask)
    Capabilities.cancel(body,nextTask)
    local data=Body.data(body)
    if data then data.GoblinJobActive=false;data.GoblinAction="";data.GoblinJobProgress=nil end
end

function Jobs.prepare(body,owner,task,payload)
    return Capabilities.prepare(task,body,owner,payload)
end

function Jobs.update(body,task,payload,now)
    local result
    if not serverReady() then
        result=Capabilities.result(true,false,"UNSUPPORTED","server work is unavailable",0)
    elseif not Support.validPoint(payload and payload.anchor) then
        result=Capabilities.result(true,false,"TARGET_CHANGED",
            "saved job has no valid work area; issue it again",0)
    else result=Capabilities.update(task,body,payload,now) end
    local data=Body.data(body)
    if data then
        local previous=data.GoblinLastJobResult
        data.GoblinJobActive=result.done~=true
        data.GoblinJobProgress=tonumber(payload and payload.completed) or 0
        data.GoblinLastJobResult={task=task,done=result.done,success=result.success,code=result.code,
            detail=result.detail,progress=result.progress}
        if type(print)=="function" and (not previous or previous.code~=result.code or result.done) then
            print("[GoblinSurvivor] CAPABILITY_RESULT task="..tostring(task)
                .." owner="..tostring(Body.owner(body)).." done="..tostring(result.done)
                .." success="..tostring(result.success).." code="..tostring(result.code)
                .." progress="..tostring(result.progress))
        end
    end
    if result.done then Movement.clear(body) end
    return result
end

function Jobs.snapshot(body) return Capabilities.snapshot(body) end
function Jobs.requirements(task,payload) return Capabilities.requirements(task,payload) end
function Jobs.registry() return Capabilities.list() end

return Jobs

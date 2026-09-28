local Body=require("GoblinSurvivor/GoblinBody")
local Movement=require("GoblinSurvivor/GoblinMovement")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local Capabilities=require("GoblinSurvivor/GoblinCapabilities")

-- Conjured supplies (GoblinProvision) feed every job Goblin does for himself;
-- they are quarantined inside Goblin's inventory.
local Jobs={active=Capabilities.active}
-- Home upkeep Goblin keeps doing on his own, also while the owner is away.
Jobs.CARETAKER={RESTORE_POWER=true,FARM=true,CLOSE_CURTAINS=true,CHECK_TRAPS=true}
local VehicleService=require("GoblinSurvivor/GoblinVehicleService")
local Survival=require("GoblinSurvivor/GoblinSurvival")
local Life=require("GoblinSurvivor/GoblinSurvivalLife")
local vehicleTools={"Base.Wrench","Base.Screwdriver","Base.LugWrench","Base.Jack","Base.TirePump"}
local definitions={
    FARM={handler=require("GoblinSurvivor/GoblinFarming"),destructive=true,
        requirements={reusable_tools={"Base.HandShovel","Base.Scythe"},
            consumables={"installed crop seed types when sowing","water (carried, nearby, or conjured for Goblin's own use)"}}},
    CRAFT={handler=require("GoblinSurvivor/GoblinCrafting"),destructive=true,
        requirements={recipe="exact installed hand-crafting recipe",
            consumables={"native recipe inputs"},reusable_tools={"installed keep-input tools"}}},
    REPAIR_VEHICLE={handler=require("GoblinSurvivor/GoblinVehicles"),destructive=true,
        requirements={reusable_tools={"Base.Wrench"},
            consumables={"Base.EngineParts or installed fixing inputs"}}},
    CLOSE_CURTAINS={handler=require("GoblinSurvivor/GoblinCurtains"),destructive=false,
        requirements={target="owner's bounded loaded house",consumables={}}},
    INSPECT_BASE={handler=require("GoblinSurvivor/GoblinBaseInspect"),destructive=false,
        requirements={target="saved base's bounded loaded BuildingDef",consumables={}}},
    MAINTAIN_BASE={handler=require("GoblinSurvivor/GoblinBaseMaintain"),destructive=true,
        requirements={target="saved base's bounded loaded BuildingDef",
            consumables={"Base.Plank and Base.Nails for window work (carried, conjured, or salvaged)"},
            unsupported={"generic structure repair","missing-stock replenishment"}}},
    DISMANTLE={handler=require("GoblinSurvivor/GoblinDismantle"),destructive=true,
        requirements={target="one explicitly ordered empty, single-tile wooden furniture object in the owner's saved base; "
                .."or (salvage) the nearest such object indoors in another building, never the saved base, its buffer or any safehouse",
            reusable_tools={"Base.Hammer","Base.Saw"},
            salvage="only items granted by the installed native moveables scrap rules; salvage mode picks them up",
            unsupported={"teardown inside the base or a safehouse","IsoThumpable","multi-sprite objects","valuable or filled containers"}}},
    STOCKPILE={handler=require("GoblinSurvivor/GoblinStockpileWork"),destructive=true,
        requirements={target="exact persisted assigned base container and installed item full type",
            material="only existing matching item instances, nearest first within 150 tiles",
            limit="at most 20 delivered items per explicit run"}},
    SORT_STORAGE={handler=require("GoblinSurvivor/GoblinSortWork"),destructive=false,timeout_ms=600000,
        requirements={target="owner-assigned semantic storage containers in the saved base",
            material="only existing items in the INBOX, misplaced in another category, or (sort all) unassigned/floor",
            limit="at most 60 items per explicit run; cold storage food is never removed",
            fallback="same category, then OVERFLOW, then back to the original source"}},
    FETCH_ITEM={handler=require("GoblinSurvivor/GoblinFetchWork"),destructive=false,
        requirements={target="online owner",
            material="existing matching items inside the saved base; shortages are reported, never filled",
            limit="1-20 items of one exact full type or one storage category"}},
    DELIVER={handler=require("GoblinSurvivor/GoblinDeliverWork"),destructive=false,
        requirements={target="owner-assigned base storage by category, then OVERFLOW, then INBOX",
            material="only the carried item instances selected at order time",
            fallback="base floor only with explicit owner permission"}},
    REPAIR_STRUCTURE={handler=require("GoblinSurvivor/GoblinStructureRepair"),destructive=true,timeout_ms=600000,
        requirements={target="damaged (20-95% health) native-repairable objects and smashed-window glass in the saved base",
            reusable_tools={"material-specific native repair tools, e.g. Base.Hammer + Base.Saw for Wood"},
            consumables={"native repair parts for the live damage factor, e.g. Base.Plank and Base.Nails/Base.Screws"},
            unsupported={"BlowTorch repairs without real fuel","Tag-only parts not already carried"}}},
    VEHICLE_INSPECT={handler=VehicleService.Inspect,destructive=false,
        requirements={target="nearest loaded vehicle within Goblin range (150 tiles) of the owner",consumables={}}},
    REFUEL_VEHICLE={handler=VehicleService.Refuel,destructive=true,
        requirements={target="parked vehicle with an installed gas tank",
            consumables={"petrol from a carried can, a pump with piped fuel, or a conjured can (discarded when empty)"}}},
    INSTALL_PART={handler=VehicleService.Install,destructive=true,
        requirements={target="empty vehicle part slot",reusable_tools=vehicleTools,
            material="a carried or conjured matching part, else the nearest within 150 tiles",
            gates={"script install table","none: Goblin has every recipe, profession, trait and opens any lock"}}},
    REMOVE_PART={handler=VehicleService.Remove,destructive=true,
        requirements={target="installed vehicle part",reusable_tools=vehicleTools,
            gates={"script uninstall table","requireEmpty","mechanic key or unlocked access"}}},
    REPLACE_PART={handler=VehicleService.Replace,destructive=true,
        requirements={target="installed or empty vehicle part slot",reusable_tools=vehicleTools,
            material="a carried or conjured matching part, else the nearest within 150 tiles"}},
    CHANGE_TIRE={handler=VehicleService.Tire,destructive=true,
        requirements={target="named or worst tire",reusable_tools={"Base.Jack","Base.LugWrench","Base.TirePump"},
            material="a carried or conjured matching tire, else the nearest within 150 tiles"}},
    VEHICLE_SERVICE={handler=VehicleService.Full,destructive=true,timeout_ms=600000,
        requirements={target="parked vehicle",reusable_tools={"Base.TirePump"},
            consumables={"petrol (conjured when none is carried)"},steps={"inspect","inflate tires","charge battery (Goblin's own charger)","refuel"}}},
    CHOP_WOOD={handler=Survival.Chop,destructive=true,
        requirements={target="1-5 loaded trees, nearest first within 150 tiles of the owner",
            reusable_tools={"Base.Axe"},output="native IsoTree.WeaponHit log drops only"}},
    TREAT_PLAYER={handler=Survival.Treat,destructive=true,
        requirements={target="the online owner's unbandaged wounds, bleeding first",
            consumables={"clean bandages carried, conjured, or within 150 tiles"}}},
    FORAGE={handler=Life.Forage,destructive=false,timeout_ms=600000,
        requirements={target="outdoor forage-zone ground near the owner first, out to 150 tiles",
            output="1-10 real items rolled by the installed forageSystem; delivered as cargo"}},
    CHECK_TRAPS={handler=Life.Traps,destructive=false,timeout_ms=600000,
        requirements={target="STrapSystem traps within 150 tiles of the base or owner",
            output="native trap catches (corpse/food items) as cargo",consumables={"bait (conjured)"}}},
    COOK={handler=Life.Cook,destructive=false,timeout_ms=960000,
        requirements={target="a loaded IsoStove (stove, oven, microwave) nearest within 150 tiles of the owner",
            consumables={"1-5 raw cookable foods carried or the nearest within 150 tiles"},
            output="the same food items, cooked by the engine, delivered as cargo"}},
    RESTORE_POWER={handler=require("GoblinSurvivor/GoblinPower"),destructive=false,timeout_ms=600000,
        requirements={target="a loaded IsoGenerator within 150 tiles of the base, else one conjured onto free outdoor ground beside it",
            consumables={"petrol (conjured)"},steps={"place generator if none","repair to full condition","fill with petrol","plug in","start"}}},
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
        destructive=item.destructive,offline_allowed=false,owner_required=true,
        caretaker=Jobs.CARETAKER[task]==true,
        timeout_ms=item.timeout_ms or 300000,
        requirements=item.requirements,
        can_prepare=function(body,owner,payload)
            if not serverReady() then return false,"work must run on the game server" end
            if not Body.isGoblin(body) then return false,"Goblin body is not present" end
            if not owner and not (Jobs.CARETAKER[task] and payload and payload.caretaker==true) then
                return false,"the owner must be present to issue this job"
            end
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
    local names={}
    for _,entry in ipairs(Capabilities.list()) do names[#names+1]=entry.name end
    print("[GoblinSurvivor] CAPABILITY_REGISTRY_READY count="..#names.." tasks="..table.concat(names,","))
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

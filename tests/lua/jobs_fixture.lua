Farm=require('GoblinSurvivor/GoblinFarming')
Craft=require('GoblinSurvivor/GoblinCrafting')
Vehicles=require('GoblinSurvivor/GoblinVehicles')
Jobs=require('GoblinSurvivor/GoblinJobs')
Tools=require('GoblinSurvivor/GoblinTools')
Curtains=require('GoblinSurvivor/GoblinCurtains')
-- A small exact BuildingDef fixture for house-scoped curtain jobs.  Squares
-- outside this room deliberately have no room/building, so tests exercise
-- perimeter and adjacent-house rejection instead of nearest-building guesses.
houseBuilding={}
houseRoom={x=0,y=0,x2=6,y2=6,z=0,building=houseBuilding}
houseRooms={houseRoom}
function houseRoom:getX() return self.x end;function houseRoom:getY() return self.y end
function houseRoom:getX2() return self.x2 end;function houseRoom:getY2() return self.y2 end
function houseRoom:getZ() return self.z end;function houseRoom:getBuilding() return self.building end
function houseRoom:isInside() return true end
function houseBuilding:getRooms() return list(houseRooms) end
function houseBuilding:getMinLevel() return 0 end;function houseBuilding:getMaxLevel() return 0 end
function houseBuilding:isFullyStreamedIn() return true end
local oldHouseSquare=cell.getGridSquare
function cell:getGridSquare(x,y,z)
    local sq=oldHouseSquare(self,x,y,z)
    if not sq.getRoom then
        function sq:getRoom()
            for _,room in ipairs(houseRooms) do
                if self.x>=room.x and self.x<=room.x2 and self.y>=room.y
                    and self.y<=room.y2 and self.z==room.z then return room end
            end
            return nil
        end
    end
    return sq
end
function curtain(x,y,z)
    local sq=cell:getGridSquare(x,y or 0,z or 0)
    local c={kind='IsoCurtain',opened=true,calls=0,square=sq}
    function c:getSquare() return self.square end
    function c:IsOpen() return self.opened end
    function c:getOppositeSquare() return cell:getGridSquare(x,(y or 0)-1,z or 0) end
    function c:isAdjacentToSquare(other)
        return other and other:getY()==sq:getY() and math.abs(other:getX()-sq:getX())<=1
    end
    function c:canInteractWith(who)
        local here=World.square(Body.position(who))
        return here:getZ()==sq:getZ() and (self:isAdjacentToSquare(here) or here==self:getOppositeSquare())
            and not sq:isBlockedTo(here)
    end
    function c:ToggleDoor(who)
        assert(self:canInteractWith(who));self.calls=self.calls+1
        if not self.refused then self.opened=not self.opened end
    end
    sq.objects[#sq.objects+1]=c
    return c
end
Perks={Farming='farming',Mechanics='mechanics'}
function a:getPerkLevel() return 10 end
ArrayList={new=function() return list() end}
ZomboidGlobals={farmingFluidContainerMillilitresPerUse=100}
plants={}
farming_vegetableconf={props={Cabbages={seedName='Base.CabbageSeed',waterNeeded=80}}}
function makePlant(x,state)
    local p={x=x,y=0,z=0,state=state or 'seeded',waterLvl=20,waterNeeded=80,typeOfSeed='Cabbages',hasVegetable=false}
    function p:isAlive() return self.state=='seeded' or self.state=='plow' end
    function p:seed(kind,skill) self.state='seeded';self.typeOfSeed=kind;self.seeded=(self.seeded or 0)+1 end
    function p:water(source,uses) self.waterLvl=math.min(100,self.waterLvl+uses*10) end
    plants[x..':0:0']=p;return p
end
SFarmingSystem={instance={}}
function SFarmingSystem.instance:getLuaObjectOnSquare(sq) return plants[sq:getX()..':'..sq:getY()..':'..sq:getZ()] end
function SFarmingSystem.instance:plow(sq) makePlant(sq:getX(),'plow') end
function SFarmingSystem.instance:harvest(p,body)
    body:getInventory():AddItem('Base.Cabbage');p.hasVegetable=false;p.state='harvested';harvestCount=(harvestCount or 0)+1
end
ISShovelGroundCursor={GetDirtGravelSand=function(sq) return sq.dirt and 'dirt' or nil end}
function waterItem(amount,kind)
    local i=item('Base.WaterBottle');local fluid={amount=amount}
    function fluid:getPrimaryFluid() return {getFluidTypeString=function() return kind or 'Water' end} end
    function fluid:getAmount() return self.amount end
    function fluid:adjustAmount(v) self.amount=v end
    function i:getFluidContainer() return fluid end
    i.fluid=fluid;return i
end
function job() return {startedAt=clock,skipped={}} end
function farmPayload(mode) return {job=mode,crop=mode=='sow' and 'Cabbages' or nil,anchor={x=0,y=0,z=0},completed=0} end

function input(kind,count,keep)
    local v={kind=kind,count=count,keep=keep}
    function v:isKeep() return self.keep==true end
    function v:isTool() return self.keep==true end
    function v:getPossibleInputItems() return list({{getFullName=function() return kind end}}) end
    function v:canUseItem(i,body) return i:getFullType()==kind end
    function v:getAmount() return count end
    function v:isItemCount() return true end
    return v
end
recipe={name='SawLogs',inputs={input('Base.Log',1,false),input('Base.Saw',1,true)}}
function recipe:getName() return self.name end
function recipe:getTranslationName() return 'Saw Logs' end
function recipe:getInputs() return list(self.inputs) end
function recipe:getTime() return 30 end
function recipe:isBuildableRecipe() return self.buildable==true end
function recipe:requiresSpecificWorkstation() return self.workstation==true end
function recipe:isInHandCraftCraft() return true end
function recipe:isAnySurfaceCraft() return false end
ScriptManager={instance={getCraftRecipe=function(self,name) if name=='SawLogs' then return recipe end end,
    getAllCraftRecipes=function() return list({recipe}) end}}
HandcraftLogic={new=function(body)
    local l={body=body,output={}}
    function l:setContainers(value) self.containers=value end
    function l:setRecipe(value) self.recipe=value end
    function l:setManualSelectInputs() end
    function l:setTargetVariableInputRatio() end
    function l:getInputCount(input)
        local n=0;for _,i in ipairs(body.inv.items) do if input:canUseItem(i,body) then n=n+1 end end
        return n
    end
    function l:canPerformCurrentRecipe()
        for _,v in ipairs(self.recipe.inputs) do if self:getInputCount(v)<v.count then return false end end
        return true
    end
    function l:getRecipeData()
        return {getAllNotKeepInputItems=function()
            local result={}
            for _,v in ipairs(l.recipe.inputs) do if not v.keep then
                for _,i in ipairs(body.inv.items) do if v:canUseItem(i,body) then result[#result+1]=i;break end end
            end end
            return list(result)
        end,luaCallOnCreate=function() end,processDestroyAndUsedItems=function() end}
    end
    function l:getCreatedOutputItems(out) for _,i in ipairs(self.output) do out:add(i) end end
    function l:performCurrentRecipe() error('unsafe player-only native entry must not be called') end
    return l
end}
goblinServerCraft=function(body,logic)
    craftCalls=(craftCalls or 0)+1
    local used=logic:getRecipeData():getAllNotKeepInputItems()
    if not World.reserve(body,World.values(used)) then return false end
    for i=1,3 do logic.output[#logic.output+1]=item('Base.Plank') end
    return true
end
goblinServerRepair=function() return true end
function vehicle()
    local v={x=1,y=0,z=0,speed=0,running=false,passenger=nil}
    function v:getX() return self.x end;function v:getY() return self.y end;function v:getZ() return self.z end
    function v:getId() return 7 end
    function v:getCurrentSpeedKmHour() return self.speed end
    function v:isEngineRunning() return self.running end
    function v:getMaxPassengers() return 2 end
    function v:getCharacter() return self.passenger end
    function v:getSquareForArea() return cell:getGridSquare(1,0,0) end
    function v:isInArea() return not self.areaBlocked end
    function v:getScript() return {getEngineRepairLevel=function() return 5 end} end
    function v:transmitPartCondition() self.synced=(self.synced or 0)+1 end
    local part={condition=90}
    function part:getId() return 'Engine' end
    function part:getCondition() return self.condition end
    function part:setCondition(c) self.condition=math.floor(c) end
    function part:getArea() return 'Engine' end
    function v:getPartById(id) if id=='Engine' then return part end end
    function v:getPartCount() return 1 end
    function v:getPartByIndex() return part end
    function part:getInventoryItem() return nil end
    v.engine=part
    function cell:getVehicles() return list({v}) end
    getVehicleById=function(id) if id==7 then return v end end
    return v
end

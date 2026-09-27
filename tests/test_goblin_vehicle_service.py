"""Milestone 6 vehicle-service fixtures (not engine or multiplayer evidence)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"

VEHICLE_FIXTURE = r'''
Service=require('GoblinSurvivor/GoblinVehicleService')
rolls={}
ZombRand=function(a,b) local v=table.remove(rolls,1); if v then return v end; return a and b and a or 0 end
Perks={FromString=function(name) return name end, Mechanics='Mechanics'}
Fluid={Petrol='Petrol'}
Vehicles={JerryCanLitres=10}
transmits={}
-- Toolkit: ensure creates one reserved real item per type.
local Tools=package.loaded['GoblinSurvivor/GoblinTools']
Tools.ensure=function(b,kind)
    for _,v in ipairs(b.inv.items) do if v.kind==kind and reserved[v] then return v end end
    local tool=item(kind,'Tool'); reserved[tool]=true; b.inv.items[#b.inv.items+1]=tool
    return tool
end
function body:getPerkLevel() return self.mechanics or 0 end
function body:isRecipeActuallyKnown(name) return self.recipes and self.recipes[name]==true end
function body:getCurrentSquare() return squareAt(math.floor(self.pos.x),math.floor(self.pos.y),0) end
body.inv.haveThisKeyId=function(self,id)
    for _,v in ipairs(self.items) do if v.keyId==id then return true end end
    return false
end
function javaList(values)
    return {size=function() return #values end,get=function(_,i) return values[i+1] end}
end
function makePart(vehicle,id,opts)
    local p={id=id,vehicle=vehicle,item=opts.item,tables=opts.tables or {},types=opts.types or {},
        area=opts.area or id,condition=opts.condition or 100,content=opts.content or 0,
        capacity=opts.capacity or 0,wheel=opts.wheel,door=opts.door,requireKey=opts.requireKey==true}
    function p:getId() return self.id end
    function p:getInventoryItem() return self.item end
    function p:setInventoryItem(value) self.item=value end
    function p:getTable(name) return self.tables[name] end
    function p:getItemType() return javaList(self.types) end
    function p:getArea() return self.area end
    function p:getCondition() return self.condition end
    function p:setCondition(v) self.condition=v end
    function p:getContainerContentAmount() return self.content end
    function p:setContainerContentAmount(v) self.content=v end
    function p:getContainerCapacity() return self.capacity end
    function p:getWheelIndex() return self.wheel end
    function p:getDoor() return self.door end
    function p:getWindow() return nil end
    function p:getItemContainer() return nil end
    function p:getContainerSeatNumber() return -1 end
    function p:getScriptPart() local r=self.requireKey; return {isMechanicRequireKey=function() return r end} end
    vehicle.parts[#vehicle.parts+1]=p
    vehicle.byId[id]=p
    return p
end
function makeVehicle(x,y)
    local v={x=x,y=y,z=0,id=7,sql=4242,speed=0,running=false,parts={},byId={},keyId=99,battery=0.5}
    function v:getX() return self.x end
    function v:getY() return self.y end
    function v:getZ() return self.z end
    function v:getId() return self.id end
    function v:getSqlId() return self.sql end
    function v:getCurrentSpeedKmHour() return self.speed end
    function v:isEngineRunning() return self.running end
    function v:getMaxPassengers() return 4 end
    function v:getCharacter() return self.passenger end
    function v:getPartById(id) return self.byId[id] end
    function v:getPartCount() return #self.parts end
    function v:getPartByIndex(i) return self.parts[i+1] end
    function v:getSquareForArea() return squareAt(math.floor(self.x),math.floor(self.y)+1,0) end
    function v:isInArea() return true end
    function v:getKeyId() return self.keyId end
    function v:getBatteryCharge() return self.battery end
    function v:getSquare() return squareAt(math.floor(self.x),math.floor(self.y),0) end
    function v:isSeatOccupied() return false end
    function v:getAreaCenter() return {getX=function() return self.x end,getY=function() return self.y end} end
    function v:setTireInflation(i,value) self.inflation=self.inflation or {}; self.inflation[i]=value end
    for _,name in ipairs({'transmitPartItem','transmitPartModData','transmitPartDoor','transmitPartCondition'}) do
        v[name]=function(_,p) transmits[#transmits+1]={name=name,part=p and p.id} end
    end
    return v
end
car=makeVehicle(10.5,10.5)
cell.getVehicles=function() return javaList({car}) end
getVehicleById=function(id) if id==car.id then return car end end
owner.pos={x=9.5,y=10.5,z=0}
body.pos={x=8.5,y=10.5,z=0}
tireTables={
    install={items={[1]={type='Base.Jack',keep='true'},[2]={tags='base:lugwrench',equip='primary',keep='true'}},
        requireInstalled='BrakeFrontLeft;SuspensionFrontLeft',skills='Mechanics:1',time='400',
        complete='Vehicles.InstallComplete.Tire'},
    uninstall={items={[1]={type='Base.Jack',keep='true'},[2]={tags='base:lugwrench',equip='primary',keep='true'}},
        skills='Mechanics:1',time='400',complete='Vehicles.UninstallComplete.Tire'}}
completions={}
VehicleUtils={callLua=function(name,v,p,i) completions[#completions+1]={name=name,part=p.id,item=i} end}
function withTire(condition,pressure)
    local old=item('Base.NormalTire1','VehicleMaintenance'); old.condition=condition
    function old:getCondition() return self.condition or 100 end
    function old:setCondition(v) self.condition=v end
    function old:setItemCapacity(v) self.capacityValue=v end
    function old:setJobDelta() end
    makePart(car,'BrakeFrontLeft',{item=item('Base.NormalBrake1','VehicleMaintenance'),types={'Base.NormalBrake1'},
        tables={install={recipes='Basic Mechanics',items={[1]={type='Base.Jack'}},skills='Mechanics:3'},
            uninstall={recipes='Basic Mechanics',items={[1]={type='Base.Jack'}},skills='Mechanics:3',
                requireUninstalled='TireFrontLeft'}}})
    makePart(car,'SuspensionFrontLeft',{item=item('Base.NormalSuspension1','VehicleMaintenance'),
        types={'Base.NormalSuspension1'}})
    return makePart(car,'TireFrontLeft',{item=old,types={'Base.OldTire1','Base.NormalTire1','Base.ModernTire1'},
        tables=tireTables,condition=condition,content=pressure,capacity=35,wheel=0}), old
end
function spareTire()
    local spare=item('Base.NormalTire1','VehicleMaintenance')
    function spare:getCondition() return 100 end
    function spare:setJobDelta() end
    return spare
end
function runVehicle(handler,payload,limit)
    return run(handler,payload,{},limit)
end
'''


class VehicleServiceTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT / "tests/lua/logistics_fixture.lua").read_text())
        self.lua.execute(VEHICLE_FIXTURE)

    def test_inspection_reports_real_state_without_mutation(self):
        self.lua.execute('''
            local tank=makePart(car,'GasTank',{item=item('Base.NormalGasTank1','VehicleMaintenance'),
                types={'Base.NormalGasTank1'},content=20,capacity=50})
            withTire(80,20)
            local payload=assert(Service.Inspect.prepare(body,owner,{}))
            assert(payload.vehicle_sql==4242)
            local success,detail=runVehicle(Service.Inspect,payload)
            assert(success and detail:find('fuel 40%%') and detail:find('battery 50%%'), detail)
            assert(detail:find('1 low tire'), detail)
            assert(#transmits==0 and tank.content==20)
        ''')

    def test_refuel_moves_real_petrol_from_carried_can(self):
        self.lua.execute('''
            local tank=makePart(car,'GasTank',{item=item('Base.NormalGasTank1','VehicleMaintenance'),
                types={'Base.NormalGasTank1'},content=10,capacity=50})
            local can=item('Base.PetrolCan','VehicleMaintenance')
            local fluid={amount=8}
            function fluid:contains(kind) return kind=='Petrol' end
            function fluid:getAmount() return self.amount end
            function fluid:adjustAmount(v) self.amount=v end
            function can:getFluidContainer() return fluid end
            function can:syncItemFields() self.synced=true end
            body.inv.items={can}
            local payload=assert(Service.Refuel.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=runVehicle(Service.Refuel,payload)
            assert(success and code=='COMPLETE', detail)
            assert(tank.content==18 and fluid.amount==0 and can.synced and payload.added==8)
            assert(body.inv.items[1]==can)
        ''')

    def test_refuel_uses_pump_units_and_refuses_running_engine(self):
        self.lua.execute('''
            local tank=makePart(car,'GasTank',{item=item('Base.NormalGasTank1','VehicleMaintenance'),
                types={'Base.NormalGasTank1'},content=40,capacity=50})
            local pump={units=100}
            function pump:getPipedFuelAmount() return self.units end
            function pump:setPipedFuelAmount(v) self.units=v end
            local sq=squareAt(11,10,0); sq.objects[#sq.objects+1]=pump
            car.running=true
            assert(Service.Refuel.prepare(body,owner,{explicit_owner_order=true})==nil)
            car.running=false
            local payload=assert(Service.Refuel.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail=runVehicle(Service.Refuel,payload)
            assert(success and tank.content==50 and pump.units==92, detail..' '..pump.units)
        ''')

    def test_change_tire_removes_installs_and_inflates_with_real_parts(self):
        self.lua.execute('''
            local tire,old=withTire(10,0)
            local spare=spareTire()
            body.inv.items={spare}
            rolls={0,0}
            local payload=assert(Service.Tire.prepare(body,owner,{explicit_owner_order=true}))
            assert(payload.part=='TireFrontLeft' and payload.stage=='remove')
            local success,detail,code=runVehicle(Service.Tire,payload)
            assert(success and code=='COMPLETE', detail)
            assert(tire.item==spare and tire.content==35 and car.inflation[0]==1.0)
            local held=false
            for _,v in ipairs(body.inv.items) do if v==old then held=true end end
            assert(held, 'old tire must stay with Goblin')
            assert(completions[1].name=='Vehicles.UninstallComplete.Tire')
            assert(completions[2].name=='Vehicles.InstallComplete.Tire')
        ''')

    def test_missing_replacement_reports_shortage_after_removal(self):
        self.lua.execute('''
            local tire,old=withTire(10,0)
            rolls={0}
            local payload=assert(Service.Replace.prepare(body,owner,{explicit_owner_order=true,part='TireFrontLeft'}))
            -- The removed tire itself must never be chosen as its own replacement.
            local success,detail,code=runVehicle(Service.Replace,payload)
            assert(not success and code=='MISSING_MATERIAL' and detail:find('old part was removed'), detail)
            assert(tire.item==nil)
        ''')

    def test_recipe_gated_part_is_refused_unless_actually_known(self):
        self.lua.execute('''
            withTire(100,35)
            local tire=car.byId.TireFrontLeft
            tire.item=nil
            local payload,detail=Service.Remove.prepare(body,owner,{explicit_owner_order=true,part='BrakeFrontLeft'})
            assert(payload==nil and detail:find('Basic Mechanics'), detail)
            body.recipes={['Basic Mechanics']=true}
            payload=assert(Service.Remove.prepare(body,owner,{explicit_owner_order=true,part='BrakeFrontLeft'}))
        ''')

    def test_mechanic_key_rule_blocks_locked_vehicle(self):
        self.lua.execute('''
            local door={open=false,locked=true}
            function door:isOpen() return self.open end
            function door:isLocked() return self.locked end
            makePart(car,'DoorFrontLeft',{item=item('Base.FrontCarDoor1','VehicleMaintenance'),
                types={'Base.FrontCarDoor1'},door=door})
            local battery=item('Base.CarBattery1','VehicleMaintenance')
            makePart(car,'Battery',{item=battery,types={'Base.CarBattery1'},requireKey=true,
                tables={uninstall={items={[1]={tags='base:screwdriver',equip='primary'}},time='100'}}})
            local payload,detail=Service.Remove.prepare(body,owner,{explicit_owner_order=true,part='Battery'})
            assert(payload==nil and detail:find('locked'), detail)
            local key=item('Base.CarKey','Security'); key.keyId=99
            body.inv.items[#body.inv.items+1]=key
            assert(Service.Remove.prepare(body,owner,{explicit_owner_order=true,part='Battery'}))
        ''')

    def test_engine_cover_is_opened_for_battery_and_closed_after(self):
        self.lua.execute('''
            local hoodDoor={open=false,locked=false}
            function hoodDoor:isOpen() return self.open end
            function hoodDoor:isLocked() return self.locked end
            function hoodDoor:setOpen(v) self.open=v; self.history=(self.history or '')..tostring(v)..';' end
            makePart(car,'EngineDoor',{item=item('Base.EngineDoor1','VehicleMaintenance'),
                types={'Base.EngineDoor1'},door=hoodDoor})
            local batteryPart=makePart(car,'Battery',{types={'Base.CarBattery1'},
                tables={install={door='EngineDoor',items={[1]={tags='base:screwdriver',equip='primary'}},time='100'}}})
            local battery=item('Base.CarBattery1','VehicleMaintenance')
            function battery:getCondition() return 100 end
            function battery:setJobDelta() end
            body.inv.items={battery}
            local payload=assert(Service.Install.prepare(body,owner,{explicit_owner_order=true,part='Battery'}))
            local success,detail=runVehicle(Service.Install,payload)
            assert(success and batteryPart.item==battery, detail)
            assert(hoodDoor.history=='true;false;' and not hoodDoor.open, tostring(hoodDoor.history))
        ''')

    def test_restart_after_install_does_not_repeat_it(self):
        self.lua.execute('''
            local tire,old=withTire(10,35)
            tire.item=nil
            local spare=spareTire()
            body.inv.items={spare}
            local payload=assert(Service.Install.prepare(body,owner,{explicit_owner_order=true,part='TireFrontLeft'}))
            -- Simulate: install happened, the stage save was lost, only the ID was saved.
            payload.installing_id=spare:getID()
            body.inv:Remove(spare); tire.item=spare
            local success,detail=runVehicle(Service.Install,payload)
            assert(success and detail:find('installed'), detail)
            local installs=0
            for _,t in ipairs(transmits) do if t.name=='transmitPartItem' then installs=installs+1 end end
            assert(installs==0)
        ''')

    def test_moved_vehicle_and_session_id_change(self):
        self.lua.execute('''
            makePart(car,'GasTank',{item=item('Base.NormalGasTank1','VehicleMaintenance'),
                types={'Base.NormalGasTank1'},content=20,capacity=50})
            local payload=assert(Service.Inspect.prepare(body,owner,{}))
            car.id=8
            assert(Service.resolve(payload)==car)
            car.x=40
            local v,why,code=Service.resolve(payload)
            assert(v==nil and code=='TARGET_CHANGED')
        ''')

    def test_failed_install_roll_keeps_part_item_and_stops_after_three(self):
        self.lua.execute('''
            local tire,old=withTire(10,35)
            tire.item=nil
            local spare=spareTire()
            body.inv.items={spare}
            rolls={99,99,99,99,99,99}
            local payload=assert(Service.Install.prepare(body,owner,{explicit_owner_order=true,part='TireFrontLeft'}))
            local success,detail,code=runVehicle(Service.Install,payload)
            assert(not success and code=='BLOCKED' and tire.item==nil, detail)
            local held=false
            for _,v in ipairs(body.inv.items) do if v==spare then held=true end end
            assert(held)
        ''')


if __name__ == "__main__":
    unittest.main()

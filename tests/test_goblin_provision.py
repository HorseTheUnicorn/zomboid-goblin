"""Conjured supplies: Goblin may create what his own jobs consume, never give it away."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"

try:
    import test_goblin_vehicle_service as vehicle_tests
except ImportError:  # pragma: no cover
    from tests import test_goblin_vehicle_service as vehicle_tests

FACTORY = r'''
Provision=require('GoblinSurvivor/GoblinProvision')
Transfer=require('GoblinSurvivor/GoblinTransfer')
for _,name in ipairs({'Base.Plank','Base.Nails','Base.Bandage','Base.NormalTire1','Base.PetrolCan',
    'Base.WaterBottle','Base.EngineParts','Base.CarBattery1'}) do known[name]=true end
Fluid=Fluid or {}; Fluid.Petrol='Petrol'; Fluid.Water='Water'
created={}
instanceItem=function(fullType)
    local display=({['Base.Plank']='MaterialWeapon',['Base.Nails']='Material',['Base.Bandage']='Bandage',
        ['Base.NormalTire1']='VehicleMaintenance',['Base.PetrolCan']='VehicleMaintenance'})[fullType] or 'Material'
    local value=item(fullType,display)
    if fullType=='Base.Bandage' then
        function value:getBandagePower() return 4 end
        function value:isAlcoholic() return false end
        function value:isInfected() return false end
    end
    if fullType=='Base.NormalTire1' then
        function value:getCondition() return 100 end
        function value:setJobDelta() end
    end
    if fullType=='Base.PetrolCan' then
        local fluid={amount=0,capacity=10,kind=nil}
        function fluid:getCapacity() return self.capacity end
        function fluid:getAmount() return self.amount end
        function fluid:addFluid(kind,amount) self.kind=kind; self.amount=self.amount+amount end
        function fluid:adjustAmount(v) self.amount=v end
        function fluid:contains(kind) return self.kind==kind and self.amount>0 end
        function value:getFluidContainer() return fluid end
        function value:syncItemFields() end
    end
    created[#created+1]=value
    return value
end
'''


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT / "tests/lua/logistics_fixture.lua").read_text())
        self.lua.execute(FACTORY)

    def test_conjured_items_are_valid_marked_bounded_and_in_goblin_custody(self):
        self.lua.execute('''
            local items=assert(Provision.create(body,'Base.Nails',4,'test'))
            assert(#items==4 and #body.inv.items==4)
            for _,value in ipairs(items) do assert(Provision.isConjured(value)) end
            assert(Provision.create(body,'Base.NotAThing',1,'test')==nil)
            assert(Provision.create(body,'Base.Nails',21,'test')==nil)
            config.provisionPerMinute=5
            assert(Provision.create(body,'Base.Nails',2,'test')==nil) -- 4+2 > 5 this minute
            config.provisionEnabled=false
            assert(Provision.create(body,'Base.Nails',1,'test')==nil)
        ''')

    def test_conjured_items_never_reach_containers_floor_or_player(self):
        self.lua.execute('''
            local nail=assert(Provision.create(body,'Base.Nails',1,'test'))[1]
            local crate=furniture(0,0,{})
            local ok,code=Transfer.deposit(body,nail,crate.c)
            assert(not ok and code=='BLOCKED' and #crate.c.items==0)
            ok,code=Transfer.handOver(body,nail,owner,true)
            assert(not ok and code=='BLOCKED' and #owner.inv.items==0)
            ok,code=Transfer.drop(body,nail,squareAt(2,2,0))
            assert(not ok and #squareAt(2,2,0).world==0)
            assert(body.inv.items[1]==nail)
            -- Delivery never selects conjured cargo; real cargo still goes.
            local Deliver=require('GoblinSurvivor/GoblinDeliverWork')
            assignAt(0,0,'materials',crate)
            local payload,detail=Deliver.prepare(body,owner,{explicit_owner_order=true})
            assert(payload==nil and detail:find('not carrying'))
            local real=item('Base.Nails','Material'); body.inv.items[#body.inv.items+1]=real
            payload=assert(Deliver.prepare(body,owner,{explicit_owner_order=true}))
            assert(#payload.ledger==1 and payload.ledger[1].id==real:getID())
        ''')

    def test_structure_repair_conjures_its_own_parts_and_leaves_base_stock(self):
        self.lua.execute('''
            local Repair=require('GoblinSurvivor/GoblinStructureRepair')
            local sq=squareAt(1,1,0)
            local door={health=50,synced=0,sprite={getName=function() return 'door' end}}
            function door:getHealth() return self.health end
            function door:getMaxHealth() return 100 end
            function door:setHealth(v) self.health=v end
            function door:sync() self.synced=self.synced+1 end
            function door:getObjectIndex() return 0 end
            function door:getSprite() return self.sprite end
            function door:getSquare() return sq end
            sq.objects[1]=door
            ISMoveableSpriteProps={fromObject=function(object)
                local props={object=object,material='Wood',isMultiSprite=false}
                function props:canRepairObject() return {craftValid=true} end
                function props:getAllRepairParts()
                    return {{itemType='Base.Plank',amount=2,required=true},{itemType='Base.Nails',amount=4,required=false}}
                end
                function props:hasRepairTool() return true end
                function props:hasRepairParts(c) return count(c:getInventory(),'Base.Plank')>=2 and count(c:getInventory(),'Base.Nails')>=4 end
                function props:getRepairActionTime() return 100 end
                function props:getRepairSkillChance() return 100 end
                function props:getAdditionalObjects() return {} end
                return props
            end}
            ISMoveableDefinitions={getInstance=function() return {getRepairDefinition=function()
                return {tools={},tools2={}} end} end}
            ZombRand=function() return 0 end
            local shelf=furniture(3,3,{item('Base.Plank','MaterialWeapon'),item('Base.Plank','MaterialWeapon')})
            local payload=assert(Repair.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail=run(Repair,payload)
            assert(success and door.health==100, detail)
            assert(#shelf.c.items==2, 'player planks must not be used')
            assert(#body.inv.items==0, 'conjured parts are consumed')
        ''')

    def test_treat_player_conjures_a_bandage(self):
        self.lua.execute('''
            local Survival=require('GoblinSurvivor/GoblinSurvival')
            local part={index=9,bleed=5,isBandaged=false}
            function part:getIndex() return self.index end
            function part:bandaged() return self.isBandaged end
            function part:getBleedingTime() return self.bleed end
            function part:scratched() return false end
            function part:isCut() return false end
            function part:deepWounded() return false end
            function part:bitten() return false end
            function part:manipulatingUsername() return '' end
            function part:setManipulatingUsername() end
            local damage={}
            function damage:getBodyParts() return list({part}) end
            function damage:SetBandaged(i,v,life,alc,kind) part.isBandaged=v; part.kind=kind end
            function owner:getBodyDamage() return damage end
            local payload=assert(Survival.Treat.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail=run(Survival.Treat,payload)
            assert(success and part.isBandaged and part.kind=='Base.Bandage', detail)
            assert(#body.inv.items==0)
        ''')

    def test_death_purges_conjured_supplies_but_keeps_real_items(self):
        self.lua.execute('''
            assert(Provision.create(body,'Base.Plank',3,'test'))
            local real=item('Base.Nails','Material'); body.inv.items[#body.inv.items+1]=real
            assert(Provision.purge(body)==3)
            assert(#body.inv.items==1 and body.inv.items[1]==real)
        ''')


class VehicleProvisionTests(unittest.TestCase):
    setUp = vehicle_tests.VehicleServiceTests.setUp

    def test_tire_change_and_refuel_use_conjured_supplies_only_on_the_vehicle(self):
        self.lua.execute(FACTORY)
        self.lua.execute('''
            local tire,old=withTire(10,0)
            rolls={0,0}
            local payload=assert(Service.Tire.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail=runVehicle(Service.Tire,payload)
            assert(success, detail)
            assert(tire.item~=old and Provision.isConjured(tire.item) and tire.content==35)
            local tank=makePart(car,'GasTank',{item=item('Base.NormalGasTank1','VehicleMaintenance'),
                types={'Base.NormalGasTank1'},content=5,capacity=25})
            payload=assert(Service.Refuel.prepare(body,owner,{explicit_owner_order=true}))
            success,detail=runVehicle(Service.Refuel,payload)
            assert(success and tank.content==25, detail)
            for _,value in ipairs(body.inv.items) do
                assert(value.kind~='Base.PetrolCan', 'empty conjured cans are discarded')
            end
        ''')


if __name__ == "__main__":
    unittest.main()

"""Real Lua building/assignment logic with fake engine objects, not live proof."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
LUA=ROOT/'mod/Contents/mods/GoblinSurvivor/42/media/lua'


class FoodStorageTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths=';'.join((LUA/s/'?.lua').as_posix() for s in ('shared','server','client'))
        self.lua.execute('package.path=paths..";"..package.path')
        for filename in ('goblin_fixture.lua','work_fixture.lua'):
            self.lua.execute((ROOT/'tests/lua'/filename).read_text())
        self.lua.execute('''
            local Curtains=require('GoblinSurvivor/GoblinCurtains')
            house={id='test-house',rooms={{x=0,y=0,x2=3,y2=3,z=0}}}
            Curtains.scopeAt=function() return house end
            Curtains.belongsToScope=function(_,square) return square and square.x>=0 and square.y>=0 and square.x<=3 and square.y<=3 end
            records={}
            package.loaded['GoblinSurvivor/GoblinSpawner']={
                baseForOwner=function() return {x=0,y=0,z=0} end,
                storageAssignmentsForOwner=function() return records end,
                setStorageAssignmentForOwner=function(_,record) records[record.id]=record;return not rejectSave end}
            local native=IsoThumpable.new
            IsoThumpable.new=function(c,sq,sprite,north,metadata)
                local object=native(c,sq,sprite,north,metadata)
                function object:getModData() return metadata end
                function object:getSquare() return sq end
                function object:setIsContainer(v) if v then self.inv=container({}) end end
                function object:getContainer() return self.inv end
                function object:transmitModData() self.mdSent=true end
                function object:transmitCompleteItemToClients() self.worldSent=true end
                return object
            end
            FoodStorage=require('GoblinSurvivor/GoblinFoodStorage')
            Storage=require('GoblinSurvivor/GoblinStorage')
            request={food_cycle=true,explicit_owner_order=true}
            function finish(payload)
                local runtime={}
                for i=1,20 do
                    local done,success,why,code=FoodStorage.update(a,payload,runtime,clock+i*1000)
                    if done then return success,why,code end
                end
                error('storage did not finish')
            end
        ''')

    def test_build_consumes_materials_and_assigns_the_actual_crate(self):
        self.lua.execute('''
            supplies(3,3)
            local payload,why=FoodStorage.prepare(a,player,request);assert(payload,why)
            local success,detail,code=finish(payload);assert(success,detail)
            assert(code=='COMPLETE' and a.data.GoblinWorkCompleted==1)
            local planks,nails=0,0
            for _,item in ipairs(World.items(a.inv)) do
                if World.fullType(item)=='Base.Plank' then planks=planks+1 end
                if World.fullType(item)=='Base.Nails' then nails=nails+1 end
            end
            assert(planks==0 and nails==0)
            local live=Storage.assignments(a,house)
            assert(#live==1 and live[1].category=='FOOD')
            assert(live[1].object.worldSent and live[1].object.mdSent)
            assert(live[1].object:getModData().GoblinFoodCrate)
            local again=assert(FoodStorage.prepare(a,player,request))
            assert(finish(again) and a.data.GoblinWorkCompleted==1 and #Storage.assignments(a,house)==1)
        ''')

    def test_no_order_or_offline_actor_cannot_start_storage_construction(self):
        self.lua.execute('''
            assert(FoodStorage.prepare(a,player,{})==nil)
            assert(FoodStorage.prepare(a,nil,request)==nil)
        ''')

    def test_occupied_or_door_adjacent_ground_is_not_a_crate_site(self):
        self.lua.execute('''
            for x=-1,4 do for y=-1,4 do
                local sq=cell:getGridSquare(x,y,0)
                function sq:getDoorOrWindow() return {door=true} end
            end end
            assert(FoodStorage.prepare(a,player,request)==nil)
        ''')

    def test_missing_materials_do_not_create_a_container(self):
        self.lua.execute('''
            local payload=assert(FoodStorage.prepare(a,player,request))
            FoodStorage.update(a,payload,{},clock)
            local done,ok=FoodStorage.update(a,payload,{},clock+91000)
            assert(done and not ok and #Storage.assignments(a,house)==0)
            assert(a.data.GoblinWorkCompleted==nil)
        ''')

    def test_registry_failure_keeps_one_crate_and_never_claims_assignment(self):
        self.lua.execute('''
            supplies(3,3);rejectSave=true
            local payload=assert(FoodStorage.prepare(a,player,request))
            local ok,why,code=finish(payload)
            assert(not ok and code=='TARGET_CHANGED' and a.data.GoblinWorkCompleted==1)
            rejectSave=false;records={}
            local retry=assert(FoodStorage.prepare(a,player,request))
            assert(finish(retry) and a.data.GoblinWorkCompleted==1)
        ''')


if __name__=='__main__':
    unittest.main()

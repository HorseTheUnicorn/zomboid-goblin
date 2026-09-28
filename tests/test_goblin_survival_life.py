"""FORAGE / CHECK_TRAPS / COOK fixtures (not engine or multiplayer evidence)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"

FIXTURE = r'''
Life=require('GoblinSurvivor/GoblinSurvivalLife')
ZombRand=function(n) return 0 end
instanceItem=function(kind) known[kind]=true; return item(kind,'Food') end
known['Base.Carrots']=true
-- Outdoor forest squares around the owner.
for x=-12,20 do for y=-12,20 do
    local sq=squareAt(x,y,0); function sq:isOutside() return true end
end end
forageSystem={
    getDefinedZoneAt=function(x,y) return {name='Forest'} end,
    pickRandomItemType=function(zone) assert(zone=='Forest'); return 'Base.BerryBlack' end,
}
'''


class SurvivalLifeTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT / "tests/lua/logistics_fixture.lua").read_text())
        self.lua.execute(FIXTURE)

    def test_forage_rolls_real_items_from_the_installed_forage_system(self):
        self.lua.execute('''
            assert(Life.Forage.prepare(body,owner,{})==nil) -- needs an owner order
            assert(Life.Forage.prepare(body,owner,{explicit_owner_order=true,count=11})==nil)
            local payload=assert(Life.Forage.prepare(body,owner,{explicit_owner_order=true,count=3}))
            local success,detail,code=run(Life.Forage,payload)
            assert(success and code=='COMPLETE' and payload.completed==3, detail)
            assert(count(body.inv,'Base.BerryBlack')==3)
            -- Finds are ordinary cargo, not conjured supplies.
            local Provision=require('GoblinSurvivor/GoblinProvision')
            for _,v in ipairs(body.inv.items) do assert(not Provision.isConjured(v)) end
            assert(require('GoblinSurvivor/GoblinLoot').hasCargo(body))
        ''')

    def test_forage_refuses_without_forage_ground(self):
        self.lua.execute('''
            forageSystem.getDefinedZoneAt=function() return false end
            local payload,detail=Life.Forage.prepare(body,owner,{explicit_owner_order=true})
            assert(payload==nil and detail:find('no forageable'), detail)
        ''')

    def test_trap_run_collects_catches_and_rebaits_with_conjured_bait(self):
        self.lua.execute('''
            local traps={}
            local function trap(x,y,animal,bait)
                local t={x=x,y=y,z=0,animal=animal or {},bait=bait,player='horse'}
                function t:removeAnimal(character)
                    assert(character:getUsername()~='horse') -- skips IsoPlayer-only addXp
                    assert(not self.animal.canBeAlive)
                    character:getInventory():AddItem(item(self.animal.item,'Food'))
                    sendAddItemToContainer(character:getInventory(),'x')
                    self.animal={}
                end
                function t:addBait(kind,age,multi,player)
                    assert(player:getUsername()=='horse');self.bait=kind
                end
                traps[#traps+1]=t
                return t
            end
            local full=trap(4,4,{type='rabbit',item='Base.DeadRabbit',canBeAlive=true},'Base.Carrots')
            local empty=trap(6,2,nil,nil)
            local fine=trap(1,1,nil,'Base.Carrots')
            STrapSystem={instance={getLuaObjectCount=function() return #traps end,
                getLuaObjectByIndex=function(_,i) return traps[i] end}}
            local sentBefore=#sent.add
            local payload=assert(Life.Traps.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Life.Traps,payload)
            assert(success and code=='COMPLETE' and payload.caught==1 and payload.baited==1, detail)
            assert(count(body.inv,'Base.DeadRabbit')==1 and full.animal.type==nil)
            assert(empty.bait=='Base.Carrots' and count(body.inv,'Base.Carrots')==0)
            assert(#sent.add==sentBefore) -- no actor-inventory packet
            assert(sendAddItemToContainer~=nil)
        ''')

    def test_cook_loads_a_hot_stove_and_takes_food_out_cooked(self):
        self.lua.execute('''
            local function food(kind)
                local f=item(kind,'Food'); f.cooked=false
                function f:isCookable() return true end
                function f:isCooked() return self.cooked end
                function f:isBurnt() return false end
                return f
            end
            local steak=food('Base.Steak'); local egg=food('Base.Egg')
            local fridge=furniture(1,1,{steak,egg})
            local stove=furniture(3,3,{})
            stove.class='IsoStove'; stove.on=false
            function stove:Activated() return self.on end
            function stove:Toggle() self.on=not self.on end
            local payload=assert(Life.Cook.prepare(body,owner,{explicit_owner_order=true,count=2}))
            local runtime={}
            local clock=1000
            local done,success,detail,code
            for i=1,60 do
                clock=clock+1000
                done,success,detail,code=Life.Cook.update(body,payload,runtime,clock)
                assert(not done or success, detail)
                if payload.phase=='cooking' and #stove.c.items==2 then
                    assert(stove.on)
                    for _,v in ipairs(stove.c.items) do v.cooked=true end
                end
                if done then break end
            end
            assert(done and success and code=='COMPLETE' and payload.completed==2, detail)
            assert(steak.cooked and egg.cooked and #stove.c.items==0 and #fridge.c.items==0)
            assert(body.inv:contains(steak) and body.inv:contains(egg))
            assert(not stove.on) -- switched back off
        ''')

    def test_cook_reports_a_cold_stove(self):
        self.lua.execute('''
            local f=item('Base.Steak','Food')
            function f:isCookable() return true end
            function f:isCooked() return false end
            function f:isBurnt() return false end
            body.inv.items={f}
            local stove=furniture(3,3,{})
            stove.class='IsoStove'
            function stove:Activated() return false end
            function stove:Toggle() end
            local payload=assert(Life.Cook.prepare(body,owner,{explicit_owner_order=true,count=1}))
            local success,detail,code=run(Life.Cook,payload)
            assert(not success and code=='BLOCKED' and detail:find('power'), detail)
            assert(body.inv:contains(f))
        ''')


if __name__ == "__main__":
    unittest.main()

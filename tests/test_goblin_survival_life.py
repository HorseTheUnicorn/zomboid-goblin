"""FORAGE / CHECK_TRAPS / COOK fixtures (not engine or multiplayer evidence)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"

FIXTURE = r'''
Life=require('GoblinSurvivor/GoblinSurvivalLife')
next=nil -- the PZ server Lua has no global next
local seed=7
ZombRand=function(n) seed=(seed*1103515245+12345)%2147483648; return seed%n end
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

    def test_traps_are_placed_owned_by_the_player_and_baited(self):
        self.lua.execute('''
            known['Base.TrapBox']=true
            Traps={{type='Base.TrapBox',sprite='constructedobjects_01_4',closedSprite='constructedobjects_01_5'}}
            IsoFlagType={solid='solid',solidtrans='solidtrans',solidfloor='solidfloor'}
            IsoObjectType={tree='tree'}
            for k,sq in pairs(squares) do
                function sq:getMovingObjects() return list({}) end
                function sq:has(f) return f=='solidfloor' end
                function sq:AddSpecialObject(o) self.objects[#self.objects+1]=o end
                function sq:RecalcAllWithNeighbours() end
            end
            local placed={}
            local system={objects={}}
            function system:getLuaObjectCount() return #self.objects end
            function system:getLuaObjectByIndex(i) return self.objects[i] end
            function system:getLuaObjectAt(x,y,z)
                for _,o in ipairs(self.objects) do if o.x==x and o.y==y and o.z==z then return o end end
            end
            STrapSystem={instance=system}
            TrapSystem={getTrapZones=function() return {Forest='Forest'} end,
                initObjectModData=function(obj,def,north,player) obj.md={player=player:getUsername(),trapType=def.type} end}
            IsoThumpable={new=function(cell,sq,sprite,north,tbl)
                local o={sq=sq,sprite=sprite}
                function o:setName(n) self.name=n end
                function o:transmitCompleteItemToClients() self.sent=true end
                placed[#placed+1]=o
                return o
            end}
            triggerEvent=function(name,obj)
                assert(name=='OnObjectAdded')
                local p={x=obj.sq:getX(),y=obj.sq:getY(),z=obj.sq:getZ()}
                local trap={x=p.x,y=p.y,z=p.z,animal={}}
                function trap:addBait(kind,age,multi,player) assert(player:getUsername()=='horse');self.bait=kind end
                system.objects[#system.objects+1]=trap
            end
            assert(Life.Traps.prepare(body,owner,{explicit_owner_order=true,place=9})==nil)
            local payload=assert(Life.Traps.prepare(body,owner,{explicit_owner_order=true,place=2}))
            local success,detail,code=run(Life.Traps,payload)
            assert(success and code=='COMPLETE' and payload.placed==2 and payload.baited==2, detail)
            assert(#placed==2 and placed[1].name=='Trap' and placed[1].sent and placed[1].md.player=='horse')
            assert(system.objects[1].bait=='Base.Carrots' and system.objects[2].bait=='Base.Carrots')
            assert(count(body.inv,'Base.TrapBox')==0 and count(body.inv,'Base.Carrots')==0)
        ''')

    def test_soup_pot_is_filled_through_the_evolved_recipe_on_a_new_campfire(self):
        self.lua.execute('''
            local function food(kind)
                local f=item(kind,'Food')
                function f:isRotten() return false end
                function f:isBurnt() return false end
                function f:isCookable() return false end
                return f
            end
            local carrot=food('Base.Carrots'); local potato=food('Base.Potato'); local nail=item('Base.Nails','Material')
            local fridge=furniture(1,1,{carrot,potato,nail})
            local recipe={}
            function recipe:getItemRecipe(i) if i.kind=='Base.Carrots' or i.kind=='Base.Potato' then return {} end end
            function recipe:getFullResultItem() return 'Base.PotOfSoupRecipe' end
            function recipe:addItem(pot,used,character)
                assert(character==body and pot.kind=='Base.PotOfSoupRecipe')
                pot.ingredients=(pot.ingredients or 0)+1
                used.c=used.c or nil
                for _,sq in pairs(squares) do for _,o in ipairs(sq.objects) do
                    if o.getContainer and o:getContainer() then o:getContainer():Remove(used) end end end
                return pot
            end
            ScriptManager.instance.getEvolvedRecipe=function(_,name) if name=='Soup' then return recipe end end
            for k,sq in pairs(squares) do
                function sq:isOutside() return true end
                function sq:isFree() return true end
            end
            local fire
            local system={objects={}}
            function system:getLuaObjectCount() return #self.objects end
            function system:getLuaObjectByIndex(i) return self.objects[i] end
            function system:addCampfire(sq)
                local obj=furniture(sq:getX(),sq:getY(),{})
                fire={x=sq:getX(),y=sq:getY(),z=0,isLit=false,fuelAmt=0,obj=obj}
                function fire:getSquare() return sq end
                function fire:getContainer() return obj.c end
                function fire:getIsoObject() return obj end
                function fire:addFuel(n) self.fuelAmt=self.fuelAmt+n end
                function fire:lightFire() if self.fuelAmt>0 then self.isLit=true end end
                function fire:putOut() self.isLit=false end
                self.objects[#self.objects+1]=fire
                return fire
            end
            SCampfireSystem={instance=system}
            local _instanceItem=instanceItem
            instanceItem=function(kind)
                local v=_instanceItem(kind)
                if kind=='Base.PotOfSoupRecipe' then
                    v.cooked=false
                    function v:isCooked() return self.cooked end
                    function v:isBurnt() return false end
                    function v:setIsCookable(b) self.cookable=b end
                end
                return v
            end
            local payload=assert(Life.Cook.prepare(body,owner,{explicit_owner_order=true,dish='soup',count=2}))
            local runtime,clock,done,success,detail,code={},1000
            for i=1,80 do
                clock=clock+1000
                done,success,detail,code=Life.Cook.update(body,payload,runtime,clock)
                if payload.phase=='cooking' and not done then
                    assert(fire and fire.isLit and fire.fuelAmt>=120)
                    for _,v in ipairs(fire.obj.c.items) do if v.kind=='Base.PotOfSoupRecipe' then v.cooked=true end end
                end
                if done then break end
            end
            assert(done and success and code=='COMPLETE' and payload.ingredients==2, tostring(detail)..' '..tostring(code)..' '..tostring(payload.ingredients))
            local pot
            for _,v in ipairs(body.inv.items) do if v.kind=='Base.PotOfSoupRecipe' then pot=v end end
            assert(pot and pot.ingredients==2 and pot.cooked)
            assert(#fridge.c.items==1 and fridge.c.items[1]==nail)
            assert(not fire.isLit) -- put out afterwards
            -- The soup is real food for the player, not a conjured supply.
            assert(not require('GoblinSurvivor/GoblinProvision').isConjured(pot))
        ''')

    def test_cooked_item_replaced_by_the_engine_is_still_collected(self):
        # Live: the soup pot is replaced by its cooked form (new item id);
        # Goblin reported cooked=0 and the job crashed the result contract.
        self.lua.execute('''
            local f=item('Base.Steak','Food')
            function f:isCookable() return true end
            function f:isCooked() return false end
            function f:isBurnt() return false end
            body.inv.items={f}
            local stove=furniture(3,3,{})
            stove.class='IsoStove'; stove.on=false
            function stove:Activated() return self.on end
            function stove:Toggle() self.on=not self.on end
            local payload=assert(Life.Cook.prepare(body,owner,{explicit_owner_order=true,count=1}))
            local runtime,clock,done,success,detail,code={},1000
            for i=1,60 do
                clock=clock+1000
                done,success,detail,code=Life.Cook.update(body,payload,runtime,clock)
                if payload.phase=='cooking' and #stove.c.items==1 and stove.c.items[1]==f then
                    local cooked=item('Base.SteakCooked','Food')
                    function cooked:isCooked() return true end
                    function cooked:isBurnt() return false end
                    stove.c.items={cooked}
                end
                if done then break end
            end
            assert(done and success and code=='COMPLETE' and payload.completed==1, tostring(detail)..' '..tostring(code))
            assert(count(body.inv,'Base.SteakCooked')==1 and #stove.c.items==0)
        ''')


if __name__ == "__main__":
    unittest.main()

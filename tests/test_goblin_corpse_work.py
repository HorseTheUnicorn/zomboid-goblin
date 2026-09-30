"""Corpse custody fixtures. Native managed actor/MP compatibility is pending."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
LUA=ROOT/'mod/Contents/mods/GoblinSurvivor/42/media/lua'


class CorpseWorkTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths=';'.join((LUA/s/'?.lua').as_posix() for s in ('shared','server'))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT/'tests/lua/logistics_fixture.lua').read_text())
        self.lua.execute('''
            print=function() end
            config.corpseCleanupEnabled=true
            scope.bounds={x=-1,y=-1,x2=5,y2=5,min_z=0,max_z=0}
            for x=-8,12 do for y=-8,12 do
                local sq=squareAt(x,y,0);sq.bodies={}
                sq.inside=x>=0 and y>=0 and x<=4 and y<=4
                function sq:isOutside() return not self.inside end
                function sq:isFree() return true end
                function sq:haveFire() return false end
                function sq:getDeadBodys() return list(self.bodies) end
                function sq:canReachTo() return true end
            end end
            function corpse(id,sq,inv,zombie)
                local c={id=id,inv=inv,sq=sq,zombie=zombie~=false}
                function c:getObjectIDAsLong() return self.id end
                function c:getContainer() return self.inv end
                function c:isZombie() return self.zombie end
                function c:isAnimal() return false end
                function c:getCharacterOnlineID() return self.dragId end
                function c:getSquare() return self.sq end
                sq.bodies[#sq.bodies+1]=c;return c
            end
            original=corpse(55,squareAt(1,1,0),container({item('Base.Nails')}))
            originalInventory=original.inv
            function body:getSquare() return squareAt(math.floor(self.pos.x),math.floor(self.pos.y),0) end
            function body:isDraggingCorpse() return self.carried~=nil end
            function body:getGrapplingTarget() return self.carried end
            function body:getSharedGrappleType() return 'BwdDragHead' end
            package.loaded['GoblinSurvivor/GoblinSpawner'].syncClientState=function(force)
                assert(force);syncs=(syncs or 0)+1
            end
            function body:pickUpCorpse(c,mode)
                assert(mode=='BwdDrag');pickups=(pickups or 0)+1
                if unsupported then return end
                for i,v in ipairs(c.sq.bodies) do if v==c then table.remove(c.sq.bodies,i);break end end
                self.carried={inv=c.inv,id=78}
                function self.carried:getInventory() return self.inv end
                function self.carried:getOnlineID() return self.id end
                function self.carried:getPersistentOutfitID() return 123 end
            end
            function body:setDoGrappleLetGo()
                releases=(releases or 0)+1
                if not self.carried or stuckDrop then return end
                local c=corpse(99,self:getSquare(),self.carried.inv);c.dragId=self.carried.id
                self.carried=nil
            end
            function body:LetGoOfGrappled(result)
                assert(result=='Released');self:setDoGrappleLetGo()
            end
            Corpse=require('GoblinSurvivor/GoblinCorpseWork')
            request={explicit_owner_order=true}
        ''')

    def test_original_inventory_moves_into_one_outside_pile(self):
        self.lua.execute('''
            local payload,why=Corpse.prepare(body,owner,request);assert(payload,why)
            assert(run(Corpse,payload))
            assert(payload.completed==1 and not body.carried and #original.sq.bodies==0)
            local outsideBody
            for _,sq in pairs(squares) do for _,c in ipairs(sq.bodies) do outsideBody=c end end
            assert(outsideBody and not outsideBody.sq.inside and outsideBody.inv==originalInventory)
            assert(#outsideBody.inv.items==1 and pickups==1)
        ''')

    def test_unvalidated_feature_is_disabled_by_default(self):
        self.lua.execute('''
            config.corpseCleanupEnabled=false
            assert(Corpse.prepare(body,owner,request)==nil and pickups==nil)
        ''')

    def test_owner_permission_and_player_remains_are_not_bypassed(self):
        self.lua.execute('''
            assert(Corpse.prepare(body,nil,request)==nil)
            assert(Corpse.prepare(body,owner,{})==nil)
            original.zombie=false
            assert(Corpse.prepare(body,owner,request)==nil and pickups==nil)
        ''')

    def test_unsupported_native_pickup_is_not_success_or_deletion(self):
        self.lua.execute('''
            unsupported=true
            local p=assert(Corpse.prepare(body,owner,request))
            local ok,why,code=run(Corpse,p)
            assert(not ok and code=='UNSUPPORTED' and #original.sq.bodies==1)
            assert(original.inv==originalInventory and p.completed==0)
        ''')

    def test_changed_contents_or_drop_timeout_never_count_as_cleanup(self):
        self.lua.execute('''
            local p=assert(Corpse.prepare(body,owner,request))
            Corpse.update(body,p,{},1000)
            assert(body.carried)
            body.carried.inv:AddItem(item('Base.Plank'))
            local done,ok,why,code=Corpse.update(body,p,{},2000)
            assert(done and not ok and code=='TARGET_CHANGED' and p.completed==0)
        ''')

    def test_roster_link_is_bounded_and_cleared_on_cancel(self):
        self.lua.execute('''
            local p=assert(Corpse.prepare(body,owner,request))
            Corpse.update(body,p,{},1000)
            local link=assert(body.data.GoblinCorpseDrag)
            assert(link.id==78 and link.outfit==123 and link.kind=='BwdDragHead')
            assert(link.expires==6000 and syncs==1)
            Corpse.clear(body)
            assert(not body.carried and not body.data.GoblinCorpseDrag)
            assert(releases==1 and syncs==2)
        ''')


if __name__=='__main__':
    unittest.main()

"""Bounded moveables-scrap fixtures; these are not engine or MP evidence."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class DismantleTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().lua_root = LUA.as_posix()
        self.lua.execute('''
            package.path=lua_root..'/server/?.lua;'..lua_root..'/shared/?.lua;'..package.path
            function list(items)
                return {size=function() return #items end,
                    get=function(_,i) return items[i+1] end}
            end
            body={data={GoblinBaseSet=true,GoblinBaseX=0,GoblinBaseY=0,GoblinBaseZ=0}}
            owner={getUsername=function() return 'horse' end}
            function getOnlinePlayers() return list({owner}) end
            local World={}
            function World.call(object,method,...)
                if not object or type(object[method])~='function' then return false,nil end
                return pcall(object[method],object,...)
            end
            function World.values(items)
                local out={}
                if items then for i=0,items:size()-1 do out[#out+1]=items:get(i) end end
                return out
            end
            function World.square(point)
                if not point then return nil end
                return squares[math.floor(point.x)..':'..math.floor(point.y)..':'..math.floor(point.z)]
            end
            function World.point(square) return {x=square.x+0.5,y=square.y+0.5,z=square.z} end
            function World.fullType(item) return item:getFullType() end
            package.loaded['GoblinSurvivor/GoblinWorld']=World
            package.loaded['GoblinSurvivor/GoblinBody']={
                data=function(b) return b.data end,
                position=function() return {x=0.5,y=0.5,z=0} end}
            available=true
            package.loaded['GoblinSurvivor/GoblinTools']={ensure=function(_,kind)
                return available and {kind=kind} or nil end}
            workCalls=0
            package.loaded['GoblinSurvivor/GoblinJobSupport']={
                validPoint=function(p) return p and type(p.x)=='number' end,
                work=function() workCalls=workCalls+1;return true end}
            scope={id='base-house'}
            package.loaded['GoblinSurvivor/GoblinCurtains']={
                scopeAt=function(point) return scope end,
                belongsToScope=function(_,square) return square and square.inside end}
            authorized=true
            package.loaded['GoblinSurvivor/GoblinAccessPolicy']={
                access=function() return authorized end}
            function instanceof() return false end
            function body:setPrimaryHandItem(item) self.primary=item end
            function body:setSecondaryHandItem(item) self.secondary=item end
            squares={}
            square={x=0,y=0,z=0,inside=true,objects={},world={}}
            function square:getObjects() return list(self.objects) end
            function square:getWorldObjects() return list(self.world) end
            squares['0:0:0']=square
            function item(kind)
                return {getFullType=function() return kind end}
            end
            function furniture(name)
                local object={name=name or 'wood-chair',square=square}
                function object:isObjectNoContainerOrEmpty() return self.empty~=false end
                function object:getObjectIndex()
                    for i,value in ipairs(self.square.objects) do if value==self then return i-1 end end
                    return -1
                end
                function object:getSprite() return {getName=function() return self.name end} end
                object.props={canScrap=true,material='Wood'}
                function object.props:canScrapObject() return {canScrap=object.allowed~=false} end
                function object.props:getScrapActionTime() return 100 end
                function object.props:scrapObject()
                    scrapCalls=(scrapCalls or 0)+1
                    for i,value in ipairs(square.objects) do
                        if value==object then table.remove(square.objects,i);break end
                    end
                    square.world[#square.world+1]={getItem=function() return item('Base.Plank') end}
                    if object.throwAfterRemoval then error('native failure after removal') end
                end
                square.objects[#square.objects+1]=object
                return object
            end
            ISMoveableSpriteProps={fromObject=function(object) return object.props end}
            Dismantle=require('GoblinSurvivor/GoblinDismantle')
            target=furniture()
        ''')

    def test_explicit_owner_order_consumes_native_salvage_once(self):
        self.lua.execute('''
            assert(Dismantle.prepare(body,owner,{})==nil)
            local payload=assert(Dismantle.prepare(body,owner,{explicit_owner_order=true}))
            assert(payload.anchor.x==0 and payload.anchor.y==0 and payload.anchor.z==0)
            local done,success,detail,code=Dismantle.update(body,payload,{},1000)
            assert(done and success and code=='COMPLETE')
            assert(detail:find('1 item') and scrapCalls==1 and #square.objects==0)
            assert(#square.world==1 and body.data.GoblinWorkCompleted==1)
            done,success,detail,code=Dismantle.update(body,payload,{},2000)
            assert(done and not success and code=='INTERRUPTED' and scrapCalls==1)
        ''')

    def test_ambiguous_nonempty_or_unauthorized_furniture_is_not_touched(self):
        self.lua.execute('''
            local request={explicit_owner_order=true}
            target.empty=false
            assert(Dismantle.prepare(body,owner,request)==nil)
            target.empty=true;local second=furniture('second-chair')
            assert(Dismantle.prepare(body,owner,request)==nil)
            table.remove(square.objects)
            authorized=false
            assert(Dismantle.prepare(body,owner,request)==nil)
            authorized=true;available=false
            assert(Dismantle.prepare(body,owner,request)==nil)
            assert(scrapCalls==nil and #square.objects==1)
        ''')

    def test_changed_target_and_lost_runtime_do_not_reselect(self):
        self.lua.execute('''
            local payload=assert(Dismantle.prepare(body,owner,{explicit_owner_order=true}))
            target.name='different-sprite'
            local done,success,detail,code=Dismantle.update(body,payload,{},1000)
            assert(done and not success and code=='TARGET_CHANGED' and scrapCalls==nil)
            target.name='wood-chair';Dismantle.targets[body]=nil
            done,success,detail,code=Dismantle.update(body,payload,{},2000)
            assert(done and not success and code=='INTERRUPTED' and scrapCalls==nil)
        ''')

    def test_post_removal_native_exception_is_not_retried(self):
        self.lua.execute('''
            local payload=assert(Dismantle.prepare(body,owner,{explicit_owner_order=true}))
            target.throwAfterRemoval=true
            local done,success,detail,code=Dismantle.update(body,payload,{},1000)
            assert(done and not success and code=='ENGINE_ERROR' and detail:find('do not retry'))
            assert(scrapCalls==1 and #square.objects==0 and #square.world==1)
            done,success,detail,code=Dismantle.update(body,payload,{},2000)
            assert(code=='INTERRUPTED' and scrapCalls==1)
        ''')

    def test_index_change_without_removal_is_not_reported_as_success(self):
        self.lua.execute('''
            local payload=assert(Dismantle.prepare(body,owner,{explicit_owner_order=true}))
            function target.props:scrapObject()
                scrapCalls=(scrapCalls or 0)+1
                table.insert(square.objects,1,{})
            end
            local done,success,detail,code=Dismantle.update(body,payload,{},1000)
            assert(done and not success and code=='ENGINE_ERROR')
            assert(scrapCalls==1 and square.objects[2]==target)
        ''')

    def test_permission_revoked_before_mutation_stops_work(self):
        self.lua.execute('''
            local payload=assert(Dismantle.prepare(body,owner,{explicit_owner_order=true}))
            authorized=false
            local done,success,detail,code=Dismantle.update(body,payload,{},1000)
            assert(done and not success and code=='PERMISSION_DENIED')
            assert(scrapCalls==nil and square.objects[1]==target)
        ''')

    def _salvage_fixture(self):
        self.lua.execute('''
            picked={}
            package.loaded['GoblinSurvivor/GoblinTransfer']={pickup=function(b,source)
                picked[#picked+1]=source.item:getFullType();return true end}
            function room(x,y,opts)
                opts=opts or {}
                local sq={x=x,y=y,z=0,inside=false,objects={},world={}}
                function sq:getObjects() return list(self.objects) end
                function sq:getWorldObjects() return list(self.world) end
                function sq:getRoom() if opts.outdoors then return nil end return {} end
                squares[x..':'..y..':0']=sq
                local object={name='other-house-table',square=sq}
                function object:isObjectNoContainerOrEmpty() return self.empty~=false end
                function object:getObjectIndex()
                    for i,value in ipairs(sq.objects) do if value==self then return i-1 end end
                    return -1
                end
                function object:getSprite() return {getName=function() return self.name end} end
                object.props={canScrap=true,material='Wood'}
                function object.props:canScrapObject() return {canScrap=true} end
                function object.props:getScrapActionTime() return 100 end
                function object.props:scrapObject()
                    scrapCalls=(scrapCalls or 0)+1
                    for i,value in ipairs(sq.objects) do if value==object then table.remove(sq.objects,i);break end end
                    sq.world[#sq.world+1]={getItem=function() return item('Base.Plank') end}
                    sq.world[#sq.world+1]={getItem=function() return item('Base.Plank') end}
                    sq.world[#sq.world+1]={getItem=function() return item('Base.Nails') end}
                end
                sq.objects[#sq.objects+1]=object
                return sq,object
            end
        ''')

    def test_salvage_scraps_furniture_elsewhere_and_keeps_the_planks(self):
        self._salvage_fixture()
        self.lua.execute('''
            local other,object=room(10,0)
            local payload,detail=Dismantle.prepare(body,owner,{salvage=true,autonomous=true})
            assert(payload,detail)
            assert(payload.salvage and payload.x==10 and payload.anchor.x==10)
            local done,success,detail,code=Dismantle.update(body,payload,{},1000)
            assert(done and success and code=='COMPLETE',detail)
            assert(#other.objects==0 and square.objects[1]==target,'base furniture must be untouched')
            assert(#picked==3 and detail:find('2 plank'),detail)
        ''')

    def test_salvage_never_touches_base_safehouses_outdoors_or_the_buffer(self):
        self._salvage_fixture()
        self.lua.execute('''
            -- Only the base's own furniture nearby: nothing to salvage.
            assert(Dismantle.prepare(body,owner,{salvage=true})==nil)
            -- Inside the base buffer (6 tiles from the saved base).
            room(4,0)
            assert(Dismantle.prepare(body,owner,{salvage=true})==nil)
            -- Outdoors (no room): not an indoor furnishing.
            room(12,0,{outdoors=true})
            assert(Dismantle.prepare(body,owner,{salvage=true})==nil)
            -- A claimed safehouse, even one the owner may enter.
            local claimed=room(14,0)
            SafeHouse={getSafeHouse=function(sq) if sq==claimed then return {} end end}
            assert(Dismantle.prepare(body,owner,{salvage=true})==nil)
            -- Owner offline: no salvage at all.
            SafeHouse=nil
            function getOnlinePlayers() return list({}) end
            assert(Dismantle.prepare(body,owner,{salvage=true})==nil)
            assert(scrapCalls==nil)
        ''')

    def test_salvage_stops_if_the_building_becomes_protected(self):
        self._salvage_fixture()
        self.lua.execute('''
            local other=room(10,0)
            local payload=assert(Dismantle.prepare(body,owner,{salvage=true}))
            SafeHouse={getSafeHouse=function(sq) if sq==other then return {} end end}
            local done,success,detail,code=Dismantle.update(body,payload,{},1000)
            assert(done and not success and code=='TARGET_CHANGED' and scrapCalls==nil)
            SafeHouse=nil
        ''')

    def test_unload_after_native_call_is_uncertain_not_success(self):
        self.lua.execute('''
            local payload=assert(Dismantle.prepare(body,owner,{explicit_owner_order=true}))
            function target.props:scrapObject()
                scrapCalls=(scrapCalls or 0)+1
                squares['0:0:0']=nil
            end
            local done,success,detail,code=Dismantle.update(body,payload,{},1000)
            assert(done and not success and code=='ENGINE_ERROR')
            assert(detail:find('uncertain') and scrapCalls==1 and square.objects[1]==target)
        ''')


if __name__ == '__main__':
    unittest.main()


class SalvageIntentTests(unittest.TestCase):
    def test_qwen_can_ask_for_salvage_but_nothing_else(self):
        from goblin_zomboid.validator import IntentValidator, IntentError
        from goblin_zomboid.qwen import QwenClient
        valid = IntentValidator().validate({"intent": "DISMANTLE", "mode": "SAFE", "job": "salvage"})
        self.assertEqual(valid.data["job"], "salvage")
        with self.assertRaises(IntentError):
            IntentValidator().validate({"intent": "DISMANTLE", "mode": "SAFE", "job": "the whole house"})
        schema = QwenClient._chat_schema({"mode": "SAFE"})
        self.assertIn('"salvage"', __import__("json").dumps(schema))

    def test_brain_maps_salvage_job_to_salvage_payload(self):
        source = (LUA / "server/GoblinSurvivor/GoblinBrain.lua").read_text()
        self.assertIn('if action == T.DISMANTLE and job == "salvage" then payload.salvage = true', source)
        autonomy = (LUA / "server/GoblinSurvivor/GoblinAutonomy.lua").read_text()
        self.assertIn('Brain.setTask(body,"DISMANTLE",{salvage=true,autonomous=true})', autonomy)

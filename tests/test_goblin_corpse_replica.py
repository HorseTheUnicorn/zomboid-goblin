"""Client native grapple replay fixtures; no claim of in-engine replication."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / 'mod/Contents/mods/GoblinSurvivor/42/media/lua/shared'


class CorpseReplicaTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().lua_path = (LUA / '?.lua').as_posix()
        self.lua.execute('package.path=lua_path..";"..package.path')
        self.lua.execute('''
            print=function() end
            isClient=function() return true end
            function actor(id,outfit)
                local a={id=id,outfit=outfit,grappleOnly=true,dead=false,accepts=0,resets=0}
                function a:getOnlineID() return self.id end
                function a:getPersistentOutfitID() return self.outfit end
                function a:isReanimatedForGrappleOnly() return self.grappleOnly end
                function a:isDead() return self.dead end
                function a:getGrappledBy() return self.parent end
                function a:isBeingGrappled() return self.parent~=nil end
                function a:getGrapplingTarget() return self.target end
                function a:AcceptGrapple(target,kind)
                    if self.reject then error('native rejected') end
                    self.target=target;self.accepts=self.accepts+1;self.kind=kind
                end
                function a:Grappled(body,weapon,effectiveness,kind)
                    assert(effectiveness==1)
                    self.parent=body;self.kind=kind;body:AcceptGrapple(self,kind)
                end
                function a:GrapplerLetGo(body,reason)
                    assert(reason=='ServerReleased')
                    assert(self.parent==body)
                    self.parent=nil;self.resets=self.resets+1;self.dead=true
                end
                function a:LetGoOfGrappled(reason)
                    local held=self.target;self.target=nil;self.resets=self.resets+1
                    held:GrapplerLetGo(self,reason)
                end
                -- Actual Kahlua cannot index the returned Java helper object.
                function a:getWrappedGrappleable() error('not a Lua-exposed class') end
                return a
            end
            body=actor(1,22);target=actor(78,123);zombies={body,target}
            function getCell() return {getZombieList=function()
                return {size=function() return #zombies end,get=function(_,i) return zombies[i+1] end}
            end} end
            state={task='MOVE_CORPSE',body_present=true,
                corpse_drag={id=78,outfit=123,expires=6000,kind='BwdDragHead'}}
            Replica=require('GoblinSurvivor/GoblinCorpseReplica')
        ''')

    def test_server_confirmed_native_pair_binds_once(self):
        self.lua.execute('''
            assert(Replica.apply(body,state,true,1000))
            assert(body.target==target and target.parent==body)
            assert(Replica.apply(body,state,true,2000) and body.accepts==1)
            assert(not Replica.apply(body,nil,false,3000))
            assert(not body.target and not target.parent)
            assert(body.resets==1 and target.resets==1 and target.dead)
        ''')

    def test_unconfirmed_expired_malformed_or_server_state_never_binds(self):
        self.lua.execute('''
            assert(not Replica.apply(body,state,false,1000))
            assert(not Replica.apply(body,state,true,6000))
            for _,kind in ipairs({'BwdDragAnything','', 'EatBody'}) do
                state.corpse_drag.kind=kind;assert(not Replica.apply(body,state,true,1000))
            end
            state.corpse_drag.kind='BwdDragHead';state.corpse_drag.id=-1
            assert(not Replica.apply(body,state,true,1000))
            state.corpse_drag.id=78;state.task='FOLLOW'
            assert(not Replica.apply(body,state,true,1000))
            state.task='MOVE_CORPSE';isClient=function() return false end
            assert(not Replica.apply(body,state,true,1000) and body.accepts==0)
        ''')

    def test_reused_identity_ordinary_zombie_and_dead_target_are_rejected(self):
        self.lua.execute('''
            target.outfit=456;assert(not Replica.apply(body,state,true,1000))
            target.outfit=123;target.grappleOnly=false
            assert(not Replica.apply(body,state,true,1000))
            target.grappleOnly=true;target.dead=true
            assert(not Replica.apply(body,state,true,1000) and body.accepts==0)
        ''')

    def test_hat_state_does_not_invalidate_identity(self):
        self.lua.execute('''
            target.outfit=123+32768
            assert(Replica.apply(body,state,true,1000))
        ''')

    def test_other_native_pair_is_never_stolen_or_cleared(self):
        self.lua.execute('''
            local stranger=actor(2,24)
            target.parent=stranger
            assert(not Replica.apply(body,state,true,1000))
            target.parent=nil;body.target=stranger
            assert(not Replica.apply(body,state,true,1000))
            assert(body.accepts==0 and body.resets==0 and target.resets==0)
            body.target=nil;assert(Replica.apply(body,state,true,1000))
            body.target=stranger;target.parent=stranger
            Replica.apply(body,nil,false,1000)
            assert(body.target==stranger and target.parent==stranger)
            assert(body.resets==0 and target.resets==0)
        ''')

    def test_failed_second_half_rolls_back_only_adapter_pair(self):
        self.lua.execute('''
            body.reject=true
            assert(not Replica.apply(body,state,true,1000))
            assert(not target.parent and not body.target and not Replica.bound[body])
            assert(target.resets==1 and target.dead)
        ''')

    def test_creation_packet_can_arrive_after_roster(self):
        self.lua.execute('''
            zombies={body};assert(not Replica.apply(body,state,true,1000))
            zombies={body,target};assert(Replica.apply(body,state,true,1100))
        ''')

    def test_native_initial_pickup_type_is_supported(self):
        self.lua.execute('''
            state.corpse_drag.kind='BwdDrag'
            assert(Replica.apply(body,state,true,1000))
            assert(body.kind=='BwdDrag' and target.kind=='BwdDrag')
        ''')


if __name__ == '__main__':
    unittest.main()

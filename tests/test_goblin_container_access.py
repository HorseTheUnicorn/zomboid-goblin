"""Real Lua adapter with mocked engine boundaries; live acceptance is separate."""
import unittest
from tests import test_goblin_work as fixtures


class ContainerAccessTests(unittest.TestCase):
    def setUp(self):
        fixture=fixtures.CompanionWorkTests();fixture.setUp();self.lua=fixture.lua
        self.lua.execute('''
            AccessJob=require('GoblinSurvivor/GoblinGainAccess')
            nativeLocked=false
            sq=cell:getGridSquare(4,0,0);storage=container({item('Base.Nails')})
            target={metadata={}}
            function target:getContainer() return storage end
            function target:getSquare() return sq end
            function target:getObjectIndex() return 0 end
            function target:getModData() return self.metadata end
            function target:transmitModData() end
            function target:isLockedToCharacter(actor) assert(actor==a);return nativeLocked end
            sq.objects={target};player.x=0.5;player.y=0.5
        ''')

    def test_walks_before_completion_and_does_not_transfer_or_unlock(self):
        self.lua.execute('''
            local p=assert(AccessJob.prepare(a,player,{target={kind='CONTAINER'}}))
            assert(p.access_method=='CONTAINER' and type(p.container_id)=='string')
            local runtime={}
            local done,ok,detail,code=AccessJob.update(a,p,runtime,clock)
            assert(not done and ok and code=='MOVING_TO_TARGET' and a.pathCalls>0)
            assert(#storage.items==1 and #a.inv.items==0)
            a.x=3.5
            done,ok,detail,code=AccessJob.update(a,p,runtime,clock+1000)
            assert(done and ok and code=='COMPLETE')
            assert(#storage.items==1 and #a.inv.items==0)
        ''')

    def test_relock_and_replacement_are_rechecked(self):
        self.lua.execute('''
            local p=assert(AccessJob.prepare(a,player,{target={kind='CONTAINER'}}))
            nativeLocked=true
            local done,ok,detail,code=AccessJob.update(a,p,{},clock)
            assert(done and not ok and code=='LOCKED')
            nativeLocked=false;target.metadata={}
            done,ok,detail,code=AccessJob.update(a,p,{},clock)
            assert(done and not ok and code=='TARGET_CHANGED')
            assert(#storage.items==1)
        ''')

    def test_locked_or_distant_target_is_not_selected(self):
        self.lua.execute('''
            nativeLocked=true
            assert(not AccessJob.prepare(a,player,{target={kind='CONTAINER'}}))
            nativeLocked=false;player.x=-2
            assert(not AccessJob.prepare(a,player,{target={kind='CONTAINER'}}))
            assert(target.metadata.GoblinAccessContainerID==nil)
        ''')

    def test_policy_revocation_and_timeout_do_not_report_success(self):
        self.lua.execute('''
            local p=assert(AccessJob.prepare(a,player,{target={kind='CONTAINER'}}))
            SafeHouse={getSafeHouse=function() return {playerAllowed=function() return false end} end}
            local done,ok,detail,code=AccessJob.update(a,p,{},clock)
            assert(done and not ok and code=='PERMISSION_DENIED')
            SafeHouse=nil
            local runtime={};AccessJob.update(a,p,runtime,clock)
            done,ok,detail,code=AccessJob.update(a,p,runtime,clock+46000)
            assert(done and not ok and code=='NO_PATH' and #storage.items==1)
        ''')

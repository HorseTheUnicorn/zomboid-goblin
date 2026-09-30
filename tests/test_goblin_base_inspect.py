"""Fixture checks for the bounded, read-only base survey (not engine/MP proof)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class BaseInspectTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / scope / "?.lua").as_posix()
            for scope in ("shared", "server", "client")
        )
        self.lua.execute('package.path=paths..";"..package.path')
        for filename in ("goblin_fixture.lua", "work_fixture.lua"):
            self.lua.execute((ROOT / "tests/lua" / filename).read_text())
        self.lua.execute('''
            Inspect=require('GoblinSurvivor/GoblinBaseInspect')
            building={}
            room={x=0,y=0,z=0}
            function room:getX() return self.x end
            function room:getY() return self.y end
            function room:getX2() return self.x end
            function room:getY2() return self.y end
            function room:getZ() return self.z end
            function room:getBuilding() return building end
            function building:getRooms() return list({room}) end
            function building:isFullyStreamedIn() return true end
            isoRoom={getRoomDef=function() return room end,
                isInside=function() return true end}
            local original=cell.getGridSquare
            function cell:getGridSquare(x,y,z)
                if unloaded and unloaded[x..':'..y..':'..z] then return nil end
                local sq=original(self,x,y,z)
                if not sq.getRoom then function sq:getRoom() return isoRoom end end
                function sq:getMovingObjects() return list(self.moving or {}) end
                return sq
            end
            scope=assert(require('GoblinSurvivor/GoblinCurtains').scopeAt({x=0,y=0,z=0}))
        ''')

    def test_reports_actual_categories_without_mutating_objects(self):
        self.lua.execute('''
            local sq=cell:getGridSquare(0,0,0)
            local win={kind='IsoWindow',isSmashed=function() return true end,
                isExterior=function() return true end,isBarricaded=function() return false end}
            local door={kind='IsoDoor',isExterior=function() return true end,
                IsOpen=function() return true end,getHealth=function() return 50 end,
                getMaxHealth=function() return 100 end}
            local box={getContainer=function() return {
                getCapacity=function() return 100 end,
                getContentsWeight=function() return 90 end} end}
            local generator={kind='IsoGenerator',isActivated=function() return true end,
                getFuel=function() return 40 end,getCondition=function() return 80 end}
            sq.objects={win,door,box,generator}
            sq.moving={{kind='IsoZombie',data={}}}
            report=assert(Inspect.scan(scope,a,clock))
            assert(report.unbarricaded_windows==1 and report.broken_windows==1)
            assert(report.open_exterior_doors==1 and report.damaged_structures==1)
            assert(report.storage_nearly_full==1 and report.nearby_threats==1)
            assert(report.generator_status[1].fuel==40)
            assert(report.missing_supplies.status=='NOT_CONFIGURED')
            assert(report.squares_scanned==9 and not report.partial)
            assert(door:getHealth()==50 and #sq.objects==4)
        ''')

    def test_unloaded_squares_are_partial_not_clear(self):
        self.lua.execute('''
            unloaded={['1:0:0']=true}
            local report=assert(Inspect.scan(scope,a,clock))
            assert(report.partial and report.squares_unloaded==1)
            assert(report.squares_scanned==8)
            assert(report.generator_status.status=='UNKNOWN')
        ''')

    def test_other_players_safehouse_is_not_inspected(self):
        self.lua.execute('''
            SafeHouse={getSafeHouse=function(square)
                return {playerAllowed=function(self,owner) return false end}
            end}
            local payload,why=Inspect.prepare(a,player)
            assert(payload==nil and why:find('safehouse'))
            local report=assert(Inspect.scan(scope,a,clock))
            assert(report.partial and report.squares_inaccessible==9)
            assert(report.squares_scanned==0 and #report.findings==0)
        ''')

    def test_neighboring_building_is_excluded(self):
        self.lua.execute('''
            local sq=cell:getGridSquare(1,0,0)
            function sq:getRoom()
                return {getRoomDef=function()
                    return {getBuilding=function() return {} end}
                end}
            end
            sq.objects={{kind='IsoWindow',isSmashed=function() return true end,
                isExterior=function() return true end,isBarricaded=function() return false end}}
            local report=assert(Inspect.scan(scope,a,clock))
            assert(report.squares_outside_building==1)
            assert(report.broken_windows==0 and report.squares_scanned==8)
        ''')

    def test_fortification_selects_far_window_in_saved_house_not_neighbor(self):
        self.lua.execute('''
            room.x2=20
            function room:getX2() return self.x2 end
            local neighbor=cell:getGridSquare(1,0,0)
            function neighbor:getRoom()
                return {getRoomDef=function()
                    return {getBuilding=function() return {} end}
                end}
            end
            local wrong=window(neighbor)
            local correct=window(cell:getGridSquare(20,0,0))
            Work.update(a,'FORTIFY',{},clock)
            assert(Work.jobs[a].target==correct)
            assert(Work.jobs[a].target~=wrong)
            assert(Work.jobs[a].scope~=nil)
        ''')

    def test_fortification_refuses_other_players_safehouse(self):
        self.lua.execute('''
            local protected=window(cell:getGridSquare(0,0,0))
            SafeHouse={getSafeHouse=function(square)
                return {playerAllowed=function(self,owner) return false end}
            end}
            local done=Work.update(a,'FORTIFY',{},clock)
            assert(done and protected.barr==nil)
            assert(Work.jobs[a].target==nil)
        ''')

    def test_model_originated_jobs_need_the_owners_consumed_chat_grant(self):
        # Qwen commands reach the game only through GoblinBridge -> Brain.execute.
        # The bridge sets owner_authorized after consuming the owner's one-use
        # chat grant; without it (or for offline/autonomous grants) jobs refuse.
        self.lua.execute('''
            local Brain=require('GoblinSurvivor/GoblinBrain')
            local before=a.data.GoblinTask
            local jobs={'SORT_STORAGE','FETCH_ITEM','DELIVER','REPAIR_STRUCTURE',
                'REFUEL_VEHICLE','INSTALL_PART','REMOVE_PART','REPLACE_PART','CHANGE_TIRE',
                'VEHICLE_SERVICE','VEHICLE_INSPECT','STOCKPILE','DISMANTLE','CHOP_WOOD','TREAT_PLAYER','MOVE_CORPSE'}
            for _,action in ipairs(jobs) do
                local ok,detail=Brain.execute({action=action,item={name='Base.Nails'}},a)
                assert(ok==false and detail:find('own request'),action..' '..tostring(detail))
                ok,detail=Brain.execute({action=action,owner_authorized=true,autonomous=true},a)
                assert(ok==false,action)
                assert(a.data.GoblinTask==before)
            end
            local calls={}
            local original=Brain.setTask
            Brain.setTask=function(body,task,payload) calls[#calls+1]={task=task,payload=payload};return true,'ok' end
            assert(Brain.execute({action='FETCH_ITEM',owner_authorized=true,item={name='food',count=3}},a))
            assert(calls[1].task=='FETCH_ITEM' and calls[1].payload.explicit_owner_order)
            assert(calls[1].payload.item=='food' and calls[1].payload.count==3)
            assert(Brain.execute({action='REPLACE_PART',owner_authorized=true,job='battery'},a))
            assert(calls[2].payload.part=='battery')
            assert(Brain.execute({action='SORT_STORAGE',owner_authorized=true,job='all'},a))
            assert(calls[3].payload.all==true)
            assert(Brain.execute({action='DELIVER',owner_authorized=true,job='floor'},a))
            assert(calls[4].payload.allow_floor==true)
            assert(Brain.execute({action='CHOP_WOOD',owner_authorized=true,item={count=2}},a))
            assert(calls[5].payload.count==2)
            assert(Brain.execute({action='MOVE_CORPSE',owner_authorized=true},a))
            assert(calls[6].task=='MOVE_CORPSE' and calls[6].payload.explicit_owner_order)
            Brain.setTask=original
        ''')

    def test_fortify_base_uses_existing_real_material_path(self):
        self.lua.execute('''
            local Brain=require('GoblinSurvivor/GoblinBrain')
            local target=window(cell:getGridSquare(1,0,0))
            supplies(1,2)
            assert(Brain.setTask(a,'FORTIFY_BASE',{}))
            assert(a.data.GoblinTask=='FORTIFY_BASE')
            Brain.update(a,clock)
            Brain.update(a,clock+5000)
            assert(target.barr and target.barr:getNumPlanks()==1)
            assert(#a.inv.items==1)
        ''')

    def test_fortification_refunds_if_exact_window_changes_before_mutation(self):
        self.lua.execute('''
            local square=cell:getGridSquare(1,0,0)
            local target=window(square)
            supplies(1,2)
            local original=World.reserve
            World.reserve=function(body,selected)
                local ok=original(body,selected)
                square.objects={}
                return ok
            end
            Work.update(a,'FORTIFY_BASE',{},clock)
            Work.update(a,'FORTIFY_BASE',{},clock+5000)
            assert(target.barr==nil and #a.inv.items==4)
            assert(Work.jobs[a].skipped[target]==true)
            World.reserve=original
        ''')

    def test_unloaded_house_tiles_do_not_produce_all_clear_fortify_claim(self):
        self.lua.execute('''
            unloaded={['1:0:0']=true}
            local done=Work.update(a,'FORTIFY_BASE',{},clock)
            assert(done)
            assert(Work.jobs[a].partial==true)
            assert(a.data.GoblinWorkStatus:find('unverified'))
        ''')

    def test_maintenance_inspects_then_uses_material_backed_window_child(self):
        self.lua.execute('''
            local Maintain=require('GoblinSurvivor/GoblinBaseMaintain')
            local target=window(cell:getGridSquare(1,0,0))
            function target:isExterior() return true end
            function target:isBarricaded() return self.barr~=nil end
            function target:isSmashed() return false end
            supplies(4,8)
            local payload=assert(Maintain.prepare(a,player))
            local original=World.approach
            World.approach=function() return true end
            local job={}
            local done=Maintain.update(a,payload,job,clock)
            assert(done==false and target.barr==nil)
            done=Maintain.update(a,payload,job,clock+1500)
            assert(done==false and job.phase=='FORTIFY_WINDOWS')
            local success,detail,code
            for n=1,20 do
                done,success,detail,code=Maintain.update(a,payload,job,clock+1500+n*5000)
                if done then break end
            end
            assert(done and not success and code=='UNSUPPORTED')
            assert(target.barr:getNumPlanks()==4 and #a.inv.items==1)
            assert(a.data.GoblinBaseReport.unbarricaded_windows==0)
            assert(detail:find('4 windows boarded')==nil)
            assert(detail:find('1 windows boarded'))
            World.approach=original
        ''')

    def test_maintenance_without_supported_defect_reports_partial_not_success(self):
        self.lua.execute('''
            local Maintain=require('GoblinSurvivor/GoblinBaseMaintain')
            local payload=assert(Maintain.prepare(a,player))
            local original=World.approach
            World.approach=function() return true end
            local job={}
            Maintain.update(a,payload,job,clock)
            local done,success,detail,code=Maintain.update(a,payload,job,clock+1500)
            assert(done and success==false and code=='UNSUPPORTED')
            assert(detail:find('other maintenance remains unimplemented'))
            World.approach=original
        ''')

    def test_saved_base_required_and_huge_scope_refused(self):
        self.lua.execute('''
            a.data.GoblinBaseSet=false
            local payload,why=Inspect.prepare(a,player)
            assert(payload==nil and why:find('set a base'))
            a.data.GoblinBaseSet=true
            payload=assert(Inspect.prepare(a,player))
            assert(payload.building_id==scope.id and payload.anchor.x==0)
            local huge={id='huge',rooms={{x=0,y=0,x2=100,y2=100,z=0}}}
            local report,reason,code=Inspect.scan(huge,a,clock)
            assert(report==nil and code=='UNSUPPORTED')
        ''')

    def test_partial_inspection_uses_standard_failure_code_but_keeps_report(self):
        self.lua.execute('''
            unloaded={['1:0:0']=true}
            local oldApproach=World.approach
            World.approach=function() return true end
            local payload=assert(Inspect.prepare(a,player))
            local runtime={}
            Inspect.update(a,payload,runtime,clock)
            local done,success,detail,code=Inspect.update(a,payload,runtime,clock+1500)
            assert(done and not success and code=='TARGET_UNLOADED')
            assert(a.data.GoblinBaseReport.partial and a.data.GoblinBaseReport.squares_unloaded==1)
            World.approach=oldApproach
        ''')

    def test_maintenance_missing_material_uses_standard_code(self):
        self.lua.execute('''
            local Maintain=require('GoblinSurvivor/GoblinBaseMaintain')
            local target=window(cell:getGridSquare(1,0,0))
            function target:isExterior() return true end
            function target:isBarricaded() return self.barr~=nil end
            local oldApproach=World.approach
            World.approach=function() return true end
            local payload=assert(Maintain.prepare(a,player))
            local runtime={}
            Maintain.update(a,payload,runtime,clock)
            Maintain.update(a,payload,runtime,clock+1500)
            local done,success,detail,code=Maintain.update(a,payload,runtime,clock+3000)
            assert(not done)
            done,success,detail,code=Maintain.update(a,payload,runtime,clock+94000)
            assert(done and not success and code=='MISSING_MATERIAL')
            assert(target.barr==nil and detail:find('missing materials'))
            World.approach=oldApproach
        ''')

    def test_authorized_job_persists_report_only_after_work_delay(self):
        self.lua.execute('''
            local payload=assert(Inspect.prepare(a,player))
            local oldApproach=World.approach
            World.approach=function() return true end
            local runtime={}
            local done=Inspect.update(a,payload,runtime,clock)
            assert(done==false and a.data.GoblinBaseReport==nil)
            local finished,success,detail,code=Inspect.update(a,payload,runtime,clock+1500)
            assert(finished and success and code=='COMPLETE')
            assert(a.data.GoblinBaseReport.building_id==payload.building_id)
            World.approach=oldApproach
        ''')

    def test_new_survey_marks_old_report_stale_until_replaced(self):
        self.lua.execute('''
            a.data.GoblinBaseReport={building_id='old',stale=false}
            local payload=assert(Inspect.prepare(a,player))
            assert(a.data.GoblinBaseReport.stale==true)
            local oldApproach=World.approach
            World.approach=function() return true end
            local runtime={}
            Inspect.update(a,payload,runtime,clock)
            Inspect.update(a,payload,runtime,clock+1500)
            assert(a.data.GoblinBaseReport.stale==false)
            assert(a.data.GoblinBaseReport.building_id==scope.id)
            World.approach=oldApproach
        ''')

    def test_companion_snapshot_exposes_only_coarse_survey_facts(self):
        self.lua.execute('''
            a.data.GoblinBaseReport={building_id='secret-house',stale=false,
                partial=true,timestamp_ms=clock,squares_scanned=8,
                squares_unloaded=1,unbarricaded_windows=2,
                missing_supplies={status='NOT_CONFIGURED'},
                findings={{x=123,y=456,z=0,category='unbarricaded_windows'}}}
            a.data.goblin_owned=true
            package.loaded['GoblinSurvivor/GoblinBody']=nil
            local realBody=require('GoblinSurvivor/GoblinBody')
            local snapshot=assert(realBody.snapshot(a))
            assert(snapshot.base_report.unbarricaded_windows==2)
            assert(snapshot.base_report.partial==true)
            assert(snapshot.base_report.building_id==nil)
            assert(snapshot.base_report.findings==nil)
            assert(snapshot.base_report.x==nil and snapshot.base_report.y==nil)
        ''')


if __name__ == "__main__":
    unittest.main()

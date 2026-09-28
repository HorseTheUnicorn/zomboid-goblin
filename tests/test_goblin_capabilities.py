from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class CapabilityRegistryTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix()
            for side in ("shared", "server", "client")
        )
        self.lua.execute('package.path=paths..";"..package.path')
        for filename in ("goblin_fixture.lua", "work_fixture.lua", "jobs_fixture.lua"):
            self.lua.execute((ROOT / "tests/lua" / filename).read_text())

    def test_existing_jobs_are_registered_with_policy_and_requirements(self):
        self.lua.execute('''
            local Jobs=require('GoblinSurvivor/GoblinJobs')
            local registry=Jobs.registry()
            assert(#registry==26)
            local seen={}
            for _,entry in ipairs(registry) do
                seen[entry.name]=entry
                assert(entry.owner_required and not entry.offline_allowed)
                assert(entry.timeout_ms==300000 or entry.timeout_ms==600000 or entry.timeout_ms==960000)
            end
            assert(seen.SORT_STORAGE.timeout_ms==600000 and not seen.SORT_STORAGE.destructive)
            assert(not seen.FETCH_ITEM.destructive and not seen.DELIVER.destructive)
            assert(seen.REPAIR_STRUCTURE.destructive and seen.REPAIR_STRUCTURE.timeout_ms==600000)
            assert(not seen.VEHICLE_INSPECT.destructive and seen.REFUEL_VEHICLE.destructive)
            for _,name in ipairs({'INSTALL_PART','REMOVE_PART','REPLACE_PART','CHANGE_TIRE','VEHICLE_SERVICE'}) do
                assert(seen[name] and seen[name].destructive and seen[name].owner_required)
            end
            assert(seen.FARM.destructive and seen.CRAFT.destructive)
            assert(seen.REPAIR_VEHICLE.destructive and not seen.CLOSE_CURTAINS.destructive)
            assert(seen.GAIN_ACCESS.destructive and seen.GAIN_ACCESS.owner_required)
            assert(seen.RESTORE_POWER and not seen.RESTORE_POWER.destructive and seen.RESTORE_POWER.owner_required)
            assert(not seen.INSPECT_BASE.destructive)
            assert(seen.MAINTAIN_BASE.destructive and seen.DISMANTLE.destructive)
            assert(seen.STOCKPILE.destructive and seen.STOCKPILE.owner_required)
            local farm=Jobs.requirements('FARM',{})
            assert(farm.reusable_tools[1]=='Base.HandShovel')
            assert(Jobs.requirements('NOT_REAL',{})==nil)
        ''')

    def test_persisted_payload_boundary_rejects_functions_cycles_and_nonfinite_numbers(self):
        self.lua.execute('''
            local Cap=require('GoblinSurvivor/GoblinCapabilities')
            assert(Cap.serializable({name='job',point={x=1,y=2,z=0}}))
            assert(not Cap.serializable({callback=function() end}))
            local cyclic={};cyclic.self=cyclic;assert(not Cap.serializable(cyclic))
            assert(not Cap.serializable({value=0/0}))
            Cap.register('BAD_PAYLOAD',{destructive=false,offline_allowed=false,owner_required=false,
                prepare=function() return {engine=function() end},'bad' end,
                update=function() return Cap.result(true,true,'COMPLETE','done',1) end})
            local payload,detail=Cap.prepare('BAD_PAYLOAD',a,nil,{})
            assert(payload==nil and detail:find('non%-serializable'))
        ''')

    def test_structured_results_are_strict_and_engine_exceptions_fail_closed(self):
        self.lua.execute('''
            local Cap=require('GoblinSurvivor/GoblinCapabilities')
            assert(not pcall(Cap.result,true,false,'MADE_UP','bad',0))
            assert(not pcall(Cap.result,true,true,'WORKING','bad',1))
            assert(not pcall(Cap.result,false,true,'WORKING','bad',2))
            Cap.register('EXPLODE',{destructive=true,offline_allowed=false,owner_required=false,
                prepare=function() return {anchor={x=0,y=0,z=0}},'ready' end,
                update=function() error('native partial failure') end})
            local result=Cap.update('EXPLODE',a,{anchor={x=0,y=0,z=0}},clock)
            assert(result.done and not result.success and result.code=='ENGINE_ERROR')
            assert(result.progress==0 and #result.detail>0)
        ''')

    def test_terminal_results_do_not_repeat_physical_handlers_until_cleared(self):
        self.lua.execute('''
            local Cap=require('GoblinSurvivor/GoblinCapabilities')
            for _,mode in ipairs({'COMPLETE','ENGINE_ERROR','INVALID'}) do
                local calls=0
                local name='TERMINAL_'..mode
                Cap.register(name,{destructive=true,offline_allowed=false,owner_required=false,
                    prepare=function() return {},'ready' end,
                    update=function()
                        calls=calls+1 -- stands for the physical side effect
                        if mode=='ENGINE_ERROR' then error('failed after consumption') end
                        if mode=='INVALID' then return {} end
                        return Cap.result(true,true,'COMPLETE','done',1)
                    end})
                local first=Cap.update(name,a,{},clock)
                assert(first.done)
                local expected=first.code
                first.done=false;first.code='WORKING'
                local second=Cap.update(name,a,{},clock+1)
                assert(second.done and second.code==expected and calls==1)
                Cap.cancel(a)
                Cap.update(name,a,{},clock+2)
                assert(calls==2) -- explicit new job may execute
                Cap.cancel(a)
            end
        ''')

    def test_runtime_objects_stay_out_of_snapshot_and_cancel_is_scoped(self):
        self.lua.execute('''
            local Cap=require('GoblinSurvivor/GoblinCapabilities')
            local cancelled=0
            Cap.register('TEST_JOB',{destructive=false,offline_allowed=true,owner_required=false,
                prepare=function() return {anchor={x=0,y=0,z=0}},'ready' end,
                update=function(body,payload,runtime)
                    runtime.engine_object=function() end
                    runtime.ticks=(runtime.ticks or 0)+1
                    if runtime.ticks==1 then return Cap.result(false,true,'WORKING','moving',0) end
                    return Cap.result(true,true,'COMPLETE','done',1)
                end,
                cancel=function() cancelled=cancelled+1 end,
                snapshot=function(body,runtime) return {ticks=runtime.ticks} end})
            local payload=Cap.prepare('TEST_JOB',a,nil,{})
            assert(payload and Cap.serializable(payload))
            local first=Cap.update('TEST_JOB',a,payload,clock)
            assert(not first.done and first.code=='WORKING')
            local snap=Cap.snapshot(a)
            assert(snap.task=='TEST_JOB' and snap.runtime.ticks==1)
            assert(snap.runtime.engine_object==nil and Cap.serializable(snap))
            local second=Cap.update('TEST_JOB',a,payload,clock+1)
            assert(second.done and second.code=='COMPLETE')
            assert(Cap.cancel(a) and cancelled==1 and Cap.snapshot(a)==nil)
        ''')

    def test_handler_result_extras_and_caller_mutation_cannot_leak_into_snapshot(self):
        self.lua.execute('''
            local Cap=require('GoblinSurvivor/GoblinCapabilities')
            Cap.register('RESULT_BOUNDARY',{destructive=false,offline_allowed=true,
                owner_required=false,prepare=function() return {},'ready' end,
                update=function()
                    return {done=false,success=true,code='WORKING',detail='safe',
                        progress=0,engine_object=function() end}
                end})
            local result=Cap.update('RESULT_BOUNDARY',a,{},clock)
            assert(result.code=='WORKING' and result.engine_object==nil)
            result.detail='caller changed it'
            result.engine_object=function() end
            local snapshot=Cap.snapshot(a)
            assert(snapshot.result.detail=='safe')
            assert(snapshot.result.engine_object==nil)
            assert(Cap.serializable(snapshot))
            snapshot.result.detail='snapshot changed it'
            assert(Cap.snapshot(a).result.detail=='safe')
        ''')

    def test_handler_owned_metadata_payload_and_snapshot_are_copied(self):
        self.lua.execute('''
            local Cap=require('GoblinSurvivor/GoblinCapabilities')
            local requirements={tools={'Base.Saw'}}
            local prepared={anchor={x=3,y=4,z=0}}
            local runtimeExtra={steps={1}}
            Cap.register('COPY_BOUNDARY',{destructive=false,offline_allowed=true,
                owner_required=false,requirements=requirements,
                prepare=function() return prepared,'ready' end,
                update=function() return Cap.result(false,true,'WORKING','moving',0) end,
                snapshot=function() return runtimeExtra end})
            local metadata=Cap.requirements('COPY_BOUNDARY',{})
            metadata.tools[1]='Base.FakeSaw'
            assert(requirements.tools[1]=='Base.Saw')
            assert(Cap.requirements('COPY_BOUNDARY',{}).tools[1]=='Base.Saw')
            local payload=Cap.prepare('COPY_BOUNDARY',a,nil,{})
            payload.anchor.x=99
            assert(prepared.anchor.x==3)
            Cap.update('COPY_BOUNDARY',a,{anchor={x=3,y=4,z=0}},clock)
            local snapshot=Cap.snapshot(a)
            snapshot.runtime.steps[1]=99
            assert(runtimeExtra.steps[1]==1)
            assert(Cap.snapshot(a).runtime.steps[1]==1)
        ''')

    def test_dynamic_requirement_failure_does_not_escape_registry(self):
        self.lua.execute('''
            local Cap=require('GoblinSurvivor/GoblinCapabilities')
            Cap.register('BAD_REQUIREMENTS',{destructive=false,offline_allowed=true,
                owner_required=false,requirements=function() error('handler failed') end,
                prepare=function() return {},'ready' end,
                update=function() return Cap.result(true,true,'COMPLETE','done',1) end})
            local ok,result=pcall(Cap.requirements,'BAD_REQUIREMENTS',{})
            assert(ok and result==nil)
        ''')

    def test_jobs_persist_only_the_structured_result_for_external_reasoning(self):
        self.lua.execute('''
            local Jobs=require('GoblinSurvivor/GoblinJobs')
            local payload={anchor={x=0,y=0,z=0}}
            local result=Jobs.update(a,'NOT_REAL',payload,clock)
            assert(result.done and not result.success and result.code=='UNSUPPORTED')
            assert(a.data.GoblinLastJobResult.task=='NOT_REAL')
            assert(a.data.GoblinLastJobResult.code=='UNSUPPORTED')
            assert(a.data.GoblinLastJobResult.detail==result.detail)
            assert(type(a.data.GoblinLastJobResult.progress)=='number')
        ''')

    def test_missing_native_recipe_input_is_an_explicit_waiting_result(self):
        self.lua.execute('''
            local Jobs=require('GoblinSurvivor/GoblinJobs')
            local payload=Jobs.prepare(a,player,'CRAFT',{item={name='SawLogs',count=1}})
            assert(payload)
            local result=Jobs.update(a,'CRAFT',payload,clock)
            assert(not result.done and result.success)
            assert(result.code=='WAITING_FOR_MATERIAL')
            assert(result.detail:find('materials'))
            assert(a.data.GoblinLastJobResult.code=='WAITING_FOR_MATERIAL')
        ''')


if __name__ == "__main__":
    unittest.main()

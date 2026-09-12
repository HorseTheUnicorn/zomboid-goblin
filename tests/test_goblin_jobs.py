from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
LUA=ROOT/'mod/Contents/mods/GoblinSurvivor/42/media/lua'


class ExtendedJobTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths=';'.join((LUA/s/'?.lua').as_posix() for s in ('shared','server','client'))
        self.lua.execute('package.path=paths..";"..package.path')
        for filename in ('goblin_fixture.lua','work_fixture.lua','jobs_fixture.lua'):
            self.lua.execute((ROOT/'tests/lua'/filename).read_text())

    def test_follow_backs_out_of_chair_neighbor_ring_without_mutating_player(self):
        self.lua.execute('''
            Motion=require('GoblinSurvivor/GoblinLocomotion')
            player.x,player.y=0.95,0.95;a.x,a.y=1.01,1.01
            goal=Motion.followGoal(a,player);assert(goal)
            assert(math.max(math.abs(math.floor(goal.x)),math.abs(math.floor(goal.y)))>=2)
            assert(Motion.distance(goal,Body.position(player))>=3.2)
            a.x,a.y=3.6,0.95
            assert(not Motion.followGoal(a,player))
            a.x,a.y=1.01,1.01
            local original=cell.getGridSquare;cell.getGridSquare=function() return nil end
            assert(not Motion.followGoal(a,player))
            cell.getGridSquare=original
            assert(player.x==0.95 and player.y==0.95)
        ''')

    def test_toolkit_is_idempotent_and_never_grants_materials(self):
        self.lua.execute('''
            assert(Tools.ensureKit(a));local n=#a.inv.items
            assert(n==#Tools.types and Tools.ensureKit(a) and #a.inv.items==n)
            assert(not Tools.ensure(a,'Base.Plank') and not Tools.ensure(a,'Base.EngineParts'))
            ordinary=a.inv:AddItem('Base.Hammer');Tools.ensureKit(a)
            assert(not Tools.reserved(ordinary) and #a.inv.items==n+1)
            assert(not Loot.hasCargo(a))
        ''')

    def test_only_a_native_reusable_tool_slot_can_extend_kit(self):
        self.lua.execute('''
            assert(not Tools.ensure(a,'Base.ModTool'))
            assert(not Tools.ensure(a,'Base.ModTool',input('Base.ModTool',1,false)))
            assert(Tools.ensure(a,'Base.ModTool',input('Base.ModTool',1,true)))
            assert(not Tools.ensure(a,'Base.Log',input('Base.ModTool',1,true)))
        ''')

    def test_multiple_native_reusable_tools_are_supplied_once_and_retained(self):
        self.lua.execute('''
            recipe.inputs={input('Base.Log',1,false),input('Base.ModTool',2,true)}
            player.x,player.y=0.5,0.5;a.inv:AddItem('Base.Log')
            p=Craft.prepare(a,player,{item={name='SawLogs'}});j=job()
            Craft.update(a,p,j,clock)
            assert(World.materials(a,{['Base.ModTool']=2}))
            assert(not Tools.ensure(a,'Base.ModTool',recipe.inputs[2],3))
            assert(not Tools.ensure(a,'Base.Hammer',input('Base.Hammer',1,false)))
            done,ok=Craft.update(a,p,j,clock+6000);assert(done and ok and craftCalls==1)
            n=0;for _,i in ipairs(a.inv.items) do if i:getFullType()=='Base.ModTool' then
                n=n+1;assert(Tools.reserved(i)) end end
            assert(n==2)
        ''')

    def test_curtain_order_walks_then_closes_the_same_real_object_only_once(self):
        self.lua.execute('''
            player.x,player.y=4.5,0.5;c=curtain(4);curtain(5).opened=false
            p=Jobs.prepare(a,player,'CLOSE_CURTAINS',{});assert(p)
            assert(not Jobs.update(a,'CLOSE_CURTAINS',p,clock) and c.calls==0 and a.pathCalls==1)
            a.x=3.5;done,ok=Jobs.update(a,'CLOSE_CURTAINS',p,clock+1000)
            assert(done and ok and not c.opened and c.calls==1 and p.completed==1)
            Jobs.update(a,'CLOSE_CURTAINS',p,clock+2000);assert(c.calls==1)
            assert(not Curtains.prepare(a,player,{}))
        ''')

    def test_curtain_does_not_toggle_closed_replacement_unloaded_or_wrong_floor_targets(self):
        self.lua.execute('''
            player.x,player.y=0.5,0.5;c=curtain(0)
            p=Curtains.prepare(a,player,{});c.opened=false
            done,ok=Curtains.update(a,p,job(),clock);assert(done and ok and c.calls==0)
            c.opened=true;p=Curtains.prepare(a,player,{})
            c.square.objects={};replacement=curtain(0)
            done,ok=Curtains.update(a,p,job(),clock);assert(done and not ok and replacement.calls==0)
            p=Curtains.prepare(a,player,{});a.z=1
            done,ok=Curtains.update(a,p,job(),clock);assert(not done and replacement.calls==0)
            a.z=0;p=Curtains.prepare(a,player,{})
            local original=cell.getGridSquare;cell.getGridSquare=function() return nil end
            done,ok=Curtains.update(a,p,job(),clock);assert(done and not ok and replacement.calls==0)
            cell.getGridSquare=original
            p=Curtains.prepare(a,player,{});Curtains.targets[a]=nil
            done,ok=Curtains.update(a,p,job(),clock);assert(done and not ok)
        ''')

    def test_curtain_bounds_blockage_timeout_and_native_refusal_are_honest(self):
        self.lua.execute('''
            player.x,player.y=0.5,0.5;c=curtain(10);curtain(0,0,1)
            assert(not Curtains.prepare(a,player,{}))
            c=curtain(1);c.square.blocked=true;p=Curtains.prepare(a,player,{});assert(p)
            local j=job();done,ok=Curtains.update(a,p,j,clock);assert(not done and c.calls==0)
            done,ok=Curtains.update(a,p,j,clock+45001);assert(done and not ok and c.calls==0)
            c.square.blocked=false
            c.refused=true;p=Curtains.prepare(a,player,{})
            done,ok=Curtains.update(a,p,job(),clock);assert(done and not ok and c.opened and p.completed==0)
        ''')

    def test_farming_consumes_one_seed_and_changes_real_plot_once(self):
        self.lua.execute('''
            plant=makePlant(1,'plow');a.inv:AddItem('Base.CabbageSeed');j=job();p=farmPayload('sow')
            assert(not Farm.update(a,p,j,clock) and plant.state=='plow')
            Farm.update(a,p,j,clock+3001)
            assert(plant.state=='seeded' and plant.seeded==1)
            assert(not World.materials(a,{['Base.CabbageSeed']=1}))
            done,ok=Farm.update(a,p,j,clock+4000);assert(done and ok and plant.seeded==1)
        ''')

    def test_missing_seed_does_not_create_crop(self):
        self.lua.execute('''
            plant=makePlant(1,'plow');j=job();p=farmPayload('sow')
            Farm.update(a,p,j,clock);Farm.update(a,p,j,clock+10000)
            assert(plant.state=='plow' and p.completed==0 and a.speech:find('seeds'))
        ''')

    def test_watering_uses_real_water_not_gasoline_and_stops_at_crop_requirement(self):
        self.lua.execute('''
            plant=makePlant(1);plant.waterLvl=70
            water=waterItem(0.2);gas=waterItem(10,'Gasoline');a.inv:AddItem(water)
            assert(Farm.waterUses(gas)==0)
            p=farmPayload('water');j=job()
            Farm.update(a,p,j,clock);Farm.update(a,p,j,clock+3001)
            assert(plant.waterLvl==80 and math.abs(water.fluid.amount-0.1)<0.0001)
            done,ok=Farm.update(a,p,j,clock+7000);assert(done and ok and plant.waterLvl==80)
        ''')

    def test_harvest_revalidates_plot_and_cannot_duplicate(self):
        self.lua.execute('''
            plant=makePlant(1);plant.hasVegetable=true;p=farmPayload('harvest');j=job()
            Farm.update(a,p,j,clock);Farm.update(a,p,j,clock+3001)
            Farm.update(a,p,j,clock+7000)
            assert(harvestCount==1 and World.materials(a,{['Base.Cabbage']=1}))
        ''')

    def test_a_crop_changed_by_another_actor_is_not_harvested_twice(self):
        self.lua.execute('''
            plant=makePlant(1);plant.hasVegetable=true;p=farmPayload('harvest');j=job()
            Farm.update(a,p,j,clock);plant.hasVegetable=false
            Farm.update(a,p,j,clock+4000)
            assert(harvestCount==nil and p.completed==0)
        ''')

    def test_plowing_uses_one_explicit_empty_dirt_tile(self):
        self.lua.execute('''
            player.x,player.y=0.5,0.5;sq=cell:getGridSquare(0,0,0)
            function sq:hasGrave() return false end
            assert(not Farm.prepare(a,player,{job='plow'}))
            sq.dirt=true;p=Farm.prepare(a,player,{job='plow'});assert(p)
            j=job();Farm.update(a,p,j,clock);done,ok=Farm.update(a,p,j,clock+4000)
            assert(done and ok and plants['0:0:0'].state=='plow')
            assert(not Farm.prepare(a,player,{job='plow'}))
        ''')

    def test_crafting_calls_server_adapter_consumes_inputs_and_outputs_real_recipe(self):
        self.lua.execute('''
            player.x,player.y=0.5,0.5;a.inv:AddItem('Base.Log')
            p=Craft.prepare(a,player,{item={name='planks'}});assert(p.recipe=='SawLogs')
            j=job();assert(not Craft.update(a,p,j,clock))
            done,ok=Craft.update(a,p,j,clock+5001)
            assert(done and ok and craftCalls==1 and p.remaining==0)
            assert(World.materials(a,{['Base.Plank']=3}) and not World.materials(a,{['Base.Log']=1}))
            Craft.update(a,p,j,clock+9000);assert(craftCalls==1)
        ''')

    def test_missing_crafting_input_cannot_create_output(self):
        self.lua.execute('''
            p=Craft.prepare(a,player,{item={name='SawLogs'}});j=job()
            Craft.update(a,p,j,clock);Craft.update(a,p,j,clock+20000)
            assert(craftCalls==nil and not World.materials(a,{['Base.Plank']=1}))
        ''')

    def test_crafting_cannot_consume_reserved_tool_or_bypass_workstation(self):
        self.lua.execute('''
            recipe.workstation=true;assert(not Craft.prepare(a,player,{item={name='SawLogs'}}))
            recipe.workstation=false;recipe.inputs={input('Base.Saw',1,false)}
            Tools.ensure(a,'Base.Saw');p=Craft.prepare(a,player,{item={name='SawLogs'}})
            done,ok,why=Craft.update(a,p,job(),clock)
            assert(done and not ok and why:find('equipment') and craftCalls==nil)
        ''')

    def test_repair_requires_parked_empty_vehicle_and_actual_engine_parts(self):
        self.lua.execute('''
            v=vehicle();player.x=0.5
            v.running=true;assert(not Vehicles.prepare(a,player,{}))
            v.running=false;v.passenger=player;assert(not Vehicles.prepare(a,player,{}))
            v.passenger=nil;p=Vehicles.prepare(a,player,{job='engine'});j=job()
            Vehicles.update(a,p,j,clock);assert(v.engine.condition==90)
            a.inv:AddItem('Base.EngineParts')
            Vehicles.update(a,p,j,clock+1000);Vehicles.update(a,p,j,clock+7000)
            assert(v.engine.condition==93 and v.synced==1)
            assert(not World.materials(a,{['Base.EngineParts']=1}))
        ''')

    def test_repair_rechecks_occupancy_before_consumption(self):
        self.lua.execute('''
            v=vehicle();player.x=0.5;p=Vehicles.prepare(a,player,{job='engine'});j=job()
            a.inv:AddItem('Base.EngineParts');Vehicles.update(a,p,j,clock)
            v.passenger=player;done,ok=Vehicles.update(a,p,j,clock+9000)
            assert(done and not ok and v.engine.condition==90 and World.materials(a,{['Base.EngineParts']=1}))
        ''')

    def test_orders_are_owner_scoped_and_cancel_cleanly(self):
        self.lua.execute('''
            assert(not Jobs.prepare(a,nil,'FARM',{job='water'}))
            clientMode=true;assert(not Jobs.prepare(a,player,'FARM',{job='water'}));clientMode=false
            plant=makePlant(1);p=farmPayload('water');Jobs.update(a,'FARM',p,clock)
            assert(Jobs.active[a] and a.data.GoblinJobActive)
            Jobs.clear(a);assert(not Jobs.active[a] and not a.data.GoblinJobActive and a.data.GoblinAction=='')
        ''')

    def test_partial_native_failure_is_terminal_and_timeout_is_bounded(self):
        self.lua.execute('''
            player.x,player.y=0.5,0.5;a.inv:AddItem('Base.Log')
            p=Craft.prepare(a,player,{item={name='SawLogs'}})
            Jobs.update(a,'CRAFT',p,clock)
            goblinServerCraft=function() error('native partial failure') end
            done,ok=Jobs.update(a,'CRAFT',p,clock+6000);assert(done and not ok)
            Jobs.clear(a);p=farmPayload('water');makePlant(1)
            Jobs.update(a,'FARM',p,clock);done,ok=Jobs.update(a,'FARM',p,clock+300001)
            assert(done and not ok)
        ''')

    def test_plain_chat_routes_commands_without_qwen_and_preserves_negation(self):
        self.lua.execute('''
            Chat=require('GoblinSurvivor/ChatBridge')
            assert(Chat.directIntent('goblin, open then door')=='OPEN_DOOR')
            assert(Chat.directIntent('goblin, close the curtains')=='CLOSE_CURTAINS')
            assert(Chat.directIntent('goblin, shut the blinds')=='CLOSE_CURTAINS')
            assert(Chat.directIntent('goblin, draw the curtain')=='CLOSE_CURTAINS')
            assert(not Chat.directIntent('goblin, do not close the curtains'))
            assert(not Chat.directIntent('goblin, how do you close curtains?'))
            assert(not Chat.directIntent('goblin, open the window curtains'))
            assert(Chat.directIntent('goblin, craft 2 SawLogs')=='CRAFT')
            p=Chat.jobPayload('CRAFT','goblin, craft 2 SawLogs');assert(p.item.name=='SawLogs' and p.item.count==2)
            assert(Chat.directIntent('goblin, sow cabbage seeds')=='FARM')
            p=Chat.jobPayload('FARM','goblin, sow cabbage seeds');assert(p.job=='sow' and Farm.crop(p.item.name)=='Cabbages')
            assert(Chat.directIntent('goblin, repair the engine')=='REPAIR_VEHICLE')
            assert(not Chat.directIntent('goblin, do not harvest the crops'))
            assert(not Chat.directIntent('goblin, how do you craft rope?'))
        ''')

    def test_extended_orders_require_one_use_grant_for_the_matching_owner(self):
        self.lua.execute('''
            Authority=require('GoblinSurvivor/Authority')
            for _,action in ipairs({'OPEN_DOOR','OPEN_WINDOW','CLOSE_CURTAINS','FARM','CRAFT','REPAIR_VEHICLE'}) do
                assert(Authority.requires(action))
                local token=Authority.issue(player)
                assert(not Authority.consume({action=action,owner='unicorn',authority_token=token}))
                local message={action=action,owner='horse',authority_token=token}
                assert(Authority.consume(message) and not Authority.consume(message))
            end
        ''')

    def test_open_order_targets_nearest_edge_walks_then_opens_once(self):
        self.lua.execute('''
            Access=require('GoblinSurvivor/GoblinAccess')
            player.x,player.y=4.5,0.5
            near=cell:getGridSquare(4,0,0)
            door={opened=false,calls=0}
            function door:isOpen() return self.opened end
            function door:isLocked() return self.locked==true end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function door:isLockedByKey() return false end
            function door:ToggleDoor(who) self.opened=true;self.calls=self.calls+1 end
            function near:getDoorTo(other) if other:getX()==5 and other:getY()==0 then return door end end
            p=Access.prepare(player,false,clock);assert(p and p.edge.x==4)
            done=Access.perform(a,p,clock);assert(not done and a.pathCalls==1 and door.calls==0)
            a.x=4.5;done,ok=Access.perform(a,p,clock+1000);assert(done and ok and door.calls==1)
            Access.perform(a,p,clock+2000);assert(door.calls==1)
            door.opened=false;door.locked=true
            p,why=Access.prepare(player,false,clock);assert(not p and why:find('locked'))
            done,ok=Access.perform(a,{edge={}},clock);assert(done and not ok)
        ''')

    def test_new_actions_have_strict_model_schemas(self):
        from goblin_zomboid.validator import IntentValidator, IntentError
        from goblin_zomboid.qwen import QwenClient
        validator=IntentValidator()
        for payload in (
            {'intent':'CLOSE_CURTAINS','mode':'PARTY'},
            {'intent':'FARM','mode':'PARTY','job':'sow','item':{'name':'Cabbages'}},
            {'intent':'CRAFT','mode':'PARTY','item':{'name':'SawLogs','count':2}},
            {'intent':'REPAIR_VEHICLE','mode':'PARTY','job':'engine'},
        ):
            self.assertEqual(validator.validate(payload).intent,payload['intent'])
        for payload in (
            {'intent':'FARM','mode':'PARTY','job':'sow'},
            {'intent':'CRAFT','mode':'PARTY'},
            {'intent':'REPAIR_VEHICLE','mode':'PARTY','job':'teleport'},
            {'intent':'CRAFT','mode':'PARTY','item':{'name':'SawLogs','count':11}},
        ):
            with self.assertRaises(IntentError): validator.validate(payload)
        branches={b['properties']['intent']['const'] for b in QwenClient._chat_schema({'mode':'PARTY'})['oneOf']}
        self.assertTrue({'FARM','CRAFT','REPAIR_VEHICLE','OPEN_DOOR','OPEN_WINDOW','CLOSE_CURTAINS'}<=branches)


if __name__=='__main__':
    unittest.main()

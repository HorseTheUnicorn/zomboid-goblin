"""Survival-cycle custody/goal fixtures, not engine or multiplayer evidence."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"

FIXTURE = r'''
config.foodReserveItems=2
goals={}
local Spawner=package.loaded['GoblinSurvivor/GoblinSpawner']
Spawner.goalsForOwner=function() return goals end
Spawner.setGoalsForOwner=function(_,values) goals=values;return true end
events={}
package.loaded['GoblinSurvivor/GoblinSituation']={note=function(_,kind,text)
    events[#events+1]={kind=kind,text=text} end}
Food=require('GoblinSurvivor/GoblinFoodCycle')
Goals=require('GoblinSurvivor/GoblinGoals')
Life=require('GoblinSurvivor/GoblinSurvivalLife')
Deliver=require('GoblinSurvivor/GoblinDeliverWork')
function food(kind,cooked,opts)
    opts=opts or {}
    local f=item(kind,'Food'); f.class='Food'; f.cooked=cooked;f.burnt=false
    function f:getHungerChange() return -0.2 end
    function f:getPoisonPower() return opts.poison or 0 end
    function f:isRotten() return opts.rotten or false end
    function f:isSpice() return opts.spice or false end
    function f:isBurnt() return self.burnt end
    function f:isCookable() return opts.raw or false end
    function f:isCooked() return self.cooked or false end
    function f:isbDangerousUncooked() return opts.raw or false end
    return f
end
destination=furniture(2,2,{})
assignAt(2,2,'FOOD',destination)
body.data.GoblinTask='FOLLOW';body.data.GoblinTaskPayload={owner='horse'}
for x=-20,20 do for y=-20,20 do
    local square=squareAt(x,y,0)
    function square:isOutside() return true end
end end
ZombRand=function(n) return math.floor(n/2)+1 end
forageSystem={itemDefs={['Base.Apple']={}},
    getDefinedZoneAt=function() return {name='Forest'} end,
    pickRandomItemType=function() return 'Base.Apple' end}
instanceItem=function(kind) return food(kind,true) end
handlers={FORAGE=Life.Forage,COOK=Life.Cook,DELIVER=Deliver}
started={}
function setTask(b,task,request)
    if task=='FOLLOW' then
        if b.data.GoblinTask=='COOK' then Life.Cook.clear(b,liveRuntime) end
        b.data.GoblinTask=task;b.data.GoblinTaskPayload=request
        return true
    end
    local payload,why=handlers[task].prepare(b,owner,request)
    if not payload then return false,why end
    payload.goal_id=request.goal_id
    b.data.GoblinTask=task;b.data.GoblinTaskPayload=payload
    liveRuntime={}
    started[#started+1]=task
    return true
end
clock=1000
function step()
    local task=body.data.GoblinTask
    if task=='FOLLOW' then return Goals.tick(body,setTask,{idle=true},clock) end
    local payload=body.data.GoblinTaskPayload
    local done,ok,detail,code=handlers[task].update(body,payload,liveRuntime,clock)
    if stove and payload.phase=='cooking' and not stove.cold then
        for _,v in ipairs(stove.c.items) do v.cooked=true end
    end
    if done then
        Goals.onResult(body,task,{done=true,success=ok,detail=detail,code=code},clock,payload.goal_id,payload)
        setTask(body,'FOLLOW',{owner='horse'})
    end
    return true
end
function cycle()
    assert(Goals.ensureFood(body,clock))
    for i=1,200 do
        clock=clock+1000;step()
        if goals[1].state=='DONE' then return end
    end
    error('cycle did not finish: '..Goals.describe('horse'))
end
function makeStove(cold)
    local s=furniture(3,3,{})
    s.class='IsoStove';s.on=false;s.cold=cold
    function s:Activated() return self.on end
    function s:Toggle() if not self.cold then self.on=not self.on end end
    return s
end
'''


class FoodCycleTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT / "tests/lua/logistics_fixture.lua").read_text())
        self.lua.execute(FIXTURE)

    def test_real_raw_items_are_fetched_cooked_and_stored_without_duplication(self):
        self.lua.execute('''
            local a=food('Base.Steak',false,{raw=true});local b=food('Base.Egg',false,{raw=true})
            local source=furniture(1,1,{a,b});stove=makeStove(false)
            cycle()
            assert(table.concat(started,',')=='COOK,DELIVER')
            assert(#source.c.items==0 and #stove.c.items==0 and not stove.on)
            assert(#body.inv.items==0 and #destination.c.items==2)
            assert(destination.c:contains(a) and destination.c:contains(b) and a.cooked and b.cooked)
            assert(goals[1].last_code=='VERIFIED_FOOD_STORED' and goals[1].food.delivered==2)
            assert(events[#events].kind=='survival' and events[#events].text:find('verified'))
            assert(#sent.add>0 and sent.add[#sent.add].c==destination.c)
        ''')

    def test_no_ingredients_uses_installed_foraging_then_deposits(self):
        self.lua.execute('''
            cycle()
            assert(table.concat(started,',')=='FORAGE,DELIVER')
            assert(count(destination.c,'Base.Apple')==2 and #body.inv.items==0)
            assert(goals[1].state=='DONE' and Food.scan(body).ready==2)
        ''')

    def test_missing_food_storage_prepares_a_crate_but_unreadable_storage_does_not(self):
        self.lua.execute('''
            storageRecords={}
            assert(not Food.scan(body).known and Food.scan(body).reason=='NO_FOOD_STORAGE')
            assert(Goals.ensureFood(body,clock) and #goals==1)
            local task,payload=Food.next(body,goals[1],clock)
            assert(task=='PREPARE_FOOD_STORAGE' and payload.food_cycle)
            goals={}
            assignAt(2,2,'FOOD',destination)
            destination.getContainer=function() return nil end
            assert(not Food.scan(body).known and not Goals.ensureFood(body,clock))
        ''')

    def test_storage_job_cannot_claim_success_without_a_readable_assignment(self):
        self.lua.execute('''
            storageRecords={}
            assert(Goals.ensureFood(body,clock))
            Food.onResult(body,goals[1],'PREPARE_FOOD_STORAGE',
                {success=true,code='COMPLETE'},clock,{})
            assert(goals[1].state=='WAITING' and goals[1].last_code=='TARGET_CHANGED')
        ''')

    def test_only_native_safe_food_counts(self):
        self.lua.execute('''
            destination.c.items={item('Base.Fake','Food'),food('Base.Bad',true,{poison=10}),
                food('Base.Rotten',true,{rotten=true}),food('Base.Salt',true,{spice=true}),
                food('Base.Steak',false,{raw=true}),food('Base.Apple',true)}
            local scan=Food.scan(body)
            assert(scan.known and scan.ready==1 and scan.raw==1 and scan.shortage==1)
            local unknown=food('Base.Unknown',true);unknown.isbDangerousUncooked=nil
            assert(Food.classify(unknown)==nil)
        ''')

    def test_false_complete_without_stored_item_ids_is_rejected(self):
        self.lua.execute('''
            body.inv.items={food('Base.Apple',true)}
            assert(Goals.ensureFood(body,clock));assert(Goals.tick(body,setTask,{idle=true},clock))
            local payload=body.data.GoblinTaskPayload
            payload.ledger[1].state='delivered' -- false result, actor still owns it
            Goals.onResult(body,'DELIVER',{success=true,code='COMPLETE'},clock,payload.goal_id,payload)
            assert(goals[1].state=='WAITING' and goals[1].last_code=='TARGET_CHANGED')
            assert(#body.inv.items==1 and #destination.c.items==0)
        ''')

    def test_full_storage_keeps_cargo_and_does_not_claim_success(self):
        self.lua.execute('''
            destination.c.capacity=0
            assert(Goals.ensureFood(body,clock))
            for i=1,100 do clock=clock+1000;step() end
            assert(goals[1].state=='WAITING' and goals[1].last_code=='BLOCKED')
            assert(#body.inv.items==2 and #destination.c.items==0)
        ''')

    def test_cold_stove_replans_to_ready_forage_instead_of_faking_cooking(self):
        self.lua.execute('''
            local steak=food('Base.Steak',false,{raw=true});body.inv.items={steak};stove=makeStove(true)
            cycle()
            assert(table.concat(started,',')=='COOK,FORAGE,DELIVER')
            assert(not steak.cooked and body.inv:contains(steak))
            assert(Food.scan(body).ready==2 and goals[1].state=='DONE')
        ''')

    def test_poisonous_definitions_and_non_food_rolls_are_bounded(self):
        self.lua.execute('''
            forageSystem.itemDefs['Base.Apple']={poisonChance=10}
            assert(Goals.ensureFood(body,clock))
            for i=1,200 do clock=clock+1000;step() end
            assert(goals[1].state=='WAITING' and goals[1].last_code=='NO_TARGET')
            assert(#body.inv.items==0 and #destination.c.items==0)
        ''')

    def test_restart_rescans_carried_cargo_instead_of_starting_another_forage(self):
        self.lua.execute('''
            assert(Goals.ensureFood(body,clock))
            for i=1,100 do
                clock=clock+1000;step()
                if body.data.GoblinTask=='DELIVER' then break end
            end
            assert(goals[1].state=='ACTIVE' and #body.inv.items==2)
            assert(require('GoblinSurvivor/GoblinCapabilities').serializable(goals))
            -- Persistent primitive goal restored; runtime body flags lost.
            body.data.GoblinGoalActive=nil;body.data.GoblinTask='FOLLOW';body.data.GoblinTaskPayload={}
            liveRuntime={}
            for i=1,100 do clock=clock+1000;step();if goals[1].state=='DONE' then break end end
            assert(table.concat(started,',')=='FORAGE,DELIVER,DELIVER')
            assert(#body.inv.items==0 and #destination.c.items==2 and goals[1].state=='DONE')
        ''')

    def test_owner_movement_and_wait_override_suspend_the_cycle(self):
        self.lua.execute('''
            assert(Goals.ensureFood(body,clock));assert(Goals.tick(body,setTask,{idle=true},clock))
            assert(Goals.tick(body,setTask,{idle=false},clock+1))
            assert(goals[1].state=='WAITING' and body.data.GoblinTask=='FOLLOW')
            body.data.GoblinTask='WAIT';body.data.GoblinTaskPayload={}
            assert(not Goals.tick(body,setTask,{idle=true},clock+600000))
            assert(#started==1)
        ''')

    def test_cancel_prevents_automatic_rearming_and_owner_goals_take_priority(self):
        self.lua.execute('''
            assert(Goals.ensureFood(body,clock));assert(Goals.add('horse','secure',0,clock))
            assert(Goals.select(goals,clock).kind=='SECURE_BASE')
            assert(Goals.cancel('horse','food'))
            assert(not Goals.ensureFood(body,clock+600000) and #goals==2)
            assert(Goals.add('horse','food',0,clock+600001))
            assert(Goals.ensureFood(body,clock+600002) and #goals==2)
        ''')

    def test_survival_busy_does_not_block_qwen_after_autonomy_is_disabled(self):
        self.lua.execute('''
            config.autonomyEnabled=true;config.foodSurvivalEnabled=true;body.data.GoblinFreewillEnabled=true
            assert(Goals.ensureFood(body,clock));assert(Goals.foodBusy(body,clock))
            config.autonomyEnabled=false
            assert(not Goals.foodBusy(body,clock))
        ''')

    def test_restored_running_job_remains_interruptible_and_cancelled_job_stops(self):
        self.lua.execute('''
            assert(Goals.ensureFood(body,clock));assert(Goals.tick(body,setTask,{idle=true},clock))
            body.data.GoblinGoalActive=nil
            assert(Goals.restoreActive(body))
            assert(Goals.tick(body,setTask,{idle=false},clock+1))
            assert(body.data.GoblinTask=='FOLLOW' and goals[1].state=='WAITING')
            assert(Goals.tick(body,setTask,{idle=true},clock+10000))
            assert(Goals.cancel('horse','food'))
            body.data.GoblinGoalActive=nil
            assert(Goals.restoreActive(body))
            Goals.tick(body,setTask,{idle=true},clock+10001)
            assert(body.data.GoblinTask=='FOLLOW' and goals[1].state=='CANCELLED')
        ''')

    def test_already_stocked_base_does_not_start_a_cycle(self):
        self.lua.execute('''
            destination.c.items={food('Base.Apple',true),food('Base.Apple',true)}
            assert(not Goals.ensureFood(body,clock) and #goals==0 and #started==0)
        ''')

    def test_new_owner_goal_preempts_an_active_food_run(self):
        self.lua.execute('''
            assert(Goals.ensureFood(body,clock));assert(Goals.tick(body,setTask,{idle=true},clock))
            assert(Goals.add('horse','secure',0,clock+1))
            assert(Goals.tick(body,setTask,{idle=true},clock+2))
            assert(goals[1].state=='WAITING' and body.data.GoblinTask=='FOLLOW')
            assert(Goals.select(goals,clock+3).kind=='SECURE_BASE')
        ''')

    def test_freewill_off_suspends_automatic_food_work(self):
        self.lua.execute('''
            assert(Goals.ensureFood(body,clock));assert(Goals.tick(body,setTask,{idle=true},clock))
            assert(Goals.tick(body,setTask,{idle=true,food_enabled=false},clock+1))
            assert(goals[1].state=='WAITING' and body.data.GoblinTask=='FOLLOW')
            assert(not Goals.tick(body,setTask,{idle=true,food_enabled=false},clock+600000))
            assert(#started==1)
        ''')

    def test_cook_cancellation_stops_owned_heat_and_recovers_only_tracked_nearby_food(self):
        self.lua.execute('''
            local steak=food('Base.Steak',false,{raw=true});body.inv.items={steak};stove=makeStove(false)
            assert(Goals.ensureFood(body,clock));assert(Goals.tick(body,setTask,{idle=true},clock))
            local payload=body.data.GoblinTaskPayload
            for i=1,10 do
                clock=clock+1000
                Life.Cook.update(body,payload,liveRuntime,clock)
                if payload.phase=='cooking' then break end
            end
            assert(stove.on and stove.c:contains(steak) and not body.inv:contains(steak))
            assert(Goals.tick(body,setTask,{idle=false},clock+1))
            assert(not stove.on and #stove.c.items==0 and body.inv:contains(steak))
        ''')


if __name__ == "__main__":
    unittest.main()

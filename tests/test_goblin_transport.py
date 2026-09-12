from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime
from goblin_zomboid.controllers import Action, BodyState, SafetyController, TacticalController
from goblin_zomboid.validator import INTENTS, IntentValidator

ROOT=Path(__file__).resolve().parents[1]
LUA=ROOT/'mod/Contents/mods/GoblinSurvivor/42/media/lua'

class PassengerTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths=';'.join((LUA/s/'?.lua').as_posix() for s in ('shared','server','client'))
        self.lua.execute('package.path=paths..";"..package.path')
        for file in ('goblin_fixture.lua','work_fixture.lua','passenger_fixture.lua'):
            self.lua.execute((ROOT/'tests/lua'/file).read_text())

    def test_board_requires_approach_and_preserves_driver(self):
        self.lua.execute('''
            v.seats[0]=player;player.vehicle=v
            local p=assert(Transport.prepare(a,player,'ENTER_VEHICLE',clock))
            local done=Transport.board(a,p,clock);assert(not done and not a.vehicle and v.entries==0)
            assert(Movement.snapshot(a).goal)
            local point=Passenger.point(v,p.seat,'outside');a.x=point.x;a.y=point.y
            local finished,ok=Transport.board(a,p,clock+1000)
            assert(finished and ok and a.vehicle==v and v.seats[0]==player and not a.collidable)
            assert(a.data.GoblinRide.seat>0 and not v.doorOpen)
        ''')

    def test_moving_locked_full_missing_and_blocked_vehicles_are_refused(self):
        self.lua.execute('''
            v.speed=10;assert(not Transport.prepare(a,player,'ENTER_VEHICLE',clock));v.speed=0
            for _,field in ipairs({'locked','missing','blocked','cargo'}) do
                v[field]=true;assert(not Transport.prepare(a,player,'ENTER_VEHICLE',clock));v[field]=false
            end
            v.seats[1]=player;v.seats[2]=player;assert(not Transport.prepare(a,player,'ENTER_VEHICLE',clock))
            assert(v.entries==0)
        ''')

    def test_seat_race_reselects_without_overwriting_player(self):
        self.lua.execute('''
            local p=assert(Transport.prepare(a,player,'ENTER_VEHICLE',clock))
            local selected=p.seat;v.seats[selected]=player
            local done=Transport.board(a,p,clock+1);assert(not done and p.seat~=selected)
            local point=Passenger.point(v,p.seat,'outside');a.x=point.x;a.y=point.y
            local finished,ok=Transport.board(a,p,clock+2)
            assert(finished and ok and v.seats[selected]==player)
        ''')

    def test_exit_waits_for_stop_and_clear_space_without_losing_seat(self):
        self.lua.execute('''
            board();v.speed=20
            assert(not Transport.exit(a,clock+1000) and a.vehicle==v)
            v.speed=0;v.exitBlocked=true
            assert(not Transport.exit(a,clock+2000) and a.vehicle==v)
            v.exitBlocked=false
            assert(not Transport.exit(a,clock+3000) and a.data.GoblinRide.phase=='EXIT')
            local done,ok=Transport.exit(a,clock+3800)
            assert(done and ok and not a.vehicle and a.collidable and not a.data.GoblinRide)
            assert(v:getSeat(a)==-1 and a.x==v.x+1 and a.data.GoblinVehicleExit.x==a.x)
        ''')

    def test_follow_auto_boards_and_owner_exit_disembarks(self):
        self.lua.execute('''
            player.vehicle=v;v.seats[0]=player
            assert(Transport.tick(a,player,clock))
            local p=Transport.pending[a];local point=Passenger.point(v,p.seat,'outside');a.x=point.x;a.y=point.y
            assert(Transport.tick(a,player,clock+1000) and a.vehicle==v)
            v.x=20;v.speed=25;Transport.tick(a,player,clock+2000);assert(a.x==20 and a.vehicle==v)
            player.vehicle=nil;v.seats[0]=nil;Transport.tick(a,player,clock+3000);assert(a.vehicle==v)
            v.speed=0;Transport.tick(a,player,clock+4000);Transport.tick(a,player,clock+4800)
            assert(not a.vehicle and a.collidable)
        ''')

    def test_explicit_exit_does_not_immediately_board_again(self):
        self.lua.execute('''
            player.vehicle=v;v.seats[0]=player;board()
            a.data.GoblinTask='EXIT_VEHICLE'
            Transport.tick(a,player,clock+1000);Transport.tick(a,player,clock+1800)
            a.data.GoblinTask='FOLLOW';local entries=v.entries
            assert(not Transport.tick(a,player,clock+2000) and v.entries==entries)
            player.vehicle=nil;Transport.tick(a,player,clock+3000);assert(not a.data.GoblinBoardHold)
        ''')

    def test_wait_aboard_survives_logout_and_follow_exits_when_parked(self):
        self.lua.execute('''
            board();a.data.GoblinTask='WAIT'
            Transport.tick(a,nil,clock+2000);assert(a.vehicle==v)
            a.data.GoblinTask='FOLLOW'
            Transport.tick(a,nil,clock+3000);Transport.tick(a,nil,clock+4000);assert(not a.vehicle)
        ''')

    def test_client_replication_uses_no_player_packets_and_rebinds_after_vanilla_snapshot(self):
        self.lua.execute('''
            board();local state=Transport.snapshot(a)
            Passenger.detach(a);clientMode=true
            assert(Passenger.apply(a,state) and a.vehicle==v)
            v:clearPassenger(state.vehicle_seat);a.vehicle=nil -- vanilla player-only snapshot
            assert(Passenger.apply(a,state) and a.vehicle==v)
            local entries=v.entries
            vehicleUnloaded=true;assert(Passenger.apply(a,state) and v.entries==entries)
            vehicleUnloaded=false
            assert(not Passenger.apply(a,{vehicle_exit={x=4,y=1,z=0}}))
            assert(not a.vehicle and a.x==4 and a.collidable)
        ''')

    def test_client_never_evicts_another_occupant_or_accepts_invalid_seat(self):
        self.lua.execute('''
            clientMode=true
            local s={vehicle_id=7,vehicle_script='Base.TestCar',vehicle_seat=1,vehicle_phase='RIDE'}
            v.seats[1]=player;assert(Passenger.apply(a,s));assert(v.seats[1]==player and not a.vehicle)
            for _,bad in ipairs({0,-1,100,1.5,0/0}) do s.vehicle_seat=bad;assert(Passenger.apply(a,s));end
            assert(v.entries==0)
            s.vehicle_seat=2;s.vehicle_script='Base.WrongCar';assert(Passenger.apply(a,s) and v.entries==0)
        ''')

    def test_owner_authority_and_approach_timeout(self):
        self.lua.execute('''
            local other=actor(0,0,0);function other:getUsername() return 'unicorn' end
            assert(not Transport.prepare(a,other,'ENTER_VEHICLE',clock))
            local p=assert(Transport.prepare(a,player,'ENTER_VEHICLE',clock))
            local done,ok=Transport.board(a,p,clock+46000);assert(done and not ok and not a.vehicle)
        ''')

    def test_moving_hands_are_empty_before_native_window_climb(self):
        self.lua.execute('''
            clientMode=true;a.hand={};a.secondary=a.hand
            function a:getPrimaryHandItem() return self.hand end
            function a:getSecondaryHandItem() return self.secondary end
            function a:setPrimaryHandItem(v) self.hand=v end
            function a:setSecondaryHandItem(v) self.secondary=v end
            function a:pathToLocationF() assert(not self.hand and not self.secondary,'unsafe player drop packet');self.pathCalls=self.pathCalls+1 end
            Motion.drive(a,{x=9,y=0,z=0},'RUN',clock)
            assert(a.pathCalls==1 and not a.hand and not a.secondary)
            a.hand={};a.secondary=a.hand
            function a:getCurrentStateName() return 'ClimbThroughWindowState' end
            require('GoblinSurvivor/GoblinCombatVisual').apply(a,{npc_id='a',generation=1},clock)
            assert(not a.hand and not a.secondary)
        ''')

    def test_vehicle_and_singular_kill_orders_are_direct_but_negations_are_not(self):
        self.lua.execute('''
            local Chat=require('GoblinSurvivor/ChatBridge')
            for _,s in ipairs({'Goblin get in the car','Goblin, enter vehicle','Goblin board the truck'}) do assert(Chat.directIntent(s)=='ENTER_VEHICLE') end
            for _,s in ipairs({'Goblin get out of the car','Goblin exit vehicle','Goblin disembark'}) do assert(Chat.directIntent(s)=='EXIT_VEHICLE') end
            for _,s in ipairs({'Goblin kill that zombie!','Goblin go in and kill the zombie','Goblin attack those zombies'}) do assert(Chat.directIntent(s)=='ATTACK') end
            assert(Chat.directIntent('Goblin, do not kill that zombie')==nil)
            assert(Chat.directIntent('Goblin, how do you enter vehicles?')==nil)
            assert(Chat.directIntent('Goblin board up the window')=='FORTIFY')
        ''')

    def test_missing_build_materials_end_wait_and_explain(self):
        self.lua.execute('''
            local Work=require('GoblinSurvivor/GoblinWork')
            local p={kind='crate',x=0,y=0,z=0}
            assert(not Work.update(a,'BUILD',p,clock))
            assert(Work.update(a,'BUILD',p,clock+91000))
            assert(a.data.GoblinWorkStatus:find('Resuming follow',1,true))
        ''')

class CommandMappingTests(unittest.TestCase):
    def test_all_validated_intents_have_a_controller_mapping(self):
        self.assertEqual(INTENTS-set(TacticalController._mapping),set())

    def test_attack_and_passenger_intents_do_not_crash_or_require_model_coordinates(self):
        body=BodyState(body_present=True,control_ready=True,npc_engine_ready=True,mode='PARTY')
        for action in ('ATTACK','ENTER_VEHICLE','EXIT_VEHICLE'):
            intent=IntentValidator().validate({'intent':action,'mode':'PARTY'})
            result=SafetyController().decide(intent,body)
            self.assertTrue(result.accepted,result.reason)
            self.assertEqual(result.action.action,Action(action))

if __name__=='__main__':
    unittest.main()

"""Execute the real chat dispatcher; downstream spies are not engine proof."""
import json
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

from goblin_zomboid.npc import OFFLINE_ACTIONS
from goblin_zomboid.qwen import QwenClient

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / 'mod/Contents/mods/GoblinSurvivor/42/media/lua'
CATALOG = json.loads((ROOT / 'reference/goblin-commands.json').read_text())


class CommandInventoryTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().lua_root = LUA.as_posix()
        self.lua.execute('''
            package.path=lua_root..'/shared/?.lua;'..lua_root..'/server/?.lua;'..package.path
            calls={}; body={}; player={}
            function player:getUsername() return 'horse' end
            function player:Say(text) end
            local function record(handler,who,task,payload)
                calls[#calls+1]={handler=handler,who=who,task=task,payload=payload}
            end
            config={enabled=true,weaponType='Base.DoubleBarrelShotgun',
                isAuthorizedPlayer=function() return authorized==true end}
            package.loaded['GoblinSurvivor/Config']=config
            package.loaded['GoblinSurvivor/GoblinBody']={say=function() end}
            package.loaded['GoblinSurvivor/GoblinSpawner']={
                findForPlayer=function(p) assert(p==player); return body end,
                ensureForPlayer=function(p) record('Spawner.ensureForPlayer',p);return body end,
                setBaseForPlayer=function(p) record('Spawner.setBaseForPlayer',p);return true,'base' end,
                snapshotForOwner=function(name) record('Spawner.snapshotForOwner',name);return {} end,
                removeForPlayer=function(p) record('Spawner.removeForPlayer',p) end,
                setFreewillForOwner=function(owner,on) record('Spawner.setFreewillForOwner',player,nil,{owner=owner,on=on});return true end}
            package.loaded['GoblinSurvivor/GoblinBrain']={setTask=function(b,t,p)
                record('Brain.setTask',b,t,p);return true,'accepted' end}
            package.loaded['GoblinSurvivor/GoblinStockpiles']={assign=function(b,p,kind,minimum)
                record('Stockpiles.assign',p,nil,{body=b,item=kind,minimum=minimum})
                return true,'threshold recorded' end}
            package.loaded['GoblinSurvivor/GoblinStorage']={
                assign=function(b,p,category) record('Storage.assign',p,nil,{body=b,category=category})
                    return true,'assigned' end,
                unassign=function(b,p) record('Storage.unassign',p,nil,{body=b});return true,'cleared' end}
            package.loaded['GoblinSurvivor/GoblinGoals']={
                add=function(owner,name) record('Goals.add',player,nil,{owner=owner,name=name});return true,'goal' end,
                describe=function(owner) record('Goals.describe',player,nil,{owner=owner});return 'no goals' end,
                cancel=function(owner,name) record('Goals.cancel',player,nil,{owner=owner,name=name});return true,'cancelled' end}
            Events={OnClientCommand={}}
            package.loaded['GoblinSurvivor/EventHooks']={install=function(key,event,fn)
                callback=fn;return true end}
            Commands=require('GoblinSurvivor/GoblinCommands');assert(Commands.start())
            function invoke(text)
                calls={};Commands.lastAt={}
                callback('GoblinSurvivor','debug',player,
                    {text=text,owner='unicorn',npc_id='foreign',task='DRIVE',x=99999})
            end
        ''')

    def test_all_catalogued_commands_and_aliases_reach_declared_handler(self):
        for entry in CATALOG['existing_goblin_chat']['commands']:
            for spelling in [entry['command'], *entry['aliases']]:
                with self.subTest(command=spelling):
                    self.lua.globals().invoke('/goblin ' + spelling)
                    calls = self.lua.globals().calls
                    self.assertEqual(len(calls), 1)
                    call = calls[1]
                    self.assertEqual(call['handler'], entry['handler'])
                    if entry['handler'] == 'Brain.setTask':
                        self.assertEqual(call['task'], entry['task'])
                        self.lua.execute('assert(calls[1].who==body)')
                    elif entry['handler'] == 'Spawner.snapshotForOwner':
                        self.assertEqual(call['who'], 'horse')
                    else:
                        self.lua.execute('assert(calls[1].who==player)')

    def test_proposed_commands_do_not_dispatch_tasks(self):
        for entry in CATALOG['proposed_goblin_chat']:
            with self.subTest(command=entry['command']):
                self.lua.globals().invoke('/goblin ' + entry['command'])
                self.assertEqual(len(self.lua.globals().calls), 0)

    def test_admin_despawn_requires_authorization(self):
        self.lua.globals().invoke('/goblin despawn')
        self.assertEqual(len(self.lua.globals().calls), 0)
        self.lua.globals().authorized = True
        self.lua.globals().invoke('/goblin despawn')
        self.assertEqual(self.lua.globals().calls[1]['handler'], 'Spawner.removeForPlayer')
        self.lua.execute('assert(calls[1].who==player)')

    def test_api_names_code_and_invalid_subcommands_do_not_dispatch(self):
        for text in ('IsoZombie.Hit', 'getPlayer():Kill()', 'open vault',
                     'close doors', 'loot all', 'DRIVE', 'x' * 161):
            with self.subTest(text=text):
                self.lua.globals().invoke(text)
                self.assertEqual(len(self.lua.globals().calls), 0)

    def test_follow_uses_authenticated_owner_not_extra_client_fields(self):
        self.lua.globals().invoke('/goblin follow')
        self.lua.execute('''
            assert(calls[1].payload.owner=='horse')
            assert(calls[1].payload.x==nil and calls[1].payload.npc_id==nil)
            assert(calls[1].task=='FOLLOW' and calls[1].who==body)
        ''')

    def test_track_rule_uses_authenticated_owner_and_exact_arguments(self):
        self.lua.globals().invoke('/goblin track Base.Nails 50')
        self.lua.execute('''
            assert(#calls==1 and calls[1].handler=='Stockpiles.assign')
            assert(calls[1].who==player and calls[1].payload.body==body)
            assert(calls[1].payload.item=='Base.Nails' and calls[1].payload.minimum=='50')
        ''')

    def test_only_explicit_breach_command_grants_destructive_access(self):
        self.lua.globals().invoke('/goblin access room')
        self.lua.execute('''
            assert(calls[1].task=='GAIN_ACCESS')
            assert(calls[1].payload.target.kind=='ROOM')
            assert(calls[1].payload.allow_breach==false)
        ''')
        self.lua.globals().invoke('/goblin breach room')
        self.lua.execute('''
            assert(calls[1].task=='GAIN_ACCESS')
            assert(calls[1].payload.target.kind=='ROOM')
            assert(calls[1].payload.allow_breach==true)
        ''')

    def test_transport_filters_and_disabled_mod_do_not_dispatch(self):
        self.lua.execute('''
            callback('OtherMod','debug',player,{text='follow'})
            callback('GoblinSurvivor','execute',player,{text='follow'})
            callback('GoblinSurvivor','debug',player,{text={}})
            callback('GoblinSurvivor','debug',player,nil)
            callback('GoblinSurvivor','debug',player,{text=''})
            config.enabled=false
            callback('GoblinSurvivor','debug',player,{text='follow'})
            assert(#calls==0)
        ''')


class NaturalLanguageInventoryTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().lua_root = LUA.as_posix()
        self.lua.execute('''
            package.path=lua_root..'/shared/?.lua;'..lua_root..'/server/?.lua;'..package.path
            package.loaded['GoblinSurvivor/Config']={enabled=true}
            package.loaded['GoblinSurvivor/EventLog']={emit=function() return true end}
            package.loaded['GoblinSurvivor/Authority']={issue=function() return nil end}
            package.loaded['GoblinSurvivor/EventHooks']={install=function() return true end}
            package.loaded['GoblinSurvivor/GoblinSpawner']={findForOwner=function() return nil end}
            ChatBridge=require('GoblinSurvivor/ChatBridge')
        ''')

    def test_catalogued_direct_examples_match_real_router(self):
        inventory = CATALOG['existing_natural_language_chat']
        for route in inventory['routes']:
            with self.subTest(task=route['task'], example=route['example']):
                self.assertEqual(
                    self.lua.globals().ChatBridge.directIntent(route['example']),
                    route['task'],
                )

    def test_fuel_and_power_phrases_route_to_the_right_jobs(self):
        route = self.lua.globals().ChatBridge.directIntent
        for text, task in (('goblin need gas in the car', 'REFUEL_VEHICLE'),
                           ('goblin fuel the car', 'REFUEL_VEHICLE'),
                           ('Goblin, put petrol in the truck', 'REFUEL_VEHICLE'),
                           ('Goblin, the generator needs gas', 'RESTORE_POWER'),
                           ('Goblin, fix the power', 'RESTORE_POWER')):
            with self.subTest(text=text):
                self.assertEqual(route(text), task)

    def test_direct_router_rejects_negated_and_question_examples(self):
        for text in (
            'Goblin, do not kill that zombie',
            'Goblin, how do you open doors?',
            'Goblin, never loot this house',
        ):
            with self.subTest(text=text):
                self.assertIsNone(self.lua.globals().ChatBridge.directIntent(text))

    def test_natural_access_dispatch_is_non_destructive(self):
        self.lua.execute('''
            Events={OnClientCommand={}}
            local hooks=package.loaded['GoblinSurvivor/EventHooks']
            function hooks.install(key,event,fn) callback=fn;return true end
            local spawner=package.loaded['GoblinSurvivor/GoblinSpawner']
            body={};player={getUsername=function() return 'horse' end}
            function spawner.ensureForPlayer(who) assert(who==player);return body end
            package.loaded['GoblinSurvivor/GoblinBody']={say=function() return true end}
            calls={}
            package.loaded['GoblinSurvivor/GoblinBrain']={setTask=function(who,task,payload)
                calls[#calls+1]={who=who,task=task,payload=payload}
                return true,'accepted'
            end}
            ChatBridge.start()
            callback('GoblinSurvivor','chat',player,{text='Goblin, access the yard'})
            assert(#calls==1 and calls[1].who==body)
            assert(calls[1].task=='GAIN_ACCESS')
            assert(calls[1].payload.target.kind=='YARD')
            assert(calls[1].payload.allow_breach==false)
            callback('GoblinSurvivor','chat',player,{text='Goblin, breach the room'})
            assert(#calls==1)
        ''')

    def test_qwen_and_offline_action_sets_match_inventory(self):
        schema = QwenClient._chat_schema({'mode': 'ROAM', 'controlled_owner': 'horse'})
        generated = {
            branch['properties']['intent']['const']
            for branch in schema['oneOf']
        }
        inventory = CATALOG['qwen_intent_transport']
        self.assertEqual(generated, set(inventory['chat_generation_actions']))
        self.assertEqual(set(OFFLINE_ACTIONS), set(inventory['offline_actions']))

    def test_rcon_is_separate_and_empty(self):
        rcon = CATALOG['administrative_server_rcon']
        self.assertEqual(rcon['inventory_status'], 'audited_no_rcon_integration_in_repository')
        self.assertEqual(rcon['commands'], [])
        self.assertFalse(rcon['gameplay_callable'])


if __name__ == '__main__':
    unittest.main()

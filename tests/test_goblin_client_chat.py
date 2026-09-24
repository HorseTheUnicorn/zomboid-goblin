"""The client relay must not lowercase installed item or recipe identifiers."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class ClientChatRelayTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().lua_root = LUA.as_posix()
        self.lua.execute('''
            package.path=lua_root..'/client/?.lua;'..lua_root..'/shared/?.lua;'..package.path
            package.loaded['GoblinSurvivor/Config']={npcVisualAsset='fixture'}
            hooks={}
            package.loaded['GoblinSurvivor/EventHooks']={install=function(key,event,callback)
                hooks[key]=callback;return true end}
            for _,name in ipairs({'GoblinAppearance','GoblinLocomotion','GoblinGuard',
                'GoblinCombatVisual','GoblinNameplates','GoblinVisibility','GoblinMap'}) do
                package.loaded['GoblinSurvivor/'..name]={}
            end
            package.loaded['GoblinSurvivor/GoblinSpeech']={observe=function() end}
            Events={}
            for _,name in ipairs({'OnRenderTick','OnGameStart','OnPostUIDraw',
                'OnServerCommand','OnInitGlobalModData','OnReceiveGlobalModData',
                'OnZombieCreate','OnZombieUpdate','OnTick','OnAddMessage',
                'OnPlayerUpdate'}) do Events[name]=name end
            getPlayer=function() return {getUsername=function() return 'horse' end} end
            sent={}
            sendClientCommand=function(module,command,args)
                sent[#sent+1]={module=module,command=command,args=args}
            end
            require('GoblinSurvivor/GoblinClient')
            function chat(author,text)
                return {getAuthor=function() return author end,
                    getText=function() return text end}
            end
        ''')

    def test_command_keyword_is_case_insensitive_but_arguments_are_not(self):
        self.lua.execute('''
            local callback=assert(hooks['client.chat_message'])
            callback(chat('horse','!GoBlIn track Base.Nails 50'),0)
            callback(chat('horse','/goblin craft Sibling.RecipeName'),0)
            assert(#sent==2)
            assert(sent[1].module=='GoblinSurvivor' and sent[1].command=='debug')
            assert(sent[1].args.text=='/goblin track Base.Nails 50')
            assert(sent[2].args.text=='/goblin craft Sibling.RecipeName')
        ''')

    def test_noncommand_prefix_is_not_accepted_as_debug_command(self):
        self.lua.execute('''
            local callback=assert(hooks['client.chat_message'])
            callback(chat('horse','!goblinized track Base.Nails 50'),0)
            assert(#sent==1 and sent[1].command=='chat')
            callback(chat('unicorn','!goblin track Base.Nails 50'),0)
            assert(#sent==1)
        ''')

    def test_fallen_hat_bit_preserves_identity_but_other_outfits_do_not(self):
        self.lua.execute('''
            local client=require('GoblinSurvivor/GoblinClient')
            local motion=require('GoblinSurvivor/GoblinLocomotion')
            motion.rejoin=function() return false end
            local appearance=require('GoblinSurvivor/GoblinAppearance')
            appearance.isSpawnOutfit=function() return true end
            appearance.apply=function() return true end
            require('GoblinSurvivor/GoblinGuard').apply=function() end
            require('GoblinSurvivor/GoblinVisibility').track=function() end
            local confirmed=0
            require('GoblinSurvivor/GoblinNameplates').track=function() confirmed=confirmed+1 end
            package.loaded['GoblinSurvivor/GoblinPassenger']={apply=function() return true end}
            local observed
            require('GoblinSurvivor/GoblinClientTrace').sampleBody=function(body,state) observed=state end
            local body={outfit=131079}
            function body:getOnlineID() return 5 end
            function body:getModData() return {} end
            function body:getPersistentOutfitID() return self.outfit end
            local state={npc_id='goblin.primary.horse',outfit_id=131079,body_present=true}
            client.statesByOnline[5]=state
            local update=assert(hooks['client.zombie_update'])
            update(body);assert(observed==state and confirmed==1)
            body.outfit=131079+32768
            update(body);assert(observed==state and confirmed==2)
            state.outfit_id=body.outfit;body.outfit=131079
            update(body);assert(observed==state and confirmed==3)
            body.outfit=131080
            update(body);assert(observed==nil and confirmed==3,'different seed must be rejected')
            state.outfit_id=-2147352569;body.outfit=state.outfit_id+32768
            update(body);assert(observed==state and confirmed==4,'preserve female/sign bit')
            body.outfit=nil
            update(body);assert(observed==nil and confirmed==4)
        ''')


if __name__ == '__main__':
    unittest.main()

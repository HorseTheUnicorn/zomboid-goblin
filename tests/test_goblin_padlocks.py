from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / 'mod/Contents/mods/GoblinSurvivor/42/media/lua'


class PadlockTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ';'.join((LUA / s / '?.lua').as_posix()
                                          for s in ('shared', 'server', 'client'))
        self.lua.execute('package.path=paths..";"..package.path')
        for name in ('goblin_fixture.lua', 'work_fixture.lua'):
            self.lua.execute((ROOT / 'tests/lua' / name).read_text())
        self.lua.execute('''
            Padlocks=require('GoblinSurvivor/GoblinPadlocks')
            Access=require('GoblinSurvivor/GoblinAccess')
            key=item('Base.KeyPadlock');key.id=42
            function key:getKeyId() return self.id end
            function key:getContainer() return a.inv end
            a.inv:AddItem(key)
            function a.inv:haveThisKeyId(id)
                if id==key.id and self:contains(key) then return key end
            end
            created=0
            function instanceItem(kind)
                assert(kind=='Base.Padlock');created=created+1
                local p=item(kind)
                function p:setNumberOfKey(n) self.number=n end
                function p:setKeyId(id) self.id=id end
                function p:getKeyId() return self.id end
                return p
            end
            gate={id=42,padlocked=true,locked=true,keyLocked=true,opened=false,syncs=0}
            function gate:getSquare() return cell:getGridSquare(0,0,0) end
            function gate:getKeyId() return self.id end
            function gate:setKeyId(id) self.id=id end
            function gate:isLockedByPadlock() return self.padlocked end
            function gate:setLockedByPadlock(v) self.padlocked=v end
            function gate:isLocked() return self.locked end
            function gate:setLocked(v) self.locked=v end
            function gate:isLockedByKey() return self.keyLocked end
            function gate:setLockedByKey(v) self.keyLocked=v end
            function gate:getLockedByCode() return 0 end
            function gate:isOpen() return self.opened end
            function gate:isBarricaded() return false end
            function gate:isDestroyed() return false end
            function gate:sync() self.syncs=self.syncs+1 end
            gate.syncIsoObject=gate.sync
            function gate:ToggleDoorSilent() self.opened=true end
        ''')

    def test_access_converts_real_key_to_matching_padlock_once(self):
        self.lua.execute('''
            assert(Access.open(a,gate,false))
            assert(gate.opened and not gate.padlocked and gate.id==-1)
            assert(not a.inv:contains(key) and #a.inv.items==1)
            local lock=a.inv.items[1]
            assert(lock:getFullType()=='Base.Padlock' and lock.id==42 and lock.number==1)
            assert(gate.syncs>0 and created==1)
            assert(not Padlocks.remove(a,gate) and created==1)
        ''')

    def test_missing_key_and_client_authority_do_not_create_items(self):
        self.lua.execute('''
            key.id=99
            assert(not Access.open(a,gate,false) and created==0 and gate.padlocked)
            key.id=42;isClient=function() return true end
            assert(not Padlocks.remove(a,gate) and created==0 and gate.padlocked)
        ''')

    def test_failed_key_consumption_compensates_and_blocks_replay(self):
        self.lua.execute('''
            local remove=a.inv.Remove
            function a.inv:Remove(value) if value~=key then remove(self,value) end end
            assert(not Padlocks.remove(a,gate))
            assert(gate.padlocked and gate.id==42 and a.inv:contains(key) and #a.inv.items==1)
            a.inv.Remove=remove
            assert(not Padlocks.remove(a,gate) and created==1)
        ''')

    def test_failed_world_mutation_restores_transferred_key(self):
        self.lua.execute('''
            function gate:setKeyId(id) if id==-1 then error('native failure') end;self.id=id end
            assert(not Padlocks.remove(a,gate))
            assert(gate.padlocked and gate.id==42 and a.inv:contains(key) and #a.inv.items==1)
            assert(Padlocks.failed[gate])
        ''')

    def test_safehouse_denial_precedes_item_transfer(self):
        self.lua.execute('''
            SafeHouse={getSafeHouse=function() return {playerAllowed=function() return false end} end}
            assert(not Access.open(a,gate,false))
            assert(created==0 and gate.padlocked and a.inv:contains(key))
        ''')


if __name__ == '__main__':
    unittest.main()

"""A Goblin claims a base house himself (fixture, not engine evidence)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"

FIXTURE = r'''
Claim=require('GoblinSurvivor/GoblinBaseClaim')
said={}
package.loaded['GoblinSurvivor/GoblinBody'].say=function(_,text) said[#said+1]=text end
setAt=nil
package.loaded['GoblinSurvivor/GoblinSpawner'].setBaseForOwnerAt=function(owner,point)
    setAt=point; body.data.GoblinBaseSet=true
    body.data.GoblinBaseX,body.data.GoblinBaseY,body.data.GoblinBaseZ=point.x,point.y,point.z
    return true
end
-- A house occupies x,y 10..14; everything else is open ground.
for x=-5,40 do for y=-5,40 do
    local sq=squareAt(x,y,0)
    local inHouse=x>=10 and x<=14 and y>=10 and y<=14
    function sq:getRoom() return inHouse and {} or nil end
end end
package.loaded['GoblinSurvivor/GoblinCurtains'].scopeAt=function(p)
    local x,y=math.floor(p.x),math.floor(p.y)
    return (x>=10 and x<=14 and y>=10 and y<=14) and scope or nil
end
'''


class BaseClaimTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT / "tests/lua/logistics_fixture.lua").read_text())
        self.lua.execute(FIXTURE)

    def test_no_base_claims_the_nearest_house(self):
        self.lua.execute('''
            body.data.GoblinBaseSet=false
            assert(Claim.ensure(body,'INSPECT_BASE',owner))
            assert(math.floor(setAt.x)==10 and math.floor(setAt.y)==10, setAt.x..','..setAt.y)
            assert(said[1]:find('claimed the nearest house'))
        ''')

    def test_outdoor_base_moves_into_the_house_next_to_it_for_house_jobs_only(self):
        self.lua.execute('''
            body.data.GoblinBaseSet=true; body.data.GoblinBaseX=7; body.data.GoblinBaseY=12; body.data.GoblinBaseZ=0
            assert(Claim.ensure(body,'SORT_STORAGE',owner)) -- an outdoor stockpile base is fine
            assert(setAt==nil)
            assert(Claim.ensure(body,'FORTIFY',owner))
            assert(math.floor(setAt.x)==10 and math.floor(setAt.y)==12)
        ''')

    def test_other_players_safehouse_is_never_claimed(self):
        self.lua.execute('''
            body.data.GoblinBaseSet=false
            authorized=false
            assert(not Claim.ensure(body,'INSPECT_BASE',owner))
            assert(setAt==nil)
            assert(Claim.ensure(body,'FORAGE',owner)) -- jobs without a base are untouched
        ''')


if __name__ == "__main__":
    unittest.main()

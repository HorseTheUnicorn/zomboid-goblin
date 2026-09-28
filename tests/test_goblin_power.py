"""RESTORE_POWER fixtures (not engine or multiplayer evidence)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"

FIXTURE = r'''
Power=require('GoblinSurvivor/GoblinPower')
-- Base house covers x,y 0..4 (indoors); everything else is open ground.
for x=-12,24 do for y=-12,24 do
    local sq=squareAt(x,y,0)
    local indoors=x>=0 and x<=4 and y>=0 and y<=4
    function sq:isOutside() return not indoors end
    function sq:isFree() return true end
    function sq:isSolidFloor() return true end
    function sq:getVehicleContainer() return nil end
end end
generators={}
function newGenerator(item, square)
    local g={class='IsoGenerator', square=square, fuel=0, max=100, condition=item and item.condition or 100,
             connected=false, activated=false, syncs=0}
    function g:getSquare() return self.square end
    function g:getFuel() return self.fuel end
    function g:getMaxFuel() return self.max end
    function g:setFuel(v) self.fuel=v end
    function g:getCondition() return self.condition end
    function g:setCondition(v) self.condition=v end
    function g:isConnected() return self.connected end
    function g:setConnected(v) self.connected=v end
    function g:isActivated() return self.activated end
    function g:setActivated(v) self.activated=v end
    function g:sync() self.syncs=self.syncs+1 end
    function g:transmitCompleteItemToClients() self.transmitted=true end
    square.objects[#square.objects+1]=g
    generators[#generators+1]=g
    return g
end
IsoGenerator={new=function(item, cell, square) return newGenerator(item, square) end,
    updateGenerator=function() end}
instanceItem=function(kind)
    local it={kind=kind, condition=50, md={}}
    function it:setCondition(v) self.condition=v end
    function it:getModData() return self.md end
    return it
end
cans=0
package.loaded['GoblinSurvivor/GoblinProvision']={
    enabled=function() return true end,
    isConjured=function() return true end,
    fluid=function(b, kind, fluid)
        cans=cans+1
        local fc={amount=10}
        function fc:getAmount() return self.amount end
        function fc:adjustAmount(v) self.amount=v end
        local can={kind=kind}
        function can:getFluidContainer() return fc end
        return can
    end}
body.data.GoblinBaseX=2; body.data.GoblinBaseY=2
'''


class PowerTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT / "tests/lua/logistics_fixture.lua").read_text())
        self.lua.execute(FIXTURE)

    def test_no_generator_places_one_outdoors_fuels_plugs_and_starts_it(self):
        self.lua.execute('''
            assert(Power.prepare(body,owner,{})==nil) -- needs an owner order
            local payload=assert(Power.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Power,payload)
            assert(success and code=='COMPLETE', detail)
            assert(#generators==1)
            local g=generators[1]
            assert(g.square:isOutside() and g.transmitted)
            assert(g.fuel==100 and g.condition==100 and g.connected and g.activated, detail)
            assert(cans==10 and payload.placed and detail:find('running'))
        ''')

    def test_existing_broken_generator_is_repaired_topped_up_and_started(self):
        self.lua.execute('''
            local g=newGenerator({condition=30}, squareAt(6,2,0))
            g.fuel=95
            local payload=assert(Power.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Power,payload)
            assert(success and code=='COMPLETE', detail)
            assert(#generators==1 and not payload.placed and payload.repaired)
            assert(g.condition==100 and g.fuel==100 and g.connected and g.activated)
            assert(cans==1)
        ''')

    def test_other_players_safehouse_generator_is_left_alone(self):
        self.lua.execute('''
            authorized=false
            local payload=assert(Power.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Power,payload)
            assert(not success and code=='NO_TARGET', detail)
            assert(#generators==0)
        ''')


if __name__ == "__main__":
    unittest.main()

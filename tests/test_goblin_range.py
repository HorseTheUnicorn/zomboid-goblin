"""Goblin range (150 tiles): nearest-first, budgeted ring search (fixtures)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class RangeTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join((LUA / s / "?.lua").as_posix() for s in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute('''
            isServer=function() return true end
            package.loaded['GoblinSurvivor/GoblinAccessPolicy']={access=function() return true end}
            visits=0
            local squares={}
            getCell=function() return {getGridSquare=function(_,x,y,z)
                if math.abs(x)>200 or math.abs(y)>200 then return nil end
                visits=visits+1
                local key=x..':'..y
                squares[key]=squares[key] or {x=x,y=y,z=z,objects={},world={},
                    getX=function(s) return s.x end,getY=function(s) return s.y end,getZ=function(s) return s.z end,
                    getObjects=function(s) return nil end,
                    getWorldObjects=function(s) return {size=function() return #s.world end,
                        get=function(_,i) return s.world[i+1] end} end}
                return squares[key]
            end} end
            function drop(x,y,kind)
                local sq=getCell():getGridSquare(x,y,0)
                sq.world[#sq.world+1]={getItem=function() return {kind=kind,getFullType=function() return kind end} end}
            end
            World=require('GoblinSurvivor/GoblinWorld')
            Config=require('GoblinSurvivor/Config')
        ''')

    def test_default_range_is_150_tiles_everywhere(self):
        self.lua.execute('''
            assert(World.range()==150)
            assert(Config.goblinRange==150 and Config.caretakerRoamRadius==150)
            assert(Config.lootRadius==150 and Config.autonomyExploreRadius==150 and Config.salvageRadius==150)
        ''')

    def test_search_finds_things_140_tiles_away_spread_over_calls(self):
        self.lua.execute('''
            drop(140,-20,'Base.Nails')
            local state={}
            local calls=0
            local found,done
            repeat
                visits=0
                found,done=World.search({x=0,y=0,z=0},nil,function(i) return i.kind=='Base.Nails' end,nil,state,4000)
                calls=calls+1
                assert(visits<=4000+8*150, 'budget exceeded: '..visits)
            until done or calls>100
            assert(done and #found==1 and found[1].square.x==140, 'not found')
            assert(calls>10) -- spread over many ticks, never one huge stall
        ''')

    def test_nearest_band_wins_and_search_stops_early(self):
        self.lua.execute('''
            drop(3,0,'Base.Plank'); drop(100,0,'Base.Plank')
            visits=0
            local found=World.sourcesNear({x=0,y=0,z=0},function(i) return i.kind=='Base.Plank' end,nil)
            assert(#found==1 and found[1].square.x==3)
            assert(visits<=81, 'kept scanning after the nearest band: '..visits)
        ''')

    def test_ring_offsets_cover_each_ring_exactly_once(self):
        self.lua.execute('''
            for r=1,6 do
                local seen={}
                for i=0,8*r-1 do
                    local dx,dy=World.ringOffset(r,i)
                    assert(math.max(math.abs(dx),math.abs(dy))==r)
                    local k=dx..':'..dy; assert(not seen[k]); seen[k]=true
                end
            end
        ''')


if __name__ == "__main__":
    unittest.main()

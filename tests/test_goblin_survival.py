"""Milestone 5 survival adapter fixtures (not engine or multiplayer evidence)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"

FIXTURE = r'''
Survival=require('GoblinSurvivor/GoblinSurvival')
local Tools=package.loaded['GoblinSurvivor/GoblinTools']
Tools.ensure=function(b,kind)
    for _,v in ipairs(b.inv.items) do if v.kind==kind and reserved[v] then return v end end
    local tool=item(kind,'ToolWeapon'); reserved[tool]=true; b.inv.items[#b.inv.items+1]=tool
    function tool:isBroken() return false end
    return tool
end
function tree(x,y,health)
    local sq=squareAt(x,y,0)
    local t={class='IsoTree',health=health,square=sq,hits=0}
    function t:getObjectIndex()
        for i,o in ipairs(sq.objects) do if o==self then return i-1 end end
        return -1
    end
    function t:getHealth() return self.health end
    function t:WeaponHit(actor,axe)
        assert(actor==body and reserved[axe])
        self.hits=self.hits+1
        self.health=self.health-self.damage
        if self.health<=0 then
            for i,o in ipairs(sq.objects) do if o==self then table.remove(sq.objects,i) end end
            floorItem(x,y,item('Base.Log','Material'))
        end
    end
    t.damage=25
    sq.objects[#sq.objects+1]=t
    return t
end
function woundedOwner(parts)
    local damage={parts=parts}
    function damage:getBodyParts() return javaList(self.parts) end
    function damage:SetBandaged(index,value,life,alcoholic,kind)
        for _,p in ipairs(self.parts) do
            if p.index==index then p.isBandaged=value; p.life=life; p.kind=kind end
        end
    end
    function owner:getBodyDamage() return damage end
    return damage
end
function javaList(values)
    return {size=function() return #values end,get=function(_,i) return values[i+1] end}
end
function bodyPart(index,opts)
    local p={index=index,bleed=opts.bleed or 0,cut=opts.cut==true,isBandaged=false}
    function p:getIndex() return self.index end
    function p:bandaged() return self.isBandaged end
    function p:getBleedingTime() return self.bleed end
    function p:scratched() return false end
    function p:isCut() return self.cut end
    function p:deepWounded() return false end
    function p:bitten() return false end
    function p:manipulatingUsername() return self.manipulator or '' end
    function p:setManipulatingUsername(v) self.manipulator=v end
    function p:SetInfected(v) self.infected=v end
    return p
end
function bandage(kind,power)
    local b=item(kind,'Bandage')
    function b:getBandagePower() return power end
    function b:isAlcoholic() return false end
    function b:isInfected() return false end
    return b
end
synced={}
syncBodyPart=function(part,flags) synced[#synced+1]={part=part,flags=flags} end
ZombRandFloat=function(a,b) return a end
'''


class SurvivalTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT / "tests/lua/logistics_fixture.lua").read_text())
        self.lua.execute(FIXTURE)

    def test_chop_wood_uses_native_weapon_hits_until_the_tree_falls(self):
        self.lua.execute('''
            local t=tree(5,5,100)
            local payload=assert(Survival.Chop.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Survival.Chop,payload)
            assert(success and code=='COMPLETE' and payload.felled==1, detail)
            assert(t.hits==4 and t:getObjectIndex()==-1)
            assert(#squareAt(5,5,0).world==1)
        ''')

    def test_chop_refuses_without_owner_order_or_trees(self):
        self.lua.execute('''
            assert(Survival.Chop.prepare(body,owner,{})==nil)
            local payload,detail=Survival.Chop.prepare(body,owner,{explicit_owner_order=true})
            assert(payload==nil and detail:find('no tree'))
            tree(1,1,50)
            assert(Survival.Chop.prepare(body,owner,{explicit_owner_order=true,count=9})==nil)
        ''')

    def test_chop_stops_when_hits_do_not_damage(self):
        self.lua.execute('''
            local t=tree(5,5,100); t.damage=0
            local payload=assert(Survival.Chop.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Survival.Chop,payload)
            assert(not success and code=='UNSUPPORTED', detail)
        ''')

    def test_treat_player_bandages_bleeding_first_with_real_items(self):
        self.lua.execute('''
            local arm=bodyPart(3,{cut=true}); local leg=bodyPart(9,{bleed=5})
            woundedOwner({arm,leg})
            local rag=bandage('Base.RippedSheets',1); local good=bandage('Base.Bandage',4)
            body.inv.items={rag,good}
            local payload=assert(Survival.Treat.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Survival.Treat,payload)
            assert(success and code=='COMPLETE' and payload.treated==2, detail)
            assert(leg.isBandaged and leg.kind=='Base.Bandage' and leg.life==4.5)
            assert(arm.isBandaged and arm.kind=='Base.RippedSheets')
            assert(#body.inv.items==0 and #synced==2)
        ''')

    def test_treat_player_fetches_nearby_bandage_or_reports_shortage(self):
        self.lua.execute('''
            local leg=bodyPart(9,{bleed=5})
            woundedOwner({leg})
            local payload=assert(Survival.Treat.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Survival.Treat,payload)
            assert(not success and code=='MISSING_MATERIAL' and not leg.isBandaged, detail)
            local box=furniture(1,1,{bandage('Base.Bandage',4)})
            payload=assert(Survival.Treat.prepare(body,owner,{explicit_owner_order=true}))
            success,detail=run(Survival.Treat,payload)
            assert(success and leg.isBandaged and #box.c.items==0, detail)
        ''')

    def test_treat_player_skips_dirty_bandages_and_foreign_manipulation(self):
        self.lua.execute('''
            local leg=bodyPart(9,{bleed=5}); leg.manipulator='doctor'
            woundedOwner({leg})
            body.inv.items={bandage('Base.BandageDirty',2),bandage('Base.Bandage',4)}
            local payload=assert(Survival.Treat.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Survival.Treat,payload)
            assert(not success and code=='BLOCKED' and not leg.isBandaged, detail)
            assert(#body.inv.items==2)
        ''')


if __name__ == "__main__":
    unittest.main()

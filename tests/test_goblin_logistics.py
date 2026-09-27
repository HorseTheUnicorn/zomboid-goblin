"""Milestone 4 logistics fixtures: storage categories, sorting, fetch, deliver.

These exercise the real Lua custody/ledger code against an in-memory world.
They are not engine, multiplayer or save/reload evidence.
"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class LogisticsBase(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute((ROOT / "tests/lua/logistics_fixture.lua").read_text())


class StorageCategoryTests(LogisticsBase):
    def test_categories_come_from_installed_display_category(self):
        self.lua.execute('''
            assert(Storage.category(item('Base.TinnedBeans','Food'))=='FOOD')
            assert(Storage.category(item('Base.Plank','MaterialWeapon'))=='MATERIALS')
            assert(Storage.category(item('Base.Hammer','ToolWeapon'))=='TOOLS')
            assert(Storage.category(item('Base.Bandage','Bandage'))=='MEDICAL')
            assert(Storage.category(item('Base.Key1','Security'))==nil)
            assert(Storage.category(item('Base.Wound','Wound'))==nil)
            assert(Storage.category(item('Mod.Thing',nil,{legacy='Food'}))=='FOOD')
            assert(Storage.category(item('Mod.Unknown','SomethingNew'))==nil)
            assert(Storage.normalize('meds')=='MEDICAL' and Storage.normalize('Food')=='FOOD')
            assert(Storage.normalize('drop box')=='INBOX' and Storage.normalize('lasers')==nil)
        ''')

    def test_assignment_persists_identity_and_rejects_foreign_container(self):
        self.lua.execute('''
            local crate=furniture(0,0,{})
            assignAt(0,0,'food',crate)
            assert(crate.md.GoblinStorageCategory=='FOOD' and crate.md.GoblinStorageOwner=='horse')
            assert(crate.transmitted==1)
            local record=storageRecords[crate.md.GoblinStorageID]
            assert(record.category=='FOOD' and record.building_id=='house-a' and record.x==0)
            local live=Storage.assignments(body,scope)
            assert(#live==1 and live[1].container==crate.c)
            local other=furniture(4,4,{})
            other.md.GoblinStorageOwner='unicorn'
            owner.pos={x=4.5,y=4.5,z=0}
            local ok,detail=Storage.assign(body,owner,'TOOLS')
            assert(not ok and detail:find('another player'))
            owner.pos={x=0.5,y=0.5,z=0}
            assert(Storage.unassign(body,owner))
            assert(crate.md.GoblinStorageCategory==nil and next(storageRecords)==nil)
        ''')

    def test_moved_or_replaced_container_is_not_resolved_by_coordinates(self):
        self.lua.execute('''
            local crate=furniture(0,0,{})
            assignAt(0,0,'food',crate)
            squareAt(0,0,0).objects={}
            local replacement=furniture(0,0,{})
            local live,failures=Storage.assignments(body,scope)
            assert(#live==0 and failures[1].code=='TARGET_CHANGED')
        ''')


class SortStorageTests(LogisticsBase):
    def setUp(self):
        super().setUp()
        self.lua.execute('''
            Sort=require('GoblinSurvivor/GoblinSortWork')
            beans=item('Base.TinnedBeans','Food')
            nails=item('Base.Nails','Material')
            inbox=furniture(2,0,{beans,nails})
            pantry=furniture(0,0,{})
            shed=furniture(4,0,{})
            assignAt(2,0,'inbox',inbox)
            assignAt(0,0,'food',pantry)
            assignAt(4,0,'materials',shed)
        ''')

    def test_inbox_items_reach_their_category_by_identity(self):
        self.lua.execute('''
            local payload=assert(Sort.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Sort,payload)
            assert(success and code=='COMPLETE', detail)
            assert(pantry.c.items[1]==beans and #pantry.c.items==1)
            assert(shed.c.items[1]==nails and #shed.c.items==1)
            assert(#inbox.c.items==0 and #body.inv.items==0)
            assert(payload.moved==2 and #payload.ledger==0)
            assert(#sent.add==2 and #sent.remove==2)
        ''')

    def test_order_requires_owner_and_categories(self):
        self.lua.execute('''
            assert(Sort.prepare(body,owner,{})==nil)
            assert(Sort.prepare(body,owner,{explicit_owner_order=true,autonomous=true})==nil)
            owner.online=false
            assert(Sort.prepare(body,owner,{explicit_owner_order=true})==nil)
            owner.online=true
            storageRecords={}
            local payload,detail=Sort.prepare(body,owner,{explicit_owner_order=true})
            assert(payload==nil and detail:find('assign at least one'))
        ''')

    def test_full_category_falls_back_to_overflow(self):
        self.lua.execute('''
            pantry.c.capacity=0
            local spare=furniture(0,4,{})
            assignAt(0,4,'overflow',spare)
            local payload=assert(Sort.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail=run(Sort,payload)
            assert(success, detail)
            assert(spare.c.items[1]==beans and #pantry.c.items==0)
        ''')

    def test_destination_filled_in_transit_returns_item_to_source(self):
        self.lua.execute('''
            local payload=assert(Sort.prepare(body,owner,{explicit_owner_order=true}))
            local runtime={}
            -- Walk to inbox, then pick up both items.
            for clock=1,3 do Sort.update(body,payload,runtime,1000+clock*1000) end
            assert(#body.inv.items==2)
            pantry.c.capacity=0
            shed.c.capacity=0
            local success,detail,code=run(Sort,payload,runtime)
            assert(not success and code=='BLOCKED' or success, detail)
            assert(#inbox.c.items+#body.inv.items==2)
            assert(payload.returned>=1)
        ''')

    def test_restart_reconciles_carried_and_already_delivered_ledger(self):
        self.lua.execute('''
            local payload=assert(Sort.prepare(body,owner,{explicit_owner_order=true}))
            local runtime={}
            for clock=1,3 do Sort.update(body,payload,runtime,1000+clock*1000) end
            assert(#payload.ledger==2 and #body.inv.items==2)
            -- Crash after the beans deposit but before the ledger was saved.
            body.inv:Remove(beans); pantry.c:AddItem(beans)
            local success,detail=run(Sort,payload,{})
            assert(success, detail)
            assert(#pantry.c.items==1 and pantry.c.items[1]==beans)
            assert(#shed.c.items==1 and shed.c.items[1]==nails)
            assert(payload.moved==2)
        ''')

    def test_lost_ledger_item_stops_without_duplication(self):
        self.lua.execute('''
            local payload=assert(Sort.prepare(body,owner,{explicit_owner_order=true}))
            local runtime={}
            for clock=1,3 do Sort.update(body,payload,runtime,1000+clock*1000) end
            body.inv:Remove(nails)
            local success,detail,code=run(Sort,payload,{})
            assert(not success and code=='ENGINE_ERROR' and detail:find('could not be located'))
        ''')

    def test_sort_all_skips_cold_food_foreign_and_reserved_items(self):
        self.lua.execute('''
            local fridgeBeans=item('Base.TinnedBeans','Food')
            local fridgeNails=item('Base.Nails','Material')
            local fridge=furniture(2,4,{fridgeBeans,fridgeNails},10,'fridge')
            local hammer=item('Base.Hammer','ToolWeapon'); reserved[hammer]=true
            local toolbox=item('Base.Hammer','ToolWeapon')
            local neighbour=furniture(4,2,{item('Base.TinnedBeans','Food')})
            neighbour.md.GoblinStorageOwner='unicorn'
            local loose=item('Base.Nails','Material')
            floorItem(1,2,loose)
            local counter=furniture(1,4,{hammer})
            local payload=assert(Sort.prepare(body,owner,{explicit_owner_order=true,all=true}))
            local success,detail=run(Sort,payload)
            assert(success, detail)
            assert(fridge.c.items[1]==fridgeBeans and #fridge.c.items==1)
            assert(counter.c.items[1]==hammer)
            assert(#neighbour.c.items==1)
            assert(count(shed.c,'Base.Nails')==3)
            assert(#squareAt(1,2,0).world==0)
        ''')

    def test_owner_logout_keeps_cargo(self):
        self.lua.execute('''
            local payload=assert(Sort.prepare(body,owner,{explicit_owner_order=true}))
            local runtime={}
            for clock=1,3 do Sort.update(body,payload,runtime,1000+clock*1000) end
            owner.online=false
            local done,success,detail,code=Sort.update(body,payload,runtime,9000)
            assert(done and not success and code=='INTERRUPTED' and detail:find('2 carried'))
            assert(#body.inv.items==2)
        ''')


class FetchDeliverTests(LogisticsBase):
    def setUp(self):
        super().setUp()
        self.lua.execute('''
            Fetch=require('GoblinSurvivor/GoblinFetchWork')
            Deliver=require('GoblinSurvivor/GoblinDeliverWork')
            shelf=furniture(0,0,{item('Base.Nails','Material'),item('Base.Nails','Material'),
                item('Base.Nails','Material'),item('Base.TinnedBeans','Food')})
        ''')

    def test_fetch_hands_exact_count_to_owner(self):
        self.lua.execute('''
            local payload=assert(Fetch.prepare(body,owner,{explicit_owner_order=true,item='Base.Nails',count=2}))
            local success,detail,code=run(Fetch,payload)
            assert(success and code=='COMPLETE', detail)
            assert(count(owner.inv,'Base.Nails')==2 and count(shelf.c,'Base.Nails')==1)
            assert(#body.inv.items==0 and payload.delivered==2)
        ''')

    def test_fetch_category_and_shortage_is_reported(self):
        self.lua.execute('''
            local payload=assert(Fetch.prepare(body,owner,{explicit_owner_order=true,item='food',count=3}))
            local success,detail,code=run(Fetch,payload)
            assert(not success and code=='MISSING_MATERIAL' and detail:find('1 of 3'), detail)
            assert(count(owner.inv,'Base.TinnedBeans')==1)
        ''')

    def test_fetch_rejects_unknown_items_and_bad_counts(self):
        self.lua.execute('''
            assert(Fetch.prepare(body,owner,{explicit_owner_order=true,item='Base.NoSuchThing'})==nil)
            assert(Fetch.prepare(body,owner,{explicit_owner_order=true,item='Base.Nails',count=21})==nil)
            assert(Fetch.prepare(body,owner,{explicit_owner_order=true,item='inbox'})==nil)
            assert(Fetch.prepare(body,owner,{item='Base.Nails'})==nil)
        ''')

    def test_fetch_full_owner_inventory_drops_at_owner_feet(self):
        self.lua.execute('''
            owner.inv.capacity=0
            local payload=assert(Fetch.prepare(body,owner,{explicit_owner_order=true,item='Base.Nails',count=1}))
            local success,detail=run(Fetch,payload)
            assert(success, detail)
            local sq=owner:getCurrentSquare()
            assert(#sq.world==1 and sq.world[1].item.kind=='Base.Nails')
        ''')

    def test_fetch_owner_logout_retains_cargo_and_restart_resumes(self):
        self.lua.execute('''
            local payload=assert(Fetch.prepare(body,owner,{explicit_owner_order=true,item='Base.Nails',count=2}))
            local runtime={}
            for clock=1,3 do Fetch.update(body,payload,runtime,1000+clock*1000) end
            assert(count(body.inv,'Base.Nails')==2)
            owner.online=false
            local done,success,detail,code=Fetch.update(body,payload,runtime,9000)
            assert(done and code=='INTERRUPTED' and count(body.inv,'Base.Nails')==2)
            owner.online=true
            local ok,text=run(Fetch,payload,{})
            assert(ok, text)
            assert(count(owner.inv,'Base.Nails')==2 and count(shelf.c,'Base.Nails')==1)
        ''')

    def test_deliver_puts_selected_cargo_away_and_never_moves_toolkit(self):
        self.lua.execute('''
            local pantry=furniture(4,0,{}); assignAt(4,0,'food',pantry)
            local shed=furniture(0,4,{}); assignAt(0,4,'materials',shed)
            local hammer=item('Base.Hammer','ToolWeapon'); reserved[hammer]=true
            local beans=item('Base.TinnedBeans','Food')
            local plank=item('Base.Plank','MaterialWeapon')
            body.inv.items={hammer,beans,plank}
            local payload=assert(Deliver.prepare(body,owner,{explicit_owner_order=true}))
            assert(#payload.ledger==2)
            local success,detail=run(Deliver,payload)
            assert(success, detail)
            assert(pantry.c.items[1]==beans and shed.c.items[1]==plank)
            assert(#body.inv.items==1 and body.inv.items[1]==hammer)
        ''')

    def test_deliver_without_room_keeps_cargo_unless_floor_allowed(self):
        self.lua.execute('''
            local pantry=furniture(4,0,{},0); assignAt(4,0,'food',pantry)
            local beans=item('Base.TinnedBeans','Food')
            body.inv.items={beans}
            local payload=assert(Deliver.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Deliver,payload)
            assert(not success and code=='BLOCKED' and body.inv.items[1]==beans, detail)
            payload=assert(Deliver.prepare(body,owner,{explicit_owner_order=true,allow_floor=true}))
            success,detail=run(Deliver,payload)
            assert(success and detail:find('on the base floor'), detail)
            assert(#squareAt(2,2,0).world==1)
        ''')


class StructureRepairTests(LogisticsBase):
    def setUp(self):
        super().setUp()
        self.lua.execute('''
            Repair=require('GoblinSurvivor/GoblinStructureRepair')
            rolls={}
            ZombRand=function(n) return table.remove(rolls,1) or 0 end
            function damagedDoor(x,y,health)
                local sq=squareAt(x,y,0)
                local obj={health=health,max=100,synced=0,square=sq,material='Wood',
                    sprite={getName=function() return 'door_'..x end}}
                function obj:getHealth() return self.health end
                function obj:getMaxHealth() return self.max end
                function obj:setHealth(v) self.health=v end
                function obj:sync() self.synced=self.synced+1 end
                function obj:getObjectIndex() return 0 end
                function obj:getSprite() return self.sprite end
                function obj:getSquare() return self.square end
                sq.objects[#sq.objects+1]=obj
                return obj
            end
            ISMoveableSpriteProps={fromObject=function(object)
                local props={object=object,material='Wood',isMultiSprite=false}
                function props:canRepairObject() return {craftValid=true} end
                function props:getAllRepairParts()
                    return {{itemType='Base.Plank',amount=2,required=true},
                        {itemType='Base.Nails',amount=4,required=false},
                        {itemType='Base.Screws',amount=4,required=false}}
                end
                function props:hasRepairTool() return true end
                function props:hasRepairParts(character)
                    return count(character:getInventory(),'Base.Plank')>=2
                        and count(character:getInventory(),'Base.Nails')>=4
                end
                function props:getRepairActionTime() return 180 end
                function props:getRepairSkillChance() return 60 end
                function props:getAdditionalObjects() return {} end
                return props
            end}
            ISMoveableDefinitions={getInstance=function() return {getRepairDefinition=function()
                return {tools={'Base.Hammer'},tools2={'Base.Saw'}} end} end}
            function stock()
                local items={}
                for _=1,2 do items[#items+1]=item('Base.Plank','MaterialWeapon') end
                for _=1,4 do items[#items+1]=item('Base.Nails','Material') end
                return items
            end
        ''')

    def test_successful_repair_consumes_native_parts_and_restores_health(self):
        self.lua.execute('''
            local door=damagedDoor(1,1,50)
            body.inv.items=stock()
            rolls={10}
            local payload=assert(Repair.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Repair,payload)
            assert(success and code=='COMPLETE' and detail:find('1 repaired'), detail)
            assert(door.health==100 and door.synced==1)
            assert(#body.inv.items==0)
        ''')

    def test_failed_skill_roll_consumes_parts_like_vanilla_and_keeps_damage(self):
        self.lua.execute('''
            local door=damagedDoor(1,1,50)
            body.inv.items=stock()
            rolls={99}
            local payload=assert(Repair.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Repair,payload)
            assert(not success and code=='BLOCKED' and payload.failed==1, detail)
            assert(door.health==50 and #body.inv.items==0)
        ''')

    def test_parts_are_gathered_from_base_storage(self):
        self.lua.execute('''
            local door=damagedDoor(1,1,40)
            local shelf=furniture(3,3,stock())
            rolls={1}
            local payload=assert(Repair.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail=run(Repair,payload)
            assert(success, detail)
            assert(door.health==100 and #shelf.c.items==0 and #body.inv.items==0)
        ''')

    def test_missing_parts_never_mutate_health(self):
        self.lua.execute('''
            local door=damagedDoor(1,1,40)
            body.inv.items={item('Base.Plank','MaterialWeapon')}
            local payload=assert(Repair.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail,code=run(Repair,payload,nil,400)
            assert(not success and code=='MISSING_MATERIAL', tostring(code)..' '..tostring(detail))
            assert(door.health==40 and #body.inv.items==1)
        ''')

    def test_undamaged_or_nearly_destroyed_objects_are_not_targets(self):
        self.lua.execute('''
            damagedDoor(1,1,97); damagedDoor(3,1,10)
            local payload,detail=Repair.prepare(body,owner,{explicit_owner_order=true})
            assert(payload==nil and detail:find('no damaged object'))
        ''')

    def test_smashed_window_glass_is_cleared_natively(self):
        self.lua.execute('''
            local sq=squareAt(4,2,0)
            local window={class='IsoWindow',smashed=true,removed=false,synced=0,
                sprite={getName=function() return 'window' end}}
            function window:isSmashed() return self.smashed end
            function window:isGlassRemoved() return self.removed end
            function window:removeBrokenGlass() self.removed=true end
            function window:sync() self.synced=self.synced+1 end
            function window:getObjectIndex() return 0 end
            function window:getSprite() return self.sprite end
            sq.objects[1]=window
            local payload=assert(Repair.prepare(body,owner,{explicit_owner_order=true}))
            local success,detail=run(Repair,payload)
            assert(success and window.removed and window.synced==1 and payload.glass==1, detail)
        ''')

    def test_permission_revocation_skips_target(self):
        self.lua.execute('''
            local door=damagedDoor(1,1,50)
            body.inv.items=stock()
            local payload=assert(Repair.prepare(body,owner,{explicit_owner_order=true}))
            authorized=false
            local success,detail,code=run(Repair,payload)
            assert(not success and door.health==50 and #body.inv.items==6)
        ''')


if __name__ == "__main__":
    unittest.main()

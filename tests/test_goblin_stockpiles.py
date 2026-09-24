"""Stock threshold fixtures; no physical retrieval or multiplayer claim."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class StockpileTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().lua_root = LUA.as_posix()
        self.lua.execute('''
            package.path=lua_root..'/server/?.lua;'..lua_root..'/shared/?.lua;'..package.path
            function list(items)
                return {size=function() return #items end,
                    get=function(_,i) return items[i+1] end}
            end
            local World={}
            function World.call(object,method,...)
                if not object or type(object[method])~='function' then return false,nil end
                return pcall(object[method],object,...)
            end
            function World.values(items)
                local out={}
                if items then for i=0,items:size()-1 do out[#out+1]=items:get(i) end end
                return out
            end
            function World.square(point)
                if not point then return nil end
                return squares[math.floor(point.x)..':'..math.floor(point.y)..':'..math.floor(point.z)]
            end
            function World.point(square) return {x=square.x+0.5,y=square.y+0.5,z=square.z} end
            function World.items(container) return World.values(container:getItems()) end
            function World.fullType(item) return item:getFullType() end
            package.loaded['GoblinSurvivor/GoblinWorld']=World
            body={owner='horse'}
            owner={getUsername=function() return 'horse' end}
            package.loaded['GoblinSurvivor/GoblinBody']={
                owner=function(b) return b.owner end,isGoblin=function(b) return b==body end,
                position=function() return {x=0.5,y=0.5,z=0} end}
            scope={id='house-a'}
            package.loaded['GoblinSurvivor/GoblinCurtains']={
                scopeAt=function() return scope end,
                belongsToScope=function(_,square) return square and square.inside end}
            authorized=true
            package.loaded['GoblinSurvivor/GoblinAccessPolicy']={
                access=function() return authorized end}
            rules={}
            package.loaded['GoblinSurvivor/GoblinSpawner']={
                baseForOwner=function() return {x=0,y=0,z=0} end,
                stockpileRulesForOwner=function() return rules end,
                setStockpileRuleForOwner=function(_,kind,minimum,target)
                    rules[kind]={item=kind,minimum=minimum,target=target}
                    return true,'stockpile threshold recorded; Base.Nails collection requires a separate explicit stockpile order'
                end}
            ScriptManager={instance={FindItem=function(_,name)
                if name~='Base.Nails' then return nil end
                return {getFullName=function() return name end,getObsolete=function() return false end}
            end}}
            getTimestampMs=function() return 1000 end
            squares={}
            square={x=0,y=0,z=0,inside=true,objects={}}
            function square:getObjects() return list(self.objects) end
            squares['0:0:0']=square
            container={items={}}
            function container:getItems() return list(self.items) end
            object={metadata={},square=square}
            function object:getSquare() return self.square end
            function object:getContainer() return container end
            function object:getSprite() return {getName=function() return 'fixtures_01_0' end} end
            function object:getObjectIndex() return 0 end
            function object:getModData() return self.metadata end
            function object:transmitModData() self.transmitted=(self.transmitted or 0)+1 end
            square.objects[1]=object
            Stockpiles=require('GoblinSurvivor/GoblinStockpiles')
        ''')

    def test_exact_rule_persists_and_counts_only_actual_destination_items(self):
        self.lua.execute('''
            local ok,detail=Stockpiles.assign(body,owner,'Base.Nails','50')
            assert(ok and detail:find('separate explicit stockpile order') and object.transmitted==1)
            assert(type(rules['Base.Nails'].target.id)=='string')
            local report=Stockpiles.scan(scope,body)
            assert(report.status=='MISSING' and report.items[1].shortage==50)
            for i=1,50 do
                container.items[#container.items+1]={getFullType=function() return 'Base.Nails' end}
            end
            container.items[#container.items+1]={getFullType=function() return 'Base.Plank' end}
            report=Stockpiles.scan(scope,body)
            assert(report.status=='OK' and report.items[1].current==50)
            assert(report.items[1].shortage==0)
        ''')

    def test_base_inspection_reports_configured_shortage(self):
        self.lua.execute('''
            assert(Stockpiles.assign(body,owner,'Base.Nails',5))
            scope.rooms={{x=0,y=0,x2=0,y2=0,z=0}}
            local Inspect=require('GoblinSurvivor/GoblinBaseInspect')
            local report=assert(Inspect.scan(scope,body,1000))
            assert(report.missing_supplies.status=='MISSING')
            assert(report.missing_supplies.items[1].item=='Base.Nails')
            assert(report.missing_supplies.items[1].shortage==5)
        ''')

    def test_scan_does_not_require_next_global(self):
        self.lua.execute('''
            assert(Stockpiles.assign(body,owner,'Base.Nails',4))
            next=nil -- Build 42's Kahlua runtime does not expose this Lua 5.1 global.
            local report=Stockpiles.scan(scope,body)
            assert(report.status=='MISSING' and report.items[1].shortage==4)
        ''')

    def test_unknown_target_does_not_become_zero_stock(self):
        self.lua.execute('''
            assert(Stockpiles.assign(body,owner,'Base.Nails',5))
            squares['0:0:0']=nil
            local report=Stockpiles.scan(scope,body)
            assert(report.status=='UNKNOWN' and report.items[1].status=='TARGET_UNLOADED')
            assert(report.items[1].current==nil and report.items[1].shortage==nil)
            squares['0:0:0']=square
            square.objects={}
            report=Stockpiles.scan(scope,body)
            assert(report.status=='UNKNOWN' and report.items[1].status=='TARGET_CHANGED')
        ''')

    def test_unreadable_inventory_is_unknown_not_empty(self):
        self.lua.execute('''
            assert(Stockpiles.assign(body,owner,'Base.Nails',5))
            function container:getItems() error('container unavailable') end
            local report=Stockpiles.scan(scope,body)
            assert(report.status=='UNKNOWN' and report.items[1].status=='TARGET_UNLOADED')
            assert(report.items[1].current==nil and report.items[1].shortage==nil)
        ''')

    def test_partial_item_enumeration_is_unknown_not_a_shortage(self):
        self.lua.execute('''
            assert(Stockpiles.assign(body,owner,'Base.Nails',5))
            function container:getItems()
                return {size=function() return 2 end,
                    get=function(_,index)
                        if index==1 then error('stream changed') end
                        return {getFullType=function() return 'Base.Nails' end}
                    end}
            end
            local report=Stockpiles.scan(scope,body)
            assert(report.status=='UNKNOWN' and report.items[1].status=='TARGET_UNLOADED')
            assert(report.items[1].current==nil and report.items[1].shortage==nil)
        ''')

    def test_invalid_or_unauthorized_rule_never_mutates_container(self):
        self.lua.execute('''
            assert(not Stockpiles.assign(body,owner,'Base.NoSuchItem',5))
            assert(not Stockpiles.assign(body,owner,'Base.Nails',0))
            authorized=false
            assert(not Stockpiles.assign(body,owner,'Base.Nails',5))
            assert(next(rules)==nil and object.metadata.GoblinStorageID==nil)
            authorized=true;object.metadata.GoblinStorageOwner='someone-else'
            assert(not Stockpiles.assign(body,owner,'Base.Nails',5))
            assert(next(rules)==nil)
        ''')


class StockpileWorkTests(unittest.TestCase):
    def setUp(self):
        StockpileTests.setUp(self)
        self.lua.execute('''
            World=package.loaded['GoblinSurvivor/GoblinWorld']
            Body=package.loaded['GoblinSurvivor/GoblinBody']
            body.data={GoblinBaseSet=true,GoblinBaseX=0,GoblinBaseY=0,GoblinBaseZ=0}
            Body.data=function(b) return b.data end
            owner.online=true
            getOnlinePlayers=function() return list(owner.online and {owner} or {}) end
            function makeContainer()
                local result={items={}}
                function result:getItems() return list(self.items) end
                function result:hasRoomFor() return self.full~=true end
                function result:Remove(item)
                    for i,value in ipairs(self.items) do
                        if value==item then table.remove(self.items,i);return end
                    end
                end
                function result:AddItem(item)
                    if self.reject then return nil end
                    self.items[#self.items+1]=item
                    return item
                end
                return result
            end
            container=makeContainer()
            body.inv=makeContainer()
            World.inventory=function(b) return b.inv end
            World.has=function(inv,item)
                for _,value in ipairs(inv.items) do if value==item then return true end end
                return false
            end
            sourceSquare={x=1,y=0,z=0,inside=true}
            squares['1:0:0']=sourceSquare
            sourceContainer=makeContainer()
            supply={getFullType=function() return 'Base.Nails' end,
                getID=function() return 7301 end}
            sourceContainer.items[1]=supply
            sourceObject={square=sourceSquare,getSquare=function() return sourceSquare end}
            source={square=sourceSquare,container=sourceContainer,object=sourceObject,item=supply}
            World.sources=function(_,_,accept)
                if World.has(sourceContainer,supply) and accept(supply) then return {source} end
                return {}
            end
            World.take=function(b,candidate)
                if not World.has(sourceContainer,candidate.item) then return false end
                sourceContainer:Remove(candidate.item)
                b.inv:AddItem(candidate.item)
                return true
            end
            package.loaded['GoblinSurvivor/GoblinTools']={reserved=function(item)
                return item.reserved==true end}
            package.loaded['GoblinSurvivor/Config']={weaponType='Base.Pistol3',
                npcVisualItemType='Goblin.Visual',npcOutfitItems={}}
            package.loaded['GoblinSurvivor/GoblinJobSupport']={
                validPoint=function(p) return p and type(p.x)=='number' end,
                work=function(b,job,square,now,duration)
                    if b.at~=square then b.destination=square;job.readyAt=nil;return false end
                    job.readyAt=job.readyAt or now+duration
                    return now>=job.readyAt
                end}
            removePackets,addPackets=0,0
            sendRemoveItemFromContainer=function() removePackets=removePackets+1 end
            sendAddItemToContainer=function() addPackets=addPackets+1 end
            assert(Stockpiles.assign(body,owner,'Base.Nails',1))
            Work=require('GoblinSurvivor/GoblinStockpileWork')
            payload=assert(Work.prepare(body,owner,{item='Base.Nails',explicit_owner_order=true}))
            runtime={skipped={}}
        ''')

    def test_real_instance_follows_source_to_goblin_to_assigned_container(self):
        self.lua.execute('''
            local oldPrint=print
            local transferLogs={}
            print=function(line)
                if line:find('STOCKPILE_TRANSFER',1,true) then
                    transferLogs[#transferLogs+1]=line
                end
            end
            local done=Work.update(body,payload,runtime,1000)
            assert(not done and body.destination==sourceSquare)
            body.at=sourceSquare
            done=Work.update(body,payload,runtime,2000)
            assert(not done and World.has(sourceContainer,supply))
            done=Work.update(body,payload,runtime,3200)
            assert(not done and not World.has(sourceContainer,supply))
            assert(World.has(body.inv,supply) and not World.has(container,supply))
            body.at=nil
            done=Work.update(body,payload,runtime,3300)
            assert(not done and body.destination==square)
            body.at=square
            done=Work.update(body,payload,runtime,3400)
            assert(not done)
            local success,detail,code
            done,success,detail,code=Work.update(body,payload,runtime,4600)
            assert(done and success and code=='COMPLETE')
            assert(World.has(container,supply) and not World.has(body.inv,supply))
            assert(not World.has(sourceContainer,supply))
            assert(removePackets==0 and addPackets==1)
            assert(Stockpiles.scan(scope,body).items[1].current==1)
            assert(#transferLogs==2)
            assert(transferLogs[1]:find('stage=pickup',1,true)
                and transferLogs[1]:find('item_id=7301',1,true))
            assert(transferLogs[2]:find('stage=deposit',1,true)
                and transferLogs[2]:find('item_id=7301',1,true)
                and transferLogs[2]:find('stock_before=0 stock_after=1',1,true))
            print=oldPrint
        ''')

    def test_missing_supply_reports_shortage_without_fabrication(self):
        self.lua.execute('''
            sourceContainer.items={}
            local done,success,detail,code=Work.update(body,payload,runtime,1000)
            assert(done and not success and code=='MISSING_MATERIAL')
            assert(#body.inv.items==0 and #container.items==0)
        ''')

    def test_present_but_unreachable_supply_reports_no_path(self):
        self.lua.execute('''
            local done=Work.update(body,payload,runtime,1000)
            assert(not done and body.destination==sourceSquare)
            done=Work.update(body,payload,runtime,31001)
            assert(not done and runtime.unreachable and runtime.skipped[supply])
            local finished,success,detail,code=Work.update(body,payload,runtime,31002)
            assert(finished and not success and code=='NO_PATH')
            assert(detail:find('no route',1,true))
            assert(#sourceContainer.items==1 and sourceContainer.items[1]==supply)
            assert(#body.inv.items==0 and #container.items==0)
        ''')

    def test_nearest_source_precedes_scan_order_and_timeout_skips_its_square(self):
        self.lua.execute('''
            local farSquare={x=5,y=0,z=0,inside=true}
            local farItem={getFullType=function() return 'Base.Nails' end}
            local farSource={square=farSquare,container={items={farItem}},
                object={square=farSquare},item=farItem}
            World.sources=function(_,_,accept)
                local out={}
                if accept(farItem) then out[#out+1]=farSource end
                if accept(supply) then out[#out+1]=source end
                return out
            end
            local done=Work.update(body,payload,runtime,1000)
            assert(not done and runtime.source==source)
            done=Work.update(body,payload,runtime,31001)
            assert(not done and runtime.skippedSquares['1:0:0'])
            done=Work.update(body,payload,runtime,31002)
            assert(not done and runtime.source==farSource)
        ''')

    def test_other_tracked_items_are_not_physical_stockpile_targets_yet(self):
        self.lua.execute('''
            local prepared,why=Work.prepare(body,owner,
                {item='Base.Plank',explicit_owner_order=true})
            assert(prepared==nil and why:find('Base.Nails only',1,true))
            assert(#body.inv.items==0 and #container.items==0)
        ''')

    def test_full_or_replaced_destination_retains_carried_item(self):
        self.lua.execute('''
            sourceContainer:Remove(supply);body.inv:AddItem(supply)
            container.full=true;body.at=square
            local done=Work.update(body,payload,runtime,1000)
            assert(not done)
            local success,detail,code
            done,success,detail,code=Work.update(body,payload,runtime,2200)
            assert(done and not success and code=='BLOCKED')
            assert(World.has(body.inv,supply) and not World.has(container,supply))
            container.full=false;object.metadata.GoblinStorageID='replacement'
            done,success,detail,code=Work.update(body,payload,{skipped={}},3000)
            assert(done and not success and code=='TARGET_CHANGED')
            assert(World.has(body.inv,supply))
        ''')

    def test_full_destination_is_refused_before_pickup(self):
        self.lua.execute('''
            container.full=true;body.at=sourceSquare
            assert(not Work.update(body,payload,runtime,1000))
            local done,success,detail,code=Work.update(body,payload,runtime,2200)
            assert(done and not success and code=='BLOCKED')
            assert(World.has(sourceContainer,supply) and not World.has(body.inv,supply))
        ''')

    def test_restart_reconciles_existing_cargo_without_second_pickup(self):
        self.lua.execute('''
            sourceContainer:Remove(supply);body.inv:AddItem(supply)
            body.at=square
            local restarted={skipped={}}
            local done=Work.update(body,payload,restarted,1000)
            assert(not done)
            local success,detail,code
            done,success,detail,code=Work.update(body,payload,restarted,2200)
            assert(done and success and code=='COMPLETE')
            assert(World.has(container,supply) and not World.has(body.inv,supply))
            assert(#container.items==1 and #sourceContainer.items==0)
        ''')

    def test_failed_destination_add_rolls_same_item_back_to_goblin(self):
        self.lua.execute('''
            sourceContainer:Remove(supply);body.inv:AddItem(supply)
            container.reject=true;body.at=square
            assert(not Work.update(body,payload,runtime,1000))
            local done,success,detail,code=Work.update(body,payload,runtime,2200)
            assert(done and not success and code=='ENGINE_ERROR')
            assert(World.has(body.inv,supply) and not World.has(container,supply))
            assert(#body.inv.items==1 and #container.items==0)
        ''')

    def test_pickup_sync_failure_stops_with_retained_cargo(self):
        self.lua.execute('''
            World.take=function(b,candidate)
                sourceContainer:Remove(candidate.item)
                b.inv:AddItem(candidate.item)
                return false
            end
            body.at=sourceSquare
            assert(not Work.update(body,payload,runtime,1000))
            local done,success,detail,code=Work.update(body,payload,runtime,2200)
            assert(done and not success and code=='ENGINE_ERROR')
            assert(World.has(body.inv,supply) and not World.has(sourceContainer,supply))
            assert(not World.has(container,supply))
        ''')

    def test_unreadable_destination_after_add_never_clones_cargo(self):
        self.lua.execute('''
            sourceContainer:Remove(supply);body.inv:AddItem(supply)
            local oldAdd=container.AddItem
            function container:AddItem(item)
                local value=oldAdd(self,item)
                self.unreadable=true
                return value
            end
            local oldItems=container.getItems
            function container:getItems()
                if self.unreadable then error('post-add inventory unreadable') end
                return oldItems(self)
            end
            body.at=square
            assert(not Work.update(body,payload,runtime,1000))
            local done,success,detail,code=Work.update(body,payload,runtime,2200)
            assert(done and not success and code=='ENGINE_ERROR')
            assert(#body.inv.items==0 and #container.items==1 and container.items[1]==supply)
        ''')

    def test_owner_logout_or_source_unload_stops_without_pickup(self):
        self.lua.execute('''
            owner.online=false
            local done,success,detail,code=Work.update(body,payload,runtime,1000)
            assert(done and not success and code=='INTERRUPTED')
            assert(World.has(sourceContainer,supply))
            owner.online=true
            assert(not Work.update(body,payload,{skipped={}},2000))
            body.at=sourceSquare
            local job={skipped={}}
            assert(not Work.update(body,payload,job,3000))
            squares['1:0:0']=nil
            done,success,detail,code=Work.update(body,payload,job,4200)
            assert(done and not success and code=='TARGET_UNLOADED')
            assert(World.has(sourceContainer,supply) and #body.inv.items==0)
        ''')

    def test_registered_job_accepts_anchor_and_returns_structured_state(self):
        self.lua.execute('''
            package.loaded['GoblinSurvivor/GoblinMovement']={clear=function() end}
            for _,name in ipairs({'GoblinFarming','GoblinCrafting','GoblinVehicles',
                'GoblinBaseInspect','GoblinBaseMaintain','GoblinDismantle',
                'GoblinGainAccess'}) do
                package.loaded['GoblinSurvivor/'..name]={prepare=function() end,
                    update=function() return true,false,'stub','UNSUPPORTED' end}
            end
            isServer=function() return true end
            isClient=function() return false end
            Jobs=require('GoblinSurvivor/GoblinJobs')
            local request={item='Base.Nails',explicit_owner_order=true}
            local prepared=assert(Jobs.prepare(body,owner,'STOCKPILE',request))
            assert(prepared.anchor.x==0 and prepared.target_id==payload.target_id)
            local result=Jobs.update(body,'STOCKPILE',prepared,1000)
            assert(not result.done and result.code=='WORKING')
            assert(body.destination==sourceSquare)
        ''')

if __name__ == '__main__':
    unittest.main()

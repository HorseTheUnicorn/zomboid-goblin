-- Fixture for base logistics capabilities. Uses the real GoblinWorld custody
-- code (containsExact/take/reserve) with a small in-memory cell; movement is
-- reduced to "one tick to walk, next tick arrived". No engine claims.
nextId = 1000
sent = {add={}, remove={}}
function list(items)
    return {size=function() return #items end, get=function(_, i) return items[i+1] end}
end
function item(kind, display, opts)
    opts = opts or {}
    nextId = nextId + 1
    local md = {}
    local value = {kind=kind, display=display, id=opts.id or nextId, uses=opts.uses}
    function value:getFullType() return self.kind end
    function value:getDisplayCategory() return self.display end
    function value:getCategory() return opts.legacy or 'Normal' end
    function value:getID() return self.id end
    function value:getModData() return md end
    function value:getCurrentUses() return self.uses end
    function value:Use() self.uses = self.uses - 1 end
    function value:setWorldItem() end
    return value
end
function container(items, capacity, kind)
    local c = {items=items or {}, capacity=capacity or 100, kind=kind or 'crate'}
    function c:getItems() return list(self.items) end
    function c:contains(value)
        for _, v in ipairs(self.items) do if v == value then return true end end
        return false
    end
    function c:hasRoomFor() return #self.items < self.capacity end
    function c:Remove(value)
        for i, v in ipairs(self.items) do if v == value then table.remove(self.items, i); return end end
    end
    c.DoRemoveItem = c.Remove
    function c:AddItem(value)
        if self.reject or #self.items >= self.capacity then return nil end
        self.items[#self.items+1] = value; return value
    end
    function c:getType() return self.kind end
    function c:getCharacter() return self.character end
    return c
end
squares = {}
function squareAt(x, y, z)
    local k = x..':'..y..':'..z
    if not squares[k] then
        local sq = {x=x, y=y, z=z, objects={}, world={}, inside=true}
        function sq:getX() return self.x end
        function sq:getY() return self.y end
        function sq:getZ() return self.z end
        function sq:getObjects() return list(self.objects) end
        function sq:getWorldObjects() return list(self.world) end
        function sq:isBlockedTo() return false end
        function sq:transmitRemoveItemFromSquare(obj)
            for i, v in ipairs(self.world) do if v == obj then table.remove(self.world, i) end end
        end
        function sq:AddWorldInventoryItem(value)
            if self.rejectDrop then return nil end
            local obj = {item=value, square=self}
            function obj:getItem() return self.item end
            function obj:getSquare() return self.square end
            function obj:removeFromWorld() end
            function obj:removeFromSquare() end
            self.world[#self.world+1] = obj
            return value
        end
        squares[k] = sq
    end
    return squares[k]
end
cell = {getGridSquare=function(_, x, y, z) return squareAt(x, y, z) end}
function getCell() return cell end
function furniture(x, y, contents, capacity, kind)
    local sq = squareAt(x, y, 0)
    local obj = {md={}, c=container(contents, capacity, kind), square=sq,
        sprite={getName=function() return 'furniture_'..x..'_'..y end}}
    function obj:getContainer() return self.c end
    function obj:getModData() return self.md end
    function obj:transmitModData() self.transmitted = (self.transmitted or 0) + 1 end
    function obj:getSprite() return self.sprite end
    function obj:getObjectIndex() return 0 end
    function obj:getSquare() return self.square end
    sq.objects[#sq.objects+1] = obj
    return obj
end
function floorItem(x, y, value)
    return squareAt(x, y, 0):AddWorldInventoryItem(value)
end
function sendAddItemToContainer(c, value) sent.add[#sent.add+1] = {c=c, item=value} end
function sendRemoveItemFromContainer(c, value) sent.remove[#sent.remove+1] = {c=c, item=value} end
function instanceof(value, class) return type(value) == 'table' and value.class == class end
isServer = function() return true end
isClient = function() return false end
getTimestampMs = function() return 1000 end
ScriptManager = {instance={FindItem=function(_, name)
    if not known[name] then return nil end
    return {getFullName=function() return name end, getObsolete=function() return false end}
end}}
known = {['Base.Nails']=true, ['Base.Plank']=true, ['Base.TinnedBeans']=true,
    ['Base.Screws']=true, ['Base.Hammer']=true}

-- Goblin and owner.
body = {inv=container({}, 30), data={GoblinBaseSet=true,GoblinBaseX=2,GoblinBaseY=2,GoblinBaseZ=0},
    pos={x=2.5, y=2.5, z=0}}
body.inv.character = body
function body:getInventory() return self.inv end
function body:getPrimaryHandItem() return self.primary end
function body:getSecondaryHandItem() return self.secondary end
function body:setPrimaryHandItem(v) self.primary = v end
function body:setSecondaryHandItem(v) self.secondary = v end
function body:removeFromHands() return true end
owner = {name='horse', online=true, inv=container({}, 50), pos={x=3.5, y=3.5, z=0}}
function owner:getUsername() return self.name end
function owner:getInventory() return self.inv end
function owner:getCurrentSquare() return squareAt(math.floor(self.pos.x), math.floor(self.pos.y), 0) end
getOnlinePlayers = function() return list(owner.online and {owner} or {}) end

config = {weaponType='Base.Machete', npcVisualItemType='Base.Goblin', npcOutfitItems={},
    stuckTimeoutSeconds=5}
package.loaded['GoblinSurvivor/Config'] = config
package.loaded['GoblinSurvivor/GoblinBody'] = {
    owner=function() return 'horse' end, isGoblin=function(b) return b == body end,
    data=function(b) return b.data end,
    position=function(b) return b.pos end, say=function() end,
}
package.loaded['GoblinSurvivor/GoblinMovement'] = {clear=function() end, snapshot=function() end,
    command=function() return true end, update=function() return true end}
package.loaded['GoblinSurvivor/GoblinLocomotion'] = {isBlacklisted=function() return false end,
    distance=function(a, b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end, controls=function() return true end}
authorized = true
package.loaded['GoblinSurvivor/GoblinAccessPolicy'] = {access=function() return authorized end}
reserved = {}
package.loaded['GoblinSurvivor/GoblinTools'] = {
    types={'Base.Hammer','Base.Saw','Base.Screwdriver'},
    reserved=function(value) return reserved[value] == true end,
    ensure=function(_, kind) return kind end}
scope = {id='house-a', rooms={{x=0, y=0, x2=4, y2=4, z=0}}}
package.loaded['GoblinSurvivor/GoblinCurtains'] = {
    scopeAt=function() return scope end,
    belongsToScope=function(_, sq) return sq and sq.inside end}
storageRecords = {}
package.loaded['GoblinSurvivor/GoblinSpawner'] = {
    baseForOwner=function() return {x=2, y=2, z=0} end,
    storageAssignmentsForOwner=function() return storageRecords end,
    setStorageAssignmentForOwner=function(_, record)
        storageRecords[record.id] = record; return true, 'recorded' end,
    clearStorageAssignmentForOwner=function(_, id)
        if not storageRecords[id] then return false end
        storageRecords[id] = nil; return true end}

World = require('GoblinSurvivor/GoblinWorld')
-- Movement: first approach call walks, the next one arrives.
function World.reachable(b, sq)
    return math.abs(math.floor(b.pos.x) - sq:getX()) <= 1 and math.abs(math.floor(b.pos.y) - sq:getY()) <= 1
        and b.pos.z == sq:getZ()
end
function World.approach(b, sq)
    if World.reachable(b, sq) then return true end
    b.pos = {x=sq:getX()+0.5, y=sq:getY()+0.5, z=sq:getZ()}
    return false, 'walking'
end
Storage = require('GoblinSurvivor/GoblinStorage')
Transfer = require('GoblinSurvivor/GoblinTransfer')

function assignAt(x, y, category, obj)
    owner.pos = {x=x+0.5, y=y+0.5, z=0}
    local ok, detail = Storage.assign(body, owner, category)
    assert(ok, detail)
    return obj
end
-- Run a legacy handler until done (bounded).
function run(handler, payload, runtime, limit)
    runtime = runtime or {}
    local clock = 1000
    for _ = 1, limit or 400 do
        clock = clock + 1000
        local done, success, detail, code = handler.update(body, payload, runtime, clock)
        if done then return success, detail, code, runtime end
    end
    error('handler did not finish')
end
function count(c, kind)
    local n = 0
    for _, v in ipairs(c.items) do if not kind or v.kind == kind then n = n + 1 end end
    return n
end

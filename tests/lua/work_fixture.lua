World=require('GoblinSurvivor/GoblinWorld')
Work=require('GoblinSurvivor/GoblinWork')
Loot=require('GoblinSurvivor/GoblinLoot')
function item(kind)
    local md={}
    return {getFullType=function() return kind end,getCategory=function() return 'Item' end,
        getModData=function() return md end}
end
function container(items)
    local inv={items=items or {}}
    function inv:getItems() return list(self.items) end
    function inv:hasRoomFor() return not self.full end
    function inv:Remove(value)
        for i,v in ipairs(self.items) do if v==value then table.remove(self.items,i);break end end
    end
    function inv:AddItem(value)
        if self.reject then return nil end
        if type(value)=='string' then value=item(value) end
        self.items[#self.items+1]=value; return value
    end
    return inv
end
squares={}
function cell:getGridSquare(x,y,z)
    local key=x..':'..y..':'..z
    if not squares[key] then
        local sq={x=x,y=y,z=z,objects={},world={}}
        function sq:getX() return self.x end
        function sq:getY() return self.y end
        function sq:getZ() return self.z end
        function sq:isBlockedTo(other) return self.blocked==true or other.blocked==true end
        function sq:isFree() return not self.occupied end
        function sq:getObjects() return list(self.objects) end
        function sq:getWorldObjects() return list(self.world) end
        function sq:AddWorldInventoryItem(value,x,y,z)
            if self.rejectDrop then return nil end
            local obj={getItem=function() return value end,getSquare=function() return self end}
            function obj:removeFromWorld() end
            function obj:removeFromSquare() end
            self.world[#self.world+1]=obj
            return obj
        end
        function sq:AddSpecialObject(obj) self.objects[#self.objects+1]=obj;obj.index=#self.objects-1 end
        function sq:RecalcAllWithNeighbours() end
        function sq:getWall() return nil end
        function sq:getDoorOrWindow() return nil end
        squares[key]=sq
    end
    return squares[key]
end
Body.say=function(a,text) a.speech=text;return true end
Body.setCombatPose=function(a,active) a.aiming=active end
Body.faceTarget=function() end
a=actor(0.5,0.5,0)
a.data={GoblinNPC=true,GoblinOwner='horse',GoblinID='goblin.primary.horse',GoblinBaseSet=true,GoblinBaseX=0,GoblinBaseY=0,GoblinBaseZ=0}
a.inv=container()
function a:getInventory() return self.inv end
function a:setPrimaryHandItem(value) self.hand=value end
function a:setSecondaryHandItem(value) end
sendRemoveItemFromContainer=function() end
sendAddItemToContainer=function() end
IsoObjectChange={STATE='state'}
instanceof=function(obj,kind) return obj.kind==kind end
IsoThumpable={new=function(cell,sq,sprite,north,md)
    local obj={square=sq,sprite=sprite,index=-1}
    for _,name in ipairs({'setName','setMaxHealth','setHealth','setIsThumpable','setIsDismantable',
        'setBreakSound','setIsContainer','setBlockAllTheSquare','setIsHoppable','setCanBarricade','transmitCompleteItemToClients'}) do
        obj[name]=function() end
    end
    function obj:getObjectIndex() return self.index end
    return obj
end}
function window(sq)
    local obj={kind='IsoWindow',square=sq}
    function obj:getSquare() return self.square end
    function obj:getBarricadeForCharacter() return self.barr end
    sq.objects[#sq.objects+1]=obj
    return obj
end
IsoBarricade={AddBarricadeToObject=function(obj)
    local b={planks=0}
    function b:getNumPlanks() return self.planks end
    function b:addPlank() self.planks=self.planks+1 end
    function b:transmitCompleteItemToClients() end
    function b:sendObjectChange() end
    obj.barr=b
    return b
end}
function supplies(planks,nails)
    require('GoblinSurvivor/GoblinTools').ensure(a,'Base.Hammer')
    for i=1,planks do a.inv:AddItem('Base.Plank') end
    for i=1,nails do a.inv:AddItem('Base.Nails') end
end

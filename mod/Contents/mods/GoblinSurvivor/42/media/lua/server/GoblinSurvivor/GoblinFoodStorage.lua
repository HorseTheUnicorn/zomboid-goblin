-- Internal food-cycle capability. Reuse the established build/material path,
-- verify the new native crate, then persist its FOOD assignment. Never mint
-- food, overwrite furniture or take over the owner's existing containers.
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Work=require("GoblinSurvivor/GoblinWork")
local Storage=require("GoblinSurvivor/GoblinStorage")
local Curtains=require("GoblinSurvivor/GoblinCurtains")
local Policy=require("GoblinSurvivor/GoblinAccessPolicy")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local FoodStorage={}
local call=World.call
local function value(object,method,...)
    local ok,result=call(object,method,...)
    if ok then return result end
end
local function crate(body,square)
    for _,object in ipairs(World.values(value(square,"getObjects"))) do
        local metadata=value(object,"getModData")
        if type(metadata)=="table" and metadata.GoblinBuilt==true
            and metadata.GoblinOwner==Body.owner(body) and metadata.GoblinFoodCrate==true
            and value(object,"getContainer") then return object end
    end
end
local function buildable(body,scope,square)
    if not square or not Curtains.belongsToScope(scope,square)
        or value(square,"isFree",false)~=true or value(square,"haveFire")~=false
        or not Policy.access(body,{getSquare=function() return square end}) then return false end
    local movingOK,moving=call(square,"getMovingObjects")
    if not movingOK or #World.values(moving)>0 then return false end
    -- Leave both sides of nearby door/window edges clear.
    for dx=-1,1 do for dy=-1,1 do
        local adjacent=World.square({x=square:getX()+dx,y=square:getY()+dy,z=square:getZ()})
        for _,north in ipairs({true,false}) do
            local ok,edge=call(adjacent,"getDoorOrWindow",north)
            if not ok or edge then return false end
        end
    end end
    return World.approachCandidate(body,square,type(getTimestampMs)=="function" and getTimestampMs() or 0,false)~=nil
end
function FoodStorage.prepare(body,owner,request)
    if not owner or not request or request.food_cycle~=true then return nil,"internal online food-cycle work only" end
    local home=Support.anchor(body,owner,true)
    local scope,why=Curtains.scopeAt(home)
    if not scope then return nil,why end
    local candidates,seen={},{}
    for _,room in ipairs(scope.rooms) do
        if room.z==math.floor(home.z) then
            for x=math.max(room.x,math.floor(home.x)-12),math.min(room.x2,math.floor(home.x)+12) do
                for y=math.max(room.y,math.floor(home.y)-12),math.min(room.y2,math.floor(home.y)+12) do
                    local k=x..":"..y
                    if not seen[k] then
                        seen[k]=true
                        local square=World.square({x=x,y=y,z=room.z})
                        local existing=crate(body,square)
                        if existing or buildable(body,scope,square) then
                            candidates[#candidates+1]={x=x,y=y,z=room.z,
                                distance=(x-home.x)^2+(y-home.y)^2,reuse=existing~=nil}
                        end
                    end
                end
            end
        end
    end
    table.sort(candidates,function(a,b)
        if a.reuse~=b.reuse then return a.reuse end
        return a.distance<b.distance
    end)
    local target=candidates[1]
    if not target then return nil,"no safe reachable place for a food crate inside the base" end
    return {anchor=home,scope_id=scope.id,x=target.x,y=target.y,z=target.z,
        kind="crate",food_cycle=true,food_crate=true,completed=0}
end
function FoodStorage.clear(body) Work.clear(body) end
function FoodStorage.update(body,payload,runtime,now)
    local scope=Curtains.scopeAt(payload.anchor)
    local square=World.square(payload)
    if not scope or scope.id~=payload.scope_id or not square then
        return true,false,"food crate site unloaded","TARGET_UNLOADED"
    end
    local object=crate(body,square)
    if not object then
        if not buildable(body,scope,square) then return true,false,"food crate site obstructed","BLOCKED" end
        Support.status(body,"building a food storage crate")
        if not Work.update(body,"BUILD",payload,now) then return false end
        object=crate(body,square)
        if not object then return true,false,"crate construction was not verified","ENGINE_ERROR" end
    end
    if not World.approach(body,square,now) then return false end
    local ok,why=Storage.assignBuiltFood(body,scope,object)
    if not ok then return true,false,why,"TARGET_CHANGED" end
    local live,failures=Storage.assignments(body,scope)
    local metadata=value(object,"getModData")
    for _,target in ipairs(live or {}) do
        if target.id==metadata.GoblinStorageID and target.object==object and target.category=="FOOD"
            and #(failures or {})==0 then
            payload.completed=1
            print("[GoblinSurvivor] FOOD_STORAGE_CREATED owner="..Body.owner(body).." id="..target.id)
            return true,true,"food crate built and assignment verified","COMPLETE"
        end
    end
    return true,false,"food crate assignment could not be verified","TARGET_CHANGED"
end
return FoodStorage

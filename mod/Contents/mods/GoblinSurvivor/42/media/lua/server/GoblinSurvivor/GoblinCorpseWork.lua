-- Native Build 42 corpse dragging. Never remove, clone, burn or teleport bodies.
-- Native pickup changes IsoDeadBody into a grapple-only IsoZombie; native drop
-- creates a new IsoDeadBody. Custody is verified by original inventory identity
-- and item IDs, not by pretending the old world-object ID survives that cycle.
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local Curtains=require("GoblinSurvivor/GoblinCurtains")
local Policy=require("GoblinSurvivor/GoblinAccessPolicy")
local Config=require("GoblinSurvivor/Config")
local Corpse={}
local call=World.call
local MAX_SQUARES,MAX_BODIES=2048,20

local function value(object,method,...)
    local ok,result=call(object,method,...)
    if ok then return result end
    return nil
end
local function methods(body)
    for _,name in ipairs({"pickUpCorpse","isDraggingCorpse","getGrapplingTarget","LetGoOfGrappled"}) do
        local ok,member=pcall(function() return body[name] end)
        if not ok or type(member)~="function" then return false end
    end
    return true
end
local function key(corpse)
    local id=value(corpse,"getObjectIDAsLong")
    if type(id)~="number" or id<0 or id>9007199254740991 then return nil end
    return string.format("%.0f",id)
end
local function signature(container)
    if not container then return nil end
    local ids={}
    for _,item in ipairs(World.items(container)) do
        local id=value(item,"getID")
        if type(id)~="number" or #ids>=64 then return nil end
        ids[#ids+1]=tostring(id)..":"..tostring(value(item,"getFullType"))
    end
    table.sort(ids)
    return table.concat(ids,"|")
end
local function safeSquare(body,square)
    return square and Policy.access(body,{getSquare=function() return square end})==true
end
local function outside(body,p)
    local square=World.square(p)
    return square and value(square,"isOutside")==true
        and value(square,"isFree",false)==true and value(square,"haveFire")==false
        and safeSquare(body,square) and square or nil
end
local function area(scope)
    local seen,points={},{}
    for _,room in ipairs(scope.rooms) do
        for x=room.x,room.x2 do for y=room.y,room.y2 do
            local k=x..":"..y..":"..room.z
            if not seen[k] then
                seen[k]=true;points[#points+1]={x=x,y=y,z=room.z}
                if #points>MAX_SQUARES then return nil end
            end
        end end
    end
    return points
end
local function pile(body,scope)
    local data=Body.data(body)
    local saved=data.GoblinCorpsePile
    if type(saved)=="table" and saved.scope_id==scope.id and outside(body,saved) then return saved end
    local b=scope.bounds
    if b.min_z~=0 then return nil end
    local here=Body.position(body)
    local candidates={}
    -- Keep the pile away from the house perimeter/doorway, on loaded ground.
    for x=b.x-3,b.x2+3 do for y=b.y-3,b.y2+3 do
        if x==b.x-3 or x==b.x2+3 or y==b.y-3 or y==b.y2+3 then
            local p={x=x,y=y,z=0,scope_id=scope.id}
            if outside(body,p) then
                p.distance=(x-here.x)^2+(y-here.y)^2;candidates[#candidates+1]=p
            end
        end
    end end
    table.sort(candidates,function(a,b) return a.distance<b.distance end)
    local p=candidates[1]
    if p then p.distance=nil;data.GoblinCorpsePile=p end
    return p
end
local function scan(body,scope)
    local points=area(scope)
    if not points then return nil,"house exceeds the corpse scan bound" end
    local targets,partial={},scope.partiallyStreamed==true
    for _,point in ipairs(points) do
        local square=World.square(point)
        if not square then partial=true
        elseif Curtains.belongsToScope(scope,square) then
            for _,corpse in ipairs(World.values(value(square,"getDeadBodys"))) do
                local id=key(corpse)
                -- Player remains and animals are deliberately excluded.
                if id and value(corpse,"isZombie")==true and value(corpse,"isAnimal")==false then
                    if #targets>=MAX_BODIES then partial=true
                    elseif safeSquare(body,square) then
                        targets[#targets+1]={id=id,x=point.x,y=point.y,z=point.z}
                    else partial=true end
                end
            end
        end
    end
    return targets,partial
end
local function find(target)
    local square=World.square(target)
    for _,corpse in ipairs(World.values(value(square,"getDeadBodys"))) do
        if key(corpse)==target.id then return corpse,square end
    end
end
local function dragging(body)
    if value(body,"isDraggingCorpse")~=true then return nil end
    return value(body,"getGrapplingTarget")
end
local function syncDrag(body,carried,now)
    local link
    if carried then
        link={id=value(carried,"getOnlineID"),outfit=value(carried,"getPersistentOutfitID"),
            expires=now+5000,kind=value(body,"getSharedGrappleType")}
    end
    Body.data(body).GoblinCorpseDrag=link
    -- Zombie packets do not carry the IsoPlayer's grapple relationship. Send
    -- the verified native pair through the same server-only roster as seats.
    local ok,spawner=pcall(require,"GoblinSurvivor/GoblinSpawner")
    if ok and type(spawner.syncClientState)=="function" then
        local sent,why=pcall(spawner.syncClientState,true)
        if not sent then print("[GoblinSurvivor] CORPSE_LINK_FAILED detail="..tostring(why)) end
    end
end
local function dropped(body,payload,runtime)
    -- Drop animations can place the body slightly behind the actor.
    for x=payload.pile.x-2,payload.pile.x+2 do for y=payload.pile.y-2,payload.pile.y+2 do
        local square=World.square({x=x,y=y,z=payload.pile.z})
        if square and value(square,"isOutside")==true then
            for _,corpse in ipairs(World.values(value(square,"getDeadBodys"))) do
                if value(corpse,"getCharacterOnlineID")==payload.drag_id then
                    local container=value(corpse,"getContainer")
                    if signature(container)==payload.contents
                        and (not runtime.container or container==runtime.container) then return corpse end
                end
            end
        end
    end end
end

function Corpse.prepare(body,owner,request)
    if Config.corpseCleanupEnabled~=true then
        return nil,"native corpse cleanup is awaiting local managed-actor validation"
    end
    if not owner or not request or request.explicit_owner_order~=true then
        return nil,"corpse cleanup needs your explicit order while you are online"
    end
    if not methods(body) then return nil,"this actor lacks native corpse dragging support" end
    if dragging(body) then return nil,"finish dropping the current body first" end
    local anchor=Support.anchor(body,owner,true)
    local scope,why=Curtains.scopeAt(anchor)
    if not scope then return nil,why end
    local targets,partial=scan(body,scope)
    if not targets then return nil,partial end
    if #targets==0 then return nil,"no eligible zombie corpses in the loaded house" end
    local destination=pile(body,scope)
    if not destination then return nil,"no safe loaded outside ground for the corpse pile" end
    -- Native stairs/fence traversal while dragging still requires validation.
    for _,target in ipairs(targets) do
        if target.z~=destination.z then return nil,"corpse cleanup across floors is not validated yet" end
    end
    return {anchor=anchor,scope_id=scope.id,targets=targets,pile=destination,
        index=1,completed=0,phase="approach",partial=partial}
end

function Corpse.clear(body)
    -- IsoZombie cannot enter PlayerDraggingCorpse (native IsoPlayer cast).
    -- Release through the underlying native lifecycle, which creates the body
    -- and sends its world packets; never manufacture or reposition a corpse.
    if dragging(body) then call(body,"LetGoOfGrappled","Released") end
    if Body.data(body).GoblinCorpseDrag then syncDrag(body,nil) end
    Body.data(body).GoblinAction=""
end
local function failed(body,detail,code)
    Corpse.clear(body)
    return true,false,detail,code
end
function Corpse.update(body,payload,runtime,now)
    local scope=Curtains.scopeAt(payload.anchor)
    if not scope or scope.id~=payload.scope_id then return failed(body,"house is no longer loaded","TARGET_UNLOADED") end
    local destination=outside(body,payload.pile)
    if not destination then return failed(body,"outside pile is no longer safe","TARGET_CHANGED") end
    local target=payload.targets[payload.index]
    if not target then
        if payload.partial then return failed(body,"moved "..payload.completed.." bodies; house scan was partial","TARGET_UNLOADED") end
        Support.status(body,"piled "..payload.completed.." corpses outside")
        return true,true,"verified corpse pile", "COMPLETE"
    end
    payload.started_at=payload.started_at or now
    if now-payload.started_at>60000 then return failed(body,"corpse route or native dragging timed out","NO_PATH") end
    if payload.phase=="approach" then
        local corpse,square=find(target)
        if not corpse or not Curtains.belongsToScope(scope,square) or not safeSquare(body,square) then
            return failed(body,"corpse moved, disappeared or is no longer authorized","TARGET_CHANGED")
        end
        if not World.approach(body,square,now) then Support.status(body,"going to a corpse");return false end
        if value(value(body,"getSquare"),"canReachTo",square)~=true then return false end
        runtime.container=value(corpse,"getContainer")
        payload.contents=signature(runtime.container)
        if not payload.contents then return failed(body,"cannot verify corpse contents","UNSUPPORTED") end
        payload.phase="pickup";payload.phase_at=now
        if not call(body,"pickUpCorpse",corpse,"BwdDrag") then
            return failed(body,"native corpse pickup failed","ENGINE_ERROR")
        end
    end
    if payload.phase=="pickup" then
        local carried=dragging(body)
        if not carried then
            if now-payload.phase_at>5000 then return failed(body,"native actor did not establish corpse custody","UNSUPPORTED") end
            return false
        end
        local inventory=value(carried,"getInventory")
        if inventory~=runtime.container or signature(inventory)~=payload.contents then
            return failed(body,"native pickup did not preserve original corpse inventory","TARGET_CHANGED")
        end
        payload.drag_id=value(carried,"getOnlineID")
        if type(payload.drag_id)~="number" or payload.drag_id<0 then return failed(body,"dragged corpse has no network identity","UNSUPPORTED") end
        payload.phase="carry"
        runtime.carried=carried
        syncDrag(body,carried,now);runtime.link_at=now
        print("[GoblinSurvivor] CORPSE_PICKUP owner="..Body.owner(body).." source="..target.id.." drag_id="..payload.drag_id
            .." kind="..tostring(value(body,"getSharedGrappleType"))
            .." outfit="..tostring(value(carried,"getPersistentOutfitID")))
    end
    if payload.phase=="carry" then
        local carried=dragging(body)
        if not carried or value(carried,"getOnlineID")~=payload.drag_id
            or signature(value(carried,"getInventory"))~=payload.contents then
            local raw=value(body,"getGrapplingTarget")
            local held=runtime.carried
            print("[GoblinSurvivor] CORPSE_CUSTODY_LOST owner="..Body.owner(body)
                .." expected="..tostring(payload.drag_id).." actual="..tostring(value(raw,"getOnlineID"))
                .." dragging="..tostring(value(body,"isDraggingCorpse"))
                .." contents_same="..tostring(raw and signature(value(raw,"getInventory"))==payload.contents)
                .." actor_state="..tostring(value(body,"getCurrentStateName"))
                .." actor_result="..tostring(value(body,"getGrappleResult"))
                .." corpse_result="..tostring(value(held,"getGrappleResult"))
                .." corpse_dead="..tostring(value(held,"isDead")))
            return failed(body,"corpse custody changed before reaching the pile","TARGET_CHANGED")
        end
        runtime.container=runtime.container or value(carried,"getInventory")
        if now-(runtime.link_at or 0)>=1000 then syncDrag(body,carried,now);runtime.link_at=now end
        Support.status(body,"dragging corpse outside")
        if not World.approach(body,destination,now) then return false end
        local current=value(body,"getSquare")
        if value(current,"isOutside")~=true then return false end
        payload.phase="drop";payload.phase_at=now
        syncDrag(body,nil)
        if not call(body,"LetGoOfGrappled","Released") then return failed(body,"native drop is unavailable","UNSUPPORTED") end
    end
    if payload.phase=="drop" then
        if dragging(body) then
            if now-payload.phase_at>10000 then return failed(body,"native drop animation did not release the body","UNSUPPORTED") end
            return false
        end
        local corpse=dropped(body,payload,runtime)
        if not corpse then
            if now-payload.phase_at>10000 then return failed(body,"cannot verify original corpse outside","TARGET_CHANGED") end
            return false
        end
        payload.completed=payload.completed+1
        print("[GoblinSurvivor] CORPSE_PILED owner="..Body.owner(body).." original="..target.id.." dropped="..tostring(key(corpse)).." contents_preserved=true")
        payload.index=payload.index+1;payload.phase="approach";payload.started_at=nil
        payload.contents=nil;payload.drag_id=nil;runtime.container=nil;runtime.carried=nil
    end
    return false
end
return Corpse

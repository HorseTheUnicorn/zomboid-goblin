-- High-level least-destructive access capability. Persistent payloads contain
-- only primitive target descriptors; engine objects are re-resolved at each
-- update before any mutation.
local Body=require("GoblinSurvivor/GoblinBody")
local Access=require("GoblinSurvivor/GoblinAccess")
local Transport=require("GoblinSurvivor/GoblinTransport")
local Movement=require("GoblinSurvivor/GoblinMovement")

local GainAccess={}
local kinds={BUILDING=true,ROOM=true,YARD=true,VEHICLE=true,CONTAINER=true}
local kindAliases={NEARBY_BUILDING="BUILDING",BASE="BUILDING",CURRENT_POSITION="ROOM",AREA="YARD"}
local routeFields={"access_method","edge","window","breach","started_at","priority","score"}

local function nowMs()
    return type(getTimestampMs)=="function" and getTimestampMs() or 0
end

local function failureCode(detail)
    local text=string.lower(tostring(detail or ""))
    if string.find(text,"no matching key",1,true) or string.find(text,"locked",1,true) then return "LOCKED" end
    if string.find(text,"no longer loaded",1,true) or string.find(text,"area to load",1,true) then
        return "TARGET_UNLOADED"
    end
    if string.find(text,"permission",1,true) or string.find(text,"safehouse",1,true) then
        return "PERMISSION_DENIED"
    end
    if string.find(text,"unsupported",1,true) then return "UNSUPPORTED" end
    if string.find(text,"reach",1,true) or string.find(text,"path",1,true) then return "NO_PATH" end
    return "BLOCKED"
end

local function copyRoute(route,kind,method,request)
    return {
        anchor=request.anchor,target_kind=kind,access_method=method,
        edge=route.edge,window=route.window==true,breach=route.breach==true,
        started_at=route.started_at,priority=route.priority,score=route.score,
        allow_breach=request.allow_breach==true,autonomous=request.autonomous==true,
        offline=request.offline==true
    }
end

local function edgeSide(point,edge)
    if not point or type(edge)~="table" or math.floor(point.z)~=edge.z then return nil end
    local x,y=math.floor(point.x),math.floor(point.y)
    if x==edge.x and y==edge.y then return 1 end
    if x==edge.x+edge.dx and y==edge.y+edge.dy then return 2 end
    return nil
end

local function crossOpenedEdge(body,payload,runtime,now)
    local edge=payload and payload.edge
    if type(edge)~="table" then return true,false,"saved access edge is invalid","TARGET_CHANGED" end
    local point=Body.position(body)
    if not point then return true,false,"Goblin position is unavailable","TARGET_UNLOADED" end
    local side=edgeSide(point,edge)
    if not runtime.cross_from then
        -- A least-destructive selector may legitimately choose an already-open
        -- perimeter door some distance from the actor. Opening work therefore
        -- has no adjacency phase to inherit. Approach one exact side before
        -- beginning the observed-crossing phase instead of falsely reporting
        -- TARGET_CHANGED or accepting an unobserved traversal.
        if not side then
            runtime.cross_approach_started_at=runtime.cross_approach_started_at or now
            if now-runtime.cross_approach_started_at>30000 then
                Movement.clear(body)
                return true,false,"could not reach the open access edge","NO_PATH"
            end
            local a={x=edge.x+0.5,y=edge.y+0.5,z=edge.z,radius=0.25,
                approach_type="gain_access",goal_key="access-approach:"..edge.x..":"..edge.y..":"..edge.z}
            local b={x=a.x+edge.dx,y=a.y+edge.dy,z=edge.z,radius=0.25,
                approach_type=a.approach_type,goal_key=a.goal_key}
            local da=(point.x-a.x)^2+(point.y-a.y)^2
            local db=(point.x-b.x)^2+(point.y-b.y)^2
            local target=da<=db and a or b
            local active=Movement.active[body]
            if not active or active.payload.x~=target.x or active.payload.y~=target.y then
                Movement.command(body,"MOVE_TO",target)
            else Movement.update(body,now) end
            return false,true,"walking to the open access edge","MOVING_TO_TARGET"
        end
        runtime.cross_from=side
        runtime.cross_started_at=now
    elseif side and side~=runtime.cross_from then
        Movement.clear(body)
        return true,true,"crossed the "..string.lower(tostring(payload.target_kind or "access target")),"COMPLETE"
    end
    if now-(runtime.cross_started_at or now)>30000 then
        Movement.clear(body)
        return true,false,"opened the obstruction but could not physically cross it","NO_PATH"
    end
    local target={x=edge.x+0.5,y=edge.y+0.5,z=edge.z,radius=0.25,
        approach_type="gain_access",goal_key="access:"..edge.x..":"..edge.y..":"..edge.z}
    if runtime.cross_from==1 then target.x=target.x+edge.dx;target.y=target.y+edge.dy end
    local active=Movement.active[body]
    if not active or active.payload.x~=target.x or active.payload.y~=target.y then
        Movement.command(body,"MOVE_TO",target)
    else
        Movement.update(body,now)
    end
    return false,true,"crossing the opened access edge","MOVING_TO_TARGET"
end

function GainAccess.prepare(body,owner,payload)
    if not Body.isGoblin(body) or not owner then return nil,"owner must be present for access work" end
    payload=type(payload)=="table" and payload or {}
    local target=type(payload.target)=="table" and payload.target or {}
    local kind=string.upper(tostring(target.kind or payload.kind or "BUILDING"))
    kind=kindAliases[kind] or kind
    if not kinds[kind] then return nil,"choose building, room, yard, vehicle, or container" end
    local point=Body.position(owner)
    if not point then return nil,"owner location is unavailable" end
    local preparedAt=nowMs()
    local request={anchor={x=point.x,y=point.y,z=point.z},allow_breach=payload.allow_breach==true,
        autonomous=payload.autonomous==true,offline=payload.offline==true}
    if kind=="CONTAINER" then
        return nil,"container access is unsupported until a native lock implementation is verified"
    end
    if kind=="VEHICLE" then
        local route,detail=Transport.prepare(body,owner,"ENTER_VEHICLE",preparedAt)
        if not route then return nil,detail end
        route.anchor=request.anchor;route.target_kind=kind;route.access_method="VEHICLE"
        route.allow_breach=request.allow_breach;route.autonomous=request.autonomous
        return route,detail
    end
    local scope,scopeDetail=Access.resolveTargetScope(owner,kind)
    if not scope then return nil,scopeDetail end
    scope.include_open=true
    scope.actor=body
    scope.all_routes=true
    local candidates={}
    local breachRoute
    local _,_,doors=Access.prepare(owner,false,preparedAt,scope)
    for _,door in ipairs(doors or {}) do
        candidates[#candidates+1]=copyRoute(door,kind,"DOOR",request)
    end
    if kind~="YARD" then
        local _,_,windows=Access.prepare(owner,true,preparedAt,scope)
        for _,window in ipairs(windows or {}) do
            candidates[#candidates+1]=copyRoute(window,kind,"WINDOW",request)
        end
    end
    if kind=="YARD" then
        local fence=Access.prepareFence(owner,preparedAt,scope)
        if fence then candidates[#candidates+1]=copyRoute(fence,kind,"FENCE",request) end
    end
    if request.allow_breach and kind~="YARD" then
        local breach=Access.prepareBreachWindow(owner,preparedAt,scope)
        if breach then
            breachRoute=copyRoute(breach,kind,"BREACH_WINDOW",request)
            candidates[#candidates+1]=breachRoute
        end
    end
    table.sort(candidates,function(a,b)
        local ap,bp=a.priority or 99,b.priority or 99
        if ap~=bp then return ap<bp end
        return (a.score or ap*100000)<(b.score or bp*100000)
    end)
    if #candidates>16 then
        for index=#candidates,17,-1 do table.remove(candidates,index) end
        -- Explicitly authorized breach remains a last resort even when many
        -- ordinary entrances exist, while the persisted route set stays small.
        if breachRoute and candidates[16]~=breachRoute then candidates[16]=breachRoute end
    end
    local selected=candidates[1]
    if not selected then return nil,"no supported access route is loaded in the target scope" end
    -- Preserve only the already-authorized primitive route descriptors. A
    -- nearby open door can be less destructive yet unreachable from this side
    -- of a yard; failing that route must not discard a viable low fence.
    selected.alternates={}
    for index=2,#candidates do
        local alternate={}
        for _,field in ipairs(routeFields) do alternate[field]=candidates[index][field] end
        selected.alternates[#selected.alternates+1]=alternate
    end
    return selected,"using least-destructive access method "..string.lower(selected.access_method)
end

local recoverable={NO_PATH=true,TARGET_UNLOADED=true,LOCKED=true,BLOCKED=true}
local runtimeFields={"access_opened","cross_from","cross_approach_started_at","cross_started_at",
    "fence_from","fence_at","access_approach_edge","access_approach_side",
    "access_approach_switched","access_approach_best","access_approach_progress_at",
    "fence_approach_edge","fence_approach_started_at","fence_approach_side",
    "fence_approach_switched","fence_approach_best","fence_approach_progress_at"}

local function tryAlternate(body,payload,runtime,now,done,success,detail,code)
    if not done or success or not recoverable[code] or payload.access_method=="BREACH_WINDOW"
        or type(payload.alternates)~="table" or #payload.alternates==0 then
        return done,success,detail,code
    end
    local nextRoute=table.remove(payload.alternates,1)
    if type(nextRoute)~="table" or type(nextRoute.access_method)~="string" then
        return true,false,"saved alternate access route is invalid","TARGET_CHANGED"
    end
    local previous=payload.access_method
    for _,field in ipairs(routeFields) do payload[field]=nextRoute[field] end
    payload.started_at=now
    for _,field in ipairs(runtimeFields) do runtime[field]=nil end
    Access.clearApproach(body)
    Movement.clear(body)
    print("[GoblinSurvivor] ACCESS_ROUTE_FALLBACK owner="..tostring(Body.owner(body))
        .." from="..previous.." to="..payload.access_method.." reason="..code)
    return false,true,"trying alternate "..string.lower(payload.access_method).." route","MOVING_TO_TARGET"
end

function GainAccess.update(body,payload,runtime,now)
    local method=payload and payload.access_method
    if method=="VEHICLE" then
        local done,success,detail=Transport.board(body,payload,now)
        if not done then
            local code=success==false and "WAITING_FOR_TARGET" or "MOVING_TO_TARGET"
            return false,success~=false,detail,code
        end
        return true,success,detail,success and "COMPLETE" or failureCode(detail)
    end
    if method=="DOOR" or method=="WINDOW" then
        if runtime.access_opened==true then
            return tryAlternate(body,payload,runtime,now,crossOpenedEdge(body,payload,runtime,now))
        end
        local done,success,detail=Access.perform(body,payload,now,runtime)
        if not done then return false,success,detail,"MOVING_TO_TARGET" end
        if not success then
            return tryAlternate(body,payload,runtime,now,true,false,detail,failureCode(detail))
        end
        runtime.access_opened=true
        return tryAlternate(body,payload,runtime,now,crossOpenedEdge(body,payload,runtime,now))
    end
    if method=="FENCE" then
        return tryAlternate(body,payload,runtime,now,Access.performFence(body,payload,runtime,now))
    end
    if method=="BREACH_WINDOW" then
        if runtime.access_opened==true then return crossOpenedEdge(body,payload,runtime,now) end
        local done,success,detail,code=Access.performBreachWindow(body,payload,runtime,now)
        if not done then return done,success,detail,code end
        if not success then return done,success,detail,code end
        runtime.access_opened=true
        return crossOpenedEdge(body,payload,runtime,now)
    end
    return true,false,"saved access method is unsupported","UNSUPPORTED"
end

function GainAccess.clear(body) Access.clearApproach(body);Movement.clear(body) end

return GainAccess

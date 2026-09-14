-- The server chooses destinations. Only the engine's current simulation owner
-- issues native path commands; other peers render replicated motion.
local Config = require("GoblinSurvivor/Config")
local Hands = require("GoblinSurvivor/GoblinHands")
local Motion = { paths = setmetatable({}, { __mode = "k" }) }
local rejoined = setmetatable({}, {__mode="k"})
local followGoals = setmetatable({}, { __mode = "k" })

-- Far FOLLOW uses the engine's moving-character goal instead of repeatedly
-- chasing the owner's last X/Y. Once close, ordinary location pathing keeps
-- the existing three-tile bodyguard spacing and chair-rest clearance behavior.
Motion.characterPathDistance = 6.0

local function call(object, method, ...)
    if object == nil then return false, nil end
    local ok, member=pcall(function() return object[method] end)
    if not ok or type(member)~="function" then return false, nil end
    return pcall(member, object, ...)
end

function Motion.controls(body)
    if type(isClient) == "function" and isClient() then
        local ok, remote = call(body, "isRemoteZombie")
        return ok and remote == false
    end
    if type(isServer) == "function" and isServer() then
        local ok, owner = call(body, "getOwner")
        return ok and owner == nil
    end
    return true
end

function Motion.position(body)
    local _, x = call(body, "getX")
    local _, y = call(body, "getY")
    local _, z = call(body, "getZ")
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { x = x, y = y, z = z }
end

function Motion.distance(a, b)
    if not a or not b then return math.huge end
    return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2)
end

local function clearanceGoal(actor,leader)
    if type(getCell)~="function" then return nil end
    local cell=getCell()
    local best,score
    -- Chair resting treats a visible zombie on a neighboring tile as a threat.
    -- Move outside that tile ring without changing any player threat checks.
    for dx=-4,4 do for dy=-4,4 do
        if math.max(math.abs(dx),math.abs(dy))>=2 then
            local x,y=math.floor(leader.x)+dx+0.5,math.floor(leader.y)+dy+0.5
            local radius=(x-leader.x)^2+(y-leader.y)^2
            local outward=(x-leader.x)*(actor.x-leader.x)+(y-leader.y)*(actor.y-leader.y)
            if radius>=3.2^2 and radius<=4.5^2 and outward>=0 then
                local _,square=call(cell,"getGridSquare",math.floor(x),math.floor(y),math.floor(leader.z))
                local _,free=call(square,"isFree",false)
                local distance=(x-actor.x)^2+(y-actor.y)^2
                if free==true and (not score or distance<score) then
                    best,score={x=x,y=y,z=leader.z},distance
                end
            end
        end
    end end
    return best
end

function Motion.followGoal(body, owner)
    local _, dead = call(owner, "isDead")
    if dead == true then return nil end
    local actor, leader = Motion.position(body), Motion.position(owner)
    if not actor or not leader then return nil end
    local gap = Motion.distance(actor, leader)
    -- Three tiles keeps a following companion outside the chair-rest ring.
    -- Use the same rule on both simulators even with older local configs.
    local preferred = 3.0
    local adjacent=math.abs(math.floor(actor.x)-math.floor(leader.x))<=1
        and math.abs(math.floor(actor.y)-math.floor(leader.y))<=1
    if math.floor(actor.z)==math.floor(leader.z) and (adjacent or gap<2.5) then
        return clearanceGoal(actor,leader),gap
    end
    if math.floor(actor.z) == math.floor(leader.z) and gap <= preferred then
        return nil, gap
    end
    -- Far away, tag this coordinate snapshot with a runtime-only moving target.
    -- Motion.drive then asks IsoZombie.pathToCharacter(owner), so stairs/corners
    -- keep tracking a moving player without a new A* request every time X/Y changes.
    local goal={x=leader.x,y=leader.y,z=leader.z}
    if gap >= Motion.characterPathDistance then followGoals[goal]=owner end
    return goal, gap
end

function Motion.moveType(goal, gap, owner)
    if not goal then return "IDLE" end
    local _, running = call(owner, "isRunning")
    local _, sprinting = call(owner, "isSprinting")
    -- Mirror the leader immediately, not only after falling nine tiles behind.
    -- These are reads on the player, never player-only running flags on Goblin.
    if running == true or sprinting == true or (gap or 0) >= Config.followRunDistance then return "RUN" end
    return "WALK"
end

function Motion.stop(body)
    if not Motion.controls(body) then Motion.paths[body] = nil return end
    local _, behavior = call(body, "getPathFindBehavior2")
    call(behavior, "cancel")
    call(body, "setPath2", nil)
    call(body, "setPathing", false)
    call(body, "setVariable", "bPathfind", false)
    call(body, "setVariable", "bMoving", false)
    call(body, "setVariable", "GoblinMoveType", "IDLE")
    call(body, "setRunning", false)
    call(body, "setSprinting", false)
    call(body, "setWalkType", "Walk")
    call(body, "setSpeedTypeFromWalkType")
    call(body, "setUseless", true)
    Motion.paths[body] = nil
end

function Motion.rejoin(body, point, sequence, expires, timestamp)
    if type(point)~="table" or type(sequence)~="number" or type(expires)~="number"
        or timestamp>expires or rejoined[body]==sequence or not Motion.controls(body) then return false end
    for _,key in ipairs({"x","y","z"}) do
        if type(point[key])~="number" or point[key]~=point[key] or math.abs(point[key])>1000000 then return false end
    end
    local square=getCell():getGridSquare(math.floor(point.x),math.floor(point.y),math.floor(point.z))
    if not square then return false end
    Motion.stop(body)
    local ok=call(body,"teleportTo",math.floor(point.x),math.floor(point.y),math.floor(point.z))
    if ok then rejoined[body]=sequence end
    return ok
end

local function pathToCharacter(body,target)
    local ok,result=call(body,"pathToCharacter",target)
    if ok and result~=false then return true end
    -- Some builds expose the moving-character goal only on PathFindBehavior2.
    local _,behavior=call(body,"getPathFindBehavior2")
    ok,result=call(behavior,"pathToCharacter",target)
    return ok and result~=false
end

function Motion.drive(body, goal, moveType, timestamp)
    -- Before any native path call, including the first frame of a new order.
    if goal or Hands.travelling(body) then Hands.stow(body) end
    local _,vehicle=call(body,"getVehicle")
    if vehicle then Motion.stop(body);return true,"riding" end
    if not Motion.controls(body) then
        Motion.paths[body] = nil
        return true, "delegated"
    end
    if not goal then
        Motion.stop(body)
        return true, "arrived"
    end
    -- Do not mark an actively pathing actor useless: WalkTowardState.enter
    -- immediately returns such an actor to idle in 42.20.4. The idle guard
    -- disables wandering again whenever the native path has ended or failed.
    -- IsoZombie has no BodyDamage. The player running flag makes fence-vault
    -- entry dereference it in 42.20.4. Native zombie speedType plus our human
    -- RUN animation provide running without invoking that player-only branch.
    call(body, "setRunning", false)
    call(body, "setSprinting", false)
    call(body, "setWalkType", moveType == "RUN" and "sprint" or "Walk")
    call(body, "setSpeedTypeFromWalkType")
    call(body, "setVariable", "GoblinMoveType", moveType)
    local path = Motion.paths[body]
    local point = Motion.position(body)
    if not point then return false, "position unavailable" end
    if not path then
        path = { point = point, progressAt = timestamp, nextPathAt = 0, failures = 0 }
        Motion.paths[body] = path
    end
    if Motion.distance(point, path.point) > 0.1 then
        path.point, path.progressAt, path.failures = point, timestamp, 0
    end

    local targetCharacter=followGoals[goal]
    local wantedMode=targetCharacter and "character" or "location"
    local stuck = timestamp - path.progressAt >= Config.stuckTimeoutSeconds * 1000
    local changed
    if wantedMode=="character" then
        changed=path.mode~="character" or path.character~=targetCharacter
    else
        changed=path.mode~="location" or not path.goal or Motion.distance(goal,path.goal)>=0.75
    end

    if timestamp >= path.nextPathAt and (changed or stuck) then
        -- Respect the engine repath cooldown; a moving character goal updates
        -- internally, so owner X/Y changes do not restart A* every 1.25 seconds.
        call(body, "setUseless", false)
        local ok,result,usedCharacter
        if targetCharacter then
            ok=pathToCharacter(body,targetCharacter)
            usedCharacter=ok
        end
        if not ok then
            ok,result=call(body,"pathToLocationF",goal.x,goal.y,goal.z)
            usedCharacter=false
        end
        path.nextPathAt = timestamp + Config.repathSeconds * 1000
        if not ok or result == false then return false, "native path rejected" end
        path.mode=usedCharacter and "character" or "location"
        path.character=usedCharacter and targetCharacter or nil
        path.goal = { x = goal.x, y = goal.y, z = goal.z }
        if stuck then
            path.failures = path.failures + 1
            path.progressAt = timestamp
            if path.failures == 1 then print("[GoblinSurvivor] MOVEMENT_BLOCKED native path retry") end
        end
    end
    return true, path.mode=="character" and "following character" or "pathing"
end

return Motion

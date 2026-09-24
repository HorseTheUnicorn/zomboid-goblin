-- Bounded scavenging routes in loaded squares; no teleporting or invented loot.
local Config = require("GoblinSurvivor/Config")
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Movement = require("GoblinSurvivor/GoblinMovement")
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local Explore = {}
-- The task payload is replaced every time autonomous LOOT yields to FOLLOW.
-- Keep the patrol cursor on the actor so the next task does not retry the
-- same first waypoint (and the same blocked route) indefinitely.
Explore.cursors = setmetatable({}, {__mode="k"})
local directions = {{1,0},{0.707,0.707},{0,1},{-0.707,0.707},{-1,0},{-0.707,-0.707},{0,-1},{0.707,-0.707}}

function Explore.anchor(body, payload)
    -- Stored with the task, so reloading a roaming body cannot expand its leash.
    if payload.search_anchor then return payload.search_anchor end
    local data, anchor = Body.data(body), Body.position(body)
    if data.GoblinBaseSet then
        local base = {x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ}
        if World.square(base) then anchor = base end
    end
    for _, player in ipairs(World.values(getOnlinePlayers())) do
        local _, dead = World.call(player,"isDead")
        if dead~=true and string.lower(player:getUsername()) == string.lower(Body.owner(body)) then
            anchor = Body.position(player); break
        end
    end
    payload.search_anchor = anchor
    return anchor
end

function Explore.within(point, anchor)
    return math.floor(point.z) == math.floor(anchor.z)
        and (point.x-anchor.x)^2 + (point.y-anchor.y)^2 <= Config.autonomyExploreRadius^2
end

function Explore.update(body, payload, job, now)
    if now < (job.nextExploreAt or 0) then return false, "waiting for a loaded search route" end
    if job.exploreFailures and job.nextExploreAt and now >= job.nextExploreAt then
        job.exploreFailures, job.nextExploreAt = 0, nil
    end
    local anchor, point = Explore.anchor(body, payload), Body.position(body)
    local cursor = Explore.cursors[body]
    if not cursor or math.floor(cursor.anchor.z) ~= math.floor(anchor.z)
        or Motion.distance(cursor.anchor, anchor) >= 5 then
        cursor = {anchor={x=anchor.x,y=anchor.y,z=anchor.z},index=0}
        Explore.cursors[body] = cursor
    end
    if not job.explore then
        for _ = 1, 24 do
            local index = cursor.index % 24
            cursor.index = index + 1
            payload.search_cursor = cursor.index
            local direction, radius = directions[index%8+1], Config.autonomyExploreRadius*(math.floor(index/8)+1)/3
            local square = World.square({x=anchor.x+direction[1]*radius,y=anchor.y+direction[2]*radius,z=anchor.z})
            local ok, free = World.call(square, "isFree", false)
            local floorOK, solidFloor = World.call(square, "treatAsSolidFloor")
            if ok and free and (not floorOK or solidFloor) then
                local target = World.point(square)
                if Explore.within(target, anchor) and (target.x-point.x)^2+(target.y-point.y)^2 > 9
                    and not Motion.isBlacklisted(body, target, now, "target") then
                    job.explore, job.exploreAt, job.explorePoint = target, now, point
                    print("[GoblinSurvivor] IDLE_EXPLORE owner="..Body.owner(body).." waypoint="..payload.search_cursor)
                    break
                end
            end
        end
    end
    if not job.explore then
        Movement.clear(body)
        job.nextExploreAt = now + Config.autonomyDecisionSeconds*1000
        return false, "no loaded search route"
    end
    local square = World.square(job.explore)
    if point and job.explorePoint and Motion.distance(point, job.explorePoint) >= 0.25 then
        job.explorePoint, job.exploreAt = point, now
    end
    if not square or now-job.exploreAt >= 20000 then
        Motion.blacklist(body, job.explore, square and "idle route made no progress" or "idle route unloaded",
            now, "target")
        Movement.clear(body)
        job.explore, job.explorePoint = nil, nil
        job.exploreFailures = (job.exploreFailures or 0) + 1
        if job.exploreFailures >= 3 then
            job.nextExploreAt = now + 60000
            return true, "search route blocked; pausing exploration"
        end
        return true, "search route blocked or unloaded; trying another"
    end
    local reached = World.approach(body, square, now)
    if reached then
        job.explore, job.explorePoint, job.exploreFailures = nil, nil, 0
        return true, "searching a new area"
    end
    return false, payload.patrol_only and "patrolling with saved cargo" or "exploring for supplies"
end

return Explore

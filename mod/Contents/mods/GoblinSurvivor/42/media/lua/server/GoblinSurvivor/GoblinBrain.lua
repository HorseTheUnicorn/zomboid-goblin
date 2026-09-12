-- Deterministic per-body Goblin task controller.
-- Qwen chooses semantic actions; this file resolves actual PZ work.
local Config = require("GoblinSurvivor/Config")
local Constants = require("GoblinSurvivor/Constants")
local Body = require("GoblinSurvivor/GoblinBody")
local Movement = require("GoblinSurvivor/GoblinMovement")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
local Loot = require("GoblinSurvivor/GoblinLoot")
local Work = require("GoblinSurvivor/GoblinWork")
local World = require("GoblinSurvivor/GoblinWorld")
local Access = require("GoblinSurvivor/GoblinAccess")

local Brain = {}

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, first = pcall(member, object, ...)
    return ok, first
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

local function log(body, text)
    if type(print) == "function" then
        print("[GoblinSurvivor] " .. tostring(text)
            .. " owner=" .. tostring(Body.owner(body))
            .. " npc_id=" .. tostring(Body.npcId(body)))
    end
end

local function playerForOwner(body)
    local owner = Body.owner(body)
    if type(owner) ~= "string" or type(getOnlinePlayers) ~= "function" then return nil end
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return nil end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    for i = 0, size - 1 do
        local okPlayer, player = call(list, "get", i)
        if okPlayer and player ~= nil then
            local okName, name = call(player, "getUsername")
            if okName and type(name) == "string" and string.lower(name) == string.lower(owner) then return player end
        end
    end
    return nil
end


local Jobs = require("GoblinSurvivor/GoblinJobs")
local Transport = require("GoblinSurvivor/GoblinTransport")

local function setTaskInternal(body, task, payload)
    if not Body.isGoblin(body) then return false, "Goblin body is not present" end
    if Constants.ALLOWED_TASKS[task] ~= true then return false, "unsupported task" end
    payload = type(payload) == "table" and payload or {}
    -- Speech/equipment are one-shot actions, not persistent movement modes.
    -- Keeping SPEAK as the task made a greeting permanently stop following.
    if task == Constants.TASK.SPEAK then return Body.say(body, payload.text) end
    if task == Constants.TASK.EQUIP then return Body.ensureWeapon(body) end
    local jobDetail
    local transport=task=="ENTER_VEHICLE" or task=="EXIT_VEHICLE"
    if transport then
        payload,jobDetail=Transport.prepare(body,playerForOwner(body),task,nowMs())
        if not payload then return false,jobDetail end
    end
    if Jobs.handles(task) then
        local ok,prepared,detail=pcall(Jobs.prepare,body,playerForOwner(body),task,payload)
        if not ok then return false,"job preparation failed; the existing order was kept" end
        if not prepared then return false,detail end
        payload,jobDetail=prepared,detail
    end
    local opening=task==Constants.TASK.OPEN_DOOR or task==Constants.TASK.OPEN_WINDOW
    local openingDetail
    if opening then
        payload,openingDetail=Access.prepare(playerForOwner(body),task==Constants.TASK.OPEN_WINDOW,nowMs())
        if not payload then return false,openingDetail end
    end
    if task == Constants.TASK.BUILD then
        if not Work.blueprints[payload.kind] then return false, "choose crate, wall, or fence" end
        local owner = playerForOwner(body)
        local point = owner and Body.position(owner)
        if not point then return false, "owner must be present to mark a build site" end
        payload = {kind=payload.kind,north=payload.north==true,x=math.floor(point.x),y=math.floor(point.y),z=math.floor(point.z)}
    end
    Work.clear(body)
    Loot.clear(body)
    Jobs.clear(body)
    Transport.clear(body)
    local data = Body.data(body)
    data.GoblinAutonomous = payload.autonomous == true
    if task ~= Constants.TASK.ATTACK then
        Body.setCombatPose(body, false)
    end
    if not Spawner.setTask(body, task, payload) then return false, "task could not be persisted" end
    if transport then Movement.clear(body);return true,jobDetail end
    if Jobs.handles(task) then
        Movement.clear(body)
        return true,jobDetail
    end
    if opening then
        Movement.clear(body)
        return true,openingDetail
    end
    if task == Constants.TASK.BUILD or task == Constants.TASK.FORTIFY then
        Movement.clear(body)
        return true, "work queued; materials will be gathered nearby"
    end

    if task == Constants.TASK.WAIT then
        Movement.clear(body)
        Body.setPhysicalState(body, Constants.PHYSICAL.IDLE, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
        return true, "waiting"
    end
    if task == Constants.TASK.RETURN_TO_BASE then
        Movement.clear(body)
        return true, data.GoblinBaseSet and "returning to base" or "returning supplies to owner"
    end
    if task == Constants.TASK.SET_BASE then
        Movement.clear(body)
        local player = playerForOwner(body)
        if player == nil then return false, "owner is offline" end
        local ok, detail = Spawner.setBaseForPlayer(player)
        if ok then
            Spawner.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
            Body.say(body, "Base noted. The revolution now has an address.")
        end
        return ok, detail
    end
    if task == Constants.TASK.LOOT then
        Movement.clear(body)
        local data = Body.data(body)
        if data ~= nil then data.GoblinLootPhase = payload.deliver_only and "deliver" or "collect" end
        Body.setPhysicalState(body, Constants.PHYSICAL.LOOTING, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
        return true, "loot cycle started"
    end
    if task == Constants.TASK.ATTACK then
        Movement.clear(body)
        Body.setCombatPose(body, false)
        return true, "attack ordered; I will approach and engage nearby zombies"
    end
    return Movement.command(body, task, payload)
end

function Brain.setTask(body, task, payload)
    local ok, detail = setTaskInternal(body, task, payload)
    if ok then log(body, "TASK_CHANGE task=" .. tostring(task)) end
    return ok, detail
end

function Brain.execute(message, body)
    if not Body.isGoblin(body) then return false, "Goblin body is not present" end
    if type(message) ~= "table" or type(message.action) ~= "string" then return false, "malformed Goblin command" end
    local action = string.upper(message.action)
    if action=="ENTER_VEHICLE" or action=="EXIT_VEHICLE" then return Brain.setTask(body,action,{}) end
    if Jobs.handles(action) then return Brain.setTask(body,action,{job=message.job,item=message.item}) end
    if action=="OPEN_DOOR" or action=="OPEN_WINDOW" then return Brain.setTask(body,action,{}) end
    if action == "SAY" then return Brain.setTask(body, Constants.TASK.SPEAK, { text = message.text }) end
    if action == "EQUIP" then return Brain.setTask(body, Constants.TASK.EQUIP, {}) end
    if action == "WAIT" or action == "NOOP" or action == "HOLD_POSITION" or action == "REST" then return Brain.setTask(body, Constants.TASK.WAIT, {autonomous=message.autonomous==true}) end
    if action == "FOLLOW" or action == "FOLLOW_GOBLIN" or action == "REGROUP" or action == "HELP" or action == "DEFEND_PLAYER" then
        return Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
    end
    if action == "SET_BASE" or action == "REMEMBER_BASE" then return Brain.setTask(body, Constants.TASK.SET_BASE, {}) end
    if action == "SECURE_BASE" or action == "FORTIFY" then return Brain.setTask(body, Constants.TASK.FORTIFY, {autonomous=message.autonomous==true}) end
    if action == "BUILD" then
        local kind = message.kind or (type(message.item)=="table" and message.item.name)
        return Brain.setTask(body, Constants.TASK.BUILD, {kind=kind,north=message.north==true})
    end
    if action == "RETURN_TO_BASE" or action == "GO_HOME" or action == "RETURN" then return Brain.setTask(body, Constants.TASK.RETURN_TO_BASE, {autonomous=message.autonomous==true}) end
    if action == "LOOT" or action == "LOOT_AREA" or action == "SCAVENGE" or action == "SEARCH" then
        return Brain.setTask(body, Constants.TASK.LOOT, { loot_focus = type(message.loot_focus) == "string" and message.loot_focus or "surprise", autonomous=message.autonomous==true })
    end
    if action == "ATTACK" or action == "DEFEND_AREA" or action == "CLEAR_BUILDING" then return Brain.setTask(body, Constants.TASK.ATTACK, {}) end
    if action == "MOVE_TO" and type(message.x) == "number" and type(message.y) == "number" and type(message.z) == "number" then
        return Brain.setTask(body, Constants.TASK.MOVE_TO, { x = message.x, y = message.y, z = message.z })
    end
    return false, "unsupported Goblin action"
end

local function updateLoot(body, payload, timestamp)
    local data = Body.data(body)
    if data == nil then return false end
    if (data.GoblinLootPhase or (payload.deliver_only and "deliver" or "collect")) == "collect" then
        Body.setPhysicalState(body, Constants.PHYSICAL.LOOTING, Constants.MOVE_TYPE.IDLE, Constants.COMBAT.NONE)
        local ok, detail, moved, done = Loot.collect(body, payload, timestamp)
        if not ok then return false, detail end
        if not done then return true, detail end
        if (tonumber(moved) or 0) <= 0 and not Loot.hasCargo(body) then
            Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
            return true, "nothing useful found; following owner"
        end
        data.GoblinLootPhase = "deliver"
    end
    local square, destination = Loot.deliveryTarget(body)
    if not square then
        Brain.setTask(body, Constants.TASK.FOLLOW, {owner=Body.owner(body)})
        return true, destination
    end
    local reached, detail = World.approach(body, square, timestamp)
    if not reached then return true, detail end
    local delivered, deliveryDetail = Loot.deposit(body)
    if delivered then Brain.setTask(body, Constants.TASK.FOLLOW, {owner=Body.owner(body)}) end
    return true, deliveryDetail
end

local function updateReturnToBase(body, payload, timestamp)
    local square, destination = Loot.deliveryTarget(body)
    if not square then
        Brain.setTask(body, Constants.TASK.FOLLOW, {owner=Body.owner(body)})
        return true, destination
    end
    local reached, detail = World.approach(body, square, timestamp)
    if not reached then return true, detail end
    local data = Body.data(body)
    local delivered, deliveryDetail = Loot.deposit(body)
    if data ~= nil then data.GoblinLootPhase = nil end
    if delivered then
        Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
        Body.say(body, "Supplies redistributed to the collective. Mostly yours, comrade.")
    end
    return true, deliveryDetail
end

function Brain.update(body, timestamp)
    if not Body.isGoblin(body) then return false end
    Body.applyInvariants(body)
    local data = Body.data(body)
    if data == nil then return false end
    local task = data.GoblinTask or Constants.TASK.FOLLOW
    local payload = type(data.GoblinTaskPayload) == "table" and data.GoblinTaskPayload or {}
    local now = timestamp or nowMs()
    data.GoblinTransportActive=false
    -- Route-door closures remain runtime-only and must be serviced even after
    -- a house job has completed and the Goblin is otherwise idle/following.
    -- Access.tick only closes an exact door while it is still adjacent; it
    -- never performs a remote toggle or touches windows.
    Access.tick(body, now)
    if Transport.tick(body,playerForOwner(body),now) then
        data.GoblinTransportActive=true
        return true
    end
    if Jobs.handles(task) then
        local done,ok,detail=Jobs.update(body,task,payload,now)
        if done then
            local delivery=ok and Loot.hasCargo(body) and Constants.TASK.RETURN_TO_BASE or Constants.TASK.FOLLOW
            Brain.setTask(body,delivery,{owner=Body.owner(body)})
            data.GoblinWorkStatus=detail
            Body.say(body,"Comrade, "..tostring(detail)..".")
            log(body,"COMMAND_RESULT action="..task.." success="..tostring(ok).." detail="..tostring(detail))
        end
        return true
    end
    if task==Constants.TASK.OPEN_DOOR or task==Constants.TASK.OPEN_WINDOW then
        local done,ok,detail=Access.perform(body,payload,now)
        if done then
            Brain.setTask(body,Constants.TASK.FOLLOW,{owner=Body.owner(body)})
            Body.say(body,"Comrade, "..detail..".")
            log(body,"COMMAND_RESULT action="..task.." success="..tostring(ok).." detail="..detail)
        end
        return true
    end
    if task == Constants.TASK.BUILD or task == Constants.TASK.FORTIFY then
        if Work.update(body, task, payload, now) then
            Brain.setTask(body, Constants.TASK.FOLLOW, {owner=Body.owner(body)})
        end
        return true
    end
    if task == Constants.TASK.WAIT or task == Constants.TASK.SPEAK or task == Constants.TASK.EQUIP then return true end
    if task == Constants.TASK.LOOT then return updateLoot(body, payload, now) end
    if task == Constants.TASK.RETURN_TO_BASE then
        return updateReturnToBase(body, payload, now)
    end
    -- Defense owns all combat, including explicit orders. Never fall back to
    -- an immediate unanimated Hit when the combat controller did not run.
    if task == Constants.TASK.ATTACK then return false, "waiting for combat controller" end
    if task == Constants.TASK.SET_BASE then
        local player = playerForOwner(body)
        if player == nil then return false end
        Spawner.setBaseForPlayer(player)
        Brain.setTask(body, Constants.TASK.FOLLOW, { owner = Body.owner(body) })
        return true
    end
    local movement = Movement.snapshot(body)
    if movement == nil or movement.task ~= task then Movement.command(body, task, payload) end
    local ok, detail = Movement.update(body, now)
    -- An idle trip interrupted by movement still hands over its cargo once
    -- caught up. A set base instead retains it for the next idle delivery run.
    if task == Constants.TASK.FOLLOW and not data.GoblinBaseSet and Loot.hasCargo(body) then
        Loot.deposit(body)
    end
    return ok, detail
end

function Brain.snapshot(body)
    local result = Body.snapshot(body)
    if result == nil then return nil end
    result.movement = Movement.snapshot(body)
    return result
end

return Brain

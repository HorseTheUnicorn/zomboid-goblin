local Probe = {
    ticks = 0,
    attempted = false,
    survivor = nil,
    player = nil
}

local function log(message)
    print("GOBLIN_BODY_PROBE " .. tostring(message))
end

local function call(label, fn)
    local ok, value = pcall(fn)
    if ok then
        log(label .. "=ok:" .. tostring(value))
        return true, value
    end
    log(label .. "=error:" .. tostring(value))
    return false, nil
end

local function sizeOf(value)
    if value == nil then
        return "nil"
    end
    local ok, size = pcall(function()
        return value:size()
    end)
    if ok then
        return tostring(size)
    end
    return "unavailable"
end

local function createSurvivor(cell)
    local okDesc, desc = call("survivor_desc", function()
        return SurvivorFactory.CreateSurvivor()
    end)
    if not okDesc or desc == nil then
        return nil
    end

    local okBody, body = call("survivor_create", function()
        return SurvivorFactory.InstansiateInCell(desc, cell, 12067, 6801, 0)
    end)
    if not okBody or body == nil then
        return nil
    end

    call("survivor_name", function()
        return body:getObjectName()
    end)
    call("survivor_exists", function()
        return body:isExistInTheWorld()
    end)
    call("survivor_square", function()
        return body:getSquare()
    end)
    call("survivor_list_size", function()
        return sizeOf(cell:getSurvivorList())
    end)
    return body
end

local function createPlayer(cell)
    local okDesc, desc = call("player_desc", function()
        return SurvivorFactory.CreateSurvivor()
    end)
    if not okDesc or desc == nil then
        return nil
    end

    local okBody, body = call("player_create", function()
        return IsoPlayer.new(cell, desc, 12068, 6801, 0)
    end)
    if not okBody or body == nil then
        return nil
    end

    call("player_npc", function()
        body:setNpc(true)
        return body:isNpc()
    end)
    call("player_username", function()
        body:setUsername("GoblinProbe")
        return body:getUsername()
    end)
    call("player_online_id", function()
        body:setOnlineID(321)
        return body:getOnlineID()
    end)
    call("player_current_square", function()
        body:setCurrentSquareFromPosition()
        return body:getSquare()
    end)
    call("player_add_moving", function()
        cell:addMovingObject(body)
        return body:isExistInTheWorld()
    end)
    call("player_exists", function()
        return body:isExistInTheWorld()
    end)
    call("player_list_size", function()
        return sizeOf(GameServer.getPlayers())
    end)
    call("server_player_map", function()
        return GameServer.IDToPlayerMap:get(321)
    end)
    call("server_username_map", function()
        return GameServer.UserNameToPlayerMap:get("GoblinProbe")
    end)
    return body
end

local function probe()
    if Probe.attempted then
        return
    end
    Probe.attempted = true
    log("begin")

    local okCell, cell = call("cell", function()
        return getCell()
    end)
    if not okCell or cell == nil then
        log("result=cell_unavailable")
        return
    end

    call("world_square", function()
        return cell:getGridSquare(12067, 6801, 0)
    end)

    Probe.survivor = createSurvivor(cell)
    Probe.player = createPlayer(cell)
    log("result=construction_complete")
end

local function onTick()
    Probe.ticks = Probe.ticks + 1
    if Probe.ticks == 60 then
        probe()
    end
end

if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(onTick)
elseif Events and Events.EveryOneMinute and type(Events.EveryOneMinute.Add) == "function" then
    Events.EveryOneMinute.Add(probe)
end

log("loaded")

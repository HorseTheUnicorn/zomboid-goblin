-- Disposable local-client harness for the non-Steam B42 test server.
--
-- The vanilla non-Steam connection flow stops at first-time character
-- creation.  This file advances that existing UI only when the Java launch
-- property -Dgoblin.local.autoconnect=true is enabled by Start-LocalPzClient.
-- It never creates an actor itself and is inert for normal clients, servers,
-- and production deployments.

local LocalCharacterBootstrap = {
    ticks = 0,
    completed = false,
    lastPhase = nil,
    probeLogged = false,
}

print("[GoblinSurvivor] local character bootstrap loaded; enabledFn="
    .. tostring(type(goblinLocalAutoConnectEnabled))
    .. " isClientFn=" .. tostring(type(isClient))
    .. " finishFn=" .. tostring(type(finishGoblinLocalLoading)))

local function isEnabled()
    if type(goblinLocalAutoConnectEnabled) ~= "function" then
        return false
    end
    local ok, enabled = pcall(goblinLocalAutoConnectEnabled)
    return ok and enabled == true
end

local function logPhase(phase, detail)
    if LocalCharacterBootstrap.lastPhase == phase then
        return
    end
    LocalCharacterBootstrap.lastPhase = phase
    print("[GoblinSurvivor] local character bootstrap " .. phase .. (detail or ""))
end

local function isVisible(panel)
    return panel ~= nil
        and type(panel.getIsVisible) == "function"
        and panel:getIsVisible()
end

local function hasLocalPlayer()
    if type(getSpecificPlayer) ~= "function" then
        return false
    end
    return getSpecificPlayer(0) ~= nil
end

local function finishLocalLoading()
    if type(finishGoblinLocalLoading) ~= "function" then
        return false
    end
    local ok, finished = pcall(finishGoblinLocalLoading)
    return ok and finished == true
end

local function click(panel, button)
    if panel == nil or button == nil or type(panel.onOptionMouseDown) ~= "function" then
        return false
    end
    local ok = pcall(panel.onOptionMouseDown, panel, button, 0, 0)
    return ok
end

local function setDefaultName(characterCreation)
    local forename = characterCreation.forenameEntry
    local surname = characterCreation.surnameEntry
    if forename and type(forename.setText) == "function" then
        forename:setText("Goblin")
    end
    if surname and type(surname.setText) == "function" then
        surname:setText("Survivor")
    end
end

function LocalCharacterBootstrap.tick()
    if not LocalCharacterBootstrap.probeLogged then
        LocalCharacterBootstrap.probeLogged = true
        print("[GoblinSurvivor] local character bootstrap probe: enabled="
            .. tostring(isEnabled()) .. " isClient="
            .. tostring(type(isClient) == "function" and isClient() or false))
    end
    if LocalCharacterBootstrap.completed or not isEnabled() or not isClient() then
        return
    end

    -- The vanilla loading overlay waits for a native click before entering
    -- IngameState.  Ask the opt-in Java harness to perform that one state
    -- transition; it is inert unless this disposable client was launched
    -- with -Dgoblin.local.autoconnect=true.
    finishLocalLoading()

    if hasLocalPlayer() then
        LocalCharacterBootstrap.completed = true
        logPhase("complete")
        return
    end

    LocalCharacterBootstrap.ticks = LocalCharacterBootstrap.ticks + 1
    -- Let the post-handshake UI finish constructing before inspecting it.
    if LocalCharacterBootstrap.ticks < 15 or MainScreen == nil or MainScreen.instance == nil then
        return
    end

    local main = MainScreen.instance
    local spawn = main.mapSpawnSelect
    if isVisible(spawn) then
        if type(spawn.useDefaultSpawnRegion) == "function" then
            spawn:useDefaultSpawnRegion()
        end
        if spawn.listbox and spawn.listbox.items and #spawn.listbox.items > 0 then
            if not spawn.listbox.selected or spawn.listbox.selected < 1 then
                spawn.listbox.selected = 1
            end
            if click(spawn, spawn.nextButton) then
                logPhase("selected-default-spawn")
            end
        else
            logPhase("waiting-for-spawn-list")
        end
        return
    end

    local profession = main.charCreationProfession
    if isVisible(profession) then
        if profession.listboxProf and profession.listboxProf.items
                and #profession.listboxProf.items > 0 then
            profession.listboxProf.selected = 1
        end
        if click(profession, profession.playButton) then
            logPhase("selected-default-profession")
        end
        return
    end

    local characterCreation = main.charCreationMain
    if isVisible(characterCreation) then
        setDefaultName(characterCreation)
        if click(characterCreation, characterCreation.playButton) then
            logPhase("submitted-character")
        end
        return
    end

    logPhase("waiting-for-character-screen")
end

if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(LocalCharacterBootstrap.tick)
end

-- The first-time character screens live in the front-end render loop.  In
-- B42 OnTick may not run until a player already exists, while OnPostUIDraw is
-- available immediately after the connection handshake.
if Events and Events.OnPostUIDraw and type(Events.OnPostUIDraw.Add) == "function" then
    Events.OnPostUIDraw.Add(LocalCharacterBootstrap.tick)
end

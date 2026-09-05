-- Client-side renderer for the server-authoritative human survivor slice.
--
-- IsoSurvivor is intentionally created only in the client runtime. It is not
-- sent through the vanilla zombie packet stream and it never becomes an
-- IsoZombie. Every client receives the same bounded position snapshot and
-- maintains its own visual object.
local Protocol = require("GoblinSurvivor/ClientSurvivorProtocol")

local Client = {
    actors = {},
    nextCreateAt = {},
    lastSequence = {},
    generations = {},
    lastSpeechSequence = {},
    pendingSpeech = {},
    states = {},
    mapMarkers = {},
    mapMarkerApi = nil,
    mapMarkerMap = nil,
    nextMapMarkerAt = 0,
    mapFailureLogged = false,
    lastState = nil,
    nextRequestAt = 0,
    requestIntervalMs = 3000,
    started = false,
    lastDiagnosticsAt = 0
}

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] ClientSurvivorActor: " .. tostring(message))
    end
end

local function call(object, method, ...)
    if object == nil then return false, nil end
    -- Kahlua exposes java.lang.Class values as a special object. Looking up
    -- a method on one of those values outside pcall raises instead of
    -- returning nil (unlike ordinary Java userdata), so protect both the
    -- lookup and the invocation.
    local okMethod, fn = pcall(function() return object[method] end)
    if not okMethod or type(fn) ~= "function" then return false, nil end
    local ok, value = pcall(fn, object, ...)
    return ok, value
end

local function listRemove(list, object)
    if list == nil or type(list.remove) ~= "function" then return false end
    local ok, removed = pcall(list.remove, list, object)
    return ok and removed == true
end

local function listAddOnce(list, object)
    if list == nil or type(list.add) ~= "function" then return false end
    if type(list.contains) == "function" then
        local okContains, contains = pcall(list.contains, list, object)
        if okContains and contains == true then return true end
    end
    local ok, added = pcall(list.add, list, object)
    return ok and (added == true or added == nil)
end

local function cell()
    if type(getCell) ~= "function" then return nil end
    local ok, value = pcall(getCell)
    return ok and value or nil
end

local function squareFor(worldCell, x, y, z)
    if worldCell == nil then return nil end
    local ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
    if type(worldCell.getGridSquare) == "function" then
        local ok, square = pcall(worldCell.getGridSquare, worldCell, ix, iy, iz)
        if ok and square ~= nil then return square end
    end
    if type(worldCell.getOrCreateGridSquare) == "function" then
        local ok, square = pcall(worldCell.getOrCreateGridSquare, worldCell, ix, iy, iz)
        if ok then return square end
    end
    return nil
end

local function descriptor()
    local factory = rawget(_G, "SurvivorFactory")
    if factory ~= nil and type(factory.CreateSurvivor) == "function" then
        local ok, value = pcall(factory.CreateSurvivor)
        if ok and value ~= nil then return value end
    end
    if type(getPlayer) == "function" then
        local okPlayer, player = pcall(getPlayer)
        if okPlayer and player ~= nil and type(player.getDescriptor) == "function" then
            local okDescriptor, value = pcall(player.getDescriptor, player)
            if okDescriptor and value ~= nil then return value end
        end
    end
    return nil
end

local function applyHumanVisual(actor, state)
    local profile = state.profile or {}
    if type(profile.sex) == "string" then
        call(actor, "setFemale", string.lower(profile.sex) == "female")
    end
    local human = nil
    local okHuman, value = call(actor, "getHumanVisual")
    if okHuman then human = value end
    if human == nil then
        local okDescriptor, desc = call(actor, "getDescriptor")
        if okDescriptor and desc ~= nil then
            local okVisual, visual = call(desc, "getHumanVisual")
            if okVisual then human = visual end
        end
    end
    if human == nil then return false end
    call(human, "removeDirt")
    call(human, "removeBlood")
    local colorFactory = rawget(_G, "ImmutableColor")
    if colorFactory ~= nil and type(colorFactory.new) == "function"
        and type(profile.hairColor) == "table" then
        local okColor, hairColor = pcall(colorFactory.new,
            tonumber(profile.hairColor.r) or 0.18,
            tonumber(profile.hairColor.g) or 0.12,
            tonumber(profile.hairColor.b) or 0.08)
        if okColor and hairColor ~= nil then
            call(human, "setHairColor", hairColor)
            call(human, "setBeardColor", hairColor)
        end
    end
    if type(profile.hair) == "string" and profile.hair ~= "" then
        call(human, "setHairModel", profile.hair)
    end
    if type(profile.beard) == "string" then
        call(human, "setBeardModel", profile.beard == "none" and nil or profile.beard)
    end
    return true
end

local function modelManager()
    local managerClass = rawget(_G, "ModelManager")
    if managerClass == nil then return nil end
    local ok, manager = pcall(function() return managerClass.instance end)
    return ok and manager or nil
end

local function registerInWorld(actor, worldCell, square)
    -- IsoSurvivor is a legacy single-player class in B42. Keep it out of the
    -- cell update collections (its old update path expects BodyDamage), but
    -- use the moving-square API so the renderer sees it through the same list
    -- and bookkeeping used by normal characters.
    if square ~= nil then
        local attached = call(actor, "setMovingSquare", square)
        if not attached then
            local okMoving, movingObjects = call(square, "getMovingObjects")
            if okMoving then listAddOnce(movingObjects, actor) end
        end
    end
    call(actor, "setCurrentSquare", square)
    -- The B42 FBO renderer traverses IsoCell.objectList, not just movingSquares.
    -- HumanSurvivor overrides all three vanilla simulation update phases.
    call(actor, "registerVisualObject")

    -- IsoGameCharacter construction does not automatically create a model
    -- slot for an actor that is kept out of IsoCell's update loop. Register it
    -- explicitly so IsoSprite.hasActiveModel() and renderActiveModel() have a
    -- real human ModelInstance to draw.
    local manager = modelManager()
    if manager ~= nil then
        local okAdd = call(manager, "Add", actor)
        if not okAdd then
            log("ModelManager.Add failed for client-side actor")
        end
    else
        -- Kahlua cannot reliably read ModelManager.instance on this B42
        -- build. Let the Java actor call the same singleton directly, then
        -- retain the uncull fallback for a runtime with a missing manager.
        local okJavaModel, javaModelReady = call(actor, "ensureVisualModel")
        if not okJavaModel or javaModelReady ~= true then
            local okUncull = call(actor, "setSceneCulled", false)
            if not okUncull then log("setSceneCulled failed for client-side actor") end
        end
    end
end

local function squareCoordinates(square)
    if square == nil then return "nil" end
    local okX, x = call(square, "getX")
    local okY, y = call(square, "getY")
    local okZ, z = call(square, "getZ")
    if not okX or not okY or not okZ then return tostring(square) end
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function actorDiagnostics(actor)
    local okVisual, visual = call(actor, "visualDiagnostics")
    local okWeapon, weapon = call(actor, "getFirearmType")
    local okWeaponReady, weaponReady = call(actor, "hasReadyFirearm")
    local okGodMode, godMode = call(actor, "isGodMode")
    local okSprite, sprite = call(actor, "getSprite")
    local okLegs, legs = call(actor, "getLegsSprite")
    local okActive, active = false, false
    if legs ~= nil then okActive, active = call(legs, "hasActiveModel") end
    local okModel, model = call(actor, "getModelInstance")
    local okRender, doRender = call(actor, "getDoRender")
    local okInvisible, invisible = call(actor, "isSpriteInvisible")
    local okAlphaZero, alphaZero = call(actor, "isAlphaZero")
    local okCurrent, current = call(actor, "getCurrentSquare")
    local okMovingSquare, movingSquare = call(actor, "getMovingSquare")
    local inMovingList = false
    if current ~= nil then
        local okObjects, objects = call(current, "getMovingObjects")
        if okObjects and objects ~= nil and type(objects.contains) == "function" then
            local okContains, contains = pcall(objects.contains, objects, actor)
            inMovingList = okContains and contains == true
        end
    end
    local manager = modelManager()
    local okManaged, managed = false, false
    if manager ~= nil then okManaged, managed = call(manager, "ContainsChar", actor) end
    if not okManaged then okManaged, managed = call(actor, "visualModelManaged") end
    return "sprite=" .. tostring(okSprite and sprite ~= nil)
        .. " legs=" .. tostring(okLegs and legs ~= nil)
        .. " activeModel=" .. (okActive and tostring(active) or "unavailable")
        .. " model=" .. tostring(okModel and model ~= nil)
        .. " doRender=" .. (okRender and tostring(doRender) or "unavailable")
        .. " invisible=" .. (okInvisible and tostring(invisible) or "unavailable")
        .. " alphaZero=" .. (okAlphaZero and tostring(alphaZero) or "unavailable")
        .. " current=" .. squareCoordinates(okCurrent and current or nil)
        .. " moving=" .. squareCoordinates(okMovingSquare and movingSquare or nil)
        .. " inMovingList=" .. tostring(inMovingList)
        .. " modelManager=" .. (okManaged and tostring(managed) or "unavailable")
        .. " firearm=" .. (okWeapon and tostring(weapon) or "unavailable")
        .. " weaponReady=" .. (okWeaponReady and tostring(weaponReady) or "unavailable")
        .. " godMode=" .. (okGodMode and tostring(godMode) or "unavailable")
        .. " javaVisual=" .. (okVisual and tostring(visual) or "unavailable")
end

local function detachFromUpdateCollections(actor, worldCell)
    if worldCell == nil then return end
    -- IsoGameCharacter's constructor adds non-zero-position instances to the
    -- cell object list even though IsoSurvivor itself has no BodyDamage. Remove
    -- that automatic registration before the next client update tick.
    local okObjects, objectList = call(worldCell, "getObjectList")
    if okObjects then listRemove(objectList, actor) end
    local okAdds, addList = call(worldCell, "getAddList")
    if okAdds then listRemove(addList, actor) end
end

local function displaySpeech(actor, text)
    local ok = call(actor, "addLineChatElement", text, 0.1, 0.8, 0.1)
    if not ok then
        ok = call(actor, "Say", text)
    end
    return ok
end

local function applyRequestedOutfit(actor, state)
    local profile = state.profile or {}
    local outfit = profile.outfit
    if type(outfit) ~= "table" then return true end
    local ok, worn = call(actor, "applyOutfit",
        outfit.top, outfit.outer, outfit.pants,
        outfit.shoes, outfit.head, outfit.back)
    if not ok then
        log("could not apply randomized outfit for client-side actor '"
            .. tostring(state.actor_id) .. "'")
        return false
    end
    if type(worn) == "number" and worn < 3 then
        log("randomized outfit for '" .. tostring(state.actor_id)
            .. "' only equipped " .. tostring(worn) .. " item(s)")
    end
    return true
end

local function equipRequestedFirearm(actor, state)
    local profile = state.profile or {}
    if type(profile.weapon) ~= "string" or profile.weapon == "" then
        -- The server's current roster contract gives every managed human a
        -- rifle. Keep the client adapter compatible with an older snapshot
        -- by using the same bounded default rather than creating an unarmed
        -- visual actor.
        profile.weapon = "Base.AssaultRifle2"
    end
    local ok, ready = call(actor, "ensureFirearm")
    if not ok or ready ~= true then
        log("could not equip requested firearm for client-side actor '"
            .. tostring(state.actor_id) .. "'")
        return false
    end
    return true
end

local function currentWorldMap()
    local map = rawget(_G, "ISWorldMap_instance")
    if map == nil then
        local mapClass = rawget(_G, "ISWorldMap")
        if mapClass ~= nil then map = mapClass.instance end
    end
    if map == nil or map.mapAPI == nil then return nil end
    local okVisible, visible = call(map, "isVisible")
    if not okVisible or visible ~= true then return nil end
    return map
end

local function removeMapMarker(id, api)
    local marker = Client.mapMarkers[id]
    if marker ~= nil then
        call(api or Client.mapMarkerApi, "removeSymbol", marker)
        Client.mapMarkers[id] = nil
    end
end

local function clearMapMarkers()
    local api = Client.mapMarkerApi
    if api ~= nil then
        for id, _ in pairs(Client.mapMarkers) do
            removeMapMarker(id, api)
        end
    end
    Client.mapMarkers = {}
    Client.mapMarkerApi = nil
    Client.mapMarkerMap = nil
end

local function mapMarkerColor(id, state)
    if id == "goblin.primary" then return 0.20, 1.00, 0.25 end
    local colors = {
        medic = { 0.35, 0.85, 1.00 },
        guard = { 1.00, 0.35, 0.30 },
        hauler = { 1.00, 0.72, 0.20 },
        farmer = { 0.45, 1.00, 0.35 },
        builder = { 1.00, 0.55, 0.20 },
        scout = { 0.80, 0.45, 1.00 }
    }
    local color = colors[string.lower(tostring(state and state.role or ""))]
        or { 0.95, 0.95, 0.95 }
    return color[1], color[2], color[3]
end

local function updateMapMarkers(force)
    local map = currentWorldMap()
    if map == nil then return false end
    local now = Protocol.nowMs()
    if not force and now < Client.nextMapMarkerAt then return true end
    Client.nextMapMarkerAt = now + 250

    local okApi, api = call(map.mapAPI, "getSymbolsAPIv2")
    if not okApi or api == nil then
        if not Client.mapFailureLogged then
            Client.mapFailureLogged = true
            log("world-map symbol API is unavailable; survivor markers deferred")
        end
        return false
    end
    if Client.mapMarkerApi ~= nil and Client.mapMarkerApi ~= api then
        clearMapMarkers()
    end
    Client.mapMarkerApi = api
    Client.mapMarkerMap = map
    -- Keep the standard symbol layer visible even if the player previously
    -- disabled map symbols in the vanilla map options.
    call(map.mapAPI, "setBoolean", "Symbols", true)

    local live = {}
    for id, actor in pairs(Client.actors) do
        local state = Client.states[id]
        local alive = state == nil or (state.alive ~= false and state.body_present ~= false)
        if alive then
            local okX, x = call(actor, "getX")
            local okY, y = call(actor, "getY")
            if okX and okY and type(x) == "number" and type(y) == "number" then
                local marker = Client.mapMarkers[id]
                if marker == nil then
                    local okAdd, added = call(api, "addTexture", "Gun", x, y)
                    if okAdd then marker = added end
                    if marker ~= nil then
                        local r, g, b = mapMarkerColor(id, state)
                        call(marker, "setRGBA", r, g, b, 1.0)
                        call(marker, "setAnchor", 0.5, 0.5)
                        call(marker, "setScale", 1.0)
                        call(marker, "setApplyZoom", true)
                        call(marker, "setMatchPerspective", false)
                        call(marker, "setMinZoom", 0.0)
                        call(marker, "setMaxZoom", 24.0)
                        call(marker, "setUserDefined", false)
                        Client.mapMarkers[id] = marker
                    end
                end
                if marker ~= nil then
                    call(marker, "setPosition", x, y)
                    call(marker, "setVisible", true)
                    live[id] = true
                end
            end
        end
    end
    for id, _ in pairs(Client.mapMarkers) do
        if not live[id] then removeMapMarker(id, api) end
    end
    return true
end

local function runtimeClassName(actor)
    local okClass, runtimeClass = call(actor, "getClass")
    if not okClass or runtimeClass == nil then return nil end
    -- Kahlua represents java.lang.Class as a special value whose getName
    -- lookup raises even inside pcall. Its string form still contains the
    -- fully-qualified runtime class and is safe to use for diagnostics.
    return tostring(runtimeClass)
end

local function removeActor(id)
    local actor = Client.actors[id]
    if actor == nil then return false end
    local manager = modelManager()
    if manager ~= nil then call(manager, "Remove", actor) end
    -- The custom Java body is registered in IsoCell.objectList explicitly for
    -- rendering. removeFromWorld() does not reliably remove that manual
    -- visual registration, so use the symmetric lifecycle hook before the
    -- actor is forgotten or recreated for a new generation.
    call(actor, "unregisterVisualObject")
    local okSquare, square = call(actor, "getCurrentSquare")
    if okSquare and square ~= nil then
        local okMoving, movingObjects = call(square, "getMovingObjects")
        if okMoving then listRemove(movingObjects, actor) end
    end
    call(actor, "removeFromSquare")
    call(actor, "removeFromWorld")
    Client.actors[id] = nil
    return true
end

local function createActor(state)
    local class = { new = rawget(_G, "createGoblinHumanSurvivor") }
    local desc = descriptor()
    local worldCell = cell()
    if class == nil or type(class.new) ~= "function" then
        return nil, "HumanSurvivor.new is unavailable; launch the client with GoblinSurvivor Storm loaded"
    end
    if desc == nil then return nil, "SurvivorFactory descriptor is unavailable" end
    if worldCell == nil then return nil, "client world cell is unavailable" end

    local ok, actor = pcall(class.new, desc, worldCell,
        math.floor(state.x), math.floor(state.y), math.floor(state.z))
    if not ok or actor == nil then
        return nil, "HumanSurvivor.new failed: " .. tostring(actor)
    end

    detachFromUpdateCollections(actor, worldCell)

    local square = squareFor(worldCell, state.x, state.y, state.z)
    call(actor, "setAlphaAndTarget", 1.0)
    call(actor, "setDoRender", true)
    call(actor, "setInvisible", false)
    call(actor, "setVisibleToNPCs", true)
    call(actor, "setDisplayName", state.display_name)
    call(actor, "setName", state.display_name)
    call(actor, "setDir", rawget(_G, "IsoDirections")
        and rawget(_G, "IsoDirections").S or nil)
    local okData, data = call(actor, "getModData")
    if okData and type(data) == "table" then
        data.goblin_client_survivor = true
        data.goblin_actor_id = state.actor_id
        data.goblin_entity_class = Protocol.entityClass
    end
    applyHumanVisual(actor, state)
    applyRequestedOutfit(actor, state)
    if state.actor_id == "goblin.primary" then call(actor, "forceGoblinAppearance") end
    if state.god_mode ~= false then call(actor, "ensureGodMode") end
    equipRequestedFirearm(actor, state)
    registerInWorld(actor, worldCell, square)
    log("client-side actor '" .. tostring(state.actor_id) .. "' render state: "
        .. actorDiagnostics(actor))
    local pending = Client.pendingSpeech[state.actor_id]
    if pending ~= nil then
        Client.pendingSpeech[state.actor_id] = nil
        displaySpeech(actor, pending.text)
    end
    return actor
end

local function applyState(state)
    local id = state.actor_id
    local previousSequence = Client.lastSequence[id] or 0
    if state.sequence <= previousSequence then return true end
    local pending = Client.states[id]
    if pending ~= nil and state.sequence < pending.sequence then return true end
    Client.states[id] = state
    Client.lastState = state

    local actor = Client.actors[id]
    if state.alive == false or state.body_present == false then
        Client.lastSequence[id] = state.sequence
        Client.nextCreateAt[id] = nil
        if actor ~= nil then
            removeActor(id)
            log("removed absent client-side actor '" .. tostring(id) .. "'"
                .. " generation=" .. tostring(state.body_generation or 0))
        end
        Client.states[id] = nil
        removeMapMarker(id)
        Client.generations[id] = state.body_generation or Client.generations[id] or 0
        return true
    end
    local generation = state.body_generation or 0
    if actor ~= nil and Client.generations[id] ~= nil
        and generation > 0 and Client.generations[id] ~= generation then
        removeActor(id)
        actor = nil
        log("recreating client-side actor '" .. tostring(id)
            .. "' for body generation " .. tostring(generation))
    end
    if actor == nil then
        local now = Protocol.nowMs()
        if now < (Client.nextCreateAt[id] or 0) then return false end
        Client.nextCreateAt[id] = now + 1000
        local created, detail = createActor(state)
        if created == nil then
            log("could not create " .. Protocol.entityClass .. ": " .. tostring(detail))
            return false
        end
        Client.actors[id] = created
        Client.nextCreateAt[id] = nil
        actor = created
        local okZombie, isZombie = call(actor, "isZombie")
        log("created Java human survivor actor '" .. tostring(id)
            .. "' java_class=" .. tostring(runtimeClassName(actor))
            .. " isZombie=" .. (okZombie and tostring(isZombie) or "unavailable"))
    end

    Client.lastSequence[id] = state.sequence
    Client.generations[id] = generation
    equipRequestedFirearm(actor, state)
    if state.god_mode ~= false then call(actor, "ensureGodMode") end

    call(actor, "setX", state.x)
    call(actor, "setY", state.y)
    call(actor, "setZ", state.z)
    call(actor, "setLx", state.x)
    call(actor, "setLy", state.y)
    call(actor, "setLz", state.z)
    call(actor, "setAlphaAndTarget", 1.0)
    call(actor, "setDoRender", true)
    call(actor, "setInvisible", false)
    local worldCell = cell()
    local square = squareFor(worldCell, state.x, state.y, state.z)
    local okCurrent, currentSquare = call(actor, "getCurrentSquare")
    if okCurrent and currentSquare ~= square and currentSquare ~= nil then
        call(actor, "removeFromSquare")
    end
    if square ~= nil then
        local okMovingSquare, movingSquare = call(actor, "getMovingSquare")
        if not okMovingSquare or movingSquare ~= square then
            local attached = call(actor, "setMovingSquare", square)
            if not attached then
                local okMoving, movingObjects = call(square, "getMovingObjects")
                if okMoving then listAddOnce(movingObjects, actor) end
            end
        end
        call(actor, "setCurrentSquare", square)
    end
    local now = Protocol.nowMs()
    if now >= Client.lastDiagnosticsAt then
        Client.lastDiagnosticsAt = now + 5000
        log("client-side actor '" .. tostring(id) .. "' render state: "
            .. actorDiagnostics(actor))
    end
    return true
end

local function requestSnapshot()
    if type(sendClientCommand) ~= "function" then return false end
    local ok = pcall(sendClientCommand, Protocol.module,
        Protocol.requestCommand, { protocol = Protocol.version })
    return ok
end

local function showSpeech(value)
    local previous = Client.lastSpeechSequence[value.actor_id] or 0
    if value.speech_sequence <= previous then return false end
    Client.lastSpeechSequence[value.actor_id] = value.speech_sequence
    local actor = Client.actors[value.actor_id]
    if actor == nil then
        Client.pendingSpeech[value.actor_id] = value
        return true
    end
    local ok = displaySpeech(actor, value.text)
    if ok then
        log("displayed speech for client-side actor '" .. tostring(value.actor_id) .. "'")
    else
        log("could not display speech for client-side actor '" .. tostring(value.actor_id) .. "'")
    end
    return ok
end

local function onServerCommand(module, command, args)
    if module ~= Protocol.module then return end
    if command == Protocol.speechCommand then
        if not Protocol.validSpeech(args) then
            log("rejected malformed client-survivor speech packet")
            return
        end
        showSpeech(args)
        return
    end
    if command ~= Protocol.stateCommand then return end
    if not Protocol.validSnapshot(args) then
        log("rejected malformed client-survivor state packet")
        return
    end
    applyState(args)
end

if Events and Events.OnServerCommand
    and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(onServerCommand)
end

if Events and Events.OnGameStart
    and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(function()
        for id, _ in pairs(Client.actors) do removeActor(id) end
        Client.actors = {}
        Client.nextCreateAt = {}
        Client.lastSequence = {}
        Client.generations = {}
        Client.lastSpeechSequence = {}
        Client.pendingSpeech = {}
        Client.states = {}
        clearMapMarkers()
        Client.nextMapMarkerAt = 0
        Client.mapFailureLogged = false
        Client.lastState = nil
        Client.nextRequestAt = 0
        requestSnapshot()
    end)
end

if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(function()
        local now = Protocol.nowMs()
        if now >= Client.nextRequestAt then
            if requestSnapshot() then
                Client.nextRequestAt = now + Client.requestIntervalMs
            else
                Client.nextRequestAt = now + 1000
            end
        end
        -- Retry every pending roster member after transient creation failures.
        -- Successfully applied sequences are ignored by applyState.
        for _, state in pairs(Client.states) do applyState(state) end
        for id, actor in pairs(Client.actors) do
            local ok, detail = call(actor, "tickVisual")
            if not ok and not Client.visualFailureLogged then
                Client.visualFailureLogged = true
                log("visual tick failed for " .. tostring(id) .. ": " .. tostring(detail))
            end
        end
        updateMapMarkers()
    end)
end

if Events and Events.OnPostUIDraw and type(Events.OnPostUIDraw.Add) == "function" then
    -- The world map can pause the simulation, so keep marker positions fresh
    -- from the UI draw path as well as the normal game tick.
    Events.OnPostUIDraw.Add(function() updateMapMarkers() end)
end

Client.started = true
return Client

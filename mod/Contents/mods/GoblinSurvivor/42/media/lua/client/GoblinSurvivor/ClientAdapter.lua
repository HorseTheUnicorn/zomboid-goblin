local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")

local ClientAdapter = {
    started = false,
    serverEnabled = false,
    serverManifest = nil,
    catalog = nil,
    catalogMaps = {},
    catalogSentVersion = nil,
    lastHello = 0,
    lastState = 0,
    lastPump = 0,
    manifestDiagnostic = nil,
    lifecycle = "fresh",
    generation = 0,
    appearance = nil,
    pendingCharacter = nil,
    pendingAcceptAt = nil,
    restoreOnCreate = false,
    deathStartedAt = 0,
    recreationAttemptAt = 0,
    defaultCreationRequest = nil,
    activeAction = nil,
    eventSequence = 0,
    lastThreatLevel = nil,
    lastThreatBucket = nil,
    lastInjurySeverity = nil,
    mode = "SAFE",
    seenRequests = {},
    seenOrder = {}
}

local validStates = {
    fresh = true,
    creation_pending = true,
    active = true,
    dead = true,
    recreate_required = true
}

local validActions = {
    NOOP = true,
    SAY = true,
    MOVE_TO = true,
    FOLLOW = true,
    SEARCH = true,
    SCAVENGE = true,
    RETREAT = true,
    REST = true,
    GO_HOME = true,
    JOIN_PARTY = true,
    LEAVE_PARTY = true,
    ATTACK = true,
    FLEE = true,
    EAT = true,
    DRINK = true,
    BANDAGE = true,
    RELOAD = true,
    CLAIM_REWARD = true
}

local validModes = {
    SAFE = true,
    ROAM = true,
    PARTY = true,
    HUNT = true
}

local function nowSeconds()
    if type(getTimestampMs) == "function" then
        local ok, timestamp = pcall(getTimestampMs)
        if ok and type(timestamp) == "number" then
            return timestamp / 1000
        end
    end
    return os.time()
end

local function stringValue(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        return value
    end
    local ok, converted = pcall(tostring, value)
    if ok and converted ~= "nil" then
        return converted
    end
    return nil
end

local function localPlayer()
    local getter = rawget(_G, "getPlayer")
    if type(getter) == "function" then
        local ok, player = pcall(getter)
        if ok and player ~= nil then
            return player
        end
    end
    local specific = rawget(_G, "getSpecificPlayer")
    if type(specific) == "function" then
        local ok, player = pcall(specific, 0)
        if ok and player ~= nil then
            return player
        end
    end
    return nil
end

local function usernameOf(player)
    if player == nil or type(player.getUsername) ~= "function" then
        return nil
    end
    local ok, username = pcall(function() return tostring(player:getUsername()) end)
    if ok and username ~= "nil" and #username > 0 then
        return username
    end
    return nil
end

local function clientUsername()
    local player = localPlayer()
    local username = usernameOf(player)
    if username then
        return username
    end
    local coopUserName = rawget(_G, "CoopUserName")
    if type(coopUserName) == "table" and coopUserName.instance ~= nil
        and type(coopUserName.instance.getUserName) == "function" then
        local ok, value = pcall(function() return coopUserName.instance:getUserName() end)
        value = stringValue(value)
        if ok and value and #value > 0 then
            return value
        end
    end
    -- The configured body name is a PZ username, not a Steam identity.  It
    -- is used only while the connection's character screen has no player.
    return Config.bodyUsername
end

local function sendEvent(kind, fields)
    if type(kind) ~= "string" or not string.find(kind, "^[a-z][a-z0-9_]*$")
        or type(fields) ~= "table" then
        return false
    end
    ClientAdapter.eventSequence = ClientAdapter.eventSequence + 1
    local requestId = string.format(
        "event-%s-%d-%d",
        kind,
        math.floor(nowSeconds() * 1000),
        ClientAdapter.eventSequence
    )
    local args = {
        client_username = clientUsername(),
        request_id = requestId,
        kind = kind
    }
    for key, value in pairs(fields) do
        args[key] = value
    end
    if not Net.safeId(requestId, 128) or not Net.safeTable(args) then
        return false
    end
    return Net.sendClient("event", args)
end

local function gameBuild()
    local getter = rawget(_G, "getCore")
    if type(getter) ~= "function" then
        return nil
    end
    local ok, core = pcall(getter)
    if not ok or core == nil then
        return nil
    end
    local okVersion, version = pcall(function() return tostring(core:getVersion()) end)
    local okSha, sha = pcall(function() return tostring(core:getGitSha()) end)
    if not okVersion or not okSha or version == "nil" or sha == "nil"
        or version == "" or sha == "" then
        return nil
    end
    local build = version .. " " .. sha
    if #build > 64
        or string.find(build, "^[A-Za-z0-9][A-Za-z0-9%._%+%- ]*$") == nil then
        return nil
    end
    return build
end

local function modDirectory()
    local fileSystem = rawget(_G, "ZomboidFileSystem")
    if fileSystem ~= nil and fileSystem.instance ~= nil
        and type(fileSystem.instance.getModDir) == "function" then
        local ok, path = pcall(function()
            return tostring(fileSystem.instance:getModDir("GoblinSurvivor"))
        end)
        if ok and path and path ~= "nil" and path ~= "" then
            return path
        end
    end
    local getter = rawget(_G, "getModInfoByID")
    if type(getter) == "function" then
        local ok, info = pcall(getter, "GoblinSurvivor")
        if ok and info ~= nil and type(info.getDir) == "function" then
            local okDir, path = pcall(function() return tostring(info:getDir()) end)
            if okDir and path and path ~= "nil" and path ~= "" then
                return path
            end
        end
    end
    return nil
end

local function readDigestSidecar()
    local base = modDirectory()
    -- The sidecar is a build artifact next to the loaded 42 tree. It is not
    -- the Goblin IPC bridge and never contains commands or credentials.
    local candidates = {}
    if base then
        candidates = {
            base .. "/" .. Config.manifestSidecarName,
            base .. "/../" .. Config.manifestSidecarName
        }
    end
    local function readPhysical(path)
        local library = rawget(_G, "io")
        if not library or type(library.open) ~= "function" then
            return nil
        end
        local okOpen, handle = pcall(library.open, path, "rb")
        if not okOpen or handle == nil then
            return nil
        end
        local okRead, content = pcall(function()
            local value = handle:read("*a")
            handle:close()
            return value
        end)
        if okRead and type(content) == "string" then
            return content
        end
        pcall(function() handle:close() end)
        return nil
    end
    local function readLuaCache(path)
        local readerFactory = rawget(_G, "getFileReader")
        if type(readerFactory) ~= "function" then
            return nil
        end
        local okOpen, handle = pcall(readerFactory, path, false)
        if not okOpen or handle == nil then
            return nil
        end
        local lines = {}
        local okRead = pcall(function()
            while true do
                local line = handle:readLine()
                if line == nil then
                    break
                end
                table.insert(lines, line)
            end
        end)
        pcall(function() handle:close() end)
        if okRead then
            return table.concat(lines, "\n")
        end
        return nil
    end
    for _, path in ipairs(candidates) do
        local value = readPhysical(path)
        if value then
            value = string.lower(string.gsub(value, "%s+", ""))
            if #value == 64 and string.find(value, "^[0-9a-f]+$") then
                return value
            end
        end
    end
    -- getFileReader resolves relative names below the PZ Lua cache. The
    -- installer places a copy there because Build 42 may remove io from mod
    -- Lua even on the client side.
    local value = readLuaCache(Config.manifestSidecarName)
    if value then
        value = string.lower(string.gsub(value, "%s+", ""))
        if #value == 64 and string.find(value, "^[0-9a-f]+$") then
            return value
        end
    end
    return nil
end

local function listValues(javaList)
    local result = {}
    if javaList == nil then
        return result
    end
    if type(javaList) == "table" then
        for _, value in ipairs(javaList) do
            table.insert(result, value)
        end
        return result
    end
    -- Kahlua may expose Java methods through a proxy rather than as Lua
    -- functions. Invoke them through pcall instead of inspecting their
    -- reflected field types first.
    local okSize, size = pcall(function() return javaList:size() end)
    if not okSize or type(size) ~= "number" or size < 0 or size > 4096 then
        return result
    end
    for index = 0, size - 1 do
        local ok, value = pcall(function() return javaList:get(index) end)
        if ok and value ~= nil then
            table.insert(result, value)
        end
    end
    return result
end

local function activeModIds()
    local ids = {}
    local activeMods = rawget(_G, "ActiveMods")
    local values = {}
    if activeMods ~= nil and type(activeMods.getById) == "function" then
        local ok, active = pcall(function() return activeMods.getById("currentGame") end)
        if ok and active ~= nil and type(active.getMods) == "function" then
            local okMods, modList = pcall(function() return active:getMods() end)
            if okMods then
                values = listValues(modList)
            end
        end
    end
    -- Build 42's supported Lua helper returns the active ordered mod list,
    -- while ActiveMods.currentGame may expose an empty list on the client.
    -- Use the helper whenever the preferred list is unavailable or empty.
    if #values == 0 then
        local getter = rawget(_G, "getActivatedMods")
        if type(getter) == "function" then
            local ok, activated = pcall(getter)
            if ok then
                values = listValues(activated)
            end
        end
    end
    if #values == 0 then
        -- Some Build 42 environments resolve documented globals through the
        -- Lua environment without placing them in raw _G.
        local ok, activated = pcall(function() return getActivatedMods() end)
        if ok then
            values = listValues(activated)
        end
    end
    local seen = {}
    for _, value in ipairs(values) do
        local id = stringValue(value)
        if id and #id > 0 then
            local folded = string.lower(id)
            if not seen[folded] then
                seen[folded] = true
                table.insert(ids, id)
            end
        end
    end
    return ids
end

local function workshopIds(modIds)
    local result = {}
    local seen = {}
    local getter = rawget(_G, "getModInfoByID")
    if type(getter) ~= "function" then
        return result
    end
    for _, modId in ipairs(modIds) do
        local ok, info = pcall(getter, modId)
        if ok and info ~= nil and type(info.getWorkshopID) == "function" then
            local okId, workshopId = pcall(function() return info:getWorkshopID() end)
            workshopId = stringValue(workshopId)
            if okId and workshopId and #workshopId > 0
                and string.find(workshopId, "^[0-9]+$") then
                if not seen[workshopId] then
                    seen[workshopId] = true
                    table.insert(result, workshopId)
                end
            end
        end
    end
    return result
end

local function clientManifest()
    local build = gameBuild()
    local digest = readDigestSidecar()
    local mods = activeModIds()
    local workshopItems = workshopIds(mods)
    local diagnostic = (build and "build=ok" or "build=missing")
        .. " " .. (digest and "digest=ok" or "digest=missing")
        .. " mods=" .. tostring(#mods)
        .. " workshop=" .. tostring(#workshopItems)
    if build and digest then
        local candidate = {
            game_build = build,
            mods = mods,
            workshop_items = workshopItems,
            goblin_survivor_sha256 = digest
        }
        diagnostic = diagnostic .. " valid="
            .. (Net.validManifest(candidate) and "yes" or "no")
    end
    if diagnostic ~= ClientAdapter.manifestDiagnostic then
        ClientAdapter.manifestDiagnostic = diagnostic
        local logger = rawget(_G, "print")
        if type(logger) == "function" then
            pcall(logger, "[GoblinSurvivor] client manifest " .. diagnostic)
        end
    end
    if not build or not digest then
        return nil, build
    end
    local manifest = {
        game_build = build,
        mods = mods,
        workshop_items = workshopItems,
        goblin_survivor_sha256 = digest
    }
    if not Net.validManifest(manifest) then
        return nil, build
    end
    return manifest, build
end

local function labelValue(value, fallback)
    local label = stringValue(value) or fallback or "vanilla option"
    if not Net.safeText(label, 96, false) then
        label = fallback or "vanilla option"
    end
    return label
end

local function optionId(value, fallback)
    local raw = stringValue(value) or ""
    if raw == "" then
        raw = fallback or "none"
    end
    raw = string.lower(raw)
    if not Net.safeId(raw, 64) then
        return nil
    end
    return raw
end

local function ensureOptionMap(category)
    ClientAdapter.catalogMaps[category] = ClientAdapter.catalogMaps[category] or {}
    return ClientAdapter.catalogMaps[category]
end

local function categorySuffix(value)
    local raw = stringValue(value) or ""
    raw = string.lower(string.gsub(raw, "[^a-zA-Z0-9_:%-]", "_"))
    if raw == "" or not Net.safeId(raw, 48) then
        return nil
    end
    return raw
end

local function isAccessoryLocation(value)
    local folded = string.lower(stringValue(value) or "")
    for _, word in ipairs({
        "hat", "head", "mask", "eye", "ear", "neck", "scarf",
        "back", "fanny", "holster", "belt", "jewelry", "accessory"
    }) do
        if string.find(folded, word, 1, true) then
            return true
        end
    end
    return false
end

local function addOption(options, category, id, label, rawValue)
    if type(category) ~= "string" or not Net.safeId(category, 64)
        or not Net.safeId(id, 64) or not Net.safeText(label, 96, false) then
        return false
    end
    options[category] = options[category] or {}
    if #options[category] >= Net.maxCatalogItems then
        return false
    end
    for _, existing in ipairs(options[category]) do
        if existing.id == id then
            return true
        end
    end
    table.insert(options[category], {
        id = id,
        label = label,
        source = "vanilla"
    })
    ensureOptionMap(category)[id] = rawValue
    return true
end

local function addJavaOptions(options, category, javaList, fallback)
    for _, value in ipairs(listValues(javaList)) do
        local id = optionId(value, fallback)
        if id then
            addOption(options, category, id, labelValue(value, id), value)
        end
    end
end

local function getHairColorValues()
    local desc = nil
    local mainScreen = rawget(_G, "MainScreen")
    if type(mainScreen) == "table" and mainScreen.instance ~= nil then
        desc = mainScreen.instance.desc
    end
    if desc == nil then
        local factory = rawget(_G, "SurvivorFactory")
        if factory ~= nil and type(factory.CreateSurvivor) == "function" then
            local ok, created = pcall(function() return factory.CreateSurvivor() end)
            if ok then
                desc = created
            end
        end
    end
    if desc == nil or type(desc.getCommonHairColor) ~= "function" then
        return {}
    end
    local ok, colors = pcall(function() return desc:getCommonHairColor() end)
    if not ok then
        return {}
    end
    local result = {}
    for _, color in ipairs(listValues(colors)) do
        if color ~= nil and type(color.getRedFloat) == "function" then
            local okColor, red, green, blue = pcall(function()
                return color:getRedFloat(), color:getGreenFloat(), color:getBlueFloat()
            end)
            if okColor and Net.safeNumber(red, 0, 1)
                and Net.safeNumber(green, 0, 1)
                and Net.safeNumber(blue, 0, 1) then
                table.insert(result, {r = red, g = green, b = blue})
            end
        end
    end
    return result
end

local function buildCatalog()
    pcall(require, "OptionScreens/CharacterCreationMain")
    pcall(require, "OptionScreens/CharacterCreationProfession")

    local build = gameBuild() or "client"
    local versionSlug = string.lower(string.gsub(build, "[^a-zA-Z0-9%._:%-]", "-"))
    if versionSlug == "" then
        versionSlug = "client"
    end
    local catalog = {
        version = "catalog-" .. versionSlug .. "-v1",
        options = {}
    }
    if not Net.safeId(catalog.version, 64) then
        return nil
    end
    ClientAdapter.catalogMaps = {}

    addOption(catalog.options, "gender", "female", "female", true)
    addOption(catalog.options, "gender", "male", "male", false)

    local skinColors = {
        {r = 1.0, g = 0.91, b = 0.72},
        {r = 0.98, g = 0.79, b = 0.49},
        {r = 0.80, g = 0.65, b = 0.45},
        {r = 0.54, g = 0.38, b = 0.25},
        {r = 0.36, g = 0.25, b = 0.14}
    }
    for index, color in ipairs(skinColors) do
        addOption(catalog.options, "skin_tone", "tone_" .. tostring(index), "skin tone " .. tostring(index), index)
    end
    ClientAdapter.catalogMaps.skin_tone = {}
    for index = 1, #skinColors do
        ClientAdapter.catalogMaps.skin_tone["tone_" .. tostring(index)] = {
            index = index,
            color = skinColors[index]
        }
    end

    local hairStyles = nil
    local hairGetter = rawget(_G, "getAllHairStyles")
    if type(hairGetter) == "function" then
        local ok, list = pcall(hairGetter, false)
        if ok then
            hairStyles = list
        end
    end
    if hairStyles == nil then
        return nil
    end
    for _, value in ipairs(listValues(hairStyles)) do
        local id = optionId(value, "none")
        if id then
            addOption(catalog.options, "hair_style", id, labelValue(value, "none"), stringValue(value) or "")
        end
    end
    if type(catalog.options.hair_style) ~= "table" or #catalog.options.hair_style < 1 then
        return nil
    end

    local colors = getHairColorValues()
    if #colors < 1 then
        return nil
    end
    for index, color in ipairs(colors) do
        local id = "hair_" .. tostring(index)
        addOption(catalog.options, "hair_color", id, "hair color " .. tostring(index), color)
        ensureOptionMap("beard_color")[id] = color
        addOption(catalog.options, "beard_color", id, "beard color " .. tostring(index), color)
    end
    if type(catalog.options.hair_color) ~= "table" or #catalog.options.hair_color < 1 then
        return nil
    end

    local professionDefinition = rawget(_G, "CharacterProfessionDefinition")
    if professionDefinition == nil or type(professionDefinition.getProfessions) ~= "function" then
        return nil
    end
    local okProfessions, professions = pcall(function() return professionDefinition.getProfessions() end)
    if not okProfessions then
        return nil
    end
    for _, definition in ipairs(listValues(professions)) do
        local okType, kind = pcall(function() return definition:getType() end)
        local id = okType and optionId(kind, nil) or nil
        if id then
            local okLabel, label = pcall(function() return definition:getUIName() end)
            addOption(catalog.options, "profession", id, labelValue(okLabel and label or id, id), definition)
        end
    end
    if type(catalog.options.profession) ~= "table" or #catalog.options.profession < 1 then
        return nil
    end

    local traitDefinition = rawget(_G, "CharacterTraitDefinition")
    if traitDefinition == nil or type(traitDefinition.getTraits) ~= "function" then
        return nil
    end
    local okTraits, traits = pcall(function() return traitDefinition.getTraits() end)
    if not okTraits then
        return nil
    end
    for _, definition in ipairs(listValues(traits)) do
        local okType, kind = pcall(function() return definition:getType() end)
        local id = okType and optionId(kind, nil) or nil
        if id then
            local okLabel, label = pcall(function() return definition:getLabel() end)
            addOption(catalog.options, "trait", id, labelValue(okLabel and label or id, id), definition)
        end
    end
    if type(catalog.options.trait) ~= "table" or #catalog.options.trait < 1 then
        return nil
    end

    local beardGetter = rawget(_G, "getAllBeardStyles")
    if type(beardGetter) == "function" then
        local ok, list = pcall(beardGetter)
        if ok then
            addJavaOptions(catalog.options, "beard_style", list, "none")
        end
    end

    local bodyLocations = rawget(_G, "BodyLocations")
    local itemGetter = rawget(_G, "getAllItemsForBodyLocation")
    if bodyLocations ~= nil and type(bodyLocations.getGroup) == "function"
        and type(itemGetter) == "function" then
        local okGroup, group = pcall(function() return bodyLocations.getGroup("Human") end)
        if okGroup and group ~= nil and type(group.size) == "function" then
            local okSize, size = pcall(function() return group:size() end)
            if okSize and type(size) == "number" then
                for index = 0, size - 1 do
                    local okLocation, location = pcall(function() return group:getLocationByIndex(index) end)
                    if okLocation and location ~= nil and type(location.getId) == "function" then
                        local okId, locationId = pcall(function() return location:getId() end)
                        local isExcluded = false
                        if okId and rawget(_G, "ItemBodyLocation") ~= nil then
                            isExcluded = locationId == ItemBodyLocation.WOUND
                                or locationId == ItemBodyLocation.ZED_DMG
                        end
                        if okId and not isExcluded and locationId ~= nil
                            and type(locationId.getTranslationName) == "function" then
                            local okName, bodyLocation = pcall(function()
                                return tostring(locationId:getTranslationName())
                            end)
                            if okName and bodyLocation and bodyLocation ~= "nil" then
                                local okItems, items = pcall(itemGetter, bodyLocation)
                                local suffix = categorySuffix(bodyLocation)
                                local category = suffix and ("clothing_" .. suffix) or nil
                                if okItems and type(items) == "table" then
                                    local rawItems = {}
                                    for _, itemType in ipairs(items) do
                                        table.insert(rawItems, stringValue(itemType) or "")
                                    end
                                    table.sort(rawItems)
                                    for _, fullType in ipairs(rawItems) do
                                        local id = optionId(fullType, nil)
                                        if id and category ~= nil then
                                            if addOption(catalog.options, category, id, labelValue(fullType, id), fullType) then
                                                local map = ensureOptionMap(category)
                                                map[id] = fullType
                                                ClientAdapter.catalogMaps.bodyLocation = ClientAdapter.catalogMaps.bodyLocation or {}
                                                ClientAdapter.catalogMaps.bodyLocation[category] = bodyLocation
                                            end
                                            if isAccessoryLocation(bodyLocation) then
                                                local accessoryCategory = "accessory_" .. suffix
                                                local accessoryMap = ensureOptionMap("accessory")
                                                if addOption(
                                                    catalog.options,
                                                    accessoryCategory,
                                                    id,
                                                    labelValue(fullType, id),
                                                    {
                                                        body_location = bodyLocation,
                                                        full_type = fullType
                                                    }
                                                ) then
                                                    accessoryMap[id] = {
                                                        body_location = bodyLocation,
                                                        full_type = fullType
                                                    }
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local hasClothing = false
    for category, values in pairs(catalog.options) do
        if string.find(category, "^clothing_") and type(values) == "table" and #values > 0 then
            hasClothing = true
            break
        end
    end
    if not hasClothing or not Net.safeTable(catalog) then
        return nil
    end
    return catalog
end

local function hasOption(category, option)
    if type(ClientAdapter.catalog) ~= "table"
        or type(ClientAdapter.catalog.options) ~= "table"
        or type(option) ~= "string" then
        return false
    end
    for _, entry in ipairs(ClientAdapter.catalog.options[category] or {}) do
        if entry.id == option and entry.source == "vanilla" then
            return true
        end
    end
    return false
end

local function validProposal(proposal, catalogVersion)
    if type(proposal) ~= "table" or not Net.safeTable(proposal)
        or proposal.name ~= "Goblin"
        or type(catalogVersion) ~= "string"
        or not Net.safeId(catalogVersion, 64)
        or ClientAdapter.catalog == nil
        or catalogVersion ~= ClientAdapter.catalog.version then
        return false
    end
    local allowed = {
        name = true,
        gender = true,
        skin_tone = true,
        hair_style = true,
        hair_color = true,
        beard_style = true,
        beard_color = true,
        profession = true,
        traits = true,
        clothing = true,
        accessories = true,
        body_type = true,
        cosmetics = true
    }
    for key, _ in pairs(proposal) do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    for _, category in ipairs({"gender", "skin_tone", "hair_style", "hair_color", "profession"}) do
        if not hasOption(category, proposal[category]) then
            return false
        end
    end
    if type(proposal.traits) ~= "table" or #proposal.traits < 1 or #proposal.traits > 5 then
        return false
    end
    local seenTraits = {}
    for _, trait in ipairs(proposal.traits) do
        if not hasOption("trait", trait) or seenTraits[trait] then
            return false
        end
        seenTraits[trait] = true
    end
    if type(proposal.clothing) ~= "table" then
        return false
    end
    local clothingCount = 0
    for category, option in pairs(proposal.clothing) do
        if type(category) ~= "string"
            or string.find(category, "^clothing_") == nil
            or not hasOption(category, option)
            or ClientAdapter.catalogMaps.bodyLocation == nil
            or ClientAdapter.catalogMaps.bodyLocation[category] == nil then
            return false
        end
        clothingCount = clothingCount + 1
    end
    if clothingCount < 1 or clothingCount > 8 then
        return false
    end
    if type(proposal.accessories) ~= "table" or #proposal.accessories > 8 then
        return false
    end
    local seenAccessories = {}
    for _, accessory in ipairs(proposal.accessories) do
        local found = false
        for category, _ in pairs(ClientAdapter.catalog.options) do
            if string.find(category, "^accessory")
                and hasOption(category, accessory) then
                found = true
                break
            end
        end
        if not found or seenAccessories[accessory] then
            return false
        end
        seenAccessories[accessory] = true
    end
    if proposal.beard_style ~= nil and not hasOption("beard_style", proposal.beard_style) then
        return false
    end
    if proposal.beard_color ~= nil and not hasOption("beard_color", proposal.beard_color) then
        return false
    end
    if proposal.body_type ~= nil or proposal.cosmetics ~= nil then
        return false
    end
    return true
end

local function selectComboData(combo, rawValue)
    if combo == nil or type(combo.getOptionData) ~= "function" or type(combo.options) ~= "table" then
        return false
    end
    for index = 1, #combo.options do
        local ok, data = pcall(function() return combo:getOptionData(index) end)
        if ok and ((rawValue == nil and data == nil) or tostring(data or "") == tostring(rawValue or "")) then
            combo.selected = index
            return true
        end
    end
    return false
end

local function selectedTrait(profession, traitId)
    if profession == nil or profession.listboxTraitSelected == nil
        or type(profession.listboxTraitSelected.items) ~= "table" then
        return false
    end
    for _, item in pairs(profession.listboxTraitSelected.items) do
        if item and item.item and type(item.item.getType) == "function" then
            local ok, kind = pcall(function() return tostring(item.item:getType()) end)
            if ok and string.lower(kind) == traitId then
                return true
            end
        end
    end
    return false
end

local function applyProposalToCreation(proposal)
    local coop = rawget(_G, "CoopCharacterCreation")
    local mainScreen = rawget(_G, "MainScreen")
    local creation = type(coop) == "table" and coop.instance or nil
    if creation == nil or mainScreen == nil or mainScreen.instance == nil
        or creation.charCreationMain == nil or creation.charCreationProfession == nil
        or mainScreen.instance.desc == nil then
        return false, "the native multiplayer character-creation screen is not ready"
    end
    local main = creation.charCreationMain
    local profession = creation.charCreationProfession
    local desc = mainScreen.instance.desc

    -- Build 42 may put the vanilla multiplayer flow on the spawn-region
    -- page before the profession page.  The normal accept() call requires a
    -- selected region, so select the server's first deterministic region in
    -- code instead of leaving the autonomous client waiting for a human
    -- click on the map.
    local mapSpawn = creation.mapSpawnSelect
    if mapSpawn ~= nil and mapSpawn.selectedRegion == nil
        and type(mapSpawn.useDefaultSpawnRegion) == "function" then
        local okDefault, region = pcall(function()
            return mapSpawn:useDefaultSpawnRegion()
        end)
        if okDefault and region ~= nil then
            mapSpawn.selectedRegion = region
        end
    end
    if mapSpawn ~= nil and mapSpawn.selectedRegion == nil then
        return false, "vanilla spawn-region selection is unavailable"
    end
    if mapSpawn ~= nil and type(mapSpawn.setVisible) == "function" then
        pcall(function() mapSpawn:setVisible(false) end)
    end

    if type(main.setVisible) == "function" then
        pcall(function() main:setVisible(true, creation.joypadData) end)
    end

    local female = proposal.gender == "female"
    if main.genderCombo ~= nil and type(main.onGenderSelected) == "function" then
        main.genderCombo.selected = female and 1 or 2
        local ok = pcall(function() main:onGenderSelected(main.genderCombo) end)
        if not ok then
            return false, "vanilla gender selection failed"
        end
    else
        local ok = pcall(function() desc:setFemale(female) end)
        if not ok then
            return false, "vanilla gender API is unavailable"
        end
    end

    local professionDef = ClientAdapter.catalogMaps.profession
        and ClientAdapter.catalogMaps.profession[proposal.profession]
    if professionDef == nil or type(profession.onSelectProf) ~= "function"
        or not pcall(function() profession:onSelectProf(professionDef) end) then
        return false, "vanilla profession selection failed"
    end

    if profession.listboxTraitSelected and type(profession.listboxTraitSelected.items) == "table"
        and type(profession.removeTrait) == "function" then
        for index = #profession.listboxTraitSelected.items, 1, -1 do
            local selected = profession.listboxTraitSelected.items[index]
            local trait = selected and selected.item
            local isFree = false
            if trait and type(trait.isFree) == "function" then
                pcall(function() isFree = trait:isFree() end)
            end
            if trait and not isFree then
                pcall(function() profession:removeTrait(index) end)
            end
        end
    end
    for _, traitId in ipairs(proposal.traits) do
        local traitDef = ClientAdapter.catalogMaps.trait
            and ClientAdapter.catalogMaps.trait[traitId]
        if traitDef == nil or type(profession.addTrait) ~= "function"
            or not pcall(function() profession:addTrait(traitDef) end)
            or not selectedTrait(profession, traitId) then
            return false, "vanilla trait selection failed"
        end
    end

    if main.forenameEntry and type(main.forenameEntry.setText) == "function" then
        main.forenameEntry:setText("Goblin")
    end
    if main.surnameEntry and type(main.surnameEntry.setText) == "function" then
        main.surnameEntry:setText("")
    end

    local skin = ClientAdapter.catalogMaps.skin_tone[proposal.skin_tone]
    if skin == nil then
        return false, "skin tone is not in the vanilla catalog"
    end
    main.skinColor = skin.index
    if main.colorPickerSkin then
        main.colorPickerSkin.index = skin.index
    end
    if type(main.onSkinColorPicked) == "function" then
        if not pcall(function() main:onSkinColorPicked(skin.color, true) end) then
            return false, "vanilla skin selection failed"
        end
    else
        pcall(function() desc:getHumanVisual():setSkinTextureIndex(skin.index - 1) end)
    end

    if type(main.disableBtn) == "function" then
        pcall(function() main:disableBtn() end)
    end
    local hairRaw = ClientAdapter.catalogMaps.hair_style[proposal.hair_style]
    if hairRaw == nil then
        return false, "hair style is not in the vanilla catalog"
    end
    if not selectComboData(main.hairTypeCombo, hairRaw) then
        return false, "vanilla hair style is not available in the current UI"
    end
    if type(main.onHairTypeSelected) ~= "function"
        or not pcall(function() main:onHairTypeSelected(main.hairTypeCombo) end) then
        return false, "vanilla hair selection failed"
    end

    local hairColor = ClientAdapter.catalogMaps.hair_color[proposal.hair_color]
    if hairColor == nil or type(main.onHairColorPicked) ~= "function"
        or not pcall(function() main:onHairColorPicked(hairColor, true) end) then
        return false, "vanilla hair color selection failed"
    end

    if proposal.beard_style ~= nil and not female then
        local beardRaw = ClientAdapter.catalogMaps.beard_style[proposal.beard_style]
        if beardRaw == nil or not selectComboData(main.beardTypeCombo, beardRaw)
            or type(main.onBeardTypeSelected) ~= "function"
            or not pcall(function() main:onBeardTypeSelected(main.beardTypeCombo) end) then
            return false, "vanilla beard selection failed"
        end
    end
    if proposal.beard_color ~= nil then
        local beardColor = ClientAdapter.catalogMaps.beard_color[proposal.beard_color]
        if beardColor == nil or type(main.onHairColorPicked) ~= "function"
            or not pcall(function() main:onHairColorPicked(beardColor, true) end) then
            return false, "vanilla beard color selection failed"
        end
    end

    if type(desc.getWornItems) == "function" then
        pcall(function() desc:getWornItems():clear() end)
    end
    for category, itemId in pairs(proposal.clothing) do
        local bodyLocation = ClientAdapter.catalogMaps.bodyLocation[category]
        local fullType = ClientAdapter.catalogMaps[category]
            and ClientAdapter.catalogMaps[category][itemId]
        if not bodyLocation or not fullType then
            return false, "clothing is not in the vanilla catalog"
        end
        local okItem, item = pcall(instanceItem, fullType)
        if not okItem or item == nil then
            return false, "vanilla clothing item could not be instantiated"
        end
        local okWear = type(item.getBodyLocation) == "function"
            and pcall(function() desc:setWornItem(item:getBodyLocation(), item) end)
        if not okWear then
            return false, "vanilla clothing API failed"
        end
    end
    for _, itemId in ipairs(proposal.accessories) do
        local accessory = ClientAdapter.catalogMaps.accessory
            and ClientAdapter.catalogMaps.accessory[itemId]
        if type(accessory) ~= "table"
            or type(accessory.full_type) ~= "string"
            or type(accessory.body_location) ~= "string" then
            return false, "accessory is not in the vanilla catalog"
        end
        local okItem, item = pcall(instanceItem, accessory.full_type)
        if not okItem or item == nil then
            return false, "vanilla accessory item could not be instantiated"
        end
        local location = accessory.body_location
        if type(item.getBodyLocation) == "function" then
            local okLocation, itemLocation = pcall(function()
                return item:getBodyLocation()
            end)
            if okLocation and itemLocation ~= nil then
                location = itemLocation
            end
        end
        if not pcall(function() desc:setWornItem(location, item) end) then
            return false, "vanilla accessory API failed"
        end
    end
    if main.avatarPanel and type(main.avatarPanel.setSurvivorDesc) == "function" then
        pcall(function() main.avatarPanel:setSurvivorDesc(desc) end)
    end
    return true, "vanilla character appearance applied"
end

local function sendCharacterResult(requestId, generation, status, detail)
    return Net.sendClient("character_result", {
        client_username = clientUsername(),
        request_id = requestId,
        generation = generation,
        status = status,
        detail = string.sub(tostring(detail or ""), 1, 512)
    })
end

local function sendActionResult(requestId, action, status, detail)
    return Net.sendClient("action_result", {
        client_username = clientUsername(),
        request_id = requestId,
        action = action,
        status = status,
        detail = string.sub(tostring(detail or ""), 1, 512)
    })
end

local function rememberRequest(requestId)
    if ClientAdapter.seenRequests[requestId] then
        return false
    end
    ClientAdapter.seenRequests[requestId] = true
    table.insert(ClientAdapter.seenOrder, requestId)
    if #ClientAdapter.seenOrder > 1024 then
        local old = table.remove(ClientAdapter.seenOrder, 1)
        ClientAdapter.seenRequests[old] = nil
    end
    return true
end

local function handleCharacterCreate(args)
    local requestId = args and args.request_id
    local generation = args and args.generation
    if type(requestId) ~= "string" or not Net.safeId(requestId, 128)
        or type(generation) ~= "number" or math.floor(generation) ~= generation
        or generation < 1 or generation > 2147483647
        or not Net.safeId(args.catalog_version, 64)
        or type(args.proposal) ~= "table"
        or not validProposal(args.proposal, args.catalog_version) then
        if type(requestId) == "string" and Net.safeId(requestId, 128)
            and type(generation) == "number" and math.floor(generation) == generation then
            sendCharacterResult(requestId, generation, "rejected", "character command failed client validation")
        end
        return false
    end
    if not ClientAdapter.serverEnabled then
        sendCharacterResult(requestId, generation, "rejected", "GoblinEnabled is false")
        return false
    end
    if ClientAdapter.lifecycle == "active" and ClientAdapter.generation == generation then
        sendCharacterResult(requestId, generation, "accepted", "character already active; appearance was not reset")
        return true
    end
    if ClientAdapter.lifecycle == "active" and ClientAdapter.generation ~= generation then
        sendCharacterResult(requestId, generation, "rejected", "active appearance belongs to another generation")
        return false
    end
    if ClientAdapter.pendingCharacter ~= nil then
        if ClientAdapter.pendingCharacter.generation == generation then
            return true
        end
        sendCharacterResult(requestId, generation, "rejected", "another character generation is pending")
        return false
    end
    local applied, detail = applyProposalToCreation(args.proposal)
    if not applied then
        sendCharacterResult(requestId, generation, "rejected", detail)
        return false
    end
    ClientAdapter.pendingCharacter = {
        request_id = requestId,
        generation = generation,
        proposal = args.proposal
    }
    ClientAdapter.pendingAcceptAt = nowSeconds() + 0.25
    ClientAdapter.lifecycle = "creation_pending"
    ClientAdapter.generation = generation
    ClientAdapter.appearance = args.proposal
    -- The proposal has already been applied to the vanilla creation UI.
    -- Do not reapply the previous dead body's appearance when OnCreatePlayer
    -- fires for this new generation.
    ClientAdapter.restoreOnCreate = false
    return true
end

local function finishCharacterCreate()
    local pending = ClientAdapter.pendingCharacter
    if pending == nil or ClientAdapter.pendingAcceptAt == nil
        or nowSeconds() < ClientAdapter.pendingAcceptAt then
        return
    end
    local coop = rawget(_G, "CoopCharacterCreation")
    local creation = type(coop) == "table" and coop.instance or nil
    if creation == nil or type(creation.accept) ~= "function" then
        sendCharacterResult(pending.request_id, pending.generation, "rejected", "character-creation UI disappeared before accept")
        ClientAdapter.pendingCharacter = nil
        ClientAdapter.pendingAcceptAt = nil
        ClientAdapter.lifecycle = pending.default and "recreate_required" or "fresh"
        return
    end
    local ok = pcall(function() creation:accept() end)
    local accepted = ok and (coop.instance == nil)
    if accepted then
        sendCharacterResult(pending.request_id, pending.generation, "accepted", "vanilla character creation submitted")
        ClientAdapter.defaultCreationRequest = nil
        log("vanilla recreation submitted for generation " .. tostring(pending.generation))
    else
        sendCharacterResult(pending.request_id, pending.generation, "rejected", "vanilla character creation did not accept the spawn")
        ClientAdapter.lifecycle = pending.default and "recreate_required" or "fresh"
    end
    ClientAdapter.pendingCharacter = nil
    ClientAdapter.pendingAcceptAt = nil
end

local function onlinePlayers()
    local getter = rawget(_G, "getOnlinePlayers")
    if type(getter) ~= "function" then
        return {}
    end
    local ok, players = pcall(getter)
    if not ok or players == nil then
        return {}
    end
    return listValues(players)
end

local function findPlayerByName(name)
    if not Net.safeText(name, 96, false) then
        return nil
    end
    for _, player in ipairs(onlinePlayers()) do
        if usernameOf(player) == name then
            return player
        end
    end
    return nil
end

local function squareAt(x, y, z)
    local cellGetter = rawget(_G, "getCell")
    if type(cellGetter) ~= "function" then
        return nil
    end
    local okCell, cell = pcall(cellGetter)
    if not okCell or cell == nil or type(cell.getGridSquare) ~= "function" then
        return nil
    end
    local okSquare, square = pcall(function() return cell:getGridSquare(x, y, z) end)
    if okSquare then
        return square
    end
    return nil
end

local function nearbyBuildingSquare(player)
    if player == nil or type(player.getCurrentSquare) ~= "function" then
        return nil
    end
    local ok, origin = pcall(function() return player:getCurrentSquare() end)
    if not ok or origin == nil then
        return nil
    end
    local okX, x = pcall(function() return origin:getX() end)
    local okY, y = pcall(function() return origin:getY() end)
    local okZ, z = pcall(function() return origin:getZ() end)
    if not okX or not okY or not okZ then
        return nil
    end
    for radius = 1, 12 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local square = squareAt(x + dx, y + dy, z)
                    if square ~= nil and type(square.getBuilding) == "function" then
                        local okBuilding, building = pcall(function() return square:getBuilding() end)
                        if okBuilding and building ~= nil then
                            return square
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function nearbyFreeSquare(player)
    if player == nil or type(player.getCurrentSquare) ~= "function" then
        return nil
    end
    local ok, origin = pcall(function() return player:getCurrentSquare() end)
    if not ok or origin == nil then
        return nil
    end
    local x = origin:getX()
    local y = origin:getY()
    local z = origin:getZ()
    for radius = 1, 8 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local square = squareAt(x + dx, y + dy, z)
                    if square ~= nil and type(square.isFree) == "function" then
                        local okFree, free = pcall(function() return square:isFree(false) end)
                        if okFree and free == true then
                            return square
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function resolveWalkSquare(player, action, targetKind, targetLabel)
    if action == "FOLLOW" then
        if targetKind ~= "player" then
            return nil, "follow requires a named player target"
        end
        local target = findPlayerByName(targetLabel)
        if target == nil or target == player or type(target.getCurrentSquare) ~= "function" then
            return nil, "named follow target is not locally present"
        end
        local ok, square = pcall(function() return target:getCurrentSquare() end)
        if ok and square ~= nil then
            return square, "following the locally observed player"
        end
        return nil, "follow target has no local square"
    end
    if action == "MOVE_TO" then
        if targetKind == "current_position" then
            return player:getCurrentSquare(), "already at the local current position"
        elseif targetKind == "nearby_building" then
            local square = nearbyBuildingSquare(player)
            if square then
                return square, "moving to a locally resolved nearby building"
            end
            return nil, "no nearby building was locally resolved"
        end
    elseif action == "FLEE" or action == "RETREAT" then
        if targetKind == "escape_route" then
            local square = nearbyFreeSquare(player)
            if square then
                return square, "moving along a locally resolved free-square route"
            end
        end
    end
    return nil, "target kind has no verified local resolver"
end

local function actionQueueBusy(player)
    local queueType = rawget(_G, "ISTimedActionQueue")
    if queueType == nil or type(queueType.getTimedActionQueue) ~= "function" then
        return false
    end
    local ok, queue = pcall(function() return queueType.getTimedActionQueue(player) end)
    return ok and queue ~= nil and queue.current ~= nil
end

local function inventoryItems(player)
    local result = {}
    if player == nil or type(player.getInventory) ~= "function" then
        return result
    end
    local okInventory, inventory = pcall(function() return player:getInventory() end)
    if not okInventory or inventory == nil or type(inventory.getItems) ~= "function" then
        return result
    end
    local okItems, items = pcall(function() return inventory:getItems() end)
    if okItems then
        return listValues(items)
    end
    return result
end

local function itemMatches(item, requested)
    if not requested then
        return true
    end
    local wanted = string.lower(requested)
    for _, method in ipairs({"getFullType", "getName"}) do
        if type(item[method]) == "function" then
            local ok, value = pcall(function() return string.lower(tostring(item[method](item))) end)
            if ok and value == wanted then
                return true
            end
        end
    end
    return false
end

local function findFood(player, requested)
    for _, item in ipairs(inventoryItems(player)) do
        if type(item.IsFood) == "function" then
            local okFood, isFood = pcall(function() return item:IsFood() end)
            if okFood and isFood and itemMatches(item, requested) then
                return item
            end
        end
    end
    return nil
end

local function findDrink(player, requested)
    for _, item in ipairs(inventoryItems(player)) do
        if itemMatches(item, requested) and type(item.getFluidContainer) == "function" then
            local okContainer, container = pcall(function() return item:getFluidContainer() end)
            if okContainer and container ~= nil and type(container.isEmpty) == "function" then
                local okEmpty, empty = pcall(function() return container:isEmpty() end)
                if okEmpty and not empty then
                    return item
                end
            end
        end
    end
    return nil
end

local function findBandage(player, requested)
    for _, item in ipairs(inventoryItems(player)) do
        if itemMatches(item, requested) and type(item.getBandagePower) == "function" then
            local okPower, power = pcall(function() return item:getBandagePower() end)
            if okPower and type(power) == "number" and power > 0 then
                return item
            end
        end
    end
    return nil
end

local function injuredBodyPart(player)
    if player == nil or type(player.getBodyDamage) ~= "function" then
        return nil
    end
    local okDamage, damage = pcall(function() return player:getBodyDamage() end)
    if not okDamage or damage == nil or type(damage.getBodyPartCount) ~= "function"
        or rawget(_G, "BodyPartType") == nil or type(BodyPartType.FromIndex) ~= "function" then
        return nil
    end
    local okCount, count = pcall(function() return damage:getBodyPartCount() end)
    if not okCount or type(count) ~= "number" then
        return nil
    end
    for index = 0, count - 1 do
        local okType, bodyPartType = pcall(function() return BodyPartType.FromIndex(index) end)
        if okType then
            local okPart, part = pcall(function() return damage:getBodyPart(bodyPartType) end)
            if okPart and part ~= nil then
                local injured = false
                if type(part.HasInjury) == "function" then
                    pcall(function() injured = part:HasInjury() end)
                end
                if not injured and type(part.getBleedingTime) == "function" then
                    pcall(function() injured = part:getBleedingTime() > 0 end)
                end
                if injured then
                    return part
                end
            end
        end
    end
    return nil
end

local function enqueueTimedAction(player, requestId, action)
    local queueType = rawget(_G, "ISTimedActionQueue")
    if queueType == nil or type(queueType.add) ~= "function" then
        return false, "vanilla timed-action queue is unavailable"
    end
    if action == nil then
        return false, "vanilla timed action could not be created"
    end
    local ok = pcall(function() queueType.add(action) end)
    if not ok then
        return false, "vanilla timed-action queue rejected the action"
    end
    ClientAdapter.activeAction = {
        request_id = requestId,
        started_at = nowSeconds()
    }
    return true, "vanilla timed action queued"
end

local function executeAction(args)
    local action = args.action
    local requestId = args.request_id
    if type(requestId) ~= "string" or not Net.safeId(requestId, 128)
        or type(action) ~= "string" or not validActions[action]
        or not Net.safeText(args.mode, 16, false)
        or not Net.safeNumber(args.priority, 0, 3)
        or (args.target_kind ~= nil and not Net.safeText(args.target_kind, 32, false))
        or (args.target_label ~= nil and not Net.safeText(args.target_label, 96, false))
        or (args.text ~= nil and not Net.safeText(args.text, 240, false))
        or (args.item_name ~= nil and not Net.safeText(args.item_name, 96, false)) then
        return false, "typed action failed client validation"
    end
    if args.item_count ~= nil
        and (not Net.safeNumber(args.item_count, 1, 10) or math.floor(args.item_count) ~= args.item_count) then
        return false, "typed item count is invalid"
    end
    if not rememberRequest(requestId) then
        return true, "duplicate action ignored after at-most-once admission"
    end
    if not ClientAdapter.serverEnabled then
        return false, "GoblinEnabled is false"
    end
    local player = localPlayer()
    if player == nil or usernameOf(player) ~= Config.bodyUsername then
        return false, "Goblin player is not locally present"
    end
    if type(player.isDead) == "function" then
        local okDead, dead = pcall(function() return player:isDead() end)
        if okDead and dead then
            return false, "Goblin player is dead"
        end
    end
    if action == "NOOP" then
        return true, "wait accepted"
    elseif action == "SAY" then
        if not args.text then
            return false, "say action has no text"
        end
        local ok = pcall(function() player:Say(args.text) end)
        return ok, ok and "vanilla speech action executed" or "vanilla speech API failed"
    end
    if actionQueueBusy(player) then
        return false, "native timed-action queue is busy"
    end
    if action == "FOLLOW" or action == "MOVE_TO" or action == "FLEE" or action == "RETREAT" then
        local square, detail = resolveWalkSquare(player, action, args.target_kind, args.target_label)
        if square == nil then
            return false, detail
        end
        pcall(require, "TimedActions/WalkToTimedAction")
        local walkType = rawget(_G, "ISWalkToTimedAction")
        if walkType == nil or type(walkType.new) ~= "function" then
            return false, "vanilla walk timed action is unavailable"
        end
        local okAction, walk = pcall(function() return walkType:new(player, square) end)
        if not okAction then
            return false, "vanilla walk timed action could not be created"
        end
        local accepted, queueDetail = enqueueTimedAction(player, requestId, walk)
        return accepted, queueDetail .. "; " .. detail
    elseif action == "EAT" then
        pcall(require, "TimedActions/ISEatFoodAction")
        local food = findFood(player, args.item_name)
        if food == nil then
            return false, "no matching vanilla food is in the local inventory"
        end
        local eatType = rawget(_G, "ISEatFoodAction")
        if eatType == nil or type(eatType.new) ~= "function" then
            return false, "vanilla eat timed action is unavailable"
        end
        local okAction, eat = pcall(function() return eatType:new(player, food, 1.0) end)
        if not okAction then
            return false, "vanilla eat timed action could not be created"
        end
        return enqueueTimedAction(player, requestId, eat)
    elseif action == "DRINK" then
        pcall(require, "TimedActions/ISDrinkFromBottle")
        local drink = findDrink(player, args.item_name)
        if drink == nil then
            return false, "no matching filled vanilla container is in the local inventory"
        end
        local drinkType = rawget(_G, "ISDrinkFromBottle")
        if drinkType == nil or type(drinkType.new) ~= "function" then
            return false, "vanilla drink timed action is unavailable"
        end
        local okAction, actionObject = pcall(function()
            return drinkType:new(player, drink, args.item_count or 1)
        end)
        if not okAction then
            return false, "vanilla drink timed action could not be created"
        end
        return enqueueTimedAction(player, requestId, actionObject)
    elseif action == "BANDAGE" then
        pcall(require, "TimedActions/ISApplyBandage")
        local bandage = findBandage(player, args.item_name)
        local part = injuredBodyPart(player)
        if bandage == nil or part == nil then
            return false, "no matching vanilla bandage or injured body part is locally available"
        end
        local bandageType = rawget(_G, "ISApplyBandage")
        if bandageType == nil or type(bandageType.new) ~= "function" then
            return false, "vanilla bandage timed action is unavailable"
        end
        local okAction, actionObject = pcall(function()
            return bandageType:new(player, player, bandage, part, true)
        end)
        if not okAction then
            return false, "vanilla bandage timed action could not be created"
        end
        return enqueueTimedAction(player, requestId, actionObject)
    end
    return false, "action is typed but has no verified vanilla client adapter"
end

local function nearbyThreatMetrics(player)
    local result = {
        threat_level = "none",
        count_bucket = "none"
    }
    if player == nil or type(player.getCell) ~= "function" then
        return result
    end
    local okCell, cell = pcall(function() return player:getCell() end)
    if not okCell or cell == nil or type(cell.getZombieList) ~= "function"
        or type(player.getX) ~= "function" or type(player.getY) ~= "function"
        or type(player.getZ) ~= "function" then
        return result
    end
    local okZombies, zombies = pcall(function() return cell:getZombieList() end)
    local okX, originX = pcall(function() return player:getX() end)
    local okY, originY = pcall(function() return player:getY() end)
    local okZ, originZ = pcall(function() return player:getZ() end)
    if not okZombies or zombies == nil or not okX or not okY or not okZ then
        return result
    end
    local nearby = 0
    for _, zombie in ipairs(listValues(zombies)) do
        local dead = false
        if type(zombie.isDead) == "function" then
            pcall(function() dead = zombie:isDead() end)
        end
        if not dead and type(zombie.getX) == "function"
            and type(zombie.getY) == "function" and type(zombie.getZ) == "function" then
            local okZX, zombieX = pcall(function() return zombie:getX() end)
            local okZY, zombieY = pcall(function() return zombie:getY() end)
            local okZZ, zombieZ = pcall(function() return zombie:getZ() end)
            if okZX and okZY and okZZ and zombieZ == originZ then
                local dx = zombieX - originX
                local dy = zombieY - originY
                if dx * dx + dy * dy <= 14 * 14 then
                    nearby = nearby + 1
                end
            end
        end
        if nearby >= 8 then
            break
        end
    end
    if nearby >= 8 then
        result.threat_level = "overwhelming"
        result.count_bucket = "many"
    elseif nearby >= 2 then
        result.threat_level = "near"
        result.count_bucket = "few"
    end
    return result
end

local function injurySeverity(value)
    if type(value) ~= "number" or value <= 0.05 then
        return nil
    end
    if value >= 0.8 then
        return "critical"
    elseif value >= 0.4 then
        return "moderate"
    end
    return "minor"
end

local function stateMetrics(player)
    local metrics = {
        hunger = 0,
        thirst = 0,
        fatigue = 0,
        panic = 0,
        injury = 0,
        weapon_ready = false,
        has_food = false,
        has_water = false,
        has_medical = false,
        threat_level = "none",
        count_bucket = "none"
    }
    if player == nil then
        return metrics
    end
    local okStats, stats = pcall(function() return player:getStats() end)
    if okStats and stats ~= nil then
        for key, method in pairs({
            hunger = "getHunger",
            thirst = "getThirst",
            fatigue = "getFatigue",
            panic = "getPanic"
        }) do
            if type(stats[method]) == "function" then
                local ok, value = pcall(function() return stats[method](stats) end)
                if ok and Net.safeNumber(value, 0, 1) then
                    metrics[key] = value
                end
            end
        end
    end
    if type(player.getBodyDamage) == "function" then
        local okDamage, damage = pcall(function() return player:getBodyDamage() end)
        if okDamage and damage ~= nil and type(damage.getOverallBodyHealth) == "function" then
            local okHealth, health = pcall(function() return damage:getOverallBodyHealth() end)
            if okHealth and type(health) == "number" then
                metrics.injury = math.max(0, math.min(1, 1 - health / 100))
            end
        end
    end
    if type(player.getPrimaryHandItem) == "function" then
        local okWeapon, weapon = pcall(function() return player:getPrimaryHandItem() end)
        metrics.weapon_ready = okWeapon and weapon ~= nil
    end
    for _, item in ipairs(inventoryItems(player)) do
        if type(item.IsFood) == "function" then
            local okFood, isFood = pcall(function() return item:IsFood() end)
            if okFood and isFood then
                metrics.has_food = true
            end
        end
        if type(item.getFluidContainer) == "function" then
            local okContainer, container = pcall(function() return item:getFluidContainer() end)
            if okContainer and container ~= nil and type(container.isEmpty) == "function" then
                local okEmpty, empty = pcall(function() return container:isEmpty() end)
                if okEmpty and not empty then
                    metrics.has_water = true
                end
            end
        end
        if type(item.getBandagePower) == "function" then
            local okPower, power = pcall(function() return item:getBandagePower() end)
            if okPower and type(power) == "number" and power > 0 then
                metrics.has_medical = true
            end
        end
    end
    local threats = nearbyThreatMetrics(player)
    metrics.threat_level = threats.threat_level
    metrics.count_bucket = threats.count_bucket
    return metrics
end

local function sendState()
    local player = localPlayer()
    local alive = player ~= nil
    if player ~= nil and type(player.isDead) == "function" then
        local okDead, dead = pcall(function() return player:isDead() end)
        if okDead then
            alive = not dead
        end
    end
    local bodyPresent = ClientAdapter.serverEnabled
        and player ~= nil
        and usernameOf(player) == Config.bodyUsername
        and alive
        and ClientAdapter.lifecycle == "active"
    local metrics = stateMetrics(player)
    local args = {
        client_username = clientUsername(),
        body_present = bodyPresent == true,
        alive = alive == true,
        character_state = ClientAdapter.lifecycle,
        character_generation = ClientAdapter.generation or 0,
        client_catalog_version = ClientAdapter.catalog and ClientAdapter.catalog.version or nil,
        hunger = metrics.hunger,
        thirst = metrics.thirst,
        fatigue = metrics.fatigue,
        panic = metrics.panic,
        injury = metrics.injury,
        threat_level = metrics.threat_level,
        mode = validModes[ClientAdapter.mode] and ClientAdapter.mode or "SAFE",
        weapon_ready = metrics.weapon_ready,
        has_food = metrics.has_food,
        has_water = metrics.has_water,
        has_medical = metrics.has_medical,
        action_busy = player ~= nil and actionQueueBusy(player) or false,
        last_action = ClientAdapter.activeAction and "timed_action" or nil
    }
    if Net.safeTable(args) then
        local sent = Net.sendClient("state", args)
        if sent and (ClientAdapter.lastThreatLevel ~= metrics.threat_level
            or ClientAdapter.lastThreatBucket ~= metrics.count_bucket) then
            if ClientAdapter.lastThreatLevel ~= nil then
                sendEvent("threat_changed", {
                    threat_level = metrics.threat_level,
                    count_bucket = metrics.count_bucket
                })
            end
            ClientAdapter.lastThreatLevel = metrics.threat_level
            ClientAdapter.lastThreatBucket = metrics.count_bucket
        end
        local severity = injurySeverity(metrics.injury)
        if sent and severity ~= nil and severity ~= ClientAdapter.lastInjurySeverity then
            sendEvent("injury", {
                severity = severity,
                body_part = "overall"
            })
        end
        if severity ~= nil then
            ClientAdapter.lastInjurySeverity = severity
        end
        ClientAdapter.lastState = nowSeconds()
    end
end

local function adoptVisibleLiveBody(player)
    -- A reconnect can leave a native PZ player visible while the integration
    -- still holds the durable recreation boundary from the previous session.
    -- If no creation screen or recreation request is active, adopt the live
    -- native body as the next generation so control can resume immediately.
    if player == nil or usernameOf(player) ~= Config.bodyUsername
        or ClientAdapter.lifecycle ~= "recreate_required"
        or ClientAdapter.pendingCharacter ~= nil
        or ClientAdapter.defaultCreationRequest ~= nil then
        return false
    end
    local coop = rawget(_G, "CoopCharacterCreation")
    if type(coop) == "table" and coop.instance ~= nil then
        return false
    end
    if type(player.isDead) == "function" then
        local okDead, dead = pcall(function() return player:isDead() end)
        if not okDead or dead then
            return false
        end
    end
    if (ClientAdapter.generation or 0) < 1 then
        ClientAdapter.generation = 1
    end
    ClientAdapter.lifecycle = "active"
    ClientAdapter.restoreOnCreate = false
    local data = nil
    if type(player.getModData) == "function" then
        local ok, modData = pcall(function() return player:getModData() end)
        if ok then
            data = modData
        end
    end
    if data ~= nil then
        data.GoblinSurvivor = data.GoblinSurvivor or {}
        data.GoblinSurvivor.generation = ClientAdapter.generation
        data.GoblinSurvivor.lifecycle = "active"
        data.GoblinSurvivor.appearance = ClientAdapter.appearance
    end
    log("adopting the visible live native body for generation " .. tostring(ClientAdapter.generation))
    sendState()
    return true
end

local function firstListItem(listbox)
    if listbox == nil or type(listbox.items) ~= "table"
        or #listbox.items < 1 then
        return nil
    end
    local index = listbox.selected
    if type(index) ~= "number" or index < 1 or index > #listbox.items then
        index = 1
    end
    local row = listbox.items[index]
    return row and row.item or nil
end

local function prepareDefaultCharacterCreation()
    local coop = rawget(_G, "CoopCharacterCreation")
    local mainScreen = rawget(_G, "MainScreen")
    local creation = type(coop) == "table" and coop.instance or nil
    if creation == nil or mainScreen == nil or mainScreen.instance == nil
        or creation.charCreationMain == nil
        or creation.charCreationProfession == nil
        or mainScreen.instance.desc == nil then
        return false, "the native multiplayer character-creation screen is not ready"
    end

    local mapSpawn = creation.mapSpawnSelect
    if mapSpawn ~= nil and mapSpawn.selectedRegion == nil then
        local region = nil
        if type(mapSpawn.useDefaultSpawnRegion) == "function" then
            local okDefault, selected = pcall(function()
                return mapSpawn:useDefaultSpawnRegion()
            end)
            if okDefault then
                region = selected
            end
        end
        if region == nil then
            local listed = firstListItem(mapSpawn.listbox)
            if type(listed) == "table" and listed.region ~= nil then
                region = listed.region
            end
        end
        if region ~= nil then
            mapSpawn.selectedRegion = region
        end
    end
    if mapSpawn ~= nil and mapSpawn.selectedRegion == nil then
        return false, "vanilla spawn-region selection is unavailable"
    end
    if mapSpawn ~= nil and mapSpawn.selectedRegion ~= nil then
        local region = mapSpawn.selectedRegion
        local key = region.key or region.name
        if type(setSpawnRegion) == "function" and key ~= nil then
            pcall(setSpawnRegion, key)
        end
        if type(mapSpawn.setVisible) == "function" then
            pcall(function() mapSpawn:setVisible(false) end)
        end
    end

    local profession = creation.charCreationProfession
    if profession.profession == nil
        and type(profession.onSelectProf) == "function" then
        local definition = firstListItem(profession.listboxProf)
        if definition == nil then
            return false, "vanilla profession list is unavailable"
        end
        local selected = pcall(function() profession:onSelectProf(definition) end)
        if not selected or profession.profession == nil then
            return false, "vanilla default profession selection failed"
        end
    end
    if profession.profession == nil then
        return false, "vanilla profession selection is unavailable"
    end

    if type(profession.setVisible) == "function" then
        pcall(function() profession:setVisible(false, creation.joypadData) end)
    end
    local main = creation.charCreationMain
    if type(main.setVisible) == "function" then
        pcall(function() main:setVisible(true, creation.joypadData) end)
    end
    if type(main.onRandomCharacter) == "function"
        and not pcall(function() main:onRandomCharacter() end) then
        return false, "vanilla default character randomization failed"
    end
    if main.forenameEntry ~= nil
        and type(main.forenameEntry.setText) == "function" then
        main.forenameEntry:setText("Goblin")
    end
    if main.surnameEntry ~= nil
        and type(main.surnameEntry.setText) == "function" then
        main.surnameEntry:setText("")
    end
    return true, "vanilla default character is ready to submit"
end

local function queueDefaultCharacterCreation(requestId, generation)
    if ClientAdapter.pendingCharacter ~= nil then
        return ClientAdapter.pendingCharacter.generation == generation
    end
    local prepared = prepareDefaultCharacterCreation()
    if not prepared then
        return false
    end
    ClientAdapter.pendingCharacter = {
        request_id = requestId,
        generation = generation,
        default = true
    }
    ClientAdapter.pendingAcceptAt = nowSeconds() + 0.5
    ClientAdapter.lifecycle = "creation_pending"
    ClientAdapter.generation = generation
    -- The native default path intentionally does not reuse the dead body's
    -- appearance. The vanilla UI owns the new visual state.
    ClientAdapter.restoreOnCreate = false
    sendState()
    log("vanilla recreation queued for generation " .. tostring(generation))
    return true
end

local function openRecreationScreen(force)
    if (ClientAdapter.lifecycle ~= "dead" and force ~= true)
        or ClientAdapter.pendingCharacter ~= nil then
        return false
    end
    local coop = rawget(_G, "CoopCharacterCreation")
    if type(coop) ~= "table" then
        return false
    end
    if coop.instance ~= nil then
        ClientAdapter.lifecycle = "recreate_required"
        sendState()
        return true
    end
    local now = nowSeconds()
    if now - ClientAdapter.recreationAttemptAt < 1 then
        return false
    end
    ClientAdapter.recreationAttemptAt = now
    if type(coop.newPlayerMouse) ~= "function" then
        return false
    end
    local ok = pcall(function() coop.newPlayerMouse() end)
    if not ok or coop.instance == nil then
        return false
    end
    -- This is the vanilla multiplayer new-player screen.  Advertising the
    -- transition only after the screen exists prevents the agent from
    -- publishing a creation command while the old dead body is still the
    -- active UI context.
    ClientAdapter.lifecycle = "recreate_required"
    sendState()
    return true
end

local function sendCatalog()
    if ClientAdapter.catalog == nil then
        return false
    end
    local sent = Net.sendClient("catalog", {
        client_username = clientUsername(),
        catalog = ClientAdapter.catalog
    })
    if sent then
        ClientAdapter.catalogSentVersion = ClientAdapter.catalog.version
    end
    return sent
end

local function sendHello()
    local manifest, build = clientManifest()
    local args = {
        client_username = clientUsername(),
        game_build = build or "unknown"
    }
    if manifest ~= nil then
        args.client_mod_manifest = manifest
    end
    if ClientAdapter.catalog ~= nil then
        args.catalog_version = ClientAdapter.catalog.version
    end
    if Net.safeTable(args) and Net.sendClient("hello", args) then
        ClientAdapter.lastHello = nowSeconds()
        return true
    end
    return false
end

local function validWelcome(args)
    if type(args) ~= "table" or not Net.safeTable(args)
        or type(args.status) ~= "string"
        or type(args.server_enabled) ~= "boolean"
        or type(args.expected_username) ~= "string"
        or args.expected_username ~= Config.bodyUsername
        or type(args.control_ready) ~= "boolean"
        or type(args.catalog_required) ~= "boolean"
        or type(args.character_state) ~= "string"
        or not validStates[args.character_state]
        or type(args.character_generation) ~= "number"
        or math.floor(args.character_generation) ~= args.character_generation
        or args.character_generation < 0 then
        return false
    end
    if args.server_manifest ~= nil and not Net.validManifest(args.server_manifest) then
        return false
    end
    return true
end

local function onWelcome(args)
    if not validWelcome(args) then
        return
    end
    ClientAdapter.serverEnabled = args.server_enabled
    ClientAdapter.serverManifest = args.server_manifest
    if ClientAdapter.pendingCharacter == nil then
        if args.character_generation > 0 then
            ClientAdapter.generation = args.character_generation
        end
        if validStates[args.character_state] and args.character_state ~= "fresh" then
            ClientAdapter.lifecycle = args.character_state
        end
    end
    if ClientAdapter.catalog == nil then
        ClientAdapter.catalog = buildCatalog()
    end
    if ClientAdapter.catalog ~= nil and ClientAdapter.catalogSentVersion ~= ClientAdapter.catalog.version then
        sendCatalog()
    end
end

local function validServerAction(args)
    if type(args) ~= "table" or not Net.safeTable(args) then
        return false
    end
    local allowed = {
        request_id = true,
        action = true,
        mode = true,
        priority = true,
        target_kind = true,
        target_label = true,
        text = true,
        item_name = true,
        item_count = true
    }
    for key, _ in pairs(args) do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    return true
end

local function onAction(args)
    if not validServerAction(args) then
        return
    end
    local accepted, detail = executeAction(args)
    if accepted and validModes[args.mode] then
        ClientAdapter.mode = args.mode
    end
    sendActionResult(args.request_id, args.action, accepted and "accepted" or "rejected", detail)
    if accepted then
        sendState()
    end
end

local function objectText(value, methods, maximum)
    if type(value) == "string" then
        return Net.safeText(value, maximum, false) and value or nil
    end
    if value == nil then
        return nil
    end
    for _, method in ipairs(methods) do
        local okMethod, callable = pcall(function() return value[method] end)
        if okMethod and type(callable) == "function" then
            local okValue, result = pcall(function() return callable(value) end)
            result = stringValue(result)
            if okValue and result and Net.safeText(result, maximum, false) then
                return result
            end
        end
    end
    return nil
end

local function onChatMessage(message)
    local text = objectText(message, {"getText", "getMessage"}, 240)
    local speaker = objectText(
        message,
        {"getAuthor", "getUsername", "getPlayerName", "getName"},
        96
    )
    if text == nil or speaker == nil or speaker == Config.bodyUsername then
        return
    end
    sendEvent("chat", {speaker = speaker, text = text})
end

function ClientAdapter.onServerCommand(module, command, args)
    if module ~= Net.module then
        return
    end
    if command == "welcome" then
        onWelcome(args)
    elseif command == "character_create" then
        handleCharacterCreate(args)
    elseif command == "recreate" then
        if ClientAdapter.serverEnabled and ClientAdapter.pendingCharacter == nil then
            local requestId = args and args.request_id
            local generation = args and args.generation
            if type(requestId) ~= "string" or not Net.safeId(requestId, 128)
                or (generation ~= nil
                    and (type(generation) ~= "number"
                        or math.floor(generation) ~= generation
                        or generation < 1
                        or generation > 2147483647)) then
                return
            end
            if generation == nil then
                generation = (ClientAdapter.generation or 0) + 1
            end
            if generation < 1 then
                return
            end
            ClientAdapter.lifecycle = "dead"
            ClientAdapter.deathStartedAt = nowSeconds()
            ClientAdapter.defaultCreationRequest = {
                request_id = requestId,
                generation = generation
            }
            ClientAdapter.restoreOnCreate = false
            openRecreationScreen(true)
            queueDefaultCharacterCreation(requestId, generation)
        end
    elseif command == "action" then
        onAction(args)
    end
end

local function restoreSavedAppearance(player)
    if not ClientAdapter.restoreOnCreate or ClientAdapter.appearance == nil
        or ClientAdapter.catalog == nil then
        return false
    end
    local appearance = ClientAdapter.appearance
    if not validProposal(appearance, ClientAdapter.catalog.version) then
        return false
    end
    -- Reapplying a saved appearance is reserved for a confirmed death
    -- respawn. Reconnects while active do not reset natural clothing.
    local visual = player.getHumanVisual and player:getHumanVisual() or nil
    local skin = ClientAdapter.catalogMaps.skin_tone[appearance.skin_tone]
    if visual and skin then
        pcall(function() visual:setSkinTextureIndex(skin.index - 1) end)
    end
    local hair = ClientAdapter.catalogMaps.hair_style[appearance.hair_style]
    if visual and hair then
        pcall(function() visual:setHairModel(hair) end)
    end
    local hairColor = ClientAdapter.catalogMaps.hair_color[appearance.hair_color]
    if visual and hairColor and ImmutableColor ~= nil then
        pcall(function()
            local color = ImmutableColor.new(hairColor.r, hairColor.g, hairColor.b, 1)
            visual:setHairColor(color)
            visual:setNaturalHairColor(color)
        end)
    end
    if type(player.setWornItem) == "function" then
        for category, itemId in pairs(appearance.clothing) do
            local location = ClientAdapter.catalogMaps.bodyLocation[category]
            local fullType = ClientAdapter.catalogMaps[category]
                and ClientAdapter.catalogMaps[category][itemId]
            if location and fullType then
                local okItem, item = pcall(instanceItem, fullType)
                if okItem and item and type(item.getBodyLocation) == "function" then
                    pcall(function()
                        player:setWornItem(item:getBodyLocation(), item)
                    end)
                end
            end
        end
        for _, itemId in ipairs(appearance.accessories or {}) do
            local accessory = ClientAdapter.catalogMaps.accessory
                and ClientAdapter.catalogMaps.accessory[itemId]
            if type(accessory) == "table"
                and type(accessory.full_type) == "string"
                and type(accessory.body_location) == "string" then
                local okItem, item = pcall(instanceItem, accessory.full_type)
                if okItem and item ~= nil then
                    local location = accessory.body_location
                    if type(item.getBodyLocation) == "function" then
                        local okLocation, itemLocation = pcall(function()
                            return item:getBodyLocation()
                        end)
                        if okLocation and itemLocation ~= nil then
                            location = itemLocation
                        end
                    end
                    pcall(function() player:setWornItem(location, item) end)
                end
            end
        end
        pcall(function() player:resetModel() end)
    end
    ClientAdapter.restoreOnCreate = false
    return true
end

function ClientAdapter.onCreatePlayer(_playerIndex, player)
    if player == nil or usernameOf(player) ~= Config.bodyUsername then
        return
    end
    local data = nil
    if type(player.getModData) == "function" then
        local ok, modData = pcall(function() return player:getModData() end)
        if ok then
            data = modData
        end
    end
    local record = data and data.GoblinSurvivor or nil
    if type(record) == "table" and type(record.appearance) == "table"
        and ClientAdapter.appearance == nil then
        ClientAdapter.appearance = record.appearance
    end
    local recordGeneration = type(record) == "table" and record.generation or 0
    if type(recordGeneration) ~= "number" or recordGeneration < 1 then
        recordGeneration = 0
    end
    if recordGeneration > 0 and ClientAdapter.generation == 0 then
        ClientAdapter.generation = recordGeneration
    end

    local recordLifecycle = type(record) == "table" and record.lifecycle or nil
    local wasRecreation = recordLifecycle == "dead"
        or recordLifecycle == "recreate_required"
        or ClientAdapter.lifecycle == "creation_pending"
    local deathBoundary = ClientAdapter.lifecycle == "dead"
        or ClientAdapter.lifecycle == "recreate_required"
        or recordLifecycle == "dead"
        or recordLifecycle == "recreate_required"
    local creationPending = ClientAdapter.lifecycle == "creation_pending"
        and ClientAdapter.generation > 0
    local existingActive = not deathBoundary
        and (ClientAdapter.generation > 0 or recordLifecycle == "active")
    local adoptExisting = not deathBoundary
        and ClientAdapter.generation == 0
        and recordGeneration == 0
        and record == nil
        and ClientAdapter.pendingCharacter == nil

    if creationPending or existingActive or adoptExisting then
        ClientAdapter.lifecycle = "active"
    elseif deathBoundary then
        -- A player object appearing after death is not proof of a new
        -- generation.  Keep the old death boundary until the server sends a
        -- validated character_create command and PZ accepts it.
        ClientAdapter.lifecycle = "recreate_required"
        sendState()
        return
    else
        ClientAdapter.lifecycle = "fresh"
    end

    if not creationPending and type(record) == "table" and record.lifecycle == "dead" then
        ClientAdapter.restoreOnCreate = true
    end
    if data ~= nil then
        data.GoblinSurvivor = data.GoblinSurvivor or {}
        data.GoblinSurvivor.generation = ClientAdapter.generation
        data.GoblinSurvivor.lifecycle = "active"
        data.GoblinSurvivor.appearance = ClientAdapter.appearance
    end
    restoreSavedAppearance(player)
    sendState()
    if wasRecreation and ClientAdapter.lifecycle == "active" then
        sendEvent("respawn", {cooldown_seconds = 0})
    end
end

function ClientAdapter.onPlayerDeath(player)
    if player == nil or usernameOf(player) ~= Config.bodyUsername then
        return
    end
    ClientAdapter.lifecycle = "dead"
    ClientAdapter.deathStartedAt = nowSeconds()
    ClientAdapter.recreationAttemptAt = 0
    ClientAdapter.restoreOnCreate = true
    local data = nil
    if type(player.getModData) == "function" then
        local ok, modData = pcall(function() return player:getModData() end)
        if ok then
            data = modData
        end
    end
    if data ~= nil then
        data.GoblinSurvivor = data.GoblinSurvivor or {}
        data.GoblinSurvivor.generation = ClientAdapter.generation
        data.GoblinSurvivor.lifecycle = "dead"
        data.GoblinSurvivor.appearance = ClientAdapter.appearance
    end
    sendEvent("death", {cause = "unknown"})
    sendState()
end

function ClientAdapter.onTick()
    local pumpNow = nowSeconds()
    -- Build 42 can pause the normal client tick while the multiplayer
    -- character-creation screen is open.  The render tick remains live, so
    -- the same bounded transport pump is also registered there.  Keep one
    -- throttle shared by both hooks to avoid duplicate network messages.
    if ClientAdapter.lastPump > 0 and pumpNow - ClientAdapter.lastPump < 0.2 then
        return
    end
    ClientAdapter.lastPump = pumpNow
    finishCharacterCreate()
    local player = localPlayer()
    adoptVisibleLiveBody(player)
    if player ~= nil and usernameOf(player) == Config.bodyUsername
        and ClientAdapter.lifecycle == "active"
        and type(player.isDead) == "function" then
        local okDead, dead = pcall(function() return player:isDead() end)
        if okDead and dead then
            -- OnPlayerDeath is the normal signal; this fallback covers a
            -- reconnect or Build 42 timing edge where the event is delayed.
            ClientAdapter.onPlayerDeath(player)
        end
    end
    if ClientAdapter.lifecycle == "dead"
        and nowSeconds() - ClientAdapter.deathStartedAt >= 1 then
        openRecreationScreen()
    end
    if ClientAdapter.defaultCreationRequest ~= nil
        and ClientAdapter.pendingCharacter == nil
        and ClientAdapter.lifecycle ~= "active"
        and ClientAdapter.lifecycle ~= "creation_pending" then
        local request = ClientAdapter.defaultCreationRequest
        if openRecreationScreen(true) then
            queueDefaultCharacterCreation(request.request_id, request.generation)
        end
    end
    if player ~= nil and usernameOf(player) == Config.bodyUsername then
        restoreSavedAppearance(player)
    end
    local now = nowSeconds()
    if ClientAdapter.activeAction ~= nil then
        if player == nil or not actionQueueBusy(player)
            or now - ClientAdapter.activeAction.started_at > 1800 then
            ClientAdapter.activeAction = nil
        end
    end
    if ClientAdapter.lastHello == 0 or now - ClientAdapter.lastHello >= 5 then
        sendHello()
    end
    if ClientAdapter.catalog == nil and (ClientAdapter.lastHello > 0 or now - ClientAdapter.lastHello >= 1) then
        ClientAdapter.catalog = buildCatalog()
    end
    if ClientAdapter.catalog ~= nil
        and ClientAdapter.catalogSentVersion ~= ClientAdapter.catalog.version
        and ClientAdapter.lastHello > 0 then
        sendCatalog()
    end
    if ClientAdapter.lastState == 0 or now - ClientAdapter.lastState >= 5 then
        sendState()
    end
end

function ClientAdapter.start()
    if ClientAdapter.started then
        return ClientAdapter
    end
    if Events == nil then
        return ClientAdapter
    end
    if Events.OnServerCommand and type(Events.OnServerCommand.Add) == "function" then
        Events.OnServerCommand.Add(ClientAdapter.onServerCommand)
    end
    if Events.OnCreatePlayer and type(Events.OnCreatePlayer.Add) == "function" then
        Events.OnCreatePlayer.Add(ClientAdapter.onCreatePlayer)
    end
    if Events.OnPlayerDeath and type(Events.OnPlayerDeath.Add) == "function" then
        Events.OnPlayerDeath.Add(ClientAdapter.onPlayerDeath)
    end
    if Events.OnTick and type(Events.OnTick.Add) == "function" then
        Events.OnTick.Add(ClientAdapter.onTick)
    end
    if Events.OnRenderTick and type(Events.OnRenderTick.Add) == "function" then
        Events.OnRenderTick.Add(ClientAdapter.onTick)
    end
    if Events.OnGameStart and type(Events.OnGameStart.Add) == "function" then
        Events.OnGameStart.Add(function() sendHello() end)
    end
    if Events.OnConnected and type(Events.OnConnected.Add) == "function" then
        -- Build 42 fires this before a new multiplayer player exists.  The
        -- server still supplies a transport client id, so this is the
        -- handshake point that enables the initial character command and
        -- the post-death recreation command without requiring a manual
        -- character first.
        Events.OnConnected.Add(function()
            sendHello()
            sendState()
        end)
    end
    if Events.OnGameTimeLoaded and type(Events.OnGameTimeLoaded.Add) == "function" then
        Events.OnGameTimeLoaded.Add(function() sendHello(); sendState() end)
    end
    if Events.OnAddMessage and type(Events.OnAddMessage.Add) == "function" then
        Events.OnAddMessage.Add(onChatMessage)
    end
    if Events.OnChatMessage and type(Events.OnChatMessage.Add) == "function" then
        Events.OnChatMessage.Add(onChatMessage)
    end
    ClientAdapter.started = true
    sendHello()
    return ClientAdapter
end

return ClientAdapter

local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")

local Manifest = {}

local function textValue(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        return value
    end
    local ok, converted = pcall(tostring, value)
    if ok and type(converted) == "string" then
        return converted
    end
    return nil
end

local function optionValue(name, defaultValue)
    local ok, value = pcall(Config.readOption, name, defaultValue)
    if ok and value ~= nil then
        return value
    end
    return defaultValue
end

local function splitList(value, pattern, maximum)
    value = textValue(value)
    if value == nil then
        return nil
    end
    if value == "" then
        return {}
    end
    local result = {}
    local seen = {}
    for item in string.gmatch(value .. ";", "([^;]*);") do
        if item == "" or #item > 128 or string.find(item, pattern) == nil then
            return nil
        end
        local folded = string.lower(item)
        if seen[folded] then
            return nil
        end
        seen[folded] = true
        table.insert(result, item)
        if #result > maximum then
            return nil
        end
    end
    return result
end

local function coreBuild()
    local coreGetter = rawget(_G, "getCore")
    if type(coreGetter) == "function" then
        local ok, core = pcall(coreGetter)
        if ok and core ~= nil then
            local okVersion, version = pcall(function() return tostring(core:getVersion()) end)
            local okSha, sha = pcall(function() return tostring(core:getGitSha()) end)
            if okVersion and okSha
                and version ~= "" and version ~= "nil"
                and sha ~= "" and sha ~= "nil" then
                local build = version .. " " .. sha
                if #build <= 64
                    and string.find(build, "^[A-Za-z0-9][A-Za-z0-9%._%+%- ]*$") then
                    return build
                end
            end
        end
    end
    local override = textValue(Config.gameBuildOverride)
    if override and #override > 0
        and #override <= 64
        and string.find(override, "^[A-Za-z0-9][A-Za-z0-9%._%+%- ]*$") then
        return override
    end
    local configured = textValue(optionValue("GoblinGameBuild", ""))
    if configured and #configured > 0
        and #configured <= 64
        and string.find(configured, "^[A-Za-z0-9][A-Za-z0-9%._%+%- ]*$") then
        return configured
    end
    return nil
end

function Manifest.get()
    local build = coreBuild()
    local mods = splitList(
        optionValue("Mods", ""),
        "^[A-Za-z0-9][A-Za-z0-9%._:%- ]*$",
        4096
    )
    local workshopItems = splitList(
        optionValue("WorkshopItems", ""),
        "^[0-9][0-9]*$",
        4096
    )
    local digest = textValue(Config.goblinSurvivorSha256)
    if not build or not mods or not workshopItems
        or not digest or #digest ~= 64
        or string.find(digest, "^[0-9a-f]+$") == nil then
        return nil
    end
    local manifest = {
        game_build = build,
        mods = mods,
        workshop_items = workshopItems,
        goblin_survivor_sha256 = digest
    }
    if not Net.validManifest(manifest) then
        return nil
    end
    local hasGoblin = false
    for _, modId in ipairs(mods) do
        if modId == "GoblinSurvivor" then
            hasGoblin = true
            break
        end
    end
    if not hasGoblin then
        return nil
    end
    return manifest
end

function Manifest.parity(serverManifest, clientManifest)
    if type(serverManifest) ~= "table" then
        return "missing", "server manifest is unavailable"
    end
    if type(clientManifest) ~= "table" then
        return "missing", "client manifest is unavailable"
    end
    if not Net.validManifest(serverManifest) or not Net.validManifest(clientManifest) then
        return "invalid", "one or both manifests are malformed"
    end
    if serverManifest.game_build ~= clientManifest.game_build then
        return "mismatch", "game build differs"
    end
    if not Net.sameList(serverManifest.mods, clientManifest.mods) then
        return "mismatch", "ordered Mods loadout differs"
    end
    if not Net.sameList(serverManifest.workshop_items, clientManifest.workshop_items) then
        return "mismatch", "ordered WorkshopItems loadout differs"
    end
    if serverManifest.goblin_survivor_sha256 ~= clientManifest.goblin_survivor_sha256 then
        return "mismatch", "GoblinSurvivor content hash differs"
    end
    return "verified", "server and client manifests match"
end

local function hasMod(manifest, wanted)
    if type(manifest) ~= "table" or type(manifest.mods) ~= "table" then
        return false
    end
    for _, modId in ipairs(manifest.mods) do
        if modId == wanted then
            return true
        end
    end
    return false
end

function Manifest.controlCompatibility(serverManifest, clientManifest)
    -- Project Zomboid owns the ordinary multiplayer Mods/WorkshopItems
    -- handshake.  The bridge only needs an active GoblinSurvivor client with
    -- the same Build 42 build and the same deployed GoblinSurvivor bytes.
    -- Manifest.parity remains available as an exact diagnostic audit.
    if type(serverManifest) ~= "table" then
        return "missing", "server manifest is unavailable"
    end
    if type(clientManifest) ~= "table" then
        return "missing", "client manifest is unavailable"
    end
    if not Net.validManifest(serverManifest) or not Net.validManifest(clientManifest) then
        return "invalid", "one or both manifests are malformed"
    end
    if not hasMod(clientManifest, "GoblinSurvivor") then
        return "mismatch", "GoblinSurvivor is not active on the client"
    end
    if serverManifest.game_build ~= clientManifest.game_build then
        return "mismatch", "game build differs"
    end
    if serverManifest.goblin_survivor_sha256 ~= clientManifest.goblin_survivor_sha256 then
        return "mismatch", "GoblinSurvivor content hash differs"
    end
    return "compatible", "Build 42 and GoblinSurvivor content match"
end

return Manifest

local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local CharacterCatalog = require("GoblinSurvivor/CharacterCatalog")
local CharacterController = require("GoblinSurvivor/CharacterController")
local ClientBridge = require("GoblinSurvivor/ClientBridge")

local Telemetry = {}

-- A full Build 42 clothing catalog is too large for one bounded runtime
-- record. Publish it as small, replaceable chunks and write the ready
-- metadata last. The agent accepts only a complete epoch, so a partial
-- write or a server restart never becomes a usable catalog.
local catalogChunkSize = 32
local maxCatalogChunks = 1024

local function nowMilliseconds()
    return os.time() * 1000
end

local function characterFields()
    return CharacterController.state()
end

local function sortedKeys(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end
    for key, _ in pairs(value) do
        if type(key) == "string" then
            table.insert(result, key)
        end
    end
    table.sort(result)
    return result
end

local function catalogChunks(catalog)
    if type(catalog) ~= "table" or type(catalog.options) ~= "table" then
        return {}
    end
    local result = {}
    for _, category in ipairs(sortedKeys(catalog.options)) do
        local values = catalog.options[category]
        if type(values) ~= "table" or #values < 1 then
            return {}
        end
        for first = 1, #values, catalogChunkSize do
            local last = math.min(first + catalogChunkSize - 1, #values)
            local chunkValues = {}
            for index = first, last do
                table.insert(chunkValues, values[index])
            end
            table.insert(result, {
                [category] = chunkValues
            })
        end
    end
    return result
end

local function catalogEpoch()
    return tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
end

function Telemetry.writeCatalog()
    local catalog = CharacterCatalog.get()
    local chunks = catalogChunks(catalog)
    if type(catalog) ~= "table"
        or type(catalog.version) ~= "string"
        or #chunks < 1
        or #chunks > maxCatalogChunks then
        return false
    end

    local epoch = catalogEpoch()
    local count = #chunks
    local publishing = {
        protocol = Config.protocol,
        request_id = "zomboid-catalog-meta",
        timestamp_ms = nowMilliseconds(),
        type = "state.catalog_meta",
        status = "publishing",
        catalog_version = catalog.version,
        catalog_epoch = epoch,
        chunk_count = count
    }
    if not IPC.publishRuntime("zomboid-catalog-meta", publishing) then
        return false
    end

    for index, options in ipairs(chunks) do
        local name = string.format("zomboid-catalog-%04d", index)
        local message = {
            protocol = Config.protocol,
            request_id = name,
            timestamp_ms = nowMilliseconds(),
            type = "state.catalog_chunk",
            catalog_version = catalog.version,
            catalog_epoch = epoch,
            chunk_index = index,
            chunk_count = count,
            options = options
        }
        if not IPC.publishRuntime(name, message) then
            return false
        end
    end

    local ready = {
        protocol = Config.protocol,
        request_id = "zomboid-catalog-meta",
        timestamp_ms = nowMilliseconds(),
        type = "state.catalog_meta",
        status = "ready",
        catalog_version = catalog.version,
        catalog_epoch = epoch,
        chunk_count = count
    }
    return IPC.publishRuntime("zomboid-catalog-meta", ready)
end

local function clientFields()
    local state = ClientBridge.state()
    local parityStatus, parityReason = ClientBridge.parityStatus()
    local compatibilityStatus, compatibilityReason = ClientBridge.controlCompatibilityStatus()
    local fields = {
        server_mod_manifest = ClientBridge.serverManifest(),
        client_mod_manifest = ClientBridge.manifest(),
        client_mod_parity = parityStatus,
        client_mod_parity_reason = parityReason,
        client_mod_compatibility = compatibilityStatus,
        client_mod_compatibility_reason = compatibilityReason,
        client_control_ready = ClientBridge.clientControlReady(),
        body_present = ClientBridge.bodyPresent(),
        alive = state.alive == true,
        hunger = state.hunger or 0,
        thirst = state.thirst or 0,
        fatigue = state.fatigue or 0,
        panic = state.panic or 0,
        injury = state.injury or 0,
        threat_level = state.threat_level or "none",
        mode = state.mode or "SAFE",
        weapon_ready = state.weapon_ready == true,
        has_food = state.has_food == true,
        has_water = state.has_water == true,
        has_medical = state.has_medical == true,
        action_busy = state.action_busy == true,
        last_action = state.last_action
    }
    local characterResult, actionResult = ClientBridge.lastResults()
    if characterResult ~= nil then
        fields.character_result_status = characterResult.status
        fields.character_result_detail = characterResult.detail
    end
    if actionResult ~= nil then
        fields.action_result_status = actionResult.status
        fields.action_result_detail = actionResult.detail
        fields.action_result_request_id = actionResult.request_id
    end
    return fields
end

local function bodyMode()
    if not Config.enabled then
        return "disabled"
    end
    if ClientBridge.bodyPresent() then
        return "live_client"
    end
    return "sensor_only"
end

local function heartbeat(status)
    local message = {
        protocol = Config.protocol,
        request_id = "zomboid-heartbeat",
        timestamp_ms = nowMilliseconds(),
        type = "runtime.heartbeat",
        status = status,
        body_mode = bodyMode(),
        feature_enabled = Config.enabled,
        mode = "SAFE",
        body_present = false,
        client_mod_parity = "missing",
        client_control_ready = false
    }
    local client = clientFields()
    for key, value in pairs(client) do
        message[key] = value
    end
    local character = characterFields()
    message.character_state = character.character_state
    message.character_generation = character.character_generation
    return message
end

function Telemetry.writeHeartbeat()
    local status = Config.enabled and "online" or "disabled"
    return IPC.publishRuntime("zomboid-heartbeat", heartbeat(status))
end

function Telemetry.writeState()
    Telemetry.writeCatalog()
    local message = {
        protocol = Config.protocol,
        request_id = "zomboid-state",
        timestamp_ms = nowMilliseconds(),
        type = "state.snapshot",
        status = Config.enabled and "online" or "disabled",
        mode = "SAFE",
        feature_enabled = Config.enabled,
        body_mode = bodyMode(),
        body_present = false,
        client_mod_parity = "missing",
        client_control_ready = false
    }
    local client = clientFields()
    for key, value in pairs(client) do
        message[key] = value
    end
    local character = characterFields()
    message.character_state = character.character_state
    message.character_generation = character.character_generation
    return IPC.publishRuntime("zomboid-state", message)
end

return Telemetry

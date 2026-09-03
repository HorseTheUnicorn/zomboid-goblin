local Config = require("GoblinSurvivor/Config")
local JSON = require("GoblinSurvivor/JSON")

local IPC = {
    initialized = false,
    root = "",
    sequence = 0,
    initDiagnosticLogged = false
}

local channels = {
    state = true,
    events = true,
    commands = true,
    responses = true,
    acks = true,
    runtime = true,
    archive = true,
    deadletter = true
}

local bridgeMarker = ".goblin-bridge-v1"
local readyIndexName = ".ready-index.json"

local function fileExists(path)
    -- Build 42 exposes two similarly named helpers with different path
    -- roots.  On the dedicated server, serverFileExists is the authoritative
    -- check for the Lua cache used by this bridge.  Prefer it so a client
    -- helper returning false for a server-relative path cannot disable the
    -- whole server integration.
    local serverFileExistsFn = rawget(_G, "serverFileExists")
    if type(serverFileExistsFn) == "function" then
        local ok, exists = pcall(serverFileExistsFn, path)
        if ok then
            return exists == true
        end
    end
    local fileExistsFn = rawget(_G, "fileExists")
    if type(fileExistsFn) == "function" then
        local ok, exists = pcall(fileExistsFn, path)
        if ok then
            return exists == true
        end
    end
    local readerFn = rawget(_G, "getFileReader")
    if type(readerFn) == "function" then
        local ok, reader = pcall(readerFn, path, false)
        if ok and reader ~= nil then
            pcall(function() reader:close() end)
            return true
        end
    end
    return false
end

local function nonEmptyFile(path)
    local readerFn = rawget(_G, "getFileReader")
    if type(readerFn) ~= "function" then
        return false
    end
    local okOpen, reader = pcall(readerFn, path, false)
    if not okOpen or reader == nil then
        return false
    end
    local okRead, line = pcall(function() return reader:readLine() end)
    pcall(function() reader:close() end)
    return okRead and type(line) == "string" and #line > 0
end

local function safeStem(stem)
    if type(stem) ~= "string" or #stem < 1 or #stem > 128 then
        return nil
    end
    if not string.find(stem, "^[%w]") then
        return nil
    end
    if string.find(stem, "[^%w%._:%-]") then
        return nil
    end
    if string.find(stem, "/") or string.find(stem, "\\") then
        return nil
    end
    return stem
end

local function jsonEncode(value)
    return JSON.encode(value, Config.maxMessageBytes)
end

local function jsonDecode(value)
    local result = JSON.decode(value, Config.maxMessageBytes)
    return type(result) == "table" and result or nil
end

local function pathExists(path)
    -- Build 42's server Lua sandbox does not expose lfs or io.  The bridge
    -- provisioner creates a fixed marker, so this tests the relative Lua
    -- cache path with the supported reader instead of a non-PZ extension.
    return fileExists(path) or nonEmptyFile(path)
end

local function writeFile(path, content)
    -- Build 42 removes io and os file mutation APIs from mod Lua.  The PZ
    -- file writer is the supported bridge primitive.  JSON is closed before
    -- its ready marker is written; readers reject incomplete JSON and retry.
    local writerFactory = rawget(_G, "getFileWriter")
    if type(writerFactory) ~= "function" then
        return false, "PZ getFileWriter is unavailable"
    end
    local okOpen, handle = pcall(writerFactory, path, false, false)
    if not okOpen or handle == nil then
        return false, "PZ file writer could not open the bridge path"
    end
    local okWrite, writeError = pcall(function()
        handle:write(content)
        handle:close()
    end)
    if not okWrite then
        pcall(function() handle:close() end)
        return false, writeError
    end
    return true
end

local function readFile(path)
    -- On this Build 42 server both documented existence helpers return false
    -- for files under the Lua cache even when getFileReader can open them.
    -- Read directly; callers validate JSON, and done markers are considered
    -- present only when their non-empty timestamp is readable.
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
    if not okRead then
        return nil
    end
    return table.concat(lines, "\n")
end

local function validateMessage(message, encoded)
    if type(message) ~= "table" or type(encoded) ~= "string" then
        return false
    end
    if #encoded > Config.maxMessageBytes then
        return false
    end
    if message.protocol ~= Config.protocol then
        return false
    end
    if not safeStem(message.request_id) then
        return false
    end
    if type(message.timestamp_ms) ~= "number" or message.timestamp_ms <= 0 then
        return false
    end
    if type(message.type) ~= "string" or not string.find(message.type, "^[%a][%w%._:%-]*$") then
        return false
    end
    return true
end

function IPC.initialize()
    local root = Config.bridgeRoot()
    if type(root) ~= "string" or root == "" then
        return false
    end
    local markerPath = root .. "/" .. bridgeMarker
    local markerPresent = pathExists(markerPath)
    if not IPC.initDiagnosticLogged then
        local details = {}
        for _, name in ipairs({"serverFileExists", "fileExists"}) do
            local checker = rawget(_G, name)
            if type(checker) == "function" then
                local ok, exists = pcall(checker, markerPath)
                table.insert(details, name .. "=" .. tostring(ok) .. ":" .. tostring(exists))
            else
                table.insert(details, name .. "=missing")
            end
        end
        local readerFactory = rawget(_G, "getFileReader")
        if type(readerFactory) == "function" then
            local ok, reader = pcall(readerFactory, markerPath, false)
            table.insert(details, "reader=" .. tostring(ok) .. ":" .. tostring(reader ~= nil))
            if reader ~= nil then
                pcall(function() reader:close() end)
            end
        else
            table.insert(details, "reader=missing")
        end
        print("[GoblinSurvivor] IPC init root=" .. root
            .. " marker=" .. tostring(markerPresent)
            .. " " .. table.concat(details, ","))
        IPC.initDiagnosticLogged = true
    end
    if not markerPresent then
        return false
    end
    IPC.root = root
    IPC.initialized = true
    return true
end

function IPC.isReady()
    return IPC.initialized
end

function IPC.publishRuntime(name, message)
    if not IPC.initialized and not IPC.initialize() then
        return false
    end
    local stem = safeStem(name)
    if not stem then
        return false
    end
    local encoded = jsonEncode(message)
    if not encoded or not validateMessage(message, encoded) then
        return false
    end
    local path = IPC.root .. "/runtime/" .. stem .. ".json"
    local ok = writeFile(path, encoded)
    return ok == true
end

function IPC.publish(channel, message, stem)
    if channel == "commands" and not Config.enabled then
        return false
    end
    if not channels[channel] then
        return false
    end
    if not IPC.initialized and not IPC.initialize() then
        return false
    end
    local messageStem = safeStem(stem or (message and message.request_id))
    if not messageStem then
        return false
    end
    local encoded = jsonEncode(message)
    if not encoded or not validateMessage(message, encoded) then
        return false
    end
    local jsonPath = IPC.root .. "/" .. channel .. "/" .. messageStem .. ".json"
    local readyPath = IPC.root .. "/" .. channel .. "/" .. messageStem .. ".ready"
    local okJson = writeFile(jsonPath, encoded)
    if not okJson then
        return false
    end
    -- Build 42's file writer may not materialize a zero-byte file.  A
    -- non-empty marker is still ignored by readers, but guarantees that the
    -- host relay can observe acknowledgements and responses after publish.
    local okReady = writeFile(readyPath, "1")
    return okReady == true
end

function IPC.readReady(channel, stem)
    if not channels[channel] then
        return nil
    end
    if not IPC.initialized and not IPC.initialize() then
        return nil
    end
    local messageStem = safeStem(stem)
    if not messageStem then
        return nil
    end
    local jsonPath = IPC.root .. "/" .. channel .. "/" .. messageStem .. ".json"
    local encoded = readFile(jsonPath)
    if not encoded or #encoded > Config.maxMessageBytes then
        return nil
    end
    local message = jsonDecode(encoded)
    if not validateMessage(message, encoded) then
        return nil
    end
    return message
end

function IPC.listReady(channel)
    local result = {}
    if not channels[channel] then
        return result
    end
    if not IPC.initialized and not IPC.initialize() then
        return result
    end
    local encoded = readFile(IPC.root .. "/" .. channel .. "/" .. readyIndexName)
    if not encoded or #encoded > Config.maxMessageBytes then
        return result
    end
    local index = jsonDecode(encoded)
    if type(index) ~= "table" then
        return result
    end
    for _, stem in ipairs(index) do
        if safeStem(stem) then
            local readyPath = IPC.root .. "/" .. channel .. "/" .. stem .. ".ready"
            local jsonPath = IPC.root .. "/" .. channel .. "/" .. stem .. ".json"
            local donePath = IPC.root .. "/" .. channel .. "/" .. stem .. ".done"
            local processedPath = IPC.root .. "/" .. channel .. "/" .. stem .. ".processed.json"
            local encoded = readFile(jsonPath)
            local done = readFile(donePath)
            local processed = readFile(processedPath)
            if encoded ~= nil and #encoded > 0
                and (done == nil or #done == 0)
                and (processed == nil or #processed == 0) then
                table.insert(result, stem)
            end
        end
    end
    table.sort(result)
    return result
end

local function archiveReady(channel, stem, destination, reason)
    if destination ~= "archive" and destination ~= "deadletter" then
        return false
    end
    local safe = safeStem(stem)
    if not safe or not channels[channel] then
        return false
    end
    if not IPC.initialized and not IPC.initialize() then
        return false
    end
    local source = IPC.root .. "/" .. channel
    local target = IPC.root .. "/" .. destination
    IPC.sequence = IPC.sequence + 1
    local suffix = tostring(os.time()) .. "-" .. tostring(IPC.sequence)
    local targetStem = safe .. "-" .. suffix
    -- The command JSON has already passed readReady() before archiveReady is
    -- called.  Build 42 can open a host-created zero-byte .ready marker but
    -- returns no line from it, so requiring readFile(.ready) here would make
    -- every otherwise-valid command impossible to archive.
    local encoded = readFile(source .. "/" .. safe .. ".json")
    if encoded == nil then
        return false
    end
    local copiedJson = writeFile(target .. "/" .. targetStem .. ".json", encoded)
    local copiedReady = copiedJson
        and writeFile(target .. "/" .. targetStem .. ".ready", "1")
    if not copiedJson or not copiedReady then
        return false
    end
    local reasonValue = tostring(reason or "processed")
    if #reasonValue > 512 then
        reasonValue = string.sub(reasonValue, 1, 512)
    end
    local encoded = jsonEncode({
        reason = reasonValue,
        timestamp_ms = os.time() * 1000
    })
    if encoded then
        writeFile(target .. "/" .. targetStem .. ".reason.json", encoded)
    end
    -- The PZ Lua API has no supported delete/rename operation.  A durable
    -- processed JSON marker prevents replay after restart; the host relay may
    -- later compact the original command files after collecting the archive
    -- copy.  Build 42's writer materializes JSON files reliably, while the
    -- legacy zero-byte .done marker is retained only as a best-effort aid for
    -- older bridge readers.
    writeFile(source .. "/" .. safe .. ".done", tostring(os.time()))
    local processedMarker = jsonEncode({
        processed = true,
        timestamp_ms = os.time() * 1000,
        reason = reasonValue
    })
    if processedMarker then
        writeFile(source .. "/" .. safe .. ".processed.json", processedMarker)
    end
    return true
end

function IPC.archive(channel, stem, reason)
    return archiveReady(channel, stem, "archive", reason)
end

function IPC.deadletter(channel, stem, reason)
    return archiveReady(channel, stem, "deadletter", reason)
end

function IPC.acknowledge(requestId, status)
    local safe = safeStem(requestId)
    if not safe then
        return false
    end
    return IPC.publish("acks", {
        protocol = Config.protocol,
        request_id = safe,
        timestamp_ms = os.time() * 1000,
        type = "ack.command",
        status = tostring(status or "accepted")
    }, safe)
end

function IPC.writeResponse(requestId, status, detail)
    local safe = safeStem(requestId)
    if not safe then
        return false
    end
    return IPC.publish("responses", {
        protocol = Config.protocol,
        request_id = safe,
        timestamp_ms = os.time() * 1000,
        type = "response.command",
        status = tostring(status or "rejected"),
        detail = string.sub(tostring(detail or ""), 1, 512)
    }, safe)
end

return IPC

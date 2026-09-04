-- The only module that knows Bandits 2 names.  Every call is guarded so an
-- incompatible Workshop update fails closed instead of corrupting the NPC.
local BanditsAdapter = {}

local function functionExists(owner, name)
    return type(owner) == "table" and type(owner[name]) == "function"
end

function BanditsAdapter.available()
    return type(BanditServer) == "table"
        and type(BanditServer.Spawner) == "table"
        and functionExists(BanditServer.Spawner, "Individual")
        and functionExists(BanditServer.Spawner, "Restore")
        and type(BanditBrain) == "table"
        and functionExists(BanditBrain, "Get")
        and functionExists(BanditBrain, "Add")
        and type(BanditCustom) == "table"
        and functionExists(BanditCustom, "Create")
        and functionExists(BanditCustom, "Get")
end

function BanditsAdapter.capabilities()
    return {
        available = BanditsAdapter.available(),
        spawnIndividual = type(BanditServer) == "table"
            and type(BanditServer.Spawner) == "table"
            and functionExists(BanditServer.Spawner, "Individual"),
        restore = type(BanditServer) == "table"
            and type(BanditServer.Spawner) == "table"
            and functionExists(BanditServer.Spawner, "Restore"),
        brain = type(BanditBrain) == "table" and functionExists(BanditBrain, "Get")
            and functionExists(BanditBrain, "Add"),
        custom = type(BanditCustom) == "table" and functionExists(BanditCustom, "Create")
            and functionExists(BanditCustom, "Get")
    }
end

function BanditsAdapter.ensureCustom(bid)
    if not BanditsAdapter.available() or type(bid) ~= "string" or bid == "" then
        return nil, "Bandits custom-data API is unavailable"
    end
    local okGet, data = pcall(BanditCustom.Get, bid)
    if okGet and data ~= nil then
        return data
    end
    local okCreate, created = pcall(BanditCustom.Create, bid)
    if not okCreate or created == nil then
        return nil, "BanditCustom.Create failed"
    end
    return created
end

-- Bandits 2's validated server API requires a player anchor and an args.bid.
-- NPCRegistry supplies an online player only after the server is ready.
function BanditsAdapter.spawnIndividual(anchor, bid, program)
    if anchor == nil then
        return false, "no online player anchor"
    end
    local _, customError = BanditsAdapter.ensureCustom(bid)
    if customError ~= nil then
        return false, customError
    end
    local args = { bid = bid, program = program or "Bandit" }
    local ok = pcall(BanditServer.Spawner.Individual, anchor, args)
    if not ok then
        return false, "BanditServer.Spawner.Individual failed"
    end
    return true, "spawn requested"
end

function BanditsAdapter.restore(brain)
    if not BanditsAdapter.available() or type(brain) ~= "table" then
        return false, "Bandits restore API is unavailable"
    end
    local ok = pcall(BanditServer.Spawner.Restore, nil, brain)
    if not ok then
        return false, "BanditServer.Spawner.Restore failed"
    end
    return true, "restore requested"
end

function BanditsAdapter.getBrain(zombie)
    if not BanditsAdapter.available() or zombie == nil then
        return nil
    end
    local ok, brain = pcall(BanditBrain.Get, zombie)
    return ok and type(brain) == "table" and brain or nil
end

function BanditsAdapter.setTasks(zombie, tasks)
    if not BanditsAdapter.available() or zombie == nil or type(tasks) ~= "table" then
        return false, "Bandits brain API is unavailable"
    end
    local brain = BanditsAdapter.getBrain(zombie)
    if brain == nil then
        return false, "NPC has no Bandits brain"
    end
    brain.tasks = tasks
    local ok = pcall(BanditBrain.Add, zombie, brain)
    if not ok then
        return false, "BanditBrain.Add failed"
    end
    return true, "task accepted"
end

function BanditsAdapter.clearTasks(zombie)
    return BanditsAdapter.setTasks(zombie, {})
end

return BanditsAdapter

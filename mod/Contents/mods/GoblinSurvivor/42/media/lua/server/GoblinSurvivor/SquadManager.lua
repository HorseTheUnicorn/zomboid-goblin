local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")

local SquadManager = { squads = {}, maxMembers = 16, minimumBaseGuards = 1 }

local function uniqueMembers(members)
    if type(members) ~= "table" or #members < 1 or #members > SquadManager.maxMembers then return nil end
    local result, seen = {}, {}
    for _, member in ipairs(members) do
        if not Net.safeId(member, 96) or seen[member] then return nil end
        seen[member] = true
        table.insert(result, member)
    end
    return result
end

function SquadManager.form(args)
    if type(args) ~= "table" or not Net.safeId(args.squad_id or "squad.primary", 96)
        or not Net.safeId(args.leader, 96) then return false, "invalid squad identity" end
    local members = uniqueMembers(args.members)
    if members == nil then return false, "invalid squad members" end
    local formation = args.formation or "loose"
    if formation ~= "line" and formation ~= "wedge" and formation ~= "column"
        and formation ~= "ring" and formation ~= "loose" then return false, "invalid formation" end
    local squadId = args.squad_id or "squad.primary"
    SquadManager.squads[squadId] = {
        squad_id = squadId, leader = args.leader, members = members, formation = formation
    }
    return true, "squad formed"
end

function SquadManager.dismiss(args)
    local squadId = type(args) == "table" and args.squad_id or nil
    if not Net.safeId(squadId or "", 96) then return false, "invalid squad id" end
    if SquadManager.squads[squadId] == nil then return false, "squad is unknown" end
    SquadManager.squads[squadId] = nil
    return true, "squad dismissed"
end

function SquadManager.snapshot()
    return SquadManager.squads
end

return SquadManager

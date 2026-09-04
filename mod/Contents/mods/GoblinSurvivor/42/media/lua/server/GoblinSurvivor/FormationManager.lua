local FormationManager = {}

local allowed = { line = true, wedge = true, column = true, ring = true, loose = true }

function FormationManager.valid(name)
    return type(name) == "string" and allowed[name] == true
end

function FormationManager.offsets(name, count)
    if not FormationManager.valid(name) or type(count) ~= "number"
        or math.floor(count) ~= count or count < 0 or count > 16 then return nil end
    local result = {}
    for index = 1, count do
        if name == "line" then
            table.insert(result, { lateral = index - 1 - math.floor(count / 2), depth = 0 })
        elseif name == "column" then
            table.insert(result, { lateral = 0, depth = index - 1 })
        elseif name == "wedge" then
            local row = math.floor(index / 2)
            table.insert(result, { lateral = (index % 2 == 0 and -row or row), depth = row })
        else
            table.insert(result, { lateral = index - 1, depth = 0 })
        end
    end
    return result
end

return FormationManager

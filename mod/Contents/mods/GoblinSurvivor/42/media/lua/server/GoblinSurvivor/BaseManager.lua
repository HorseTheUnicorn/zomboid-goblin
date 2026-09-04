local Config = require("GoblinSurvivor/Config")

local BaseManager = {
    baseId = "base.primary",
    name = "home base",
    minimumGuards = 1,
    assignedGuards = 1,
    anchor = nil,
    loaded = false
}

local function persistentData()
    if type(ModData) ~= "table" or type(ModData.getOrCreate) ~= "function" then
        return nil
    end
    local ok, data = pcall(ModData.getOrCreate, "GoblinSurvivor")
    return ok and type(data) == "table" and data or nil
end

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function validPoint(value)
    return type(value) == "table" and finite(value.x) and finite(value.y)
        and finite(value.z)
end

local function pointOf(object)
    if object == nil or type(object.getX) ~= "function"
        or type(object.getY) ~= "function" or type(object.getZ) ~= "function" then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return object:getX(), object:getY(), object:getZ()
    end)
    if not ok then return nil end
    local point = { x = x, y = y, z = z }
    return validPoint(point) and point or nil
end

local function save()
    local data = persistentData()
    if data == nil then return false end
    local record = {
        base_id = BaseManager.baseId,
        name = BaseManager.name,
        minimum_guards = BaseManager.minimumGuards,
        assigned_guards = BaseManager.assignedGuards
    }
    if validPoint(BaseManager.anchor) then
        record.anchor = {
            x = BaseManager.anchor.x,
            y = BaseManager.anchor.y,
            z = BaseManager.anchor.z
        }
    end
    data.base = record
    if type(ModData.transmit) == "function" then
        pcall(ModData.transmit, "GoblinSurvivor")
    end
    return true
end

function BaseManager.load()
    if BaseManager.loaded then return end
    BaseManager.minimumGuards = Config.minimumBaseGuards or 1
    BaseManager.assignedGuards = BaseManager.minimumGuards
    local data = persistentData()
    local record = data and data.base or nil
    if type(record) == "table" then
        if type(record.name) == "string" and #record.name > 0 and #record.name <= 64 then
            BaseManager.name = record.name
        end
        if validPoint(record.anchor) then
            BaseManager.anchor = {
                x = record.anchor.x, y = record.anchor.y, z = record.anchor.z
            }
        end
        if type(record.assigned_guards) == "number"
            and math.floor(record.assigned_guards) == record.assigned_guards
            and record.assigned_guards >= BaseManager.minimumGuards
            and record.assigned_guards <= 16 then
            BaseManager.assignedGuards = record.assigned_guards
        end
    end
    BaseManager.loaded = true
end

function BaseManager.canDepart(count)
    BaseManager.load()
    count = count or 1
    return type(count) == "number" and math.floor(count) == count and count >= 1
        and BaseManager.assignedGuards - count >= BaseManager.minimumGuards
end

function BaseManager.setFromPlayer(player)
    BaseManager.load()
    if not Config.isAuthorizedPlayer(player) then
        return false, "only an authorized commander or server administrator may set the base"
    end
    local point = pointOf(player)
    if point == nil then return false, "issuing player has no valid world position" end
    BaseManager.anchor = point
    if save() then
        return true, "home base set from the authorized player's current position"
    end
    return false, "base position could not be persisted"
end

function BaseManager.hasAnchor()
    BaseManager.load()
    return validPoint(BaseManager.anchor)
end

function BaseManager.point()
    BaseManager.load()
    if not validPoint(BaseManager.anchor) then return nil end
    return {
        x = BaseManager.anchor.x,
        y = BaseManager.anchor.y,
        z = BaseManager.anchor.z
    }
end

function BaseManager.snapshot()
    BaseManager.load()
    -- The ordinary snapshot is safe for coarse telemetry and Qwen.  Exact
    -- anchor coordinates are exposed only through snapshotExact().
    return {
        base_id = BaseManager.baseId,
        name = BaseManager.name,
        has_anchor = BaseManager.hasAnchor(),
        minimum_guards = BaseManager.minimumGuards,
        assigned_guards = BaseManager.assignedGuards
    }
end

function BaseManager.snapshotExact()
    BaseManager.load()
    local point = BaseManager.point()
    if point == nil then return nil end
    point.base_id = BaseManager.baseId
    point.name = BaseManager.name
    point.kind = "base"
    return point
end

function BaseManager.setAssignedGuards(count)
    BaseManager.load()
    if type(count) ~= "number" or math.floor(count) ~= count
        or count < BaseManager.minimumGuards or count > 16 then
        return false
    end
    BaseManager.assignedGuards = count
    return save()
end

return BaseManager

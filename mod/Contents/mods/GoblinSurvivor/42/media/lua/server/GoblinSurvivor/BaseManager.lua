local BaseManager = { baseId = "base.primary", minimumGuards = 1, assignedGuards = 1 }

function BaseManager.canDepart(count)
    count = count or 1
    return type(count) == "number" and count >= 1 and BaseManager.assignedGuards - count >= BaseManager.minimumGuards
end

function BaseManager.snapshot()
    return {
        base_id = BaseManager.baseId,
        minimum_guards = BaseManager.minimumGuards,
        assigned_guards = BaseManager.assignedGuards
    }
end

return BaseManager

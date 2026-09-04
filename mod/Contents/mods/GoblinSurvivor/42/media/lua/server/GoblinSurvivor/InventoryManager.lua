local InventoryManager = {}

function InventoryManager.execute(_args)
    -- Inventory mutation stays fail-closed until the exact server API is
    -- verified against the installed Build 42 runtime.
    return false, "inventory API is not enabled"
end

return InventoryManager

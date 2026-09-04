local BuildManager = {}

function BuildManager.execute(_args)
    -- Build 42 construction APIs are intentionally not guessed here.
    return false, "building API is not enabled"
end

return BuildManager

-- Compact task/state contract for the per-player Goblin companions.
local Constants = {}

Constants.NPC_PREFIX = "goblin.primary"
Constants.NPC_ID = Constants.NPC_PREFIX

Constants.TASK = {
    ENTER_VEHICLE = "ENTER_VEHICLE", EXIT_VEHICLE = "EXIT_VEHICLE",
    START_VEHICLE = "START_VEHICLE", UNLOCK_VEHICLE = "UNLOCK_VEHICLE",
    FARM = "FARM",
    CRAFT = "CRAFT",
    REPAIR_VEHICLE = "REPAIR_VEHICLE",
    OPEN_DOOR = "OPEN_DOOR",
    OPEN_WINDOW = "OPEN_WINDOW",
    GAIN_ACCESS = "GAIN_ACCESS",
    CLOSE_CURTAINS = "CLOSE_CURTAINS",
    INSPECT_BASE = "INSPECT_BASE",
    MAINTAIN_BASE = "MAINTAIN_BASE",
    DISMANTLE = "DISMANTLE",
    STOCKPILE = "STOCKPILE",
    FORTIFY = "FORTIFY",
    FORTIFY_BASE = "FORTIFY_BASE",
    BUILD = "BUILD",
    FOLLOW = "FOLLOW",
    MOVE_TO = "MOVE_TO",
    WAIT = "WAIT",
    RETURN_TO_BASE = "RETURN_TO_BASE",
    LOOT = "LOOT",
    ATTACK = "ATTACK",
    EQUIP = "EQUIP",
    SPEAK = "SPEAK",
    SET_BASE = "SET_BASE"
}

Constants.PHYSICAL = {
    IDLE = "IDLE",
    PATHING = "PATHING",
    WALKING = "WALKING",
    RUNNING = "RUNNING",
    LOOTING = "LOOTING",
    RETURNING = "RETURNING",
    COMBAT = "COMBAT",
    ATTACKING = "ATTACKING",
    BLOCKED = "BLOCKED"
}

Constants.MOVE_TYPE = {
    IDLE = "IDLE",
    WALK = "WALK",
    RUN = "RUN"
}

Constants.COMBAT = {
    NONE = "NONE",
    READY = "READY",
    ATTACKING = "ATTACKING"
}

Constants.ALLOWED_TASKS = {
    ENTER_VEHICLE = true, EXIT_VEHICLE = true, START_VEHICLE = true, UNLOCK_VEHICLE = true,
    FARM = true,
    CRAFT = true,
    REPAIR_VEHICLE = true,
    OPEN_DOOR = true,
    OPEN_WINDOW = true,
    GAIN_ACCESS = true,
    CLOSE_CURTAINS = true,
    INSPECT_BASE = true,
    MAINTAIN_BASE = true,
    DISMANTLE = true,
    STOCKPILE = true,
    FORTIFY = true,
    FORTIFY_BASE = true,
    BUILD = true,
    FOLLOW = true,
    MOVE_TO = true,
    WAIT = true,
    RETURN_TO_BASE = true,
    LOOT = true,
    ATTACK = true,
    EQUIP = true,
    SPEAK = true,
    SET_BASE = true
}

return Constants

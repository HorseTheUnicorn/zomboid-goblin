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
    MOVE_CORPSE = "MOVE_CORPSE",
    PREPARE_FOOD_STORAGE = "PREPARE_FOOD_STORAGE",
    INSPECT_BASE = "INSPECT_BASE",
    MAINTAIN_BASE = "MAINTAIN_BASE",
    DISMANTLE = "DISMANTLE",
    STOCKPILE = "STOCKPILE",
    SORT_STORAGE = "SORT_STORAGE",
    FETCH_ITEM = "FETCH_ITEM",
    DELIVER = "DELIVER",
    REPAIR_STRUCTURE = "REPAIR_STRUCTURE",
    VEHICLE_INSPECT = "VEHICLE_INSPECT",
    REFUEL_VEHICLE = "REFUEL_VEHICLE",
    INSTALL_PART = "INSTALL_PART",
    REMOVE_PART = "REMOVE_PART",
    REPLACE_PART = "REPLACE_PART",
    CHANGE_TIRE = "CHANGE_TIRE",
    VEHICLE_SERVICE = "VEHICLE_SERVICE",
    CHOP_WOOD = "CHOP_WOOD",
    TREAT_PLAYER = "TREAT_PLAYER",
    FORAGE = "FORAGE",
    CHECK_TRAPS = "CHECK_TRAPS",
    COOK = "COOK",
    RESTORE_POWER = "RESTORE_POWER",
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
    MOVE_CORPSE = true,
    PREPARE_FOOD_STORAGE = true,
    INSPECT_BASE = true,
    MAINTAIN_BASE = true,
    DISMANTLE = true,
    STOCKPILE = true,
    SORT_STORAGE = true,
    FETCH_ITEM = true,
    DELIVER = true,
    REPAIR_STRUCTURE = true,
    VEHICLE_INSPECT = true,
    REFUEL_VEHICLE = true,
    INSTALL_PART = true,
    REMOVE_PART = true,
    REPLACE_PART = true,
    CHANGE_TIRE = true,
    VEHICLE_SERVICE = true,
    CHOP_WOOD = true,
    TREAT_PLAYER = true,
    FORAGE = true,
    CHECK_TRAPS = true,
    COOK = true,
    RESTORE_POWER = true,
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

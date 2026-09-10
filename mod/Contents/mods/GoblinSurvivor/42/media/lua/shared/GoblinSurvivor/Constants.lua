-- Small, engine-facing contract for the rebuilt Goblin companion.
--
-- Tasks describe intent.  Physical states describe what the body is doing.
-- Keeping those concepts separate prevents the old controller/state-sprawl
-- failure mode from returning.
local Constants = {}

Constants.NPC_ID = "goblin.primary"
Constants.TASK = {
    FOLLOW = "FOLLOW",
    MOVE_TO = "MOVE_TO",
    WAIT = "WAIT",
    GUARD = "GUARD",
    ATTACK = "ATTACK",
    RETURN_TO_OWNER = "RETURN_TO_OWNER",
    EQUIP = "EQUIP",
    SPEAK = "SPEAK",
    LOOT = "LOOT"
}

Constants.PHYSICAL = {
    IDLE = "IDLE",
    PATHING = "PATHING",
    WALKING = "WALKING",
    RUNNING = "RUNNING",
    COMBAT = "COMBAT",
    ATTACKING = "ATTACKING",
    HIT = "HIT",
    RECOVERING = "RECOVERING",
    LOOTING = "LOOTING",
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
    ATTACKING = "ATTACKING",
    HIT = "HIT"
}

Constants.ALLOWED_TASKS = {
    FOLLOW = true,
    MOVE_TO = true,
    WAIT = true,
    GUARD = true,
    ATTACK = true,
    RETURN_TO_OWNER = true,
    EQUIP = true,
    SPEAK = true,
    LOOT = true
}

return Constants

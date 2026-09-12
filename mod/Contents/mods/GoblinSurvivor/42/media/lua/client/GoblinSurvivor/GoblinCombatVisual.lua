-- Presentation only. Damage and ammunition remain exclusively server-owned.
-- Local hand models never enter an inventory or become lootable items.
local Config = require("GoblinSurvivor/Config")
local PlayerEvents = require("GoblinSurvivor/GoblinPlayerEvents")
local Hands = require("GoblinSurvivor/GoblinHands")
local Visual = { cues={}, bodies=setmetatable({}, {__mode="k"}) }

local function call(object,method,...)
    if not object then return false end
    local ok,fn=pcall(function() return object[method] end)
    if not ok or type(fn)~="function" then return false end
    return pcall(fn,object,...)
end

function Visual.cue(args,now)
    if type(args)~="table" or type(args.npc_id)~="string" or
        type(args.generation)~="number" or type(args.sequence)~="number" or
        type(args.x)~="number" or type(args.y)~="number" then return false end
    local previous=Visual.cues[args.npc_id]
    if previous and (previous.generation>args.generation or
        (previous.generation==args.generation and previous.sequence>=args.sequence)) then return false end
    Visual.cues[args.npc_id]={generation=args.generation,sequence=args.sequence,
        x=args.x,y=args.y,start=now,fireAt=now+400,untilAt=now+850}
    for id,cue in pairs(Visual.cues) do
        if now-cue.untilAt>10000 then Visual.cues[id]=nil end
    end
    return true
end

function Visual.apply(body,state,now)
    PlayerEvents.install()
    local cached=Visual.bodies[body] or {}
    Visual.bodies[body]=cached
    local action=state.action or ""
    local cue=Visual.cues[state.npc_id]
    local inCombat=cue and cue.generation==state.generation and now<cue.untilAt
    if Hands.travelling(body,state) then
        Hands.stow(body)
        call(body,"setVariable","GoblinAction",state.vehicle_phase or "")
        return state.vehicle_phase or ""
    end
    local tool=not inCombat and (state.job_active or action=="BUILD") and state.job_tool or nil
    local desired=type(tool)=="string" and #tool<100 and tool:match("^[%w_]+%.[%w_]+$") and tool or Config.weaponType
    local _,hand=call(body,"getPrimaryHandItem")
    local _,kind=call(hand,"getFullType")
    if kind~=desired then
        if cached.handType~=desired or not cached.weapon then
            local factory=rawget(_G,"instanceItem")
            if type(factory)=="function" then
                local ok,item=pcall(factory,desired)
                if ok then cached.weapon=item;cached.handType=desired end
            end
        end
        if cached.weapon then
            call(body,"setPrimaryHandItem",cached.weapon)
            call(body,"setSecondaryHandItem",desired==Config.weaponType and cached.weapon or nil)
            if desired==Config.weaponType then call(body,"setUseHandWeapon",cached.weapon) end
            call(body,"resetEquippedHandsModels")
        end
    end
    if inCombat then
        action=now<cue.fireAt and "AIM" or "SHOOT"
        local _,x=call(body,"getX")
        local _,y=call(body,"getY")
        if x and y then
            local dx,dy=cue.x-x,cue.y-y
            local length=math.sqrt(dx*dx+dy*dy)
            if length>0.001 then call(body,"setForwardDirection",dx/length,dy/length) end
        end
        if action=="SHOOT" and (cached.playedSequence~=cue.sequence or cached.playedGeneration~=cue.generation) then
            cached.playedSequence=cue.sequence
            cached.playedGeneration=cue.generation
            local _,emitter=call(body,"getEmitter")
            call(emitter,"playSound","DoubleBarrelShotgunShoot")
        end
    end
    call(body,"setVariable","GoblinAction",action)
    call(body,"setVariable","Weapon","firearm")
    return action
end

return Visual

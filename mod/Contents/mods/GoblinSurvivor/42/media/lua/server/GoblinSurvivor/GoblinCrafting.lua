-- Native Build 42 HandcraftLogic owns ingredient selection and recipe outputs.
local Body=require("GoblinSurvivor/GoblinBody")
local World=require("GoblinSurvivor/GoblinWorld")
local Tools=require("GoblinSurvivor/GoblinTools")
local Support=require("GoblinSurvivor/GoblinJobSupport")
local Craft={}
local call=World.call
local aliases={plank="SawLogs",planks="SawLogs",rope="CraftRope",sheetrope="CraftSheetRope"}
local function normalized(value) return string.lower(tostring(value or "")):gsub("[^%w]","") end

function Craft.resolve(name)
    if type(name)~="string" or #name<1 or #name>96 or name:find("[%c]") then return nil end
    local manager=ScriptManager and ScriptManager.instance
    if not manager then return nil end
    local wanted=aliases[normalized(name)] or name
    local _,recipe=call(manager,"getCraftRecipe",wanted)
    if recipe then return recipe end
    local match
    for _,candidate in ipairs(World.values(select(2,call(manager,"getAllCraftRecipes")))) do
        if normalized(candidate:getName())==normalized(wanted)
            or normalized(candidate:getTranslationName())==normalized(wanted) then
            if match then return nil end -- Do not guess between ambiguous recipes.
            match=candidate
        end
    end
    return match
end

function Craft.supported(recipe)
    if not recipe then return false,"name an installed hand-crafting recipe (for example SawLogs)" end
    if recipe:isBuildableRecipe() or recipe:requiresSpecificWorkstation()
        or not (recipe:isInHandCraftCraft() or recipe:isAnySurfaceCraft()) then
        return false,"this recipe requires a workstation/building job that is not implemented yet"
    end
    return true
end

function Craft.prepare(body,owner,payload)
    if not HandcraftLogic or not ArrayList or type(goblinServerCraft)~="function" then
        return nil,"crafting needs the updated Goblin server adapter and server-side Storm"
    end
    local item=payload.item or {}
    local recipe=Craft.resolve(item.name)
    local ok,reason=Craft.supported(recipe)
    if not ok then return nil,reason end
    local count=item.count or 1
    if type(count)~="number" or count~=math.floor(count) or count<1 or count>10 then
        return nil,"request between 1 and 10 recipe batches"
    end
    local anchor=Support.anchor(body,owner,false)
    if not anchor then return nil,"stand near the crafting area first" end
    return {recipe=recipe:getName(),remaining=count,completed=0,anchor=anchor},"crafting queued: "..recipe:getName().." x"..count
end

local function setup(body,recipe)
    -- Knowledge belongs to this companion, not the owner or a hidden player.
    call(body,"setKnowAllRecipes",true)
    for _,input in ipairs(World.values(recipe:getInputs())) do
        if input:isKeep() then
            local tool,have=nil,0
            for _,item in ipairs(World.items(World.inventory(body))) do
                if input:canUseItem(item,body) then tool=item;have=have+1 end
            end
            local needed=input:isItemCount() and input:getAmount() or 1
            if have<needed then
                for _,choice in ipairs(World.values(input:getPossibleInputItems())) do
                    local supplied=false
                    for copy=1,math.min(32,needed) do
                        local candidate=Tools.ensure(body,choice:getFullName(),input,copy)
                        if not candidate then break end
                        tool,supplied=candidate,true
                        have=0
                        for _,item in ipairs(World.items(World.inventory(body))) do
                            if input:canUseItem(item,body) then have=have+1 end
                        end
                        -- An empty fuel tool is still the tool. Never clone it to satisfy fuel/condition rules.
                        if have>=needed or not input:canUseItem(candidate,body) then break end
                    end
                    if supplied then break end
                end
            end
            if tool then call(body,"setPrimaryHandItem",tool);call(body,"setSecondaryHandItem",nil) end
        end
    end
    local containers=ArrayList.new();containers:add(World.inventory(body))
    local logic=HandcraftLogic.new(body,nil,nil)
    logic:setContainers(containers)
    logic:setRecipe(recipe)
    logic:setManualSelectInputs(false)
    logic:setTargetVariableInputRatio(1)
    return logic
end

local function safeInputs(body,logic)
    if not logic:canPerformCurrentRecipe() then return false end
    for _,item in ipairs(World.values(logic:getRecipeData():getAllNotKeepInputItems())) do
        if Tools.reserved(item) or not World.has(World.inventory(body),item) then
            return false,"the recipe would consume companion equipment or items outside my inventory"
        end
    end
    return true
end

function Craft.update(body,payload,job,now)
    if (payload.remaining or 0)<1 then return true,true,"crafting finished" end
    local recipe=Craft.resolve(payload.recipe)
    local allowed,reason=Craft.supported(recipe)
    if not allowed then return true,false,reason end
    local logic=job.logic or setup(body,recipe)
    job.logic=logic
    local ready,blocked=safeInputs(body,logic)
    if blocked then return true,false,blocked end
    if not ready then
        job.readyAt=nil
        local consumed={}
        for _,input in ipairs(World.values(recipe:getInputs())) do
            if not input:isKeep() then consumed[#consumed+1]=input end
        end
        -- Gather only a missing recipe input; never repeatedly fill up on an
        -- already-satisfied ingredient. Engine counts include partial uses.
        local missing
        for _,input in ipairs(consumed) do
            local amount=input:getAmount()
            local have=input:isItemCount() and logic:getInputCount(input) or logic:getInputUses(input)
            if have<amount then missing=input;break end
        end
        if missing then
            local before=#World.items(World.inventory(body))
            -- supply() normally returns a carried match. Here we need another
            -- unit, so only accept items not already in the companion inventory.
            Support.supply(body,job,payload.anchor,function(i)
                return not World.has(World.inventory(body),i) and not Tools.reserved(i) and missing:canUseItem(i,body)
            end,now,"more materials for "..payload.recipe)
            if #World.items(World.inventory(body))>before then job.nextSupplyScan=0 end
            job.logic=nil -- Refresh native input selection after supplies change.
        else
            Support.status(body,"recipe blocked: check fuel, ingredient condition, and a nearby work surface for "..payload.recipe)
        end
        return false
    end
    local square=World.square(payload.anchor)
    -- Native duration is a 30fps timed-action count (handcraft multiplies by 5).
    local duration=math.max(1000,recipe:getTime(body)*5*1000/30)
    local animation=payload.recipe=="SawLogs" and "SAW" or "CRAFT"
    if not Support.work(body,job,square,now,duration,animation,"crafting "..payload.recipe) then return false end
    logic=setup(body,recipe)
    ready,blocked=safeInputs(body,logic)
    if not ready then job.readyAt=nil;return false end
    -- Once perform starts, never retry this batch after an exception: native
    -- recipes may already have consumed items. The job supervisor fails closed.
    if not goblinServerCraft(body,logic) then return true,false,"native crafting refused the recipe; no completion claimed" end
    payload.remaining=payload.remaining-1
    local outputs=ArrayList.new();logic:getCreatedOutputItems(outputs)
    local inv=World.inventory(body)
    for _,item in ipairs(World.values(outputs)) do
        local ok,added=call(inv,"AddItem",item)
        if not ok or not added then
            local dropped=square:AddWorldInventoryItem(item,0.5,0.5,0)
            if not dropped then error("crafted item could not be delivered") end
        end
    end
    local data=logic:getRecipeData()
    data:luaCallOnCreate(body)
    data:processDestroyAndUsedItems(body)
    payload.completed=(payload.completed or 0)+1
    job.readyAt=nil;job.logic=nil;Body.data(body).GoblinAction=""
    if payload.remaining==0 then
        return true,true,"crafted "..payload.completed.." batch(es) of "..payload.recipe
    end
    Support.status(body,"crafted "..payload.completed.." batch(es); "..payload.remaining.." to go")
    return false
end

return Craft

local Identity={trained=setmetatable({}, {__mode="k"})}
local first={"Grubsnarl","Rattlefang","Muckbite","Scabclaw","Feral Gristle","Ratspit","Boggnash","Scrapgnaw","Moldmaw","Sootfang","Gutterclaw","Nettletooth"}
local last={"Tinchewer","Bonepicker","Nailhoarder","Windowbiter","Mudhowler","Soupthief","Ashlicker","Bootgnasher","Rustbelly","Fencegnawer","Bucketlurker","Plankgobber"}

function Identity.name(owner,records)
    local h=0
    for i=1,#owner do h=(h*31+string.byte(string.lower(owner),i))%2147483647 end
    local base=first[(h%#first)+1].." "..last[(math.floor(h/#first)%#last)+1]
    local candidate,suffix=base,1
    local used={}
    for _,record in pairs(records or {}) do if record.name then used[record.name]=true end end
    while used[candidate] do suffix=suffix+1; candidate=base.." "..suffix end
    return candidate
end

function Identity.train(body)
    if Identity.trained[body] then return true end
    local ok,err=pcall(function()
        for i=0,PerkFactory.PerkList:size()-1 do
            local perk=PerkFactory.PerkList:get(i)
            if perk:getParent() ~= Perks.None then
                body:setPerkLevelDebug(perk,10)
                -- IsoZombie has perk levels but no player XP object.
                assert(body:getPerkLevel(perk)==10,"skill level was not applied")
            end
        end
    end)
    if ok then Identity.trained[body]=true
    elseif Identity.trained[body]~=false then
        Identity.trained[body]=false
        print("[GoblinSurvivor] SKILLS_PENDING "..tostring(err))
    end
    return ok
end

return Identity

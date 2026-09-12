-- Client presentation only. Names come from the server's persistent roster.
local Names = { bodies=setmetatable({}, {__mode="k"}) }
local Visibility=require("GoblinSurvivor/GoblinVisibility")

function Names.track(body,state,now)
    if type(state.name)~="string" or state.name=="" then return end
    Names.bodies[body]={id=state.npc_id,seen=now}
end

function Names.draw(body,state,viewer,index)
    local square=body:getSquare()
    if not square or body:isDead() or body:getAlpha(index)<0.3 then return end
    if not Visibility.owned(state,viewer) and not square:isCanSee(index) then return end
    if math.floor(body:getZ())~=math.floor(viewer:getZ()) then return end
    if (body:getX()-viewer:getX())^2+(body:getY()-viewer:getY())^2>20^2 then return end
    local name=state.name
    if type(name)~="string" or name=="" then return end
    name=string.sub(string.gsub(name,"[%c]",""),1,80)
    local zoom=getCore():getZoom(index)
    if not zoom or zoom<=0 then return end
    local left,top=IsoCamera.getScreenLeft(index),IsoCamera.getScreenTop(index)
    local width,height=IsoCamera.getScreenWidth(index),IsoCamera.getScreenHeight(index)
    local x=(body:getScreenX()-IsoCamera.getOffX(index))/zoom+left
    local text=getTextManager()
    local y=(body:getScreenY()-IsoCamera.getOffY(index)-64*Core.getTileScale())/zoom+top
        -text:getFontHeight(UIFont.Small)
    local half=text:MeasureStringX(UIFont.Small,name)/2
    if x-half<left or x+half>left+width or y<top or y>top+height-16 then return end
    local alpha=math.min(body:getAlpha(index),1)
    text:DrawStringCentre(UIFont.Small,x+1,y+1,name,0,0,0,alpha)
    text:DrawStringCentre(UIFont.Small,x,y,name,1,1,1,alpha)
end

function Names.render(states,now)
    if type(getNumActivePlayers)~="function" then return end
    for body,entry in pairs(Names.bodies) do
        local state=states[entry.id]
        if now-entry.seen>2000 or not state or state.body_present==false then
            Names.bodies[body]=nil
        else
            for index=0,getNumActivePlayers()-1 do
                local viewer=getSpecificPlayer(index)
                if viewer then Names.draw(body,state,viewer,index) end
            end
        end
    end
end

return Names

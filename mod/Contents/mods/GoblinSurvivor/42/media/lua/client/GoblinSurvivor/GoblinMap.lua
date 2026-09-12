-- Owner-only live marker on the world map and minimap. No permanent map edits.
local Map = { markers = {} }

function Map.receive(args, now)
    if type(args) ~= "table" or type(args.owner) ~= "string" or type(args.npc_id) ~= "string"
        or type(args.name) ~= "string" or type(args.x) ~= "number" or type(args.y) ~= "number" then return false end
    if args.x ~= args.x or args.y ~= args.y or math.abs(args.x)>1000000 or math.abs(args.y)>1000000 then return false end
    Map.markers[string.lower(args.owner)] = {name=args.name, x=args.x, y=args.y,
        present=args.body_present==true, received=now}
    return true
end

function Map.draw(panel, now)
    local player = panel.character or getSpecificPlayer(panel.playerNum or 0)
    if not player or not panel.mapAPI then return end
    local marker = Map.markers[string.lower(player:getUsername())]
    if not marker then return end
    local x = panel.mapAPI:worldToUIX(marker.x,marker.y)
    local y = panel.mapAPI:worldToUIY(marker.x,marker.y)
    local width,height = panel:getWidth(),panel:getHeight()
    if x<7 or y<7 or x>width-7 or y>height-7 then return end
    local live = marker.present and now-marker.received<10000
    panel:drawRect(x-5,y-5,10,10,0.9,0,0,0)
    panel:drawRect(x-3,y-3,6,6,1,live and 0.45 or 0.7,live and 1 or 0.7,0.2)
    local label = marker.name .. (live and "" or " (last known)")
    local labelWidth = getTextManager():MeasureStringX(UIFont.Small,label)
    if labelWidth<width-8 then
        panel:drawText(label,math.max(4,math.min(x+9,width-labelWidth-4)),math.max(4,y-18),0.7,1,0.4,1,UIFont.Small)
    end
end

function Map.install()
    if Map.installed then return end
    require("ISUI/Maps/ISWorldMap")
    require("ISUI/Maps/ISMiniMap")
    for _, class in ipairs({ISWorldMap,ISMiniMapInner}) do
        local original = class.render
        class.render = function(self,...)
            if original then original(self,...) end
            Map.draw(self,getTimestampMs())
        end
    end
    Map.installed = true
end

return Map

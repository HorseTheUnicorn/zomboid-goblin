-- Flag-gated disposable client fixture; places only the test PLAYER.
if not isClient() or isServer() then return end
local reader=getFileReader("goblin-m3-container.flag",false)
if not reader then return end
local owner=reader:readLine();reader:close()
if owner~="m3path_61" then return end
local placed=false
Events.OnTick.Add(function()
    if placed then return end
    local player=getPlayer()
    if player and player:getUsername()==owner and player:getCurrentSquare() then
        placed=true
        player:teleportTo(10779.5,9765.5,0)
        print("[GoblinSurvivor] M3_CONTAINER placed_test_player="..owner)
    end
end)

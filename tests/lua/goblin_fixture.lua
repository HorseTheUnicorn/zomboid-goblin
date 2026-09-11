clock = 100000
getTimestampMs = function() return clock end
isClient = function() return clientMode == true end
isServer = function() return clientMode ~= true end
print = function() end
function list(items)
    return { values = items or {}, size = function(self) return #self.values end,
        get = function(self, i) return self.values[i+1] end,
        add = function(self, v) self.values[#self.values+1] = v end,
        clear = function(self) self.values = {} end }
end
function actor(x, y, z)
    local a = { x=x, y=y, z=z, data={}, pathCalls=0, cancelCalls=0, variables={}, visuals=list(), inventory={"kept-item"} }
    function a:getX() return self.x end
    function a:getY() return self.y end
    function a:getZ() return self.z end
    function a:getModData() return self.data end
    function a:getOnlineID() return self.id or 5 end
    function a:getOwner() return self.engineOwner end
    function a:isRemoteZombie() return self.remote == true end
    function a:setVariable(k,v) self.variables[k]=v end
    function a:setUseless(v) self.useless=v end
    function a:setRunning(v) self.running=v end
    function a:setPath2(v) end
    function a:setPathing(v) end
    function a:pathToLocationF(x,y,z) self.pathCalls=self.pathCalls+1; self.destination={x=x,y=y,z=z} end
    function a:getPathFindBehavior2() return {cancel=function() a.cancelCalls=a.cancelCalls+1 end} end
    function a:getItemVisuals() return self.visuals end
    function a:getHumanVisual() return {} end
    function a:resetModelNextFrame() self.resets=(self.resets or 0)+1 end
    function a:removeFromWorld() self.removed=true end
    function a:removeFromSquare() end
    function a:setSquare(v) end
    return a
end
assetReady = true
ItemVisual = {new=function()
    return {setItemType=function(self,v) self.itemType=v end,
        getItemType=function(self) return self.itemType end,
        getClothingItem=function(self) return {isReady=function() return assetReady end} end,
        pickUninitializedValues=function() end}
end}
player=actor(10,0,0)
function player:getUsername() return "horse" end
online=list({player})
zombies=list()
getOnlinePlayers=function() return online end
cell={getZombieList=function() return zombies end,
    getGridSquare=function(self,x,y,z)
        if squareUnavailable then return nil end
        return {getX=function() return x end,getY=function() return y end,getZ=function() return z end,isFree=function() return true end}
    end}
getCell=function() return cell end
saved={}
ModData={getOrCreate=function() return saved end, transmit=function() end}
spawnCount=0
addZombiesInOutfit=function(x,y,z,total)
    assert(total == 1)
    spawnCount=spawnCount+1
    local a=actor(x,y,z)
    a.id=spawnCount
    zombies:add(a)
    return list({a})
end
Body={data=function(a) return a.data end,position=function(a) return {x=a.x,y=a.y,z=a.z} end,
    owner=function(a) return a.data.GoblinOwner end,npcId=function(a) return a.data.GoblinID end,
    exists=function(a) return not a.removed end,isGoblin=function(a) return a.data.GoblinNPC == true end,
    clearNativeTargets=function() end,applyInvariants=function() end,
    setPhysicalState=function(a,p,m,c) a.data.GoblinMoveType=m end,
    setTask=function(a,t,p) a.data.GoblinTask=t; a.data.GoblinTaskPayload=p; a.taskChanges=(a.taskChanges or 0)+1; return true end,
    mark=function(a,g,o,id) a.data={GoblinNPC=true,GoblinID=id,GoblinOwner=o,GoblinGeneration=g}; return true end,
    snapshot=function(a) return {npc_id=a.data.GoblinID,owner=a.data.GoblinOwner,body_present=true,online_id=a.id,generation=a.data.GoblinGeneration,task=a.data.GoblinTask,owner_online=a.data.GoblinOwnerOnline ~= false} end}
package.loaded['GoblinSurvivor/GoblinBody']=Body

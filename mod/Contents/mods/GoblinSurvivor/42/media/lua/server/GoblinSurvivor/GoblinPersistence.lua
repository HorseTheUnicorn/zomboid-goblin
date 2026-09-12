-- Native item serialization is available only on the Storm dedicated server.
-- No inventory blobs or private disk paths are sent in public ModData.
local Persistence = { states=setmetatable({}, {__mode="k"}) }

function Persistence.available()
    return type(rawget(_G,"goblinServerInventorySave"))=="function"
        and type(rawget(_G,"goblinServerInventoryRestore"))=="function"
end

local function result(body,ok,status)
    local data=body:getModData()
    data.GoblinInventoryPersistent=ok
    data.GoblinInventoryError=not ok and tostring(status) or nil
    local state=Persistence.states[body]
    if state and state.lastError~=data.GoblinInventoryError then
        state.lastError=data.GoblinInventoryError
        if not ok then print('[GoblinSurvivor] INVENTORY_ERROR '..tostring(status)) end
    end
    return ok,status
end

function Persistence.restore(body,id)
    local state=Persistence.states[body]
    if state and state.restored and state.id==id then return true end
    if not Persistence.available() then return false,'server Storm helper unavailable' end
    state={id=id,nextSave=0}
    Persistence.states[body]=state
    local ok,status=pcall(goblinServerInventoryRestore,body,id)
    state.restored=ok and type(status)=='string' and
        (status=='new' or status=='ready' or string.match(status,'^restored:%d+$')~=nil)
    if state.restored then
        print('[GoblinSurvivor] INVENTORY_READY npc_id='..id..' status='..status)
    end
    return result(body,state.restored,status)
end

function Persistence.save(body,force)
    local state=Persistence.states[body]
    if not state or not state.restored then return false,'inventory not restored' end
    local now=getTimestampMs()
    if not force and now<state.nextSave then return true end
    state.nextSave=now+2000
    local ok,status=pcall(goblinServerInventorySave,body,state.id)
    return result(body,ok and (status=='saved' or status=='unchanged'),status)
end

return Persistence

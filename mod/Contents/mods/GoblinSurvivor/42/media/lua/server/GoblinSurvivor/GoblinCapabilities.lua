-- Additive capability registry for server-owned physical jobs.
-- Persistent payloads remain primitive-only; engine objects live only in the
-- weak runtime table below. Qwen never calls this module directly.
local Capabilities = { active = setmetatable({}, { __mode = "k" }) }
local registry = {}
local failureCodes = {
    NO_TARGET=true, NO_PATH=true, BLOCKED=true, LOCKED=true,
    MISSING_MATERIAL=true, MISSING_TOOL=true, TARGET_UNLOADED=true,
    TARGET_CHANGED=true, UNSUPPORTED=true, PERMISSION_DENIED=true,
    INTERRUPTED=true, TIMEOUT=true, ENGINE_ERROR=true
}
local activeCodes = {
    MOVING_TO_TARGET=true, WORKING=true, WAITING_FOR_MATERIAL=true,
    WAITING_FOR_TARGET=true
}

local function boundedDetail(value)
    local text=tostring(value or "")
    if #text>512 then text=string.sub(text,1,512) end
    return text
end

local function primitive(value,seen,depth,budget)
    local kind=type(value)
    if kind=="nil" or kind=="boolean" or kind=="string" then return true end
    if kind=="number" then return value==value and value~=math.huge and value~=-math.huge end
    if kind~="table" or depth>8 or seen[value] then return false end
    seen[value]=true
    for key,child in pairs(value) do
        budget.count=budget.count+1
        if budget.count>256 then seen[value]=nil;return false end
        local keyType=type(key)
        if (keyType~="string" and keyType~="number")
            or not primitive(key,seen,depth+1,budget)
            or not primitive(child,seen,depth+1,budget) then
            seen[value]=nil;return false
        end
    end
    seen[value]=nil
    return true
end

function Capabilities.serializable(value)
    return primitive(value,{},0,{count=0})
end

function Capabilities.result(done,success,code,detail,progress)
    if type(done)~="boolean" or type(success)~="boolean" then
        error("capability result requires boolean done/success")
    end
    if type(code)~="string" then error("capability result code is required") end
    if done and success and code~="COMPLETE" then
        error("successful terminal capability result must use COMPLETE")
    end
    if done and not success and not failureCodes[code] then
        error("terminal failure requires a standard failure code")
    end
    if not done and success and not activeCodes[code] then
        error("active capability result has an unsupported code")
    end
    if not done and not success and not (failureCodes[code] or activeCodes[code]) then
        error("active refusal has an unsupported code")
    end
    progress=tonumber(progress)
    if not progress or progress~=progress or progress<0 or progress>1 then
        error("capability progress must be between zero and one")
    end
    return {done=done,success=success,code=code,detail=boundedDetail(detail),progress=progress}
end

function Capabilities.fromLegacy(done,success,detail,code)
    done=done==true
    if not done then
        return Capabilities.result(false,success~=false,code or "WORKING",detail or "work in progress",0)
    end
    if success==true then return Capabilities.result(true,true,"COMPLETE",detail or "job completed",1) end
    return Capabilities.result(true,false,code or "ENGINE_ERROR",
        detail or "job failed without a specific engine result",0)
end

function Capabilities.register(name,definition)
    if type(name)~="string" or name=="" or name~=string.upper(name) then
        error("capability name must be nonempty uppercase text")
    end
    if registry[name] then error("duplicate capability: "..name) end
    if type(definition)~="table" or type(definition.prepare)~="function"
        or type(definition.update)~="function" then
        error("capability requires prepare and update functions")
    end
    for _,field in ipairs({"destructive","offline_allowed","owner_required"}) do
        if type(definition[field])~="boolean" then
            error("capability "..name.." requires boolean "..field)
        end
    end
    definition.name=name;registry[name]=definition;return true
end

function Capabilities.handles(name)
    return type(name)=="string" and registry[name]~=nil
end

function Capabilities.descriptor(name)
    local definition=registry[name]
    if not definition then return nil end
    return {name=name,destructive=definition.destructive,offline_allowed=definition.offline_allowed,
        owner_required=definition.owner_required,timeout_ms=tonumber(definition.timeout_ms) or 300000}
end

function Capabilities.list()
    local names={};for name in pairs(registry) do names[#names+1]=name end;table.sort(names)
    local result={};for _,name in ipairs(names) do result[#result+1]=Capabilities.descriptor(name) end
    return result
end

function Capabilities.requirements(name,payload)
    local definition=registry[name]
    if not definition then return nil end
    local value=type(definition.requirements)=="function"
        and definition.requirements(payload or {}) or definition.requirements or {}
    if not Capabilities.serializable(value) then return nil end
    return value
end

function Capabilities.prepare(name,body,owner,payload)
    local definition=registry[name]
    if not definition then return nil,"unsupported capability" end
    if definition.owner_required and not owner then return nil,"the owner must be present to issue this job" end
    if type(definition.can_prepare)=="function" then
        local ran,allowed,detail=pcall(definition.can_prepare,body,owner,payload or {})
        if not ran then return nil,"capability preparation check failed" end
        if allowed~=true then return nil,boundedDetail(detail or "capability cannot prepare") end
    end
    local ran,prepared,detail=pcall(definition.prepare,body,owner,payload or {})
    if not ran then return nil,"capability preparation failed" end
    if prepared==nil then return nil,boundedDetail(detail) end
    if not Capabilities.serializable(prepared) then
        return nil,"capability produced a non-serializable job payload"
    end
    return prepared,boundedDetail(detail)
end

local function validResult(value)
    if type(value)~="table" then return false end
    return pcall(Capabilities.result,value.done,value.success,value.code,value.detail,value.progress)
end

function Capabilities.update(name,body,payload,now)
    local definition=registry[name]
    if not definition then return Capabilities.result(true,false,"UNSUPPORTED","unsupported capability",0) end
    if not Capabilities.serializable(payload) then
        return Capabilities.result(true,false,"TARGET_CHANGED",
            "saved job payload is not primitive and serializable",0)
    end
    local runtime=Capabilities.active[body]
    if runtime and runtime.task~=name then Capabilities.cancel(body);runtime=nil end
    if not runtime then runtime={task=name,startedAt=now,skipped={}};Capabilities.active[body]=runtime end
    local timeout=tonumber(definition.timeout_ms) or 300000
    if type(now)=="number" and type(runtime.startedAt)=="number" and now-runtime.startedAt>timeout then
        local result=Capabilities.result(true,false,"TIMEOUT",
            "job stopped after five minutes; check materials and access, then retry",0)
        runtime.last_result=result;return result
    end
    local ran,result=pcall(definition.update,body,payload,runtime,now)
    if not ran or not validResult(result) then
        if type(print)=="function" then
            print("[GoblinSurvivor] CAPABILITY_ERROR task="..name
                .." detail="..boundedDetail(ran and "invalid structured result" or result))
        end
        result=Capabilities.result(true,false,"ENGINE_ERROR",
            "the native job failed; I stopped to avoid repeating a partial operation",0)
    end
    runtime.last_result=result;return result
end

function Capabilities.cancel(body,nextName)
    local runtime=Capabilities.active[body]
    if not runtime then return false end
    local definition=registry[runtime.task]
    -- A same-capability prepare may already have replaced its runtime target.
    if runtime.task~=nextName and definition and type(definition.cancel)=="function" then
        pcall(definition.cancel,body,runtime,"replaced")
    end
    Capabilities.active[body]=nil;return true
end

function Capabilities.snapshot(body)
    local runtime=Capabilities.active[body]
    if not runtime then return nil end
    local definition=registry[runtime.task]
    local result={task=runtime.task,started_at=runtime.startedAt,result=runtime.last_result}
    if definition and type(definition.snapshot)=="function" then
        local ok,extra=pcall(definition.snapshot,body,runtime)
        if ok and Capabilities.serializable(extra) then result.runtime=extra end
    end
    return result
end

return Capabilities

-- Usage: lua tools/analyze_progression.lua [--preset=name] [--start=room:area]
--   [--ability=id:true|false] [--item=id:count] [--flag=id:true|false]
local P=require "developer.tools.progression_project"
local opts={root=".",state={abilities={},items={},flags={}}}
for _,arg in ipairs(arg or {}) do
    local k,v=arg:match("^%-%-([^=]+)=(.+)$")
    if k=="preset" then opts.preset=v
    elseif k=="start" then opts.state.at=v
    elseif k=="ability" or k=="item" or k=="flag" then
        local id,value=v:match("^(.+):([^:]+)$")
        assert(id,"Expected id:value")
        if k=="item" then opts.state.items[id]=assert(tonumber(value),"Expected item count")
        else assert(value=="true" or value=="false","Expected true or false"); opts.state[k=="ability" and "abilities" or "flags"][id]=value=="true" end
    else error("Unknown argument: " .. arg) end
end
local ok,result=pcall(P.check,opts)
if not ok then print(result); os.exit(1) end
P.publish(result,opts); print(result.message)
-- Incomplete/unknown/blocked gameplay conclusions are warnings, not proof of a
-- broken export. Only invalid model references/source data give a failure code.
os.exit(result.ok and 0 or 1)

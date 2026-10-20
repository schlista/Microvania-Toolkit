-- Editable preview state, independent of GUI nodes and player save data.
local Project=require "developer.tools.progression_project"
local M={}
function M.new() return {overrides={abilities={},items={},flags={}},mode="areas",selected=1,page=1} end
function M.run(session,opts)
    opts.state=session.overrides; opts.preset=session.preset
    session.result=Project.check(opts); session.preset=session.result.preset
    session.selected=session.selected or 1; session.page=session.page or 1
    Project.publish(session.result,opts)
    return session.result
end
function M.rows(s)
    local r=s.result; if not r then return {} end
    local out={}
    if s.mode=="areas" or s.mode=="edges" or s.mode=="objectives" then
        for id,v in pairs(r[s.mode]) do
            out[#out+1]={id=id,text="[" .. v.status .. "] " .. id,status=v.status,
                detail=v.path and table.concat(v.path," -> ") or v.reason or "No modeled acquisition route. See gates and diagnostics."}
        end
    elseif s.mode=="diagnostics" then
        for i,d in ipairs(r.diagnostics) do out[#out+1]={id=tostring(i),text=d.code .. " " .. (d.room or d.area or ""),detail=d.message,status="unknown"} end
    elseif s.mode=="presets" then
        for id in pairs(r.config.presets) do out[#out+1]={id=id,text=(id==s.preset and "[selected] " or "") .. id,detail="Select and press Apply to reset the preview to this preset."} end
    elseif s.mode=="start" then
        for id in pairs(r.graph.areas) do out[#out+1]={id=id,text=id,detail="Select and press Apply to start analysis in this area."} end
    else
        local keys={}
        for id in pairs(r.state[s.mode] or {}) do keys[id]=true end
        if s.mode=="abilities" then for _,id in ipairs(r.ability_ids or {}) do keys[id]=true end end
        for _,e in ipairs(r.graph.edges) do for id in pairs((e.requirements or {})[s.mode] or {}) do keys[id]=true end end
        for _,reward in ipairs(r.graph.rewards) do for id in pairs(reward[s.mode] or {}) do keys[id]=true end end
        for _,objective in ipairs(r.graph.objectives) do for id in pairs((objective.requirements or {})[s.mode] or {}) do keys[id]=true end end
        for id in pairs(keys) do
            local value=(r.state[s.mode] or {})[id] or (s.mode=="items" and 0 or false)
            out[#out+1]={id=id,text=id .. " = " .. tostring(value),detail="Preview only. +/- changes counts; Apply toggles abilities/flags. Run refreshes disk inputs."}
        end
    end
    table.sort(out,function(a,b) return a.id<b.id end)
    return out
end
function M.edit(s,delta)
    local row=M.rows(s)[s.selected]; if not row then return end
    if s.mode=="presets" then s.preset=row.id; s.overrides={abilities={},items={},flags={}}
    elseif s.mode=="start" then s.overrides.at=row.id
    elseif s.mode=="items" then s.overrides.items[row.id]=math.max(0,((s.result.state.items or {})[row.id] or 0)+delta)
    elseif s.mode=="abilities" or s.mode=="flags" then s.overrides[s.mode][row.id]=not s.result.state[s.mode][row.id] end
end
return M

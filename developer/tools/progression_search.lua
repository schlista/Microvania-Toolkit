-- Bounded, location-aware state search. Consumable inventory, opened gates,
-- collected rewards and visited objectives belong to each branch independently.
local Requirements = require "mvtk.world.gates.requirements"
local M = {}
local function copy(t)
    local out={}; for k,v in pairs(t or {}) do out[k]=type(v)=="table" and copy(v) or v end; return out
end
M.copy=copy
local function key(s)
    local parts={s.at}
    for _,field in ipairs({"abilities","items","flags","resources","opened","collected","visited"}) do
        local keys={}; for k in pairs(s[field] or {}) do keys[#keys+1]=k end; table.sort(keys)
        for _,k in ipairs(keys) do
            local v=s[field][k]; local value=tostring(v)
            parts[#parts+1]=field .. ":" .. #k .. ":" .. k .. "=" .. type(v) .. ":" .. #value .. ":" .. value
        end
    end
    return table.concat(parts,"|")
end
local function grant(s,reward)
    for k,v in pairs(reward.abilities or {}) do s.abilities[k]=v end
    for k,v in pairs(reward.flags or {}) do s.flags[k]=v end
    for k,v in pairs(reward.items or {}) do s.items[k]=(s.items[k] or 0)+v end
end
local function path(states, index)
    local out={}
    while index do
        local s=states[index]; table.insert(out,1,s.step); index=s.parent
    end
    return out
end
local function run(graph, start, opts, optimistic)
    local clock=opts.clock or os.clock or function() return 0 end
    local deadline=clock()+(opts.max_seconds or 0.25)
    local cap=opts.max_states or 12000
    local initial=copy(start); initial.at=start.at or graph.start
    for _,f in ipairs({"abilities","items","flags","resources","opened","collected","visited"}) do initial[f]=initial[f] or {} end
    local states,seen,head={},{},1
    local result={areas={},objectives={},edges={},obstructions={},complete=true,states=states}
    local function push(s,parent,step)
        -- Objectives are visits with conditions, not a union of different runs.
        for _,o in ipairs(graph.objectives) do
            local location=o.locations and o.locations[s.at]
            local present=o.anywhere or (o.locations and location~=nil) or (not o.locations and o.area==s.at)
            if present and Requirements.evaluate(o.requirements,s) and (optimistic or (not o.unknown and not (location and location.unknown))) then s.visited[o.id]=true end
        end
        local signature=key(s)
        if seen[signature] then return end
        if #states>=cap then result.complete=false; return end
        s.parent,s.step=parent,step
        states[#states+1]=s; seen[signature]=true
        local i=#states
        result.areas[s.at]=result.areas[s.at] or i
        local all=true
        for _,o in ipairs(graph.objectives) do
            if s.visited[o.id] then result.objectives[o.id]=result.objectives[o.id] or i
            elseif o.required~=false then all=false end
        end
        if all then result.campaign=result.campaign or i end
    end
    if not graph.areas[initial.at] then result.complete=false; return result end
    push(initial,nil,"Start " .. initial.at)
    while head<=#states do
        if clock()>deadline then result.complete=false; break end
        local s=states[head]
        for _,r in ipairs(graph.rewards_by_area[s.at] or {}) do
            if not s.collected[r.id] and (optimistic or not r.unknown) and Requirements.evaluate(r.requirements,s) then
                local n=copy(s); n.collected[r.id]=true
                for id,amount in pairs(r.cost or {}) do n.items[id]=(n.items[id] or 0)-amount end
                grant(n,r); push(n,head,"Collect " .. r.id)
            end
        end
        for _,e in ipairs(graph.outgoing[s.at] or {}) do
            local open=e.unlock and s.opened[e.unlock]
            local ok,missing=Requirements.evaluate(e.requirements,s)
            if (open or ok) and (optimistic or not e.unknown) then
                local n=copy(s); n.at=e.to
                if not open then
                    for id,amount in pairs(e.cost or {}) do n.items[id]=(n.items[id] or 0)-amount end
                    if e.unlock then n.opened[e.unlock]=true end
                end
                result.edges[e.id]=result.edges[e.id] or head
                push(n,head,"Traverse " .. e.id .. " -> " .. e.to)
            else
                local reason=e.unknown or table.concat(missing,", ")
                result.obstructions[e.id]=reason
            end
        end
        head=head+1
    end
    return result
end
function M.analyze(graph,start,opts)
    opts=opts or {}; start=start or {}
    local definite=run(graph,start,opts,false)
    local possible=run(graph,start,opts,true)
    local result={areas={},objectives={},edges={},diagnostics=copy(graph.diagnostics or {}),
        complete=definite.complete and possible.complete, explored=#definite.states+#possible.states}
    local function status(known,maybe)
        if known then return "reachable" end
        if maybe or not result.complete or graph.unmodeled_rewards or graph.unmodeled_traversal then return "unknown" end
        return "blocked"
    end
    for id in pairs(graph.areas) do
        result.areas[id]={status=graph.areas[id].unknown and possible.areas[id] and "unknown" or status(definite.areas[id],possible.areas[id]),
            path=definite.areas[id] and path(definite.states,definite.areas[id])}
    end
    for _,o in ipairs(graph.objectives) do
        local i=definite.objectives[o.id]
        result.objectives[o.id]={status=status(i,possible.objectives[o.id]),path=i and path(definite.states,i),area=o.area}
    end
    for _,e in ipairs(graph.edges) do
        result.edges[e.id]={status=status(definite.edges[e.id],possible.edges[e.id]),
            reason=definite.edges[e.id] and "Requirements met on at least one modeled route." or e.unknown
                or (definite.obstructions[e.id] and "Unmet in a reached state: " .. definite.obstructions[e.id])
                or "The source area has no known route.",from=e.from,to=e.to}
    end
    for _,o in ipairs(graph.objectives) do
        local r=result.objectives[o.id]
        if not r.path then
            local upstream,q={},{}
            for area in pairs(o.locations or {[o.area]=true}) do upstream[area]=true; q[#q+1]=area end
            for _,at in ipairs(q) do for _,e in ipairs(graph.edges) do
                if e.to==at and not upstream[e.from] then upstream[e.from]=true; q[#q+1]=e.from end
            end end
            local why={}
            for _,e in ipairs(graph.edges) do
                if upstream[e.to] and definite.areas[e.from] and not definite.edges[e.id] then
                    why[#why+1]=e.id .. ": " .. result.edges[e.id].reason
                end
            end
            r.reason=o.unknown or (#why>0 and table.concat(why,"; ")) or
                "No route satisfies this objective's location and conditions; inspect connectivity and preview state."
        end
    end
    result.campaign=status(definite.campaign,possible.campaign)
    result.path=definite.campaign and path(definite.states,definite.campaign)
    local function warn(code,area,message) result.diagnostics[#result.diagnostics+1]={severity="warning",code=code,area=area,message=message} end
    if not result.complete then warn("analysis_incomplete",nil,"Search bound reached; unreached results are unknown.") end
    -- Structural flood ignores locks and uncertain movement, so no physical
    -- traversal assumption can turn a potentially connected room into an error.
    local reachable,queue={}, {start.at or graph.start}; reachable[queue[1] or ""]=true
    for _,at in ipairs(queue) do for _,e in ipairs(graph.outgoing[at] or {}) do
        if not reachable[e.to] then reachable[e.to]=true; queue[#queue+1]=e.to end
    end end
    for _,o in ipairs(graph.objectives) do
        local r=result.objectives[o.id]
        local connected=o.anywhere or reachable[o.area]
        for area in pairs(o.locations or {}) do connected=connected or reachable[area] end
        if r.status~="reachable" then warn(not connected and "disconnected_objective" or "unreachable_objective",o.area,
            (o.required==false and "Optional " or "Required ") .. o.id .. ": " .. r.status) end
    end
    local reverse={}; for _,e in ipairs(graph.edges) do reverse[e.to]=reverse[e.to] or {}; table.insert(reverse[e.to],e.from) end
    local returns,q={}, {start.at or graph.start}; returns[q[1] or ""]=true
    for _,at in ipairs(q) do for _,from in ipairs(reverse[at] or {}) do if not returns[from] then returns[from]=true; q[#q+1]=from end end end
    for area,r in pairs(result.areas) do
        if r.status=="reachable" and not returns[area] then warn("one_way_trap",area,"No modeled return route to the start; confirm this one-way route is intentional.") end
    end
    local providers,needed,deps={},{},{}
    for _,reward in ipairs(graph.rewards) do for ability in pairs(reward.abilities or {}) do
        providers[ability]=providers[ability] or {}; table.insert(providers[ability],reward.area)
    end end
    for _,e in ipairs(graph.edges) do for ability in pairs((e.requirements or {}).abilities or {}) do needed[ability]=true end end
    for requirement in pairs(needed) do
        local accessible,q={}, {start.at or graph.start}; accessible[q[1] or ""]=true
        for _,at in ipairs(q) do for _,e in ipairs(graph.outgoing[at] or {}) do
            if not ((e.requirements or {}).abilities or {})[requirement] and not accessible[e.to] then
                accessible[e.to]=true; q[#q+1]=e.to
            end
        end end
        for ability,areas in pairs(providers) do
            local trapped=true
            for _,at in ipairs(areas) do if accessible[at] or not reachable[at] then trapped=false end end
            if trapped and not (start.abilities or {})[ability] and not (start.abilities or {})[requirement] then
                deps[ability]=deps[ability] or {}; deps[ability][requirement]=true
            end
        end
    end
    local visiting,done={},{}
    local function visit(ability,chain)
        if visiting[ability] then
            warn(#chain==1 and "locked_upgrade" or "progression_cycle",nil,
                "Upgrade dependency cycle: " .. table.concat(chain," -> ") .. " -> " .. ability .. ". Review alternate routes and preview state.")
            return
        end
        if done[ability] then return end
        visiting[ability]=true; chain[#chain+1]=ability
        for dep in pairs(deps[ability] or {}) do visit(dep,chain) end
        chain[#chain]=nil; visiting[ability]=nil; done[ability]=true
    end
    for ability in pairs(deps) do visit(ability,{}) end
    return result
end
return M

-- Fresh project reads for CLI, Defold commands, Layout Editor and publication.
local Project = require "developer.tools.relationship_project"
local Graph = require "developer.tools.progression_graph"
local Search = require "developer.tools.progression_search"
local Keys = require "mvtk.core.key_ids"
local M = {}
M.report_path="developer/assets/tiled/progression_diagnostics.txt"
M.json_path="developer/assets/tiled/progression_analysis.json"
function M.load(root,path,read)
    return Project.load_table((read or Project.read)((root or ".") .. "/" .. path),path)
end
local function merge(state,overrides)
    for _,field in ipairs({"abilities","items","flags","resources"}) do
        for k,v in pairs(overrides[field] or {}) do
            local key=field=="items" and Keys.canonicalize(k) or k
            state[field][key]=v
        end
    end
    if overrides.at and overrides.at~="" then state.at=overrides.at end
end
function M.check(opts)
    opts=opts or {}; local root=opts.root or "."
    local report=opts.relationships or Project.check(opts)
    local config,err=opts.config,nil
    if not config then config,err=M.load(root,"developer/config/progression_analysis.lua",opts.read) end
    assert(config,err)
    config=Search.copy(config)
    assert(type(config.max_states or 12000)=="number" and (config.max_states or 12000)>=1
        and (config.max_states or 12000)==math.floor(config.max_states or 12000),"max_states must be a positive integer")
    assert(type(config.max_seconds or 0.25)=="number" and (config.max_seconds or 0.25)>0,"max_seconds must be positive")
    local gate_types=M.load(root,"developer/config/gate_types.lua",opts.read)
    config.gate_types=gate_types or {}
    config.gates=M.load(root,"developer/config/gates.lua",opts.read) or {}
    config.collectible_types=M.load(root,"developer/config/collectible_types.lua",opts.read) or {}
    config.boss_types=(report.configs or {}).bosses or {}
    config.game_completion=require("developer.tools.completion_authoring").load(root,opts.read)
    local layout=opts.layout
    if not layout then
        layout=M.load(root,"developer/runtime/layout/world_layout.local.lua",opts.read)
        if not layout then layout,err=M.load(root,"developer/runtime/layout/world_layout.lua",opts.read) end
    end
    assert(layout,err)
    local g=Graph.build(report.index,layout,config)
    for _,d in ipairs(require("developer.tools.completion_authoring").validate(config.game_completion,report.index,config.boss_types,layout)) do g.diagnostics[#g.diagnostics+1]=d end
    local state={abilities={},items={},flags={},resources={}}
    for id,a in pairs((report.configs and report.configs.abilities) or {}) do
        state.abilities[id]=a.starts_unlocked==true
    end
    local ability_defaults=M.load(root,"developer/config/ability_defaults.lua",opts.read)
    for id,value in pairs(ability_defaults and ability_defaults.abilities or {}) do state.abilities[id]=value end
    local creator=M.load(root,"developer/config/creator_settings.lua",opts.read)
    if creator and creator.published then
        for id,v in pairs((creator.overrides or {}).abilities or {}) do state.abilities[id]=v end
    end
    local preset=opts.preset or config.default_preset or "new_game"
    if not (config.presets or {})[preset] then error("Unknown progression preset: " .. tostring(preset)) end
    merge(state,config.presets[preset]); merge(state,opts.state or {})
    for _,field in ipairs({"abilities","items","flags","resources"}) do
        for key,value in pairs(state[field]) do
            assert(type(key)=="string" and key~="","Preview IDs must be nonempty strings")
            if field=="abilities" then assert(type(value)=="boolean","Ability state must be true/false: " .. key) end
            if field=="flags" then assert(type(value)=="boolean" or type(value)=="string" or type(value)=="number","Invalid flag state: " .. key) end
            if field=="resources" then assert(type(value)=="number" and value>=0,"Invalid resource amount: " .. key) end
        end
    end
    for key,amount in pairs(state.items) do assert(type(amount)=="number" and amount>=0 and amount==math.floor(amount),"Invalid inventory count: " .. key) end
    if state.at and not g.areas[state.at] then g.diagnostics[#g.diagnostics+1]={severity="error",code="missing_start_area",message="Preview start is absent: " .. state.at} end
    local structural=false
    for _,d in ipairs(g.diagnostics) do if d.severity=="error" then structural=true end end
    local result
    if structural or not report.ok or not g.start then result={areas={},edges={},objectives={},diagnostics=g.diagnostics,complete=false,campaign="unknown",explored=0}
    else result=Search.analyze(g,state,{max_states=config.max_states,max_seconds=config.max_seconds,clock=opts.clock}) end
    result.graph=g; result.state=state; result.config=config; result.preset=preset
    result.ability_ids={}
    for id in pairs((report.configs and report.configs.abilities) or {}) do result.ability_ids[#result.ability_ids+1]=id end
    table.sort(result.ability_ids)
    result.ok=not structural and report.ok
    result.empty=#(layout.rooms or {})==0
    local required=0; for _,o in ipairs(g.objectives) do if o.required~=false then required=required+1 end end
    if required==0 then result.campaign="no required objectives" end
    for _,d in ipairs(report.diagnostics or {}) do result.diagnostics[#result.diagnostics+1]=d end
    local lines={"Progression: " .. (result.empty and "no placed rooms" or result.campaign) ..
        " | " .. (result.complete and "search complete" or "INCOMPLETE") .. " | preset=" .. preset,
        "Reachable means a route in the authored model, not proof of platforming or combat."
    }
    local function entries(kind,values)
        local keys={}; for key in pairs(values) do keys[#keys+1]=key end; table.sort(keys)
        for _,key in ipairs(keys) do
            local value=values[key]; lines[#lines+1]=kind .. " " .. key .. ": " .. value.status .. (value.reason and " | " .. value.reason or "")
            if value.path then lines[#lines+1]="  " .. table.concat(value.path," -> ") end
        end
    end
    entries("Area",result.areas); entries("Gate",result.edges); entries("Objective",result.objectives)
    for _,d in ipairs(result.diagnostics) do lines[#lines+1]="[" .. d.severity .. "] " .. d.code .. " " .. (d.room or d.area or "") .. ": " .. d.message end
    result.message=table.concat(lines,"\n")
    return result
end
function M.publish(result,opts)
    opts=opts or {}; local root=opts.root or "."
    local function write(path,value)
        if (opts.read or Project.read)(root .. "/" .. path)==value then return false end
        if opts.write then return opts.write(root .. "/" .. path,value) end
        if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
        local f=assert(io.open(root .. "/" .. path,"wb")); assert(f:write(value)); assert(f:close())
    end
    write(M.report_path,result.message .. "\n")
    write(M.json_path,Project.json({version=1,preset=result.preset,complete=result.complete,campaign=result.campaign,
        areas=result.areas,edges=result.edges,objectives=result.objectives,diagnostics=result.diagnostics,explored=result.explored}) .. "\n")
end
function M.require_valid(opts)
    local result=M.check(opts)
    if opts.publish_report then M.publish(result,opts) end
    if opts.log then opts.log(result.message) end
    if not result.ok then error("Progression model blocks publication:\n" .. result.message,0) end
    return result
end
return M

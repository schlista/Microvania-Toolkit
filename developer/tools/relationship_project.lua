-- Project-side relationship gate. Reads disk on every invocation; never trusts
-- package.loaded or the last successful index to approve a changed draft.
local Relationships = require "developer.tools.content_relationships"
local Source = require "developer.tools.project_source"
local Adler32 = require "mvtk.core.adler32"
local M = {}
M.index_path = "developer/assets/tiled/content_index.json"
M.report_path = "developer/assets/tiled/relationship_diagnostics.txt"

local read = Source.read
M.read = read

-- Portable checksum for freshness (not a security hash), also implemented in
-- the Tiled extension. Small integer arithmetic works in LuaJIT and JavaScript.
function M.fingerprint(s)
    s=s:gsub("^\239\187\191", ""):gsub("\r\n","\n")
    return Adler32.fingerprint(s)
end

local load_table = Source.load_table

M.load_table = load_table

function M.json(value)
    local t=type(value)
    if t=="nil" then return "null" end
    if t=="boolean" or t=="number" then return tostring(value) end
    if t=="string" then
        return '"' .. value:gsub('[%z\1-\31\\"]',function(c)
            if c=='"' then return '\\"' end
            if c=='\\' then return '\\\\' end
            return string.format('\\u%04x',c:byte())
        end) .. '"'
    end
    assert(t=="table","Cannot serialize relationship index value: " .. t)
    local parts={}
    if #value>0 or (getmetatable(value) or {}).__json_array then
        for _,v in ipairs(value) do parts[#parts+1]=M.json(v) end
        return '[' .. table.concat(parts,',') .. ']'
    end
    local keys={}; for k in pairs(value) do keys[#keys+1]=k end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    for _,k in ipairs(keys) do parts[#parts+1]=M.json(tostring(k)) .. ':' .. M.json(value[k]) end
    return '{' .. table.concat(parts,',') .. '}'
end

function M.check(opts)
    opts=opts or {}
    local root=opts.root or "."
    local get=opts.read or read
    local maps, diagnostics, sources = {},{},{}
    local source_complete=true
    local function issue(code,path,message)
        diagnostics[#diagnostics+1]={severity="error",code=code,file=path,
            message=message,fix="Correct the file, export the room from Tiled, then run Prepare & Check."}
    end
    local function read_table(path)
        local text=get(root .. "/" .. path)
        if text then sources[path]=M.fingerprint(text) end
        local value,err=load_table(text,path)
        if not value then issue("content_source_unavailable",path,tostring(err)) end
        return value
    end
    local dir="developer/assets/tiled/maps"
    local files=opts.files
    if not files then
        if opts.list_dir_filesystem then
            local ok,_,result=pcall(opts.list_dir_filesystem,root .. "/" .. dir)
            if ok then files=result end
        elseif editor then
            local _,result=require("hooks.core.filesystem").list_dir_filesystem(root .. "/" .. dir)
            files=result
        else
            files=require("developer.tools.dev_helpers").list_files(root .. "/" .. dir)
        end
    end
    if type(files)~="table" then issue("content_index_unavailable",dir,"Cannot enumerate Tiled room exports."); files={} end
    for _,name in ipairs(files) do
        name=name:gsub("\\","/"):match("([^/]+)$")
        if name:match("%.lua$") and name:sub(1,1)~="." then
            local room=name:gsub("%.lua$","")
            local path=dir .. "/" .. name
            local map=read_table(path)
            if map then
                maps[room]={file=path,map=map}
                local tmx_path=dir .. "/" .. room .. ".tmx"
                local tmx=get(root .. "/" .. tmx_path)
                if tmx then
                    sources[tmx_path]=M.fingerprint(tmx)
                    if not map.mvtk_source_signature then
                        source_complete=false
                        diagnostics[#diagnostics+1]={severity="warning",code="export_freshness_unverified",
                            file=tmx_path,room=room,message="This legacy Lua export has no source fingerprint; TMX freshness is unverified.",
                            fix="Export this map once with Export Lua + Defold Tilemap, then run Prepare & Check."}
                    elseif map.mvtk_source_signature~=sources[tmx_path] then
                        issue("stale_tiled_export",tmx_path,"The saved Tiled map changed after its last Lua export.")
                    end
                elseif map.mvtk_source_signature then
                    issue("stale_tiled_export",tmx_path,"The source map for this export is missing.")
                end
            end
        end
    end
    local abilities=read_table("developer/config/abilities.lua")
    local dialogues=read_table("developer/config/narrative/dialogues.lua")
    local arenas=read_table("developer/config/boss_arenas.lua")
    local bosses=read_table("developer/config/boss_types.lua")
    local ok,index=pcall(Relationships.build_index,maps)
    if not ok then
        issue("invalid_content_index",dir,tostring(index))
        index={objects={},rooms={},definitions={},references={}}
    else
        local ds=Relationships.validate(index,{ability_config=abilities,dialogue_config=dialogues,
            arena_config=arenas,boss_config=bosses,published_rooms=opts.published_rooms})
        for _,d in ipairs(ds) do diagnostics[#diagnostics+1]=d end
    end
    if opts.published_rooms then
        for room in pairs(opts.published_rooms) do
            if not maps[room] then issue("missing_layout_room",dir .. "/" .. room .. ".lua","Published layout references a missing room.") end
        end
    end
    local completion=require "developer.tools.completion_authoring"
    for _,path in ipairs({"developer/config/game_completion.lua","developer/config/creator_settings.lua"}) do
        local text=get(root.."/"..path); if text then sources[path]=M.fingerprint(text) end
    end
    local loaded,ending=pcall(completion.load,root,get)
    if not loaded then issue("invalid_completion_config","developer/config/game_completion.lua",tostring(ending))
    else
        for _,d in ipairs(completion.validate(ending,index,bosses,opts.layout)) do diagnostics[#diagnostics+1]=d end
    end
    -- Content checks for mistakes that otherwise fail silently in play.
    -- Missing optional config files skip their check instead of erroring.
    -- Generation preflights check authored inputs only: Create Rooms produces
    -- the chest lookup. Validation/build/publication check it by default,
    -- including when the generated file is missing after a reset.
    local function optional_table(path)
        local text=get(root.."/"..path)
        if not text then return nil end
        local value=load_table(text,path)
        return type(value)=="table" and value or nil
    end
    local Checks=require "developer.tools.content_checks"
    local effective=Checks.effective_settings({
        ability_defaults=optional_table("developer/config/ability_defaults.lua"),
        player_settings=optional_table("developer/config/player_settings.lua"),
        creator=optional_table("developer/config/creator_settings.lua")})
    local chest_inline
    if opts.check_generated ~= false then
        chest_inline=optional_table("developer/config/chest_inline_contents.lua") or {}
    end
    local checks_ok,check_ds=pcall(Checks.validate,index,{abilities=effective.abilities,max_energy=effective.max_energy,
        gate_types=optional_table("developer/config/gate_types.lua"),
        chest_inline=chest_inline})
    if not checks_ok then issue("content_checks_failed","developer/tools/content_checks.lua",tostring(check_ds))
    else for _,d in ipairs(check_ds) do diagnostics[#diagnostics+1]=d end end
    local summary=Relationships.summary(diagnostics)
    local report={ok=summary.errors==0,index=index,diagnostics=diagnostics,summary=summary,sources=sources,source_complete=source_complete,
        ending=loaded and ending or nil,configs={abilities=abilities and abilities.abilities,dialogues=dialogues,arenas=arenas,bosses=bosses}}
    local lines={}
    for _,d in ipairs(diagnostics) do lines[#lines+1]=Relationships.format_diagnostic(d) end
    lines[#lines+1]="Locate in Tiled: open the room TMX, use View > Views and Toolbars > Objects, and find the object ID."
    lines[#lines+1]="Locate in Defold: open developer/rooms/collections/<room>.collection and select <room>_<type>_<object_id>."
    report.message=table.concat(lines,"\n")
    return report
end

function M.snapshot(report)
    local objects=setmetatable({}, {__json_array=true})
    for _,o in ipairs(report.index.objects) do
        objects[#objects+1]={room=o.room,file=o.file,layer=o.layer,object_id=o.object_id,type=o.type,
            name=o.name,visible=o.visible,instance_id=o.instance_id,persistent_id=o.persistent_id,properties=o.properties}
    end
    local configs={}
    for kind,config in pairs(report.configs) do
        configs[kind]={}
        for key in pairs(kind=="arenas" and (config.arenas or config) or config) do configs[kind][key]=true end
    end
    configs.keys={}
    local Keys=require "mvtk.core.key_ids"
    for _,key in ipairs(Keys.canonical_ids()) do configs.keys[key]=true end
    for alias in pairs(Keys.AUTHORED_TO_CANONICAL) do configs.keys[alias]=true end
    configs.boss_phase_counts={}
    for id,config in pairs(report.configs.bosses or {}) do
        if type(config)=="table" and type(config.phases)=="table" then configs.boss_phase_counts[id]=#config.phases end
    end
    return {version=2,sources=report.sources,objects=objects,configs=configs,completion=report.ending,source_complete=report.source_complete}
end

function M.publish_report(report,opts)
    opts=opts or {}; local root=opts.root or "."
    local function put(path,text)
        if (opts.read or M.read)(root .. "/" .. path)==text then return false end
        if opts.write then return opts.write(root .. "/" .. path,text) end
        if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
        local f=assert(io.open(root .. "/" .. path,"wb")); assert(f:write(text)); assert(f:close())
    end
    put(M.report_path,report.message .. "\n")
    -- A failed scan never replaces the last valid cross-room registry.
    if report.ok then put(M.index_path,M.json(M.snapshot(report)) .. "\n") end
end

function M.require_valid(opts)
    local report=M.check(opts)
    if opts and opts.publish_report then M.publish_report(report,opts) end
    if opts and opts.log then
        for _,d in ipairs(report.diagnostics) do opts.log(Relationships.format_diagnostic(d)) end
    end
    if not report.ok then error("Authored relationships block publication:\n" .. report.message,0) end
    return report
end

return M

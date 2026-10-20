-- Shared read-only world freshness checks; kept separate from publication to
-- avoid a dependency cycle in Defold's Lua build graph.
local Source=require "developer.tools.project_source"
local Project=require "developer.tools.relationship_project"
local M={}
local function path_key(path)
    local key=path:gsub("\\", "/"):gsub("/+", "/"):gsub("/%./", "/")
    return key:match("^%a:/") and key:lower() or key
end

-- A world owns placement, while each paired room export owns its content.
-- Accept a newer room only when its exported source dependencies are current and
-- its dimensions/start designation still agree with the exported world.
local function current_room(opts, manifest, member, text)
    local read=opts.read or Source.read
    local root=opts.root or "."
    local map=Source.load_table(text,member.id..".lua")
    if not map or map.orientation~="orthogonal" or map.infinite then return false end
    if map.tilewidth~=manifest.tile_width or map.tileheight~=manifest.tile_height then return false end
    if (tonumber(map.width) or 0)*map.tilewidth~=member.width or
        (tonumber(map.height) or 0)*map.tileheight~=member.height then return false end
    if ((map.properties or {}).is_starting_room==true)~=(member.id==manifest.start_room) then return false end
    local provenance=map.mvtk_provenance
    if not provenance or provenance.version~=1 then return false end
    local found_source=false
    for _,dep in ipairs(provenance.dependencies or {}) do
        local absolute=dep.path:match("^%a:[/\\]") or dep.path:sub(1,1)=="/"
        local path=absolute and dep.path or root.."/"..dep.path
        local content=read(path)
        if not content then return false end
        local signature=dep.binary and opts.fingerprint(content) or Project.fingerprint(content)
        if signature~=dep.fingerprint then return false end
        if path_key(path)==path_key(member.source) then found_source=true end
        -- Headless preparation may use root="." while the Tiled manifest uses
        -- absolute paths. A portable dependency must also match the source bytes.
        local portable=path_key(dep.path):gsub("^%./", "")
        if member.source:match("^%a:[/\\]") then portable=portable:lower() end
        if not absolute and path_key(member.source):sub(-#portable-1)=="/"..portable then
            local original=read(member.source)
            if original and Project.fingerprint(original)==Project.fingerprint(content) then found_source=true end
        end
    end
    -- Import Assets regenerates tilemaps from this Lua export before resolving
    -- the world, so the original Tiled tilemap bytes are not a freshness input.
    return found_source
end
function M.selected_manifest(opts)
    local root=opts.root or ".";local read=opts.read or Source.read
    local function load(path) return Source.load_table(read(root.."/developer/"..path),path) end
    local config=load("config/world_layout_source.lua")
    if not config or config.owner~="tiled" then return nil,false end
    local active=load(config.manifest or "assets/tiled/worlds/active.lua")
    local pending=load("assets/tiled/worlds/pending.lua")
    local manifest=pending and active and pending.source==active.source and pending or active
    return manifest,true
end
function M.check_manifest(opts,manifest,fingerprint)
    local Imported=require "developer.tools.imported_inputs"
    opts=Imported.check_context(opts)
    fingerprint=Imported.memo_fingerprint(fingerprint)
    local root=opts.root or ".";local read=opts.read or Source.read
    local issues={}
    local function issue(path,message) issues[#issues+1]={status="export_needed",path=path,message=message} end
    if not manifest or manifest.version~=1 then issue("Tiled world manifest","Selected world is missing or invalid.");return issues end
    if manifest.input_mode=="project_copies" then
        local checked={}
        -- The manifest is the exported placement snapshot. Original world and
        -- pattern directories are checked by Tiled during export, never here.
        for _,member in ipairs(manifest.maps or {}) do
            checked[member.id]=true
            local path="developer/assets/tiled/maps/"..member.id..".lua"
            local map=Source.load_table(read(root.."/"..path),path)
            if not map then issue(path,"Imported room is missing or invalid. Export the room from Tiled.")
            else
                for _,d in ipairs(require("developer.tools.imported_inputs").check(opts,map,member.id,fingerprint)) do issues[#issues+1]=d end
                local provenance=map.mvtk_provenance or {}
                if not provenance.source or path_key(provenance.source)~=path_key(member.source) then
                    issue(path,"Room came from a different source. Export All Maps and Tiled World.")
                end
                if map.orientation~="orthogonal" or map.infinite or map.tilewidth~=manifest.tile_width or map.tileheight~=manifest.tile_height or
                    (tonumber(map.width) or 0)*(tonumber(map.tilewidth) or 0)~=member.width or
                    (tonumber(map.height) or 0)*(tonumber(map.tileheight) or 0)~=member.height or
                    ((map.properties or {}).is_starting_room==true)~=(member.id==manifest.start_room) then
                    issue(path,"Room dimensions or starting room differ from the exported world. Export All Maps and Tiled World.")
                end
            end
        end
        return issues,checked
    end
    local function verify(path,signature)
        local text=read(path)
        if not text then issue(path,"This legacy world export requires its original sources. Run Export All Maps and Tiled World once with the updated exporter to use imported copies.")
        elseif fingerprint(text)~=signature then issue(path,"World source changed after export. Run Export All Maps and Tiled World.") end
    end
    verify(manifest.source,manifest.source_fingerprint)
    local member_sources={}
    for _,map in ipairs(manifest.maps or {}) do
        member_sources[path_key(map.source)]=true
        local source=read(map.source)
        local path=root.."/developer/assets/tiled/maps/"..map.id..".lua"
        local text=read(path)
        if not source or not text or fingerprint(source)~=map.source_fingerprint or fingerprint(text)~=map.lua_fingerprint then
            local room_opts={root=root,read=read,fingerprint=fingerprint}
            if not (source and text and current_room(room_opts,manifest,map,text)) then
                issue(path,"Room export is missing, stale, or differs from the world dimensions/start room. Run Export Current Room for a content edit; use Export All Maps and Tiled World for world changes.")
            end
        end
    end
    for _,dep in ipairs(manifest.dependencies or {}) do
        if not member_sources[path_key(dep.path)] then verify(dep.path,dep.fingerprint) end
    end
    if manifest.pattern_directory then
        local _,files=(opts.list_dir_filesystem or require("hooks.core.filesystem").list_dir_filesystem)(manifest.pattern_directory)
        local names={};for _,name in ipairs(files or {}) do if name:lower():match("%.tmx$") then names[#names+1]=name end end;table.sort(names)
        if table.concat(names,"\n")~=table.concat(manifest.pattern_files or {},"\n") then issue(manifest.pattern_directory,"World pattern directory membership changed.") end
    end
    return issues
end
function M.check(opts,fingerprint)
    local manifest,selected=M.selected_manifest(opts)
    if not selected then return {} end
    return M.check_manifest(opts,manifest,fingerprint)
end
return M

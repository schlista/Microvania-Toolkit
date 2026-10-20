-- Disk-only Tiled world preparation. No runtime object creation or editor APIs.
local Source=require "developer.tools.project_source"
local P=require "developer.tools.preparation"
local Transaction=require "mvtk.editor.project_transaction"
local WorldProperties=require "mvtk.tiled.world_properties"
local M={pending="assets/tiled/worlds/pending.lua",active="assets/tiled/worlds/active.lua",config="config/world_layout_source.lua"}
local function read(opts,path) return (opts.read or Source.read)((opts.root or ".").."/developer/"..path) end
local function load(opts,path) return Source.load_table(read(opts,path),path) end
function M.source(opts)
    local text=read(opts,M.config)
    local config=text and assert(Source.load_table(text,M.config)) or {owner="layout_editor",manifest=M.active,seen_export=""}
    assert(config.owner=="tiled" or config.owner=="layout_editor","Invalid world layout owner")
    return config
end
function M.pending_export(opts)
    local text=read(opts,M.pending)
    return text and assert(Source.load_table(text,M.pending)),text and P.fingerprint(text)
end
local function config_text(config)
    return "-- Placement owner: tiled or layout_editor. Changed only by an explicit source switch.\n"..
        "-- manifest: selected developer-relative world; seen_export: last reviewed batch fingerprint.\nreturn "..
        require("mvtk.core.creator_settings_model").encode(config).."\n"
end
function M.select(opts,use_tiled)
    local pending,signature=M.pending_export(opts); assert(pending,"Export a Tiled world first")
    local config=M.source(opts); config.seen_export=signature
    local files={}
    if use_tiled then
        config.owner="tiled";config.manifest=M.active
        files[#files+1]={path=M.active,content=read(opts,M.pending)}
        local draft=read(opts,"runtime/layout/draft_revision.lua")
        if draft and not read(opts,"runtime/layout/manual_backup.lua") then files[#files+1]={path="runtime/layout/manual_backup.lua",content=draft} end
    end
    files[#files+1]={path=M.config,content=config_text(config)}
    Transaction.commit((opts.root or ".").."/developer",files,opts.transaction)
    return config
end
function M.take_manual(opts,previous_draft)
    local config=M.source(opts);config.owner="layout_editor"
    local files={{path=M.config,content=config_text(config)}}
    if previous_draft then files[#files+1]={path="runtime/layout/manual_backup.lua",content=P.encode(previous_draft)} end
    return Transaction.commit((opts.root or ".").."/developer",files,opts.transaction)
end
function M.manifest(opts)
    local config=M.source(opts)
    if config.owner~="tiled" then return nil end
    local active=assert(load(opts,config.manifest),"Selected Tiled world is missing; export again")
    local pending=M.pending_export(opts)
    -- Re-exporting the same source updates it automatically; another world needs an explicit switch.
    if pending and pending.source==active.source then return pending end
    return active
end
function M.require_fresh(opts,manifest)
    assert(not read(opts,"assets/tiled/.world_export_transaction.json"),"Interrupted Tiled world export. Run Export All Maps and Tiled World again to recover before preparing.")
    assert(manifest and manifest.version==1 and #manifest.maps>0,"Invalid/empty Tiled world manifest")
    local issues=require("developer.tools.world_provenance").check_manifest(opts,manifest,P.fingerprint)
    if #issues>0 then error(issues[1].message.." "..issues[1].path) end
    return true
end
local opposite={left="right",right="left",up="down",down="up"}
local function door_meta(d,shape)
    -- RoomDoors also supplies inset GUI strokes. Runtime seams belong on the
    -- authored bounds edge; applying that visual inset would move an elevator
    -- doorway away from the neighboring room's doorway in a butt-joined world.
    return {side=d.side,cx=d.side=="left" and 0 or d.side=="right" and shape.w_px or d.cx,
        cy=d.side=="down" and 0 or d.side=="up" and shape.h_px or d.cy,len=d.len_px or d.len}
end

-- Persistent factories and elevator routes belong to the selected world.
-- Other exported maps stay available for authoring without entering this build.
function M.generation_room_ids(opts,available)
    local manifest=opts.world_manifest or M.manifest(opts)
    if not manifest then return available end
    local present,ids={},{}
    for _,id in ipairs(available) do present[id]=true end
    for _,map in ipairs(manifest.maps or {}) do
        assert(present[map.id],"Selected world room export is missing: "..tostring(map.id))
        ids[#ids+1]=map.id
    end
    table.sort(ids)
    return ids
end
function M.selection(opts)
    local pending,signature=M.pending_export(opts);assert(pending,"Export a Tiled world first")
    local config=M.source(opts);config.owner="tiled";config.manifest=M.active;config.seen_export=signature
    return config,pending
end
-- Strict authored seams: no layout-editor attraction radius and no position snapping.
function M.connect(rooms)
    local neighbors,used={},{}
    local ids={};for id in pairs(rooms) do ids[#ids+1]=id;neighbors[id]={} end;table.sort(ids)
    for i,id in ipairs(ids) do for j=i+1,#ids do
        local other=ids[j];local a,b=rooms[id],rooms[other];local ap,bp=a.base_pos,b.base_pos
        local aw,ah,bw,bh=a.shape.w_px,a.shape.h_px,b.shape.w_px,b.shape.h_px
        assert(math.min(ap.x+aw,bp.x+bw)-math.max(ap.x,bp.x)<=0.001 or
            math.min(ap.y+ah,bp.y+bh)-math.max(ap.y,bp.y)<=0.001,"Overlapping world room bounds: "..id.." / "..other)
        for ai,da in ipairs(a.shape.doors or {}) do for bi,db in ipairs(b.shape.doors or {}) do
            if opposite[da.side]==db.side then
                local horizontal=da.side=="left" or da.side=="right"
                local gap=da.side=="right" and bp.x-(ap.x+aw) or da.side=="left" and ap.x-(bp.x+bw) or
                    da.side=="up" and bp.y-(ap.y+ah) or ap.y-(bp.y+bh)
                local ac=horizontal and ap.y+da.cy or ap.x+da.cx
                local bc=horizontal and bp.y+db.cy or bp.x+db.cx
                local al,bl=da.len_px or da.len,db.len_px or db.len
                if math.abs(gap)<0.001 and math.min(ac+al/2,bc+bl/2)-math.max(ac-al/2,bc-bl/2)>0.001 then
                    local ak,bk=id..":"..ai,other..":"..bi
                    assert(not used[ak] and not used[bk],"Ambiguous world door: "..ak.." / "..bk)
                    used[ak]=true;used[bk]=true
                    neighbors[id][#neighbors[id]+1]={id=other,side=da.side,door=door_meta(da,a.shape),mate=door_meta(db,b.shape)}
                    neighbors[other][#neighbors[other]+1]={id=id,side=db.side,door=door_meta(db,b.shape),mate=door_meta(da,a.shape)}
                end
            end
        end end
    end end
    local diagnostics={}
    for _,id in ipairs(ids) do for index,door in ipairs(rooms[id].shape.doors or {}) do
        if not used[id..":"..index] then diagnostics[#diagnostics+1]=string.format("%s: unmatched %s exit %d; align an opposing painted opening in Tiled or leave it intentionally disconnected.",id,door.side,index) end
    end end
    local reached,groups={},0
    local function visit(id) if reached[id] then return end;reached[id]=true;for _,n in ipairs(neighbors[id]) do visit(n.id) end end
    for _,id in ipairs(ids) do if not reached[id] then groups=groups+1;visit(id) end end
    if groups>1 then diagnostics[#diagnostics+1]=string.format("World has %d disconnected door groups. Check intended teleporter/elevator routes in play.",groups) end
    return neighbors,diagnostics
end
function M.candidate(opts,manifest)
    manifest=manifest or M.manifest(opts);M.require_fresh(opts,manifest)
    local world_properties=WorldProperties.validate(manifest.world_properties)
    local root=opts.root or "."
    local function resource(path) if not path or path=="" then return nil end;return (opts.read or Source.read)(root.."/"..path:gsub("^/", "")) end
    local function config(path) return assert(Source.load_table(resource("developer/config/"..path..".lua"),path)) end
    WorldProperties.validate_domains(world_properties,config)
    local tile=config("tile_settings");local rooms,records,files,seen,starts={},{},{},{},0
    local tw,th=manifest.tile_width,manifest.tile_height
    assert(tile.width==tw and tile.height==th,"World tile dimensions differ from tile_settings.lua")
    local doors=require("mvtk.editor.room_doors").with_settings(config("layout_editor_settings"),{},tile)
    local previous=load(opts,"runtime/layout/world_layout.local.lua") or {rooms={}}
    local tags={};for _,r in ipairs(previous.rooms or {}) do tags[r.id]=r.tags end
    for _,m in ipairs(manifest.maps) do
        assert(type(m.id)=="string" and m.id:match("^[%w_][%w_%-]*$") and not seen[m.id:lower()],"Invalid/duplicate world room ID")
        seen[m.id:lower()]=true;files[#files+1]=m.id..".lua"
        local path="/developer/assets/tiled/maps/"..m.id
        local map=assert(Source.load_table(resource(path..".lua"),path))
        assert(map.orientation=="orthogonal" and not map.infinite,"World maps must be finite and orthogonal")
        assert(map.width*tw==m.width and map.height*th==m.height and map.tilewidth==tw and map.tileheight==th,"World map dimensions changed: "..m.id)
        if map.properties and map.properties.is_starting_room then starts=starts+1;assert(m.id==manifest.start_room,"World starting room changed") end
        local shape,err=require("mvtk.editor.room_outline").read_shape(path..".tilemap",true,100000,resource);assert(shape,m.id..": "..tostring(err))
        assert(shape.tile_w==tw and shape.tile_h==th,"Prepared tilesource dimensions differ: "..m.id)
        shape.doors=doors.from_tilemap_text(assert(resource(path..".tilemap")),shape)
        local ox,oy=(shape.min_x-1)*tw,(shape.min_y-1)*th
        local collection_offset_x,collection_offset_y=require("mvtk.map.streaming.room_geometry").collection_offsets(shape,tw,th)
        -- Tiled top-left/down -> Defold bottom-left/up. The common tile step
        -- reconciles zero-based exported cells with the existing layout offset contract.
        local x,y=m.x+tw,-m.y-m.height+th
        rooms[m.id]={shape=shape,tilemap_path=path..".tilemap",base_pos={x=x+ox,y=y+oy},
            map_properties=WorldProperties.resolve(map.properties,world_properties)}
        records[#records+1]={id=m.id,path="developer/rooms/"..m.id,x=x,y=y,w=shape.w_px,h=shape.h_px,ox=ox,oy=oy,tw=tw,th=th,doors={},tags=tags[m.id]}
        records[#records].collection_offset_x=collection_offset_x
        records[#records].collection_offset_y=collection_offset_y
        for _,d in ipairs(shape.doors) do records[#records].doors[#records[#records].doors+1]=door_meta(d,shape) end
    end
    assert(starts==1,"World must contain exactly one starting room")
    local neighbors,diagnostics=M.connect(rooms)
    for _,r in ipairs(records) do r.neighbors=neighbors[r.id] end
    table.sort(records,function(a,b) if a.id==manifest.start_room then return true elseif b.id==manifest.start_room then return false end;return a.id<b.id end)
    local layout={version=8,preserve_origin=true,source={kind="tiled",world=manifest.source},rooms=records,
        world_properties=world_properties}
    local elevators=load(opts,"config/elevators_generated.lua")
    if elevators then
        local resolved,diagnostics=require("mvtk.elevators.layout_resolver").resolve(elevators.manifest or elevators,layout,
            {require_door_hints=true,require_reciprocal=true})
        local errors={};for _,d in ipairs(diagnostics or {}) do if d.severity=="error" then errors[#errors+1]=d.message end end
        assert(resolved and resolved.valid~=false,"Tiled world elevator alignment: "..table.concat(errors,"; "))
    end
    for id in pairs(tags) do if not rooms[id] then diagnostics[#diagnostics+1]="Removed room tags retained in previous_world_layout.lua: "..id end end
    return {layout=layout,rooms=rooms,map_files=files,manifest=manifest,read=resource,settings=config("minimap_settings"),diagnostics=diagnostics}
end
function M.publish(opts,candidate)
    candidate=candidate or M.candidate(opts)
    local root=opts.root or ".";local inputs=P.snapshot(opts)
    local rendered=require("developer.tools.layout_minimap").render(candidate.rooms,{root=root,read=candidate.read,
        tile_width=candidate.manifest.tile_width,tile_height=candidate.manifest.tile_height,settings=candidate.settings,progress=opts.render_progress,
        world_name=candidate.layout.world_properties and candidate.layout.world_properties.world_name})
    rendered.files[#rendered.files+1]={path="runtime/layout/world_layout.local.lua",content=P.encode(candidate.layout)}
    rendered.files[#rendered.files+1]={path="config/poi.lua",content=require("mvtk.editor.layout_editor.tag_export").render(candidate.layout)}
    rendered.files[#rendered.files+1]={path=M.active,content=P.encode(candidate.manifest)}
    rendered.files[#rendered.files+1]={path=M.config,content=config_text(opts.selection or M.source(opts))}
    local manual_backup=read(opts,"runtime/layout/manual_backup.lua")
    if opts.selection then manual_backup=read(opts,"runtime/layout/draft_revision.lua") or manual_backup end
    if manual_backup then rendered.files[#rendered.files+1]={path="runtime/layout/manual_backup.lua",content=manual_backup} end
    local previous=load(opts,"runtime/layout/world_layout.local.lua")
    local backup=read(opts,"runtime/layout/previous_world_layout.lua")
    if previous and P.encode(previous.rooms)~=P.encode(candidate.layout.rooms) then backup=P.encode(previous) end
    if backup then rendered.files[#rendered.files+1]={path="runtime/layout/previous_world_layout.lua",content=backup} end
    M.require_fresh(opts,candidate.manifest)
    return require("developer.tools.layout_publication").publish(root,candidate.layout,rendered.files,{expected_inputs=inputs,
        list_dir_filesystem=opts.list_dir_filesystem,map_files=candidate.map_files,log=opts.log,read=opts.read,transaction=opts.transaction,
        input_paths={["developer/"..M.active]=true,["developer/"..M.config]=true}})
end
return M

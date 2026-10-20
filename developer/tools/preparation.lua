-- Disk-based authoring revisions. Never load cached config modules to approve a build.
local Project = require "developer.tools.relationship_project"
local Model = require "mvtk.core.creator_settings_model"
local Transaction = require "mvtk.editor.project_transaction"
local SpineAddon = require "mvtk.editor.spine_addon"
local M = {version=1, manifest="runtime/layout/publication.lua", prepared="assets/tiled/preparation.lua"}
local roots={"developer/assets/tiled/worlds", "tiled/extensions", "developer/config", "developer/assets/tiled/maps", "developer/assets/tilesheets", "developer/assets/atlas",
    "developer/assets/tiled/backgrounds", "developer/assets/tiled/tilesets", "developer/assets/fonts", "developer/assets/fx",
    "developer/assets/generated_audio", "developer/assets/sfx",
    "developer/assets/enemies", "developer/assets/music", "developer/assets/source", "developer/assets/sprites", "developer/assets/cutscenes",
    "developer/game", "developer/ui", "developer/rooms", "developer/runtime", "hooks"}
-- hooks/project_path.txt and tiled/extensions/export_path.txt only record where
-- this toolkit sits on disk (Project > Set Up This Toolkit, the installers), so
-- moving the folder or re-running setup never makes the publication stale.
local excluded={ ["hooks/project_path.txt"]=true, ["tiled/extensions/export_path.txt"]=true,
    ["developer/"..M.manifest]=true, ["developer/runtime/layout/world_layout.local.lua"]=true,
    ["developer/runtime/layout/draft_revision.lua"]=true,
    ["developer/runtime/layout/manual_backup.lua"]=true,
    ["developer/runtime/layout/previous_world_layout.lua"]=true,
    ["developer/runtime/layout/world_layout.lua"]=true }

M.fingerprint = require("mvtk.core.adler32").fingerprint
local Collection = require "developer.tools.collection_fingerprint"
-- Any editor save re-serializes baked collections without changing them (see
-- collection_fingerprint.lua), so those compare by protobuf meaning. Every
-- other file compares byte for byte.
function M.content_fingerprint(path,content)
    if path:match("%.collection$") then return Collection.fingerprint(content) end
    return M.fingerprint(content)
end
local function get(opts,path) return (opts.read or Project.read)((opts.root or ".").."/"..path) end
local function listing(opts,dir)
    if opts.list_dir_filesystem then return opts.list_dir_filesystem((opts.root or ".").."/"..dir) end
    local dirs,files={},{}
    if editor and editor.can_get then
        if editor.can_get("/"..dir,"children") then
            for _,p in ipairs(editor.get("/"..dir,"children")) do
                local attrs=editor.resource_attributes(p); local name=p:match("([^/]+)$")
                if attrs.is_directory then dirs[#dirs+1]=name elseif attrs.is_file then files[#files+1]=name end
            end
        end
        return dirs,files
    end
    -- Runtime authoring/headless branch: reuse the existing read-only process
    -- directory listing. It handles dotted directory names without probe writes.
    return require("hooks.core.filesystem").list_dir_filesystem((opts.root or ".").."/"..dir)
end
local metrics={snapshots=0,partial_snapshots=0,build_snapshots=0,files=0,bytes=0,seconds=0,calls={}}
function M.reset_stats() metrics={snapshots=0,partial_snapshots=0,build_snapshots=0,files=0,bytes=0,seconds=0,calls={}} end
function M.stats() return metrics end
local function fingerprint(path, content, metric)
    if metric then metric.files=metric.files+1; metric.bytes=metric.bytes+#content end
    return M.content_fingerprint(path,content)
end
local function record(metric, started)
    metric.seconds=os.clock()-started
    metrics.files=metrics.files+metric.files; metrics.bytes=metrics.bytes+metric.bytes
    metrics.seconds=metrics.seconds+metric.seconds; metrics.calls[#metrics.calls+1]=metric
end
local function walk(opts,dir,out,metric)
    local dirs,files=listing(opts,dir)
    for _,name in ipairs(files or {}) do
        local p=dir.."/"..name
        if not excluded[p] and not name:match("^%.") then
            local content=get(opts,p)
            if content then out[p]=fingerprint(p,content,metric) end
        end
    end
    for _,name in ipairs(dirs or {}) do if not name:match("^%.") then walk(opts,dir.."/"..name,out,metric) end end
end
function M.snapshot(opts,caller)
    opts=opts or {}; local out={}
    local started=os.clock(); local metric={caller=caller or opts.caller or "snapshot",files=0,bytes=0}
    local key=opts.paths and "partial_snapshots" or "snapshots"; metrics[key]=metrics[key]+1
    if opts.paths then
        for _,p in ipairs(opts.paths) do local s=get(opts,p); out[p]=s and fingerprint(p,s,metric) or "missing" end
    else
        for _,dir in ipairs(roots) do walk(opts,dir,out,metric) end
        -- Ignored Spine art does not affect an Off project's publication.
        -- Read the controls from disk each time, so a toggle cannot be hidden
        -- by cached runtime config or an editor module's previous state.
        local spine_controls={}
        for _,p in ipairs(SpineAddon.CONTROL_PATHS) do spine_controls[p]=get(opts,p) end
        if SpineAddon.state(spine_controls)=="on" then walk(opts,SpineAddon.ADDON_DIR,out,metric) end
        for _,p in ipairs({"game.project",".defignore","hooks.editor_script","mvtk/editor/spine_addon.lua","mvtk/editor/proto_emit.lua","mvtk/tiled/property_groups.lua",
            "mvtk/tiled/template_versions.lua","mvtk/core/creator_settings_model.lua","mvtk/core/adler32.lua","mvtk/editor/object_art.lua","mvtk/editor/shared_atlas.lua","mvtk/editor/asset_scanner.lua","mvtk/editor/resource_text.lua","mvtk/editor/file_utils.lua","mvtk/editor/tilesheet_sync.lua","mvtk/editor/tilemap_regen.lua","mvtk/editor/player_scale_writer.lua","mvtk/editor/tile_settings_writer.lua","mvtk/editor/project_transaction.lua","hooks/core/io_stats.lua","hooks/core/write_bundle.lua","hooks/core/go_generation.lua","hooks/core/tilesource.lua","hooks/enemy_art_sync.lua","developer/tools/relationship_project.lua","developer/tools/progression_project.lua","developer/tools/dev_helpers.lua","developer/tools/regenerate_minimap.lua","tools/validate_tiled_export.lua","hooks/core/filesystem.lua","developer/tools/preparation.lua","developer/tools/collection_fingerprint.lua",
            "developer/tools/layout_publication.lua","developer/tools/world_layout.lua","developer/tools/world_provenance.lua","developer/tools/imported_inputs.lua","mvtk/editor/background_atlas.lua","developer/tools/layout_minimap.lua","developer/tools/layout_geometry.lua","MVTK.tiled-project","mvtk/editor_host/rooms_manifest.collection"}) do
            local s=get(opts,p); out[p]=s and fingerprint(p,s,metric) or "missing"
        end
    end
    record(metric,started)
    return out
end
function M.diff(a,b)
    local changes,seen={},{}
    for p,v in pairs(a or {}) do if not b or b[p]~=v then changes[#changes+1]=p; seen[p]=true end end
    for p,v in pairs(b or {}) do if not seen[p] and (not a or a[p]~=v) then changes[#changes+1]=p end end
    table.sort(changes); return changes
end
function M.preparation_snapshot(opts,base)
    local out=Model.copy(base or M.snapshot(opts,"preparation_snapshot"))
    -- Layout-authored POI tags affect publication/build, not room generation.
    out["developer/config/poi.lua"]=nil
    return out
end
function M.load(opts,path) return Project.load_table(get(opts,"developer/"..path),path) end
function M.encode(value) return "-- Generated successful authoring revision; do not edit.\nreturn "..Model.encode(value).."\n" end
function M.commit(opts,path,value)
    return Transaction.commit((opts.root or ".").."/developer",{{path=path,content=M.encode(value)}},opts.transaction)
end
-- Disposable single-file diagnostics do not need a multi-file recovery journal.
function M.write_report(opts,path,value)
    assert(path:match("^assets/tiled/[%w_]+%.lua$"),"Invalid report path")
    local absolute=(opts.root or ".").."/developer/"..path
    local text=M.encode(value)
    if get(opts,"developer/"..path)==text then return {} end
    local write=opts.write or (opts.transaction and opts.transaction.fs and opts.transaction.fs.write)
    if write then write(absolute,text)
    else
        require("developer.tools.dev_helpers").ensure_dir(absolute:match("^(.*)/[^/]+$"))
        local f=assert(io.open(absolute,"wb")); local ok,err=f:write(text);local closed,close_err=f:close()
        assert(ok and closed,err or close_err)
        if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
    end
    return {absolute}
end
function M.provenance(opts)
    local Imported=require "developer.tools.imported_inputs"
    opts=Imported.check_context(opts)
    local fingerprint=Imported.memo_fingerprint(M.fingerprint)
    local World=require "developer.tools.world_provenance"
    local issues,checked
    if opts.world_manifest then issues,checked=World.check_manifest(opts,opts.world_manifest,fingerprint)
    else issues,checked=World.check(opts,fingerprint) end
    checked=checked or {}
    if get(opts,"developer/assets/tiled/.world_export_transaction.json") then
        issues[#issues+1]={status="export_needed",path="Tiled world transaction",message="Interrupted world export. Run Export All Maps and Tiled World to recover."}
    end
    local _,files=listing(opts,"developer/assets/tiled/maps")
    if opts.map_files then files=opts.map_files
    else
        local world=opts.world_manifest or World.selected_manifest(opts)
        if world then files={};for _,map in ipairs(world.maps or {}) do files[#files+1]=map.id..".lua" end end
    end
    for _,name in ipairs(files or {}) do if name:match("%.lua$") and not checked[name:gsub("%.lua$","")] then
        local path="developer/assets/tiled/maps/"..name
        local map=Project.load_table(get(opts,path),path)
        local provenance=map and map.mvtk_provenance
        if provenance and provenance.version==2 then
            for _,d in ipairs(Imported.check(opts,map,name:gsub("%.lua$",""),fingerprint)) do issues[#issues+1]=d end
        elseif not provenance or provenance.version~=1 then
            issues[#issues+1]={status="unverified",path=path,message="Re-export this map from Tiled to record source dependencies."}
        else
            for _,dep in ipairs(provenance.dependencies or {}) do
                local absolute=dep.path:match("^%a:[/\\]") or dep.path:sub(1,1)=="/"
                local readable,content=pcall(opts.read or Project.read,absolute and dep.path or ((opts.root or ".").."/"..dep.path))
                if not readable then content=nil end
                if not content then issues[#issues+1]={status="unverified",path=dep.path,message="Source unavailable; freshness cannot be verified."}
                elseif (dep.binary and M.fingerprint(content) or Project.fingerprint(content))~=dep.fingerprint then
                    issues[#issues+1]={status="export_needed",path=dep.path,message="Source changed; export the map from Tiled."}
                end
            end
            if #(provenance.dependencies or {})==0 then issues[#issues+1]={status="unverified",path=path,message="No source dependencies recorded."} end
        end
    end end
    return issues
end
function M.require_exports(opts)
    for _,d in ipairs(M.provenance(opts)) do assert(d.status~="export_needed",d.path..": "..d.message) end
    return true
end
function M.publication(opts,files,layout)
    local outputs={}
    for _,f in ipairs(files) do outputs["developer/"..f.path]=M.content_fingerprint(f.path,f.content) end
    return {version=M.version,inputs=M.snapshot(opts,"publication"),outputs=outputs,layout=layout,
        draft=get(opts,"developer/runtime/layout/draft_revision.lua")}
end
function M.publication_changes(opts,base)
    local manifest=M.load(opts,M.manifest)
    if not manifest or manifest.version~=M.version then return {"developer/"..M.manifest} end
    local changes=M.diff(manifest.inputs,base or M.snapshot(opts,"publication_changes"))
    if manifest.draft~=get(opts,"developer/runtime/layout/draft_revision.lua") then changes[#changes+1]="Layout Editor draft placements" end
    for p,signature in pairs(manifest.outputs or {}) do local s=get(opts,p)
        if not s or M.content_fingerprint(p,s)~=signature then changes[#changes+1]=p end
    end
    return changes
end
function M.require_published(opts)
    local changes=M.publication_changes(opts)
    assert(#changes==0,"Layout publication is stale. For Tiled World run Prepare & Check. For manual placement, prepare/rebuild then Layout Export. Changed: "..table.concat(changes,", "))
    for _,d in ipairs(M.provenance(opts)) do
        assert(d.status~="export_needed","Tiled export is stale: "..d.path)
    end
    return true
end
function M.require_built_sources(opts)
    local built=M.load(opts,"assets/tiled/build_revision.lua")
    assert(built and built.version==M.version,"No successful build revision was recorded. Stop the game, Reload Editor Scripts, Prepare & Check, then Build. If this repeats, check the editor console for an on_build_finished error.")
    assert(built.sources,"Build again to record the source revision before publishing a layout.")
    local before=Model.copy(built.sources)
    local current=M.snapshot(opts)
    -- POI tags are authored by the Layout Editor itself and published below.
    before["developer/config/poi.lua"]=nil; current["developer/config/poi.lua"]=nil
    before["developer/config/world_layout_source.lua"]=nil; current["developer/config/world_layout_source.lua"]=nil
    local changed=M.diff(before,current)
    assert(#changed==0,"The running Layout Editor uses older resources. Stop, Prepare & Check, Build, rescan, and export. Changed: "..table.concat(changed,", "))
end
-- Room generation leaves retired-world outputs in place. Report those files
-- without changing the freshness decision or deleting creator content.
local function generated_orphan_warning(opts)
    opts=opts or {}
    local directory="developer/rooms/generated"
    local _,files=listing(opts,directory)
    if not files or #files==0 then return nil end
    -- Reuse provenance's active/pending world selection without a static
    -- dependency on world_layout (which already requires this module).
    local world,tiled=opts.world_manifest
    if not world then world,tiled=require("developer.tools.world_provenance").selected_manifest(opts) end
    if tiled and not world then return nil end -- Missing world is already a provenance error.
    local prefixes={}
    if world then
        for _,map in ipairs(world.maps or {}) do
            if type(map.id)=="string" and map.id~="" then prefixes[#prefixes+1]=map.id.."_" end
        end
    else
        -- Match Create Rooms: manual placement includes both Lua exports and
        -- tilemap-only rooms, including exports not placed in the layout yet.
        local _,maps=listing(opts,"developer/assets/tiled/maps")
        local seen={}
        for _,name in ipairs(maps or {}) do
            local id=name:match("^(.*)%.lua$") or name:match("^(.*)%.tilemap$")
            if id and id~="" and not seen[id] then
                seen[id]=true; prefixes[#prefixes+1]=id.."_"
            end
        end
    end
    local retired={}
    for _,name in ipairs(files) do
        if not name:match("^%.") then
            local current=false
            for _,prefix in ipairs(prefixes) do
                if name:sub(1,#prefix)==prefix then current=true;break end
            end
            if not current then retired[#retired+1]=name end
        end
    end
    if #retired==0 then return nil end
    table.sort(retired)
    local samples={}
    for i=1,math.min(5,#retired) do samples[i]=retired[i] end
    local remainder=#retired>#samples and string.format("; and %d more",#retired-#samples) or ""
    return {status="warning",code="orphan_generated_files",path=directory,count=#retired,samples=samples,
        message=string.format("Warning: %d generated room files do not match the current world. First files: %s%s. Review these leftovers; Prepare & Check does not remove them.",
            #retired,table.concat(samples,", "),remainder)}
end
function M.status(opts,base)
    base=base or M.snapshot(opts,"status")
    local report={version=M.version,status="ready",next_action="Build/run to play; Export Game packages the published world.",affected={},diagnostics=M.provenance(opts)}
    local has_provenance_diagnostics=#report.diagnostics>0
    local warning=generated_orphan_warning(opts)
    if warning then report.diagnostics[#report.diagnostics+1]=warning end
    for _,d in ipairs(report.diagnostics) do if d.status=="export_needed" then
        report.status="export_needed"; report.next_action=d.message; report.affected[#report.affected+1]=d.path
    end end
    if report.status=="export_needed" then return report end
    local last=M.load(opts,"assets/tiled/preparation_run.lua")
    if last and last.status=="failed" then report.status="failed"; report.next_action="Correct the last preparation failure, then Prepare & Check: "..tostring(last.error); return report end
    local prepared=M.load(opts,M.prepared)
    local changes=M.diff(prepared and prepared.inputs,M.preparation_snapshot(opts,base))
    if not prepared or prepared.version~=M.version or #changes>0 then
        report.status="preparation_needed"; report.next_action="Stop the game, then Project > Prepare & Check."; report.affected=changes
    else
        changes=M.publication_changes(opts,base)
        if #changes>0 then report.status="layout_publication_needed"; report.next_action="Publish your active layout source: Prepare & Check for Tiled World, or Layout Export for Layout Editor."; report.affected=changes
        else
            local built=M.load(opts,"assets/tiled/build_revision.lua")
            if not built or #M.diff(built.inputs,M.build_snapshot(opts,base))>0 then report.status="rebuild_needed"; report.next_action="Build the project to use the published revision." end
        end
    end
    if has_provenance_diagnostics and report.status=="ready" then report.status="unverified"; report.next_action="Restore unavailable sources or re-export legacy maps in Tiled; see diagnostics." end
    return report
end
function M.import_changed(before,after)
    for _,p in ipairs(M.diff(before,after)) do
        -- Taking a Tiled world into the Layout Editor expands generation to all
        -- exported rooms. Those additional rooms also need their assets imported,
        -- even when their exports predate the last world-only preparation.
        if p:match("^developer/assets/") or p:match("^hooks/") or p=="developer/config/tile_settings.lua"
            or p=="developer/config/world_layout_source.lua" or p=="mvtk/editor/asset_scanner.lua" then return true end
    end
    return false
end
function M.build_snapshot(opts,base)
    metrics.build_snapshots=metrics.build_snapshots+1
    base=base or M.snapshot(opts,"build_snapshot/base")
    local out=Model.copy(base)
    local started=os.clock(); local metric={caller="build_snapshot/extra",files=0,bytes=0}
    if not opts.paths then walk(opts,"mvtk",out,metric) end
    local manifest=M.load(opts,M.manifest)
    for p in pairs(manifest and manifest.outputs or {}) do local s=get(opts,p); out[p]=s and fingerprint(p,s,metric) or "missing" end
    local s=get(opts,"developer/"..M.manifest); out["developer/"..M.manifest]=s and fingerprint(M.manifest,s,metric) or "missing"
    record(metric,started)
    return out,base
end
function M.begin_build(opts)
    M.write_report(opts,"assets/tiled/build_pending.lua",{version=M.version,inputs=M.build_snapshot(opts)})
end
function M.record_build(opts)
    local pending=M.load(opts,"assets/tiled/build_pending.lua")
    local inputs,base=M.build_snapshot(opts)
    assert(pending and pending.version==M.version,"Record the inputs with --begin-build before starting the build.")
    assert(#M.diff(pending.inputs,inputs)==0,"Files changed during build; rebuild before recording a successful revision.")
    M.write_report(opts,"assets/tiled/build_revision.lua",{version=M.version,inputs=inputs,sources=base})
end
-- Stage callbacks may yield to native progress UI. Cancellation is checked only
-- between complete stages; no stage publishes draft layout/minimap files.
function M.run(opts,stages)
    local report={version=M.version,status="preparing",stages={},diagnostics={}}
    for i,stage in ipairs(stages) do
        if opts.cancelled and opts.cancelled(i,stage,report) then report.status="cancelled"; return report end
        if opts.progress then opts.progress(i,#stages,stage.name) end
        if opts.stage_start then opts.stage_start(stage.name) end
        local ok,result,err=pcall(stage.run)
        if opts.stage_stop then opts.stage_stop(stage.name) end
        report.stages[#report.stages+1]={name=stage.name,ok=ok and result~=false}
        if not ok or result==false then report.status="failed"; report.error=tostring(not ok and result or err or (stage.name.." returned failure; see its diagnostics.")); return report end
    end
    local base=M.snapshot(opts,"run/end")
    M.write_report(opts,M.prepared,{version=M.version,inputs=M.preparation_snapshot(opts,base)})
    report.status="prepared"; return report,base
end
return M

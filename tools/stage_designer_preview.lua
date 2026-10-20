-- Headless only. tools/designer_preview.ps1 creates and owns this workspace.
local Transaction=require "mvtk.editor.project_transaction"
local Model=require "mvtk.core.creator_settings_model"
local id=assert(Transaction.read(".designer-preview"),"Refusing to stage outside a disposable preview")
local request=require("developer.tools.designer_preview").unpack_request(dofile("preview_request.lua"))
assert(request.version==1 and request.id==id and id:match("^[%d_]+$"),"Invalid preview request")
local function commit(files) return Transaction.commit(".",files) end
if arg[1]=="--course" then
    assert(request.mode=="course")
    local cfg=Model.merge(require "developer.config.movement_test",request.document.overrides.movement_test or {})
    local tile=require "developer.config.tile_settings"
    commit(require("developer.tools.movement_course").files(cfg,tile))
    -- Import Assets is not part of the preview pipeline, so build the course's
    -- tile set with the same generator it uses (tile 0 is fully solid). The
    -- module resolves paths from the working directory, the preview project.
    local image="/developer/assets/tilesheets/designer_course.png"
    commit({{path="developer/assets/tilesheets/designer_course.tilesource",content=require("hooks.core.tilesource")
        .make_tilesource_text(image,tile.width,tile.height,tile.width,tile.height,{tile_collision={[0]=true}})}})
    return
end
if request.mode=="course" then request.document=require("developer.tools.movement_course").document(request.document) end
Model.validate(request.document)
local result,err=require("mvtk.editor.creator_settings_writer").save({requested_document=request.document},
    {force_geometry=true,art_import=request.art_import})
assert(result,err and err.message)
local debug_cfg=require "developer.config.debug_config"
debug_cfg.boot.skip_menu=true
local main=assert(Transaction.read("developer/game/main.collection"))
local input=assert(Transaction.read("developer/input/game.input_binding"))
for i=5,7 do input=input..string.format('\nkey_trigger { input: KEY_F%d action: "preview_f%d" }\n',i,i) end
local paths=assert(Transaction.read("mvtk/core/save_paths.lua"))
-- The copied module routes every modern save scope into this disposable tree.
paths=assert(paths:gsub("return M%s*$",[[function M.path(file,scope)
    assert(not file:find("[/\\]"),"Preview save filename must be a leaf")
    return "./preview_saves/"..(scope or "player").."_"..file
end
return M
]]))
local files={
    {path="developer/config/persistence_settings.lua",content='-- Disposable identity: never reuses player data.\nreturn { game_id = "preview_'..id..'" }\n'},
    {path="developer/config/debug_config.lua",content="return "..Model.encode(debug_cfg).."\n"},
    {path="developer/game/main.collection",content=main..'\ninstances { id: "designer_preview" prototype: "/developer/tools/preview/controls.go" }\n'},
    {path="developer/input/game.input_binding",content=input},
    {path="mvtk/core/save_paths.lua",content=paths},
    {path="preview_saves/README.txt",content="Disposable preview progress only. Remove the job directory after closing the preview.\n"},
}
if request.mode=="course" then files[#files+1]={path=".preview-course",content="1"}
else
    local layout=assert(require("mvtk.rooms.runtime_layout_loader").load())
    assert(#layout.rooms>0,"Export at least one room from Layout Editor before previewing its camera; use Movement test for an empty project.")
end
commit(files)

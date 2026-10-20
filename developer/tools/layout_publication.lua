-- Publish the minimap and runtime world together. Draft autosaves live elsewhere.
local Project = require "developer.tools.relationship_project"
local Transaction = require "mvtk.editor.project_transaction"
local M = {}

function M.publish(root, layout, files, opts)
    opts=opts or {}
    Transaction.recover(root .. "/developer",opts.transaction)
    local placed={}
    for _,room in ipairs(layout and layout.rooms or {}) do placed[room.id]=true end
    assert(next(placed),"Place at least one room before publishing the layout")
    local check={root=root,published_rooms=placed,log=opts.log,publish_report=opts.publish_report,
        read=opts.read,write=opts.write,files=opts.map_files,list_dir_filesystem=opts.list_dir_filesystem}
    -- Re-read just before publication: minimap rendering can yield for frames
    -- while a designer edits/exports rooms in Tiled.
    check.relationships=Project.require_valid(check)
    check.layout=layout
    require("developer.tools.progression_project").require_valid(check)
    local Preparation=require "developer.tools.preparation"
    local publish_opts={root=root,read=opts.read,list_dir_filesystem=opts.list_dir_filesystem,paths=opts.paths}
    local revision=Preparation.publication(publish_opts,files,layout)
    if opts.expected_inputs then
        local changed=Preparation.diff(opts.expected_inputs,revision.inputs)
        assert(#changed==0,"Project changed while the minimap was rendering. Prepare, rebuild, and export again: "..table.concat(changed,", "))
    end
    -- Files that are both inputs and derived outputs (POI tags) must describe
    -- the committed generation, otherwise every successful export is stale.
    for _,file in ipairs(files) do
        local path="developer/"..file.path
        if revision.inputs[path] or (opts.input_paths and opts.input_paths[path]) then revision.inputs[path]=Preparation.content_fingerprint(path,file.content) end
    end
    local committed={}
    for _,file in ipairs(files) do committed[#committed+1]=file end
    committed[#committed+1]={path=Preparation.manifest,content=Preparation.encode(revision)}
    return Transaction.commit(root .. "/developer",committed,opts.transaction)
end

return M

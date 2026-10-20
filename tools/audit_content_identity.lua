-- Headless Lua only: keep a snapshot before renaming/duplicating Tiled content.
-- lua tools/audit_content_identity.lua snapshot .build/before.lua
-- lua tools/audit_content_identity.lua compare .build/before.lua .build/remap.lua
local Audit=require "developer.tools.content_identity"
local Helpers=require "developer.tools.dev_helpers"
local Model=require "mvtk.core.creator_settings_model"
local maps={}
local dir="developer/assets/tiled/maps"
for _,file in ipairs(Helpers.list_files(dir,"%.lua$")) do
    maps[file:gsub("%.lua$","")]=assert(loadfile(dir .. "/" .. file))()
end
local current=Audit.snapshot(maps)
if arg[1]=="snapshot" then
    assert(arg[2],"Provide an output snapshot path")
    local file=assert(io.open(arg[2],"wb"))
    assert(file:write("return " .. Model.encode(current) .. "\n")); assert(file:close())
elseif arg[1]=="compare" then
    local before=assert(loadfile(assert(arg[2],"Provide the previous snapshot")))()
    local remap=arg[3] and assert(loadfile(arg[3]))() or {rooms={},objects={}}
    local report=Audit.compare(before,current,remap)
    print("-- Review all changes and suggested aliases; this command writes no project files.")
    print("return " .. Model.encode(report))
else error("Use snapshot <output.lua> or compare <before.lua> [remap.lua]") end

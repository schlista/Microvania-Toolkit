-- Run from the project root: lua tools/prepare_project.lua [--status]
-- Mutating preparation is intended for CI/disposable projects with Defold stopped.
local ok,err=pcall(function()
    dofile("hooks/editor_core.lua")
    dofile("hooks/editor_script.lua")
    dofile("hooks/editor_generators.lua")
    local commands=dofile("hooks/editor_commands.lua")
    if arg and arg[1]=="--begin-build" then
        require("developer.tools.preparation").begin_build({root="."})
    elseif arg and arg[1]=="--record-build" then
        local P=require "developer.tools.preparation"
        P.record_build({root="."})
    elseif arg and arg[1]=="--status" then
        local report=commands.preparation_commands.status()
        print(require("developer.tools.relationship_project").json(report))
    else commands.preparation_commands.run() end
end)
if not ok then print(tostring(err)); os.exit(1) end

-- Command-line asset/reference scan. Editor preparation uses the shared module
-- with its own filesystem reader so pending tilemap changes are included.
-- Usage: lua developer/tools/asset_scanner.lua [project-root]
local H = require "developer.tools.dev_helpers"
local Scanner = require "mvtk.editor.asset_scanner"
local report = Scanner.scan({
    root = (arg and arg[1] and arg[1] ~= "" and arg[1]) or H.get_project_root(),
    list = function(directory)
        if not H.dir_exists(directory) then return nil, nil end
        return {}, H.list_files(directory)
    end,
    read = H.read_file,
    exists = H.file_exists,
})
print(Scanner.format(report))
if not report.ok then error("Asset scan failed: " .. #report.missing .. " missing reference(s).", 0) end

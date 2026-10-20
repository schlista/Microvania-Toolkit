-- File reads for the native settings window. Called only before/after dialogs;
-- renderers validate against this snapshot without consulting the filesystem.
local Identity = require "developer.tools.project_identity"
local Source = require "developer.tools.project_source"
local M = {}

function M.source_path(value)
    if type(value) ~= "string" then return nil end
    local path = value:gsub("\\", "/"):gsub("^/", ""):gsub("^%./", ""):gsub("/$", "")
    if path == "" or path:find(":", 1, true) or path:find("[%c]") then return nil end
    for part in path:gmatch("[^/]+") do if part == ".." or part == "." then return nil end end
    return path
end

function M.load(deps)
    local root = tostring(deps.root or "."):gsub("\\", "/"):gsub("/$", "")
    local read = deps.read or Source.read
    local context = { identity = Identity.inspect(root, { read = read }) }
    local host = deps.editor
    if host and host.can_get and host.get and host.resource_attributes then
        local paths = {}
        local function visit(path)
            local attrs = host.resource_attributes(path)
            if not attrs.exists then return end
            paths[path:sub(2)] = attrs.is_directory and "directory" or "file"
            if attrs.is_directory and host.can_get(path, "children") then
                for _, child in ipairs(host.get(path, "children")) do visit(child) end
            end
        end
        visit("/")
        context.paths = paths
        local files = {}
        local prefix = "developer/assets/tiled/maps/"
        for path, kind in pairs(paths) do
            if kind == "file" and path:sub(1, #prefix) == prefix then
                local name = path:sub(#prefix + 1)
                if not name:find("/", 1, true) and name:match("%.lua$") then files[#files + 1] = name end
            end
        end
        table.sort(files)
        local function table_at(path)
            local text = read(root .. "/" .. path)
            if text then return assert(Source.load_table(text, path)) end
        end
        local layout = table_at("developer/runtime/layout/world_layout.local.lua")
            or table_at("developer/runtime/layout/world_layout.lua")
        local report = require("developer.tools.relationship_project").check({
            root = root, read = read, files = files, layout = layout })
        context.ending = { index = report.index, bosses = report.configs.bosses, layout = layout }
    end
    return context
end

function M.source_issue(value, mode, context)
    if value == "" then return nil end -- Art import is optional until a source is chosen.
    local path = M.source_path(value)
    if not path then return "Choose a source inside this project, without parent-directory steps." end
    if context and context.paths then
        local kind = context.paths[path]
        if not kind then return "Source is missing: " .. value .. ". Reopen Game Settings after adding it." end
        if mode == "sequence" and kind ~= "directory" then return "Choose a project folder for a sequence." end
        if mode == "sheet" and (kind ~= "file" or not path:lower():match("%.png$")) then return "Choose a PNG file for a sheet." end
    end
end

return M

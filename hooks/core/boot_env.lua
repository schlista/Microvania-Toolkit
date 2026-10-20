-- hooks/core/boot_env.lua
--
-- Tiny boot-time handoff for values discovered by hooks.editor_script before
-- the split hook chunks are loaded.

local M = {}

local project_root = nil

function M.set_project_root(value)
    project_root = value
end

function M.get_project_root()
    return project_root
end

function M.is_project_root(path, open_file)
    if type(path) ~= "string" or path == "" then return false end
    open_file = open_file or io.open
    local ok, file = pcall(open_file, path:gsub("[/\\]+$", "") .. "/game.project", "rb")
    if not ok or not file then return false end
    if type(file.close) == "function" then file:close() end
    return true
end

return M

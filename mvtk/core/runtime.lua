-- mvtk/core/runtime.lua
--
-- Small runtime-environment predicates shared by editor tooling and runtime
-- modules. Keep raw global inspection here so callers do not need to reach
-- into _G directly.

local M = {}

function M.get_editor_api()
    return rawget(_G, "editor")
end

function M.is_editor()
    local editor_api = M.get_editor_api()
    return editor_api ~= nil
end

function M.is_headless()
    local editor_api = M.get_editor_api()
    return not (editor_api and editor_api.create_directory and editor_api.save)
end

return M

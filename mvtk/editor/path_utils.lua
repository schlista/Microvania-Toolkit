-- mvtk/editor/path_utils.lua
-- Pure path string manipulation used by the editor hook scripts.
-- No file I/O and no Defold editor API.
--
-- A subset of helpers (is_path_safe, to_project_fs_path,
-- to_project_resource_path) need the project root. Call M.configure(root)
-- once at boot to set it; downstream calls read it from module state.

local M = {}

M.DIR_SEP = package.config:sub(1, 1)

M.RESOURCE_TOP_LEVEL_DIRS = {
    developer = true,
    mvtk = true,
    game = true,
    assets = true,
    boot = true,
    renderer = true,
    test = true,
    tiled = true,
    docs = true,
    hooks = true,
    tools = true,
}

local _ROOT = "."

function M.normalize(path)
    if path == nil then
        return ""
    end
    path = tostring(path)
    path = path:gsub("\\", "/")
    return (path:gsub("/+", "/"))
end

function M.to_os_path(path)
    if not path then
        return path
    end
    if M.DIR_SEP == "\\" then
        -- string.gsub returns both the rewritten string and the replacement
        -- count. Keep this helper deliberately single-valued: when used as
        -- the final expression in an argv table literal, the second value
        -- otherwise becomes a stray command-line argument (for example the
        -- trailing `9` that made Reset Project's PowerShell helper fail).
        return (path:gsub("/", "\\"))
    end
    return path
end

function M.is_absolute_path(path)
    if not path or path == "" then
        return false
    end
    local first = path:sub(1, 1)
    if first == "/" then
        return true
    end
    if path:match("^[A-Za-z]:") then
        return true
    end
    return false
end

function M.join(...)
    local result = nil
    local count = select('#', ...)
    for i = 1, count do
        local part = select(i, ...)
        if part ~= nil and part ~= '' then
            local seg = tostring(part):gsub('[/\\]+', M.DIR_SEP)
            if not result or result == '' then
                result = seg
            else
                local left_sep = result:sub(-1)
                local right_sep = seg:sub(1, 1)
                if left_sep == M.DIR_SEP then
                    if right_sep == M.DIR_SEP then
                        result = result .. seg:sub(2)
                    else
                        result = result .. seg
                    end
                else
                    if right_sep == M.DIR_SEP then
                        result = result .. seg
                    else
                        result = result .. M.DIR_SEP .. seg
                    end
                end
            end
        end
    end
    return result or ''
end

function M.dirname(path)
    local p = M.normalize(path or "")
    if p == "" then
        return ""
    end
    return p:match("^(.*)/[^/]*$") or ""
end

function M.basename(path)
    local p = M.normalize(path or "")
    return p:match("([^/]+)$") or p
end

function M.configure(root)
    _ROOT = M.normalize(root or ".")
end

function M.get_root()
    return _ROOT
end

function M.is_path_safe(path)
    if not path or path == "" then
        return false
    end
    local normalized = M.normalize(path)
    if normalized:match("%.%.") then
        return false
    end
    if _ROOT and _ROOT ~= "" and _ROOT ~= "." then
        local root_normalized = M.normalize(_ROOT)
        if normalized ~= root_normalized and normalized:sub(1, #root_normalized + 1) ~= root_normalized .. "/" then
            return false
        end
    end
    return true
end

function M.to_project_fs_path(path)
    local normalized = M.normalize(path or "")
    if normalized == "" then
        return normalized
    end
    if normalized:sub(1, 1) == "/" then
        local first = normalized:match("^/([^/]+)")
        if first and M.RESOURCE_TOP_LEVEL_DIRS[first] then
            return M.normalize(M.join(_ROOT, normalized:sub(2)))
        end
    end
    return normalized
end

function M.to_project_resource_path(path)
    local normalized = M.normalize(path or "")
    if normalized == "" then
        return nil
    end

    if normalized:sub(1, 1) == "/" then
        local first = normalized:match("^/([^/]+)")
        if first and M.RESOURCE_TOP_LEVEL_DIRS[first] then
            return normalized
        end
    end

    if _ROOT and _ROOT ~= "" then
        local root_normalized = M.normalize(_ROOT)
        if normalized == root_normalized or normalized:sub(1, #root_normalized + 1) == root_normalized .. "/" then
            normalized = normalized:sub(#root_normalized + 1)
        end
    end

    normalized = normalized:gsub("^%./", "")
    normalized = normalized:gsub("^/+", "")
    local first = normalized:match("^([^/]+)")
    if first and M.RESOURCE_TOP_LEVEL_DIRS[first] then
        return "/" .. normalized
    end

    return nil
end

return M

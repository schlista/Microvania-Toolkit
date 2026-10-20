-- mvtk/editor/file_utils.lua
-- File I/O helpers used by the editor hook scripts.
-- Pairs with mvtk.editor.path_utils for path normalization + project safety.
--
-- Two tiers of helpers are exposed:
--   * read_text / file_exists        -- project-safe: reject paths outside
--                                       the configured project root
--   * *_any variants                 -- tolerate any path, falling back to
--                                       LuaFileSystem then shell commands
--                                       when io.open is sandboxed

local path_utils = require("mvtk.editor.path_utils")

local M = {}
local pending_read
-- Injected by the editor writer; avoids a dependency back into hooks.
function M.set_pending_reader(reader) pending_read=reader end
function M.read_pending(path)
    local fs_path=path_utils.to_project_fs_path(path)
    if path_utils.is_path_safe(fs_path) and pending_read then return pending_read(fs_path) end
end

-- LuaFileSystem belongs only to desktop helpers; the editor has its own API.
local _LFS_OK, _LFS = false, nil
if not editor then _LFS_OK, _LFS = pcall(require, "lfs") end

-- Project-safe file read. Returns nil if the path is outside ROOT or unreadable.
function M.read_disk(path)
    local fs_path = path_utils.to_project_fs_path(path)
    if not path_utils.is_path_safe(fs_path) then
        return nil
    end
    local ok_open, fh = pcall(io.open, fs_path, "rb")
    if not ok_open or not fh then
        return nil
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

function M.read_text(path)
    local fs_path=path_utils.to_project_fs_path(path)
    if not path_utils.is_path_safe(fs_path) then return nil end
    local text=pending_read and pending_read(fs_path)
    if text~=nil then return text end
    return M.read_disk(fs_path)
end

-- Project-safe file existence check.
function M.file_exists(path)
    local fs_path = path_utils.to_project_fs_path(path)
    if not path_utils.is_path_safe(fs_path) then
        return false
    end
    if pending_read and pending_read(fs_path)~=nil then return true end
    local ok_open, fh = pcall(io.open, fs_path, "rb")
    if ok_open and fh then
        fh:close()
        return true
    end
    return false
end

-- Returns (modification_time, size) from LuaFileSystem, or (nil, nil) if LFS
-- is unavailable or the path can't be stat'd.
function M.get_file_signature(path)
    if not _LFS_OK or not _LFS or not _LFS.attributes then
        return nil, nil
    end
    local attrs = _LFS.attributes(path)
    if type(attrs) == "table" then
        return attrs.modification, attrs.size
    end
    local mtime = _LFS.attributes(path, "modification")
    local size = _LFS.attributes(path, "size")
    return mtime, size
end

-- Any-path existence check with LFS and popen fallbacks.
function M.file_exists_any(path)
    if not path or path == "" then
        return false
    end
    if _LFS_OK and _LFS and _LFS.attributes then
        local os_path = path_utils.to_os_path(path)
        local mode = _LFS.attributes(os_path, "mode")
        if mode == "file" or mode == "directory" then
            return true
        end
        if os_path ~= path then
            mode = _LFS.attributes(path, "mode")
            if mode == "file" or mode == "directory" then
                return true
            end
        end
    end
    local ok_open, fh = pcall(io.open, path, "rb")
    if ok_open and fh and fh.close then
        fh:close()
        return true
    end
    if (not ok_open or (fh == nil and type(path) == "string" and path_utils.is_absolute_path(path))) and io and io.popen then
        local exists = false
        if path_utils.DIR_SEP == "\\" then
            local win_path = path_utils.to_os_path(path):gsub('"', '""')
            local proc = io.popen(string.format('cmd /c if exist "%s" (echo 1) else (echo 0)', win_path))
            if proc then
                local line = proc:read("*l")
                proc:close()
                exists = (line == "1")
            end
        else
            local unix_path = path_utils.to_os_path(path):gsub("'", "'\\''")
            local proc = io.popen(string.format("test -e '%s' && echo 1 || echo 0", unix_path))
            if proc then
                local line = proc:read("*l")
                proc:close()
                exists = (line == "1")
            end
        end
        if exists then
            return true
        end
    end
    return false
end

-- Any-path text read with OS-path retry and popen fallback. Returns nil on
-- empty result so callers can distinguish "missing" from "empty file".
function M.read_text_any(path)
    if not path or path == "" then
        return nil
    end
    local ok_open, fh = pcall(io.open, path, "rb")
    if not ok_open or not fh or not fh.read then
        local os_path = path_utils.to_os_path(path)
        if os_path ~= path then
            ok_open, fh = pcall(io.open, os_path, "rb")
        end
    end
    if not ok_open or not fh or not fh.read then
        if (not ok_open or (type(path) == "string" and path_utils.is_absolute_path(path))) and io and io.popen then
            if path_utils.DIR_SEP == "\\" then
                local win_path = path_utils.to_os_path(path):gsub('"', '""')
                local proc = io.popen(string.format('cmd /c type "%s"', win_path))
                if proc then
                    local data = proc:read("*a")
                    proc:close()
                    if data and data ~= "" then
                        return data
                    end
                end
            else
                local unix_path = path:gsub("'", "'\\''")
                local proc = io.popen(string.format("cat '%s'", unix_path))
                if proc then
                    local data = proc:read("*a")
                    proc:close()
                    if data and data ~= "" then
                        return data
                    end
                end
            end
        end
        return nil
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

-- Any-path binary read. Shell fallback is intentionally omitted because
-- `cmd /c type` corrupts binary data (treats 0x1A as EOF, does CR/LF
-- translation). Callers that need external-file binary copies should use
-- copy_file_any (defined in editor_core.lua) which uses `cmd /c copy`.
function M.read_binary_any(path)
    if not path or path == "" then
        return nil
    end
    local ok_open, fh = pcall(io.open, path, "rb")
    if not ok_open or not fh then
        local os_path = path_utils.to_os_path(path)
        if os_path ~= path then
            ok_open, fh = pcall(io.open, os_path, "rb")
        end
    end
    if not ok_open or not fh then
        return nil
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

return M

-- developer/tools/dev_helpers.lua
-- ============================================================================
-- Shared Developer Tool Helpers
-- ============================================================================
-- Common utilities for developer-side tooling scripts (Game Settings,
-- asset scanner, relink, regenerate, tiled import, etc.).
--
-- Provides: file I/O, path normalization, directory operations, OS detection,
-- project root resolution, directory listing, and Tiled map loading.
--
-- Usage (from any developer tool script):
--   local H = require "developer.tools.dev_helpers"
--   if H.file_exists("foo.lua") then ... end
--   local content = H.read_file("bar.txt")

local M = {}

-- ============================================================================
-- LFS (LuaFileSystem) — cached, defensive load
-- ============================================================================
local lfs_ok, lfs = pcall(require, "lfs")

--- Check if LuaFileSystem is available
-- @return true if lfs loaded successfully
function M.has_lfs()
    return lfs_ok and lfs ~= nil
end

--- Get the lfs module (or nil if unavailable)
-- @return lfs module or nil
function M.get_lfs()
    if lfs_ok then return lfs end
    return nil
end

-- ============================================================================
-- OS DETECTION
-- ============================================================================

--- Check if the current OS is Windows
-- @return true on Windows, false on Unix/Mac
function M.is_windows()
    return package.config:sub(1, 1) == "\\"
end

-- ============================================================================
-- PATH UTILITIES
-- ============================================================================

--- Normalize path separators to forward slashes
-- @param path File path string (nil-safe)
-- @return Normalized path with forward slashes
function M.normalize_path(path)
    if type(path) ~= "string" then return "" end
    return path:gsub("\\", "/")
end

-- ============================================================================
-- FILE EXISTENCE
-- ============================================================================

--- Check if a file exists (by attempting to open it)
-- @param path File path to check
-- @return true if the file can be opened for reading
function M.file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

--- Check if a directory exists
-- Uses lfs.attributes if available, falls back to io.open heuristic
-- @param dir Directory path to check
-- @return true if directory exists
function M.dir_exists(dir)
    if lfs_ok and lfs and lfs.attributes then
        local attr = lfs.attributes(dir, "mode")
        return attr == "directory"
    end
    -- Fallback: try opening a temp file in the directory
    local test_fh = io.open(dir .. "/.test_dir_check", "w")
    if test_fh then
        test_fh:close()
        os.remove(dir .. "/.test_dir_check")
        return true
    end
    return false
end

-- ============================================================================
-- FILE I/O
-- ============================================================================

--- Read entire file contents as a string
-- @param path File path to read
-- @param mode Optional open mode (default "rb")
-- @return File contents string, or nil if file cannot be opened
function M.read_file(path, mode)
    local f = io.open(path, mode or "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- Write data to a file
-- @param path File path to write to
-- @param data String data to write
-- @param mode Optional open mode (default "wb")
-- @return true on success, or false + error message on failure
function M.write_file(path, data, mode)
    local f, err = io.open(path, mode or "wb")
    if not f then
        return false, "Cannot open file for writing: " .. tostring(path) .. " - " .. tostring(err)
    end
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
    f:write(data)
    f:close()
    return true
end

--- Copy a file (binary-safe)
-- @param src Source file path
-- @param dest Destination file path
-- @return true on success, or false + error message on failure
function M.copy_file(src, dest)
    local data = M.read_file(src)
    if not data then
        return false, "Cannot read source file: " .. tostring(src)
    end
    return M.write_file(dest, data)
end

-- ============================================================================
-- DIRECTORY OPERATIONS
-- ============================================================================

--- Recursively ensure a directory path exists
-- Creates all intermediate directories. Requires lfs.
-- @param path Directory path to create (forward or back slashes accepted)
-- @param is_file_path If true, the last segment is treated as a filename and skipped
function M.ensure_dir(path, is_file_path)
    local norm = M.normalize_path(path)
    local parts = {}
    for part in norm:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    local count = is_file_path and (#parts - 1) or #parts
    local accum = ""
    for i = 1, count do
        accum = accum .. (i == 1 and parts[i] or ("/" .. parts[i]))
        if lfs_ok and lfs then
            lfs.mkdir(accum)
        else
            -- Fallback to OS command
            if M.is_windows() then
                os.execute('mkdir "' .. accum:gsub("/", "\\") .. '" 2>nul')
            else
                os.execute('mkdir -p "' .. accum .. '" 2>/dev/null')
            end
        end
    end
end

--- List files in a directory matching a pattern
-- Uses lfs.dir if available, falls back to shell commands
-- @param dir Directory path to list
-- @param pattern Lua pattern to filter filenames (e.g., "%.lua$")
-- @return Array of matching filenames
function M.list_files(dir, pattern)
    local files = {}

    if lfs_ok and lfs then
        local ok, iter = pcall(lfs.dir, dir)
        if ok then
            for file in iter do
                if file ~= "." and file ~= ".." and (not pattern or file:match(pattern)) then
                    files[#files + 1] = file
                end
            end
        end
    else
        -- Fallback to shell command
        local cmd
        if M.is_windows() then
            cmd = string.format('cmd /c dir /b "%s" 2>nul', dir)
        else
            cmd = string.format('ls "%s" 2>/dev/null', dir)
        end
        local handle = io.popen(cmd)
        if handle then
            for line in handle:lines() do
                if not pattern or line:match(pattern) then
                    files[#files + 1] = line
                end
            end
            handle:close()
        end
    end

    return files
end

-- ============================================================================
-- PROJECT ROOT DETECTION
-- ============================================================================

--- Detect the project root directory
-- Tries multiple strategies: arg[0], debug.getinfo, known paths
-- @return Absolute path to project root (normalized with forward slashes)
function M.get_project_root()
    -- Strategy 1: From script arg[0]
    if arg and arg[0] and arg[0] ~= "" then
        local root = arg[0]:gsub("[/\\]developer[/\\].*$", "")
        if root ~= arg[0] and M.file_exists(root .. "/game.project") then
            return M.normalize_path(root)
        end
    end

    -- Strategy 2: From debug.getinfo source
    if debug and debug.getinfo then
        local info = debug.getinfo(2, "S")
        if info and info.source then
            local here = info.source:gsub("^@", "")
            local root = here:gsub("[/\\]developer[/\\].*$", "")
            root = M.normalize_path(root)
            if root ~= here and M.file_exists(root .. "/game.project") then
                return root
            end
        end
    end

    -- Strategy 3: Current working directory
    if lfs_ok and lfs and lfs.currentdir then
        local cwd = M.normalize_path(lfs.currentdir())
        if M.file_exists(cwd .. "/game.project") then
            return cwd
        end
    end

    -- Strategy 4: Fallback to "."
    return "."
end

-- ============================================================================
-- TILED MAP LOADING
-- ============================================================================

--- Load a Tiled Lua export file and return its data table
-- @param path Path to the .lua Tiled export file
-- @return data table on success, or nil + error string on failure
function M.load_tiled_map(path)
    local ok, data = pcall(dofile, path)
    if not ok then
        return nil, tostring(data)
    end
    if type(data) ~= "table" then
        return nil, "Tiled file did not return a table: " .. tostring(path)
    end
    return data, nil
end

return M

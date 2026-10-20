-- mvtk/editor/tiled_export.lua
-- Tiled-to-Lua export loader used by the editor hook scripts.
--
-- Responsibilities:
--   * Resolve the configured Tiled Lua-export + .tilemap root paths from
--     developer.config.tiled_object_config.
--   * Compile-and-cache the per-room Lua export chunk (keyed by mtime+size
--     so edits invalidate automatically).
--   * Execute the cached chunk and hand back the returned table.
--   * Warn when the .lua export is older than the corresponding .tilemap
--     (i.e. the user edited in Tiled but forgot to re-export Lua).
--
-- Call M.configure{ tiled_config = ..., logger = ... } once at boot from
-- editor_core.lua. The logger should be the final file-backed info function
-- so staleness warnings land in debug_output.txt, not just stdout.

local path_utils = require("mvtk.editor.path_utils")
local file_utils = require("mvtk.editor.file_utils")

local M = {}

local _tiled_config = nil
local _logger = function(msg) print("[tiled_export] " .. tostring(msg)) end
local _lfs_ok, _lfs = pcall(require, "lfs")

local CACHE = {}

function M.configure(opts)
    opts = opts or {}
    if opts.tiled_config ~= nil then
        _tiled_config = opts.tiled_config
    end
    if opts.logger ~= nil then
        _logger = opts.logger
    end
end

local function get_paths()
    assert(_tiled_config,
        "mvtk.editor.tiled_export.configure{tiled_config=...} must be called before use")
    local paths = assert(_tiled_config.paths,
        "developer.config.tiled_object_config.paths is required")
    local lua_maps = assert(paths.tiled_lua_maps,
        "developer.config.tiled_object_config.paths.tiled_lua_maps is required")
    local tilemaps = assert(paths.tiled_tilemaps,
        "developer.config.tiled_object_config.paths.tiled_tilemaps is required")
    return lua_maps, tilemaps
end

-- Public accessor for callers that need the configured Tiled paths (e.g.
-- regenerating tilemaps from .lua exports).
function M.get_paths()
    return get_paths()
end

-- Compile-cache a Tiled Lua export chunk by file signature. Returns (chunk)
-- or (nil, err). safe_load is injected so the module does not pick between
-- loadstring and load on the caller's behalf.
local function load_chunk(path, safe_load)
    local fs_path = path_utils.to_project_fs_path(path)
    local cache_key = path_utils.normalize(fs_path)
    local mtime, size = file_utils.get_file_signature(fs_path)
    local cached = CACHE[cache_key]

    if cached
        and cached.chunk
        and cached.mtime == mtime
        and cached.size == size then
        return cached.chunk
    end

    local content = file_utils.read_text(fs_path)
    if not content then
        CACHE[cache_key] = nil
        return nil, "cannot read: " .. tostring(fs_path)
    end

    local chunk, err = safe_load(content, "@" .. fs_path)
    if not chunk then
        CACHE[cache_key] = nil
        return nil, err or ("failed to compile: " .. tostring(fs_path))
    end

    if mtime ~= nil or size ~= nil then
        CACHE[cache_key] = {
            mtime = mtime,
            size = size,
            chunk = chunk,
        }
    end

    return chunk
end

local function warn_if_stale(room_id, lua_path, tiled_tilemaps_path)
    if not _lfs_ok or not _lfs or not _lfs.attributes then
        return
    end
    local root = path_utils.get_root()
    local tilemap_path = path_utils.normalize(
        path_utils.join(root, tiled_tilemaps_path, room_id .. ".tilemap"))
    local lua_mtime = _lfs.attributes(lua_path, "modification")
    local tilemap_mtime = _lfs.attributes(tilemap_path, "modification")
    if lua_mtime and tilemap_mtime and tilemap_mtime > lua_mtime then
        _logger(string.format(
            "WARNING: Tiled Lua export appears stale for room '%s' (%s older than %s). Re-export .lua from Tiled.",
            tostring(room_id),
            tostring(lua_path),
            tostring(tilemap_path)
        ))
    end
end

-- Load the Tiled Lua export for a room. Returns (data_table, lua_path) on
-- success or (nil, err) on any failure. Caches the compiled chunk; executes
-- it every call so each caller gets a fresh table.
function M.load(room_id)
    if not room_id or room_id == "" then
        return nil, "no room id provided"
    end

    local safe_load = loadstring or load
    if not safe_load then
        return nil, "Lua loadstring/load unavailable"
    end

    local tiled_maps_path, tiled_tilemaps_path = get_paths()
    local root = path_utils.get_root()
    local lua_path = path_utils.normalize(
        path_utils.join(root, tiled_maps_path, room_id .. ".lua"))

    warn_if_stale(room_id, lua_path, tiled_tilemaps_path)

    local chunk, err = load_chunk(lua_path, safe_load)
    if not chunk then
        return nil, err or "Tiled export not found"
    end

    local ok, data = pcall(chunk)
    if ok and type(data) == "table" then
        local normalized, diagnostics = require("developer.tools.object_references").normalize(data, room_id)
        if #diagnostics > 0 then
            return nil, require("developer.tools.content_relationships").format_diagnostic(diagnostics[1])
        end
        return normalized, lua_path
    elseif ok then
        return nil, "Tiled export did not return a table: " .. lua_path
    else
        return nil, tostring(data)
    end
end

function M.clear_cache()
    CACHE = {}
end

return M

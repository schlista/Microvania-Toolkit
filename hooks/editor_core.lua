-- Shared editor helpers extracted to real modules (see mvtk/editor/*).
-- The project-root-aware helpers (is_path_safe, to_project_fs_path,
-- to_project_resource_path) and their dependents (read_text, file_exists)
-- are bound below once ROOT has been resolved.
local _path_utils = require("mvtk.editor.path_utils")
local _file_utils = require("mvtk.editor.file_utils")
local _proto_utils = require("mvtk.editor.proto_utils")
local _runtime = require("mvtk.core.runtime")
local _tiled_export = require("mvtk.editor.tiled_export")
local _tilemap_regen = require("mvtk.editor.tilemap_regen")
local _tilesheet_sync = require("mvtk.editor.tilesheet_sync")
local _export_packager = require("mvtk.editor.export_packager")
local _project_reset = require("mvtk.editor.project_reset")
local _reset_baseline = require("mvtk.editor.reset_baseline")
local _boot_env = require("hooks.core.boot_env")
local _context = require("hooks.core.context")
local _filesystem = require("hooks.core.filesystem")
local _go_generation = require("hooks.core.go_generation")
local _validation = require("hooks.core.validation")
local _tilesource = require("hooks.core.tilesource")
local _tiled_objects = require("hooks.core.tiled_objects")

local normalize = _path_utils.normalize
local to_os_path = _path_utils.to_os_path
local is_absolute_path = _path_utils.is_absolute_path
local join = _path_utils.join
local path_dirname = _path_utils.dirname
local path_basename = _path_utils.basename
local DIR_SEP = _path_utils.DIR_SEP
local RESOURCE_TOP_LEVEL_DIRS = _path_utils.RESOURCE_TOP_LEVEL_DIRS

local fmt_num = _proto_utils.fmt_num
local split_proto_lines = _proto_utils.split_proto_lines
local split_text_lines = _proto_utils.split_text_lines
local brace_delta = _proto_utils.brace_delta

local get_file_signature = _file_utils.get_file_signature
local read_text_any = _file_utils.read_text_any
local read_binary_any = _file_utils.read_binary_any
local file_exists_any = _file_utils.file_exists_any

-- Tilemap/tilesheet sync entry points exposed to the split editor hook chunks
-- via _context. Without these locals, the references at the bottom of this
-- file resolve to nil and room generation silently no-ops because every call
-- site wraps the function in pcall.
local regenerate_tilemap_from_lua = _tilemap_regen.regenerate
local regenerate_all_tilemaps_from_lua = _tilemap_regen.regenerate_all
local sync_tilesheet_images = _tilesheet_sync.sync

-- These three need ROOT. They are rebound after _path_utils.configure(ROOT).
local is_path_safe = _path_utils.is_path_safe
local to_project_fs_path = _path_utils.to_project_fs_path
local to_project_resource_path = _path_utils.to_project_resource_path
local read_text = _file_utils.read_text
local file_exists = _file_utils.file_exists

local editor_api = _runtime.get_editor_api()
local HEADLESS = _runtime.is_headless()

-- Simple logger (defined early so it's available everywhere)
local function info(msg)
    local full_msg = "[hooks.editor_script] " .. tostring(msg)
    print(full_msg)
end

-- ── Performance Profiler ────────────────────────────────────────────
-- Lightweight timing instrumentation for diagnosing slow room generation.
-- Usage:
--   profiler.reset()
--   profiler.start("label")
--   ... work ...
--   profiler.stop("label")
--   profiler.report()   -- prints sorted timing summary to console
local ROOT
local profiler = {}
do
    local timings = {}   -- label -> { elapsed = 0, calls = 0, t0 = nil }
    -- LuaJ's OsLib clock uses System.currentTimeMillis, so it is already a
    -- wall clock in the editor. Desktop Lua's clock measures CPU time instead.
    local wall_now = os.clock
    if HEADLESS then
        local ok, socket = pcall(require, "socket")
        wall_now = ok and socket.gettime or os.time
    end
    function profiler.now() return wall_now() end

    local function clone_timings(state)
        local copy = {}
        for label, entry in pairs(state or {}) do
            copy[label] = {
                elapsed = entry.elapsed,
                calls = entry.calls,
                t0 = entry.t0,
                order = entry.order,
            }
        end
        return copy
    end

    function profiler.reset()
        timings = {}
    end

    function profiler.snapshot()
        return clone_timings(timings)
    end

    function profiler.restore(state)
        timings = clone_timings(state)
    end

    function profiler.start(label)
        local entry = timings[label]
        if not entry then
            entry = { elapsed = 0, calls = 0, t0 = nil, order = 0 }
            timings[label] = entry
        end
        entry.t0 = profiler.now()
        -- Track insertion order for stable display of equal-time items
        if entry.order == 0 then
            local count = 0
            for _ in pairs(timings) do count = count + 1 end
            entry.order = count
        end
    end

    function profiler.stop(label)
        local entry = timings[label]
        if entry and entry.t0 then
            entry.elapsed = entry.elapsed + (profiler.now() - entry.t0)
            entry.calls = entry.calls + 1
            entry.t0 = nil
        end
    end

    -- Shift every active timer across a modal UI wait; user response time is not work.
    function profiler.exclude_wait(seconds)
        for _,entry in pairs(timings) do if entry.t0 then entry.t0=entry.t0+seconds end end
    end
    function profiler.stop_all()
        for label in pairs(timings) do profiler.stop(label) end
    end
    function profiler.report(extra)
        -- Collect entries into a sortable list
        local list = {}
        for label, entry in pairs(timings) do
            list[#list + 1] = { label = label, elapsed = entry.elapsed, calls = entry.calls, order = entry.order }
        end
        if #list == 0 then
            print("[PERF] No profiling data collected.")
            return
        end
        -- Sort by elapsed time descending, then insertion order
        table.sort(list, function(a, b)
            if a.elapsed ~= b.elapsed then return a.elapsed > b.elapsed end
            return a.order < b.order
        end)
        -- Build the full report as a single string for clean console output
        local lines = {}
        lines[#lines + 1] = ""
        lines[#lines + 1] = "[PERF] ═══════════════════════════════════════════════════════"
        lines[#lines + 1] = "[PERF]  PERFORMANCE REPORT"
        lines[#lines + 1] = "[PERF] ═══════════════════════════════════════════════════════"
        for _, item in ipairs(list) do
            local ms = math.floor(item.elapsed * 1000 + 0.5)
            local suffix = ""
            if item.calls > 1 then
                suffix = string.format("  (%d calls, avg %d ms)", item.calls, math.floor(ms / item.calls + .5))
            end
            lines[#lines + 1] = string.format("[PERF]  %8d ms  %s%s", ms, item.label, suffix)
        end
        lines[#lines + 1] = "[PERF] ═══════════════════════════════════════════════════════"
        lines[#lines + 1] = ""
        for _,line in ipairs(extra or {}) do lines[#lines+1]=line end
        local report_text = table.concat(lines, "\n")
        -- info delivers the consolidated report once to the console and debug log.
        info(report_text)
        -- Write a dedicated perf report file (easy to check after editor freezes)
        local perf_path = (ROOT or ".") .. "/perf_report.txt"
        local fh = io.open(perf_path, "w")
        if fh then
            fh:write("Generated: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
            fh:write(report_text .. "\n")
            fh:close()
        end
    end
end

-- Safe io.open wrapper.  Defold's sandbox THROWS (not returns nil) when
-- accessing paths outside the project directory.  This wraps every io.open
-- call in a pcall so callers get the standard nil, err return on failure.
local _raw_io_open = io.open
local function safe_io_open(path, mode)
    local ok, fh_or_err, err2 = pcall(_raw_io_open, path, mode)
    if ok then
        return fh_or_err, err2
    end
    -- pcall caught the throw — return nil + error string
    return nil, tostring(fh_or_err)
end
-- Replace io.open globally so ALL code (including libraries) is safe
io.open = safe_io_open

local function project_root()
    local candidates = {}

    local function add_candidate(path)
        if not path or path == "" then
            return
        end
        path = normalize(path)
        candidates[#candidates + 1] = path
    end

    -- If the proxy already resolved an absolute root, prefer it.
    add_candidate(_boot_env.get_project_root())

    -- Read explicit project path from hooks/project_path.txt.
    -- This is the most reliable way to get the absolute path in Defold's sandbox.
    -- The file contains a single line with the absolute project root path.
    local path_file = io.open("hooks/project_path.txt", "r")
    if path_file then
        local line = path_file:read("*l")
        path_file:close()
        if line and line ~= "" then
            local override = normalize(line)
            if _boot_env.is_project_root(override, io.open) then
                add_candidate(override)
            else
                info("Ignoring stale hooks/project_path.txt -> " .. tostring(override))
            end
        end
    end

    -- Try to get absolute path from this script's location, and walk up parents
    if debug and debug.getinfo then
        local src = debug.getinfo(1, "S").source
        src = src:gsub("^@", "")
        src = normalize(src)
        local base = src:match("^(.*)/[^/]+$")
        local current = base
        while current and current ~= "" do
            add_candidate(current)
            local parent = current:match("^(.*)/[^/]+$")
            if not parent or parent == current then
                break
            end
            current = parent
        end
    end

    -- Current working directory (best-effort, without hard-coded paths)
    local cwd = "."
    local ok_lfs, lfs_local = pcall(require, "lfs")
    if ok_lfs and lfs_local and lfs_local.currentdir then
        local ok_cwd, val = pcall(lfs_local.currentdir)
        if ok_cwd and val then
            cwd = val
        end
    end
    add_candidate(cwd)
    add_candidate(".")

    -- Pick the first candidate that actually contains game.project.
    -- IMPORTANT: io.open THROWS on paths outside the project sandbox, so
    -- every io.open call must be wrapped in pcall.
    local seen = {}
    for _, test_path in ipairs(candidates) do
        local normalized = normalize(test_path)
        if not seen[normalized] then
            seen[normalized] = true
            local test_file = normalized .. "/game.project"
            local ok_open, fh = pcall(io.open, test_file, "r")
            if ok_open and fh then
                fh:close()
                return normalized
            end
        end
    end

    return "."
end

ROOT = normalize(project_root())

print("[hooks.editor_script] DEBUG: ROOT = " .. tostring(ROOT))
local detected_platform = editor_api and editor_api.platform
if type(detected_platform) == "function" then
    local ok_platform, value = pcall(detected_platform)
    detected_platform = ok_platform and value or nil
end
print("[hooks.editor_script] INFO: platform = "
    .. tostring(detected_platform or (DIR_SEP == "\\" and "windows" or "posix")))
print("[hooks.editor_script] DEBUG: Current working directory check...")
local test_cwd = io.open("game.project", "r")
if test_cwd then
    print("[hooks.editor_script] DEBUG: Can open game.project from current directory")
    test_cwd:close()
else
    print("[hooks.editor_script] DEBUG: Cannot open game.project from current directory")
end

-- Configure the path module so is_path_safe / to_project_fs_path /
-- to_project_resource_path (and file_utils helpers that call them) know the
-- project root.
_path_utils.configure(ROOT)

local ok_stream_settings, StreamSettings = pcall(require, "developer.config.stream_settings")
if not ok_stream_settings or type(StreamSettings) ~= "table" then
    StreamSettings = {}
end

local function stream_resource_dir(value, fallback)
    local path = type(value) == "string" and value ~= "" and value or fallback
    path = normalize(path):gsub("/+$", "")
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    return path
end

local TILED_MAPS_RESOURCE_DIR = stream_resource_dir(StreamSettings.tiled_maps_dir, "/developer/assets/tiled/maps")
local GENERATED_ROOMS_RESOURCE_DIR = stream_resource_dir(StreamSettings.generated_rooms_dir, "/developer/rooms/generated")

local PATH = {
    tilemaps = ROOT .. TILED_MAPS_RESOURCE_DIR,
    generated_go = ROOT .. GENERATED_ROOMS_RESOURCE_DIR,
    generated_scenery_tiles = ROOT .. "/developer/assets/atlas/generated/scenery_tiles",
    generated_bg_tint_fills = ROOT .. "/developer/assets/atlas/generated/background_tint_fills",
    collections = ROOT .. "/developer/rooms/collections",
    factories = ROOT .. "/developer/rooms/factories",
    holder_go = ROOT .. "/developer/rooms/factories/factory_holder.go",
    config_lua = ROOT .. "/developer/config/rooms_config.lua",
    elevator_config_lua = ROOT .. "/developer/config/elevators_generated.lua",
    tiled_object_config_lua = ROOT .. "/developer/config/tiled_object_config.lua",
    manifest_col = ROOT .. "/mvtk/editor_host/rooms_manifest.collection",
    runtime_layout_dir = ROOT .. "/developer/runtime/layout",
    runtime_layout_lua = ROOT .. "/developer/runtime/layout/world_layout.lua",
}

local function require_table_module(module_name)
    local mod = require(module_name)
    assert(type(mod) == "table", module_name .. " must return a table")
    return mod
end

-- Load tileset mapping config (configurable + auto-discovery)
local TilesetMapping = require_table_module("developer.config.tileset_mapping")
info("[hooks.editor_script] Loaded tileset mapping config")

-- Run config validation early so build fails fast on bad data
local function run_config_validation()
    return _validation.run_config_validation(info)
end

-- Manual-only editor workflow: do not validate automatically when the
-- editor script loads. Use the Project menu command instead.

-- Shared runner for validation steps (used by menu + commands)
local list_room_ids
local function run_validate_all(opts)
    opts=opts or {}
    return _validation.run_validate_all({
        info = info,
        root = ROOT,
        to_os_path = to_os_path,
        list_dir_filesystem = _filesystem.list_dir_filesystem,
        list_room_ids = list_room_ids,
        write_if_changed = _filesystem.write_if_changed,
        headless = HEADLESS,
        skip_tests = opts.skip_tests,
        allow_empty = opts.allow_empty,
        layout = opts.layout,
        map_files = opts.map_files,
        world_manifest = opts.world_manifest,
    })
end

-- Register editor menu item to run validations (Lua-only)
local function register_menu()
    return _validation.register_menu({
        info = info,
        editor_api = editor_api,
        headless = HEADLESS,
        run_validate_all = run_validate_all,
    })
end

-- Load Tiled object configuration
local TILED_CONFIG = require_table_module("developer.config.tiled_object_config")
print("[hooks.editor_script] Loaded TILED_CONFIG - collectible offset: " .. tostring(TILED_CONFIG.y_offsets and TILED_CONFIG.y_offsets.collectible or "nil"))

-- Configure the tiled-export loader with the project TILED_CONFIG and a
-- logger thunk that forwards to the module-local `info`. The thunk reads
-- `info` as an upvalue at call time, so when `info` is later rebound to
-- the file-backed logger, staleness warnings route through it automatically.
_tiled_export.configure({
    tiled_config = TILED_CONFIG,
    logger = function(msg) info(msg) end,
})
local function get_tiled_paths()
    return _tiled_export.get_paths()
end
local load_tiled_export = _tiled_export.load
_tiled_objects.configure({
    info = function(msg) info(msg) end,
    load_tiled_export = function(room_id) return load_tiled_export(room_id) end,
    require_table_module = require_table_module,
})

local TileSnap = require_table_module("mvtk.tiled.tile_snap")
local CollisionBox = require_table_module("mvtk.tiled.collision_box")

local lfs_ok, lfs = pcall(require, "lfs")

-- Log file setup - write to project directory
local LOG_FILE = ROOT .. "/debug_output.txt"
local log_handle = nil

local log_rotation_checked = false
local function open_log()
    if not log_handle then
        if not log_rotation_checked then
            log_rotation_checked = true
            local text = read_text(join(ROOT, "developer/config/editor_performance.lua"))
            local chunk = text and (loadstring or load)(text, "@editor_performance.lua")
            local settings = chunk and chunk() or {}
            local limit = tonumber(settings.debug_log_max_bytes) or 5 * 1024 * 1024
            if not HEADLESS and tostring(detected_platform):match("%-win32$")
                    and editor_api and editor_api.execute and limit > 0 then
                local ok, err = pcall(editor_api.execute, "powershell.exe", "-NoProfile", "-NonInteractive",
                    "-ExecutionPolicy", "Bypass", "-File", join(ROOT, "hooks/tools/rotate_debug_log.ps1"),
                    "-ProjectRoot", ROOT, "-MaxBytes", tostring(limit),
                    {reload_resources=false, out="capture", err="stdout"})
                if not ok then print("[LOG] Could not rotate debug log: " .. tostring(err)) end
            end
        end
        log_handle = io.open(LOG_FILE, "a")
        if log_handle then
            log_handle:write("\n=== Editor Script Session: " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
            log_handle:flush()
        end
    end
end

local function close_log()
    if log_handle then
        log_handle:close()
        log_handle = nil
    end
end

-- File-backed logger (extends the early info logger)
do
    local base_info = info
    function info(msg)
        local full_msg = "[hooks.editor_script] " .. tostring(msg)
        base_info(full_msg)
        open_log()
        if log_handle then
            log_handle:write(full_msg .. "\n")
            log_handle:flush()
        end
    end
end

_filesystem.configure({
    root = ROOT,
    editor_api = editor_api,
    headless = HEADLESS,
    info = function(msg) info(msg) end,
    profiler = profiler,
    lfs_ok = lfs_ok,
    lfs = lfs,
})
local ensure_dir = _filesystem.ensure_dir
local list_dir_filesystem = _filesystem.list_dir_filesystem
local copy_file_basic = _filesystem.copy_file_basic
local copy_directory_filesystem = _filesystem.copy_directory_filesystem
local write_if_changed = _filesystem.write_if_changed
local write_binary_if_changed = _filesystem.write_binary_if_changed
local is_array = _filesystem.is_array
local serialize_value = _filesystem.serialize_value
local write_layout_module = _filesystem.write_layout_module
local run_process = _filesystem.run_process
local run_shell_command_with_exit_code = _filesystem.run_shell_command_with_exit_code
local remove_path_filesystem = _filesystem.remove_path_filesystem
local copy_file_any = _filesystem.copy_file_any

-- is_path_safe, to_project_fs_path, to_project_resource_path, read_text, and
-- file_exists are bound at the top of this file from mvtk.editor.path_utils /
-- mvtk.editor.file_utils. The path-utils module was configured with ROOT
-- above, so these helpers are ready to use.

_tilesource.configure({
    root = ROOT,
    path = PATH,
    tileset_mapping = TilesetMapping,
    info = function(msg) info(msg) end,
    load_tiled_export = function(room_id) return load_tiled_export(room_id) end,
    write_if_changed = write_if_changed,
    copy_file_any = copy_file_any,
    list_dir_filesystem = list_dir_filesystem,
})
local Tilesource = _tilesource
local PNG_DIMENSION_CACHE = Tilesource.PNG_DIMENSION_CACHE
local TSX_META_CACHE = Tilesource.TSX_META_CACHE
local STANDARD_TILE_COLLISION_GROUP = Tilesource.STANDARD_TILE_COLLISION_GROUP
local STANDARD_TILE_COLLISION_FIRST = Tilesource.STANDARD_TILE_COLLISION_FIRST
local STANDARD_TILE_COLLISION_LAST = Tilesource.STANDARD_TILE_COLLISION_LAST
local resolve_tilesource_collision_resource = Tilesource.resolve_tilesource_collision_resource
local resolve_image_path = Tilesource.resolve_image_path
local get_png_dimensions = Tilesource.get_png_dimensions
local collect_missing_generated_rooms = Tilesource.collect_missing_generated_rooms
local sanitize_asset_name = Tilesource.sanitize_asset_name
local get_tiled_property = Tilesource.get_tiled_property
local parse_xml_attributes = Tilesource.parse_xml_attributes
local resolve_source_file = Tilesource.resolve_source_file
local parse_tsx_tileset = Tilesource.parse_tsx_tileset
local get_tileset_meta = Tilesource.get_tileset_meta
local collect_collection_source_dirs = Tilesource.collect_collection_source_dirs
local maybe_infer_missing_collection_tile_image = Tilesource.maybe_infer_missing_collection_tile_image
local make_tilesource_text = Tilesource.make_tilesource_text
local tilesource_matches_grid = Tilesource.tilesource_matches_grid
local count_non_four_point_hulls = Tilesource.count_non_four_point_hulls
local ensure_tilesource_from_tiled = Tilesource.ensure_tilesource_from_tiled
local resolve_tilesource = Tilesource.resolve_tilesource
local update_tilemap_tilesource = Tilesource.update_tilemap_tilesource
local update_all_tilemap_tilesources = Tilesource.update_all_tilemap_tilesources
local relink_prefab_tilemaps = Tilesource.relink_prefab_tilemaps

-- fmt_num and get_file_signature are bound at the top of this file from
-- mvtk.editor.proto_utils / mvtk.editor.file_utils. Tiled export loading
-- (get_tiled_paths / load_tiled_export + internal chunk cache) lives in
-- mvtk.editor.tiled_export and is bound right after TILED_CONFIG is loaded.

_export_packager.configure({
    root = ROOT,
    join = join,
    file_exists_any = file_exists_any,
})
local ensure_main_collection = _export_packager.ensure_main_collection
local ensure_native_extension_app_manifest = _export_packager.ensure_native_extension_app_manifest
local prepare_export_game_project = _export_packager.prepare_export_game_project

-- Filesystem, shell, copy, and write helpers live in hooks.core.filesystem.

list_room_ids = function()
    local ids = {}
    local seen = {}
    local function room_id_from_export_name(name)
        if not name or name == "" then
            return nil
        end
        if name:sub(-8) == ".tilemap" then
            return name:sub(1, -9)
        end
        if name:sub(-4) == ".lua" then
            return name:sub(1, -5)
        end
        return nil
    end
    local function add_room_id(id)
        if not id or id == "" or seen[id] then
            return
        end
        seen[id] = true
        ids[#ids + 1] = id
    end
    local resource_children = nil
    local cg_ok1, cg_res1 = pcall(function()
        return editor_api and editor_api.can_get and editor_api.can_get("/developer/rooms", "children")
    end)
    if cg_ok1 and cg_res1 then
        local cg_ok2, cg_res2 = pcall(function()
            return editor_api.can_get(TILED_MAPS_RESOURCE_DIR, "children")
        end)
        if cg_ok2 and cg_res2 then
            local ok, children = pcall(editor_api.get, TILED_MAPS_RESOURCE_DIR, "children")
            if ok and children then
                resource_children = children
                info("list_room_ids: editor children count=" .. tostring(#children))
            else
                info("list_room_ids: editor.get(tiled_maps_dir,'children') failed: " .. tostring(children))
            end
        end
    end
    local editor_count = 0
    if resource_children then
        for _, resource in ipairs(resource_children) do
            local name = resource:match("/([^/]+)$") or resource
            local room_id = room_id_from_export_name(name)
            if room_id then
                add_room_id(room_id)
                editor_count = editor_count + 1
            end
        end
        info("list_room_ids: using editor resource listing (" .. tostring(editor_count) .. " entries)")
    end

    -- Scan the maps folder ON DISK and union it with the editor resource listing
    -- above. The on-disk scan ALWAYS runs (it is not gated behind a stale or
    -- empty editor resource tree), so a room exported from Tiled moments ago is
    -- found even before Defold rescans its resources. It is also SOFT: a missing
    -- or empty maps folder just yields no rooms, never a hard error. Enumeration
    -- failing was the old "list_room_ids requires lfs or editor resource
    -- listing" crash; there is nothing here a creator can act on by crashing.
    local fs_count = 0
    if lfs_ok and lfs and lfs.attributes then
        local mode = lfs.attributes(PATH.tilemaps, "mode")
        if mode == "directory" then
            info("list_room_ids: scanning lfs at " .. PATH.tilemaps)
            for name in lfs.dir(PATH.tilemaps) do
                local room_id = room_id_from_export_name(name)
                if room_id then
                    add_room_id(room_id)
                    fs_count = fs_count + 1
                end
            end
        else
            info("list_room_ids: maps folder not present yet at " .. PATH.tilemaps)
        end
    else
        -- Force the configured process adapter here because a just-exported
        -- Tiled room may not be present in Defold's resource tree yet.
        info("list_room_ids: no lfs; process-listing " .. PATH.tilemaps)
        local _, disk_files = list_dir_filesystem(PATH.tilemaps, { force_process = true })
        for _, name in ipairs(disk_files or {}) do
            local room_id = room_id_from_export_name(name)
            if room_id then
                add_room_id(room_id)
                fs_count = fs_count + 1
            end
        end
    end
    info("list_room_ids: on-disk scan saw " .. tostring(fs_count) .. " entries")
    table.sort(ids)
    if #ids == 0 then
        info("list_room_ids: no room exports found in " .. PATH.tilemaps
            .. ". Export a room from Tiled first (File > Export Lua + Defold Tilemap)."
            .. " If you just exported and Defold has not caught up, use"
            .. " Project > Fetch Libraries (or reopen the project) and retry.")
        return ids
    end
    info("list_room_ids: found " .. tostring(#ids) .. " room export(s)")
    return ids
end

-- =============================================================================
-- AUTOMATED TILESOURCE ASSIGNMENT
-- =============================================================================

-- Tilesource, image, TSX, and tileset import helpers live in hooks.core.tilesource.

-- =============================================================================
-- TILEMAP REGENERATION + TILESHEET SYNC
--
-- Tiled .lua → Defold .tilemap regeneration lives in
-- mvtk.editor.tilemap_regen, and Tiled-source-PNG syncing lives in
-- mvtk.editor.tilesheet_sync. Both are configured above with the
-- collaborators that live in this file (writers, shell runner, copy helper,
-- resolve_tilesource, get_tiled_property, get_tileset_meta,
-- ensure_tilesource_from_tiled, profiler, logger).
-- =============================================================================
-- TILED PREFLIGHT
-- =============================================================================

local TiledObjects = _tiled_objects
local load_object_type_set = TiledObjects.load_object_type_set
local REQUIRED_OBJECT_FIELDS = TiledObjects.REQUIRED_OBJECT_FIELDS
local unwrap_tiled_prop_value = TiledObjects.unwrap_tiled_prop_value
local to_optional_bool = TiledObjects.to_optional_bool
local get_prop_value = TiledObjects.get_prop_value
local has_prop = TiledObjects.has_prop
local normalize_object_type = TiledObjects.normalize_object_type
local is_background_layer_name = TiledObjects.is_background_layer_name
local is_background_visual_object_candidate = TiledObjects.is_background_visual_object_candidate
local infer_object_type = TiledObjects.infer_object_type
local resolve_object_type = TiledObjects.resolve_object_type
local validate_object_fields = TiledObjects.validate_object_fields
local preflight_tiled_map = TiledObjects.preflight_tiled_map
local preflight_tiled_maps = TiledObjects.preflight_tiled_maps
-- =============================================================================

local function append_resource_path(value, acc, visited)
    local vtype = type(value)
    if vtype == "string" then
        acc[#acc + 1] = value
    elseif vtype == "userdata" then
        if visited[value] then
            return
        end
        visited[value] = true
        if editor_api and editor_api.get then
            local ok, path = pcall(editor_api.get, value, "path")
            if ok and type(path) == "string" then
                acc[#acc + 1] = path
            end
        end
    elseif vtype == "table" then
        if visited[value] then
            return
        end
        visited[value] = true
        if type(value.path) == "string" then
            acc[#acc + 1] = value.path
        end
        for _, item in pairs(value) do
            local itype = type(item)
            if itype == "string" or itype == "table" or itype == "userdata" then
                append_resource_path(item, acc, visited)
            end
        end
    end
end

local function tilemap_id_from_resource(path)
    if type(path) ~= "string" then
        return nil
    end
    local normalized = normalize(path)
    if normalized:sub(-8) ~= ".tilemap" then
        return nil
    end
    local rid = normalized:match("/([^/]+)%.tilemap$")
    if not rid then
        rid = normalized:match("([^/]+)%.tilemap$")
    end
    return rid
end

local function get_selected_tilemap_ids(opts)
    local resources = {}
    local visited = {}
    if opts ~= nil then
        append_resource_path(opts, resources, visited)
        if type(opts) == "table" and opts.selection ~= nil then
            append_resource_path(opts.selection, resources, visited)
        end
    end
    if #resources == 0 and editor_api and editor_api.get_selection then
        local ok, selection = pcall(editor_api.get_selection, "resources")
        if ok and selection then
            append_resource_path(selection, resources, visited)
        end
    end
    local ids = {}
    local seen = {}
    for _, res in ipairs(resources) do
        local rid = tilemap_id_from_resource(res)
        if rid and not seen[rid] then
            ids[#ids + 1] = rid
            seen[rid] = true
        end
    end
    table.sort(ids)
    return ids
end

_go_generation.configure({
    info = function(msg) info(msg) end,
    collision_box = CollisionBox,
    get_png_dimensions = get_png_dimensions,
    -- Bake per-tile collision shapes (Tiled Tile Collision Editor) into each
    -- generated level.go. Tilesource is configured above, so this is ready.
    gen_tile_collision = function(rid) return Tilesource.gen_room_tile_collision(rid) end,
    gen_object_collision = function(rid) return Tilesource.gen_room_object_collision(rid) end,
})
local GoGeneration = _go_generation
local LEVEL_GO_TEMPLATE = GoGeneration.LEVEL_GO_TEMPLATE
local sanitize_collision_group_text = GoGeneration.sanitize_collision_group_text
local gen_level_go = GoGeneration.gen_level_go
local gen_level_tilecol_go = GoGeneration.gen_level_tilecol_go
local gen_backgrounds_go = GoGeneration.gen_backgrounds_go
local gen_pushable_block_go = GoGeneration.gen_pushable_block_go
local gen_hazard_zone_go = GoGeneration.gen_hazard_zone_go
local gen_ladder_go = GoGeneration.gen_ladder_go
local resolve_half_extents = GoGeneration.resolve_half_extents
local sprite_scale_from_base = GoGeneration.sprite_scale_from_base
local gen_sized_rect_instance_go = GoGeneration.gen_sized_rect_instance_go
local tiled_image_layer_to_defold_pos = GoGeneration.tiled_image_layer_to_defold_pos

-- =============================================================================
-- ROOM CLEANUP / RESET
-- =============================================================================

local function make_trash_root(label)
    local base = normalize(join(ROOT, "developer/.trash"))
    local safe_label = tostring(label or "cleanup"):gsub("[^%w_%-]+", "_")
    local stamp = os.date("%Y%m%d_%H%M%S")
    local candidate = normalize(join(base, stamp .. "_" .. safe_label))
    local suffix = 1
    while file_exists_any(candidate) do
        suffix = suffix + 1
        candidate = normalize(join(base, stamp .. "_" .. safe_label .. "_" .. tostring(suffix)))
    end
    ensure_dir(candidate)
    return candidate
end

local function new_project_reset_mover()
    return _project_reset.new({
        root = ROOT,
        dir_sep = DIR_SEP,
        normalize = normalize,
        join = join,
        dirname = path_dirname,
        to_os_path = to_os_path,
        is_path_safe = is_path_safe,
        path_exists = file_exists_any,
        ensure_dir = ensure_dir,
        list_dir = list_dir_filesystem,
        read_binary = read_binary_any,
        run_process = run_process,
        remove_empty_dir = _filesystem.remove_empty_directory_filesystem,
        windows_helper_path = normalize(join(ROOT, "tools/reset_project_move.ps1")),
        delete_directory = function(abs_path)
            if HEADLESS or not (editor_api and type(editor_api.delete_directory) == "function") then
                return false, "editor.delete_directory is unavailable"
            end
            local resource_path = to_project_resource_path(abs_path)
            if type(resource_path) ~= "string" or resource_path:sub(1, 1) ~= "/" then
                return false, "cannot convert reset path to a Defold resource path"
            end
            local ok, delete_result = pcall(editor_api.delete_directory, resource_path)
            if not ok then return false, delete_result end
            if delete_result == false then
                return false, "editor.delete_directory returned false"
            end
            return true
        end,
    })
end

local function collect_owned_biome_image_dirs_and_atlases(dirs, atlas_files)
    -- Import Assets owns only atlases named by a Tiled room's biome property.
    -- Do not sweep arbitrary *_images directories: creators may organize an
    -- unrelated hand-authored atlas that way.
    local maps_dir = normalize(ROOT .. TILED_MAPS_RESOURCE_DIR)
    local _, files = list_dir_filesystem(maps_dir, { force_process = true })
    local biome_ids = {}

    local function add_biome(value)
        if value == nil or tostring(value) == "" then return end
        biome_ids[sanitize_asset_name(value, "biome")] = true
    end

    for _, name in ipairs(files or {}) do
        local room_id = tostring(name):match("^(.*)%.lua$")
        if room_id then
            local ok, data = pcall(load_tiled_export, room_id)
            if ok and type(data) == "table" then
                add_biome(get_tiled_property(data.properties, "biome"))
            end
        elseif tostring(name):match("%.tmx$") then
            local text = read_text_any(normalize(join(maps_dir, name)))
            if text then
                for attr_text in text:gmatch("<property%s+([^>]-)/?>") do
                    local attrs = parse_xml_attributes(attr_text)
                    if attrs.name == "biome" then add_biome(attrs.value) end
                end
            end
        end
    end

    local atlas_dir = normalize(join(ROOT, "developer/assets/atlas"))
    local ordered = {}
    for biome_id in pairs(biome_ids) do ordered[#ordered + 1] = biome_id end
    table.sort(ordered)
    for _, biome_id in ipairs(ordered) do
        dirs[#dirs + 1] = {
            path = normalize(join(atlas_dir, biome_id .. "_images")),
        }
        local atlas_path = normalize(join(atlas_dir, biome_id .. ".atlas"))
        if file_exists_any(atlas_path) then atlas_files[#atlas_files + 1] = atlas_path end
    end
end

local function should_cleanup_room_collection(name)
    return not name:match("^_")
end

local function collect_reset_files(path, recursive, output)
    output = output or {}
    local dirs, files = list_dir_filesystem(path, { force_process = true })
    for _, name in ipairs(files or {}) do
        output[#output + 1] = {
            path = normalize(join(path, name)),
            name = name,
        }
    end
    if recursive then
        for _, name in ipairs(dirs or {}) do
            collect_reset_files(normalize(join(path, name)), true, output)
        end
    end
    return output
end

local function run_room_cleanup(mode)
    _filesystem.clear_ensure_dir_cache()
    local destructive = mode == "reset"
    if destructive then
        local safe, source_errors = require("mvtk.editor.tiled_source_safety").check(
            ROOT, list_dir_filesystem, read_binary_any,
            not HEADLESS and editor_api and editor_api.external_file_attributes or nil)
        if not safe then
            error("Reset stopped before moving any files. Keep Tiled originals outside the Defold project "
                .. "and export again. Reconnect an unavailable source drive before retrying.\n"
                .. table.concat(source_errors, "\n"), 0)
        end
    end
    local label = destructive and "reset_project" or "delete_my_rooms"
    local title = destructive and "Reset Project to Empty" or "Delete My Rooms"
    info("[DELETE_ROOMS] === " .. title .. " ===")

    local trash_root = make_trash_root(label)
    local dirs = {}
    if destructive then
        -- Only verified exported copies may reach this cleanup.
        dirs[#dirs + 1] = { path = normalize(ROOT .. TILED_MAPS_RESOURCE_DIR) }
    else
        dirs[#dirs + 1] = {
            path = normalize(ROOT .. TILED_MAPS_RESOURCE_DIR),
            match = function(name)
                return name:match("%.lua$") or name:match("%.tilemap$")
            end,
            recursive = true,
            remove_empty_dirs = true,
        }
    end
    dirs[#dirs + 1] = {
        path = normalize(join(ROOT, "developer/rooms/collections")),
        match = should_cleanup_room_collection,
        recursive = true,
        remove_empty_dirs = true,
    }
    dirs[#dirs + 1] = { path = normalize(ROOT .. GENERATED_ROOMS_RESOURCE_DIR) }
    dirs[#dirs + 1] = {
        path = normalize(join(ROOT, "developer/rooms/factories")),
        match = function(name)
            return name:match("_factory%.collectionfactory$") ~= nil
        end,
        recursive = true,
        remove_empty_dirs = true,
    }
    local atlas_files = {}

    if destructive then
        for _, relative_path in ipairs(_reset_baseline.DESTRUCTIVE_DIRECTORIES) do
            dirs[#dirs + 1] = { path = normalize(join(ROOT, relative_path)) }
        end
        dirs[#dirs + 1] = {
            path = normalize(join(ROOT, "developer/assets/tilesheets")),
            match = _reset_baseline.should_remove_tilesheet,
            recursive = true,
            remove_empty_dirs = true,
        }
        collect_owned_biome_image_dirs_and_atlases(dirs, atlas_files)
        -- Shared object-art atlases sit beside hand-authored framework atlases,
        -- not under atlas/generated. Include only verified generator output.
        for _, path in ipairs(require("mvtk.editor.shared_atlas").collect_generated(
            ROOT, list_dir_filesystem, read_text_any)) do
            atlas_files[#atlas_files + 1] = path
        end

        -- Game save files & runtime state. When the game runs from the editor
        -- these are written to the project root (mvtk_save_slot_*, mvtk_last_slot,
        -- mvtk_settings, plus .bak siblings). Reset clears them so
        -- there is no stale save/progress left over. Root-level only (non-recursive)
        -- so we never touch the mvtk/ source directory.
        dirs[#dirs + 1] = {
            path = ROOT,
            match = _reset_baseline.should_remove_root_runtime_file,
        }

        -- updated_map.* is the live-refresh staging output. layout_map.* is
        -- also generated, but is backed up separately and replaced by the
        -- canonical blank build dependency below.
        dirs[#dirs + 1] = {
            path = normalize(join(ROOT, "developer/assets/minimap")),
            match = _reset_baseline.should_remove_updated_minimap_file,
        }
    end

    local mover = new_project_reset_mover()

    local prefab_baselines = {}
    local player_baselines = {}
    local music_baselines = {}
    local secret_baselines = {}
    local music_sound_files = {}
    if destructive then
        for _, relative_path in ipairs(_reset_baseline.REQUIRED_FRAMEWORK_TILES) do
            local absolute_path = normalize(join(ROOT, relative_path))
            if not file_exists_any(absolute_path) then
                error("Reset Project cannot establish a buildable baseline because "
                    .. relative_path .. " is missing. Restore it from developer/.trash or reinstall the toolkit, then retry.", 0)
            end
        end

        -- Validate every build-critical input before the first destructive
        -- move. A missing prefab cannot be repaired by merely restoring its
        -- tilesource dependency.
        for _, relative_path in ipairs(_reset_baseline.PREFAB_TILEMAPS) do
            local absolute_path = normalize(join(ROOT, relative_path))
            local previous = read_text_any(absolute_path)
            if not previous then
                error("Reset Project cannot establish a buildable baseline because "
                    .. relative_path .. " is missing or unreadable. Restore it from developer/.trash or reinstall the toolkit, then retry.", 0)
            end
            local baseline = _reset_baseline.repoint_prefab_tilemap(previous)
            if not baseline:find(
                'tile_set: "/developer/assets/tilesheets/defold_sample.tilesource"',
                1, true)
            then
                error("Reset Project cannot repair the tilesource reference in "
                    .. relative_path .. ". Restore the framework prefab and retry.", 0)
            end
            prefab_baselines[#prefab_baselines + 1] = {
                path = relative_path,
                content = baseline,
            }
        end

        local music_error
        music_baselines, music_error = _reset_baseline.build_empty_music_files(function(relative_path)
            return read_text_any(normalize(join(ROOT, relative_path)))
        end)
        if not music_baselines then
            error("Reset Project cannot establish empty music wiring: "
                .. tostring(music_error), 0)
        end

        player_baselines = _reset_baseline.build_player_files(function(relative_path)
            return read_text_any(normalize(join(ROOT, relative_path)))
        end)

        local secret_error
        secret_baselines, secret_error = _reset_baseline.build_secret_rooms_files(function(relative_path)
            return read_text_any(normalize(join(ROOT, relative_path)))
        end)
        if not secret_baselines then
            error("Reset Project cannot empty the secret room list: "
                .. tostring(secret_error) .. ". Fix the file's syntax and retry.", 0)
        end

        local audio_dir = normalize(join(ROOT, "developer/game/audio"))
        local _, audio_files = list_dir_filesystem(audio_dir, { force_process = true })
        for _, name in ipairs(audio_files or {}) do
            if tostring(name):match("%.sound$") then
                local sound_path = normalize(join(audio_dir, name))
                local sound_text = read_text_any(sound_path)
                if sound_text and sound_text:match('group:%s*"music"') then
                    music_sound_files[#music_sound_files + 1] = sound_path
                end
            end
        end
    end

    for _, spec in ipairs(dirs) do
        if spec.match then
            -- Selective cleanup preserves explicit framework-owned files and
            -- underscore-prefixed diagnostic collections.
            mover:move_files(spec.path, trash_root, {
                match = spec.match,
                recursive = spec.recursive,
                remove_empty_dirs = spec.remove_empty_dirs,
                force_process = destructive,
            })
        else
            -- Whole-directory cleanup: try an atomic rename, then a single
            -- bulk OS move. Recursive Lua I/O is the last-resort path only.
            mover:move_directory(spec.path, trash_root)
        end
    end

    for _, atlas_path in ipairs(atlas_files) do
        mover:move_file(atlas_path, trash_root)
    end

    if not destructive and #(mover:get_stats().failed or {}) == 0 then
        for _, relative_path in ipairs(_reset_baseline.SAFE_ROOM_DERIVED_FILES) do
            mover:move_file(normalize(join(ROOT, relative_path)), trash_root)
        end
    end

    -- Do not move or overwrite build-critical singleton files after an earlier
    -- cleanup failure. The failed reset remains recoverable and is reported as
    -- incomplete instead of silently replacing content that was never backed up.
    if destructive and #(mover:get_stats().failed or {}) == 0 then
        for _, relative_path in ipairs(_reset_baseline.ROOM_DERIVED_FILES) do
            mover:move_file(normalize(join(ROOT, relative_path)), trash_root)
        end
        for _, entry in ipairs(player_baselines) do
            mover:move_file(normalize(join(ROOT, entry.path)), trash_root)
        end
        for _, relative_path in ipairs(_reset_baseline.EXTRA_DERIVED_FILES) do
            mover:move_file(normalize(join(ROOT, relative_path)), trash_root)
        end
        for _, relative_path in ipairs(_reset_baseline.PREFAB_TILEMAPS) do
            mover:move_file(normalize(join(ROOT, relative_path)), trash_root)
        end
        for _, relative_path in ipairs(_reset_baseline.MUSIC_WIRING_FILES) do
            mover:move_file(normalize(join(ROOT, relative_path)), trash_root)
        end
        for _, sound_path in ipairs(music_sound_files) do
            mover:move_file(sound_path, trash_root)
        end
        for _, entry in ipairs(secret_baselines) do
            mover:move_file(normalize(join(ROOT, entry.path)), trash_root)
        end
    end

    local baseline_writes = 0
    if not destructive and #(mover:get_stats().failed or {}) == 0 then
        local baseline_ok, baseline_error = pcall(function()
            _filesystem.begin_resource_write_batch()
            for _, entry in ipairs(_reset_baseline.SAFE_TEXT_FILES) do
                if write_if_changed(normalize(join(ROOT, entry.path)), entry.content) then
                    baseline_writes = baseline_writes + 1
                end
            end
            _filesystem.end_resource_write_batch()
        end)
        if not baseline_ok then
            _filesystem.cancel_resource_write_batch()
            error("Delete My Rooms cleanup ran, but its empty room indexes could not be written: "
                .. tostring(baseline_error), 0)
        end
    end
    if destructive and #(mover:get_stats().failed or {}) == 0 then
        local baseline_ok, baseline_error = pcall(function()
            _filesystem.begin_resource_write_batch()
            for _, entry in ipairs(_reset_baseline.TEXT_FILES) do
                if write_if_changed(normalize(join(ROOT, entry.path)), entry.content) then
                    baseline_writes = baseline_writes + 1
                end
            end
            for _, entry in ipairs(prefab_baselines) do
                if write_if_changed(normalize(join(ROOT, entry.path)), entry.content) then
                    baseline_writes = baseline_writes + 1
                end
            end
            for _, entry in ipairs(player_baselines) do
                if write_if_changed(normalize(join(ROOT, entry.path)), entry.content) then
                    baseline_writes = baseline_writes + 1
                end
            end
            for _, entry in ipairs(music_baselines) do
                if write_if_changed(normalize(join(ROOT, entry.path)), entry.content) then
                    baseline_writes = baseline_writes + 1
                end
            end
            for _, entry in ipairs(secret_baselines) do
                if write_if_changed(normalize(join(ROOT, entry.path)), entry.content) then
                    baseline_writes = baseline_writes + 1
                end
            end

            -- Rebuild the atlas index from what actually survived the reset so
            -- no entry can keep pointing at a removed biome atlas.
            local AtlasManifest = require "hooks.core.atlas_manifest"
            local manifest_ok, manifest_result = AtlasManifest.sync_core({
                root = ROOT,
                join = join,
                to_os_path = to_os_path,
                list_dir_filesystem = function(path)
                    return list_dir_filesystem(path, { force_process = true })
                end,
                read_text = read_text,
                write_if_changed = write_if_changed,
            })
            if not manifest_ok then
                error("Could not rebuild the empty-project atlas manifest: "
                    .. tostring(manifest_result), 0)
            end
            if type(manifest_result) == "table"
                and #(manifest_result.changed_files or {}) > 0
            then
                baseline_writes = baseline_writes + 1
            end
            _filesystem.end_resource_write_batch()

            for _, entry in ipairs(_reset_baseline.BINARY_FILES) do
                if write_binary_if_changed(normalize(join(ROOT, entry.path)), entry.content) then
                    baseline_writes = baseline_writes + 1
                end
            end

        end)
        if not baseline_ok then
            _filesystem.cancel_resource_write_batch()
            error("Reset cleanup ran, but the build-safe empty baseline could not be written: "
                .. tostring(baseline_error), 0)
        end
    end

    if #(mover:get_stats().failed or {}) == 0 then
        local expected_content = {}
        local function add_expected(entries)
            for _, entry in ipairs(entries or {}) do
                expected_content[normalize(join(ROOT, entry.path))] = entry.content
            end
        end
        local legacy_manifest = normalize(join(ROOT, "developer/config/rooms_manifest.lua"))
        if file_exists_any(legacy_manifest) then
            mover:record_failure(legacy_manifest, "legacy room manifest survived reset")
        end

        if destructive then
            add_expected(_reset_baseline.TEXT_FILES)
            add_expected(_reset_baseline.BINARY_FILES)
            add_expected(prefab_baselines)
            add_expected(music_baselines)
            add_expected(secret_baselines)
        else
            add_expected(_reset_baseline.SAFE_TEXT_FILES)
        end

        -- Verify the real filesystem, not Defold's potentially stale resource
        -- graph. A reset cannot report success while any selected source file,
        -- generated room, export artifact, or stale baseline payload remains.
        for _, spec in ipairs(dirs) do
            local recursive = spec.recursive == true or spec.match == nil
            for _, file in ipairs(collect_reset_files(spec.path, recursive)) do
                local should_be_gone = spec.match and spec.match(file.name)
                    or (spec.match == nil and expected_content[file.path] == nil)
                if should_be_gone then
                    mover:record_failure(file.path, "reset postcondition left targeted data behind")
                    break
                end
            end
        end

        local targeted_atlases = {}
        for _, path in ipairs(atlas_files) do targeted_atlases[path] = true end
        for _, file in ipairs(collect_reset_files(normalize(join(ROOT, "developer/assets/atlas")), false)) do
            if targeted_atlases[file.path] then
                mover:record_failure(file.path, "generated atlas survived reset")
            end
        end

        for path, content in pairs(expected_content) do
            local actual = read_binary_any(path)
            if actual ~= content then
                mover:record_failure(path, actual == nil
                    and "reset baseline file is missing"
                    or "reset baseline content does not match the canonical empty state")
            end
        end

        if destructive then
            for _, sound_path in ipairs(music_sound_files) do
                if file_exists_any(sound_path) then
                    mover:record_failure(sound_path, "generated music sound definition survived reset")
                end
            end
            local atlas_manifest = normalize(join(ROOT, "developer/config/atlas_animations_generated.lua"))
            if not file_exists_any(atlas_manifest) then
                mover:record_failure(atlas_manifest, "empty atlas manifest was not rebuilt")
            end
            for _, required_path in ipairs(_reset_baseline.REQUIRED_FRAMEWORK_TILES) do
                local absolute_path = normalize(join(ROOT, required_path))
                if not file_exists_any(absolute_path) then
                    mover:record_failure(absolute_path, "required framework tilesheet did not survive reset")
                end
            end
        end
    end

    if destructive and #(mover:get_stats().failed or {}) == 0 then
        -- Runtime sys.get_save_file() state lives outside the editor VM. Write
        -- the marker only after every cleanup and baseline postcondition passes;
        -- the bootstrap consumes it before settings, saves, or Layout Editor.
        local marker_path = normalize(join(ROOT, "mvtk_reset_pending"))
        local marker_ok, marker_changed_or_error = pcall(
            write_if_changed,
            marker_path,
            "reset_at=" .. tostring(os.time()) .. "\n"
        )
        if not marker_ok or not file_exists_any(marker_path) then
            mover:record_failure(marker_path,
                "could not schedule external saved-state cleanup: "
                .. tostring(marker_changed_or_error))
        elseif marker_changed_or_error then
            baseline_writes = baseline_writes + 1
        end
    end

    -- External moves suppress intermediate resource reloads. Request exactly
    -- one reload now that the filesystem transaction is complete.
    local summary = mover:finish()
    summary.baseline_writes = baseline_writes
    _filesystem.clear_ensure_dir_cache()
    for _, stage in ipairs(summary.stages or {}) do
        local moved = stage.moved_directories == 1
            and "1 directory tree"
            or (tostring(stage.moved_files or 0) .. " file(s)")
        info(string.format(
            "[DELETE_ROOMS] %s: moved %s via %s in %.1fs",
            tostring(stage.path),
            moved,
            tostring(stage.strategy),
            tonumber(stage.elapsed_seconds) or 0
        ))
        if stage.strategy == "bulk" and stage.rename_error then
            info("[DELETE_ROOMS] Atomic rename unavailable for " .. tostring(stage.path)
                .. "; bulk move succeeded (rename error: " .. tostring(stage.rename_error) .. ")")
        end
        if stage.strategy == "editor delete" then
            info("[DELETE_ROOMS] Verified a trash backup, then used Defold's resource deletion API for "
                .. tostring(stage.path))
        end
        if stage.copy_warning then
            info("[DELETE_ROOMS] Bulk move verified after robocopy warning for "
                .. tostring(stage.path) .. " (" .. tostring(stage.copy_warning) .. ")")
        end
        if stage.strategy == "per-file fallback" or stage.strategy == "bulk failed" then
            info(string.format(
                "[DELETE_ROOMS] WARNING bulk move unavailable for %s (rename: %s; bulk: %s)",
                tostring(stage.path),
                tostring(stage.rename_error),
                tostring(stage.bulk_error)
            ))
        end
    end

    local failure_limit = math.min(#(summary.failed or {}), 20)
    for index = 1, failure_limit do
        local failure = summary.failed[index]
        info("[DELETE_ROOMS] Failed to move: " .. tostring(failure.path)
            .. " (" .. tostring(failure.reason) .. ")")
    end
    if #(summary.failed or {}) > failure_limit then
        info("[DELETE_ROOMS] " .. tostring(#summary.failed - failure_limit)
            .. " additional failure(s) omitted; see the first failures above.")
    end
    if summary.refresh_requested and not summary.refresh_ok then
        info("[DELETE_ROOMS] WARNING final Defold resource refresh request failed; "
            .. "the files were moved, but the editor may need a manual reload.")
    end

    local total = (summary.moved_files or 0) + (summary.moved_directories or 0)
    info(string.format(
        "[DELETE_ROOMS] Complete in %.1fs: %d file(s), %d directory tree(s), %d baseline file(s), %d failure(s); resource refresh=%s",
        tonumber(summary.elapsed_seconds) or 0,
        tonumber(summary.moved_files) or 0,
        tonumber(summary.moved_directories) or 0,
        tonumber(summary.baseline_writes) or 0,
        #(summary.failed or {}),
        summary.refresh_requested and tostring(summary.refresh_ok) or "not needed"
    ))
    info("[DELETE_ROOMS] Trash backup: " .. tostring(trash_root))
    return total, trash_root, summary
end

local function delete_my_room_files()
    return run_room_cleanup("safe")
end

local function reset_project_to_empty()
    return run_room_cleanup("reset")
end

local function delete_all_room_files()
    return reset_project_to_empty()
end


-- Wire up the runtime collaborators that mvtk.editor.tilemap_regen and
-- mvtk.editor.tilesheet_sync need before they can do real work. Both modules
-- assert collaborator presence on first use and fail loudly otherwise (we
-- already shipped a regression to that effect when configure() was missing).
-- This block lives here so every collaborator (writers, shell runner,
-- tilesource helpers) is fully bound by the time it runs.
_tilemap_regen.configure({
    logger = function(msg) info(msg) end,
    profiler = profiler,
    write_text = write_if_changed,
    write_binary = write_binary_if_changed,
    run_process = run_process,
    run_shell = run_shell_command_with_exit_code,
    resolve_tilesource = resolve_tilesource,
    get_tiled_property = get_tiled_property,
})
_tilesheet_sync.configure({
    logger = function(msg) info(msg) end,
    profiler = profiler,
    copy_file = copy_file_any,
    resolve_tilesource = resolve_tilesource,
    get_tileset_meta = get_tileset_meta,
    ensure_tilesource_from_tiled = ensure_tilesource_from_tiled,
})

-- Export all core symbols for the split editor hook chunks.
local MVTK = _context.set({
    -- Core variables
    normalize = normalize,
    editor_api = editor_api,
    HEADLESS = HEADLESS,
    info = info,
    profiler = profiler,
    ROOT = ROOT,
    DIR_SEP = DIR_SEP,
    to_os_path = to_os_path,
    PATH = PATH,
    TILED_MAPS_RESOURCE_DIR = TILED_MAPS_RESOURCE_DIR,
    GENERATED_ROOMS_RESOURCE_DIR = GENERATED_ROOMS_RESOURCE_DIR,
    TilesetMapping = TilesetMapping,
    TileSnap = TileSnap,
    CollisionBox = CollisionBox,
    lfs_ok = lfs_ok,
    lfs = lfs,
    TILED_CONFIG = TILED_CONFIG,
    get_tiled_paths = get_tiled_paths,
    LOG_FILE = LOG_FILE,
    log_handle = log_handle,
    PNG_DIMENSION_CACHE = PNG_DIMENSION_CACHE,
    TSX_META_CACHE = TSX_META_CACHE,
    RESOURCE_TOP_LEVEL_DIRS = RESOURCE_TOP_LEVEL_DIRS,
    LEVEL_GO_TEMPLATE = LEVEL_GO_TEMPLATE,
    REQUIRED_OBJECT_FIELDS = REQUIRED_OBJECT_FIELDS,

    -- Forward-declared variables (assigned by runtime)
    copy_file_basic = copy_file_basic,
    copy_directory_filesystem = copy_directory_filesystem,
    ensure_dir = ensure_dir,
    list_dir_filesystem = list_dir_filesystem,

    -- Functions
    open_log = open_log,
    close_log = close_log,
    join = join,
    is_path_safe = is_path_safe,
    to_project_fs_path = to_project_fs_path,
    to_project_resource_path = to_project_resource_path,
    read_text = read_text,
    file_exists = file_exists,
    resolve_tilesource_collision_resource = resolve_tilesource_collision_resource,
    resolve_image_path = resolve_image_path,
    get_png_dimensions = get_png_dimensions,
    fmt_num = fmt_num,
    load_tiled_export = load_tiled_export,
    ensure_main_collection = ensure_main_collection,
    ensure_native_extension_app_manifest = ensure_native_extension_app_manifest,
    prepare_export_game_project = prepare_export_game_project,
    is_absolute_path = is_absolute_path,
    write_if_changed = write_if_changed,
    write_binary_if_changed = write_binary_if_changed,
    clear_ensure_dir_cache = _filesystem.clear_ensure_dir_cache,
    begin_resource_write_batch = _filesystem.begin_resource_write_batch,
    flush_resource_write_batch = _filesystem.flush_resource_write_batch,
    end_resource_write_batch = _filesystem.end_resource_write_batch,
    cancel_resource_write_batch = _filesystem.cancel_resource_write_batch,
    is_array = is_array,
    serialize_value = serialize_value,
    write_layout_module = write_layout_module,
    run_process = run_process,
    list_room_ids = list_room_ids,
    file_exists_any = file_exists_any,
    read_text_any = read_text_any,
    collect_missing_generated_rooms = collect_missing_generated_rooms,
    read_binary_any = read_binary_any,
    path_dirname = path_dirname,
    path_basename = path_basename,
    copy_file_any = copy_file_any,
    source_is_newer = _tilesheet_sync.source_is_newer,
    sanitize_asset_name = sanitize_asset_name,
    get_tiled_property = get_tiled_property,
    parse_xml_attributes = parse_xml_attributes,
    resolve_source_file = resolve_source_file,
    parse_tsx_tileset = parse_tsx_tileset,
    get_tileset_meta = get_tileset_meta,
    collect_collection_source_dirs = collect_collection_source_dirs,
    maybe_infer_missing_collection_tile_image = maybe_infer_missing_collection_tile_image,
    make_tilesource_text = make_tilesource_text,
    tilesource_matches_grid = tilesource_matches_grid,
    count_non_four_point_hulls = count_non_four_point_hulls,
    ensure_tilesource_from_tiled = ensure_tilesource_from_tiled,
    resolve_tilesource = resolve_tilesource,
    update_tilemap_tilesource = update_tilemap_tilesource,
    update_all_tilemap_tilesources = update_all_tilemap_tilesources,
    relink_prefab_tilemaps = relink_prefab_tilemaps,
    load_object_type_set = load_object_type_set,
    unwrap_tiled_prop_value = unwrap_tiled_prop_value,
    to_optional_bool = to_optional_bool,
    get_prop_value = get_prop_value,
    has_prop = has_prop,
    normalize_object_type = normalize_object_type,
    is_background_layer_name = is_background_layer_name,
    is_background_visual_object_candidate = is_background_visual_object_candidate,
    infer_object_type = infer_object_type,
    resolve_object_type = resolve_object_type,
    validate_object_fields = validate_object_fields,
    preflight_tiled_map = preflight_tiled_map,
    preflight_tiled_maps = preflight_tiled_maps,
    append_resource_path = append_resource_path,
    tilemap_id_from_resource = tilemap_id_from_resource,
    get_selected_tilemap_ids = get_selected_tilemap_ids,
    sanitize_collision_group_text = sanitize_collision_group_text,
    STANDARD_TILE_COLLISION_GROUP = STANDARD_TILE_COLLISION_GROUP,
    STANDARD_TILE_COLLISION_FIRST = STANDARD_TILE_COLLISION_FIRST,
    STANDARD_TILE_COLLISION_LAST = STANDARD_TILE_COLLISION_LAST,
    gen_level_go = gen_level_go,
    gen_level_tilecol_go = gen_level_tilecol_go,
    gen_backgrounds_go = gen_backgrounds_go,
    gen_pushable_block_go = gen_pushable_block_go,
    gen_hazard_zone_go = gen_hazard_zone_go,
    gen_ladder_go = gen_ladder_go,
    resolve_half_extents = resolve_half_extents,
    sprite_scale_from_base = sprite_scale_from_base,
    gen_sized_rect_instance_go = gen_sized_rect_instance_go,
    tiled_image_layer_to_defold_pos = tiled_image_layer_to_defold_pos,
    run_validate_all = run_validate_all,
    run_config_validation = run_config_validation,
    sync_tilesheet_images = sync_tilesheet_images,
    regenerate_tilemap_from_lua = regenerate_tilemap_from_lua,
    regenerate_all_tilemaps_from_lua = regenerate_all_tilemaps_from_lua,
    should_cleanup_room_collection = should_cleanup_room_collection,
    delete_my_room_files = delete_my_room_files,
    reset_project_to_empty = reset_project_to_empty,
    delete_all_room_files = delete_all_room_files,
    remove_path_filesystem = remove_path_filesystem,
})

return MVTK

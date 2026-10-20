-- Import core symbols from editor_core.lua (loaded by hooks.editor_script wrapper)
--
-- This file is the editor-host entry. editor_core.lua publishes shared
-- helpers via hooks/core/context.lua; we rebind the hot ones as locals so
-- the inner loops don't go through table lookups. See hooks/core/context.lua
-- for the canonical context shape (categories: editor_api/HEADLESS, ROOT/
-- PATH, TILED_CONFIG, info/profiler, filesystem helpers, Tiled IO helpers,
-- generator entry points, etc.).
local Context = require "hooks.core.context"
local _C = Context.require_context("hooks/editor_script.lua")
local RenderOrder = require "mvtk.core.render_order"
local ParallaxRepeat = require "mvtk.tiled.parallax_repeat"
local VisualOwnership = require "mvtk.tiled.visual_ownership"
local VisualPrefab = require "mvtk.editor.visual_prefab"
local _proto_utils = require "mvtk.editor.proto_utils"
local ImageCrop = require "mvtk.editor.image_crop"
local proto_escape = _proto_utils.proto_escape
local bool_to_proto = _proto_utils.bool_to_proto
local split_lines = _proto_utils.split_lines_with_crlf

-- High-frequency symbols imported as locals for performance
local normalize = _C.normalize
local editor_api = _C.editor_api
local HEADLESS = _C.HEADLESS
local info = _C.info
local ROOT = _C.ROOT
local DIR_SEP = _C.DIR_SEP
local to_os_path = _C.to_os_path
local PATH = _C.PATH
local TileSnap = _C.TileSnap
local CollisionBox = _C.CollisionBox
local lfs_ok = _C.lfs_ok
local lfs = _C.lfs
local TILED_CONFIG = _C.TILED_CONFIG
local join = _C.join
local ensure_dir = _C.ensure_dir
local copy_file_basic = _C.copy_file_basic
local copy_directory_filesystem = _C.copy_directory_filesystem
local list_dir_filesystem = _C.list_dir_filesystem
local read_text = _C.read_text
local file_exists = _C.file_exists
local file_exists_any = _C.file_exists_any
local read_binary_any = _C.read_binary_any
local write_if_changed = _C.write_if_changed
local resolve_tilesource_collision_resource = _C.resolve_tilesource_collision_resource
local fmt_num = _C.fmt_num
local get_prop_value = _C.get_prop_value
local get_tiled_property = _C.get_tiled_property
local load_tiled_export = _C.load_tiled_export
local list_room_ids = _C.list_room_ids
local path_dirname = _C.path_dirname
local path_basename = _C.path_basename
local to_project_resource_path = _C.to_project_resource_path
local sanitize_asset_name = _C.sanitize_asset_name
local resolve_source_file = _C.resolve_source_file
local resolve_half_extents = _C.resolve_half_extents
local sprite_scale_from_base = _C.sprite_scale_from_base
local tiled_image_layer_to_defold_pos = _C.tiled_image_layer_to_defold_pos
local resolve_object_type = _C.resolve_object_type
local is_background_visual_object_candidate = _C.is_background_visual_object_candidate
local update_all_tilemap_tilesources = _C.update_all_tilemap_tilesources
local get_selected_tilemap_ids = _C.get_selected_tilemap_ids
local prepare_export_game_project = _C.prepare_export_game_project
local gen_level_go = _C.gen_level_go
local gen_backgrounds_go = _C.gen_backgrounds_go
local gen_pushable_block_go = _C.gen_pushable_block_go
local gen_hazard_zone_go = _C.gen_hazard_zone_go
local gen_ladder_go = _C.gen_ladder_go
local sanitize_collision_group = _C.sanitize_collision_group
local run_validate_all = _C.run_validate_all
local sync_tilesheet_images = _C.sync_tilesheet_images
local delete_all_room_files = _C.delete_all_room_files
local remove_path_filesystem = _C.remove_path_filesystem
local run_process = _C.run_process
local profiler = _C.profiler

local PARALLAX_BACKGROUND_MATERIAL = "/mvtk/tiled/materials/parallax_clip_background.material"
local PARALLAX_FOREGROUND_MATERIAL = "/mvtk/tiled/materials/parallax_clip_foreground.material"

-- Less frequently used symbols accessed via _C:
--   _C.to_project_fs_path, _C.resolve_image_path, _C.get_png_dimensions,
--   _C.collect_missing_generated_rooms, _C.copy_file_any,
--   _C.get_tileset_meta, _C.maybe_infer_missing_collection_tile_image,
--   _C.resolve_tilesource, _C.load_object_type_set,
--   _C.preflight_tiled_maps

local _visual = {}

_visual.uses_defold_sprite = function(object_or_properties, object_type)
    return VisualOwnership.uses_defold_sprite(object_or_properties, object_type)
end

-- Resolve a shared prefab to an object-specific, sprite-free generated copy
-- when Tiled art owns the visual. The source is read before the target is
-- written, so generated custom collectible prefabs are safe as inputs too.
_visual.resolve_visual_proto = function(rid, object, object_type, source_resource)
    if _visual.uses_defold_sprite(object, object_type) then
        return source_resource
    end

    local resource = _visual.normalize_defold_resource_path(source_resource, ".go")
    if not resource then
        info(string.format(
            "[CREATE ROOMS][WARNING] map '%s' object id=%s type='%s': invalid visual prefab '%s'; keeping shared prefab.",
            tostring(rid), tostring(object and object.id), tostring(object_type), tostring(source_resource)
        ))
        return source_resource
    end

    local source_path = join(ROOT, resource:sub(2))
    local source_text = read_text(source_path)
    if type(source_text) ~= "string" or source_text == "" then
        info(string.format(
            "[CREATE ROOMS][WARNING] map '%s' object id=%s type='%s': cannot read visual prefab '%s'; keeping shared prefab.",
            tostring(rid), tostring(object and object.id), tostring(object_type), tostring(resource)
        ))
        return source_resource
    end

    local generated_resource, stripped, count = VisualPrefab.resolve(
        rid, object, object_type, resource, source_text
    )
    if count == 0 then
        -- Behavior-only prototypes are the normal Tiled-art path.
        return source_resource
    end

    local filename = generated_resource:match("([^/]+)$")
    local target_path = join(PATH.generated_go, filename)
    if write_if_changed(target_path, stripped) then
        info("Created " .. target_path)
    end
    return generated_resource
end

_visual.trim_string = function(value)
    if value == nil then
        return nil
    end
    local s = tostring(value)
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    if s == "" then
        return nil
    end
    return s
end

_visual.normalize_defold_resource_path = function(value, extension)
    local s = _visual.trim_string(value)
    if not s then
        return nil
    end

    s = normalize(s)

    -- If an absolute OS path is provided, keep only the project-relative part.
    if s:match("^[A-Za-z]:") then
        local lower = s:lower()
        local marker = lower:find("/developer/", 1, true) or lower:find("/mvtk/", 1, true)
        if marker then
            s = s:sub(marker)
        else
            return nil
        end
    end

    if s:sub(1, 1) ~= "/" then
        s = "/" .. s
    end

    if extension and extension ~= "" then
        local ext = tostring(extension):lower()
        if ext:sub(1, 1) ~= "." then
            ext = "." .. ext
        end
        if s:sub(-#ext):lower() ~= ext then
            return nil
        end
    end

    return s
end

_visual.proto_inline_escape = function(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\n", "\\n")
    s = s:gsub('"', '\\"')
    return s
end

_visual.TILESOURCE_METADATA_CACHE = {}

_visual.sanitize_resource_token = function(value, fallback)
    local token = tostring(value or "")
    token = token:lower()
    token = token:gsub("[^%w_]+", "_")
    token = token:gsub("^_+", "")
    token = token:gsub("_+$", "")
    if token == "" then
        token = fallback or "token"
    end
    return token
end

local STANDARD_TILE_COLLISION_GROUP = _C.STANDARD_TILE_COLLISION_GROUP or "solid"
local STANDARD_TILE_COLLISION_FIRST = _C.STANDARD_TILE_COLLISION_FIRST or 2
local STANDARD_TILE_COLLISION_LAST = _C.STANDARD_TILE_COLLISION_LAST or 20

local function should_standardize_tilesource_resource(resource_path)
    local resource = _visual.normalize_defold_resource_path(resource_path, ".tilesource")
    if not resource then
        return false
    end
    if resource:find("/vfx/", 1, true) or resource:find("/fx/", 1, true) then
        return false
    end
    if resource:find("/tilesheets/", 1, true) then
        return true
    end
    if resource:find("/tiles/", 1, true) then
        return true
    end
    return false
end

local function collect_standard_tilesource_resources()
    local resources = {}
    local seen = {}

    local function add(resource_path)
        local resource = _visual.normalize_defold_resource_path(resource_path, ".tilesource")
        if not resource or not should_standardize_tilesource_resource(resource) or seen[resource] then
            return
        end
        seen[resource] = true
        resources[#resources + 1] = resource
    end

    local function scan_dir(abs_dir, resource_dir)
        local dirs, files = list_dir_filesystem(abs_dir)
        for _, file_name in ipairs(files or {}) do
            if file_name:match("%.tilesource$") then
                add(resource_dir .. "/" .. file_name)
            end
        end
        for _, dir_name in ipairs(dirs or {}) do
            scan_dir(join(abs_dir, dir_name), resource_dir .. "/" .. dir_name)
        end
    end

    -- Only scan directories that can contain standardizable tilesources
    -- (tilesheets, tiles) instead of all of developer/.
    local scan_roots = {
        { join(ROOT, "developer/assets/tilesheets"), "/developer/assets/tilesheets" },
        { join(ROOT, "developer/examples"),          "/developer/examples" },
    }
    for _, entry in ipairs(scan_roots) do
        local abs, res = entry[1], entry[2]
        -- list_dir_filesystem already falls back through the editor resource
        -- API, lfs, and a shell listing. An io.open-style file_exists check on
        -- a directory is false in Defold's no-lfs editor sandbox and used to
        -- skip every tilesource even though the directory was listable.
        scan_dir(abs, res)
    end
    info("collect_standard_tilesource_resources: found " .. #resources .. " tilesource(s)")
    table.sort(resources)
    return resources
end

local function make_standard_tile_collision_assignments()
    -- Collision is now authored through Tiled Tile Collision Editor shapes and
    -- Solid Box/Slope objects. Keep legacy per-index tile assignments empty so
    -- tiles 2..20 are not implicitly treated as full solid boxes.
    return {}
end

local function read_tilesource_collision_group_ids(tilesource_resource)
    local ids = {}
    local ok_can_get, can_get = pcall(function()
        return editor_api and editor_api.can_get and editor_api.can_get(tilesource_resource, "collision_groups")
    end)
    if not ok_can_get or not can_get then
        return ids
    end

    local ok_nodes, nodes = pcall(editor_api.get, tilesource_resource, "collision_groups")
    if not ok_nodes or type(nodes) ~= "table" then
        return ids
    end

    for _, node in ipairs(nodes) do
        local ok_id, id = pcall(editor_api.get, node, "id")
        if ok_id and type(id) == "string" and id ~= "" then
            ids[#ids + 1] = id
        end
    end

    table.sort(ids)
    return ids
end

local function tile_collision_assignments_match(actual, expected)
    if type(actual) ~= "table" then
        return false
    end

    for tile_id = STANDARD_TILE_COLLISION_FIRST, STANDARD_TILE_COLLISION_LAST do
        if actual[tile_id] ~= expected[tile_id] then
            return false
        end
    end

    for key, value in pairs(actual) do
        local tile_id = tonumber(key)
        if tile_id ~= nil then
            tile_id = math.floor(tile_id)
        end
        if tile_id ~= nil and (tile_id < STANDARD_TILE_COLLISION_FIRST or tile_id > STANDARD_TILE_COLLISION_LAST) then
            if value ~= nil and value ~= "" then
                return false
            end
        end
    end

    return true
end

local function standardize_tilesource_collision_setup()
    if HEADLESS then
        info("tilesource collision standardization skipped: editor API unavailable")
        return false
    end
    if not (editor_api and editor_api.transact and editor_api.tx and editor_api.tx.add and editor_api.tx.set and editor_api.tx.clear) then
        info("tilesource collision standardization skipped: transaction API unavailable")
        return false
    end

    profiler.start("  collision: collect_resources")
    local targets = collect_standard_tilesource_resources()
    profiler.stop("  collision: collect_resources")
    if #targets == 0 then
        info("tilesource collision standardization: no tilesources found")
        return false
    end

    profiler.start("  collision: build_transactions")
    local desired_assignments = make_standard_tile_collision_assignments()
    local txs = {}
    local changed = {}

    for _, resource in ipairs(targets) do
        local resource_changed = false

        local current_group_ids = read_tilesource_collision_group_ids(resource)
        local groups_match = (#current_group_ids == 1 and current_group_ids[1] == STANDARD_TILE_COLLISION_GROUP)
        if not groups_match then
            txs[#txs + 1] = editor_api.tx.clear(resource, "collision_groups")
            txs[#txs + 1] = editor_api.tx.add(resource, "collision_groups", { id = STANDARD_TILE_COLLISION_GROUP })
            resource_changed = true
        end

        local image_resource = nil
        local ok_can_get_image, can_get_image = pcall(function()
            return editor_api.can_get and editor_api.can_get(resource, "image")
        end)
        if ok_can_get_image and can_get_image then
            local ok_image, image_value = pcall(editor_api.get, resource, "image")
            if ok_image and type(image_value) == "string" and image_value ~= "" then
                image_resource = image_value
            end
        end

        if image_resource then
            local desired_collision_resource = resolve_tilesource_collision_resource(image_resource)
            local current_collision = nil
            local ok_can_get_collision, can_get_collision = pcall(function()
                return editor_api.can_get and editor_api.can_get(resource, "collision")
            end)
            if ok_can_get_collision and can_get_collision then
                local ok_collision, collision_value = pcall(editor_api.get, resource, "collision")
                if ok_collision and type(collision_value) == "string" then
                    current_collision = collision_value
                end
            end

            local ok_can_set_collision, can_set_collision = pcall(function()
                return editor_api.can_set and editor_api.can_set(resource, "collision")
            end)
            if ok_can_set_collision and can_set_collision and current_collision ~= desired_collision_resource then
                txs[#txs + 1] = editor_api.tx.set(resource, "collision", desired_collision_resource)
                resource_changed = true
            end
        end

        local current_assignments = nil
        local ok_can_get_assignments, can_get_assignments = pcall(function()
            return editor_api.can_get and editor_api.can_get(resource, "tile_collision_groups")
        end)
        if ok_can_get_assignments and can_get_assignments then
            local ok_assignments, assignment_value = pcall(editor_api.get, resource, "tile_collision_groups")
            if ok_assignments then
                current_assignments = assignment_value
            end
        end

        local ok_can_set_assignments, can_set_assignments = pcall(function()
            return editor_api.can_set and editor_api.can_set(resource, "tile_collision_groups")
        end)
        if ok_can_set_assignments and can_set_assignments and not tile_collision_assignments_match(current_assignments, desired_assignments) then
            txs[#txs + 1] = editor_api.tx.set(resource, "tile_collision_groups", desired_assignments)
            resource_changed = true
        end

        if resource_changed then
            changed[#changed + 1] = resource
        end
    end
    profiler.stop("  collision: build_transactions")

    if #txs == 0 then
        info("tilesource collision standardization: already up-to-date for " .. tostring(#targets) .. " tilesource(s)")
        return false
    end

    profiler.start("  collision: editor_api.transact")
    local ok_transact, transact_err = pcall(editor_api.transact, txs)
    profiler.stop("  collision: editor_api.transact")
    if not ok_transact then
        info("tilesource collision standardization failed: " .. tostring(transact_err))
        return false
    end

    info("tilesource collision standardization updated " .. tostring(#changed) .. " tilesource(s)")
    if editor_api.save then
        profiler.start("  collision: editor_api.save")
        local ok_save, save_err = pcall(editor_api.save)
        profiler.stop("  collision: editor_api.save")
        if not ok_save then
            info("tilesource collision standardization save failed: " .. tostring(save_err))
        end
    end
    return true
end

_visual.resolve_room_tilesource_resource = function(rid)
    local failures = {}
    local function existing_tilesource(resource, source)
        resource = _visual.normalize_defold_resource_path(resource, ".tilesource")
        if not resource then
            failures[#failures + 1] = tostring(source) .. " did not provide a valid .tilesource path"
            return nil
        end
        local relative = resource:gsub("^/", "")
        local absolute = normalize(join(ROOT, relative))
        if not file_exists_any(absolute) then
            failures[#failures + 1] = string.format("%s references missing resource %s", tostring(source), resource)
            return nil
        end
        return resource
    end

    local tilemap_path = join(PATH.tilemaps, tostring(rid or "") .. ".tilemap")
    local tilemap_content = read_text(tilemap_path)
    if tilemap_content then
        local from_tilemap = existing_tilesource(
            tilemap_content:match('tile_set:%s*"([^"]+)"'),
            "room tilemap"
        )
        if from_tilemap then
            return from_tilemap, nil
        end
    else
        failures[#failures + 1] = "room tilemap is missing: " .. tostring(tilemap_path)
    end

    local tileset_name = nil
    local tiled_data, export_or_err = load_tiled_export(rid)
    if tiled_data then
        local TilesetSelection = require "mvtk.editor.tileset_selection"
        local primary = TilesetSelection.select_primary_tileset(tiled_data, get_tiled_property)
        if primary and primary.name and tostring(primary.name) ~= "" then
            tileset_name = tostring(primary.name)
        end
    elseif export_or_err then
        info(string.format("scenery tilesource: room=%s tileset lookup failed (%s)", tostring(rid), tostring(export_or_err)))
    end

    if tileset_name then
        local mapped, map_err = _C.resolve_tilesource(tileset_name)
        local resolved = existing_tilesource(mapped, "tileset mapping for '" .. tostring(tileset_name) .. "'")
        if resolved then
            return resolved, nil
        end
        if map_err then
            failures[#failures + 1] = "tileset resolution failed: " .. tostring(map_err)
        end
    else
        failures[#failures + 1] = "Tiled export has no resolvable primary tileset"
    end

    return nil, table.concat(failures, "; ")
end

_visual.load_tilesource_metadata = function(tilesource_resource)
    local resource = _visual.normalize_defold_resource_path(tilesource_resource, ".tilesource")
    if not resource then
        return nil, "invalid_tilesource"
    end

    local cached = _visual.TILESOURCE_METADATA_CACHE[resource]
    if cached then
        return cached
    end

    local resource_rel = resource:gsub("^/", "")
    local abs_path = normalize(join(ROOT, resource_rel))
    local content = nil
    do
        local fh = io.open(abs_path, "rb")
        if not fh then
            fh = io.open(to_os_path(abs_path), "rb")
        end
        if fh then
            content = fh:read("*a")
            fh:close()
        end
    end
    if not content then
        return nil, "tilesource_missing"
    end

    local image_resource = content:match('image:%s*"([^"]+)"')
    if not image_resource then
        return nil, "tilesource_missing_image"
    end
    image_resource = normalize(image_resource)
    if image_resource:sub(1, 1) ~= "/" then
        image_resource = "/" .. image_resource
    end

    local tile_w = math.floor(tonumber(content:match("tile_width:%s*(%d+)")) or 0)
    local tile_h = math.floor(tonumber(content:match("tile_height:%s*(%d+)")) or 0)
    if tile_w <= 0 then
        return nil, "tilesource_invalid_tile_width"
    end
    if tile_h <= 0 then
        tile_h = tile_w
    end

    local image_w, image_h = _C.get_png_dimensions(image_resource)
    if not image_w or not image_h then
        return nil, "tilesource_image_missing"
    end

    local columns = math.floor(image_w / tile_w)
    local rows = math.floor(image_h / tile_h)
    if columns <= 0 or rows <= 0 then
        return nil, "tilesource_invalid_grid"
    end

    local image_rel = image_resource:gsub("^/", "")

    local meta = {
        resource = resource,
        abs_path = abs_path,
        image_resource = image_resource,
        image_abs = normalize(join(ROOT, image_rel)),
        tile_width = tile_w,
        tile_height = tile_h,
        image_width = image_w,
        image_height = image_h,
        columns = columns,
        rows = rows,
        token = _visual.sanitize_resource_token(resource:match("([^/]+)%.tilesource$"), "tiles"),
    }
    _visual.TILESOURCE_METADATA_CACHE[resource] = meta
    return meta
end

_visual.resolve_tilesource_rect = function(meta, tile_id)
    local id = math.floor(tonumber(tile_id) or 0)
    if id < 0 then
        return nil, "tile_id_invalid"
    end
    -- Interpret authored IDs exactly as shown in Tiled's Tile panel (zero-based).
    local index = id
    local tx = index % meta.columns
    local ty = math.floor(index / meta.columns)
    local px = tx * meta.tile_width
    local py = ty * meta.tile_height
    if px + meta.tile_width > meta.image_width or py + meta.tile_height > meta.image_height then
        return nil, "tile_id_out_of_range"
    end
    return px, py, meta.tile_width, meta.tile_height
end

_visual.platform_family = function()
    local platform = editor_api and editor_api.platform
    if type(platform) == "function" then
        local ok, value = pcall(platform)
        platform = ok and value or nil
    end
    platform = tostring(platform or ""):lower()
    if platform:find("mac", 1, true) or platform:find("darwin", 1, true) then
        return "macos"
    elseif platform:find("linux", 1, true) then
        return "linux"
    elseif platform:find("win", 1, true) or DIR_SEP == "\\" then
        return "windows"
    end
    return "linux"
end

_visual.CROP_TOOL = nil

_visual.resolve_crop_tool = function()
    if _visual.CROP_TOOL ~= nil then
        return _visual.CROP_TOOL.tool, _visual.CROP_TOOL.error
    end
    if type(run_process) ~= "function" then
        _visual.CROP_TOOL = { error = "external_process_unavailable" }
        return nil, _visual.CROP_TOOL.error
    end

    local platform = _visual.platform_family()
    local candidates
    if platform == "windows" then
        candidates = {
            { command = "powershell", probe = { "-NoProfile", "-Command", "$PSVersionTable.PSVersion.Major" } },
        }
    elseif platform == "macos" then
        candidates = {
            { command = "sips", probe = { "--version" } },
        }
    else
        candidates = {
            { command = "magick", probe = { "-version" } },
            { command = "convert", probe = { "-version" } },
        }
    end

    for _, candidate in ipairs(candidates) do
        local ok = run_process(candidate.command, candidate.probe, {
            capture = true,
            reload_resources = false,
        })
        if ok then
            _visual.CROP_TOOL = { tool = candidate.command }
            return candidate.command
        end
    end

    local remedy
    if platform == "linux" then
        remedy = "ImageMagick not found. Install it (Ubuntu: sudo apt install imagemagick)."
    elseif platform == "macos" then
        remedy = "macOS sips was not found; report this as a toolkit bug."
    else
        remedy = "Windows PowerShell was not found."
    end
    _visual.CROP_TOOL = { error = remedy }
    return nil, remedy
end

_visual.build_crop_process = function(platform, tool, src_abs, dst_abs, x, y, w, h)
    return ImageCrop.build_process(platform, tool, src_abs, dst_abs, x, y, w, h, to_os_path)
end

_visual.crop_png_region = function(src_abs, dst_abs, x, y, w, h)
    local tool, tool_err = _visual.resolve_crop_tool()
    if not tool then
        return false, tool_err
    end
    local command, args = _visual.build_crop_process(
        _visual.platform_family(), tool, src_abs, dst_abs, x, y, w, h
    )
    local ok, _, output = run_process(command, args, {
        capture = true,
        reload_resources = true,
    })
    if ok and file_exists(dst_abs) then
        return true
    end
    return false, string.format("%s crop failed: %s", tostring(tool), tostring(output or "no output"))
end

-- Crop a single tile rect out of a sheet-style tilesource into a stable PNG and
-- return its absolute filesystem path plus its Defold resource path.  Used when
-- a Tiled "picture object" (objectgroup with gid) references a sheet tileset
-- (single-image grid) instead of a Collection-of-Images tileset.  The crop is
-- cached on disk so re-exports are cheap, and idempotent so concurrent rooms
-- referencing the same tile share one PNG.  Falls back gracefully on non-
-- Windows hosts or when PowerShell is unavailable.
--
--   tileset_name : Tiled tileset name (e.g. "graveyard_tilemap").
--   local_tile_id: zero-based tile id inside that tileset.
--
-- Returns abs_path, resource_path, width, height on success, or nil + error.
_visual.ensure_extracted_background_tile_image = function(tileset_name, local_tile_id)
    local id = math.floor(tonumber(local_tile_id) or -1)
    if id < 0 then
        return nil, nil, nil, nil, "tile_id_invalid"
    end

    local tileset = tostring(tileset_name or "")
    if tileset == "" then
        return nil, nil, nil, nil, "tileset_name_missing"
    end

    -- Map Tiled tileset name -> Defold .tilesource resource (uses the same
    -- tileset_mapping.lua lookup the rest of the toolkit uses).
    local tilesource_resource, resolve_err = _C.resolve_tilesource(tileset)
    tilesource_resource = _visual.normalize_defold_resource_path(tilesource_resource, ".tilesource")
    if not tilesource_resource then
        return nil, nil, nil, nil, resolve_err or "tilesource_unmapped"
    end

    local meta, meta_err = _visual.load_tilesource_metadata(tilesource_resource)
    if not meta then
        return nil, nil, nil, nil, meta_err or "tilesource_meta_failed"
    end

    -- Collection-of-Images tilesources don't need cropping; the caller already
    -- has per-tile images via the TSX `tiles[].image` entries.
    if meta.image_width == nil or meta.image_height == nil then
        return nil, nil, nil, nil, "tilesource_not_sheet"
    end

    local x, y, w, h = _visual.resolve_tilesource_rect(meta, id)
    if not x then
        return nil, nil, nil, nil, y or "tile_id_out_of_range"
    end

    ensure_dir(PATH.generated_scenery_tiles)

    -- Keep filenames deterministic and unique per (sheet, tile) so different
    -- rooms reusing the same tile share one PNG without colliding with the
    -- breakable-tile frames generated next to them.
    local frame_name = string.format("%s_extracted_t%04d.png", tostring(meta.token or "tiles"), id)
    local frame_abs = join(PATH.generated_scenery_tiles, frame_name)
    local frame_resource = "/developer/assets/atlas/generated/scenery_tiles/" .. frame_name

    local crop_tool, crop_tool_err = _visual.resolve_crop_tool()
    if crop_tool then
        local ok, crop_err = _visual.crop_png_region(meta.image_abs, frame_abs, x, y, w, h)
        if not ok then
            return nil, nil, nil, nil, crop_err or "crop_failed"
        end
    elseif not file_exists(frame_abs) then
        return nil, nil, nil, nil, crop_tool_err or "extracted_tile_missing_and_cropping_unavailable"
    end

    return frame_abs, frame_resource, w, h, nil
end

-- Generate (and cache) a 1x1 RGBA PNG of a solid color, used to render Tiled
-- layers that rely on `tintcolor` instead of an image to produce flat-colored
-- background fills.  The 1x1 PNG is added to the room background atlas like
-- any other image and stretched via sprite scale to cover the target rect, so
-- a single PNG per unique color is enough no matter how many rooms use it.
--
-- The Defold editor sandbox doesn't expose `os.execute`, so this is implemented
-- as a pure-Lua PNG encoder writing raw bytes via `io.open(..., "wb")`.  The
-- output PNG is 1x1, 8-bit RGBA, with a single uncompressed deflate block so
-- no zlib/compression library is required.
--
--   r, g, b : 0..255 channel values (numbers).
--   a       : optional 0..255 alpha (defaults to 255).
--
-- Returns abs_path, resource_path, 1, 1 on success, or nil + error.
do
    -- Bitwise XOR helper that works on whichever bit library this Lua runtime
    -- exposes (LuaJIT `bit`, Lua 5.2 `bit32`) and falls back to a pure-math
    -- bit-by-bit implementation otherwise (Defold's editor scripts run in a
    -- Java-hosted Lua VM so we can't assume native bitops are present).
    local _bxor
    if type(bit32) == "table" and type(bit32.bxor) == "function" then
        _bxor = bit32.bxor
    elseif type(bit) == "table" and type(bit.bxor) == "function" then
        _bxor = function(x, y) return bit.bxor(x, y) % 0x100000000 end
    else
        _bxor = function(a, b)
            a = a % 0x100000000
            b = b % 0x100000000
            local r, p = 0, 1
            for _ = 1, 32 do
                local ab = a % 2
                local bb = b % 2
                if ab ~= bb then r = r + p end
                a = (a - ab) / 2
                b = (b - bb) / 2
                p = p * 2
            end
            return r
        end
    end

    -- Precompute the standard CRC32 polynomial (0xEDB88320) lookup table.
    local crc_table = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if c % 2 == 1 then
                c = _bxor(math.floor(c / 2), 0xEDB88320)
            else
                c = math.floor(c / 2)
            end
        end
        crc_table[i] = c
    end

    local function crc32(bytes)
        local c = 0xFFFFFFFF
        for i = 1, #bytes do
            local idx = _bxor(c, string.byte(bytes, i)) % 256
            c = _bxor(math.floor(c / 256), crc_table[idx])
        end
        return _bxor(c, 0xFFFFFFFF)
    end

    local function be32(n)
        n = math.floor(n) % 0x100000000
        local b1 = math.floor(n / 0x1000000) % 256
        local b2 = math.floor(n / 0x10000) % 256
        local b3 = math.floor(n / 0x100) % 256
        local b4 = n % 256
        return string.char(b1, b2, b3, b4)
    end

    local function png_chunk(chunk_type, data)
        return be32(#data) .. chunk_type .. data .. be32(crc32(chunk_type .. data))
    end

    -- Encode a 1x1 RGBA PNG with a single uncompressed deflate (stored) block.
    local function encode_solid_rgba_png(r8, g8, b8, a8)
        local signature = string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

        -- IHDR: width=1, height=1, bit_depth=8, color_type=6 (truecolor+alpha),
        -- compression=0, filter=0, interlace=0
        local ihdr = be32(1) .. be32(1) .. string.char(8, 6, 0, 0, 0)

        -- Raw IDAT pixel stream: filter byte (0 = None) followed by R,G,B,A.
        local raw = string.char(0, r8, g8, b8, a8)

        -- Adler32 of the raw 5-byte stream.
        local adler_a, adler_b = 1, 0
        for i = 1, #raw do
            adler_a = (adler_a + string.byte(raw, i)) % 65521
            adler_b = (adler_b + adler_a) % 65521
        end
        local adler = adler_b * 0x10000 + adler_a

        -- zlib stream: header (0x78 0x01) + stored deflate block + adler32.
        local len = #raw
        local nlen = 0xFFFF - len
        local zlib =
            string.char(0x78, 0x01) ..
            string.char(0x01) ..             -- BFINAL=1, BTYPE=00 (stored)
            string.char(len % 256, math.floor(len / 256)) ..
            string.char(nlen % 256, math.floor(nlen / 256)) ..
            raw ..
            be32(adler)

        return signature ..
            png_chunk("IHDR", ihdr) ..
            png_chunk("IDAT", zlib) ..
            png_chunk("IEND", "")
    end

    _visual.ensure_solid_color_quad_image = function(r, g, b, a)
        local function clamp_byte(v)
            local n = math.floor(tonumber(v) or 0)
            if n < 0 then n = 0 end
            if n > 255 then n = 255 end
            return n
        end

        local cr = clamp_byte(r)
        local cg = clamp_byte(g)
        local cb = clamp_byte(b)
        local ca = clamp_byte(a == nil and 255 or a)

        ensure_dir(PATH.generated_bg_tint_fills)

        local frame_name = string.format("tint_%02x%02x%02x%02x.png", cr, cg, cb, ca)
        local frame_abs = join(PATH.generated_bg_tint_fills, frame_name)
        local frame_resource = "/developer/assets/atlas/generated/background_tint_fills/" .. frame_name

        -- One PNG per unique color is enough; only (re)generate if missing.
        if not file_exists(frame_abs) then
            local png_bytes = encode_solid_rgba_png(cr, cg, cb, ca)
            local fh, open_err = io.open(to_os_path(frame_abs), "wb")
            if not fh then
                fh, open_err = io.open(frame_abs, "wb")
            end
            if not fh then
                return nil, nil, nil, nil, "open_failed:" .. tostring(open_err)
            end
            local ok_write, write_err = fh:write(png_bytes)
            fh:close()
            if not ok_write then
                return nil, nil, nil, nil, "write_failed:" .. tostring(write_err)
            end
        end

        return frame_abs, frame_resource, 1, 1, nil
    end
end

local PrefabGenerators = require("mvtk.editor.prefab_generators")
PrefabGenerators.configure({
    resolve_half_extents = resolve_half_extents,
    sprite_scale_from_base = sprite_scale_from_base,
    normalize_defold_resource_path = _visual.normalize_defold_resource_path,
    proto_inline_escape = _visual.proto_inline_escape,
})

local gen_one_way_platform_go = PrefabGenerators.gen_one_way_platform_go
local gen_platform_tilemap = PrefabGenerators.gen_platform_tilemap
local gen_tile_platform_go = PrefabGenerators.gen_tile_platform_go
local gen_tile_platform_collision_go = PrefabGenerators.gen_tile_platform_collision_go
local gen_crumble_platform_go = PrefabGenerators.gen_crumble_platform_go
local gen_crumble_platform_collision_go = PrefabGenerators.gen_crumble_platform_collision_go
local gen_pressure_plate_go = PrefabGenerators.gen_pressure_plate_go
local gen_torch_holder_go = PrefabGenerators.gen_torch_holder_go
local gen_gate_go = PrefabGenerators.gen_gate_go
local gen_breakable_wall_go = PrefabGenerators.gen_breakable_wall_go
local gen_teleporter_go = PrefabGenerators.gen_teleporter_go
local gen_water_volume_go = PrefabGenerators.gen_water_volume_go
local gen_bounce_pad_go = PrefabGenerators.gen_bounce_pad_go
local gen_collision_zone_go = PrefabGenerators.gen_collision_zone_go
local gen_checkpoint_go = PrefabGenerators.gen_checkpoint_go
local gen_screen_effect_zone_go = PrefabGenerators.gen_screen_effect_zone_go

-- `gen_collection` is already at Lua 5.1's upvalue ceiling. Keep these on
-- the shared helper table that it already captures instead of adding more
-- direct upvalues in hooks/editor_generators.lua.
_visual.gen_platform_tilemap = gen_platform_tilemap
_visual.gen_tile_platform_go = gen_tile_platform_go
_visual.gen_tile_platform_collision_go = gen_tile_platform_collision_go
_visual.gen_crumble_platform_go = gen_crumble_platform_go
_visual.gen_crumble_platform_collision_go = gen_crumble_platform_collision_go

local BackgroundAtlas = require("mvtk.editor.background_atlas")
BackgroundAtlas.configure({
    visual_helpers = _visual,
    logger = function(msg) info(msg) end,
    normalize = normalize,
    join = join,
    path_basename = path_basename,
    path_dirname = path_dirname,
    sanitize_asset_name = sanitize_asset_name,
    get_tiled_property = get_tiled_property,
    resolve_source_file = resolve_source_file,
    file_exists_any = file_exists_any,
    ensure_dir = ensure_dir,
    write_if_changed = write_if_changed,
    to_project_resource_path = to_project_resource_path,
    tiled_image_layer_to_defold_pos = tiled_image_layer_to_defold_pos,
    is_background_visual_object_candidate = is_background_visual_object_candidate,
    to_project_fs_path = _C.to_project_fs_path,
    resolve_image_path = _C.resolve_image_path,
    copy_file_any = _C.copy_file_any,
    source_is_newer = _C.source_is_newer,
    get_tileset_meta = _C.get_tileset_meta,
    maybe_infer_missing_collection_tile_image = _C.maybe_infer_missing_collection_tile_image,
    ensure_extracted_background_tile_image = _visual.ensure_extracted_background_tile_image,
    ensure_solid_color_quad_image = _visual.ensure_solid_color_quad_image,
    parallax_background_material = PARALLAX_BACKGROUND_MATERIAL,
    parallax_foreground_material = PARALLAX_FOREGROUND_MATERIAL,
})

local get_room_background_atlas_paths = BackgroundAtlas.get_room_background_atlas_paths
local flatten_tiled_layers = BackgroundAtlas.flatten_tiled_layers
local collect_room_background_sprite_components = BackgroundAtlas.collect_room_background_sprite_components
local gen_backgrounds_metadata = BackgroundAtlas.gen_backgrounds_metadata

local ProtoEmit = require("mvtk.editor.proto_emit")
local number_to_proto = ProtoEmit.number_to_proto
local object_rect_center = ProtoEmit.object_rect_center
local resolve_rect_size_pixels = ProtoEmit.resolve_rect_size_pixels
local scale_from_full_size = ProtoEmit.scale_from_full_size
local resolve_breakable_swap_extent = ProtoEmit.resolve_breakable_swap_extent
local rect_center_and_scale = ProtoEmit.rect_center_and_scale
local snapped_rect_center_and_scale = ProtoEmit.snapped_rect_center_and_scale
local append_component_properties = ProtoEmit.append_component_properties
local add_prefab_instance = ProtoEmit.add_prefab_instance
local text_prop = ProtoEmit.text_prop
local static_dialogue_exists = ProtoEmit.static_dialogue_exists
local collectible_type_exists = ProtoEmit.collectible_type_exists
local bool_prop = ProtoEmit.bool_prop
local number_prop = ProtoEmit.number_prop
local normalize_string_enum = ProtoEmit.normalize_string_enum
local build_tiled_loader_props = ProtoEmit.build_tiled_loader_props
local add_rect_prefab_instance = ProtoEmit.add_rect_prefab_instance
local generated_object_id = ProtoEmit.generated_object_id

-- split_lines is imported from mvtk.editor.proto_utils (as
-- split_lines_with_crlf) at the top of this file.

local function parse_tilemap_proto(text)
    local lines, use_crlf = split_lines(text)
    local parsed = {
        top_lines = {},
        tail_lines = {},
        layers = {},
        tile_set = nil,
        use_crlf = use_crlf,
    }

    local saw_layer = false
    local current_layer = nil
    local current_cell = nil

    local function finalize_cell(layer, cell_lines)
        local blob = table.concat(cell_lines, "\n")
        local cell = {
            x = tonumber(blob:match("x:%s*(-?%d+)")),
            y = tonumber(blob:match("y:%s*(-?%d+)")),
            tile = tonumber(blob:match("tile:%s*(-?%d+)")) or 0,
            h_flip = tonumber(blob:match("h_flip:%s*(-?%d+)")) or 0,
            v_flip = tonumber(blob:match("v_flip:%s*(-?%d+)")) or 0,
            rotate90 = tonumber(blob:match("rotate90:%s*(-?%d+)")) or 0,
        }
        if cell.x ~= nil and cell.y ~= nil then
            layer.cells[#layer.cells + 1] = cell
        end
    end

    local function finalize_layer(layer)
        local pre_blob = table.concat(layer.pre_lines, "\n")
        layer.id = pre_blob:match('id:%s*"([^"]+)"') or ""
        layer.z = tonumber(pre_blob:match("z:%s*([%-+%deE%.]+)"))
        local is_visible = pre_blob:match("is_visible:%s*(-?%d+)")
        if is_visible ~= nil then
            layer.is_visible = tonumber(is_visible)
        end
        parsed.layers[#parsed.layers + 1] = layer
    end

    for _, line in ipairs(lines) do
        if not current_layer then
            if line:match("^%s*layers%s*{%s*$") then
                saw_layer = true
                current_layer = {
                    open_line = line,
                    pre_lines = {},
                    cells = {},
                    id = "",
                    z = nil,
                    is_visible = nil,
                }
            else
                if saw_layer then
                    parsed.tail_lines[#parsed.tail_lines + 1] = line
                else
                    parsed.top_lines[#parsed.top_lines + 1] = line
                end
            end
        else
            if current_cell then
                current_cell[#current_cell + 1] = line
                if line:match("^%s*}%s*$") then
                    finalize_cell(current_layer, current_cell)
                    current_cell = nil
                end
            else
                if line:match("^%s*cell%s*{%s*$") then
                    current_cell = { line }
                elseif line:match("^%s*}%s*$") then
                    finalize_layer(current_layer)
                    current_layer = nil
                else
                    current_layer.pre_lines[#current_layer.pre_lines + 1] = line
                end
            end
        end
    end

    local top_blob = table.concat(parsed.top_lines, "\n")
    parsed.tile_set = top_blob:match('tile_set:%s*"([^"]+)"')
    return parsed
end

local function emit_tilemap_cell(lines, indent, cell)
    indent = indent or "  "
    local inner = indent .. "  "
    lines[#lines + 1] = indent .. "cell {"
    lines[#lines + 1] = inner .. "x: " .. tostring(math.floor(tonumber(cell.x) or 0))
    lines[#lines + 1] = inner .. "y: " .. tostring(math.floor(tonumber(cell.y) or 0))
    lines[#lines + 1] = inner .. "tile: " .. tostring(math.floor(tonumber(cell.tile) or 0))
    lines[#lines + 1] = inner .. "h_flip: " .. tostring(math.floor(tonumber(cell.h_flip) or 0))
    lines[#lines + 1] = inner .. "v_flip: " .. tostring(math.floor(tonumber(cell.v_flip) or 0))
    lines[#lines + 1] = inner .. "rotate90: " .. tostring(math.floor(tonumber(cell.rotate90) or 0))
    lines[#lines + 1] = indent .. "}"
end

local function serialize_tilemap_proto(parsed)
    local lines = {}
    for _, line in ipairs(parsed.top_lines or {}) do
        lines[#lines + 1] = line
    end
    for _, layer in ipairs(parsed.layers or {}) do
        lines[#lines + 1] = layer.open_line or "layers {"
        for _, line in ipairs(layer.pre_lines or {}) do
            lines[#lines + 1] = line
        end
        for _, cell in ipairs(layer.cells or {}) do
            emit_tilemap_cell(lines, "  ", cell)
        end
        lines[#lines + 1] = "}"
    end
    for _, line in ipairs(parsed.tail_lines or {}) do
        lines[#lines + 1] = line
    end
    local sep = (parsed.use_crlf == true) and "\r\n" or "\n"
    return table.concat(lines, sep) .. sep
end

local function tilemap_proto_bounds(parsed)
    local min_tx, min_ty, max_tx, max_ty
    for _, layer in ipairs(parsed.layers or {}) do
        for _, cell in ipairs(layer.cells or {}) do
            local tx = tonumber(cell.x)
            local ty = tonumber(cell.y)
            if tx ~= nil and ty ~= nil then
                if min_tx == nil or tx < min_tx then min_tx = tx end
                if min_ty == nil or ty < min_ty then min_ty = ty end
                if max_tx == nil or tx > max_tx then max_tx = tx end
                if max_ty == nil or ty > max_ty then max_ty = ty end
            end
        end
    end
    if min_tx == nil then
        return nil
    end
    return min_tx, max_tx, min_ty, max_ty
end

local function build_tile_frame_for_bake(parsed, tile_w, tile_h)
    local min_tx, max_tx, min_ty, max_ty = tilemap_proto_bounds(parsed)
    if not min_tx then
        return nil
    end
    local tw = tonumber(tile_w) or 128
    local th = tonumber(tile_h) or tw
    if tw <= 0 then tw = 128 end
    if th <= 0 then th = tw end
    return {
        min_tx = min_tx,
        max_tx = max_tx,
        min_ty = min_ty,
        max_ty = max_ty,
        tile_w = tw,
        tile_h = th,
        -- Tile coordinates in .tilemap proto are already map indices; keep
        -- bake-space origin aligned to min tile index directly.
        origin_x = min_tx * tw,
        origin_y = min_ty * th,
    }
end

local function resolve_tile_bounds_for_bake(frame, pos_x, pos_y, width, height)
    if not (frame and pos_x and pos_y and width and height) then
        return nil
    end

    local half_w = math.max((tonumber(width) or 0) * 0.5, 0.5)
    local half_h = math.max((tonumber(height) or 0) * 0.5, 0.5)
    local eps_x = math.min(0.1, half_w * 0.5)
    local eps_y = math.min(0.1, half_h * 0.5)

    local function to_tx(wx)
        return frame.min_tx + math.floor((wx - frame.origin_x) / frame.tile_w)
    end
    local function to_ty(wy)
        return frame.min_ty + math.floor((wy - frame.origin_y) / frame.tile_h)
    end

    local min_tx = to_tx(pos_x - half_w + eps_x)
    local max_tx = to_tx(pos_x + half_w - eps_x)
    local min_ty = to_ty(pos_y - half_h + eps_y)
    local max_ty = to_ty(pos_y + half_h - eps_y)

    min_tx = math.max(frame.min_tx, min_tx)
    max_tx = math.min(frame.max_tx, max_tx)
    min_ty = math.max(frame.min_ty, min_ty)
    max_ty = math.min(frame.max_ty, max_ty)

    if min_tx > max_tx or min_ty > max_ty then
        return nil
    end
    return min_tx, max_tx, min_ty, max_ty
end

local function strip_tilesource_collision_data(content)
    if type(content) ~= "string" or content == "" then
        return content
    end

    local out = {}
    local skipping_hull = false
    local hull_depth = 0

    for line in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if not skipping_hull and line:match("^convex_hulls%s*{") then
            skipping_hull = true
            hull_depth = _proto_utils.brace_delta(line)
            if hull_depth <= 0 then
                skipping_hull = false
                hull_depth = 0
            end
        elseif skipping_hull then
            hull_depth = hull_depth + _proto_utils.brace_delta(line)
            if hull_depth <= 0 then
                skipping_hull = false
                hull_depth = 0
            end
        elseif not line:match("^collision:%s*")
            and not line:match("^collision_groups:%s*")
        then
            out[#out + 1] = line
        end
    end

    return table.concat(out, "\n") .. "\n"
end

local function ensure_visual_tilesource_copy(resource_path)
    local resource = _visual.normalize_defold_resource_path(resource_path, ".tilesource")
    if not resource then
        return nil
    end
    if resource:match("_visual%.tilesource$") then
        return resource
    end

    local visual_resource = resource:gsub("%.tilesource$", "_visual.tilesource")
    local source_abs = normalize(join(ROOT, resource:gsub("^/", "")))
    local visual_abs = normalize(join(ROOT, visual_resource:gsub("^/", "")))
    local source_content = read_text(source_abs)
    if not source_content then
        info("pushable bake: failed to read tilesource " .. tostring(source_abs))
        return resource
    end

    local visual_content = strip_tilesource_collision_data(source_content)
    if write_if_changed(visual_abs, visual_content) then
        info("Created " .. visual_abs)
    end

    return visual_resource
end

local function build_chunk_tilemap_content(tile_set_path, layers, use_crlf)
    local lines = {
        string.format('tile_set: "%s"', tostring(tile_set_path or "/developer/assets/tilesheets/tiles.tilesource")),
    }
    for _, layer in ipairs(layers or {}) do
        lines[#lines + 1] = "layers {"
        lines[#lines + 1] = string.format('  id: "%s"', tostring(layer.id or "solid"))
        if layer.z ~= nil then
            lines[#lines + 1] = "  z: " .. fmt_num(layer.z)
        end
        if layer.is_visible ~= nil then
            lines[#lines + 1] = "  is_visible: " .. tostring(math.floor(tonumber(layer.is_visible) or 0))
        end
        for _, cell in ipairs(layer.cells or {}) do
            emit_tilemap_cell(lines, "  ", cell)
        end
        lines[#lines + 1] = "}"
    end
    local sep = (use_crlf == true) and "\r\n" or "\n"
    return table.concat(lines, sep) .. sep
end

local function clone_tilemap_proto(parsed)
    if not parsed then
        return nil
    end
    local text = serialize_tilemap_proto(parsed)
    if not text then
        return nil
    end
    return parse_tilemap_proto(text)
end

local function build_tilemap_proto_state(parsed)
    local state = {}
    for _, layer in ipairs((parsed and parsed.layers) or {}) do
        local layer_id = tostring(layer.id or "")
        local cells = {}
        local count = 0
        for _, cell in ipairs(layer.cells or {}) do
            local tx = tonumber(cell.x)
            local ty = tonumber(cell.y)
            local tid = math.floor(tonumber(cell.tile) or 0)
            if tx ~= nil and ty ~= nil and tid ~= 0 then
                cells[string.format("%d,%d", tx, ty)] = tid
                count = count + 1
            end
        end
        state[layer_id] = {
            count = count,
            cells = cells,
        }
    end
    return state
end

local function collect_proto_changed_keys(before_cells, after_cells)
    local keys = {}
    local seen = {}

    local function add_key(key)
        if not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end

    for key in pairs(before_cells or {}) do
        if (before_cells[key] or 0) ~= (after_cells[key] or 0) then
            add_key(key)
        end
    end
    for key in pairs(after_cells or {}) do
        if (before_cells[key] or 0) ~= (after_cells[key] or 0) then
            add_key(key)
        end
    end

    table.sort(keys, function(a, b)
        local ax, ay = a:match("(-?%d+),(-?%d+)")
        local bx, by = b:match("(-?%d+),(-?%d+)")
        ax, ay = tonumber(ax) or 0, tonumber(ay) or 0
        bx, by = tonumber(bx) or 0, tonumber(by) or 0
        if ay ~= by then
            return ay < by
        end
        return ax < bx
    end)

    return keys
end

local function log_tilemap_proto_diff(tag, room_id, before_parsed, after_parsed, max_layers, max_samples)
    local before_state = build_tilemap_proto_state(before_parsed)
    local after_state = build_tilemap_proto_state(after_parsed)
    local layer_ids = {}
    local seen = {}

    for layer_id in pairs(before_state) do
        seen[layer_id] = true
        layer_ids[#layer_ids + 1] = layer_id
    end
    for layer_id in pairs(after_state) do
        if not seen[layer_id] then
            layer_ids[#layer_ids + 1] = layer_id
        end
    end
    table.sort(layer_ids)

    local logged = 0
    local layer_limit = tonumber(max_layers) or 3
    local sample_limit = tonumber(max_samples) or 6

    for _, layer_id in ipairs(layer_ids) do
        local before_layer = before_state[layer_id] or { count = 0, cells = {} }
        local after_layer = after_state[layer_id] or { count = 0, cells = {} }
        local changed_keys = collect_proto_changed_keys(before_layer.cells, after_layer.cells)
        if #changed_keys > 0 or before_layer.count ~= after_layer.count then
            local samples = {}
            for i = 1, math.min(#changed_keys, sample_limit) do
                local key = changed_keys[i]
                local tx, ty = key:match("(-?%d+),(-?%d+)")
                samples[#samples + 1] = string.format("(%s,%s):%s->%s",
                    tostring(tx),
                    tostring(ty),
                    tostring(before_layer.cells[key] or 0),
                    tostring(after_layer.cells[key] or 0))
            end
            info(string.format(
                "%s room=%s layer=%s before=%d after=%d changed=%d%s",
                tostring(tag or "[TILEMAP_PROTO_DIFF]"),
                tostring(room_id),
                tostring(layer_id ~= "" and layer_id or "<unnamed>"),
                tonumber(before_layer.count) or 0,
                tonumber(after_layer.count) or 0,
                #changed_keys,
                (#samples > 0) and (" samples=" .. table.concat(samples, ", ")) or ""
            ))
            logged = logged + 1
            if logged >= layer_limit then
                break
            end
        end
    end

    if logged == 0 then
        info(string.format("%s room=%s no layer diffs detected", tostring(tag or "[TILEMAP_PROTO_DIFF]"), tostring(room_id)))
    end
end

local function ensure_pushable_bake_context(rid, map_tile_w, map_tile_h)
    local tilemap_path = join(PATH.tilemaps, rid .. ".tilemap")
    local source_tilemap_path = join(PATH.generated_go, rid .. "_pushable_source.tilemap")

    local tilemap_content = read_text(tilemap_path)
    if not tilemap_content then
        info("pushable bake: tilemap not found: " .. tostring(tilemap_path))
        return nil
    end

    local source_content = read_text(source_tilemap_path)
    local refresh_source = (source_content == nil)
    local refresh_reason = refresh_source and "missing_source" or "up_to_date"
    local tilemap_mtime = nil
    local source_mtime = nil
    if (not refresh_source) and lfs_ok and lfs and lfs.attributes then
        tilemap_mtime = lfs.attributes(tilemap_path, "modification")
        source_mtime = lfs.attributes(source_tilemap_path, "modification")
        if tilemap_mtime and source_mtime and tilemap_mtime > source_mtime then
            refresh_source = true
            refresh_reason = "tilemap_newer"
        end
    end
    if (not refresh_source) and source_content ~= tilemap_content then
        refresh_source = true
        refresh_reason = "content_mismatch"
    end

    local current_parsed = parse_tilemap_proto(tilemap_content)

    if refresh_source then
        source_content = tilemap_content
        if write_if_changed(source_tilemap_path, source_content) then
            info("Updated " .. source_tilemap_path .. " (pushable bake source)")
        end
    end

    local source_parsed = parse_tilemap_proto(source_content)
    if not source_parsed or not source_parsed.layers or #source_parsed.layers == 0 then
        info("pushable bake: failed to parse source tilemap layers for " .. tostring(rid))
        return nil
    end

    info(string.format(
        "[PUSHABLE_BAKE_CONTEXT] room=%s refresh_source=%s reason=%s tilemap_mtime=%s source_mtime=%s source_path=%s",
        tostring(rid),
        tostring(refresh_source),
        tostring(refresh_reason),
        tostring(tilemap_mtime),
        tostring(source_mtime),
        tostring(source_tilemap_path)
    ))
    if current_parsed and source_parsed then
        log_tilemap_proto_diff("[PUSHABLE_BAKE_SOURCE]", rid, current_parsed, source_parsed, 4, 8)
    end

    local parsed = clone_tilemap_proto(source_parsed)
    if not parsed then
        info("pushable bake: failed to clone tilemap source for " .. tostring(rid))
        return nil
    end

    local frame = build_tile_frame_for_bake(source_parsed, map_tile_w, map_tile_h)
    if not frame then
        info("pushable bake: failed to compute tilemap bounds for " .. tostring(rid))
        return nil
    end

    return {
        room_id = rid,
        tilemap_path = tilemap_path,
        source_tilemap_path = source_tilemap_path,
        current_parsed = current_parsed,
        source_parsed = source_parsed,
        parsed = parsed,
        frame = frame,
        dirty = false,
    }
end

local function bake_pushable_chunk_tilemap(ctx, rid, obj, defold_y, resolved_w, resolved_h)
    if not ctx or not ctx.source_parsed or not ctx.parsed or not ctx.frame then
        return nil, false, 0, 0
    end

    local raw_x = tonumber(obj and obj.x) or 0
    local raw_y = tonumber(defold_y) or 0
    local px = raw_x + (resolved_w * 0.5)
    local py = raw_y - (resolved_h * 0.5)

    local min_tx, max_tx, min_ty, max_ty = resolve_tile_bounds_for_bake(ctx.frame, px, py, resolved_w, resolved_h)
    if not min_tx then
        info(string.format("pushable bake: no tile bounds for %s id=%s", tostring(rid), tostring(obj and obj.id)))
        return nil, false, 0, 0
    end

    local chunk_w = max_tx - min_tx + 1
    local chunk_h = max_ty - min_ty + 1
    if chunk_w <= 0 or chunk_h <= 0 then
        return nil, false, 0, 0
    end

    local cx_start = (chunk_w % 2 == 0) and (1 - (chunk_w / 2)) or (-math.floor(chunk_w / 2))
    local cy_start = (chunk_h % 2 == 0) and (1 - (chunk_h / 2)) or (-math.floor(chunk_h / 2))
    local tile_w = tonumber(ctx.frame.tile_w) or 128
    local tile_h = tonumber(ctx.frame.tile_h) or tile_w
    if tile_w <= 0 then tile_w = 128 end
    if tile_h <= 0 then tile_h = tile_w end
    -- Align chunk-local tile coordinates to the source map tile coordinates,
    -- so the baked visual in the editor matches runtime world placement.
    local chunk_offset_x = ((min_tx - cx_start) * tile_w) - px
    local chunk_offset_y = ((min_ty - cy_start) * tile_h) - py
    if math.abs(chunk_offset_x) < 0.0005 then chunk_offset_x = 0 end
    if math.abs(chunk_offset_y) < 0.0005 then chunk_offset_y = 0 end
    local chunk_name = string.format("%s_pushable_block_%d_chunk.tilemap", rid, obj.id)
    local chunk_abs_path = join(PATH.generated_go, chunk_name)
    local chunk_proto_path = string.format("/developer/rooms/generated/%s", chunk_name)

    local chunk_layers = {}
    for li, source_layer in ipairs(ctx.source_parsed.layers or {}) do
        local work_layer = ctx.parsed.layers and ctx.parsed.layers[li]
        local layer_key = (source_layer.id ~= "" and source_layer.id) or ("layer_" .. tostring(li))

        local source_cells = {}
        for _, cell in ipairs(source_layer.cells or {}) do
            local tx = tonumber(cell.x)
            local ty = tonumber(cell.y)
            if tx ~= nil and ty ~= nil then
                source_cells[tostring(tx) .. "," .. tostring(ty)] = cell
            end
        end

        local captured_cells = {}
        local removed_source = {}

        for oy = 0, chunk_h - 1 do
            for ox = 0, chunk_w - 1 do
                local tx = min_tx + ox
                local ty = min_ty + oy
                local local_x = cx_start + ox
                local local_y = cy_start + oy

                local source_key = tostring(tx) .. "," .. tostring(ty)
                local source_cell = source_cells[source_key]
                local src_tid = tonumber(source_cell and source_cell.tile) or 0
                local tid = src_tid
                local h_flip = tonumber(source_cell and source_cell.h_flip) or 0
                local v_flip = tonumber(source_cell and source_cell.v_flip) or 0
                local rotate90 = tonumber(source_cell and source_cell.rotate90) or 0

                if source_cell ~= nil then
                    -- Capture any present source cell, including tile:0 (a valid
                    -- first tile), not just non-zero ids.
                    captured_cells[#captured_cells + 1] = {
                        x = local_x,
                        y = local_y,
                        tile = tid,
                        h_flip = h_flip,
                        v_flip = v_flip,
                        rotate90 = rotate90,
                    }
                    removed_source[source_key] = true
                end
            end
        end

        if #captured_cells > 0 then
            if work_layer then
                local remaining_cells = {}
                local removed_any = false
                for _, cell in ipairs(work_layer.cells or {}) do
                    local tx = tonumber(cell.x)
                    local ty = tonumber(cell.y)
                    local key = (tx ~= nil and ty ~= nil) and (tostring(tx) .. "," .. tostring(ty)) or nil
                    if key and removed_source[key] then
                        removed_any = true
                    else
                        remaining_cells[#remaining_cells + 1] = cell
                    end
                end
                if removed_any then
                    work_layer.cells = remaining_cells
                    ctx.dirty = true
                end
            end
            chunk_layers[#chunk_layers + 1] = {
                id = layer_key,
                z = source_layer.z,
                is_visible = source_layer.is_visible,
                cells = captured_cells,
            }
        end
    end

    if #chunk_layers == 0 then
        -- Idempotent re-generation path:
        -- if tiles were already baked out of the source map on a previous run,
        -- keep using the previously generated chunk tilemap.
        if file_exists(chunk_abs_path) then
            return chunk_proto_path, true, chunk_offset_x, chunk_offset_y
        end
        return nil, false, 0, 0
    end

    local chunk_tilesource = ensure_visual_tilesource_copy(ctx.source_parsed.tile_set) or ctx.source_parsed.tile_set
    local chunk_content = build_chunk_tilemap_content(chunk_tilesource, chunk_layers, ctx.source_parsed.use_crlf)
    if write_if_changed(chunk_abs_path, chunk_content) then
        info("Created " .. chunk_abs_path)
    end

    return chunk_proto_path, true, chunk_offset_x, chunk_offset_y
end

local function flush_pushable_bake_context(ctx)
    if not ctx or not ctx.dirty then
        return
    end
    if ctx.current_parsed and ctx.parsed then
        log_tilemap_proto_diff("[PUSHABLE_BAKE_RESULT]", ctx.room_id, ctx.current_parsed, ctx.parsed, 4, 8)
    end
    local updated = serialize_tilemap_proto(ctx.parsed)
    if write_if_changed(ctx.tilemap_path, updated) then
        info("Updated " .. ctx.tilemap_path .. " (baked pushable tiles)")
    end
end

-- ── Share locals with subsequent hook files via explicit context ───────
-- editor_generators.lua and editor_commands.lua read these at load time.
do
    local _S = Context.require_context("hooks/editor_script.lua exports")
    _S.visual_helpers = _visual
    _S.RenderOrder = RenderOrder
    _S.ParallaxRepeat = ParallaxRepeat
    _S.PARALLAX_BACKGROUND_MATERIAL = PARALLAX_BACKGROUND_MATERIAL
    _S.PARALLAX_FOREGROUND_MATERIAL = PARALLAX_FOREGROUND_MATERIAL
    _S.STANDARD_TILE_COLLISION_GROUP = STANDARD_TILE_COLLISION_GROUP
    _S.STANDARD_TILE_COLLISION_FIRST = STANDARD_TILE_COLLISION_FIRST
    _S.STANDARD_TILE_COLLISION_LAST = STANDARD_TILE_COLLISION_LAST
    _S.standardize_tilesource_collision_setup = standardize_tilesource_collision_setup
    _S.gen_one_way_platform_go = gen_one_way_platform_go
    _S.gen_platform_tilemap = gen_platform_tilemap
    _S.gen_tile_platform_go = gen_tile_platform_go
    _S.gen_tile_platform_collision_go = gen_tile_platform_collision_go
    _S.gen_crumble_platform_go = gen_crumble_platform_go
    _S.gen_crumble_platform_collision_go = gen_crumble_platform_collision_go
    _S.gen_pressure_plate_go = gen_pressure_plate_go
    _S.gen_torch_holder_go = gen_torch_holder_go
    _S.gen_gate_go = gen_gate_go
    _S.gen_breakable_wall_go = gen_breakable_wall_go
    _S.gen_teleporter_go = gen_teleporter_go
    _S.gen_water_volume_go = gen_water_volume_go
    _S.gen_bounce_pad_go = gen_bounce_pad_go
    _S.gen_collision_zone_go = gen_collision_zone_go
    _S.gen_checkpoint_go = gen_checkpoint_go
    _S.gen_screen_effect_zone_go = gen_screen_effect_zone_go
    _S.flatten_tiled_layers = flatten_tiled_layers
    _S.collect_room_background_sprite_components = collect_room_background_sprite_components
    _S.take_background_import_warnings = BackgroundAtlas.take_import_warnings
    _S.gen_backgrounds_metadata = gen_backgrounds_metadata
    _S.get_room_background_atlas_paths = get_room_background_atlas_paths
    _S.proto_escape = proto_escape
    _S.bool_to_proto = bool_to_proto
    _S.number_to_proto = number_to_proto
    _S.object_rect_center = object_rect_center
    _S.resolve_rect_size_pixels = resolve_rect_size_pixels
    _S.scale_from_full_size = scale_from_full_size
    _S.resolve_breakable_swap_extent = resolve_breakable_swap_extent
    _S.rect_center_and_scale = rect_center_and_scale
    _S.snapped_rect_center_and_scale = snapped_rect_center_and_scale
    _S.append_component_properties = append_component_properties
    _S.add_prefab_instance = add_prefab_instance
    _S.text_prop = text_prop
    _S.static_dialogue_exists = static_dialogue_exists
    _S.collectible_type_exists = collectible_type_exists
    _S.bool_prop = bool_prop
    _S.number_prop = number_prop
    _S.normalize_string_enum = normalize_string_enum
    _S.build_tiled_loader_props = build_tiled_loader_props
    _S.add_rect_prefab_instance = add_rect_prefab_instance
    _S.generated_object_id = generated_object_id
    _S.ensure_pushable_bake_context = ensure_pushable_bake_context
    _S.bake_pushable_chunk_tilemap = bake_pushable_chunk_tilemap
    _S.flush_pushable_bake_context = flush_pushable_bake_context
end

return true

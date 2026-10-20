-- hooks/core/tilesource.lua
--
-- Tilesource, image, TSX, and Tiled tileset helpers used by editor-time room
-- generation. hooks/editor_core.lua configures the project-specific
-- collaborators and re-exports these functions through the shared hook context.

local path_utils = require("mvtk.editor.path_utils")
local file_utils = require("mvtk.editor.file_utils")
local TileCollision = require("mvtk.tiled.tile_collision")
local TileSettingsWriter = require("mvtk.editor.tile_settings_writer")
local TilesetSelection = require("mvtk.editor.tileset_selection")
local TiledObjects = require("hooks.core.tiled_objects")
local Adler32 = require("mvtk.core.adler32")
local TiledSourceSafety = require("mvtk.editor.tiled_source_safety")
local ResourceText = require("mvtk.editor.resource_text")
local TilemapRegen = require("mvtk.editor.tilemap_regen")
local Transaction = require("mvtk.editor.project_transaction")

local M = {}

local ROOT = "."
local PATH = {}
local TilesetMapping = nil

local config = {
    info = function() end,
    load_tiled_export = nil,
    write_if_changed = nil,
    copy_file_any = nil,
    list_dir_filesystem = nil,
}

local CONFIG_KEYS = {
    info = true,
    load_tiled_export = true,
    write_if_changed = true,
    copy_file_any = true,
    list_dir_filesystem = true,
}

function M.configure(deps)
    deps = deps or {}
    if deps.root ~= nil then ROOT = path_utils.normalize(deps.root) end
    if deps.path ~= nil then PATH = deps.path end
    if deps.tileset_mapping ~= nil then TilesetMapping = deps.tileset_mapping end
    for key, value in pairs(deps) do
        if CONFIG_KEYS[key] then
            config[key] = value
        end
    end
end

local normalize = path_utils.normalize
local join = path_utils.join
local is_absolute_path = path_utils.is_absolute_path
local path_dirname = path_utils.dirname
local path_basename = path_utils.basename

local read_text = file_utils.read_text
local file_exists = file_utils.file_exists
local file_exists_any = file_utils.file_exists_any
local read_text_any = file_utils.read_text_any

local function info(msg)
    return (config.info or function() end)(msg)
end

local function load_tiled_export(room_id)
    assert(config.load_tiled_export, "hooks.core.tilesource requires load_tiled_export")
    return config.load_tiled_export(room_id)
end

local function write_if_changed(...)
    assert(config.write_if_changed, "hooks.core.tilesource requires write_if_changed")
    return config.write_if_changed(...)
end

local function copy_file_any(...)
    assert(config.copy_file_any, "hooks.core.tilesource requires copy_file_any")
    return config.copy_file_any(...)
end

local function list_dir_filesystem(...)
    assert(config.list_dir_filesystem, "hooks.core.tilesource requires list_dir_filesystem")
    return config.list_dir_filesystem(...)
end

local function project_tile_size_defaults()
    local ok, Tile = pcall(require, "developer.config.tile_settings")
    local w = ok and Tile and tonumber(Tile.width or Tile.tile_width or Tile.size) or nil
    local h = ok and Tile and tonumber(Tile.height or Tile.tile_height or Tile.size) or nil
    if not w or w <= 0 then w = 128 end
    if not h or h <= 0 then h = w end
    return w, h
end

local function resolve_tilesource_collision_resource(image_resource)
    if not image_resource or image_resource == "" then
        return image_resource
    end

    local normalized = normalize(tostring(image_resource))
    if normalized:sub(-4):lower() ~= ".png" then
        return normalized
    end

    local collision_resource = normalized:gsub("%.png$", "_collision.png")
    local collision_abs = ROOT .. collision_resource
    if file_exists_any(collision_abs) then
        return collision_resource
    end

    return normalized
end

local STANDARD_TILE_COLLISION_GROUP = "solid"
local STANDARD_TILE_COLLISION_FIRST = 2
local STANDARD_TILE_COLLISION_LAST = 20

local function positive_integer(value)
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    n = math.floor(n)
    if n <= 0 then
        return nil
    end
    return n
end

local function nonnegative_integer(value)
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    n = math.floor(n)
    if n < 0 then
        return nil
    end
    return n
end

local function compute_tileset_axis_count(axis_size, tile_size, spacing, margin)
    local axis = positive_integer(axis_size)
    local tile = positive_integer(tile_size)
    if not axis or not tile then
        return nil
    end

    local gap = nonnegative_integer(spacing) or 0
    local edge = nonnegative_integer(margin) or 0
    local stride = tile + gap
    if stride <= 0 then
        return nil
    end

    local usable = axis - (edge * 2) + gap
    if usable < tile then
        return nil
    end

    local count = math.floor(usable / stride)
    if count <= 0 then
        return nil
    end
    return count
end

local function resolve_tilesource_tile_count(tile_width, tile_height, image_width, image_height, opts)
    opts = type(opts) == "table" and opts or {}

    local explicit_tile_count = positive_integer(opts.tilecount or opts.tile_count)
    if explicit_tile_count then
        return explicit_tile_count
    end

    local spacing = nonnegative_integer(opts.spacing) or 0
    local margin = nonnegative_integer(opts.margin) or 0
    local columns = positive_integer(opts.columns)
        or compute_tileset_axis_count(opts.imagewidth or image_width, tile_width, spacing, margin)
    local rows = positive_integer(opts.rows)
        or compute_tileset_axis_count(opts.imageheight or image_height, tile_height, spacing, margin)

    if columns and rows then
        return columns * rows
    end

    return nil
end

local function append_default_tilesource_convex_hulls(rows, tile_count, shaped_defold_ids)
    local total_tiles = positive_integer(tile_count) or 1
    shaped_defold_ids = shaped_defold_ids or {}
    for tile_id = 1, total_tiles do
        local collision_group = ""
        if shaped_defold_ids[tile_id] then
            -- This tile has a precise hull authored in the Tile Collision
            -- Editor; that hull is baked into the room collisionobject. The
            -- tilesource itself no longer assigns collision by tile index.
            collision_group = ""
        end
        rows[#rows + 1] = "convex_hulls {"
        rows[#rows + 1] = string.format("  index: %d", (tile_id - 1) * 4)
        rows[#rows + 1] = "  count: 4"
        rows[#rows + 1] = string.format('  collision_group: "%s"', collision_group)
        rows[#rows + 1] = "}"
    end
end

-- Resolve a Tiled image path to an actual PNG inside the project
local function resolve_image_path(image_path)
    if not image_path or image_path == "" then
        return nil
    end

    local cleaned = normalize(image_path)
    local filename = cleaned:match("([^/\\]+)$")
    local candidates = {}
    local seen = {}

    local function add_candidate(path)
        if not path or path == "" then return end
        path = normalize(path)
        if not seen[path] then
            seen[path] = true
            candidates[#candidates + 1] = path
        end
    end

    -- Direct/absolute paths
    if cleaned:match("^[A-Za-z]:") then
        add_candidate(cleaned)
    elseif cleaned:sub(1, 1) == "/" then
        add_candidate(join(ROOT, cleaned))
    end

    -- Relative paths from Tiled exports (strip ALL leading ../ sequences)
    local relative = cleaned:gsub("^(%.%./)+", "")

    -- Handle case-insensitive matches (Assets vs assets)
    local relative_lower = relative:gsub("^[Aa]ssets/", "assets/")

    add_candidate(join(ROOT, relative))
    add_candidate(join(ROOT, relative_lower))
    add_candidate(join(ROOT, "developer", relative_lower))
    add_candidate(join(ROOT, "developer", "assets", "tiled", "backgrounds", filename or ""))

    -- Common asset locations (fallback by filename)
    if filename then
        add_candidate(join(ROOT, "developer", "assets", "tiled", "backgrounds", filename))
        add_candidate(join(ROOT, "developer", "assets", "tiled", filename))
        add_candidate(join(ROOT, "assets", "tiled", "backgrounds", filename))
        add_candidate(join(ROOT, "assets", "tiled", "images", filename))
        add_candidate(join(ROOT, "assets", "tiled", filename))
        add_candidate(join(ROOT, "assets", filename))
    end

    for _, candidate in ipairs(candidates) do
        if file_exists(candidate) then
            return candidate
        end
    end

    return nil
end

local PNG_DIMENSION_CACHE = {}

-- Read PNG dimensions without external dependencies
local function get_png_dimensions(image_path)
    if not image_path or image_path == "" then
        return nil, nil
    end

    local cache_key = normalize(image_path)
    if PNG_DIMENSION_CACHE[cache_key] then
        return PNG_DIMENSION_CACHE[cache_key][1], PNG_DIMENSION_CACHE[cache_key][2]
    end

    local resolved = resolve_image_path(image_path)
    if not resolved then
        PNG_DIMENSION_CACHE[cache_key] = { nil, nil }
        return nil, nil
    end

    local ok_open, fh = pcall(io.open, resolved, "rb")
    if not ok_open or not fh then
        PNG_DIMENSION_CACHE[cache_key] = { nil, nil }
        return nil, nil
    end

    local header = fh:read(24)
    fh:close()

    -- PNG header is: 8-byte signature, 4-byte length, 4-byte "IHDR", then width/height (big-endian)
    if not header or #header < 24 or header:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        PNG_DIMENSION_CACHE[cache_key] = { nil, nil }
        return nil, nil
    end

    local function read_int(str, offset)
        local b1, b2, b3, b4 = str:byte(offset, offset + 3)
        if not b4 then return nil end
        return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end

    local width = read_int(header, 17)
    local height = read_int(header, 21)
    PNG_DIMENSION_CACHE[cache_key] = { width, height }
    return width, height
end


local function collect_missing_generated_rooms(room_ids)
    local missing = {}
    for _, rid in ipairs(room_ids or {}) do
        local level_path = join(PATH.generated_go, rid .. "_level.go")
        local collection_path = join(PATH.collections, rid .. ".collection")
        local factory_path = join(PATH.factories, rid .. "_factory.collectionfactory")

        local missing_level = not file_exists_any(level_path)
        local missing_collection = not file_exists_any(collection_path)
        local missing_factory = not file_exists_any(factory_path)

        if missing_level or missing_collection or missing_factory then
            missing[#missing + 1] = rid
            info(string.format(
                "[IMPORT] room '%s' missing generated files: level=%s collection=%s factory=%s",
                tostring(rid),
                tostring(missing_level),
                tostring(missing_collection),
                tostring(missing_factory)
            ))
        end
    end
    table.sort(missing)
    return missing
end

-- copy_file_any lives in hooks.core.filesystem.

local function sanitize_asset_name(value, fallback)
    local s = tostring(value or ""):lower()
    s = s:gsub("[%s%-]+", "_")
    s = s:gsub("[^%w_]", "_")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    if s == "" then
        s = tostring(fallback or "tiles")
    end
    return s
end

local function get_tiled_property(properties, key)
    if type(properties) ~= "table" or not key or key == "" then
        return nil
    end

    local direct = properties[key]
    if direct ~= nil then
        if type(direct) == "table" then
            if direct.value ~= nil then return direct.value end
            if direct.Value ~= nil then return direct.Value end
        end
        return direct
    end

    for _, entry in ipairs(properties) do
        if type(entry) == "table" then
            local name = entry.name or entry.Name
            if name == key then
                if entry.value ~= nil then return entry.value end
                if entry.Value ~= nil then return entry.Value end
            end
        end
    end

    return nil
end

local function parse_xml_attributes(attr_text)
    local attrs = {}
    if type(attr_text) ~= "string" then
        return attrs
    end
    for name, _, value in attr_text:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[name] = value
    end
    return attrs
end

local function parse_tile_animation_frames(frames_data)
    if type(frames_data) ~= "string" and type(frames_data) ~= "table" then
        return nil
    end

    local frames = {}
    local durations_ms = {}

    if type(frames_data) == "string" then
        for frame_attr_text in frames_data:gmatch("<frame%s+([^>/]-)/>") do
            local attrs = parse_xml_attributes(frame_attr_text)
            local tileid = tonumber(attrs.tileid)
            local duration = tonumber(attrs.duration)
            if tileid ~= nil then
                frames[#frames + 1] = tileid
                durations_ms[#durations_ms + 1] = duration or 100
            end
        end
    else
        for _, frame in ipairs(frames_data) do
            if type(frame) == "table" then
                local tileid = tonumber(frame.tileid or frame.id or frame.tile)
                local duration = tonumber(frame.duration or frame.duration_ms or frame.ms)
                if tileid ~= nil then
                    frames[#frames + 1] = tileid
                    durations_ms[#durations_ms + 1] = duration or 100
                end
            end
        end
    end

    if #frames < 2 then
        return nil
    end

    return {
        frames = frames,
        durations_ms = durations_ms,
    }
end

local RESOLVE_SOURCE_CACHE = {}

local function resolve_source_file(raw_path, base_dir)
    if not raw_path or raw_path == "" then
        return nil
    end

    -- Cache key combines path + base_dir to avoid collisions
    local cache_key = tostring(raw_path) .. "\0" .. tostring(base_dir or "")
    if RESOLVE_SOURCE_CACHE[cache_key] ~= nil then
        -- false means "previously resolved to nil"
        local cached = RESOLVE_SOURCE_CACHE[cache_key]
        if cached == false then return nil end
        return cached
    end

    local cleaned = normalize(raw_path)
    local filename = cleaned:match("([^/\\]+)$")
    local candidates = {}
    local seen = {}

    local function add_candidate(path)
        if not path or path == "" then
            return
        end
        path = normalize(path)
        if seen[path] then
            return
        end
        seen[path] = true
        candidates[#candidates + 1] = path
    end

    local function add_project_filename_candidates()
        if not filename then
            return
        end
        add_candidate(join(ROOT, "developer", "assets", "tilesheets", filename))
        add_candidate(join(ROOT, "developer", "assets", "tiled", "tilesets", filename))
        add_candidate(join(ROOT, "developer", "assets", "tiled", "backgrounds", filename))
        add_candidate(join(ROOT, "developer", "assets", "tiled", filename))
        add_candidate(join(ROOT, "assets", "tiled", "tilesets", filename))
        add_candidate(join(ROOT, "assets", "tiled", "backgrounds", filename))
        add_candidate(join(ROOT, "assets", filename))
    end

    -- Tiled exports often reference tilesets/images through paths that escape
    -- the project. Prefer project-local copies by filename when that happens;
    -- the Defold editor can report that external files exist but still fail to
    -- read/copy them through the editor pipeline.
    if not is_absolute_path(cleaned) and cleaned:find("%.%.", 1, true) then
        add_project_filename_candidates()
    end

    if base_dir and base_dir ~= "" and not is_absolute_path(cleaned) then
        add_candidate(join(base_dir, cleaned))
    end

    local relative = cleaned:gsub("^(%.%./)+", "")
    local drive_relative = cleaned:match("^[A-Za-z]:/(.*)$")
    if drive_relative and drive_relative ~= "" then
        relative = drive_relative
    end
    local relative_lower = relative:gsub("^[Aa]ssets/", "assets/")
    add_candidate(join(ROOT, relative))
    add_candidate(join(ROOT, relative_lower))
    add_candidate(join(ROOT, "developer", relative))
    add_candidate(join(ROOT, "developer", relative_lower))
    add_candidate(join(ROOT, "assets", relative))
    add_candidate(join(ROOT, "assets", relative_lower))

    add_project_filename_candidates()

    -- External absolute files are fallback candidates.
    -- Prefer project-local copies to avoid editor sandbox read/copy failures.
    if is_absolute_path(cleaned) then
        add_candidate(cleaned)
        local drive, rest = cleaned:match("^([A-Za-z]):/(.*)$")
        if drive and rest then
            add_candidate("/mnt/" .. drive:lower() .. "/" .. rest)
        end
    end

    -- When the path was relative (../../Assets/...) and stripping led to a path
    -- like "Assets/graveyard/moon.png", try it as a root-level path on likely
    -- drives.  Tiled exports often use relative paths that escape the project
    -- tree and land on a shared asset drive.
    if not is_absolute_path(cleaned) and relative ~= cleaned then
        -- relative has the ../ stripped.  Try it on the project's drive and
        -- common asset drives.
        local proj_drive = ROOT:match("^([A-Za-z]):")
        local tried_drives = {}
        local drive_list = {"V", "C", "D", "E"}
        if proj_drive then
            table.insert(drive_list, 1, proj_drive:upper())
        end
        for _, drive in ipairs(drive_list) do
            if not tried_drives[drive] then
                tried_drives[drive] = true
                add_candidate(drive .. ":/" .. relative)
            end
        end
    end

    for _, candidate in ipairs(candidates) do
        if file_exists_any(candidate) then
            RESOLVE_SOURCE_CACHE[cache_key] = candidate
            return candidate
        end
    end

    RESOLVE_SOURCE_CACHE[cache_key] = false
    return nil
end

local TSX_META_CACHE = {}

local function simple_checksum(content)
    return string.format("%x", Adler32.checksum(content or ""))
end

local function tsx_cache_key(tsx_path, content)
    return tostring(tsx_path or "") .. "#" .. tostring(#(content or "")) .. "#" .. simple_checksum(content or "")
end

local function parse_tsx_tileset(tsx_path)
    tsx_path = normalize(tsx_path or "")
    if tsx_path == "" then
        return nil, "missing tsx path"
    end

    local content = read_text_any(tsx_path)
    if not content then
        return nil, "cannot read tsx: " .. tostring(tsx_path)
    end
    local cache_key = tsx_cache_key(tsx_path, content)
    if TSX_META_CACHE[cache_key] ~= nil then
        return TSX_META_CACHE[cache_key]
    end

    local tsx_dir = path_dirname(tsx_path)
    local root_attrs = parse_xml_attributes(content:match("<tileset%s+([^>]*)>") or "")
    local meta = {
        tilewidth = tonumber(root_attrs.tilewidth),
        tileheight = tonumber(root_attrs.tileheight),
        tilecount = tonumber(root_attrs.tilecount),
        columns = tonumber(root_attrs.columns),
        spacing = tonumber(root_attrs.spacing),
        margin = tonumber(root_attrs.margin),
        image = nil,
        imagewidth = nil,
        imageheight = nil,
        objectalignment = root_attrs.objectalignment,
        tile_properties = {},
        tile_classes = {},
        tile_images = {},
        tile_animations = {},
        tile_collision = {},
        tile_collision_diagnostics = {},
        collection = false,
        tsx_path = tsx_path,
    }

    -- Only a tileset-level image is a sheet. A collection's images belong to
    -- individual tiles. LuaJ cannot use frontier patterns to find this boundary.
    local sheet_text = content
    local search_at = 1
    while true do
        local tile_at = content:find("<tile", search_at, true)
        if not tile_at then break end
        local after = content:sub(tile_at + 5, tile_at + 5)
        if after == ">" or after:match("%s") then
            sheet_text = content:sub(1, tile_at - 1)
            break
        end
        search_at = tile_at + 5
    end
    local image_attr_text = sheet_text:match("<image%s+([^>/]-)/>") or sheet_text:match("<image%s+([^>]*)>")
    if image_attr_text then
        local image_attrs = parse_xml_attributes(image_attr_text)
        meta.imagewidth = tonumber(image_attrs.width)
        meta.imageheight = tonumber(image_attrs.height)
        if image_attrs.source then
            meta.image = resolve_source_file(image_attrs.source, tsx_dir)
        end
    end

    for tile_block in content:gmatch("<tile%s+.-</tile>") do
        local tile_attrs = parse_xml_attributes(tile_block:match("<tile%s+([^>]*)>") or "")
        local tile_id = tonumber(tile_attrs.id)
        if tile_id ~= nil then
            meta.tile_classes[tile_id] = tile_attrs.class or tile_attrs.type
            local props = {}
            local prop_block = tile_block:match("<properties>(.-)</properties>") or ""
            for attrs in prop_block:gmatch("<property%s+([^>]-)/>") do
                local p = parse_xml_attributes(attrs)
                if p.name then
                    local value = p.value
                    if p.type == "bool" then value = value == "true"
                    elseif p.type == "int" or p.type == "float" or p.type == "object" then value = tonumber(value) end
                    props[p.name] = value
                end
            end
            meta.tile_properties[tile_id] = props
            local tile_image_attrs = parse_xml_attributes(
                tile_block:match("<image%s+([^>/]-)/>") or tile_block:match("<image%s+([^>]*)>") or ""
            )
            if tile_image_attrs.source then
                local resolved = resolve_source_file(tile_image_attrs.source, tsx_dir)
                if resolved then
                    meta.tile_images[tile_id] = resolved
                end
            end

            local animation_block = tile_block:match("<animation>(.-)</animation>")
            local animation = parse_tile_animation_frames(animation_block)
            if animation then
                meta.tile_animations[tile_id] = animation
            end

            -- Per-tile collision shapes authored in Tiled's Tile Collision
            -- Editor (an <objectgroup> inside the <tile>). Kept in raw
            -- tile-local Tiled coords; converted to Defold hulls at bake time.
            local collision_shapes, collision_diagnostics = TileCollision.parse_tile_collision_shapes(tile_block)
            if collision_shapes then
                meta.tile_collision[tile_id] = collision_shapes
            end
            if collision_diagnostics then
                meta.tile_collision_diagnostics[tile_id] = collision_diagnostics
            end
        end
    end

    meta.collection = next(meta.tile_images) ~= nil
    local prefix = tsx_path .. "#"
    for key in pairs(TSX_META_CACHE) do
        if tostring(key):sub(1, #prefix) == prefix then
            TSX_META_CACHE[key] = nil
        end
    end
    TSX_META_CACHE[cache_key] = meta
    return meta
end

local function get_tileset_meta(tileset_entry, tiled_export_path)
    local map_dir = path_dirname(tiled_export_path)
    local meta = {
        tilewidth = tonumber(tileset_entry and tileset_entry.tilewidth),
        tileheight = tonumber(tileset_entry and tileset_entry.tileheight),
        tilecount = tonumber(tileset_entry and tileset_entry.tilecount),
        columns = tonumber(tileset_entry and tileset_entry.columns),
        spacing = tonumber(tileset_entry and tileset_entry.spacing),
        margin = tonumber(tileset_entry and tileset_entry.margin),
        image = nil,
        imagewidth = tonumber(tileset_entry and tileset_entry.imagewidth),
        imageheight = tonumber(tileset_entry and tileset_entry.imageheight),
        objectalignment = tileset_entry and tileset_entry.objectalignment,
        tile_properties = {},
        tile_classes = {},
        tile_images = {},
        tile_animations = {},
        tile_collision = {},
        tile_collision_diagnostics = {},
        collection = false,
        tsx_ref = nil,
        tsx_path = nil,
    }

    if type(tileset_entry) ~= "table" then
        return meta
    end

    if tileset_entry.image then
        meta.image = resolve_source_file(tileset_entry.image, map_dir)
    end

    if type(tileset_entry.tiles) == "table" then
        for _, tile in ipairs(tileset_entry.tiles) do
            local tile_id = tonumber(tile and tile.id)
            local tile_image = tile and tile.image
            if tile_id ~= nil then
                meta.tile_properties[tile_id] = require("mvtk.tiled.property_flattener").flatten(tile.properties or {})
                meta.tile_classes[tile_id] = tile.class or tile.type
            end
            if tile_id ~= nil and tile_image then
                local resolved = resolve_source_file(tile_image, map_dir)
                if resolved then
                    meta.tile_images[tile_id] = resolved
                end
            end

            local animation = parse_tile_animation_frames(tile and tile.animation)
            if tile_id ~= nil and animation then
                meta.tile_animations[tile_id] = animation
            end

            local collision_shapes, collision_diagnostics = TileCollision.parse_tile_collision_shapes_from_objectgroup(
                tile and tile.objectGroup
            )
            if tile_id ~= nil and collision_shapes then
                meta.tile_collision[tile_id] = collision_shapes
            end
            if tile_id ~= nil and collision_diagnostics then
                meta.tile_collision_diagnostics[tile_id] = collision_diagnostics
            end
        end
    end

    local tsx_ref = tileset_entry.filename or tileset_entry.source
    if tsx_ref and tsx_ref ~= "" then
        meta.tsx_ref = tsx_ref
        local tsx_path = resolve_source_file(tsx_ref, map_dir)
        meta.tsx_path = tsx_path
        if tsx_path then
            local tsx_meta = parse_tsx_tileset(tsx_path)
            if tsx_meta then
                if not meta.image then
                    meta.image = tsx_meta.image
                end
                if not meta.tilewidth then
                    meta.tilewidth = tsx_meta.tilewidth
                end
                if not meta.tileheight then
                    meta.tileheight = tsx_meta.tileheight
                end
                if not meta.tilecount then
                    meta.tilecount = tsx_meta.tilecount
                end
                if not meta.columns then
                    meta.columns = tsx_meta.columns
                end
                if not meta.spacing then
                    meta.spacing = tsx_meta.spacing
                end
                if not meta.margin then
                    meta.margin = tsx_meta.margin
                end
                if not meta.imagewidth then
                    meta.imagewidth = tsx_meta.imagewidth
                end
                if not meta.imageheight then
                    meta.imageheight = tsx_meta.imageheight
                end
                for tile_id, resolved in pairs(tsx_meta.tile_images or {}) do
                    if not meta.tile_images[tile_id] then
                        meta.tile_images[tile_id] = resolved
                    end
                end
                meta.objectalignment = meta.objectalignment or tsx_meta.objectalignment
                for tile_id, props in pairs(tsx_meta.tile_properties or {}) do
                    local merged = {}
                    for k,v in pairs(props) do merged[k]=v end
                    for k,v in pairs(meta.tile_properties[tile_id] or {}) do merged[k]=v end
                    meta.tile_properties[tile_id]=merged
                end
                for tile_id, kind in pairs(tsx_meta.tile_classes or {}) do
                    meta.tile_classes[tile_id] = meta.tile_classes[tile_id] or kind
                end
                for tile_id, animation in pairs(tsx_meta.tile_animations or {}) do
                    if not meta.tile_animations[tile_id] then
                        meta.tile_animations[tile_id] = animation
                    end
                end
                for tile_id, shapes in pairs(tsx_meta.tile_collision or {}) do
                    if not meta.tile_collision[tile_id] then
                        meta.tile_collision[tile_id] = shapes
                    end
                end
                for tile_id, diagnostics in pairs(tsx_meta.tile_collision_diagnostics or {}) do
                    if not meta.tile_collision_diagnostics[tile_id] then
                        meta.tile_collision_diagnostics[tile_id] = diagnostics
                    end
                end
            end
        else
            info(string.format(
                "tileset '%s' references '%s' which is not in the project; per-tile collision will be missing. Re-export this room from Tiled with the MVTK export action — it copies tilesets/images into the project automatically. As a last-resort fallback, copy its .tsx into developer/assets/tiled/tilesets/ and re-run Prepare & Check.",
                tostring(tileset_entry.name or "(unnamed)"),
                tostring(tsx_ref)
            ))
        end
    end

    meta.collection = next(meta.tile_images) ~= nil
    return meta
end

local function collect_collection_source_dirs(meta)
    local dirs = {}
    local seen = {}
    local function add_dir(dir)
        dir = normalize(dir or "")
        if dir == "" or seen[dir] then
            return
        end
        seen[dir] = true
        dirs[#dirs + 1] = dir
    end

    if type(meta) ~= "table" then
        return dirs
    end

    for _, image_path in pairs(meta.tile_images or {}) do
        add_dir(path_dirname(image_path))
    end
    add_dir(path_dirname(meta.image))
    add_dir(path_dirname(meta.tsx_path))

    -- Common local fallback folders used by this toolkit.
    add_dir(join(ROOT, "developer", "assets", "tiled", "backgrounds"))
    add_dir(join(ROOT, "assets", "tiled", "backgrounds"))

    return dirs
end

local function maybe_infer_missing_collection_tile_image(meta, local_tile_id, tileset_name, room_id, object_id)
    if type(meta) ~= "table" or meta.collection ~= true then
        return nil
    end
    local wanted = tonumber(local_tile_id)
    if wanted == nil or wanted < 0 then
        return nil
    end
    if meta.tile_images and meta.tile_images[wanted] then
        return meta.tile_images[wanted]
    end

    local max_id = -1
    local known_names = {}
    for tile_id, image_path in pairs(meta.tile_images or {}) do
        local n = tonumber(tile_id)
        if n and n > max_id then
            max_id = n
        end
        local base = path_basename(image_path or ""):lower()
        if base ~= "" then
            known_names[base] = true
        end
    end

    -- Only infer appended IDs (common stale-TSX scenario). We intentionally
    -- avoid guessing for gaps in the middle because that can remap art wrongly.
    if wanted <= max_id then
        return nil
    end

    local extras = {}
    local seen_extra = {}
    for _, dir in ipairs(collect_collection_source_dirs(meta)) do
        local _, files = list_dir_filesystem(dir)
        if files then
            for _, file in ipairs(files) do
                local lower = tostring(file):lower()
                if lower:match("%.png$") or lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.webp$") then
                    if not known_names[lower] then
                        local full = normalize(join(dir, file))
                        if file_exists_any(full) and not seen_extra[full] then
                            seen_extra[full] = true
                            extras[#extras + 1] = full
                        end
                    end
                end
            end
        end
    end

    if #extras == 0 then
        return nil
    end

    table.sort(extras, function(a, b)
        return path_basename(a):lower() < path_basename(b):lower()
    end)

    local next_id = max_id + 1
    for _, image_path in ipairs(extras) do
        if not meta.tile_images[next_id] then
            meta.tile_images[next_id] = image_path
        end
        if next_id == wanted then
            info(string.format(
                "background_visual: inferred missing collection tile id=%d for tileset '%s' using '%s' (room=%s object=%s)",
                tonumber(wanted) or -1,
                tostring(tileset_name or ""),
                tostring(image_path),
                tostring(room_id or ""),
                tostring(object_id or "")
            ))
            return image_path
        end
        next_id = next_id + 1
    end

    return nil
end

local function make_tilesource_text(image_resource, tile_width, tile_height, image_width, image_height, opts)
    local fallback_w, fallback_h = project_tile_size_defaults()
    local tw = tonumber(tile_width) or fallback_w
    local th = tonumber(tile_height) or fallback_h
    if tw <= 0 then tw = fallback_w end
    if th <= 0 then th = fallback_h end
    local collision_resource = resolve_tilesource_collision_resource(image_resource)
    local tile_count = resolve_tilesource_tile_count(tw, th, image_width, image_height, opts)

    local rows = {
        string.format('image: "%s"', tostring(image_resource)),
        string.format("tile_width: %d", tw),
        string.format("tile_height: %d", th),
        string.format('collision: "%s"', tostring(collision_resource)),
    }

    -- Defold tilesource tiles are 1-based; .tsx tile ids are 0-based, so a
    -- shaped .tsx tile id N maps to Defold tile id N+1.
    local shaped_defold_ids = {}
    if type(opts) == "table" and type(opts.tile_collision) == "table" then
        for tsx_id in pairs(opts.tile_collision) do
            shaped_defold_ids[(tonumber(tsx_id) or 0) + 1] = true
        end
    end
    append_default_tilesource_convex_hulls(rows, tile_count, shaped_defold_ids)
    rows[#rows + 1] = string.format('collision_groups: "%s"', STANDARD_TILE_COLLISION_GROUP)

    -- Required animation block and border extrusion
    rows[#rows + 1] = "animations {"
    rows[#rows + 1] = '  id: "anim"'
    rows[#rows + 1] = "  start_tile: 1"
    rows[#rows + 1] = "  end_tile: 1"
    rows[#rows + 1] = "}"
    rows[#rows + 1] = "extrude_borders: 2"
    rows[#rows + 1] = ""
    return table.concat(rows, "\n")
end

local function tilesource_matches_grid(
    content, image_resource, collision_resource, tile_width, tile_height, tile_count
)
    if type(content) ~= "string" or content == "" then
        return false
    end
    local expected_width = positive_integer(tile_width)
    local expected_height = positive_integer(tile_height)
    local expected_count = positive_integer(tile_count)
    if not expected_width or not expected_height or not expected_count then
        return false
    end

    -- Parse complete scalar lines instead of searching numeric substrings.
    -- A plain search for `tile_width: 64`, for example, also matches 640 and
    -- would incorrectly preserve hull geometry for a changed grid.
    local padded = "\n" .. content .. "\n"
    local parsed_image = padded:match('\n[ \t]*image[ \t]*:[ \t]*"([^"\r\n]*)"[ \t]*\r?\n')
    local parsed_collision = padded:match('\n[ \t]*collision[ \t]*:[ \t]*"([^"\r\n]*)"[ \t]*\r?\n')
    local parsed_width = tonumber(padded:match(
        "\n[ \t]*tile_width[ \t]*:[ \t]*([+-]?%d+)[ \t]*\r?\n"
    ))
    local parsed_height = tonumber(padded:match(
        "\n[ \t]*tile_height[ \t]*:[ \t]*([+-]?%d+)[ \t]*\r?\n"
    ))
    local parsed_group = padded:match(
        '\n[ \t]*collision_groups[ \t]*:[ \t]*"([^"\r\n]*)"[ \t]*\r?\n'
    )
    if parsed_image ~= tostring(image_resource)
        or parsed_collision ~= tostring(collision_resource)
        or parsed_width ~= expected_width
        or parsed_height ~= expected_height
        or parsed_group ~= STANDARD_TILE_COLLISION_GROUP
    then
        return false
    end

    local hull_count = 0
    for _ in content:gmatch("convex_hulls%s*{") do
        hull_count = hull_count + 1
    end
    return hull_count == expected_count
end

local function count_non_four_point_hulls(content)
    if type(content) ~= "string" or content == "" then
        return 0, 0
    end

    local non_four_count = 0
    local hull_count = 0
    for block in content:gmatch("convex_hulls%s*{(.-)}") do
        local point_count = tonumber(block:match("count%s*:%s*([+-]?%d+)"))
        if point_count ~= nil then
            hull_count = hull_count + 1
            if point_count ~= 4 then
                non_four_count = non_four_count + 1
            end
        end
    end
    return non_four_count, hull_count
end

local function ensure_tilesource_from_tiled(room_id, tiled_data, tiled_export_path, primary_tileset, asset_name_override)
    if type(primary_tileset) ~= "table" then
        return nil, "missing_primary_tileset"
    end

    local tileset_name = tostring(primary_tileset.name or "")
    local asset_base
    if asset_name_override then
        asset_base = sanitize_asset_name(asset_name_override, asset_name_override)
    else
        local biome_name = get_tiled_property(tiled_data and tiled_data.properties, "biome")
        asset_base = sanitize_asset_name(biome_name or tileset_name or room_id, room_id or "tiles")
    end

    local meta = get_tileset_meta(primary_tileset, tiled_export_path)
    local source_image = meta.image
    if not source_image then
        local image_candidates = {
            join(ROOT, "developer", "assets", "tilesheets", asset_base .. ".png"),
            join(ROOT, "developer", "assets", "tilesheets", tileset_name .. ".png"),
            join(ROOT, "developer", "assets", "tilesheets", asset_base .. ".jpg"),
            join(ROOT, "developer", "assets", "tilesheets", tileset_name .. ".jpg"),
        }
        for _, candidate in ipairs(image_candidates) do
            if file_exists_any(candidate) then
                source_image = candidate
                break
            end
        end
    end
    if not source_image then
        return nil, "no_tilesheet_image"
    end

    local ext = path_basename(source_image):match("(%.[^%.]+)$") or ".png"
    ext = ext:lower()
    if ext == "" then ext = ".png" end

    local image_file = asset_base .. ext
    local image_resource = "/developer/assets/tilesheets/" .. image_file
    local image_abs = join(ROOT, "developer", "assets", "tilesheets", image_file)
    local tilesource_resource = "/developer/assets/tilesheets/" .. asset_base .. ".tilesource"
    local tilesource_abs = join(ROOT, "developer", "assets", "tilesheets", asset_base .. ".tilesource")

    if not copy_file_any(source_image, image_abs) then
        return nil, "cannot_copy_tilesheet_image"
    end
    if normalize(source_image) ~= normalize(image_abs) then
        local receipt = TiledSourceSafety.receipt_for_copy(
            source_image, image_abs, ROOT, file_utils.read_binary_any)
        if receipt then write_if_changed(image_abs .. ".mvtk-source", receipt) end
    end
    info("update_tilemap_tilesource: copied tilesheet for '" .. tostring(room_id) .. "' to " .. tostring(image_abs))

    local fallback_w, fallback_h = project_tile_size_defaults()
    local tile_width = tonumber(meta.tilewidth) or tonumber(tiled_data and tiled_data.tilewidth) or fallback_w
    local tile_height = tonumber(meta.tileheight) or tonumber(tiled_data and tiled_data.tileheight) or tile_width
    if tile_width <= 0 then tile_width = fallback_w end
    if tile_height <= 0 then tile_height = tile_width end

    local img_w, img_h = get_png_dimensions(image_abs)
    if img_w and img_h and ((img_w % tile_width) ~= 0 or (img_h % tile_height) ~= 0) then
        info(string.format(
            "update_tilemap_tilesource: WARNING tilesheet '%s' size %dx%d is not divisible by tile size %dx%d",
            tostring(image_abs), img_w, img_h, tile_width, tile_height
        ))
    end

    local tile_count = resolve_tilesource_tile_count(tile_width, tile_height, img_w, img_h, meta)
    local collision_resource = resolve_tilesource_collision_resource(image_resource)
    local existing_tilesource = read_text_any(tilesource_abs)
    local wrote_tilesource = false
    if tilesource_matches_grid(
        existing_tilesource,
        image_resource,
        collision_resource,
        tile_width,
        tile_height,
        tile_count
    ) then
        -- Defold serializes image-derived convex hull geometry into this file.
        -- Replacing a valid existing resource with make_tilesource_text's
        -- rectangular bootstrap hulls destroys that geometry on every import.
        info("update_tilemap_tilesource: retained existing collision hulls in " .. tostring(tilesource_abs))
    else
        local tilesource_text = make_tilesource_text(image_resource, tile_width, tile_height, img_w, img_h, meta)
        if type(existing_tilesource) == "string" and existing_tilesource:find("%S") then
            local bootstrap_abs = tilesource_abs .. ".bootstrap"
            write_if_changed(bootstrap_abs, tilesource_text)
            local non_four_count, hull_count = count_non_four_point_hulls(existing_tilesource)
            info(string.format(
                "update_tilemap_tilesource: WARNING preserved nonempty existing tilesource %s " ..
                "(%d hull records, %d with count other than 4); proposed replacement written to %s. " ..
                "Review both files. Delete the original and rerun Prepare & Check only when replacement is intentional.",
                tostring(tilesource_abs),
                hull_count,
                non_four_count,
                tostring(bootstrap_abs)
            ))
        else
            wrote_tilesource = write_if_changed(tilesource_abs, tilesource_text)
            if wrote_tilesource then
                info("update_tilemap_tilesource: created tilesource " .. tostring(tilesource_abs))
            end
        end
    end

    if TilesetMapping and TilesetMapping.refresh_discovered then
        TilesetMapping.refresh_discovered()
    end

    -- Register the EXACT authored tileset name -> tilesource so resolution by
    -- name is guaranteed even when the generated filename (derived from biome or
    -- a sanitized name) differs from the Tiled tileset name.
    if TilesetMapping and TilesetMapping.register and tileset_name ~= "" then
        TilesetMapping.register(tileset_name, tilesource_resource)
    end

    return tilesource_resource, nil
end

-- Map Tiled tileset names to Defold tilesource paths (config + discovery)
local function resolve_tilesource(tileset_name)
    if not tileset_name or tileset_name == "" then
        return nil, "no tileset name in Tiled export"
    end
    local ts = nil
    if TilesetMapping and TilesetMapping.get_tilesource then
        ts = TilesetMapping.get_tilesource(tileset_name)
        if not ts and TilesetMapping.refresh_discovered then
            TilesetMapping.refresh_discovered()
            ts = TilesetMapping.get_tilesource(tileset_name)
        end
    end
    if ts then
        return ts, nil
    end
    return nil, "unmapped"
end

-- Ensure a .tilesource exists (and is name-registered) for EVERY single-image
-- tileset a room references -- not just the painted "primary" tileset that the
-- .tilemap points at. This covers tilesets used only by scenery "picture
-- objects" on object layers, which otherwise never get a tilesource and fail
-- background_visual tile extraction with "unmapped".
--
-- Collection (image-of-images) tilesets are skipped: they have per-tile images
-- and are handled as atlases, not single-image tilesources. Failures on a
-- secondary tileset are logged but never fatal -- the painted primary must
-- still relink even if one scenery tileset is missing its image.
local function ensure_room_tilesources(room_id, tiled_data, tiled_export_path)
    if type(tiled_data) ~= "table" or type(tiled_data.tilesets) ~= "table" then
        return
    end
    for _, ts in ipairs(tiled_data.tilesets) do
        if type(ts) == "table" then
            local name = tostring(ts.name or "")
            if name ~= "" then
                local meta = get_tileset_meta(ts, tiled_export_path)
                -- A single-image (grid) tileset resolves to a sheet image;
                -- collections do not.
                if meta and meta.collection == true then
                    info("ensure_room_tilesources: skipped image collection '" .. name .. "'")
                elseif meta and meta.image then
                    local existing = resolve_tilesource(name)
                    local needs = true
                    if existing then
                        -- single-local assign drops gsub()'s count return (else
                        -- join() would tack a stray "/1" onto the path).
                        local rel = existing:gsub("^/", "")
                        local abs = normalize(join(ROOT, rel))
                        needs = not file_exists_any(abs)
                    end
                    if needs then
                        local res, err = ensure_tilesource_from_tiled(
                            room_id, tiled_data, tiled_export_path, ts, name
                        )
                        if not res then
                            info("ensure_room_tilesources: could not build tilesource for tileset '"
                                .. name .. "' in room " .. tostring(room_id)
                                .. " (" .. tostring(err) .. ")")
                        end
                    end
                end
            end
        end
    end
end

-- Remove only receipted leftovers from the old collection-as-sheet importer.
-- Search every project resource before deleting; unreadable resources keep the
-- candidate. Ignored folders (including disposable projects) are not resources.
local function cleanup_collection_tilesources(room_ids)
    local candidates = {}
    for _, room_id in ipairs(room_ids or {}) do
        local data, export_path = load_tiled_export(room_id)
        for _, ts in ipairs(data and data.tilesets or {}) do
            local meta = get_tileset_meta(ts, export_path)
            if meta.collection == true and ts.name and ts.name ~= "" then
                local name = sanitize_asset_name(ts.name, ts.name)
                candidates[name] = "/developer/assets/tilesheets/" .. name .. ".tilesource"
            end
        end
    end
    if next(candidates) == nil then return 0 end
    -- Most imports have no historical junk. Avoid scanning all resources when
    -- none of these candidates has anything to clean up.
    local has_candidates = false
    for name in pairs(candidates) do
        local base = join(ROOT, "developer/assets/tilesheets", name)
        if file_exists_any(base .. ".png") or file_exists_any(base .. ".tilesource")
            or Transaction.read(base .. ".png.mvtk-source") ~= nil then
            has_candidates = true
            break
        end
    end
    if not has_candidates then return 0 end

    local ignored = {}
    for line in (read_text_any(join(ROOT, ".defignore")) or ""):gmatch("[^\r\n]+") do
        local entry = line:match("^%s*(/[^%s]+)")
        if entry and not entry:find("*", 1, true) then
            ignored[#ignored + 1] = entry:gsub("/$", "")
        end
    end
    local function skip(relative)
        if relative:match("/%.") then return true end
        for _, entry in ipairs(ignored) do
            if relative == entry or relative:sub(1, #entry + 1) == entry .. "/" then return true end
        end
        return false
    end
    local referenced, scan_ok = {}, true
    local function scan(relative)
        -- Parentheses discard gsub's second return (replacement count), which
        -- otherwise becomes an extra segment passed to variadic join.
        local dirs, files = list_dir_filesystem(join(ROOT, (relative:gsub("^/", ""))))
        if not dirs or not files then
            -- The shared listing helper returns nil for empty directories too.
            -- Confirm an empty editor resource directory before treating it as
            -- scanned; an unavailable listing must keep all candidates.
            local resource_dir = relative ~= "" and relative or "/"
            if editor and editor.can_get and editor.can_get(resource_dir, "children") then
                local children = editor.get(resource_dir, "children")
                if type(children) == "table" and next(children) == nil then return end
            end
            scan_ok = false
            return
        end
        for _, filename in ipairs(files) do
            local resource = relative .. "/" .. filename
            local disk_path = join(ROOT, (resource:gsub("^/", "")))
            local is_directory = false
            if editor and editor.external_file_attributes then
                -- LuaJ's shared listing helper infers file/directory from the
                -- name when lfs is absent. Dotted folders must still be scanned.
                local ok, attributes = pcall(editor.external_file_attributes, disk_path)
                if not ok then scan_ok = false
                else is_directory = attributes.is_directory == true end
            end
            if is_directory then
                if not skip(resource) then scan(resource) end
            elseif filename:match("%.tilemap$") or filename:match("%.go$") or filename:match("%.collection$") then
                local content = read_text_any(disk_path)
                if content == nil then scan_ok = false end
                for name, tilesource in pairs(candidates) do
                    if content and content:find(tilesource, 1, true) then referenced[name] = resource end
                end
            end
        end
        for _, dirname in ipairs(dirs) do
            local child = relative .. "/" .. dirname
            if not skip(child) then scan(child) end
        end
    end
    scan("")
    local removed = 0
    for name in pairs(candidates) do
        local base = join(ROOT, "developer/assets/tilesheets", name)
        local receipt = Transaction.read(base .. ".png.mvtk-source")
        local has_junk = receipt ~= nil or file_exists_any(base .. ".png") or file_exists_any(base .. ".tilesource")
        if has_junk then
            if not scan_ok or referenced[name] or receipt == nil then
                info("collection tileset '" .. name .. "': kept old sheet files ("
                    .. (not scan_ok and "resource scan incomplete" or referenced[name] and
                        ("referenced by " .. referenced[name]) or "no source receipt") .. ")")
            else
                -- Transaction.remove reads the path back; LuaJ may report a
                -- falsy os.remove result even after successfully deleting it.
                Transaction.remove(base .. ".tilesource")
                Transaction.remove(base .. ".png")
                Transaction.remove(base .. ".png.mvtk-source")
                removed = removed + 1
                info("collection tileset '" .. name .. "': removed receipted sheet leftovers")
            end
        end
    end
    return removed
end

-- Update tilemap file with correct tilesource
local function update_tilemap_tilesource(room_id)
    local tilemap_path = join(PATH.tilemaps, room_id .. ".tilemap")
    local tilemap_content = read_text(tilemap_path)
    if not tilemap_content then
        info("update_tilemap_tilesource: tilemap not found: " .. tilemap_path)
        return false
    end

    local tiled_data, tiled_export_path_or_err = load_tiled_export(room_id)
    if not tiled_data then
        info("update_tilemap_tilesource: failed to load Tiled export for " .. room_id .. ": " .. tostring(tiled_export_path_or_err))
        return false, "load_failed"
    end

    local primary_tileset = TilesetSelection.select_primary_tileset(tiled_data, get_tiled_property)
    if not primary_tileset then
        info("update_tilemap_tilesource: no tileset found in Tiled export for " .. room_id)
        return false, "no_tileset"
    end

    local tileset_name = tostring(primary_tileset.name or "")
    if tileset_name == "" then
        info("update_tilemap_tilesource: primary tileset has no name in Tiled export for " .. room_id)
        return false, "no_tileset_name"
    end

    -- Map to Defold tilesource
    local tilesource = resolve_tilesource(tileset_name)

    -- Even when the mapping exists, the tilesource file may have been deleted
    -- (e.g. after a destructive project reset). Re-create it when missing.
    if tilesource then
        local ts_rel = tilesource:gsub("^/", "")
        local ts_abs = normalize(join(ROOT, ts_rel))
        if not file_exists_any(ts_abs) then
            info("update_tilemap_tilesource: mapped tilesource missing on disk, re-creating: " .. tostring(tilesource))
            local recreated, recreate_err = ensure_tilesource_from_tiled(
                room_id,
                tiled_data,
                tiled_export_path_or_err,
                primary_tileset
            )
            if recreated then
                tilesource = recreated
            else
                info("update_tilemap_tilesource: re-create failed (" .. tostring(recreate_err) .. "), clearing mapping")
                tilesource = nil
            end
        end
    end

    if not tilesource then
        local auto_tilesource, auto_err = ensure_tilesource_from_tiled(
            room_id,
            tiled_data,
            tiled_export_path_or_err,
            primary_tileset
        )
        if auto_tilesource then
            tilesource = auto_tilesource
        else
            info("update_tilemap_tilesource: tileset '" .. tostring(tileset_name) .. "' is not mapped and auto-import failed (" .. tostring(auto_err) .. "); see developer/config/tileset_mapping.lua")
            -- Encode the auto-import failure reason after a \1 delimiter so the
            -- caller can give an actionable message (missing image vs missing
            -- mapping are different problems with different fixes).
            return false, "unmapped:" .. tostring(tileset_name) .. "\1" .. tostring(auto_err or "no_mapping")
        end
    end
    info("update_tilemap_tilesource: " .. room_id .. " -> tileset '" .. tileset_name .. "' -> " .. tilesource)

    -- Ensure tilesources for every OTHER single-image tileset in this room
    -- (scenery picture-object tilesets that are not the painted primary). The
    -- primary was just resolved/registered above, so it is skipped as already
    -- present. Non-fatal: a failure here must not break the primary relink.
    pcall(ensure_room_tilesources, room_id, tiled_data, tiled_export_path_or_err)

    -- Check if tilesource needs updating
    local current_tilesource = tilemap_content:match('tile_set:%s*"([^"]*)"')
    if current_tilesource == tilesource then
        -- Already correct
        return true
    end

    -- Update tile_set line. If no line exists, add one.
    local updated_content = tilemap_content
    if updated_content:find('tile_set:%s*"') then
        updated_content = updated_content:gsub(
            'tile_set:%s*"[^"]*"',
            'tile_set: "' .. tilesource .. '"',
            1
        )
    else
        updated_content = 'tile_set: "' .. tilesource .. '"\n' .. updated_content
    end

    -- Preparation stages regenerated tilemaps until collection baking finishes.
    -- Use the same writer so later readers see the relink instead of the older
    -- staged copy, and the final flush cannot overwrite it with that copy.
    write_if_changed(tilemap_path, updated_content)

    info("update_tilemap_tilesource: updated " .. room_id .. " from '" .. (current_tilesource or "") .. "' to '" .. tilesource .. "'")
    return true
end

-- Bundled toolkit prefab tilemaps (pushable block, moving platform) ship with a
-- hardcoded sample tilesource (sample_tileset.tilesource), which lives in
-- developer/assets/tilesheets/ -- the folder "Reset Project to Empty" wipes. They
-- have no Tiled export, so the per-room relink above never touches them. Whenever
-- a room tilesource exists we re-point them at it here so Create Rooms / Import
-- Assets leave a project that compiles. NOTE: this cannot heal a *bare* reset
-- (no tilesource on disk at all) -- that state only builds again after the user
-- re-imports art; see pick_prefab_tilesource's nil return.
local PREFAB_TILEMAPS = {
    "/developer/game/prefabs/pushable_tile_chunk.tilemap",
    "/developer/game/prefabs/tile_moving_platform.tilemap",
}

local function tilesource_resource_to_abs(resource_path)
    -- Assign gsub() to a single local so its replacement-count second return
    -- value is dropped; passing it straight into join(...) would append a stray
    -- "/1" path segment and break every existence/read check on the result.
    local rel = tostring(resource_path or ""):gsub("^/", "")
    return normalize(join(ROOT, rel))
end

local function tilesource_resource_exists(resource_path)
    if not resource_path or resource_path == "" then return false end
    return file_exists_any(tilesource_resource_to_abs(resource_path))
end

-- Pick the tilesource to point the prefab tilemaps at: prefer the one the
-- user's rooms resolved to (so prefabs match the user's art), falling back to
-- any .tilesource present under developer/assets/tilesheets/. Returns nil only
-- when the project has no tilesource on disk at all (a truly empty project,
-- which would not build regardless).
local function pick_prefab_tilesource(room_ids)
    -- 1) Most common existing tilesource across the generated room tilemaps.
    local counts, order = {}, {}
    for _, room_id in ipairs(room_ids or {}) do
        local content = read_text(join(PATH.tilemaps, room_id .. ".tilemap"))
        if content then
            local ts = content:match('tile_set:%s*"([^"]*)"')
            if ts and ts ~= "" and tilesource_resource_exists(ts) then
                if not counts[ts] then
                    order[#order + 1] = ts
                    counts[ts] = 0
                end
                counts[ts] = counts[ts] + 1
            end
        end
    end
    local best, best_n
    for _, ts in ipairs(order) do
        if not best_n or counts[ts] > best_n then best, best_n = ts, counts[ts] end
    end
    if best then return best end

    -- 2) Any tilesource present in the tilesheets folder (deterministic order).
    local dir = normalize(join(ROOT, "developer/assets/tilesheets"))
    local _, files = list_dir_filesystem(dir)
    local candidates = {}
    for _, name in ipairs(files or {}) do
        if tostring(name):match("%.tilesource$") then
            candidates[#candidates + 1] = "/developer/assets/tilesheets/" .. name
        end
    end
    table.sort(candidates)
    return candidates[1]
end

-- Re-point the bundled prefab tilemaps at a tilesource that exists on disk so
-- Create Rooms / Import Assets always leave a project that compiles, even right
-- after a destructive reset. Idempotent: only writes when the tile_set changes.
local function relink_prefab_tilemaps(room_ids)
    local target = pick_prefab_tilesource(room_ids)
    local healed = {}
    for _, resource in ipairs(PREFAB_TILEMAPS) do
        local abs = tilesource_resource_to_abs(resource)
        local content = read_text(abs)
        if content then
            local current = content:match('tile_set:%s*"([^"]*)"')
            if not target then
                if not (current and tilesource_resource_exists(current)) then
                    info("relink_prefab_tilemaps: " .. resource .. " points at missing tilesource '"
                        .. tostring(current) .. "' and no existing tilesource was found to heal it")
                end
            elseif current ~= target then
                local updated
                if content:find('tile_set:%s*"') then
                    updated = content:gsub('tile_set:%s*"[^"]*"', 'tile_set: "' .. target .. '"', 1)
                else
                    updated = 'tile_set: "' .. target .. '"\n' .. content
                end
                if write_if_changed(abs, updated) then
                    healed[#healed + 1] = resource
                    info("relink_prefab_tilemaps: " .. resource .. " '" .. tostring(current)
                        .. "' -> '" .. target .. "'")
                end
            end
        end
    end
    if #healed > 0 then
        info("relink_prefab_tilemaps: re-pointed " .. #healed .. " prefab tilemap(s) -> " .. tostring(target))
    end
    return healed, target
end

-- Update all tilemaps with correct tilesources
local function update_all_tilemap_tilesources(room_ids)
    local updated_count = 0
    local unmapped = {}
    local failed = {}
    for _, room_id in ipairs(room_ids) do
        local ok_call, ok, err = pcall(update_tilemap_tilesource, room_id)
        if not ok_call then
            info("update_all_tilemap_tilesources: failed room '" .. tostring(room_id) .. "': " .. tostring(ok))
            failed[#failed + 1] = tostring(room_id)
        elseif ok then
            updated_count = updated_count + 1
        elseif err and type(err) == "string" and err:match("^unmapped:") then
            local ts, reason = err:match("^unmapped:([^\1]*)\1?(.*)$")
            unmapped[#unmapped + 1] = {
                room_id = room_id,
                tileset = (ts and ts ~= "") and ts or "?",
                reason = (reason and reason ~= "") and reason or "no_mapping",
            }
        end
    end

    if #unmapped > 0 then
        local unresolved = {}
        for _, entry in ipairs(unmapped) do
            local tileset_name = entry.tileset or "?"
            local tilesource = resolve_tilesource(tileset_name)
            local tilesource_exists = false
            if tilesource then
                -- single-local assign drops gsub()'s count return (else join()
                -- would tack a stray "/1" onto the path).
                local rel = tilesource:gsub("^/", "")
                local ts_abs = normalize(join(ROOT, rel))
                tilesource_exists = file_exists_any(ts_abs)
            end

            -- A shared tilesource may be created by a later room after an
            -- earlier room reports the mapping as unavailable. Re-try those
            -- delayed rooms once all rooms have had a chance to auto-import.
            if tilesource_exists then
                local ok_retry_call, ok_retry, retry_err = pcall(update_tilemap_tilesource, entry.room_id)
                if ok_retry_call and ok_retry then
                    updated_count = updated_count + 1
                    info("[TILESET_MAPPING] Resolved delayed tileset '" .. tostring(tileset_name) .. "' for room " .. tostring(entry.room_id))
                elseif ok_retry_call and retry_err and type(retry_err) == "string" and retry_err:match("^unmapped:") then
                    unresolved[tileset_name] = entry.reason or "no_mapping"
                else
                    info("update_all_tilemap_tilesources: retry failed room '" .. tostring(entry.room_id) .. "': " .. tostring(ok_retry_call and retry_err or ok_retry))
                    failed[#failed + 1] = tostring(entry.room_id)
                end
            else
                unresolved[tileset_name] = entry.reason or "no_mapping"
            end
        end

        local names = {}
        for name, _ in pairs(unresolved) do names[#names + 1] = name end
        if #names > 0 then
            table.sort(names)
            -- A missing tilesheet image and a missing mapping entry are
            -- different problems with different fixes.  Split the unresolved
            -- tilesets by reason so the message points at the real cause.
            local image_missing, mapping_missing = {}, {}
            for _, name in ipairs(names) do
                local reason = unresolved[name]
                if reason == "no_tilesheet_image"
                    or reason == "cannot_copy_tilesheet_image"
                    or reason == "missing_primary_tileset" then
                    image_missing[#image_missing + 1] = name
                else
                    mapping_missing[#mapping_missing + 1] = name
                end
            end

            info("[TILESET_MAPPING] ERROR: Unresolved tilesets: " .. table.concat(names, ", "))
            local hints = {}
            if #image_missing > 0 then
                local msg = "No tilesheet image found for: " .. table.concat(image_missing, ", ")
                    .. ". Re-export this room from Tiled with the MVTK export action — it copies"
                    .. " tilesets/images into the project automatically. As a last-resort fallback, place each"
                    .. " tileset's .tsx in developer/assets/tiled/tilesets/ and its PNG in"
                    .. " developer/assets/tilesheets/ (or embed the image in the .tsx), then re-run Prepare & Check."
                info("[TILESET_MAPPING] " .. msg)
                hints[#hints + 1] = msg
            end
            if #mapping_missing > 0 then
                local msg = "No tilesource mapping for: " .. table.concat(mapping_missing, ", ")
                    .. ". Add a mapping in developer/config/tileset_mapping.lua or place a matching"
                    .. " .tilesource in developer/assets/tilesheets/."
                info("[TILESET_MAPPING] " .. msg)
                hints[#hints + 1] = msg
            end
            error(table.concat(hints, " "))
        end
    end
    if #failed > 0 then
        error("Tileset update failed for rooms: " .. table.concat(failed, ", "))
    end

    -- Heal the bundled prefab tilemaps so the project still compiles after a
    -- destructive reset wiped their hardcoded sample tilesource. Non-fatal: a
    -- prefab relink failure must never break room generation.
    pcall(relink_prefab_tilemaps, room_ids)

    local ok_sync, sync_result = pcall(TileSettingsWriter.write_project_settings_from_art, {
        root = ROOT,
        room_ids = room_ids,
        maps_dir = PATH.tilemaps,
        tilemaps_dir = PATH.tilemaps,
        tilesheets_dir = join(ROOT, "developer", "assets", "tilesheets"),
        tile_settings_path = join(ROOT, "developer", "config", "tile_settings.lua"),
        write_if_changed = write_if_changed,
        generator = "Import Assets",
    })
    if not ok_sync then
        info("update_all_tilemap_tilesources: WARNING failed to sync tile_settings.lua from art: " .. tostring(sync_result))
    elseif sync_result then
        for _, line in ipairs(TileSettingsWriter.format_validation_messages(sync_result)) do
            info("update_all_tilemap_tilesources: WARNING tile-size consistency: " .. tostring(line))
        end
        if sync_result.primary and package and package.loaded then
            package.loaded["developer.config.tile_settings"] = nil
        end
        if sync_result.changed and sync_result.primary then
            info(string.format(
                "update_all_tilemap_tilesources: synced tile_settings.lua to %dx%d from %s",
                tonumber(sync_result.primary.width) or 0,
                tonumber(sync_result.primary.height) or 0,
                tostring(sync_result.primary.source or "tilesource art")
            ))
        end
    end

    info("update_all_tilemap_tilesources: processed " .. updated_count .. " / " .. #room_ids .. " rooms")
end

-- Format a number as a Defold float literal (always with a decimal point).
local function fmt_float(n)
    n = tonumber(n) or 0
    if n == math.floor(n) then
        return string.format("%d.0", n)
    end
    return tostring(n)
end

-- Bake per-tile collision (authored in Tiled's Tile Collision Editor) into a
-- STATIC collisionobject for a room. Reads the already-generated <rid>.tilemap
-- (whose `cell` entries carry the Defold cell coords and 0-based local tile id)
-- and, for every cell whose tile has authored shapes, emits a convex-hull shape
-- positioned at that cell's center -- in the same local space as the tilemap
-- component, so it aligns exactly.
--
-- Returns the embedded_components text to append to the level.go, or "" when
-- the room has no shaped tiles. Never throws: any failure yields "" so the
-- level.go still builds (mirrors the rest of this module's non-fatal posture).
-- Defold forbids hull shapes inside an embedded_collision_shape (only box /
-- sphere / capsule embed; hulls must be a separate .convexshape resource, and a
-- collisionobject references exactly one shape). Defold ALSO ignores a
-- component-level position on a convexshape-based collisionobject, so the world
-- placement is baked into the hull points themselves (room-local absolute), and
-- the collisionobject is left at the origin -- exactly like the tilemap
-- collisionobject, which sits at origin and gets its placement from cell data.
-- That means points differ per cell, so each cell gets its own .convexshape.
local function write_convexshape_file(fname, pts)
    local lines = { "shape_type: TYPE_HULL" }
    for _, p in ipairs(pts) do
        lines[#lines + 1] = "data: " .. fmt_float(p.x)
        lines[#lines + 1] = "data: " .. fmt_float(p.y)
        lines[#lines + 1] = "data: 0.0"
    end
    write_if_changed(join(PATH.generated_go, fname), table.concat(lines, "\n") .. "\n")
    return "/developer/rooms/generated/" .. fname
end

local function write_tile_convexshape(rid, cx, cy, idx, pts)
    return write_convexshape_file(string.format("%s_tilecol_%d_%d_%d.convexshape", rid, cx, cy, idx), pts)
end

-- One STATIC "solid" collisionobject block referencing a baked .convexshape.
local function tile_collisionobject_block(id, resource)
    local L = {}
    local function add(s) L[#L + 1] = s end
    add('embedded_components {')
    add(string.format('  id: "tilecol_%d"', id))
    add('  type: "collisionobject"')
    add(string.format('  data: "collision_shape: \\"%s\\"\\n"', resource))
    add('  "type: COLLISION_OBJECT_TYPE_STATIC\\n"')
    add('  "mass: 0.0\\n"')
    add('  "friction: 0.1\\n"')
    add('  "restitution: 0.0\\n"')
    add('  "group: \\"solid\\"\\n"')
    add('  "mask: \\"player\\"\\n"')
    add('  "mask: \\"enemy\\"\\n"')
    add('  ""')
    add('}')
    return table.concat(L, '\n')
end

local function sorted_numeric_keys(map)
    local keys = {}
    for key in pairs(map or {}) do
        keys[#keys + 1] = tonumber(key) or key
    end
    table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
    return keys
end

local function count_keys(map)
    local n = 0
    for _ in pairs(map or {}) do
        n = n + 1
    end
    return n
end

local function format_tile_id_counts(counts, max_ids)
    max_ids = tonumber(max_ids) or 12
    local ids = sorted_numeric_keys(counts)
    if #ids == 0 then
        return "none"
    end
    local parts = {}
    local total = 0
    for _, id in ipairs(ids) do
        total = total + (tonumber(counts[id]) or 0)
    end
    for i = 1, math.min(#ids, max_ids) do
        local id = ids[i]
        parts[#parts + 1] = tostring(id) .. "x" .. tostring(counts[id])
    end
    if #ids > max_ids then
        parts[#parts + 1] = "..." .. tostring(#ids - max_ids) .. " more"
    end
    return table.concat(parts, ", ") .. " (" .. tostring(total) .. " cell(s))"
end

local function diagnostic_reasons(diagnostics)
    local reasons = {}
    for _, diag in ipairs(diagnostics or {}) do
        local message = diag and diag.message
        if message and message ~= "" then
            reasons[#reasons + 1] = tostring(message)
        elseif diag and diag.kind then
            reasons[#reasons + 1] = tostring(diag.kind)
        end
    end
    if #reasons == 0 then
        return "no supported collision shapes"
    end
    return table.concat(reasons, "; ")
end

local function emit_tile_collision_diagnostics(rid, meta, painted_counts)
    local emitted = {}
    for _, tid in ipairs(sorted_numeric_keys(painted_counts)) do
        local diagnostics = meta and meta.tile_collision_diagnostics and meta.tile_collision_diagnostics[tid]
        if diagnostics then
            local has_shapes = meta and meta.tile_collision and meta.tile_collision[tid] ~= nil
            if not has_shapes then
                info(string.format(
                    "gen_room_tile_collision: WARNING room '%s' tile id=%s has a collision objectgroup but 0 parsed shapes (%s)",
                    tostring(rid), tostring(tid), diagnostic_reasons(diagnostics)))
            end
            for _, diag in ipairs(diagnostics) do
                local kind = diag and diag.kind
                local key = tostring(tid) .. "|" .. tostring(kind)
                if kind and not emitted[key] then
                    emitted[key] = true
                    if kind == "polyline_auto_closed" or kind == "ellipse_approximated" then
                        info(string.format(
                            "gen_room_tile_collision: room '%s' tile id=%s: %s",
                            tostring(rid), tostring(tid), tostring(diag.message or kind)))
                    end
                end
            end
        end
    end
end

local function gen_room_tile_collision(rid)
    local ok, result = pcall(function()
        local tiled_data, export_path = load_tiled_export(rid)
        if not tiled_data then return "" end

        local primary = TilesetSelection.select_primary_tileset(tiled_data, get_tiled_property)
        if not primary then return "" end

        local meta = get_tileset_meta(primary, export_path)
        local tilemap_text = read_text(join(PATH.tilemaps, rid .. ".tilemap"))
        if not tilemap_text then return "" end

        local fallback_w, fallback_h = project_tile_size_defaults()
        local tw = tonumber(meta and meta.tilewidth) or tonumber(tiled_data.tilewidth) or fallback_w
        local th = tonumber(meta and meta.tileheight) or tonumber(tiled_data.tileheight) or tw
        if tw <= 0 then tw = fallback_w end
        if th <= 0 then th = tw end

        local known_types = TiledObjects.load_object_type_set()
        local platform_rects = TiledObjects.collect_tile_copy_platform_rects(tiled_data, known_types)
        local excluded = TiledObjects.tile_copy_platform_cell_exclusions(tiled_data, platform_rects, tw, th)

        -- Pass 1: classify every shaped cell. A cell whose tile carries a
        -- full-cell rectangle is "full solid" and can be merged with its
        -- neighbours into a single collider; anything else (slopes, blobs,
        -- partial shapes) keeps a precise per-cell hull.
        local cells = {}
        local solid_lookup = {}
        local painted_counts = {}
        local missing_counts = {}
        local shaped_tile_ids = {}
        local painted_cells = 0
        local excluded_cells = 0
        local terrain_cells = {}
        -- Grapple paint tags anchors only, even when its gid has a tile hull.
        -- Keep every other layer, including hidden solid collision layers.
        for _, layer in ipairs(ResourceText.all(ResourceText.parse(tilemap_text).root, "layers")) do
            if TilemapRegen.normalize_layer_name(ResourceText.value(layer.node, "id")) ~= "grapple" then
                for _, cell in ipairs(ResourceText.all(layer.node, "cell")) do
                    terrain_cells[#terrain_cells + 1] = cell.node
                end
            end
        end
        for _, cell in ipairs(terrain_cells) do
            local cx = tonumber(ResourceText.value(cell, "x"))
            local cy = tonumber(ResourceText.value(cell, "y"))
            local tid = tonumber(ResourceText.value(cell, "tile"))
            if cx and cy and tid then
                painted_cells = painted_cells + 1
                painted_counts[tid] = (painted_counts[tid] or 0) + 1
            end
            local is_excluded = cx and cy and excluded[cx .. "," .. cy]
            if is_excluded then
                excluded_cells = excluded_cells + 1
            end
            local tile_shapes = (not is_excluded and cx and cy and tid and meta and meta.tile_collision)
                and meta.tile_collision[tid] or nil
            if tile_shapes then
                shaped_tile_ids[tid] = true
                local full = TileCollision.tile_shapes_contain_full_cell(tile_shapes, tw, th)
                -- Per-cell flip/rotate flags (Defold .tilemap fields). A full-cell
                -- box is orientation-invariant, so only precise per-cell hulls
                -- (Pass 2b) need these applied.
                local hflip = tonumber(ResourceText.value(cell, "h_flip")) or 0
                local vflip = tonumber(ResourceText.value(cell, "v_flip")) or 0
                local rot90 = tonumber(ResourceText.value(cell, "rotate90")) or 0
                cells[#cells + 1] = {
                    cx = cx, cy = cy, tid = tid, shapes = tile_shapes, full = full,
                    hflip = hflip, vflip = vflip, rot90 = rot90,
                }
                if full then
                    solid_lookup[cx .. "," .. cy] = true
                end
            elseif not is_excluded and cx and cy and tid then
                missing_counts[tid] = (missing_counts[tid] or 0) + 1
            end
        end

        if excluded_cells > 0 then
            local labels = {}
            for _, rect in ipairs(platform_rects) do
                labels[#labels + 1] = string.format("%s id=%s", tostring(rect.type), tostring(rect.id))
            end
            info(string.format(
                "gen_room_tile_collision: room '%s' excluded %d cell(s) under %d tile-copying platform rect(s) (%s)",
                tostring(rid), excluded_cells, #platform_rects, table.concat(labels, ", ")))
        end

        emit_tile_collision_diagnostics(rid, meta, painted_counts)
        info(string.format(
            "gen_room_tile_collision: room '%s' coverage summary: painted cells=%d, cells with collision=%d, distinct shaped tile ids=%d, painted tile ids without collision=%s",
            tostring(rid),
            painted_cells,
            #cells,
            count_keys(shaped_tile_ids),
            format_tile_id_counts(missing_counts)))

        if #cells == 0 then
            if painted_cells > 0 and (not meta or next(meta.tile_collision or {}) == nil) then
                local tileset_name = tostring(primary.name or "(unnamed)")
                local tsx_ref = tostring(primary.filename or primary.source or "")
                local tsx_status = "no external .tsx referenced"
                if tsx_ref ~= "" then
                    if meta and meta.tsx_path then
                        tsx_status = "external .tsx resolved to '" .. tostring(meta.tsx_path) .. "'"
                    else
                        tsx_status = "external .tsx '" .. tsx_ref .. "' was not resolved"
                    end
                end
                info(string.format(
                    "gen_room_tile_collision: room '%s' has painted tilemap cells, but primary tileset '%s' has no per-tile collision data (%s). Add Tile Collision Editor shapes, save/export the tileset, and re-run Prepare & Check.",
                    tostring(rid),
                    tileset_name,
                    tsx_status
                ))
            end
            return ""
        end

        local blocks = {}
        local n = 0
        local warned_bbox_tiles = {}
        local warned_degenerate_tiles = {}

        -- Pass 2a: merge full-solid cells into rectangles -- one collider each.
        local solid_cells = {}
        for _, c in ipairs(cells) do
            if c.full then
                solid_cells[#solid_cells + 1] = { x = c.cx, y = c.cy }
            end
        end
        local rects = TileCollision.merge_cell_rectangles(solid_cells)
        for ri, r in ipairs(rects) do
            -- Rectangle bounds in level.go-local space (cell (0,0) spans
            -- [0,tw]x[0,th]); points wound counter-clockwise, +Y up, for Box2D.
            local left = r.x * tw
            local right = (r.x + r.w) * tw
            local bottom = r.y * th
            local top = (r.y + r.h) * th
            local pts = {
                { x = left, y = bottom },
                { x = right, y = bottom },
                { x = right, y = top },
                { x = left, y = top },
            }
            local resource = write_convexshape_file(
                string.format("%s_tilecol_rect_%d.convexshape", rid, ri), pts)
            n = n + 1
            blocks[#blocks + 1] = tile_collisionobject_block(n, resource)
        end

        -- Pass 2b: precise per-cell hulls for non-full-cell shapes. Skip cells
        -- already covered by a merged solid rectangle (the box wins).
        local seen = {}
        for _, c in ipairs(cells) do
            local cell_key = c.cx .. "," .. c.cy
            if not c.full and not solid_lookup[cell_key] and not seen[cell_key] then
                seen[cell_key] = true
                -- Cell center in level.go-local space (same space the tilemap
                -- renders its cells), so the baked hull aligns with the tile.
                local center_x = (c.cx + 0.5) * tw
                local center_y = (c.cy + 0.5) * th
                local out_idx = 0
                for _, shape in ipairs(c.shapes) do
                    local hulls, reason = TileCollision.tile_shape_to_defold_points(
                        shape, tw, th, c.hflip, c.vflip, c.rot90)
                    if hulls then
                        if reason == "bbox" and not warned_bbox_tiles[c.tid] then
                            warned_bbox_tiles[c.tid] = true
                            info(string.format(
                                "gen_room_tile_collision: WARNING room '%s' tile id=%s cell=(%d,%d) could not be decomposed; baking its bounding box.",
                                tostring(rid), tostring(c.tid), c.cx, c.cy))
                        end
                        for _, pts in ipairs(hulls) do
                            out_idx = out_idx + 1
                            -- Bake the cell's world placement into the points.
                            local abs = {}
                            for _, p in ipairs(pts) do
                                abs[#abs + 1] = { x = p.x + center_x, y = p.y + center_y }
                            end
                            local resource = write_tile_convexshape(rid, c.cx, c.cy, out_idx, abs)
                            n = n + 1
                            blocks[#blocks + 1] = tile_collisionobject_block(n, resource)
                        end
                    elseif not warned_degenerate_tiles[c.tid] then
                        warned_degenerate_tiles[c.tid] = true
                        info(string.format(
                            "gen_room_tile_collision: WARNING room '%s' tile id=%s cell=(%d,%d) has a degenerate collision shape; skipping it.",
                            tostring(rid), tostring(c.tid), c.cx, c.cy))
                    end
                end
            end
        end

        if n == 0 then return "" end
        info(string.format(
            "gen_room_tile_collision: room '%s' baked %d collider(s) (%d merged solid rect(s) from %d solid cell(s))",
            tostring(rid), n, #rects, #solid_cells))
        return table.concat(blocks, '\n') .. '\n'
    end)
    if ok then return result end
    info("gen_room_tile_collision: failed for '" .. tostring(rid) .. "': " .. tostring(result))
    return ""
end

local SOLID_BOX_OBJECT_TYPES = {
    collision_box = true,
    solid_box = true,
    solid = true,
    ground = true,
    collision = true,
}

local SOLID_SLOPE_OBJECT_TYPES = {
    collision_slope = true,
    solid_slope = true,
    slope = true,
}

local function normalize_object_type_name(value)
    if value == nil then
        return nil
    end
    local s = tostring(value):lower()
    s = s:gsub("[%s%-]+", "_")
    s = s:gsub("[^%w_]", "")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    if s == "" then
        return nil
    end
    return s
end

local function object_property(object, key)
    local props = type(object) == "table" and object.properties or nil
    if type(props) ~= "table" then
        return nil
    end
    if props[key] ~= nil then
        return props[key]
    end
    for _, entry in ipairs(props) do
        if type(entry) == "table" and (entry.name == key or entry.Name == key) then
            if entry.value ~= nil then return entry.value end
            if entry.Value ~= nil then return entry.Value end
        end
    end
    return nil
end

local function object_property_truthy(object, key)
    local value = object_property(object, key)
    if value == true then
        return true
    end
    if value == false or value == nil then
        return false
    end
    local s = tostring(value):lower()
    return s == "true" or s == "1" or s == "yes" or s == "on"
end

local function resolve_solid_collision_object_type(object)
    if type(object) ~= "table" then
        return nil
    end

    local candidates = {
        object.type,
        object.class,
        object.className,
    }

    local template_file = object_property(object, "template_file")
    if template_file ~= nil then
        candidates[#candidates + 1] = tostring(template_file):match("([^/\\]+)%.tx$") or template_file
    end
    candidates[#candidates + 1] = object.name

    for _, value in ipairs(candidates) do
        local normalized = normalize_object_type_name(value)
        if normalized then
            if SOLID_BOX_OBJECT_TYPES[normalized] then
                return "collision_box"
            end
            if SOLID_SLOPE_OBJECT_TYPES[normalized] then
                return "collision_slope"
            end
        end
    end

    if object_property_truthy(object, "solid") then
        return "collision_box"
    end

    return nil
end

local function write_object_convexshape(rid, obj_id, pts, idx, total)
    local lines = { "shape_type: TYPE_HULL" }
    for _, p in ipairs(pts) do
        lines[#lines + 1] = "data: " .. fmt_float(p.x)
        lines[#lines + 1] = "data: " .. fmt_float(p.y)
        lines[#lines + 1] = "data: 0.0"
    end
    local object_id = math.floor(tonumber(obj_id) or 0)
    local fname
    if (tonumber(total) or 1) > 1 then
        fname = string.format("%s_objcol_%d_%d.convexshape", rid, object_id, tonumber(idx) or 1)
    else
        fname = string.format("%s_objcol_%d.convexshape", rid, object_id)
    end
    write_if_changed(join(PATH.generated_go, fname), table.concat(lines, "\n") .. "\n")
    return "/developer/rooms/generated/" .. fname
end

local function gen_room_object_collision(rid)
    local ok, result = pcall(function()
        local tiled_data = load_tiled_export(rid)
        if type(tiled_data) ~= "table" or type(tiled_data.layers) ~= "table" then
            return ""
        end

        local map_height = (tonumber(tiled_data.height) or 0) * (tonumber(tiled_data.tileheight) or 0)
        if map_height <= 0 then
            return ""
        end

        local blocks = {}
        local n = 0

        local function add_object_collision(object, obj_type)
            if type(object) ~= "table" or object.visible == false then
                return
            end
            local hulls
            if obj_type == "collision_slope" then
                -- Slopes are authored as an editable polygon (triangle) in
                -- Tiled. Bake the actual drawn points into a room-local hull.
                local polygon = object.polygon
                if type(polygon) == "table" and #polygon >= 3 then
                    local reason
                    hulls, reason = TileCollision.object_polygon_to_defold_points(
                        polygon, object.x, object.y, map_height, object.rotation)
                    if reason == "bbox" then
                        info(string.format(
                            "gen_room_object_collision: WARNING room '%s' Solid Slope (object id=%s) could not be decomposed; baking its bounding box.",
                            tostring(rid), tostring(object.id)))
                    end
                end
                if not hulls then
                    -- No polygon (e.g. an old rectangle-based slope): degrade to
                    -- a box so the surface still collides, and tell the author to
                    -- re-drag the Solid Slope template for an editable triangle.
                    info(string.format(
                        "gen_room_object_collision: room '%s' Solid Slope (object id=%s) has no polygon; baking a box instead. Re-drag the Solid Slope template in Tiled to get an editable triangle.",
                        tostring(rid), tostring(object.id)))
                    local pts = TileCollision.object_rect_to_defold_points(
                        object.x, object.y, object.width, object.height, map_height, object.rotation)
                    hulls = pts and { pts } or nil
                end
            else
                -- Solid Box: bake the rectangle's four corners, rotated around
                -- its Tiled origin so a rotated box collides where it's drawn.
                local pts = TileCollision.object_rect_to_defold_points(
                    object.x, object.y, object.width, object.height, map_height, object.rotation)
                hulls = pts and { pts } or nil
            end

            for idx, pts in ipairs(hulls or {}) do
                local resource = write_object_convexshape(rid, object.id, pts, idx, #hulls)
                n = n + 1
                local L = {}
                local function add(s) L[#L + 1] = s end
                add("embedded_components {")
                add(string.format('  id: "objcol_%d"', n))
                add('  type: "collisionobject"')
                add(string.format('  data: "collision_shape: \\"%s\\"\\n"', resource))
                add('  "type: COLLISION_OBJECT_TYPE_STATIC\\n"')
                add('  "mass: 0.0\\n"')
                add('  "friction: 0.1\\n"')
                add('  "restitution: 0.0\\n"')
                add('  "group: \\"solid\\"\\n"')
                add('  "mask: \\"player\\"\\n"')
                add('  "mask: \\"enemy\\"\\n"')
                add('  ""')
                add("}")
                blocks[#blocks + 1] = table.concat(L, "\n")
            end
        end

        local function walk(layers)
            for _, layer in ipairs(layers or {}) do
                if type(layer) == "table" then
                    if layer.type == "group" and type(layer.layers) == "table" then
                        walk(layer.layers)
                    elseif layer.type == "objectgroup" and type(layer.objects) == "table" then
                        for _, object in ipairs(layer.objects) do
                            local obj_type = resolve_solid_collision_object_type(object)
                            if obj_type then
                                add_object_collision(object, obj_type)
                            end
                        end
                    end
                end
            end
        end

        walk(tiled_data.layers)
        if n == 0 then return "" end
        info(string.format("gen_room_object_collision: room '%s' baked %d Solid Box/Slope collider(s)", tostring(rid), n))
        return table.concat(blocks, "\n") .. "\n"
    end)
    if ok then return result end
    info("gen_room_object_collision: failed for '" .. tostring(rid) .. "': " .. tostring(result))
    return ""
end


M.PNG_DIMENSION_CACHE = PNG_DIMENSION_CACHE
M.TSX_META_CACHE = TSX_META_CACHE
M.STANDARD_TILE_COLLISION_GROUP = STANDARD_TILE_COLLISION_GROUP
M.STANDARD_TILE_COLLISION_FIRST = STANDARD_TILE_COLLISION_FIRST
M.STANDARD_TILE_COLLISION_LAST = STANDARD_TILE_COLLISION_LAST

M.resolve_tilesource_collision_resource = resolve_tilesource_collision_resource
M.resolve_image_path = resolve_image_path
M.get_png_dimensions = get_png_dimensions
M.collect_missing_generated_rooms = collect_missing_generated_rooms
M.sanitize_asset_name = sanitize_asset_name
M.get_tiled_property = get_tiled_property
M.parse_xml_attributes = parse_xml_attributes
M.resolve_source_file = resolve_source_file
M.parse_tsx_tileset = parse_tsx_tileset
M.get_tileset_meta = get_tileset_meta
M.collect_collection_source_dirs = collect_collection_source_dirs
M.maybe_infer_missing_collection_tile_image = maybe_infer_missing_collection_tile_image
M.make_tilesource_text = make_tilesource_text
M.tilesource_matches_grid = tilesource_matches_grid
M.count_non_four_point_hulls = count_non_four_point_hulls
M.ensure_tilesource_from_tiled = ensure_tilesource_from_tiled
M.ensure_room_tilesources = ensure_room_tilesources
M.cleanup_collection_tilesources = cleanup_collection_tilesources
M.resolve_tilesource = resolve_tilesource
M.update_tilemap_tilesource = update_tilemap_tilesource
M.relink_prefab_tilemaps = relink_prefab_tilemaps
M.update_all_tilemap_tilesources = update_all_tilemap_tilesources
M.gen_room_tile_collision = gen_room_tile_collision
M.gen_room_object_collision = gen_room_object_collision

return M

-- mvtk/editor/tile_settings_writer.lua
-- Shared generator and consistency checks for developer/config/tile_settings.lua.

local M = {}
local ok_filesystem, Filesystem = pcall(require, "hooks.core.filesystem")

M.DEFAULT_WIDTH = 128
M.DEFAULT_HEIGHT = 128

local function normalize(path)
    if path == nil then
        return ""
    end
    return (tostring(path):gsub("\\", "/"):gsub("/+", "/"))
end

local function join_path(a, b)
    a = normalize(a or "")
    b = normalize(b or "")
    if a == "" or a == "." then
        return b
    end
    if b == "" then
        return a
    end
    if a:sub(-1) == "/" then
        return a .. b:gsub("^/+", "")
    end
    return a .. "/" .. b:gsub("^/+", "")
end

local function dirname(path)
    return normalize(path):match("^(.*)/[^/]*$") or ""
end

local function read_text(path)
    local pending=require("mvtk.editor.file_utils").read_pending(path)
    if pending~=nil then return pending end
    local fh = io and io.open and io.open(path, "rb") or nil
    if not fh then
        return nil
    end
    local text = fh:read("*a")
    fh:close()
    return text
end

local function write_text(path, text)
    local fh, err = io.open(path, "wb")
    if not fh then
        return nil, err
    end
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
    fh:write(text)
    fh:close()
    return true
end

local function ensure_dir(path)
    if not path or path == "" then
        return
    end
    if ok_filesystem and Filesystem and type(Filesystem.ensure_dir) == "function" then
        Filesystem.ensure_dir(path)
        return
    end
    local sep = package.config and package.config:sub(1, 1) or "/"
    if sep == "\\" then
        local win_path = path:gsub("/", "\\")
        os.execute(string.format('cmd /c if not exist "%s" mkdir "%s"', win_path, win_path))
    else
        os.execute(string.format('mkdir -p "%s"', path:gsub("'", "'\\''")))
    end
end

local function file_exists(path)
    local fh = io and io.open and io.open(path, "rb") or nil
    if fh then
        fh:close()
        return true
    end
    return false
end

local function list_files(dir, suffix)
    local out = {}
    dir = normalize(dir)
    if editor then
        -- The editor has no lfs. Resource children are sufficient for these
        -- imported, project-owned tilesources/maps and avoid a shell fallback.
        local root = normalize(editor.external_file_attributes(".").path):gsub("/$", "")
        local relative = dir:gsub("^%./", "")
        if relative:sub(1, #root + 1):lower() == (root .. "/"):lower() then
            relative = relative:sub(#root + 2)
        end
        local resource = "/" .. relative:gsub("^/", "")
        if editor.can_get(resource, "children") then
            for _, child in ipairs(editor.get(resource, "children")) do
                local name = child:match("([^/]+)$")
                if name and (not suffix or name:sub(-#suffix) == suffix) then out[#out + 1] = name end
            end
        end
        table.sort(out)
        return out
    end
    local ok_lfs, lfs = pcall(require, "lfs")
    if ok_lfs and lfs and lfs.dir then
        local ok_dir, iter, state = pcall(lfs.dir, dir)
        if ok_dir and iter then
            for name in iter, state do
                if name ~= "." and name ~= ".." and (not suffix or name:sub(-#suffix) == suffix) then
                    out[#out + 1] = name
                end
            end
        end
    elseif ok_filesystem and Filesystem and type(Filesystem.list_dir_filesystem) == "function" then
        local _, files = Filesystem.list_dir_filesystem(dir)
        for _, name in ipairs(files or {}) do
            if name ~= "" and (not suffix or name:sub(-#suffix) == suffix) then
                out[#out + 1] = name
            end
        end
    end
    table.sort(out)
    return out
end

local function positive_int(value)
    local n = tonumber(value)
    if not n or n <= 0 then
        return nil
    end
    return math.floor(n + 0.5)
end

local function entry_key(width, height)
    return tostring(width) .. "x" .. tostring(height)
end

local function add_entry(entries, kind, source, width, height)
    width = positive_int(width)
    height = positive_int(height) or width
    if not width or not height then
        return nil
    end
    local entry = {
        kind = kind,
        source = source,
        width = width,
        height = height,
    }
    entries[#entries + 1] = entry
    return entry
end

function M.generate(width, height, opts)
    opts = opts or {}
    width = positive_int(width) or M.DEFAULT_WIDTH
    height = positive_int(height) or width
    local source = opts.source or "imported tilesource art"
    local generator = opts.generator or "Microvania Toolkit"
    local template = [[
-- ============================================================================
-- developer/config/tile_settings.lua
-- ============================================================================
-- DERIVED MIRROR for tile dimensions across the project.
-- Imported tilesource art is the source of truth; this file is regenerated from
-- %s so runtime/editor systems can share the same value.
-- ============================================================================
-- Generated by %s

local TILE = {
    width  = %d,
    height = %d,
}

-- Derived helpers
TILE.tile_width  = TILE.width   -- alias used by validators
TILE.tile_height = TILE.height
TILE.half_width  = TILE.width * 0.5
TILE.half_height = TILE.height * 0.5
TILE.size        = TILE.width  -- convenience when tiles are square
TILE.size_half   = TILE.half_width

return TILE
]]
    return string.format(template, source, generator, width, height)
end

function M.write_if_changed(path, width, height, opts)
    opts = opts or {}
    local content = M.generate(width, height, opts)
    if opts.write_if_changed then
        return opts.write_if_changed(path, content), content
    end

    local previous = read_text(path)
    if previous == content then
        return false, content
    end
    ensure_dir(dirname(path))
    local ok, err = write_text(path, content)
    if not ok then
        return nil, err
    end
    return true, content
end

function M.parse_tilesource_text(text)
    if type(text) ~= "string" then
        return nil, nil
    end
    local width = positive_int(text:match("tile_width:%s*(%d+)"))
    local height = positive_int(text:match("tile_height:%s*(%d+)")) or width
    return width, height
end

local function parse_lua_number_field(text, field)
    if type(text) ~= "string" then
        return nil
    end
    return positive_int(text:match(field .. "%s*=%s*(%d+)"))
        or positive_int(text:match("%[\"" .. field .. "\"%]%s*=%s*(%d+)"))
        or positive_int(text:match("%['" .. field .. "'%]%s*=%s*(%d+)"))
end

function M.parse_tiled_export_text(text)
    local width = parse_lua_number_field(text, "tilewidth")
    local height = parse_lua_number_field(text, "tileheight") or width
    return width, height
end

function M.read_tile_settings(path)
    local text = read_text(path)
    if not text then
        return nil
    end
    local width = parse_lua_number_field(text, "width")
        or parse_lua_number_field(text, "tile_width")
        or parse_lua_number_field(text, "size")
    local height = parse_lua_number_field(text, "height")
        or parse_lua_number_field(text, "tile_height")
        or width
    if not width then
        return nil
    end
    return { width = width, height = height, path = path }
end

local function resource_to_fs_path(root, resource)
    resource = normalize(resource or "")
    if resource == "" then
        return nil
    end
    if resource:sub(1, 1) == "/" then
        return join_path(root, resource:sub(2))
    end
    return resource
end

local function collect_referenced_tilesource_entries(opts, entries, seen)
    local root = opts.root or "."
    local tilemaps_dir = opts.tilemaps_dir or join_path(root, "developer/assets/tiled/maps")
    for _, room_id in ipairs(opts.room_ids or {}) do
        local tilemap_path = join_path(tilemaps_dir, tostring(room_id) .. ".tilemap")
        local text = read_text(tilemap_path)
        if text then
            for resource in text:gmatch('tile_set:%s*"([^"]+)"') do
                local fs_path = resource_to_fs_path(root, resource)
                if fs_path and not seen[fs_path] then
                    seen[fs_path] = true
                    local ts_text = read_text(fs_path)
                    local width, height = M.parse_tilesource_text(ts_text)
                    add_entry(entries, "tilesource", resource, width, height)
                end
            end
        end
    end
end

local function collect_all_tilesource_entries(opts, entries, seen)
    local root = opts.root or "."
    local tilesheets_dir = opts.tilesheets_dir or join_path(root, "developer/assets/tilesheets")
    for _, name in ipairs(list_files(tilesheets_dir, ".tilesource")) do
        local path = join_path(tilesheets_dir, name)
        if not seen[path] then
            seen[path] = true
            local width, height = M.parse_tilesource_text(read_text(path))
            add_entry(entries, "tilesource", path, width, height)
        end
    end
end

local function collect_tiled_export_entries(opts, entries)
    local root = opts.root or "."
    local maps_dir = opts.maps_dir or opts.tilemaps_dir or join_path(root, "developer/assets/tiled/maps")
    for _, name in ipairs(list_files(maps_dir, ".lua")) do
        local path = join_path(maps_dir, name)
        local width, height = M.parse_tiled_export_text(read_text(path))
        add_entry(entries, "tiled_export", path, width, height)
    end
end

local function choose_primary(entries)
    local counts = {}
    local order = {}
    for _, entry in ipairs(entries or {}) do
        local key = entry_key(entry.width, entry.height)
        if not counts[key] then
            counts[key] = { width = entry.width, height = entry.height, count = 0, first = entry }
            order[#order + 1] = key
        end
        counts[key].count = counts[key].count + 1
    end
    table.sort(order, function(a, b)
        local ca, cb = counts[a], counts[b]
        if ca.count ~= cb.count then
            return ca.count > cb.count
        end
        return a < b
    end)
    local best = order[1] and counts[order[1]] or nil
    if not best then
        return nil
    end
    return {
        width = best.width,
        height = best.height,
        count = best.count,
        source = best.first and best.first.source or nil,
    }
end

function M.validate_consistency(opts)
    opts = opts or {}
    local root = opts.root or "."
    local entries = {}
    local seen_tilesources = {}
    collect_referenced_tilesource_entries(opts, entries, seen_tilesources)
    if #entries == 0 then
        collect_all_tilesource_entries(opts, entries, seen_tilesources)
    end
    collect_tiled_export_entries(opts, entries)

    local primary = choose_primary(entries)
    local result = {
        ok = true,
        entries = entries,
        primary = primary,
        mismatches = {},
        warnings = {},
    }

    for _, entry in ipairs(entries) do
        if primary and (entry.width ~= primary.width or entry.height ~= primary.height) then
            result.ok = false
            result.mismatches[#result.mismatches + 1] = entry
        end
    end

    local settings_path = opts.tile_settings_path or join_path(root, "developer/config/tile_settings.lua")
    result.tile_settings = M.read_tile_settings(settings_path)
    if opts.require_tile_settings_match and primary and result.tile_settings then
        local cfg = result.tile_settings
        if cfg.width ~= primary.width or cfg.height ~= primary.height then
            result.ok = false
            result.tile_settings_mismatch = {
                width = cfg.width,
                height = cfg.height,
                expected_width = primary.width,
                expected_height = primary.height,
                path = cfg.path,
            }
        end
    elseif opts.require_tile_settings_match and primary and not result.tile_settings then
        result.ok = false
        result.tile_settings_mismatch = {
            missing = true,
            expected_width = primary.width,
            expected_height = primary.height,
            path = settings_path,
        }
    end

    return result
end

function M.format_validation_messages(result)
    local lines = {}
    result = result or {}
    if result.tile_settings_mismatch then
        local m = result.tile_settings_mismatch
        if m.missing then
            lines[#lines + 1] = string.format(
                "%s is missing; expected %dx%d from imported tilesource art.",
                tostring(m.path), tonumber(m.expected_width) or 0, tonumber(m.expected_height) or 0
            )
        else
            lines[#lines + 1] = string.format(
                "%s is %dx%d, but imported tilesource art is %dx%d.",
                tostring(m.path), tonumber(m.width) or 0, tonumber(m.height) or 0,
                tonumber(m.expected_width) or 0, tonumber(m.expected_height) or 0
            )
        end
    end
    for _, entry in ipairs(result.mismatches or {}) do
        local primary = result.primary or {}
        lines[#lines + 1] = string.format(
            "%s uses %dx%d; expected %dx%d.",
            tostring(entry.source or entry.kind), tonumber(entry.width) or 0, tonumber(entry.height) or 0,
            tonumber(primary.width) or 0, tonumber(primary.height) or 0
        )
    end
    return lines
end

function M.write_project_settings_from_art(opts)
    opts = opts or {}
    local result = M.validate_consistency(opts)
    local primary = result.primary
    if not primary then
        primary = {
            width = M.DEFAULT_WIDTH,
            height = M.DEFAULT_HEIGHT,
            source = "neutral default",
        }
        result.primary = primary
        result.warnings[#result.warnings + 1] = "No tilesource art found; using neutral tile-size default."
    end

    local tile_settings_path = opts.tile_settings_path
        or join_path(opts.root or ".", "developer/config/tile_settings.lua")
    local changed, content_or_err = M.write_if_changed(tile_settings_path, primary.width, primary.height, {
        write_if_changed = opts.write_if_changed,
        source = primary.source or "imported tilesource art",
        generator = opts.generator or "Import Assets",
    })
    result.changed = changed == true
    result.write_error = (changed == nil) and content_or_err or nil
    return result
end

function M.validate_layout_shapes(rooms, tile_settings)
    local width = positive_int(tile_settings and (tile_settings.width or tile_settings.tile_width or tile_settings.size))
    local height = positive_int(tile_settings and (tile_settings.height or tile_settings.tile_height or tile_settings.size)) or width
    local result = { ok = true, mismatches = {}, expected_width = width, expected_height = height }
    if not width or not height then
        result.ok = false
        result.error = "tile_settings width/height must be positive"
        return result
    end
    for room_id, room in pairs(rooms or {}) do
        local shape = room and room.shape
        local tw = positive_int(shape and shape.tile_w)
        local th = positive_int(shape and shape.tile_h) or tw
        if tw and th and (tw ~= width or th ~= height) then
            result.ok = false
            result.mismatches[#result.mismatches + 1] = {
                room_id = room_id,
                width = tw,
                height = th,
            }
        end
    end
    return result
end

return M

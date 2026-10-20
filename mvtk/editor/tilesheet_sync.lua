-- mvtk/editor/tilesheet_sync.lua
-- Copy updated tilesheet PNGs from Tiled source folders into the Defold
-- project (developer/assets/tilesheets/) so artists' edits propagate.
--
-- For every tileset referenced by each room's Tiled export:
--   * Resolve the Defold tilesource and the PNG it points at.
--   * Compare the source PNG (from Tiled metadata / TSX) to the project copy
--     by mtime and size.
--   * Overwrite the project copy when the source is newer or differs.
--   * For collection-image tilesets, refresh the managed tilesource instead
--     of copying a single PNG (those use atlases).
--   * For tilesets that have no Defold tilesource yet, auto-import one.
--
-- Wiring: editor_core.lua calls M.configure{...} once with the collaborators
-- that live there (logger, profiler, copy_file, resolve_tilesource,
-- get_tileset_meta, ensure_tilesource_from_tiled).

local path_utils = require("mvtk.editor.path_utils")
local file_utils = require("mvtk.editor.file_utils")
local tiled_export = require("mvtk.editor.tiled_export")

local M = {}

local _logger = function(msg) print("[tilesheet_sync] " .. tostring(msg)) end
local _profiler = nil
local _copy_file = nil
local _resolve_tilesource = nil
local _get_tileset_meta = nil
local _ensure_tilesource_from_tiled = nil

local _lfs_ok, _lfs = pcall(require, "lfs")

local TILESOURCE_IMAGE_CACHE = {}

function M.configure(opts)
    opts = opts or {}
    if opts.logger ~= nil then _logger = opts.logger end
    if opts.profiler ~= nil then _profiler = opts.profiler end
    if opts.copy_file ~= nil then _copy_file = opts.copy_file end
    if opts.resolve_tilesource ~= nil then _resolve_tilesource = opts.resolve_tilesource end
    if opts.get_tileset_meta ~= nil then _get_tileset_meta = opts.get_tileset_meta end
    if opts.ensure_tilesource_from_tiled ~= nil then _ensure_tilesource_from_tiled = opts.ensure_tilesource_from_tiled end
end

local function require_collab(name, value)
    assert(value, "mvtk.editor.tilesheet_sync: missing collaborator '" .. name
        .. "'; configure{} must supply it before calling sync(...)")
    return value
end

local function profiler_start(label)
    if _profiler and _profiler.start then _profiler.start(label) end
end

local function profiler_stop(label)
    if _profiler and _profiler.stop then _profiler.stop(label) end
end

-- ── File metadata helpers ─────────────────────────────────────────────

local function file_size(path)
    if _lfs_ok and _lfs and _lfs.attributes then
        local s = _lfs.attributes(path_utils.to_os_path(path), "size")
        if s then return s end
    end
    -- Fallback: read entire file and measure length
    local fh = io.open(path, "rb")
    if not fh then
        fh = io.open(path_utils.to_os_path(path), "rb")
    end
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data and #data or nil
end

local function file_mtime(path)
    if not _lfs_ok or not _lfs or not _lfs.attributes then return nil end
    return _lfs.attributes(path_utils.to_os_path(path), "modification")
end

-- Resolve a tilesource resource (e.g. /developer/assets/.../foo.tilesource)
-- to (absolute_png_path, png_resource_path). Cached per resource.
local function tilesource_image_abs(tilesource_resource)
    if not tilesource_resource or tilesource_resource == "" then return nil end
    if TILESOURCE_IMAGE_CACHE[tilesource_resource] then
        local c = TILESOURCE_IMAGE_CACHE[tilesource_resource]
        return c[1], c[2]
    end
    local ts_rel = tilesource_resource:gsub("^/", "")
    local ts_abs = path_utils.normalize(path_utils.join(path_utils.get_root(), ts_rel))
    local content = file_utils.read_text(ts_abs)
    if not content then
        TILESOURCE_IMAGE_CACHE[tilesource_resource] = { nil, nil }
        return nil, nil
    end
    local image_resource = content:match('image:%s*"([^"]+)"')
    if not image_resource then
        TILESOURCE_IMAGE_CACHE[tilesource_resource] = { nil, nil }
        return nil, nil
    end
    local img_rel = image_resource:gsub("^/", "")
    local result = path_utils.normalize(path_utils.join(path_utils.get_root(), img_rel))
    TILESOURCE_IMAGE_CACHE[tilesource_resource] = { result, image_resource }
    return result, image_resource
end

-- Determine whether *src* is newer or different from *dst*. Returns true
-- when *dst* should be overwritten. Exposed on M because callers outside
-- this module (editor_script.lua) use it directly to gate atlas refreshes.
local function source_is_newer(src, dst)
    if not src or src == "" then return false end
    if not file_utils.file_exists_any(src) then return false end
    if not file_utils.file_exists_any(dst) then return true end -- dest missing

    local src_mt = file_mtime(src)
    local dst_mt = file_mtime(dst)
    if src_mt and dst_mt then
        return src_mt > dst_mt
    end

    local src_sz = file_size(src)
    local dst_sz = file_size(dst)
    if src_sz and dst_sz then
        return src_sz ~= dst_sz
    end

    return false
end
M.source_is_newer = source_is_newer

-- ── Public API ────────────────────────────────────────────────────────

--- Sync tilesheet images for the given room list.
-- See module header for the full algorithm.
function M.sync(room_ids)
    if not room_ids or #room_ids == 0 then return end

    require_collab("copy_file", _copy_file)
    require_collab("resolve_tilesource", _resolve_tilesource)
    require_collab("get_tileset_meta", _get_tileset_meta)
    require_collab("ensure_tilesource_from_tiled", _ensure_tilesource_from_tiled)

    _logger("[TILESHEET_SYNC] Checking tilesheet images for " .. #room_ids .. " rooms...")

    -- Track which destination files we have already synced this run to
    -- avoid redundant copies when multiple rooms share a tileset.
    local synced = {}
    local refreshed_tilesources = {}
    local copied_count = 0
    local skipped_count = 0

    for _, room_id in ipairs(room_ids) do
        profiler_start("  sync_tilesheet [" .. room_id .. "]")
        local tiled_data, tiled_export_path = tiled_export.load(room_id)
        if tiled_data and type(tiled_data.tilesets) == "table" then
            for _, tileset_entry in ipairs(tiled_data.tilesets) do
                local tileset_name = tostring(tileset_entry.name or "")
                if tileset_name ~= "" then
                    local meta = _get_tileset_meta(tileset_entry, tiled_export_path)
                    -- Collection images are atlas inputs. Resolving a missing
                    -- tilesource rescans the project, once per room otherwise.
                    local tilesource
                    if not (meta and meta.collection) then tilesource = _resolve_tilesource(tileset_name) end
                    if tilesource then
                        local is_managed_tilesource = tilesource:find("^/developer/assets/tilesheets/", 1, true) == 1
                        if is_managed_tilesource and meta and not meta.collection then
                            if not refreshed_tilesources[tilesource] then
                                refreshed_tilesources[tilesource] = true
                                local asset_name = path_utils.basename(tilesource):gsub("%.tilesource$", "")
                                local refreshed_ts, refresh_err = _ensure_tilesource_from_tiled(
                                    room_id, tiled_data, tiled_export_path, tileset_entry, asset_name
                                )
                                if refreshed_ts then
                                    copied_count = copied_count + 1
                                    _logger(string.format("[TILESHEET_SYNC] Refreshed managed tilesource '%s' from Tiled metadata",
                                        tostring(tilesource)))
                                else
                                    _logger(string.format("[TILESHEET_SYNC] Failed to refresh managed tilesource '%s': %s",
                                        tostring(tilesource), tostring(refresh_err)))
                                end
                            else
                                skipped_count = skipped_count + 1
                            end
                        else
                            local dest_abs, dest_resource = tilesource_image_abs(tilesource)
                            if dest_abs and not synced[dest_abs] then
                                synced[dest_abs] = true
                                local source_image = meta and meta.image
                                if source_image and source_image ~= "" then
                                    if source_is_newer(source_image, dest_abs) then
                                        local ok_copy = _copy_file(source_image, dest_abs)
                                        if ok_copy then
                                            copied_count = copied_count + 1
                                            _logger(string.format("[TILESHEET_SYNC] Updated: %s -> %s",
                                                path_utils.basename(source_image), dest_resource or path_utils.basename(dest_abs)))
                                        else
                                            _logger(string.format("[TILESHEET_SYNC] FAILED to copy: %s -> %s",
                                                tostring(source_image), tostring(dest_abs)))
                                        end
                                    else
                                        skipped_count = skipped_count + 1
                                    end
                                end
                            end
                        end
                    else
                        -- Tileset not yet mapped — auto-import the PNG and
                        -- create a tilesource so the tileset is available.
                        if meta and meta.collection then
                            skipped_count = skipped_count + 1
                            _logger(string.format(
                                "[TILESHEET_SYNC] Skipping collection-image tileset '%s' (background/object atlas import does not need a tilesource)",
                                tostring(tileset_name)
                            ))
                        else
                            local auto_ts, auto_err = _ensure_tilesource_from_tiled(
                                tileset_name, tiled_data, tiled_export_path, tileset_entry, tileset_name
                            )
                            if auto_ts then
                                copied_count = copied_count + 1
                                _logger(string.format("[TILESHEET_SYNC] Auto-imported tileset '%s' -> %s",
                                    tileset_name, tostring(auto_ts)))
                            else
                                _logger(string.format("[TILESHEET_SYNC] Could not auto-import tileset '%s': %s",
                                    tileset_name, tostring(auto_err)))
                            end
                        end
                    end
                end
            end
        end
        profiler_stop("  sync_tilesheet [" .. room_id .. "]")
    end

    if copied_count > 0 then
        _logger(string.format("[TILESHEET_SYNC] Synced %d tilesheet(s), %d up-to-date.", copied_count, skipped_count))
    else
        _logger(string.format("[TILESHEET_SYNC] All %d tilesheet(s) up-to-date.", skipped_count))
    end
end

function M.clear_cache()
    TILESOURCE_IMAGE_CACHE = {}
end

return M

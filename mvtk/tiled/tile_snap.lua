--- Tile-aligned size snapping helpers.
-- Shared by editor-time generation and runtime systems that need to convert
-- authored rectangle sizes into whole-tile dimensions.
--
-- @module tile_snap

local M = {}

local DEFAULT_TILE_SIZE = 128

local function normalize_default(value)
    local n = tonumber(value)
    if not n or n <= 0 then
        return DEFAULT_TILE_SIZE
    end
    return n
end

local function normalize_dimension(value, fallback)
    local n = tonumber(value)
    if not n or n <= 0 then
        n = fallback
    end
    if n <= 0 then
        n = DEFAULT_TILE_SIZE
    end
    return n
end

--- Normalize tile width and height values with safe fallbacks.
-- @param tile_w number|nil Tile width in pixels
-- @param tile_h number|nil Tile height in pixels
-- @param default_w number|nil Optional fallback width (default 128)
-- @param default_h number|nil Optional fallback height (default 128)
-- @return number, number normalized tile width and height
function M.normalize_tile_size(tile_w, tile_h, default_w, default_h)
    local fallback_w = normalize_default(default_w)
    local fallback_h = normalize_default(default_h)
    return normalize_dimension(tile_w, fallback_w), normalize_dimension(tile_h, fallback_h)
end

--- Snap a single length to the nearest tile multiple.
-- @param length number|nil Length in pixels
-- @param tile_size number|nil Tile size in pixels
-- @return number snapped length in pixels
function M.snap_length_to_tile(length, tile_size)
    local t = normalize_dimension(tile_size, DEFAULT_TILE_SIZE)
    local value = normalize_dimension(length, t)
    local snapped = math.floor((value / t) + 0.5) * t
    if snapped <= 0 then
        snapped = t
    end
    return snapped
end

--- Snap a single coordinate to the nearest tile boundary.
-- @param coord number|nil Coordinate in pixels
-- @param tile_size number|nil Tile size in pixels
-- @return number snapped coordinate in pixels
function M.snap_coordinate_to_tile(coord, tile_size)
    local t = normalize_dimension(tile_size, DEFAULT_TILE_SIZE)
    local value = tonumber(coord) or 0
    return math.floor((value / t) + 0.5) * t
end

--- Snap width/height to nearest whole-tile dimensions.
-- @param width number|nil Width in pixels
-- @param height number|nil Height in pixels
-- @param tile_w number|nil Tile width
-- @param tile_h number|nil Tile height
-- @param default_w number|nil Optional fallback width (default 128)
-- @param default_h number|nil Optional fallback height (default 128)
-- @return number, number, number, number snapped_w, snapped_h, tile_w, tile_h
function M.snap_size_to_tile(width, height, tile_w, tile_h, default_w, default_h)
    local t_w, t_h = M.normalize_tile_size(tile_w, tile_h, default_w, default_h)
    local snapped_w = M.snap_length_to_tile(width, t_w)
    local snapped_h = M.snap_length_to_tile(height, t_h)
    return snapped_w, snapped_h, t_w, t_h
end

--- Snap a rectangle's bounds to the nearest tile boundaries.
-- This allows slightly off-grid authored rectangles to expand/shrink to the
-- nearest whole-tile area while keeping the resulting bounds aligned.
-- @param x number|nil Bottom-left x in pixels
-- @param y number|nil Bottom-left y in pixels
-- @param width number|nil Width in pixels
-- @param height number|nil Height in pixels
-- @param tile_w number|nil Tile width in pixels
-- @param tile_h number|nil Tile height in pixels
-- @param default_w number|nil Optional fallback width
-- @param default_h number|nil Optional fallback height
-- @return number, number, number, number, number, number
--         snapped_x, snapped_y, snapped_w, snapped_h, tile_w, tile_h
function M.snap_rect_bounds_to_tile(x, y, width, height, tile_w, tile_h, default_w, default_h)
    local t_w, t_h = M.normalize_tile_size(tile_w, tile_h, default_w, default_h)
    local raw_x = tonumber(x) or 0
    local raw_y = tonumber(y) or 0
    local raw_w = normalize_dimension(width, tonumber(default_w) or t_w)
    local raw_h = normalize_dimension(height, tonumber(default_h) or t_h)

    local snapped_left = M.snap_coordinate_to_tile(raw_x, t_w)
    local snapped_bottom = M.snap_coordinate_to_tile(raw_y, t_h)
    local snapped_right = M.snap_coordinate_to_tile(raw_x + raw_w, t_w)
    local snapped_top = M.snap_coordinate_to_tile(raw_y + raw_h, t_h)

    if snapped_right <= snapped_left then
        snapped_right = snapped_left + t_w
    end
    if snapped_top <= snapped_bottom then
        snapped_top = snapped_bottom + t_h
    end

    return snapped_left, snapped_bottom, snapped_right - snapped_left, snapped_top - snapped_bottom, t_w, t_h
end

--- Convert authored width/height to whole-tile counts.
-- @param width number|nil Width in pixels
-- @param height number|nil Height in pixels
-- @param tile_w number|nil Tile width
-- @param tile_h number|nil Tile height
-- @param default_w number|nil Optional fallback width (default 128)
-- @param default_h number|nil Optional fallback height (default 128)
-- @return number, number, number, number, number, number
--         tiles_x, tiles_y, snapped_w, snapped_h, tile_w, tile_h
function M.size_to_tile_counts(width, height, tile_w, tile_h, default_w, default_h)
    local snapped_w, snapped_h, t_w, t_h = M.snap_size_to_tile(width, height, tile_w, tile_h, default_w, default_h)
    local tiles_x = math.max(1, math.floor((snapped_w / t_w) + 0.5))
    local tiles_y = math.max(1, math.floor((snapped_h / t_h) + 0.5))
    return tiles_x, tiles_y, snapped_w, snapped_h, t_w, t_h
end

return M

--- Collision box size conversion helpers.
-- Converts between authored full sizes (Tiled/Defold world units) and
-- Defold box shape half-extents used in embedded collision shape data.
--
-- @module collision_box

local M = {}

local DEFAULT_SIZE = 128

local function normalize(value, fallback)
    local n = tonumber(value)
    if not n or n <= 0 then
        n = tonumber(fallback) or DEFAULT_SIZE
    end
    if n <= 0 then
        n = DEFAULT_SIZE
    end
    return n
end

--- Resolve width/height as full extents in world units.
-- @param width number|nil Full width
-- @param height number|nil Full height
-- @param fallback_w number|nil Fallback width
-- @param fallback_h number|nil Fallback height
-- @return number, number width, height
function M.resolve_full_size(width, height, fallback_w, fallback_h)
    local fw = normalize(fallback_w, DEFAULT_SIZE)
    local fh = normalize(fallback_h, fw)
    local w = normalize(width, fw)
    local h = normalize(height, fh)
    return w, h
end

--- Convert full width/height to Defold box half-extents.
-- @param width number|nil Full width
-- @param height number|nil Full height
-- @param fallback_w number|nil Fallback width
-- @param fallback_h number|nil Fallback height
-- @return number, number, number, number
--         half_w, half_h, full_w, full_h
function M.full_to_half_extents(width, height, fallback_w, fallback_h)
    local w, h = M.resolve_full_size(width, height, fallback_w, fallback_h)
    return w * 0.5, h * 0.5, w, h
end

--- Convert full size to instance scale based on authored base half-extents.
-- @param width number|nil Full width
-- @param height number|nil Full height
-- @param base_half_w number|nil Base half-width from prefab collision box
-- @param base_half_h number|nil Base half-height from prefab collision box
-- @param fallback_w number|nil Fallback full width
-- @param fallback_h number|nil Fallback full height
-- @return number, number, number, number
--         scale_x, scale_y, full_w, full_h
function M.scale_from_full_size(width, height, base_half_w, base_half_h, fallback_w, fallback_h)
    local half_w, half_h, full_w, full_h = M.full_to_half_extents(width, height, fallback_w, fallback_h)
    local base_hw = normalize(base_half_w, DEFAULT_SIZE * 0.5)
    local base_hh = normalize(base_half_h, base_hw)
    return half_w / base_hw, half_h / base_hh, full_w, full_h
end

--- Convert a bottom-left rectangle origin to a centered GO position.
-- Tiled rectangle objects become bottom-left aligned after object_spawner's
-- coordinate conversion; most Defold prefabs expect their GO origin at center.
-- @param x number|nil Bottom-left x
-- @param y number|nil Bottom-left y
-- @param width number|nil Full width
-- @param height number|nil Full height
-- @param fallback_w number|nil Fallback full width
-- @param fallback_h number|nil Fallback full height
-- @return number, number, number, number
--         center_x, center_y, full_w, full_h
function M.center_from_bottom_left(x, y, width, height, fallback_w, fallback_h)
    local full_w, full_h = M.resolve_full_size(width, height, fallback_w, fallback_h)
    local px = tonumber(x) or 0
    local py = tonumber(y) or 0
    return px + (full_w * 0.5), py + (full_h * 0.5), full_w, full_h
end

return M

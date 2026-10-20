-- mvtk/map/streaming/room_geometry.lua
-- Pure helpers extracted from room_manager.lua as part of Phase 5 step 32.
-- These functions are stateless and take all data via arguments — they do NOT
-- close over module-local state in room_manager.lua. Keeping them in their
-- own file lets the manager focus on streaming lifecycle while the math /
-- normalization logic stays unit-testable.

local Util = require "mvtk.core.util"

local M = {}

--- Normalize a side string ("e", "east", "n", etc.) to one of
-- "left" | "right" | "up" | "down" (or the lower-cased input if unknown).
function M.normalize_side(side)
    local s = tostring(side or ''):lower()
    if s == 'e' or s == 'east' then return 'right' end
    if s == 'w' or s == 'west' then return 'left' end
    if s == 'n' or s == 'north' then return 'up' end
    if s == 's' or s == 'south' then return 'down' end
    if s == 'top' then return 'up' end
    if s == 'bottom' or s == 'down' then return 'down' end
    if s == 'left' or s == 'right' then return s end
    return s
end

--- Convert a normalized side ("up"/"down") into the canonical Tiled name
-- ("top"/"bottom"). Other inputs pass through unchanged.
function M.canonical_side(side)
    if side == 'up' then return 'top' end
    if side == 'down' then return 'bottom' end
    return side
end

--- Offset from the bounds corner to the baked collection's tilemap origin.
-- Defold tilemap cells are zero-based, including negative/inset bounds cells.
function M.collection_offsets(shape, tile_w, tile_h)
    return -(tonumber(shape.min_x) or 0) * tile_w,
        -(tonumber(shape.min_y) or 0) * tile_h
end

--- Compute the world origin of baked content, not the room bounds corner.
-- Layout x+ox/y+oy still locate bounds, doors and minimap geometry. New exports
-- carry the displacement back to the collection origin; absent fields retain
-- the legacy placement contract until that layout is exported again.
function M.compute_spawn_xy(room)
    if not room then return 0, 0 end
    local x = tonumber(room.x) or 0
    local y = tonumber(room.y) or 0
    local ox = tonumber(room.ox) or 0
    local oy = tonumber(room.oy) or 0
    return x + ox + (tonumber(room.collection_offset_x) or 0),
        y + oy + (tonumber(room.collection_offset_y) or 0)
end

--- Build an axis-aligned bounding box for a room data table. Returns nil
-- for non-table input. The bounds always apply ox/oy and use width/height
-- as the room footprint.
function M.make_room_bounds(room_data)
    if type(room_data) ~= "table" then
        return nil
    end
    local base_x = tonumber(room_data.x) or 0
    local base_y = tonumber(room_data.y) or 0
    local ox = tonumber(room_data.ox) or 0
    local oy = tonumber(room_data.oy) or 0
    local width = tonumber(room_data.w) or 0
    local height = tonumber(room_data.h) or 0
    return {
        min_x = base_x + ox,
        max_x = base_x + ox + width,
        min_y = base_y + oy,
        max_y = base_y + oy + height,
    }
end

--- Inclusive AABB containment test. Tolerates missing fields by treating
-- them as 0. Returns false when point or bounds is nil.
function M.point_in_bounds(point, bounds)
    if not point or not bounds then
        return false
    end
    local px = tonumber(point.x) or 0
    local py = tonumber(point.y) or 0
    return px >= (tonumber(bounds.min_x) or 0)
        and px <= (tonumber(bounds.max_x) or 0)
        and py >= (tonumber(bounds.min_y) or 0)
        and py <= (tonumber(bounds.max_y) or 0)
end

--- Normalize an authored room id, rejecting opaque engine ids.
function M.normalize_room_id(id)
    id = Util.normalize_hash_string(id)
    if not id then return nil end
    local rid = Util.normalize_room_id(id)
    if rid == "" then return nil end
    return rid
end

return M

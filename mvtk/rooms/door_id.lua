-- mvtk/developer/rooms/door_id.lua
-- Generates a canonical string id for a door edge shared between two rooms.
-- Expect tx/ty to be room-local tile coordinates (0-based) measured from the
-- lower-left corner of the room's bounding rectangle. Sorting the endpoints
-- keeps the id symmetric regardless of traversal direction.
local M = {}

local function endpoint(room_id, tx, ty)
    return string.format("%s:%d,%d", tostring(room_id), tx, ty)
end

local function orient_tag(side)
    if side == "left" or side == "right" then return "V" end  -- vertical seam
    if side == "top"  or side == "bottom" then return "H" end -- horizontal seam
    return "?"
end

function M.edge_id(room_a, tx_a, ty_a, room_b, tx_b, ty_b, side)
    local a = endpoint(room_a, tx_a, ty_a)
    local b = endpoint(room_b, tx_b, ty_b)
    if a > b then a, b = b, a end
    return string.format("mvtk:door:%s:%s|%s", orient_tag(side), a, b)
end

return M



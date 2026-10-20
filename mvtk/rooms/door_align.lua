-- mvtk/developer/rooms/door_align.lua
-- Helper: Convert a found door pair into precise world spawn positions aligned to the seam.
-- This ensures blockers and triggers sit exactly on the room boundary instead of the tile center.
-- 2025-09-28

local TileFrame = require("mvtk.rooms.tile_frame")

local M = {}

local function axis_for(side)
	if side == "left" or side == "right" then return "x" end
	if side == "top" or side == "bottom" then return "y" end
	return nil
end

--- Compute world positions on each side of the seam for a door pair.
-- @param pair table  Result from mvtk.rooms.tile_doors.find_pair()
-- @param frame_a mvtk.rooms.tile_frame  Frame for the center room
-- @param frame_b mvtk.rooms.tile_frame  Frame for the neighbor room
-- @param side string  Seam orientation from the perspective of the center room ("left","right","top","bottom")
-- @return v3 wpos_a, v3 wpos_b
function M.spawn_positions(pair, frame_a, frame_b, side)
	if not (pair and frame_a and frame_b and side) then return nil, nil end
	local axis = axis_for(side)

	-- Base positions from the door tiles' centers
	local ltx_a, lty_a = pair.a_tile and pair.a_tile.local_tx, pair.a_tile and pair.a_tile.local_ty
	local ltx_b, lty_b = pair.b_tile and pair.b_tile.local_tx, pair.b_tile and pair.b_tile.local_ty
	if not (ltx_a and lty_a and ltx_b and lty_b) then return nil, nil end

	local wx_a, wy_a = TileFrame.local_to_world_center(frame_a, ltx_a, lty_a)
	local wx_b, wy_b = TileFrame.local_to_world_center(frame_b, ltx_b, lty_b)
	if not (wx_a and wy_a and wx_b and wy_b) then return nil, nil end

	-- Override along the perpendicular axis with the exact seam edge from the pair (if present)
	if axis == "x" then
		if pair.a_edge then wx_a = pair.a_edge end
		if pair.b_edge then wx_b = pair.b_edge end
	elseif axis == "y" then
		if pair.a_edge then wy_a = pair.a_edge end
		if pair.b_edge then wy_b = pair.b_edge end
	end

	return vmath.vector3(wx_a, wy_a, 0), vmath.vector3(wx_b, wy_b, 0)
end

return M

-- mvtk/editor/room_outline.lua
-- Continuous outline from 'bounds' + fast merged-rect fill. Debug prints included.

local Util = require "mvtk.core.util"
local Tile = Util.require_config("developer.config.tile_settings")

local M = {}
local function outline_log(...) end


local function read_text(path)
	if not path or path == "" then return nil end
	if path:sub(1,1) ~= "/" then path = "/" .. path end
	local ok, txt = pcall(sys.load_resource, path)
	return (ok and txt and #txt > 0) and txt or nil
end

local function parse_tilesource_tile_size(ts_text)
	local tw = tonumber(ts_text and ts_text:match("tile_width:%s*(%d+)")) or Tile.width
	local th = tonumber(ts_text and ts_text:match("tile_height:%s*(%d+)")) or Tile.height
	return tw, th
end

local function scan_layer_cells(tilemap_text, layer_id)
	local cells, in_layer, cur_x = {}, false, nil
	for line in tilemap_text:gmatch("[^\r\n]+") do
		local lid = line:match('^%s*id:%s*"([^"]+)"')
		if lid then
			in_layer, cur_x = (lid == layer_id), nil
		elseif in_layer then
			local x = line:match('^%s*x:%s*(-?%d+)%s*$')
			if x then
				cur_x = tonumber(x)
			else
				local y = line:match('^%s*y:%s*(-?%d+)%s*$')
				if y and cur_x ~= nil then
					cells[#cells+1] = { x = cur_x, y = tonumber(y) }
					cur_x = nil
				end
			end
		end
	end
	return cells
end

local function key_xy(x,y) return ("%d:%d"):format(x,y) end

-- 8 directions in clockwise order (for Y-up coordinate system)
local CW_DIRS = {
	{ 1,  0},  -- 0: E
	{ 1, -1},  -- 1: SE
	{ 0, -1},  -- 2: S
	{-1, -1},  -- 3: SW
	{-1,  0},  -- 4: W
	{-1,  1},  -- 5: NW
	{ 0,  1},  -- 6: N
	{ 1,  1},  -- 7: NE
}

-- Moore neighborhood boundary tracing through border cell centers.
-- Uses the right-hand wall-following rule to correctly handle
-- concave shapes (L-rooms, U-rooms, etc.) without cutting diagonals.
local function order_polyline_from_bounds(cells, min_x, min_y, tile_w, tile_h)
	if not cells or #cells == 0 then return {} end

	-- Build border set
	local border = {}
	for _, c in ipairs(cells) do
		border[key_xy(c.x, c.y)] = true
	end

	-- Find start: leftmost, then bottommost
	local start_x, start_y
	for _, c in ipairs(cells) do
		if not start_x or c.x < start_x or (c.x == start_x and c.y < start_y) then
			start_x, start_y = c.x, c.y
		end
	end

	-- Moore neighborhood boundary tracing.
	-- At each cell, scan clockwise from the direction AFTER the backtrack
	-- (the direction we came from). The first border cell found is the next cell.
	-- This traces the outer boundary, correctly handling concave corners.
	local poly = {}
	local cx, cy = start_x, start_y
	-- We "entered" from the west (start is leftmost, so cell to the left is empty)
	local backtrack = 4  -- W direction (index 4)
	local guard = 0
	local max_iter = #cells * 10 + 100

	repeat
		poly[#poly + 1] = {
			x = (cx - min_x + 0.5) * tile_w,
			y = (cy - min_y + 0.5) * tile_h,
		}

		-- Scan clockwise starting from one step CW past the backtrack direction
		local scan_start = (backtrack + 1) % 8
		local found = false
		for offset = 0, 7 do
			local di = (scan_start + offset) % 8
			local d = CW_DIRS[di + 1]
			local nx, ny = cx + d[1], cy + d[2]
			if border[key_xy(nx, ny)] then
				-- Backtrack for next cell = reverse of movement direction
				backtrack = (di + 4) % 8
				cx, cy = nx, ny
				found = true
				break
			end
		end

		if not found then break end
		guard = guard + 1
	until (cx == start_x and cy == start_y) or guard > max_iter

	if #poly > 0 then poly[#poly + 1] = { x = poly[1].x, y = poly[1].y } end
	return poly
end

local function pip(px, py, poly)
	local inside = false
	for i = 1, #poly - 1 do
		local x1,y1 = poly[i].x,   poly[i].y
		local x2,y2 = poly[i+1].x, poly[i+1].y
		local cond = ((y1 > py) ~= (y2 > py)) and (px < (x2 - x1) * (py - y1) / ((y2 - y1) ~= 0 and (y2 - y1) or 1e-9) + x1)
		if cond then inside = not inside end
	end
	return inside
end

local function build_fill_rects(poly, w_cells, h_cells, tile_w, tile_h, max_rects)
	local rects, active = {}, {}
	for ry = 0, h_cells - 1 do
		local y = (ry + 0.5) * tile_h
		local runs, inside, x0 = {}, false, 0
		for rx = 0, w_cells - 1 do
			local x = (rx + 0.5) * tile_w
			local inr = pip(x, y, poly)
			if inr and not inside then inside, x0 = true, rx
			elseif inside and not inr then inside = false; runs[#runs+1] = {x=x0, w=rx-x0} end
		end
		if inside then runs[#runs+1] = { x = x0, w = w_cells - x0 } end

		local next_active = {}
		for _, r in ipairs(runs) do
			local k = ("%d:%d"):format(r.x, r.w)
			local prev = active[k]
			if prev then prev.h = (prev.h or tile_h) + tile_h; next_active[k] = prev
			else
				local rc = { x = r.x * tile_w, y = ry * tile_h, w = r.w * tile_w, h = tile_h }
				rects[#rects+1] = rc
				next_active[k] = rc
			end
		end
		active = next_active
		if max_rects and #rects > max_rects then break end
	end
	return rects
end

function M.read_shape(tilemap_path, want_fill, max_rects, reader)
	local read_text = reader or read_text
	outline_log(("[LE.Outline] read_shape('%s')"):format(tilemap_path))
	local tm_text = read_text(tilemap_path)
	if not tm_text then outline_log("[LE.Outline][ERR] tilemap not found"); return nil, "tilemap_not_found" end

	local tileset_path = tm_text:match('tile_set:%s*"([^"]+)"')
	local ts_text = read_text(tileset_path)
	local tile_w, tile_h = parse_tilesource_tile_size(ts_text)
	outline_log(("[LE.Outline] tileset='%s'  tile=(%d x %d)"):format(tostring(tileset_path), tile_w, tile_h))

	local bounds = scan_layer_cells(tm_text, "bounds")
	outline_log(("[LE.Outline] bounds cells=%d"):format(#bounds))
	if #bounds == 0 then return nil, "no_bounds" end

	-- extents
	local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
	for _,c in ipairs(bounds) do
		if c.x < minx then minx = c.x end
		if c.y < miny then miny = c.y end
		if c.x > maxx then maxx = c.x end
		if c.y > maxy then maxy = c.y end
	end

	local w_cells = maxx - minx + 1
	local h_cells = maxy - miny + 1
	outline_log(("[LE.Outline] cell extents: min=(%d,%d) size=(%d x %d)"):format(minx,miny,w_cells,h_cells))

	local poly = order_polyline_from_bounds(bounds, minx, miny, tile_w, tile_h)
	outline_log(("[LE.Outline] poly points=%d (closed)"):format(#poly))

	local rects = {}
	if want_fill then
		rects = build_fill_rects(poly, w_cells, h_cells, tile_w, tile_h, max_rects or 128)
		outline_log(("[LE.Outline] fill rects=%d"):format(#rects))
	end

	return {
		tile_w = tile_w, tile_h = tile_h,
		min_x = minx, min_y = miny,
		w_cells = w_cells, h_cells = h_cells,
		w_px = w_cells * tile_w, h_px = h_cells * tile_h,
		poly = poly,
		rects = rects,
	}
end

return M

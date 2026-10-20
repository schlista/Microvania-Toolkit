-- mvtk/editor/layout_editor/render.lua
-- Layout Editor Render (vZ42)
-- Responsibilities:
--  * Geometry helpers: reduce colinear, concave flags, fill bands
--  * Budget-aware fill rect generation
--  * Draw outline / doors / markers
--  * Locked-door classification from Tiled-authored objects
--  * Recolor pairs for locked/open overlap
--  * draw_room(self, R, shape)

local Util = require "mvtk.core.util"
local S = Util.require_config("developer.config.layout_editor_settings")
local LDSET = Util.require_config("developer.config.locked_door_settings")
local UI    = require "mvtk.editor.layout_editor.ui"
local LockedDoorReader = require "mvtk.editor.locked_door_reader"

local Tile = Util.require_config("developer.config.tile_settings")

local NODE_LIMIT = (S.preview and S.preview.node_budget) or 512
local SAFE_MARGIN = (S.preview and S.preview.node_safe_margin) or 24
local COL_FILL = (S.palette and S.palette.room_fill) or vmath.vector4(0.12, 0.26, 0.33, 0.65)

local resource = resource
local buffer = buffer
local graphics = graphics

local TEXTURE_TYPE_2D = graphics and graphics.TEXTURE_TYPE_2D or hash("texture_type_2d")
local TEXTURE_FORMAT_RGBA = graphics and graphics.TEXTURE_FORMAT_RGBA or hash("texture_format_rgba")
local resource_delete = resource and (resource.delete or resource.release) or function(_) end

local M = {}

-- ----------------------------------------------------------------
-- Polygon utilities (fallback fill)

local function polygon_bounds(poly)
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    for i = 1, #poly do
        local p = poly[i]
        if p.x < min_x then min_x = p.x end
        if p.x > max_x then max_x = p.x end
        if p.y < min_y then min_y = p.y end
        if p.y > max_y then max_y = p.y end
    end
    return min_x, min_y, max_x, max_y
end

local function point_in_poly(poly, x, y)
    local inside = false
    local j = #poly
    for i = 1, #poly do
        local pi = poly[i]
        local pj = poly[j]
        local intersect = ((pi.y > y) ~= (pj.y > y)) and
            (x < (pj.x - pi.x) * (y - pi.y) / ((pj.y - pi.y) ~= 0 and (pj.y - pi.y) or 1e-9) + pi.x)
        if intersect then inside = not inside end
        j = i
    end
    return inside
end

local function raster_fill_polygon(self, R, shape)
    local poly = shape.poly
    if not (poly and #poly >= 3) then return false end

    local min_x, min_y, max_x, max_y = polygon_bounds(poly)
    if not (min_x and min_y and max_x and max_y) then return false end

    min_x = math.max(0, min_x)
    min_y = math.max(0, min_y)
    max_x = math.min(shape.w_px or max_x, max_x)
    max_y = math.min(shape.h_px or max_y, max_y)

    local step = math.max(8, math.min((shape.tile_w or Tile.width or 64), (shape.tile_h or Tile.height or 64)))
    local current_nodes = UI.count_scene_nodes(self)
    local node_limit = NODE_LIMIT or 512
    local safe_margin = SAFE_MARGIN or 24
    local budget = math.max(0, (node_limit - safe_margin) - current_nodes)
    if budget <= 0 then return false end

    -- coarse pass with reduction if we would exceed budget
    local created = 0
    for y = min_y, max_y - 0.1, step do
        local run_start = nil
        local y_mid = y + step * 0.5
        if y_mid > max_y then y_mid = max_y - 0.5 * step end
        for x = min_x, max_x + step, step do
            local x_mid = x + step * 0.5
            local inside = x <= max_x and point_in_poly(poly, x_mid, y_mid)
            if inside then
                if not run_start then run_start = x end
            elseif run_start then
                local x0 = math.max(min_x, run_start)
                local x1 = math.min(max_x, x)
                local w = x1 - x0
                if w > 0.5 then
                    if created >= budget then
                        return created > 0
                    end
                    local node = gui.new_box_node(vmath.vector3(x0, y, 0), vmath.vector3(w, math.min(step, max_y - y), 0))
                    gui.set_parent(node, R.group, false)
                    gui.set_pivot(node, gui.PIVOT_SW)
                    gui.set_color(node, COL_FILL)
                    R.fill_nodes[#R.fill_nodes+1] = node
                    created = created + 1
                end
                run_start = nil
            end
        end
    end

    return created > 0
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Logging

local function logf(fmt, ...) print(string.format("[LE.RND] "..fmt, ...)) end
local function locklog(fmt, ...) if LDSET.debug and LDSET.debug.prints then print(string.format("[LE.Lock] "..fmt, ...)) end end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local TEXTURE_PREFIX = "/dynamic/mvtk_room_fill/"
local texture_seq = 0

local function sanitize_room_id(id)
	local txt = tostring(id or "room")
	txt = txt:gsub("[^%w_%-]+", "_")
	if txt == "" then txt = "room" end
	return txt
end

local function build_fill_samples(count)
	local n = math.max(1, math.floor(tonumber(count) or 0))
	if n <= 1 then
		return { { 0.5, 0.5 } }
	end
	local offsets = { { 0.5, 0.5 } }
	local grid = math.max(1, math.ceil(math.sqrt(n)))
	local step = 1.0 / (grid + 1)
	for gy = 1, grid do
		for gx = 1, grid do
			local ox = gx * step
			local oy = gy * step
			if math.abs(ox - 0.5) > 1e-3 or math.abs(oy - 0.5) > 1e-3 then
				offsets[#offsets + 1] = { ox, oy }
			end
			if #offsets >= n then
				return offsets
			end
		end
	end
	return offsets
end

local function choose_texture_scale(shape)
	local cfg = S.preview or {}
	local max_dim = math.max(shape.w_px or 0, shape.h_px or 0)
	if max_dim <= 0 then return 1.0 end

	local target = tonumber(cfg.fill_texture_scale) or 0.5
	local min_scale = tonumber(cfg.fill_texture_min_scale) or 0.05
	local max_px = tonumber(cfg.fill_texture_max_px) or 0

	if max_px and max_px > 0 then
		local clamp = max_px / max_dim
		if clamp < target then
			target = clamp
		end
	end

	if target <= 0 then target = min_scale end
	target = math.max(min_scale, math.min(target, 1.0))
	return target
end

local function rasterize_fill_mask(shape, scale, samples)
	local poly = shape.poly
	if not poly or #poly < 3 then
		return nil
	end

	local tex_w = math.max(1, math.floor((shape.w_px or 0) * scale + 0.5))
	local tex_h = math.max(1, math.floor((shape.h_px or 0) * scale + 0.5))
	if tex_w <= 0 or tex_h <= 0 then
		return nil
	end

	local poly_tex = {}
	for i = 1, #poly do
		local p = poly[i]
		poly_tex[i] = { x = p.x * scale, y = p.y * scale }
	end

	local min_x, min_y = math.huge, math.huge
	local max_x, max_y = -math.huge, -math.huge
	for _, pt in ipairs(poly_tex) do
		if pt.x < min_x then min_x = pt.x end
		if pt.x > max_x then max_x = pt.x end
		if pt.y < min_y then min_y = pt.y end
		if pt.y > max_y then max_y = pt.y end
	end
	min_x = math.max(0, math.floor(min_x) - 1)
	min_y = math.max(0, math.floor(min_y) - 1)
	max_x = math.min(tex_w - 1, math.ceil(max_x) + 1)
	max_y = math.min(tex_h - 1, math.ceil(max_y) + 1)

	local buf = buffer.create(tex_w * tex_h, {
		{ name = hash("color"), type = buffer.VALUE_TYPE_UINT8, count = 4 },
	})
	local stream = buffer.get_stream(buf, hash("color"))
	local sample_count = #samples
	local EPS = 1e-6

	local function point_in_poly(x, y)
		local inside = false
		local j = #poly_tex
		for i = 1, #poly_tex do
			local pi = poly_tex[i]
			local pj = poly_tex[j]
			if ((pi.y > y) ~= (pj.y > y)) then
				local diff = pj.y - pi.y
				if math.abs(diff) < 1e-9 then
					diff = diff >= 0 and 1e-9 or -1e-9
				end
				local x_intersect = (y - pi.y) * (pj.x - pi.x) / diff + pi.x
				if x <= x_intersect + EPS then
					inside = not inside
				end
			end
			j = i
		end
		return inside
	end

	for py = min_y, max_y do
		local row_base = py * tex_w * 4
		for px = min_x, max_x do
			local coverage = 0
			for s = 1, sample_count do
				local sample = samples[s]
				if point_in_poly(px + sample[1], py + sample[2]) then
					coverage = coverage + 1
				end
			end
			if coverage > 0 then
				local idx = row_base + px * 4
				local alpha = math.floor((coverage / sample_count) * 255 + 0.5)
				stream[idx + 1] = 255
				stream[idx + 2] = 255
				stream[idx + 3] = 255
				stream[idx + 4] = alpha
			end
		end
	end

	return buf, tex_w, tex_h
end

local function release_fill_texture(R)
	local info = R and R.fill_texture
	if not info then return end

	if info.created and info.path then
		pcall(resource_delete, info.path)
	end

	R.fill_texture = nil
	R.fill_texture_node = nil
end

-- Colors

local COL_OUTLINE = (S.palette and S.palette.room_outline) or vmath.vector4(0.8,0.93,0.99,1)
local COL_OUTLINE_SELECTED = vmath.vector4(0.4, 1.0, 0.5, 1.0)  -- Light green for selected rooms
-- COL_FILL defined at top of file
local COL_YELLOW  = (S.door and (S.door.open_rgba or S.door.color)) or vmath.vector4(1,1,0,1)
local COL_RED     = (S.door and S.door.locked_rgba)  or vmath.vector4(1.0, 0.0, 0.0, 1.0)
local COL_ORANGE  = (S.door and S.door.contact_rgba) or vmath.vector4(1.0, 0.55, 0.10, 1.0)

local LOCK_KEY_CFG          = S.locked_key or {}
local LOCK_KEY_OFFSET       = tonumber(LOCK_KEY_CFG.offset_px)          or (Tile.half_width + 64)
local LOCK_KEY_SHAFT_LEN    = math.max(16, tonumber(LOCK_KEY_CFG.shaft_len_px)       or math.floor(Tile.width * 0.65))
local LOCK_KEY_SHAFT_THICK  = math.max(8,  tonumber(LOCK_KEY_CFG.shaft_thickness_px) or 18)
local LOCK_KEY_HEAD_SIZE    = math.max(24, tonumber(LOCK_KEY_CFG.head_size_px)       or 52)
local LOCK_KEY_HEAD_HOLE    = math.max(0,  tonumber(LOCK_KEY_CFG.head_hole_px)       or 22)
local LOCK_KEY_Z            = tonumber(LOCK_KEY_CFG.z_offset)           or 0.085
local LOCK_KEY_COLOR_HEAD   = LOCK_KEY_CFG.head_rgba  or vmath.vector4(0.95, 0.97, 1.00, 0.92)
local LOCK_KEY_COLOR_SHAFT  = LOCK_KEY_CFG.shaft_rgba or LOCK_KEY_COLOR_HEAD
local LOCK_KEY_COLOR_HOLE   = LOCK_KEY_CFG.hole_rgba  or vmath.vector4(0.05, 0.08, 0.12, 0.85)

local function draw_fill_texture_mask(self, R, shape)
	if R and R.fill_texture_skip then
		return false
	end
	local samples = build_fill_samples((S.preview and S.preview.fill_texture_samples) or 9)
	local scale = choose_texture_scale(shape)
	local buf, tex_w, tex_h = rasterize_fill_mask(shape, scale, samples)
	if not buf then
		return false
	end

	local info = R.fill_texture or {}
	if not info.path then
		texture_seq = texture_seq + 1
		local safe = sanitize_room_id(R.id)
		info.path = string.format("%s%s_%04d", TEXTURE_PREFIX, safe, texture_seq)
	end
	info.hash = info.hash or hash(info.path)
	R.fill_texture = info

	local header = {
		width = tex_w,
		height = tex_h,
		type = TEXTURE_TYPE_2D,
		format = TEXTURE_FORMAT_RGBA,
		num_mip_maps = 1,
	}

	if info.created and (info.width ~= tex_w or info.height ~= tex_h) then
		pcall(resource_delete, info.path)
		info.created = false
	end

	local ok, err
	if not info.created then
		ok, err = pcall(resource.create_texture, info.path, header, buf)
		if ok then
			info.created = true
		end
	else
		ok, err = pcall(resource.set_texture, info.path, header, buf)
	end

	if not ok then
		logf("fill texture failed for %s: %s", tostring(R.id), tostring(err))
		R.fill_texture_skip = true
		release_fill_texture(R)
		return false
	end

	info.width = tex_w
	info.height = tex_h
	info.scale = scale
	R.fill_texture_skip = nil

	local node = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(shape.w_px, shape.h_px, 0))
	gui.set_parent(node, R.group, false)
	gui.set_pivot(node, gui.PIVOT_SW)
	gui.set_texture(node, info.hash)
	gui.set_color(node, COL_FILL)
	R.fill_nodes[#R.fill_nodes + 1] = node
	R.fill_texture_node = node
	return true
end


-- Node budget (defined at top of file)
-- local NODE_LIMIT  = (S.preview and S.preview.node_budget) or 512
-- local SAFE_MARGIN = (S.preview and S.preview.node_safe_margin) or 24

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Geometry helpers

function M.outline_thickness(self)
	local px = (S.preview and S.preview.outline_thick_px) or 12
	return px -- Fixed thickness for consistent visual appearance at all zoom levels
end

local function poly_area2(poly)
	local s=0
	for i=1,#poly-1 do local a,b=poly[i],poly[i+1]; s=s+(a.x*b.y-b.x*a.y) end
	return s
end

local function compute_concave_flags(P)
	local N = #P - 1
	local area2 = poly_area2(P)
	local sign  = (area2 >= 0) and 1 or -1
	local flags, count = {}, 0
	for i=1,N do
		local v=P[i]
		local p0=P[(i-2+N)%N+1]
		local p1=P[i+1]
		local d0x,d0y=v.x-p0.x, v.y-p0.y
		local d1x,d1y=p1.x-v.x, p1.y-v.y
		local cross = d0x*d1y - d0y*d1x
		local concave = (cross*sign) < -1e-6
		flags[i]=concave; if concave then count=count+1 end
	end
	return flags, count
end

local function poly_reduce_colinear(poly, dot_epsilon)
	local n = #poly
	if n <= 2 then return poly end
	local th = dot_epsilon or 0.9995
	local out = { poly[1] }
	for i = 2, n - 1 do
		local a, b, c = out[#out], poly[i], poly[i+1]
		local abx, aby = (b.x - a.x), (b.y - a.y)
		local bcx, bcy = (c.x - b.x), (c.y - b.y)
		local abl = math.sqrt(abx*abx + aby*aby)
		local bcl = math.sqrt(bcx*bcx + bcy*bcy)
		if abl > 0 and bcl > 0 then
			local d = (abx*bcx + aby*bcy) / (abl*bcl)
			if d < th then out[#out+1] = b end
		end
	end
	out[#out+1] = poly[n]
	logf("outline reduced: %d â†’ %d points (segments=%d)", n, #out, math.max(0, #out-1))
	return out
end

-- Fill generation via horizontal band merge

local function scan_xs_at_y(poly, y)
	local xs, n = {}, #poly
	for i = 1, n - 1 do
		local a, b = poly[i], poly[i+1]
		local ymin, ymax = math.min(a.y, b.y), math.max(a.y, b.y)
		if y >= ymin and y < ymax and a.y ~= b.y then
			local t = (y - a.y) / (b.y - a.y)
			xs[#xs+1] = a.x + t * (b.x - a.x)
		end
	end
	table.sort(xs)
	return xs
end

local function build_fill_rects_precise_merged(shape, step_px)
	local poly = shape.poly or {}
	if #poly < 3 then return {} end
	local h = shape.h_px or 0
	local w = shape.w_px or 0
	local step = math.max(1, math.floor(step_px or 8))
	local eps  = 1e-4

	local out, active = {}, {}
	local y0 = 0
	while y0 < h do
		local band_h = math.min(step, h - y0)
		local y_top  = y0 + eps
		local y_bot  = math.min(y0 + band_h - eps, h - eps)

		local xt = scan_xs_at_y(poly, y_top)
		local xb = scan_xs_at_y(poly, y_bot)
		local pair_count = math.min(math.floor(#xt/2), math.floor(#xb/2))

		local seen = {}
		for k = 1, pair_count do
			local lt, rt = xt[2*k-1], xt[2*k]
			local lb, rb = xb[2*k-1], xb[2*k]
			local left   = math.max(math.min(lt, lb), 0)
			local right  = math.min(math.max(rt, rb), w)
			local width  = right - left
			if width > 0.5 and band_h > 0.5 then
				local xq = math.floor(left + 0.5)
				local wq = math.max(1, math.ceil(right) - xq)
				local key = string.format("%d|%d|%d", k, xq, wq)
				seen[key] = true
				local a = active[key]
				if a and math.abs((a.y + a.h) - y0) <= 0.5 then
					a.h = a.h + band_h
				else
					if a then out[#out+1] = a end
					active[key] = { x = xq, y = y0, w = wq, h = band_h }
				end
			end
		end

		for key, a in next, active do
			if not seen[key] then out[#out+1] = a; active[key] = nil end
		end
		y0 = y0 + band_h
	end
	for _, a in next, active do out[#out+1] = a end
	logf("fill precise merged: step=%dpx rects=%d", step, #out)
	return out, step
end

local function choose_fill_rects_for_budget(self, shape, outline_segments, concave_joins, extra_nodes)
	local base_step = (S.preview and S.preview.fill_step_px) or 8
	local step      = math.max(1, math.floor(base_step))
	extra_nodes     = extra_nodes or 0

	local current_nodes   = UI.count_scene_nodes(self)
	local allowed_for_new = math.max(0, NODE_LIMIT - SAFE_MARGIN - current_nodes)
	logf("node budget: current=%d, allowed_for_new=%d", current_nodes, allowed_for_new)

	for _ = 1, 6 do
		local rects, used = build_fill_rects_precise_merged(shape, step)
		local new_nodes = outline_segments + concave_joins + extra_nodes + #rects + 1
		if new_nodes <= allowed_for_new then
			logf("budget ok: outline=%d fill=%d joins=%d extra=%d total_new=%d (<= %d)",
				outline_segments, #rects, concave_joins, extra_nodes, new_nodes, allowed_for_new)
			return rects, used
		end
		step = step * 2
		logf("over budget â†’ step=%d", step)
	end
	logf("budget failsafe: no fill")
	return {}, step
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Drawing

local function draw_outline(self, parent, P, color4)
	local t      = M.outline_thickness(self)
	local extend = t * ((S.preview and S.preview.outline_extend_ratio) or 0.75)

	local nodes = {}
	for i = 1, #P - 1 do
		local a, b = P[i], P[i+1]
		local dx, dy = b.x - a.x, b.y - a.y
		local len = math.sqrt(dx*dx + dy*dy)
		if len > 0.001 then
			local ux, uy = dx / len, dy / len
			local cx = (a.x - ux*extend + b.x + ux*extend) * 0.5
			local cy = (a.y - uy*extend + b.y + uy*extend) * 0.5
			local n  = gui.new_box_node(vmath.vector3(cx, cy, 0), vmath.vector3(len + 2*extend, t, 0))
			gui.set_parent(n, parent, false)
			gui.set_pivot(n, gui.PIVOT_CENTER)
			gui.set_rotation(n, vmath.quat_rotation_z(math.atan2(dy, dx)))
			gui.set_color(n, color4)
			nodes[#nodes+1] = n
		end
	end

	local flags, concave_count = compute_concave_flags(P)
	if concave_count > 0 then
		for i = 1, (#P - 1) do
			if flags[i] then
				local v  = P[i]
				local p0 = P[(i-2+(#P-1))%(#P-1) + 1]
				local p1 = P[i+1]
				local d0x, d0y = v.x - p0.x, v.y - p0.y
				local d1x, d1y = p1.x - v.x, p1.y - v.y
				local l0 = math.sqrt(d0x*d0x + d0y*d0y)
				local l1 = math.sqrt(d1x*d1x + d1y*d1y)
				if l0 > 0.001 and l1 > 0.001 then
					d0x, d0y = d0x/l0, d0y/l0
					d1x, d1y = d1x/l1, d1y/l1
					local bx, by = d0x + d1x, d0y + d1y
					local bl = math.sqrt(bx*bx + by*by)
					if bl > 0.0001 then
						bx, by = bx/bl, by/bl
						local tlen = math.min(t * ((S.preview and S.preview.join_len_max_factor) or 3.5), t*2.5)
						local n = gui.new_box_node(vmath.vector3(v.x, v.y, 0), vmath.vector3(tlen, t, 0))
						gui.set_parent(n, parent, false)
						gui.set_pivot(n, gui.PIVOT_CENTER)
						gui.set_rotation(n, vmath.quat_rotation_z(math.atan2(by, bx)))
						gui.set_color(n, color4)
						nodes[#nodes+1] = n
					end
				end
			end
		end
	end
	logf("concave joins used: %d", concave_count)
	return nodes, concave_count
end

local function base_door_thickness(self)
    return M.outline_thickness(self) * ((S.door and S.door.thickness_scale) or 1.0)
end

local function door_width_reduction()
    return math.max(0, (S.door and S.door.door_width_reduction) or 0)
end

local function door_visual_thickness(self)
    local visual = base_door_thickness(self) - door_width_reduction()
    if visual < 1 then visual = 1 end
    return visual
end

local function door_visual_inset_thickness(self)
    local visual = (base_door_thickness(self) * 0.5) - door_width_reduction()
    if visual < 1 then visual = 1 end
    return visual
end

local function door_visual_length(len, extend)
    return len + 2 * extend
end

local function create_full_door_node(self, parent, door, color4)
    local base_thickness = base_door_thickness(self)
    local visual_thickness = base_thickness  -- Full thickness for unsnapped doors
    local extend = base_thickness * ((S.door and S.door.extend_ratio) or 0.20)

    local dx, dy = (door.x1 - door.x0), (door.y1 - door.y0)
    local len = math.sqrt(dx * dx + dy * dy)
    if len <= 0.001 then return nil end

    local cx = (door.x0 + door.x1) * 0.5
    local cy = (door.y0 + door.y1) * 0.5
    local visual_len = door_visual_length(len, extend)

    local node = gui.new_box_node(
        vmath.vector3(cx, cy, 0),
        vmath.vector3(visual_len, visual_thickness, 0)
    )
    gui.set_parent(node, parent, false)
    gui.set_pivot(node, gui.PIVOT_CENTER)
    gui.set_rotation(node, vmath.quat_rotation_z(math.atan2(dy, dx)))
    gui.set_color(node, color4)
    if S.door and S.door.z_bias then
        local p = gui.get_position(node)
        p.z = S.door.z_bias
        gui.set_position(node, p)
    end
    return node
end

local function create_inset_door_node(self, parent, door, side, inset_px)
    local base_full_thickness = base_door_thickness(self)
    local reduction = door_width_reduction()
    local extend = base_full_thickness * ((S.door and S.door.extend_ratio) or 0.20)

    local dx, dy = (door.x1 - door.x0), (door.y1 - door.y0)
    local len = math.sqrt(dx * dx + dy * dy)
    if len <= 0.001 then return nil end

    local cx = (door.x0 + door.x1) * 0.5
    local cy = (door.y0 + door.y1) * 0.5

    local push = tonumber(inset_px) or 0
    local base_cut_thickness = base_full_thickness * 0.5
    local visual_cut_thickness = math.max(1, base_cut_thickness - reduction)
    local seam_correction = (base_full_thickness - visual_cut_thickness) * 0.5 -- keep seam edge touching after thinning
    local total_inset = seam_correction + push
    if total_inset ~= 0 then
        if side == "left" then
            cx = cx + total_inset
        elseif side == "right" then
            cx = cx - total_inset
        elseif side == "up" then
            cy = cy - total_inset
        elseif side == "down" then
            cy = cy + total_inset
        end
    end


    local visual_len = door_visual_length(len, extend)

    local node = gui.new_box_node(
        vmath.vector3(cx, cy, 0),
        vmath.vector3(visual_len, visual_cut_thickness, 0)
    )
    gui.set_parent(node, parent, false)
    gui.set_pivot(node, gui.PIVOT_CENTER)
    gui.set_rotation(node, vmath.quat_rotation_z(math.atan2(dy, dx)))
    if S.door and S.door.z_bias then
        local p = gui.get_position(node)
        p.z = S.door.z_bias
        gui.set_position(node, p)
    end
    return node, visual_cut_thickness
end

local function draw_doors(self, parent, doors, color4, offset_px)
    if not doors or #doors == 0 then return {} end

    local nodes = {}
    for _, door in ipairs(doors) do
        local node = create_full_door_node(self, parent, door, color4)
        if node then
            nodes[#nodes + 1] = node
        end
    end

    return nodes
end

local function add_marker_line(self, parent, door, color)
    if not (LDSET.editor and LDSET.editor.marker and LDSET.editor.marker.enabled) then return nil end
    local t = M.outline_thickness(self) * ((LDSET.editor.marker.thickness_scale or LDSET.editor.marker.thickness_px or 1.0) / (S.preview.outline_thick_px or 6))
	local L = LDSET.editor.marker.len_px or 14
	local z = (LDSET.editor.marker.z_offset ~= nil) and LDSET.editor.marker.z_offset or 0.08
	local pos

    -- Place the short marker slightly toward the interior, independent of sign
    -- of door_draw_offset_px. Compute a strictly inward inset and apply per side.
    local draw_off = LDSET.editor and tonumber(LDSET.editor.door_draw_offset_px) or 0
    local inward   = math.abs(draw_off) - (L * 0.5)
    if inward < 0 then inward = 0 end

    if door.side == "left"  then pos = vmath.vector3(door.cx + inward, door.cy, z) end
    if door.side == "right" then pos = vmath.vector3(door.cx - inward, door.cy, z) end
    if door.side == "up"    then pos = vmath.vector3(door.cx, door.cy - inward, z) end
    if door.side == "down"  then pos = vmath.vector3(door.cx, door.cy + inward, z) end

	if not pos then return nil end
	local node = gui.new_box_node(pos, vmath.vector3(L, t, 0))
	gui.set_parent(node, parent, false)
	gui.set_pivot(node, gui.PIVOT_CENTER)
	gui.set_color(node, LDSET.editor.marker.color or COL_ORANGE)
	return node
end

local function add_locked_key_marker(self, R, door, meta)
    if not (self and R and meta and R.group) then return end

    R.key_markers = R.key_markers or {}
    meta.key_nodes = nil

    local side = (meta.side or (door and door.side)) or "right"
    local pos = vmath.vector3(meta.cx or 0, meta.cy or 0, LOCK_KEY_Z)
    local dir = 1

    if side == "left" then
        pos.x = pos.x + LOCK_KEY_OFFSET
        dir = 1
    elseif side == "right" then
        pos.x = pos.x - LOCK_KEY_OFFSET
        dir = -1
    elseif side == "down" then
        pos.y = pos.y + LOCK_KEY_OFFSET
        dir = 1
    elseif side == "up" then
        pos.y = pos.y - LOCK_KEY_OFFSET
        dir = -1
    else
        pos.x = pos.x + LOCK_KEY_OFFSET
        side = "right"
        dir = -1
    end

    local head = gui.new_box_node(pos, vmath.vector3(LOCK_KEY_HEAD_SIZE, LOCK_KEY_HEAD_SIZE, 0))
    gui.set_parent(head, R.group, false)
    gui.set_pivot(head, gui.PIVOT_CENTER)
    gui.set_color(head, LOCK_KEY_COLOR_HEAD)
    R.key_markers[#R.key_markers + 1] = head

    local key_nodes = { head }

    if LOCK_KEY_HEAD_HOLE > 0 then
        local hole = gui.new_box_node(vmath.vector3(pos.x, pos.y, pos.z + 0.001), vmath.vector3(LOCK_KEY_HEAD_HOLE, LOCK_KEY_HEAD_HOLE, 0))
        gui.set_parent(hole, R.group, false)
        gui.set_pivot(hole, gui.PIVOT_CENTER)
        gui.set_color(hole, LOCK_KEY_COLOR_HOLE)
        R.key_markers[#R.key_markers + 1] = hole
        key_nodes[#key_nodes + 1] = hole
    end

    local is_vertical = (side == "up" or side == "down")
    local shaft_len = LOCK_KEY_SHAFT_LEN
    local shaft_thick = LOCK_KEY_SHAFT_THICK
    local tooth_len = math.max(shaft_thick, shaft_thick * 1.4)

    if is_vertical then
        local shaft_center = vmath.vector3(
            pos.x,
            pos.y + dir * ((LOCK_KEY_HEAD_SIZE * 0.5) + (shaft_len * 0.5)),
            pos.z
        )
        local shaft = gui.new_box_node(shaft_center, vmath.vector3(shaft_thick, shaft_len, 0))
        gui.set_parent(shaft, R.group, false)
        gui.set_pivot(shaft, gui.PIVOT_CENTER)
        gui.set_color(shaft, LOCK_KEY_COLOR_SHAFT)
        R.key_markers[#R.key_markers + 1] = shaft
        key_nodes[#key_nodes + 1] = shaft

        local tooth_center = vmath.vector3(
            pos.x,
            pos.y + dir * ((LOCK_KEY_HEAD_SIZE * 0.5) + shaft_len - (shaft_thick * 0.5)),
            pos.z
        )
        local tooth = gui.new_box_node(tooth_center, vmath.vector3(tooth_len, shaft_thick, 0))
        gui.set_parent(tooth, R.group, false)
        gui.set_pivot(tooth, gui.PIVOT_CENTER)
        gui.set_color(tooth, LOCK_KEY_COLOR_SHAFT)
        R.key_markers[#R.key_markers + 1] = tooth
        key_nodes[#key_nodes + 1] = tooth
    else
        local shaft_center = vmath.vector3(
            pos.x + dir * ((LOCK_KEY_HEAD_SIZE * 0.5) + (shaft_len * 0.5)),
            pos.y,
            pos.z
        )
        local shaft = gui.new_box_node(shaft_center, vmath.vector3(shaft_len, shaft_thick, 0))
        gui.set_parent(shaft, R.group, false)
        gui.set_pivot(shaft, gui.PIVOT_CENTER)
        gui.set_color(shaft, LOCK_KEY_COLOR_SHAFT)
        R.key_markers[#R.key_markers + 1] = shaft
        key_nodes[#key_nodes + 1] = shaft

        local tooth_center = vmath.vector3(
            pos.x + dir * ((LOCK_KEY_HEAD_SIZE * 0.5) + shaft_len - (shaft_thick * 0.5)),
            pos.y,
            pos.z
        )
        local tooth = gui.new_box_node(tooth_center, vmath.vector3(shaft_thick, tooth_len, 0))
        gui.set_parent(tooth, R.group, false)
        gui.set_pivot(tooth, gui.PIVOT_CENTER)
        gui.set_color(tooth, LOCK_KEY_COLOR_SHAFT)
        R.key_markers[#R.key_markers + 1] = tooth
        key_nodes[#key_nodes + 1] = tooth
    end

    meta.key_nodes = key_nodes
end

-- Arrow indicating lock direction (from red -> yellow) when doors overlap
local function add_lock_arrow(self, world_from, world_to, side_from, color)
    local parent = UI.ensure_canvas_root(self)
    -- Use fixed screen pixels for arrow thickness/length (parent is not scaled)
    local t = (LDSET.editor and LDSET.editor.arrow and LDSET.editor.arrow.thickness_px) or 3
    local L = (LDSET.editor and LDSET.editor.arrow and LDSET.editor.arrow.len_px) or 16
    local z = (LDSET.editor and LDSET.editor.arrow and LDSET.editor.arrow.z_offset) or 0.09
    local shaft_color = (LDSET.editor and LDSET.editor.arrow and LDSET.editor.arrow.color) or (LDSET.editor and LDSET.editor.marker and LDSET.editor.marker.color) or color or COL_ORANGE

    local horiz = (side_from=="left" or side_from=="right")
    local dir   = (side_from=="left" or side_from=="down") and 1 or -1

    -- Shaft center: slightly toward the target
    local cx, cy
    if horiz then
        cx = world_from.x + dir * (L * 0.5)
        cy = world_from.y
    else
        cx = world_from.x
        cy = world_from.y + dir * (L * 0.5)
    end

    local shaft = gui.new_box_node(vmath.vector3(cx, cy, z), vmath.vector3(L, t, 0))
    gui.set_parent(shaft, parent, false)
    gui.set_pivot(shaft, gui.PIVOT_CENTER)
	gui.set_rotation(shaft, vmath.quat_rotation_z(horiz and 0 or math.rad(90)))
    gui.set_color(shaft, shaft_color)

    -- Head: small crossbar at the tip pointing to the open door
    local hx, hy
    if horiz then
        hx = world_from.x + dir * L
        hy = world_from.y
    else
        hx = world_from.x
        hy = world_from.y + dir * L
    end
    local head = gui.new_box_node(vmath.vector3(hx, hy, z), vmath.vector3(t, t, 0))
    gui.set_parent(head, parent, false)
    gui.set_pivot(head, gui.PIVOT_CENTER)
    gui.set_color(head, shaft_color)

    return { shaft, head }
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Locked-door classification
-- recolor when two facing doors overlap and are mixed locked/open â†’ orange
-- Replace the recolor_doors_for_overlaps function in your render.lua with this version:

function M.recolor_doors_for_overlaps(self)
	local settings = LDSET.editor or {}
	local recolor_enabled = settings.overlap_recolor_enabled ~= false
	local full_thickness = base_door_thickness(self)  -- Full thickness for unsnapped doors (no reduction)
	local inset_thickness = door_visual_inset_thickness(self)  -- Reduced thickness for snapped doors

	local ALL = {}
	for _, R in pairs(self.rooms or {}) do
		for i, meta in ipairs(R.doors_meta or {}) do
			local manual_inset = meta and meta.manual_inset_px
			if manual_inset then
				meta.wants_inset = true
				local desired = inset_thickness
				local needs_rebuild = (not meta.cut_half) or (meta.inset_px ~= manual_inset) or math.abs((meta.thickness_px or 0) - desired) > 0.1
				if needs_rebuild then
					if meta.node then gui.delete_node(meta.node) end
					local door = R.shape and R.shape.doors and R.shape.doors[i]
					if door then
						local new_node, used_thickness = create_inset_door_node(self, R.group, door, meta.side or door.side, manual_inset)
						meta.node = new_node
						meta.inset_px = manual_inset
						meta.thickness_px = used_thickness or desired
						meta.cut_half = true
						R.door_nodes[i] = new_node
						if new_node then
							gui.set_color(new_node, (meta.state=="locked") and COL_RED or COL_YELLOW)
						end
					end
				end
			else
				meta.wants_inset = false
				local needs_rebuild = meta.cut_half or math.abs((meta.thickness_px or 0) - full_thickness) > 0.1
				if needs_rebuild then
					if meta.node then gui.delete_node(meta.node) end
					local door = R.shape and R.shape.doors and R.shape.doors[i]
					if door then
						local color = (meta.state=="locked") and COL_RED or COL_YELLOW
						local new_node = create_full_door_node(self, R.group, door, color)
						meta.node = new_node
						meta.cut_half = false
						meta.inset_px = nil
						meta.thickness_px = full_thickness
						R.door_nodes[i] = new_node
					end
				end
			end
			local gp = gui.get_position(R.group)
			local sc = self.zoom
			local base = R.base_pos or vmath.vector3()
			local layout_world = vmath.vector3(base.x + meta.cx, base.y + meta.cy, 0)
			local screen_world = vmath.vector3(gp.x + meta.cx * sc, gp.y + meta.cy * sc, 0)
			ALL[#ALL+1] = { R=R, i=i, node=meta.node, side=meta.side, state=meta.state, layout=layout_world, screen=screen_world }
			if meta.node then
				gui.set_color(meta.node, (meta.state=="locked") and COL_RED or COL_YELLOW)
			end
		end
	end

	for _, R in pairs(self.rooms or {}) do
		UI.clear_nodes(R.marker_nodes)
		R.marker_nodes = {}
	end

	local proximity_check = settings.recolor_on_proximity
	if proximity_check == nil then proximity_check = true end

	local overlap_threshold_px
	if proximity_check then
		overlap_threshold_px = settings.overlap_px or 8
	else
		overlap_threshold_px = settings.true_overlap_px or 4
	end

	local overlap_threshold2 = overlap_threshold_px * overlap_threshold_px
	local overlap_push_px = S.door and S.door.overlap_visual_push_px
	if overlap_push_px == nil then
		overlap_push_px = 50
	else
		overlap_push_px = tonumber(overlap_push_px) or 0
	end
	local pairs_orange = 0

	locklog("recolor mode: proximity_check=%s, threshold=%.1fpx", 
	tostring(proximity_check), overlap_threshold_px)

	for a=1,#ALL do
		for b=a+1,#ALL do
			local A, B = ALL[a], ALL[b]
			local lr = (A.side=="left" and B.side=="right") or (A.side=="right" and B.side=="left")
			local ud = (A.side=="up"   and B.side=="down")  or (A.side=="down"  and B.side=="up")

			if lr or ud then
				local dx, dy = (A.layout.x - B.layout.x), (A.layout.y - B.layout.y)
				local distance2 = dx*dx + dy*dy

				if distance2 <= overlap_threshold2 then
					-- Handle overlapping doors by recreating nodes inset toward their rooms
					local meta_a = A.R.doors_meta[A.i]
					local meta_b = B.R.doors_meta[B.i]

					if meta_a then meta_a.wants_inset = true end
					if meta_b then meta_b.wants_inset = true end

					-- Recreate the door nodes inset toward their rooms so both remain visible
					if meta_a and (not meta_a.cut_half or meta_a.inset_px ~= overlap_push_px or math.abs((meta_a.thickness_px or 0) - inset_thickness) > 0.1) then
						if meta_a.node then gui.delete_node(meta_a.node) end
						local door_a = A.R.shape.doors[A.i]
						if door_a then
							local new_node_a, used_thickness_a = create_inset_door_node(self, A.R.group, door_a, A.side, overlap_push_px)
							meta_a.node = new_node_a
							A.R.door_nodes[A.i] = new_node_a
							if new_node_a then
								gui.set_color(new_node_a, (meta_a.state=="locked") and COL_RED or COL_YELLOW)
							end
							meta_a.cut_half = true
							meta_a.inset_px = overlap_push_px
							meta_a.thickness_px = used_thickness_a or inset_thickness
						end
					end
					if meta_b and (not meta_b.cut_half or meta_b.inset_px ~= overlap_push_px or math.abs((meta_b.thickness_px or 0) - inset_thickness) > 0.1) then
						if meta_b.node then gui.delete_node(meta_b.node) end
						local door_b = B.R.shape.doors[B.i]
						if door_b then
							local new_node_b, used_thickness_b = create_inset_door_node(self, B.R.group, door_b, B.side, overlap_push_px)
							meta_b.node = new_node_b
							B.R.door_nodes[B.i] = new_node_b
							if new_node_b then
								gui.set_color(new_node_b, (meta_b.state=="locked") and COL_RED or COL_YELLOW)
							end
							meta_b.cut_half = true
							meta_b.inset_px = overlap_push_px
							meta_b.thickness_px = used_thickness_b or inset_thickness
						end
					end
					if recolor_enabled and ((A.state=="locked" and B.state=="open") or (A.state=="open" and B.state=="locked")) then
						pairs_orange = pairs_orange + 1
						locklog("orange pair: %s(%s) <-> %s(%s) (doors inset %.0fpx)", A.R.id or "?", A.state, B.R.id or "?", B.state, overlap_push_px)
						local from, to = A, B
						if A.state=="open" and B.state=="locked" then from, to = B, A end
						local parts = add_lock_arrow(self, from.screen, to.screen, from.side, COL_ORANGE)
						if parts then
							for _,n in ipairs(parts) do from.R.marker_nodes[#from.R.marker_nodes+1] = n end
						end
					end
				end
				end
		end
	end

	for _, entry in ipairs(ALL) do
		local meta = entry.R.doors_meta and entry.R.doors_meta[entry.i]
		if meta then
			if meta.cut_half and not meta.wants_inset then
				if meta.node then gui.delete_node(meta.node) end
				local door = entry.R.shape and entry.R.shape.doors and entry.R.shape.doors[entry.i]
				if door then
					local color = (meta.state=="locked") and COL_RED or COL_YELLOW
					local restored = create_full_door_node(self, entry.R.group, door, color)
					meta.node = restored
					entry.R.door_nodes[entry.i] = restored
				else
					meta.node = nil
				end
				meta.cut_half = false
				meta.inset_px = nil
				meta.thickness_px = full_thickness
			elseif meta.cut_half and math.abs((meta.thickness_px or 0) - inset_thickness) > 0.1 then
				if meta.node then gui.delete_node(meta.node) end
				local door = entry.R.shape and entry.R.shape.doors and entry.R.shape.doors[entry.i]
				if door then
					local new_node, used_thickness = create_inset_door_node(self, entry.R.group, door, meta.side, meta.inset_px or 0)
					meta.node = new_node
					entry.R.door_nodes[entry.i] = new_node
					if new_node then
						gui.set_color(new_node, (meta.state=="locked") and COL_RED or COL_YELLOW)
					end
					meta.thickness_px = used_thickness or inset_thickness
				else
					meta.node = nil
				end
			elseif (not meta.cut_half) and math.abs((meta.thickness_px or 0) - full_thickness) > 0.1 then
				if meta.node then gui.delete_node(meta.node) end
				local door = entry.R.shape and entry.R.shape.doors and entry.R.shape.doors[entry.i]
				if door then
					local color = (meta.state=="locked") and COL_RED or COL_YELLOW
					local new_node = create_full_door_node(self, entry.R.group, door, color)
					meta.node = new_node
					entry.R.door_nodes[entry.i] = new_node
					meta.thickness_px = full_thickness
				else
					meta.node = nil
				end
			end
			meta.wants_inset = nil
		end
	end

	locklog("overlap check: pairs=%d, mode=%s", pairs_orange, 
	proximity_check and "proximity" or "true_overlap")
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- draw a room (outline, fill, doors)

function M.draw_room(self, R, shape)
	release_fill_texture(R)
	UI.clear_nodes(R.fill_nodes);    R.fill_nodes    = {}
	UI.clear_nodes(R.outline_nodes); R.outline_nodes = {}
	UI.clear_nodes(R.door_nodes);    R.door_nodes    = {}
	UI.clear_nodes(R.marker_nodes);  R.marker_nodes  = {}
	UI.clear_nodes(R.key_markers); R.key_markers = {}
	UI.delete_safe(R.label_node); R.label_node = nil
	R.doors_meta = {}

	local P_full = shape.poly or {}
	local P      = poly_reduce_colinear(P_full, 0.9995)
	local outline_segments = math.max(0, #P - 1)
	local _, concave_count = compute_concave_flags(P)
	local door_count = #(shape.doors or {})

	local fill_mode = (S.preview and S.preview.fill_mode) or "precise"
	local used_texture = false

	-- Skip all fill rendering if disabled
	if fill_mode == "disabled" then
		logf("fill disabled for %s", tostring(R.id))
		-- No fill nodes will be created
	elseif fill_mode == "texture" then
		used_texture = draw_fill_texture_mask(self, R, shape)
		if not used_texture then
			logf("texture fill fallback for %s", tostring(R.id))
			fill_mode = "precise"
		end
	end

	if not used_texture and fill_mode ~= "disabled" then
		local rects
		if fill_mode == "tilemask" then
			rects = shape.rects or {}
		else
			rects = select(1, choose_fill_rects_for_budget(self, shape, outline_segments, concave_count, door_count))
		end

		local bias_cfg = (S.preview and S.preview.fill_coverage_bias_px) or 0
		local bias_x, bias_y
		if type(bias_cfg) == "table" then
			bias_x = tonumber(bias_cfg.x) or 0
			bias_y = tonumber(bias_cfg.y) or 0
		else
			bias_x = tonumber(bias_cfg) or 0
			bias_y = 0
		end

		for _, rc in ipairs(rects) do
			local x = rc.x - bias_x; local y = rc.y - bias_y
			local w = rc.w + bias_x*2; local h = rc.h + bias_y*2
			if x < 0 then w = w + x; x = 0 end
			if y < 0 then h = h + y; y = 0 end
			if x + w > shape.w_px then w = shape.w_px - x end
			if y + h > shape.h_px then h = shape.h_px - y end
			if w > 0.5 and h > 0.5 then
				local n = gui.new_box_node(vmath.vector3(x, y, 0), vmath.vector3(w, h, 0))
				gui.set_parent(n, R.group, false)
				gui.set_pivot(n, gui.PIVOT_SW)
				gui.set_color(n, COL_FILL)
				R.fill_nodes[#R.fill_nodes+1] = n
			end
		end

		if #R.fill_nodes == 0 then
			if not raster_fill_polygon(self, R, shape) then
				local fallback = shape.rects or {}
				if #fallback > 0 then
					local current_nodes = UI.count_scene_nodes(self)
					local node_limit = NODE_LIMIT or 512
					local safe_margin = SAFE_MARGIN or 24
					local allowed = math.max(0, (node_limit - safe_margin) - current_nodes)
					if allowed > 0 then
						table.sort(fallback, function(a, b) return (a.w or 0)*(a.h or 0) > (b.w or 0)*(b.h or 0) end)
						for i = 1, math.min(allowed, #fallback) do
							local rc = fallback[i]
							local w = rc.w or 0
							local h = rc.h or 0
							if w > 0.5 and h > 0.5 then
								local node = gui.new_box_node(vmath.vector3(rc.x or 0, rc.y or 0, 0), vmath.vector3(w, h, 0))
								gui.set_parent(node, R.group, false)
								gui.set_pivot(node, gui.PIVOT_SW)
								gui.set_color(node, COL_FILL)
								R.fill_nodes[#R.fill_nodes+1] = node
							end
						end
					end
				end
				if #R.fill_nodes == 0 then
					local n = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(shape.w_px, shape.h_px, 0))
					gui.set_parent(n, R.group, false)
					gui.set_pivot(n, gui.PIVOT_SW)
					gui.set_color(n, COL_FILL)
					R.fill_nodes[#R.fill_nodes+1] = n
				end
			end
		end
	end

	-- Use yellow outline for selected rooms, default light blue for others
	local outline_color = (R.selected) and COL_OUTLINE_SELECTED or COL_OUTLINE
	local nodes = select(1, draw_outline(self, R.group, P, outline_color))
	for i=1,#nodes do R.outline_nodes[#R.outline_nodes+1] = nodes[i] end

    -- Doors (yellow by default). Geometry extractor already insets to wall line.
    local dnodes = draw_doors(self, R.group, shape.doors or {}, COL_YELLOW, 0)
	for i=1,#dnodes do R.door_nodes[#R.door_nodes+1] = dnodes[i] end

	for i, d in ipairs(shape.doors or {}) do
		local cx = (d.x0 + d.x1) * 0.5
		local cy = (d.y0 + d.y1) * 0.5
        -- Keep exact extractor centers (no extra offset)

        local state = "open"
        R.doors_meta[i] = {
			node = dnodes[i],
			side = d.side,
			cx = cx,
			cy = cy,
			state = state,
			thickness_px = base_door_thickness(self),  -- Initially full thickness
			key_nodes = nil,
		}
        locklog("%s door meta #%d  side=%s  cx=%.1f cy=%.1f", R.id or "?", i, d.side, cx, cy)
    end

	-- ðŸ”´ classify + recolor for locked
    local states = LockedDoorReader.classify_locked_doors(R.tilemap_path, shape, shape.doors or {})
    for i, st in ipairs(states) do
        local meta = R.doors_meta[i]
        if meta then
            meta.state = st
            if meta.node then
                gui.set_color(meta.node, (st=="locked") and COL_RED or COL_YELLOW)
            end
            if st == "locked" then
                local door = shape.doors and shape.doors[i]
                add_locked_key_marker(self, R, door, meta)
            end
        end
    end

    if (S.canvas and S.canvas.show_zero_door_rooms) and (#(shape.doors or {}) == 0) then
        local warn = gui.new_text_node(vmath.vector3(shape.w_px * 0.5, shape.h_px + 16, 0.1), "NO DOORS")
        gui.set_parent(warn, R.group, false)
        gui.set_pivot(warn, gui.PIVOT_CENTER)
        gui.set_color(warn, vmath.vector4(1, 0.6, 0.2, 0.9))
        gui.set_scale(warn, vmath.vector3(0.8, 0.8, 1))
        R.marker_nodes[#R.marker_nodes+1] = warn
        logf("warning: %s extracted with zero doors", tostring(R.id))
    end
	-- No per-door markers here; arrows are handled during overlap recolor.
	local label_text = (R.id or ""):gsub("^/+", ""):gsub("_", " ")
	local label_node = gui.new_text_node(vmath.vector3(shape.w_px * 0.5, shape.h_px * 0.5, 0.05), label_text)
	gui.set_parent(label_node, R.group, false)
	gui.set_pivot(label_node, gui.PIVOT_CENTER)
	gui.set_color(label_node, (S.palette and S.palette.room_label) or vmath.vector4(0.95, 0.98, 1.0, 1.0))
	pcall(gui.set_font, label_node, hash("room_label"))
	local label_scale = tonumber(S.preview and S.preview.room_label_scale) or 1.0
	if label_scale ~= 1.0 then
		gui.set_scale(label_node, vmath.vector3(label_scale, label_scale, 1))
	end
	R.label_node = label_node
	R.label_base_scale = label_scale
end

function M.release_room_resources(R)
	release_fill_texture(R)
end

-- Update outline color for a room (used when selection changes)
function M.update_room_outline_color(R)
	if not R or not R.outline_nodes then return end
	local color = (R.selected) and COL_OUTLINE_SELECTED or COL_OUTLINE
	for _, node in ipairs(R.outline_nodes) do
		if node then
			gui.set_color(node, color)
		end
	end
end

return M

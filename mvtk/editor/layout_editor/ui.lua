local Viewport = require "mvtk.ui.viewport"
-- mvtk/editor/layout_editor/ui.lua
-- Layout Editor UI helpers (vZ42)
-- Responsibilities:
--  * Safe node ops, z-order
--  * Window/canvas rect, canvas root
--  * Sidebar + manifest read
--  * Node budgeting/count

local Util = require "mvtk.core.util"
local S = Util.require_config("developer.config.layout_editor_settings")
local LayoutIO = require "mvtk.rooms.layout_io"
local Geometry = require "mvtk.rooms.tilemap_geometry"
local RoomsCfg = Util.require_config("developer.config.rooms_config")
local Tile = Util.require_config("developer.config.tile_settings")
local StreamPaths = require "mvtk.rooms.stream_paths"

local M = {}

-- ----------------------------------------------------------------
-- Logging

local function logf(fmt, ...) print(string.format("[LE.UI] "..fmt, ...)) end

-- ----------------------------------------------------------------
-- Safe node helpers

function M.get_node_safe(id)
	local ok, n = pcall(gui.get_node, id)
	return ok and n or nil
end

function M.point_in_node(n, x, y)
	if not n then return false end
	local ok, inside = pcall(gui.pick_node, n, x, y)
	return ok and inside or false
end

function M.delete_safe(n)
	if not n then return end
	local ok = pcall(gui.get_position, n)
	if ok then gui.delete_node(n) end
end

function M.clear_nodes(list)
	if not list then return end
	for i = #list, 1, -1 do M.delete_safe(list[i]); list[i] = nil end
end

function M.set_z(n, z)
	if not n then return end
	local p=gui.get_position(n); p.z=z; gui.set_position(n,p)
end

-- ----------------------------------------------------------------
-- Window / canvas

local function design_size()
	return Viewport.design_size()
end

function M.compute_canvas_rect(self)
	local win_w, win_h = design_size()
	local m  = (S.canvas and S.canvas.margin_px) or 16
	local sw = (S.sidebar and S.sidebar.width_px) or 340
	self.canvas = { x=m, y=m, w=win_w - sw - m*2, h=win_h - m*2 }
	self.canvas.cx = self.canvas.x + self.canvas.w * 0.5
	self.canvas.cy = self.canvas.y + self.canvas.h * 0.5
end

function M.ensure_canvas_root(self)
	if self.n_canvas then return self.n_canvas end
	self.n_canvas = gui.new_box_node(vmath.vector3(0,0,-0.8), vmath.vector3(1,1,0))
	gui.set_parent(self.n_canvas, self.n_root or gui.get_node("root"), false)
	gui.set_pivot(self.n_canvas, gui.PIVOT_SW)
	gui.set_color(self.n_canvas, vmath.vector4(0,0,0,0))
	logf("canvas_root created with z=-0.8")
	return self.n_canvas
end

-- Place chrome (labels/buttons) inside current viewport bounds
function M.position_chrome(self)
	local w, h = design_size()
	local m = 20
	if self.n_btn_menu then
		gui.set_pivot(self.n_btn_menu, gui.PIVOT_NW)
		gui.set_position(self.n_btn_menu, vmath.vector3(m, h - m, 0))
		local menu_label = self.n_btn_menu_label or M.get_node_safe("btn_menu_label")
		if menu_label then
			local size = gui.get_size(self.n_btn_menu)
			gui.set_pivot(menu_label, gui.PIVOT_CENTER)
			gui.set_position(menu_label, vmath.vector3(size.x * 0.5, -size.y * 0.5, 0))
		end
	end
	-- Position the room list container (which holds the header and list items)
	if self.n_room_list_container then
		gui.set_position(self.n_room_list_container, vmath.vector3(w - m, h - m, 0))
	end
	if self.n_trash then
		local size = gui.get_size(self.n_trash)
		gui.set_pivot(self.n_trash, gui.PIVOT_CENTER)
		local sx, sy = Viewport.to_screen(w - m - (size.x * 0.5), m + (size.y * 0.5))
		if sx then gui.set_screen_position(self.n_trash, vmath.vector3(sx, sy, 0)) end
		local trash_label = self.n_trash_label or M.get_node_safe("txt_trash")
		if trash_label then
			gui.set_pivot(trash_label, gui.PIVOT_CENTER)
			gui.set_position(trash_label, vmath.vector3(0, 0, 0))
		end
	end
end

-- ----------------------------------------------------------------
-- Sidebar (rooms list from manifest)


local function make_room_list_item(self, index, room_id, text_value)
	local item_h = tonumber(S.sidebar and S.sidebar.item_h_px) or 22
	local gap = tonumber(S.sidebar and S.sidebar.item_gap_px) or 6
	local spacing = item_h + gap
	local hit_w = 240
	local hit_h = item_h + 6

	-- Position relative to the clipping box starting from top (y=0)
	-- Apply scroll offset
	local scroll_offset = self.room_list_scroll_offset or 0
	local y_offset = -((index - 1) * spacing) + scroll_offset

	-- Parent to clipping box if available, otherwise to container
	local parent_node = self.n_room_list_clip or self.n_room_list_container or self.n_root

	local hit = gui.new_box_node(vmath.vector3(0, y_offset, -0.01), vmath.vector3(hit_w, hit_h, 0))
	gui.set_parent(hit, parent_node, false)
	gui.set_pivot(hit, gui.PIVOT_NE)
	gui.set_color(hit, vmath.vector4(0,0,0,0))

	local node = gui.new_text_node(vmath.vector3(-8, y_offset + 2, 0), text_value)
	gui.set_parent(node, parent_node, false)
	gui.set_pivot(node, gui.PIVOT_NE)
	gui.set_color(node, (S.palette and S.palette.text) or vmath.vector4(1, 1, 1, 1))

	M.set_z(hit, 0.68)
	M.set_z(node, 0.70)
	return { node = node, hit = hit, id = room_id }
end

local function manifest_path()
	local app  = S.app_id or "mvtk_layout_editor"
	local file = S.auto_manifest_filename or "rooms_auto"
	return sys.get_save_file(app, file)
end

local function normalise_manifest_rooms(data)
	if type(data) ~= "table" then return {} end
	local rooms = data.rooms or data
	if type(rooms) ~= "table" then return {} end
	local list = {}
	if #rooms > 0 then
		for _, entry in ipairs(rooms) do
			if type(entry) == "table" then list[#list+1] = entry end
		end
	else
		for _, entry in pairs(rooms) do
			if type(entry) == "table" then list[#list+1] = entry end
		end
	end
	for _, entry in ipairs(list) do
		if not entry.id and entry.path then
			entry.id = entry.path:match("([^/]+)$") or entry.path
		end
	end
	table.sort(list, function(a, b)
		return tostring(a.id or "") < tostring(b.id or "")
	end)
	return list
end

local function fallback_rooms_from_config()
	local list = {}
	if not RoomsCfg or type(RoomsCfg.factories) ~= "table" then
		logf("fallback: rooms_config missing or malformed")
		return list
	end
	logf("fallback: building list from config.rooms_config (%d entries)", (RoomsCfg and RoomsCfg.factories) and (function(tbl) local c=0 for _ in pairs(tbl) do c=c+1 end return c end)(RoomsCfg.factories) or 0)
	local seen = {}
	for path, _ in pairs(RoomsCfg.factories) do
		local raw = tostring(path or ""):gsub("^developer/rooms/", "")
		if raw ~= "" and not seen[raw] then
			seen[raw] = true
			local canonical = LayoutIO.normalize_id(raw, S.rooms_zero_pad or 2) or raw
			local w, h = nil, nil
			if Geometry and Geometry.load then
				local ok, geom = pcall(Geometry.load, raw)
				if ok and type(geom) == "table" then
					w = tonumber(geom.width_px)
					h = tonumber(geom.height_px)
				end
			end
			w = w or ((Tile and Tile.width) or 128) * 10
			h = h or ((Tile and Tile.height) or 128) * 10
			list[#list + 1] = {
				id = canonical,
				width = w,
				height = h,
				tilemap = StreamPaths.tiled_tilemap(raw),
				tile = Tile and Tile.width or 128,
				manifest = { id = canonical },
			}
			logf("fallback: added %s (%dx%d)", tostring(canonical), w or -1, h or -1)
		end
	end
	table.sort(list, function(a, b) return tostring(a.id or "") < tostring(b.id or "") end)
	return list
end

local function set_rooms_header(count)
	local header = M.get_node_safe("txt_rooms")
	if header then
		if count and count > 0 then
			gui.set_text(header, string.format("Rooms (%d)", count))
		else
			gui.set_text(header, "Rooms")
		end
	end
end

function M.rebuild_rooms_sidebar(self)
	if not self then return end
	for _, item in ipairs(self.sidebar_items or {}) do
		M.delete_safe(item.node)
		M.delete_safe(item.hit)
	end
	self.sidebar_items = {}
	self.available_room_items = {}
	self.room_index = {}
	if M.position_chrome then M.position_chrome(self) end
	local header_pos = self.n_lbl_rooms and gui.get_screen_position(self.n_lbl_rooms)
	local header_size = self.n_lbl_rooms and gui.get_size(self.n_lbl_rooms)
	logf("sidebar header pos=(%.1f,%.1f) size=(%.1f,%.1f)", header_pos and header_pos.x or -1, header_pos and header_pos.y or -1, header_size and header_size.x or -1, header_size and header_size.y or -1)

	local path = manifest_path()
	local ok, manifest = pcall(sys.load, path)
	if not ok or type(manifest) ~= "table" then
		logf("rooms manifest missing or corrupt: %s", tostring(path))
		manifest = nil
	end

	local rooms = normalise_manifest_rooms(manifest)
	if #rooms == 0 then
		logf("manifest empty, using fallback from config.rooms_config")
		rooms = fallback_rooms_from_config()
	else
		logf("manifest rooms loaded: %d", #rooms)
		for i, entry in ipairs(rooms) do
			logf("  [%d] id=%s tilemap=%s w=%s h=%s", i, tostring(entry.id or entry.name), tostring(entry.tilemap or entry.path), tostring(entry.w or entry.width), tostring(entry.h or entry.height))
		end
	end

	local taken = {}
	for id in pairs(self.rooms or {}) do
		local cid = LayoutIO.normalize_id(id, S.rooms_zero_pad or 2)
		if cid then taken[cid] = true end
	end
    local index = 1
    for _, entry in ipairs(rooms) do
        local id = entry.id or entry.name
		if id then
			local canonical = LayoutIO.normalize_id(id, S.rooms_zero_pad or 2) or tostring(id)
			local label = canonical:gsub("^/+", "")

			local w = tonumber(entry.w) or tonumber(entry.width)
			local h = tonumber(entry.h) or tonumber(entry.height)
			local info = {
				id = label,
				width = w,
				height = h,
				tile = tonumber(entry.tile),
				rects = entry.rects,
				diags = entry.diags,
				tilemap = entry.tilemap or entry.path,
				manifest = entry,
				raw_id = canonical,
			}
			self.room_index[label] = info
			if label ~= canonical then
				self.room_index[canonical] = info
			end

		if not taken[canonical] then
			local item = make_room_list_item(self, index, label, label)
			item.raw_id = canonical
			self.sidebar_items[#self.sidebar_items+1] = item
			self.available_room_items[canonical] = item
			index = index + 1
		end
		end
	end

	set_rooms_header(#(self.sidebar_items or {}))
	logf("rooms sidebar rebuilt: %d available entries", #(self.sidebar_items or {}))
end

-- Update room list item positions based on scroll offset
function M.update_room_list_scroll(self)
	if not self or not self.sidebar_items then
		logf("update_room_list_scroll: no self or sidebar_items")
		return
	end
	local item_h = tonumber(S.sidebar and S.sidebar.item_h_px) or 22
	local spacing = item_h + (tonumber(S.sidebar and S.sidebar.item_gap_px) or 6)
	local scroll_offset = self.room_list_scroll_offset or 0

	logf("update_room_list_scroll: offset=%d, items=%d, spacing=%d", scroll_offset, #self.sidebar_items, spacing)

	for index, item in ipairs(self.sidebar_items) do
		local y_offset = - ((index - 1) * spacing) + scroll_offset

		if item.node then
			local old_pos = gui.get_position(item.node)
			old_pos.y = y_offset + 2
			gui.set_position(item.node, old_pos)
			local new_pos = gui.get_position(item.node)
			if index == 1 or index == #self.sidebar_items then
				logf("  item[%d] '%s': y=%d", index, item.id, new_pos.y)
			end
		end

		if item.hit then
			local pos = gui.get_position(item.hit)
			pos.y = y_offset
			gui.set_position(item.hit, pos)
		end
	end
	logf("update_room_list_scroll: updated %d items", #self.sidebar_items)
end

-- ----------------------------------------------------------------
-- Node budgeting (for render)

function M.count_scene_nodes(self)
	local cnt = 0
	if self.n_canvas then cnt = cnt + 1 end
	if self.grid_nodes then cnt = cnt + #self.grid_nodes end
	for _, R in pairs(self.rooms or {}) do
		cnt = cnt + 1
			+ #R.fill_nodes
			+ #R.outline_nodes
			+ (#R.door_nodes or 0)
			+ (#R.marker_nodes or 0)
			+ (#R.key_markers or 0)
	end
	return cnt
end

function M.remove_sidebar_item(self, target_item)
	if not (self and target_item) then return end
	if not self.sidebar_items then return end
	for idx, entry in ipairs(self.sidebar_items) do
		if entry == target_item then
			M.delete_safe(entry.node)
			M.delete_safe(entry.hit)
			table.remove(self.sidebar_items, idx)
			break
		end
	end
	if self.room_list_scroll_offset and self.room_list_scroll_offset > 0 then
		local item_h = tonumber(S.sidebar and S.sidebar.item_h_px) or 22
		local gap = tonumber(S.sidebar and S.sidebar.item_gap_px) or 6
		local spacing = item_h + gap
		local max_offset = math.max(0, (#(self.sidebar_items or {}) - 1) * spacing)
		if self.room_list_scroll_offset > max_offset then
			self.room_list_scroll_offset = max_offset
		end
	end
	M.update_room_list_scroll(self)
	set_rooms_header(#(self.sidebar_items or {}))
end

function M.remove_room_from_sidebar(self, room_id)
	if not self or not room_id then return end
	local canonical = LayoutIO.normalize_id(room_id, S.rooms_zero_pad or 2)
	if not canonical then return end
	local available = self.available_room_items or {}
	local item = available[canonical]
	if not item then return end
	M.remove_sidebar_item(self, item)
	available[canonical] = nil
end

return M

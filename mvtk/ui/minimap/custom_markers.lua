-- mvtk/developer/ui/minimap/custom_markers.lua
-- Helper for managing custom marker nodes on the minimap GUI.

local v3 = vmath.vector3
local v4 = vmath.vector4

local M = {}

local function ensure_marker_cfg(cfg)
    cfg = cfg or {}
    local size = cfg.size_px or 6
    return {
        size = size,
        color = cfg.rgba or v4(0.95, 0.65, 0.25, 0.9),
        facing_width = cfg.facing_width_px or math.max(2, size * 0.6),
        facing_height = cfg.facing_height_px or math.max(2, size * 0.25),
        facing_offset = cfg.facing_offset_px or (size * 0.75),
        facing_color = cfg.facing_rgba,
    }
end

local function resolve_facing(value)
    if value == nil then
        return nil
    end
    if type(value) == "number" then
        if value < 0 then return -1 end
        if value > 0 then return 1 end
        return nil
    end
    if type(value) == "string" then
        local lower = value:lower()
        if lower == "left" or lower == "-1" or lower == "west" then return -1 end
        if lower == "right" or lower == "1" or lower == "east" then return 1 end
    end
    return nil
end

function M.ensure_state(self, cfg)
    if not self.marker_nodes then
        self.marker_nodes = {}
    end
    self._marker_version = self._marker_version or -1
    self._marker_cfg = ensure_marker_cfg(cfg)
end

local function rebuild_nodes(self, count)
    for _, node in ipairs(self.marker_nodes) do
        if type(node) == "userdata" then
            gui.delete_node(node)
        else
            if node.box then
                gui.delete_node(node.box)
            end
            if node.facing then
                gui.delete_node(node.facing)
            end
        end
    end
    self.marker_nodes = {}
    local size = self._marker_cfg.size
    local color = self._marker_cfg.color
    local facing_color = self._marker_cfg.facing_color or color
    local facing_w = self._marker_cfg.facing_width
    local facing_h = self._marker_cfg.facing_height
    for i = 1, count do
        local box = gui.new_box_node(v3(0, 0, 0.028), v3(size, size, 0))
        gui.set_parent(box, self.container, false)
        gui.set_pivot(box, gui.PIVOT_CENTER)
        gui.set_color(box, color)

        local facing = gui.new_box_node(v3(0, 0, 0.028), v3(facing_w, facing_h, 0))
        gui.set_parent(facing, self.container, false)
        gui.set_pivot(facing, gui.PIVOT_CENTER)
        gui.set_color(facing, facing_color)

        self.marker_nodes[i] = { box = box, facing = facing }
    end
end

function M.sync(self, markers, version, center_x, center_y, zoom, offset_x, offset_y, pixel_snap)
    markers = markers or {}
    version = version or 0
    local needs_rebuild = false
    if self.marker_nodes and self.marker_nodes[1] and type(self.marker_nodes[1]) ~= "table" then
        needs_rebuild = true
    end
    if needs_rebuild or #self.marker_nodes ~= #markers or (self._marker_version or -1) ~= version then
        rebuild_nodes(self, #markers)
        self._marker_version = version
    end
    if not self.marker_nodes then
        return
    end
    for idx, node in ipairs(self.marker_nodes) do
        local marker = markers[idx]
        if marker then
            local map_x, map_y = marker.map_x, marker.map_y
            if not (map_x and map_y) then
                map_x = marker.x or 0
                map_y = marker.y or 0
            end
            local panel_x = (map_x - center_x) * zoom
            local panel_y = (map_y - center_y) * zoom
            local function step(v)
                return math.floor(v + 0.5)
            end
            if pixel_snap then
                panel_x = step(panel_x)
                panel_y = step(panel_y)
            end
            local base_x = panel_x + offset_x
            local base_y = panel_y + offset_y
            gui.set_position(node.box, v3(base_x, base_y, 0.028))
            gui.set_visible(node.box, true)

            local facing_dir = resolve_facing(marker.facing)
            if node.facing then
                if facing_dir then
                    local face_x = base_x + facing_dir * (self._marker_cfg.facing_offset or 0)
                    local face_y = base_y
                    if pixel_snap then
                        face_x = step(face_x)
                        face_y = step(face_y)
                    end
                    gui.set_position(node.facing, v3(face_x, face_y, 0.028))
                    gui.set_visible(node.facing, true)
                else
                    gui.set_visible(node.facing, false)
                end
            end
        else
            gui.set_visible(node.box, false)
            if node.facing then
                gui.set_visible(node.facing, false)
            end
        end
    end
end

function M.hide(self)
    if not self.marker_nodes then return end
    for _, node in ipairs(self.marker_nodes) do
        if type(node) == "userdata" then
            gui.set_visible(node, false)
        else
            if node.box then
                gui.set_visible(node.box, false)
            end
            if node.facing then
                gui.set_visible(node.facing, false)
            end
        end
    end
end

return M

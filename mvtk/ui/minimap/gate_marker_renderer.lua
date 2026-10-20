-- mvtk/developer/ui/minimap/gate_marker_renderer.lua
-- Renders gate markers on the minimap using color-coded squares.

local v3 = vmath.vector3
local v4 = vmath.vector4
local GateMarkers = require("mvtk.map.minimap.gate_markers")

local Time = require "mvtk.core.time"
local DEFAULT_SIZE = 8

local M = {}

local function ensure_config(self, cfg)
    cfg = cfg or {}
    self._gate_marker_cfg = cfg
    self._gate_marker_size = cfg.size_px or GateMarkers.MARKER_SIZE or DEFAULT_SIZE
end

local function rebuild_nodes(self, count)
    self.gate_marker_nodes = self.gate_marker_nodes or {}
    for _, node in ipairs(self.gate_marker_nodes) do
        gui.delete_node(node)
    end
    self.gate_marker_nodes = {}
    local size = self._gate_marker_size or DEFAULT_SIZE
    for i = 1, count do
        local node = gui.new_box_node(v3(0, 0, 0.029), v3(size, size, 0))
        gui.set_parent(node, self.container, false)
        gui.set_pivot(node, gui.PIVOT_CENTER)
        gui.set_visible(node, false)
        self.gate_marker_nodes[i] = node
    end
end

function M.ensure_state(self, cfg)
    ensure_config(self, cfg)
   self.gate_marker_nodes = self.gate_marker_nodes or {}
end

local function marker_color(marker_state, time_now)
    local colors = GateMarkers.COLORS or {}
    if marker_state == "unlocked" then
        local c = colors.UNLOCKED or v4(0.2, 0.8, 0.2, 0.5)
        return v4(c)
    elseif marker_state == "accessible" then
        local c = colors.ACCESSIBLE or v4(1.0, 0.8, 0.2, 0.9)
        local copy = v4(c)
        if GateMarkers.PULSE_ACCESSIBLE then
            local t = time_now or Time.gettime()
            local pulse = math.abs(math.sin(t * 3.0))
            copy.w = 0.5 + pulse * 0.4
        end
        return copy
    else
        local c = colors.LOCKED or v4(0.8, 0.2, 0.2, 0.9)
        return v4(c)
    end
end

function M.sync(self, markers, center_x, center_y, zoom, offset_x, offset_y, pixel_snap, time_now)
    markers = markers or {}
    M.ensure_state(self, self._gate_marker_cfg)

    if not self.gate_marker_nodes or #self.gate_marker_nodes ~= #markers then
        rebuild_nodes(self, #markers)
    end

    if not self.gate_marker_nodes then return end

    for idx, node in ipairs(self.gate_marker_nodes) do
        local marker = markers[idx]
        if marker then
            local px = (marker.map_x - center_x) * zoom
            local py = (marker.map_y - center_y) * zoom
            if pixel_snap then
                px = math.floor(px + 0.5)
                py = math.floor(py + 0.5)
            end
            gui.set_position(node, v3(px + offset_x, py + offset_y, 0.029))
            gui.set_color(node, marker_color(marker.state, time_now))
            gui.set_visible(node, true)
        else
            gui.set_visible(node, false)
        end
    end
end

function M.hide(self)
    if not self.gate_marker_nodes then return end
    for _, node in ipairs(self.gate_marker_nodes) do
        gui.set_visible(node, false)
    end
end

return M

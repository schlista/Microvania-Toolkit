-- mvtk/editor/layout_editor/controller_camera.lua
--
-- Camera and coordinate helpers for the layout editor controller.

local Util = require "mvtk.core.util"
local S = Util.require_config("developer.config.layout_editor_settings")
local LDSET = Util.require_config("developer.config.locked_door_settings")
local Render = require "mvtk.editor.layout_editor.render"

local Logger = require "mvtk.core.logger"
local log = Logger.get_logger("layout_editor.controller_camera")
local function logf(fmt, ...) log.debug(fmt, ...) end

local M = {}

function M.outline_thickness_px()
    return (S.preview and S.preview.outline_thick_px) or 12
end

function M.apply(self)
    for _, R in pairs(self.rooms or {}) do
        local origin = vmath.vector3(self.canvas.x, self.canvas.y, 0) + self.pan
        local snap = true
        if self.drag_room and R == self.drag_room then
            snap = false
        elseif S.canvas and S.canvas.pixel_snap ~= nil then
            snap = S.canvas.pixel_snap
        end
        if snap then
            origin.x = math.floor(origin.x + 0.5)
            origin.y = math.floor(origin.y + 0.5)
        end

        local pos = origin + (R.base_pos * self.zoom)
        gui.set_position(R.group, pos)
        gui.set_scale(R.group, vmath.vector3(self.zoom, self.zoom, 1))

        if R.label_node then
            local base = R.label_base_scale
            if base == nil then
                base = tonumber(S.preview and S.preview.room_label_scale) or 1.0
                R.label_base_scale = base
            end
            gui.set_scale(R.label_node, vmath.vector3(base, base, 1))
        end

        local t = M.outline_thickness_px(self)
        local dt = t * ((S.door and S.door.thickness_scale) or 1.0)

        for _, n in ipairs(R.outline_nodes) do
            local sz = gui.get_size(n)
            if math.abs(sz.y - t) > 0.01 then
                sz.y = t
                gui.set_size(n, sz)
            end
        end
        for _, n in ipairs(R.door_nodes) do
            local sz = gui.get_size(n)
            if math.abs(sz.y - dt) > 0.01 then
                sz.y = dt
                gui.set_size(n, sz)
            end
        end
        for _, n in ipairs(R.marker_nodes) do
            local sz = gui.get_size(n)
            if math.abs(sz.y - t) > 0.01 then
                sz.y = t
                gui.set_size(n, sz)
            end
        end
    end

    if LDSET.editor and LDSET.editor.overlap_recolor_enabled ~= false then
        Render.recolor_doors_for_overlaps(self)
    end
end

function M.canvas_origin(self)
    if not self or not self.canvas then
        return vmath.vector3(0, 0, 0)
    end
    return vmath.vector3(self.canvas.x or 0, self.canvas.y or 0, 0)
end

function M.viewport_center_screen(self)
    if not self or not self.canvas then
        return vmath.vector3(0, 0, 0)
    end
    return vmath.vector3(
        (self.canvas.x or 0) + ((self.canvas.w or 0) * 0.5),
        (self.canvas.y or 0) + ((self.canvas.h or 0) * 0.5),
        0
    )
end

function M.viewport_bottom_center_screen(self)
    if not self or not self.canvas then
        return vmath.vector3(0, 0, 0)
    end
    local margin = (S.canvas and S.canvas.spawn_bottom_margin_px) or 96
    if margin < 0 then margin = 0 end
    return vmath.vector3(
        (self.canvas.x or 0) + ((self.canvas.w or 0) * 0.5),
        (self.canvas.y or 0) + margin,
        0
    )
end

function M.screen_pos_to_base(self, desired)
    if not self then
        return vmath.vector3(0, 0, 0)
    end
    local zoom = self.zoom or 1
    if zoom == 0 then zoom = 1 end
    local pan = self.pan or vmath.vector3()
    local base = (desired - M.canvas_origin(self) - pan) / zoom
    base.z = 0
    return base
end

function M.default_room_spawn_base(self, shape)
    shape = shape or {}
    local zoom = self and self.zoom or 1
    if zoom == 0 then zoom = 1 end
    local desired = M.viewport_bottom_center_screen(self)
    desired.x = desired.x - ((shape.w_px or 0) * zoom * 0.5)
    return M.screen_pos_to_base(self, desired)
end

function M.align_view_on_room(self, room, mode)
    if not self or not room or not room.base_pos then
        return
    end

    local zoom = self.zoom or 1
    if zoom == 0 then zoom = 1 end

    local shape = room.shape or {}
    local target
    if mode == "bottom" then
        target = M.viewport_bottom_center_screen(self)
        target.x = target.x - ((shape.w_px or 0) * zoom * 0.5)
    else
        target = M.viewport_center_screen(self)
        target.x = target.x - ((shape.w_px or 0) * zoom * 0.5)
        target.y = target.y - ((shape.h_px or 0) * zoom * 0.5)
    end

    local origin = M.canvas_origin(self)
    local base = vmath.vector3(room.base_pos)
    local pan = target - origin - (base * zoom)
    pan.z = 0
    self.pan = pan
end

function M.zoom_step(self, factor, mouse_x, mouse_y)
    local zmin = S.canvas.zoom_min or 0.25
    local zmax = S.canvas.zoom_max or 4.0
    local old_zoom = self.zoom
    local new_zoom = math.max(zmin, math.min(zmax, old_zoom * factor))

    if new_zoom == old_zoom then
        return
    end

    if mouse_x and mouse_y then
        local origin = vmath.vector3(self.canvas.x or 0, self.canvas.y or 0, 0)
        local mouse_pos = vmath.vector3(mouse_x, mouse_y, 0)
        local screen_rel = mouse_pos - origin
        self.pan = screen_rel - (screen_rel - self.pan) * (new_zoom / old_zoom)
    end

    self.zoom = new_zoom
    M.apply(self)
    logf("zoom=%.3f", self.zoom)
end

return M

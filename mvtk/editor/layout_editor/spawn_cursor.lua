-- mvtk/editor/layout_editor/spawn_cursor.lua
--
-- Picks non-overlapping spawn positions for newly placed rooms in the layout
-- editor. Walks a virtual grid (columns x rows) outward from the requested
-- base position, returning the first free slot. Tracks a per-controller
-- cursor so successive spawns fan out instead of stacking.
--
-- All functions take the controller `self` so they can read existing rooms
-- (self.rooms) and the persistent cursor (self.spawn_cursor). Spawn config
-- (column count, padding, step size) lives in
-- developer/config/layout_editor_settings.lua under the `canvas` table.
--
-- Public API:
--   M.rects_overlap(ax, ay, aw, ah, bx, by, bw, bh, pad)
--       -> true if the two AABBs (with optional pad) intersect
--   M.slot_overlaps(self, base, shape, pad)
--       -> true if `base` placed with `shape` collides with any existing room
--   M.next_slot(self, base, shape)
--       -> vector3 of the first non-overlapping slot near `base`; advances
--          self.spawn_cursor.index for the next call
--   M.reset(self, index)
--       -> reinitialize self.spawn_cursor to the given index (default 0)

local Util = require "mvtk.core.util"
local S = Util.require_config("developer.config.layout_editor_settings")

local M = {}

function M.rects_overlap(ax, ay, aw, ah, bx, by, bw, bh, pad)
    pad = tonumber(pad) or 0
    aw = tonumber(aw) or 0
    ah = tonumber(ah) or 0
    bw = tonumber(bw) or 0
    bh = tonumber(bh) or 0
    local ax0 = ax - pad
    local ay0 = ay - pad
    local ax1 = ax + aw + pad
    local ay1 = ay + ah + pad
    local bx0 = bx - pad
    local by0 = by - pad
    local bx1 = bx + bw + pad
    local by1 = by + bh + pad
    if ax1 <= bx0 or bx1 <= ax0 or ay1 <= by0 or by1 <= ay0 then
        return false
    end
    return true
end

function M.slot_overlaps(self, base, shape, pad)
    if not self or not self.rooms or not base then
        return false
    end
    local w = (shape and tonumber(shape.w_px)) or 0
    local h = (shape and tonumber(shape.h_px)) or 0
    for _, R in pairs(self.rooms) do
        local rb = R.base_pos
        local rshape = R.shape
        if rb and rshape then
            local rw = tonumber(rshape.w_px) or 0
            local rh = tonumber(rshape.h_px) or 0
            if M.rects_overlap(base.x, base.y, w, h, rb.x, rb.y, rw, rh, pad) then
                return true
            end
        end
    end
    return false
end

function M.next_slot(self, base, shape)
    if not self then
        return vmath.vector3(base)
    end
    local cfg = S.canvas or {}
    local columns = tonumber(cfg.spawn_columns) or 3
    if columns < 1 then columns = 1 end
    local padding = tonumber(cfg.spawn_padding_px) or 256
    local step_x = tonumber(cfg.spawn_step_x_px)
    local step_y = tonumber(cfg.spawn_step_y_px)
    local shape_w = (shape and tonumber(shape.w_px)) or 1024
    local shape_h = (shape and tonumber(shape.h_px)) or 1024
    if not step_x then step_x = shape_w + padding end
    if not step_y then step_y = shape_h + padding end

    self.spawn_cursor = self.spawn_cursor or { index = 0 }
    local index = tonumber(self.spawn_cursor.index) or 0
    local max_attempts = math.max(columns * 12, 48)
    local attempt = 0
    local base_copy = vmath.vector3(base)
    local last_candidate = base_copy

    while attempt < max_attempts do
        local col = index % columns
        local row = math.floor(index / columns)
        local offset = vmath.vector3(col * step_x, row * step_y, 0)
        local candidate = base_copy + offset
        last_candidate = candidate
        if not M.slot_overlaps(self, candidate, shape, padding * 0.5) then
            self.spawn_cursor.index = index + 1
            return candidate
        end
        index = index + 1
        attempt = attempt + 1
    end

    -- Out of attempts: hand back the last position we considered. The caller
    -- accepts an overlapping placement rather than block the spawn entirely.
    self.spawn_cursor.index = index + 1
    return last_candidate
end

function M.reset(self, index)
    if not self then return end
    local idx = tonumber(index) or 0
    if idx < 0 then idx = 0 end
    self.spawn_cursor = { index = math.floor(idx) }
end

return M

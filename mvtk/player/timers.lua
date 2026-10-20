-- mvtk/player/timers.lua
-- Tiny helper for the per-frame countdown timers scattered across
-- `player_state.lua` (slide/dash/coyote/jump-buffer/etc.).
--
-- Every timer in player_state follows the same pattern:
--   if (self._field or 0) > 0 then
--     self._field = math.max(0, self._field - dt)
--   end
--
-- This module exposes that pattern as `tick(self, field, dt)` plus a
-- `tick_all(self, fields, dt)` convenience for the common case where a
-- block of timers all decrement together. The behaviour is identical to
-- the inline expressions: a `nil` field stays nil, a value <= 0 stays
-- pinned at 0 / its current value, and a positive value decrements with a
-- 0 floor.

local M = {}

--- Decrement a single timer field on `self` by `dt`, clamping to 0.
-- @param self table The state table containing the timer field.
-- @param field string Field name on `self` (e.g. "_slide_cool").
-- @param dt number Frame delta in seconds.
function M.tick(self, field, dt)
    local v = self[field]
    if v and v > 0 then
        local nv = v - dt
        if nv < 0 then nv = 0 end
        self[field] = nv
    end
end

--- Decrement a block of timer fields on `self` by `dt`.
-- Equivalent to calling `M.tick(self, field, dt)` for each entry. Use this
-- when several timers all advance together at the start/end of a frame.
-- @param self table
-- @param fields string[] Array of field names.
-- @param dt number
function M.tick_all(self, fields, dt)
    if not fields then return end
    for i = 1, #fields do
        local field = fields[i]
        local v = self[field]
        if v and v > 0 then
            local nv = v - dt
            if nv < 0 then nv = 0 end
            self[field] = nv
        end
    end
end

--- Returns true when the named timer is currently active (> 0).
-- Treats nil / 0 / negative values as inactive.
function M.is_active(self, field)
    local v = self[field]
    return type(v) == "number" and v > 0
end

return M

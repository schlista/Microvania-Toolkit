-- Contact-grace state for the player's pushable-block grab.
-- Collision callbacks own timer refresh; this module only ages and releases it.

local M = {}

function M.clear(self)
    self._block_grab = nil
    self._block_grab_contact_t = 0
    self._block_grab_motion = nil
end

function M.update(self, dt, can_hold)
    if dt and (self._block_grab_contact_t or 0) > 0 then
        self._block_grab_contact_t = math.max(0, (self._block_grab_contact_t or 0) - dt)
    end

    if self._block_grab
        and (not can_hold or (self._block_grab_contact_t or 0) <= 0) then
        M.clear(self)
        return true
    end
    return false
end

return M


-- mvtk/player/surface_effects.lua
-- Player helpers for conveyors.

local M = {}

function M.conveyor_vector(direction, speed)
  local vx, vy = 0, 0
  local spd = speed or 0
  if direction == "left" then
    vx = -spd
  elseif direction == "right" then
    vx = spd
  elseif direction == "up" then
    vy = spd
  elseif direction == "down" then
    vy = -spd
  end
  return vx, vy
end

function M.sum_conveyor_forces(self)
  local vx, vy = 0, 0
  local contacts = self._conveyor_contacts
  local current_frame = self._frame_counter or 0
  local stale = {}
  if contacts then
    for sender, force in pairs(contacts) do
      local f_frame = force.frame or current_frame
      if (current_frame - f_frame) > 2 then
        stale[#stale + 1] = sender
      else
        vx = vx + (force.vx or 0)
        vy = vy + (force.vy or 0)
      end
    end
    if #stale > 0 then
      for i = 1, #stale do
        contacts[stale[i]] = nil
      end
    end
  end
  self._conveyor_force_x = vx
  self._conveyor_force_y = vy
  return vx, vy
end

return M

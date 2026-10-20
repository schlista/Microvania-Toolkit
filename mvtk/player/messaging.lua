-- mvtk/player/messaging.lua
-- Focused player message handlers used by player.script.

local SurfaceEffects = require "mvtk.player.surface_effects"

local M = {}

function M.handle_environment_message(self, message_id, message, sender, sync_player_position)
  if message_id == hash("apply_movement_modifier") then
    local id = message and (message.id or "movement")
    local mult = tonumber(message and message.multiplier) or 1.0
    self._movement_modifiers = self._movement_modifiers or {}
    self._movement_modifiers[tostring(id)] = mult
    return true
  end

  if message_id == hash("remove_movement_modifier") then
    local id = message and (message.id or "movement")
    if self._movement_modifiers then
      self._movement_modifiers[tostring(id)] = nil
    end
    return true
  end

  if message_id == hash("external_force") then
    if message and message.conveyor then
      self._conveyor_contacts = self._conveyor_contacts or {}
      local now = (self._frame_counter or 0) + 1
      self._conveyor_contacts[sender] = {
        vx = message.vx or 0,
        vy = message.vy or 0,
        frame = now,
      }
      SurfaceEffects.sum_conveyor_forces(self)
    else
      self._ext_fx = (self._ext_fx or 0) + (message and (message.vx or 0) or 0)
      self._ext_fy = (self._ext_fy or 0) + (message and (message.vy or 0) or 0)
    end
    return true
  end

  if message_id == hash("apply_external_force") then
    -- Water currents use px/s vectors. Accept the legacy scalar form too so
    -- authored volumes and hand-written triggers share one handled path.
    local force = message and message.force
    self._ext_fx = (self._ext_fx or 0) + (force and force.x or (message and message.vx) or 0)
    self._ext_fy = (self._ext_fy or 0) + (force and force.y or (message and message.vy) or 0)
    return true
  end

  if message_id == hash("on_conveyor") then
    self._conveyor_contacts = self._conveyor_contacts or {}
    local dir = message and message.direction
    local speed = message and message.speed
    local vx, vy = SurfaceEffects.conveyor_vector(dir, speed)
    local now = (self._frame_counter or 0) + 1
    self._conveyor_contacts[sender] = { vx = vx, vy = vy, frame = now }
    SurfaceEffects.sum_conveyor_forces(self)
    return true
  end

  if message_id == hash("off_conveyor") then
    if self._conveyor_contacts and self._conveyor_contacts[sender] then
      self._conveyor_contacts[sender].frame = (self._frame_counter or 0) - 10
    end
    SurfaceEffects.sum_conveyor_forces(self)
    return true
  end

  if message_id == hash("platform_delta") then
    local dx = message and (message.dx or 0) or 0
    local dy = message and (message.dy or 0) or 0
    self._platform_delta_x = (self._platform_delta_x or 0) + dx
    self._platform_delta_y = (self._platform_delta_y or 0) + dy
    if dx ~= 0 or dy ~= 0 then
      self.pos.x = (self.pos.x or 0) + dx
      self.pos.y = (self.pos.y or 0) + dy
      if sync_player_position then
        sync_player_position(self)
      end
    end
    return true
  end

  return false
end

return M

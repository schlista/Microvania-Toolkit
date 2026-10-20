-- mvtk/player/resources.lua
-- Player health, energy, stamina, and upgrade helper routines.

local M = {}
local HealthState = require "mvtk.player.health_state"

local EnergyState
local Gamefeel

function M.configure(opts)
  opts = opts or {}
  EnergyState = opts.EnergyState or EnergyState
  Gamefeel = opts.Gamefeel or Gamefeel
end

function M.clamp_health(self)
  local max_health = tonumber(self.max_health) or 0
  if max_health <= 0 then
    HealthState.set(self.health, max_health)
    return
  end
  if (self.health or 0) > max_health then
    self.health = max_health
  elseif self.health < 0 then
    self.health = math.max(self.health, 0)
  end
  HealthState.set(self.health, max_health)
end

function M.post_resource_float(amount, dtype)
  if amount and amount ~= 0 and Gamefeel and Gamefeel.damage_number then
    pcall(Gamefeel.damage_number, amount, go.get_position(), { dtype = dtype, target = "player" })
  end
end

return M

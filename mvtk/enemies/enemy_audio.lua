-- mvtk/enemies/enemy_audio.lua
-- Resolves per-enemy-type combat sound ids with toolkit defaults.

local M = {}

M.DEFAULTS = { hurt = "enemy_hurt", death = "enemy_death" }

local function resolve_one(audio_cfg, key)
  if type(audio_cfg) ~= "table" then
    return M.DEFAULTS[key]
  end

  local value = audio_cfg[key]
  if value == false then
    return false
  end
  if type(value) == "string" then
    return value ~= "" and value or M.DEFAULTS[key]
  end
  return M.DEFAULTS[key]
end

--- Resolve optional enemy combat sound ids.
-- Missing keys use defaults, explicit false silences, and non-empty strings are
-- passed through as audio-controller SFX ids.
function M.resolve(audio_cfg)
  return {
    hurt = resolve_one(audio_cfg, "hurt"),
    death = resolve_one(audio_cfg, "death"),
  }
end

--- Return whether a living enemy should emit its hurt vocal for this hit.
function M.should_play_hurt(resolved_audio, damage_amount, health_after)
  local damage = tonumber(damage_amount) or 0
  local health = tonumber(health_after) or 0
  return damage > 0
      and health > 0
      and type(resolved_audio) == "table"
      and resolved_audio.hurt ~= nil
      and resolved_audio.hurt ~= false
end

return M

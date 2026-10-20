-- mvtk/player/combat_input.lua
-- Pure-ish player combat input/config helpers extracted from player.script.

local M = {}

local ACTIONS = {}
local Util = require "mvtk.core.util"

function M.configure(opts)
  opts = opts or {}
  ACTIONS = opts.ACTIONS or ACTIONS
  Util = opts.Util or Util
end

local MOVEMENT_CONTACT_DEFAULTS = {
  air_dash = {
    enabled = true,
    action_tag = "dash",
    damage = 0,
    knockback_px = 80,
    stun_t = 0.08,
    hit_enemy = false,
    hit_breakable = true,
    offset_x = 0,
    offset_y = 0,
    lifetime_pad = 0.04,
    default_lifetime = 0.18,
  },
  slide = {
    enabled = false,
    action_tag = "slide",
    damage = 0,
    knockback_px = 60,
    stun_t = 0.08,
    hit_enemy = false,
    hit_breakable = true,
    offset_x = 0,
    offset_y = 0,
    lifetime_pad = 0.04,
    default_lifetime = 0.20,
  },
  backdash = {
    enabled = false,
    action_tag = "backdash",
    damage = 0,
    knockback_px = 60,
    stun_t = 0.08,
    hit_enemy = false,
    hit_breakable = true,
    offset_x = 0,
    offset_y = 0,
    lifetime_pad = 0.04,
    default_lifetime = 0.20,
  },
  ground_pound = {
    enabled = false,
    action_tag = "ground_pound",
    damage = 0,
    knockback_px = 90,
    stun_t = 0.14,
    hit_enemy = true,
    hit_breakable = true,
    offset_x = 0,
    offset_y = 0,
    anchor = "feet",
    lifetime = 0.45,
    default_lifetime = 0.45,
  },
}

function M.normalize_ability_id(value)
  return Util.normalize_ability_id(value)
end

function M.trim_config_string(value)
  return Util.hash_text(value)
end

function M.string_property_from_cfg(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value ~= nil then
      local s = M.trim_config_string(value)
      if s then
        return s
      end
    end
  end
  return nil
end

function M.resolve_attack_type(...)
  for i = 1, select("#", ...) do
    local cfg = select(i, ...)
    local value = nil
    if type(cfg) == "table" then
      value = cfg.action_tag or cfg.attack_type
    else
      value = cfg
    end
    local tag = M.string_property_from_cfg(value)
    if tag then
      return tag
    end
  end
  return nil
end

function M.bool_or_default(value, default_value)
  if value == nil then
    return default_value and true or false
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    return value ~= 0
  end
  local s = tostring(value):lower()
  if s == "true" or s == "1" or s == "yes" or s == "on" then
    return true
  end
  if s == "false" or s == "0" or s == "no" or s == "off" then
    return false
  end
  return default_value and true or false
end

function M.number_or_default(value, default_value)
  local n = tonumber(value)
  if n == nil then
    return default_value
  end
  return n
end

function M.movement_action_direction(self, action_name)
  if action_name == "air_dash" then
    local dash_dir = tonumber(self._last_dash_dir or 0)
    if dash_dir and dash_dir ~= 0 then
      return dash_dir >= 0 and 1 or -1
    end
  end
  local vx = tonumber(self.vx or 0) or 0
  if math.abs(vx) > 0.1 then
    return vx >= 0 and 1 or -1
  end
  local facing = tonumber(self.facing or 1) or 1
  if action_name == "backdash" then
    facing = -facing
  end
  if facing == 0 then facing = 1 end
  return facing >= 0 and 1 or -1
end

function M.resolve_movement_contact_config(action_name)
  local defaults = MOVEMENT_CONTACT_DEFAULTS[action_name]
  if not defaults then
    return nil
  end
  local action_cfg = ACTIONS[action_name]
  if type(action_cfg) ~= "table" then
    action_cfg = {}
  end
  local contact_cfg = action_cfg.contact_attack
  if type(contact_cfg) ~= "table" then
    contact_cfg = {}
  end

  local enabled = M.bool_or_default(contact_cfg.enabled, defaults.enabled)
  if not enabled then
    return nil
  end

  local cfg = {}
  cfg.action_name = action_name
  cfg.damage = M.number_or_default(contact_cfg.damage, defaults.damage)
  cfg.knockback = M.number_or_default(contact_cfg.knockback_px, defaults.knockback_px)
  cfg.stun_t = M.number_or_default(contact_cfg.stun_t, defaults.stun_t)
  cfg.hit_enemy = M.bool_or_default(contact_cfg.hit_enemy, defaults.hit_enemy)
  cfg.hit_breakable = M.bool_or_default(contact_cfg.hit_breakable, defaults.hit_breakable)
  cfg.offset_x = M.number_or_default(contact_cfg.offset_x, defaults.offset_x)
  cfg.offset_y = M.number_or_default(contact_cfg.offset_y, defaults.offset_y)
  -- "feet" measures offset_y from the player's feet instead of the origin.
  cfg.anchor = (contact_cfg.anchor or defaults.anchor) == "feet" and "feet" or "origin"
  cfg.lifetime = M.number_or_default(contact_cfg.lifetime, defaults.lifetime)
  cfg.lifetime_pad = M.number_or_default(contact_cfg.lifetime_pad, defaults.lifetime_pad or 0)
  cfg.default_lifetime = M.number_or_default(contact_cfg.default_lifetime, defaults.default_lifetime or 0.18)
  cfg.attack_type = M.resolve_attack_type(contact_cfg, action_cfg, defaults)
  return cfg
end

M.MOVEMENT_CONTACT_DEFAULTS = MOVEMENT_CONTACT_DEFAULTS

return M

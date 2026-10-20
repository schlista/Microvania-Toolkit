-- mvtk/player/player_animation.lua
-- ============================================================================
-- Player Animation Utilities
-- ============================================================================
-- Shared animation helper functions extracted from player.script.
-- These are pure functions with no script-state dependency, suitable for
-- reuse across player-related modules.
--
-- Usage in player.script:
--   local PlayerAnim = require "mvtk.player.player_animation"
--   local lower, normalized = PlayerAnim.normalize_anim_key("Run_Left")
--   local resolved = PlayerAnim.resolve_anim_name("idle", overrides_table)
-- ============================================================================

local M = {}

--- Message hashes used by the animation controller on the player GO.
-- Shared constants so modules don't re-hash the same strings.
M.MSG_SET_STATE  = hash("anim.set_state")
M.MSG_PLAY_ONCE  = hash("anim.play_once")
M.MSG_SET_FACING = hash("anim.set_facing")
M.MSG_ANIM_DONE  = hash("anim.done")
M.MSG_ANIM_MISSING = hash("anim.missing")

--- Normalize an animation key for lookups.
-- Lowercases, trims whitespace, and collapses non-alphanumeric runs to underscores.
-- @param state string Animation state name
-- @return string|nil lower Lowercased/trimmed version
-- @return string|nil normalized Fully normalized version
function M.normalize_anim_key(state)
  if type(state) ~= "string" then
    return nil, nil
  end
  local lower = string.lower(state):gsub("^%s+", ""):gsub("%s+$", "")
  local normalized = lower
    :gsub("[^%w]+", "_")
    :gsub("^_+", "")
    :gsub("_+$", "")
    :gsub("_+", "_")
  return lower, normalized
end

--- Resolve a player animation name through override table.
-- Checks Config.player.animation_overrides (or an explicit overrides table)
-- for a remapped animation name, falling back to the original.
-- @param state string Animation state name to resolve
-- @param overrides table|nil Override lookup table (key→replacement)
-- @return string Resolved animation name
function M.resolve_anim_name(state, overrides)
  if type(state) ~= "string" or state == "" then
    return state
  end
  if type(overrides) ~= "table" then
    return state
  end
  local lower, normalized = M.normalize_anim_key(state)
  local override = overrides[state]
    or (lower and overrides[lower])
    or (normalized and overrides[normalized])
  if type(override) == "string" and override ~= "" then
    return override
  end
  return state
end

--- Determine the best attack animation name from an attack definition.
-- Falls back through: attack.animation → attack.input-based default → "punch".
-- Handles table-form animation fields: { spine = "...", sprite = "..." }.
-- @param attack table Attack definition with .animation, .input, .state fields
-- @param is_spine boolean Whether the player uses spine rendering
-- @param grounded boolean Whether the player is on the ground
-- @param vx number Horizontal velocity (for running-shoot detection)
-- @return string Animation state name
-- @return number Blend time
function M.resolve_attack_anim(attack, is_spine, grounded, vx)
  if not attack then return "punch", 0.06 end
  local state = attack.animation
  if type(state) == "table" then
    state = is_spine and state.spine or state.sprite
  end
  if not state or state == "" then
    if attack.input == "ranged" then
      local moving_h = math.abs(vx or 0) > 10
      state = (grounded and moving_h) and "running_shooting" or "shoot"
    elseif attack.input == "heavy" or attack.state == "counter" or attack.state == "down_strike" then
      state = "weapon_attack"
    elseif attack.state == "air" then
      state = "air_spin"
    else
      state = "punch"
    end
  end
  local blend = tonumber(attack.animation_blend)
  if blend == nil then
    blend = (attack.input == "heavy" or attack.input == "ranged" or state == "weapon_attack") and 0.08 or 0.06
  end
  return state, blend
end

return M

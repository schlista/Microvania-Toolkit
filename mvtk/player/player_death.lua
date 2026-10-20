-- mvtk/player/player_death.lua
-- Death transition and dead-body ground snapping extracted from player.script.

local PlayerState = require "mvtk.player.player_state"
local M = {}

local DEATH_SETTLE_VY = -240
local AttackExecutor
local C
local GROUND_GROUPS

local clear_all_movement_contact_hitboxes = function() end
local anim_once_lock = function() end
local sync_player_position = function() end

function M.configure(opts)
  opts = opts or {}
  DEATH_SETTLE_VY = opts.DEATH_SETTLE_VY or DEATH_SETTLE_VY
  AttackExecutor = opts.AttackExecutor or AttackExecutor
  C = opts.C or C
  GROUND_GROUPS = opts.GROUND_GROUPS or GROUND_GROUPS
  clear_all_movement_contact_hitboxes = opts.clear_all_movement_contact_hitboxes or clear_all_movement_contact_hitboxes
  anim_once_lock = opts.anim_once_lock or anim_once_lock
  sync_player_position = opts.sync_player_position or sync_player_position
end

function M.trigger_death(self, reason)
  if self._is_dead then return end
  PlayerState.cancel_ground_pound(self)
  print("========================================")
  print("[PLAYER] ⚠️ PLAYER DEATH TRIGGERED! Reason:", reason or "unknown")
  print("========================================")
  require("mvtk.game.death_drop").capture_death(self)
  self._is_dead = true
  self.health = 0
  require("mvtk.player.resources").clamp_health(self)
  -- Let gravity finish pulling us down so the corpse settles on ground.
  self.vx = 0
  self.vy = math.min(self.vy or 0, DEATH_SETTLE_VY)
  self._control_locked = true
  self._death_settled = false
  self._attack = nil  -- Clear any in-progress attack
  AttackExecutor.cancel(self)
  clear_all_movement_contact_hitboxes(self)
  anim_once_lock(self, "death", 1.0, { blend = 0.12, allow_movement = false })
  pcall(msg.post, msg.url("main:/mode_hud#mode_hud"), hash("hud_health"), {
    hp = 0,
    hp_max = self.max_health
  })
  local death_msg_id = C.MSG and C.MSG.PLAYER_DIED or hash("mvtk_player_died")
  local main_url = msg.url("main:/main_go#script")
  print("[PLAYER] 📤 Sending death message:", death_msg_id, "to:", main_url)
  msg.post(main_url, death_msg_id, {
    reason = reason or "unknown"
  })
  print("[PLAYER] Death message sent successfully")
end

function M.snap_dead_to_ground(self, collision)
  local half_h = self.death_collider_half_height or self.collider_half_height or 60
  local adjust = self.foot_floor_adjust or 0

  -- Prefer the ground hit we already got from BonePhysics.
  local hit_y = collision and collision.ground_hit and collision.ground_hit.y
  if not hit_y then
    -- Cast down from the current position to find the nearest ground.
    local origin = self.pos + vmath.vector3(0, half_h, 0)
    local target = origin - vmath.vector3(0, half_h * 3, 0)
    local hit = physics.raycast(origin, target, GROUND_GROUPS)
    if hit and hit.position then
      hit_y = hit.position.y
    end
  end

  if hit_y then
    local desired_y = hit_y + half_h - adjust
    if math.abs((self.pos.y or 0) - desired_y) > 0.05 then
      self.pos.y = desired_y
      sync_player_position(self)
    end
    self.vy = 0
    self._death_settled = true
  end
end

return M

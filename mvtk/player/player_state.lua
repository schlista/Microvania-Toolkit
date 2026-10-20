-- mvtk/player/player_state.lua
-- Kinematic movement state using input.move_x and player settings.
--
-- Responsibilities:
-- - Maintain player locomotion velocities and timers (ground/air)
-- - Handle jump (ground/coyote/air), slide, air-dash, wall mechanics
-- - Provide small helpers to request actions from the main player script
--
-- Usage:
--   local PSTATE = require 'mvtk.player.player_state'
--   function init(self)
--     PSTATE.init(self)
--   end
--   function update(self, dt)
--     PSTATE.update(self, input, dt)
--   end
local Util = require "mvtk.core.util"
local RuntimeSettings = require "developer.config.runtime_settings"
local PS = RuntimeSettings.get_player_settings()
local ACTIONS = Util.require_config("developer.config.player_actions")
local CONFIG = Util.require_config("developer.config.resolved_config")
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {}, movement = {} })
local SurfaceClassifier = require "mvtk.core.surface_classifier"
local BonePhysics = require "mvtk.player.bone_physics"
-- Cache Audio/FX at module level to avoid pcall(require) on every jump/dash/slide
local Audio = Util.require_module("mvtk.audio.audio")
local FX = Util.require_module("mvtk.fx.fx")
local C = require "mvtk.core.constants"
-- Tiny helper that consolidates the per-frame `if (x or 0) > 0 then x =
-- math.max(0, x - dt) end` pattern used dozens of times in this file.
local Timers = require "mvtk.player.timers"
-- Phase 5 step 31: pure jump-speed math lives in its own file so it can
-- be unit-tested without loading the full player module.
local JumpMath = require "mvtk.player.player_jump_math"
local Grapple = require "mvtk.player.player_grapple"
local SafeGround = require "mvtk.player.safe_ground"
local PoundFeedback = require "mvtk.player.ground_pound_feedback"
local AttackExecutor = require "mvtk.combat.attack_executor"
local M = {}

local pstate_log = Util.make_debug_log("[PSTATE]", function()
  return PS.debug_movement
end)

local function glide_debug_enabled()
  return Debug.global.enable or (Debug.gameplay and Debug.gameplay.glide)
end
local glide_log = Util.make_debug_log("[GLIDE]", glide_debug_enabled)

local POUND_TIMERS = { "_pound_cool", "_pound_recovery_t" }
local WALL_TIMERS = { "_wall_contact_timer", "_wall_coyote_t", "_wall_reattach_lock_t" }

local GRAPPLE_GROUP = hash("grapple")

local GRAPPLE_HASHES = {}
local function resolve_grapple_groups(actions, config, rope_check)
  local out, seen, latch = {}, {}, {}
  local function add(groups, terrain)
    for _, name in ipairs(groups) do
      local group = name
      if type(name) == "string" then
        GRAPPLE_HASHES[name] = GRAPPLE_HASHES[name] or hash(name)
        group = GRAPPLE_HASHES[name]
      end
      if terrain then latch[group] = true end
      if not seen[group] then out[#out + 1], seen[group] = group, true end
    end
  end
  add(config.block_groups or actions.block_groups or { "solid", "world" })
  add({ GRAPPLE_GROUP })
  if not rope_check and (config.targets or actions.targets or "surfaces") == "ceilings" then
    add(config.latch_groups or actions.latch_groups or { "solid", "world" }, true)
  end
  return out, latch
end


local compute_jump_speed = JumpMath.compute_jump_speed

local compute_extended_jump_speed = JumpMath.compute_extended_jump_speed

local function ledge_config(self)
  local wall_climb = self and self._cfg and self._cfg.wall_climb
  local cfg = wall_climb and wall_climb.ledge_climb
  return type(cfg) == "table" and cfg or {}
end

local function animated_ledge_hang_enabled(self, cfg)
  cfg = cfg or ledge_config(self)
  return cfg.enabled == true and cfg.hang_enabled == true and self._ledge_hang_supported == true
end

local function copy_player_position(self)
  if self and self.pos then
    return vmath.vector3(self.pos)
  end
  return vmath.vector3(go.get_position())
end

local function set_player_position(self, position)
  self.pos = vmath.vector3(position)
  go.set_position(self.pos)
end

local function input_is_away_from_wall(side, move_x, threshold)
  if side == 0 then return false end
  threshold = threshold or 0.20
  return (side < 0 and move_x >= threshold)
    or (side > 0 and move_x <= -threshold)
end

--- Clear transient ledge-hang/climb state without changing renderer support.
-- This is public so player reset/respawn paths can clear the kinematic state.
function M.clear_ledge_state(self)
  self._ledge_hanging = false
  self._ledge_climbing = false
  self._ledge_kinematic = false
  self._ledge_hang_side = 0
  self._ledge_climb_side = 0
  self._ledge_climb_t = 0
  self._ledge_climb_duration = 0
  self._ledge_climb_start = nil
  self._ledge_climb_target = nil
  self._ledge_climb_authored_target = nil
  self._ledge_climb_last_safe = nil
  self._ledge_climb_collision = nil
  self._ledge_climb_blocked_reason = nil
  self._ledge_climb_aborted = false
  self._ledge_climb_started = false
  self._ledge_climb_completed = false
end

--- Enter a stationary ledge hang and snap flush to the sampled wall face.
function M.enter_ledge_hang(self, wall_side, center_hit)
  if self._pound_active then return false end
  local side = tonumber(wall_side) or 0
  if side == 0 or self._ledge_climbing then return false end
  side = (side < 0) and -1 or 1

  local p = copy_player_position(self)
  if center_hit and center_hit.position and center_hit.position.x then
    local half_width = self.collider_half_width or 30
    p.x = center_hit.position.x - side * (half_width + 0.25)
  end
  set_player_position(self, p)

  self._ledge_hanging = true
  self._ledge_climbing = false
  self._ledge_kinematic = true
  self._ledge_hang_side = side
  self._ledge_climb_side = 0
  self._ledge_climb_started = false
  self._ledge_climb_completed = false
  self._on_wall = true
  self._wall_side = side
  self._wall_last_side = side
  self._wall_contact_timer = math.max(
    self._wall_contact_timer or 0,
    (self._cfg.wall_climb and self._cfg.wall_climb.contact_grace) or 0.12)
  self.grounded = false
  self.facing = side
  self.vx, self.vy = 0, 0
  return true
end

--- Begin the kinematic hang-to-ledge interpolation.
function M.start_ledge_climb(self)
  if not self._ledge_hanging or self._ledge_climbing then return false end
  local cfg = ledge_config(self)
  local side = self._ledge_hang_side ~= 0 and self._ledge_hang_side or self._wall_side
  if side == 0 then return false end

  local start = copy_player_position(self)
  local duration = math.max(0.001, tonumber(cfg.climb_time) or 0.45)
  -- Animated Edge_Climb moves toward/over the wall top. The opposite sign is
  -- retained only by instant_ledge_climb() for strict legacy compatibility.
  local authored_target = vmath.vector3(
    start.x + ((cfg.climb_x or 32) * side),
    start.y + (cfg.climb_y or 64),
    start.z)
  local support, support_reason = BonePhysics.probe_ledge_support(self, authored_target, start)
  if not support then
    self._ledge_climb_blocked_reason = support_reason or "no_support"
    M.release_ledge_hang(self, { down_input = 0 })
    return false
  end
  local target = support.position

  self._ledge_hanging = false
  self._ledge_climbing = true
  self._ledge_kinematic = true
  self._ledge_climb_started = true
  self._ledge_climb_completed = false
  self._ledge_climb_side = side
  self._ledge_climb_t = 0
  self._ledge_climb_duration = duration
  self._ledge_climb_start = start
  self._ledge_climb_target = target
  self._ledge_climb_authored_target = authored_target
  self._ledge_climb_last_safe = vmath.vector3(start)
  self._ledge_climb_collision = nil
  self._ledge_climb_blocked_reason = nil
  self._ledge_climb_aborted = false
  self._on_wall = false
  self._wall_side = 0
  self._wall_contact_timer = 0
  self._wall_coyote_t = 0
  self._wall_reattach_lock_t = math.max(self._wall_reattach_lock_t or 0, duration + 0.05)
  self.grounded = false
  self.facing = side
  self.vx, self.vy = 0, 0
  return true
end

local function abort_ledge_climb(self, reason)
  self._ledge_climbing = false
  self._ledge_kinematic = false
  self._ledge_climb_started = false
  self._ledge_climb_completed = false
  self._ledge_climb_collision = nil
  self._ledge_climb_blocked_reason = reason or "blocked"
  self._ledge_climb_aborted = true
  self._on_wall = false
  self._wall_side = 0
  self._wall_contact_timer = 0
  self._wall_reattach_lock_t = math.max(self._wall_reattach_lock_t or 0, 0.18)
  self.grounded = false
  self.vx, self.vy = 0, 0
end

local function advance_ledge_climb(self, dt)
  local start = self._ledge_climb_start
  local target = self._ledge_climb_target
  if not (start and target) then
    M.clear_ledge_state(self)
    return
  end

  local duration = math.max(0.001, self._ledge_climb_duration or 0.45)
  self._ledge_climb_t = math.min(duration, (self._ledge_climb_t or 0) + math.max(dt or 0, 0))
  local t = self._ledge_climb_t / duration
  -- Rise clear of the wall first, then translate over its top. A direct
  -- diagonal root lerp would necessarily sweep the collider through the wall.
  local rise_fraction = 0.55
  local desired
  if t <= rise_fraction then
    local rise_t = t / rise_fraction
    desired = vmath.vector3(
      start.x,
      start.y + ((target.y - start.y) * rise_t),
      start.z + ((target.z - start.z) * rise_t))
  else
    local across_t = (t - rise_fraction) / (1 - rise_fraction)
    desired = vmath.vector3(
      start.x + ((target.x - start.x) * across_t),
      target.y,
      start.z + ((target.z - start.z) * t))
  end

  local final_support
  if t >= 1 then
    local authored_target = self._ledge_climb_authored_target or target
    final_support, self._ledge_climb_blocked_reason = BonePhysics.probe_ledge_support(
      self, authored_target, start)
    if not final_support then
      abort_ledge_climb(self, self._ledge_climb_blocked_reason or "no_support")
      return
    end
    desired = final_support.position
  end

  local current = copy_player_position(self)
  local clear, blocked_reason = BonePhysics.sweep_ledge_motion(self, current, desired)
  if not clear then
    abort_ledge_climb(self, blocked_reason)
    return
  end

  set_player_position(self, desired)
  self._ledge_climb_last_safe = vmath.vector3(desired)
  self.vx, self.vy = 0, 0

  if t >= 1 then
    self._ledge_climbing = false
    self._ledge_kinematic = false
    self._ledge_climb_completed = true
    self._ledge_climb_collision = final_support.collision
    self._on_wall = false
    self._wall_side = 0
    self._wall_contact_timer = 0
    -- player.script routes this real support collision through set_grounded().
    self.grounded = false
  end
end

--- Release a hang either downward or as a wall jump away from the ledge.
function M.release_ledge_hang(self, opts)
  opts = opts or {}
  if not self._ledge_hanging then return false end
  local side = self._ledge_hang_side ~= 0 and self._ledge_hang_side or self._wall_side
  local wall_climb = self._cfg.wall_climb or {}
  local wall_jump = wall_climb.wall_jump or {}

  self._ledge_hanging = false
  self._ledge_kinematic = false
  self._ledge_hang_side = 0
  self._ledge_climb_started = false
  self._ledge_climb_completed = false
  self._on_wall = false
  self._wall_side = 0
  self._wall_time = 0
  self._wall_contact_timer = 0
  self._wall_coyote_t = wall_jump.coyote_time or 0
  self._wall_reattach_lock_t = math.max(
    self._wall_reattach_lock_t or 0,
    wall_climb.reattach_lock or wall_jump.reattach_lock or 0.18)

  if opts.jump_away then
    if wall_jump.enabled ~= false then
      self.vx = -side * (wall_jump.push_h or 1400)
      self.vy = wall_jump.push_v or self._jump_speed
      -- The impulse supplies jump speed; it must not unlock ground running.
    else
      self.vx = -side * (wall_climb.detach_push or 220)
      self.vy = 0
    end
  else
    self.vx = 0
    self.vy = (wall_climb.climb_speed or 800) * (opts.down_input or -1)
  end
  return true
end

local function instant_ledge_climb(self, cfg)
  cfg = cfg or ledge_config(self)
  local side = self._wall_side or 0
  if side == 0 then return false end
  local p = copy_player_position(self)
  p.x = p.x + ((cfg.climb_x or 32) * (side < 0 and 1 or -1))
  p.y = p.y + (cfg.climb_y or 64)
  set_player_position(self, p)
  M.clear_ledge_state(self)
  self._on_wall = false
  self._wall_side = 0
  self._wall_time = 0
  self.grounded = false
  self.vy = math.max(self.vy or 0, 0)
  return true
end

--- Revoke animated ledge support after renderer playback reports a missing
-- required animation. If Edge_Climb had already begun, rewind its small
-- kinematic advance and execute the exact legacy away/up teleport instead.
function M.on_ledge_animation_missing(self)
  self._ledge_hang_supported = false

  if self._ledge_climbing then
    local start = self._ledge_climb_start and vmath.vector3(self._ledge_climb_start)
      or copy_player_position(self)
    local side = self._ledge_climb_side ~= 0 and self._ledge_climb_side
      or self._ledge_hang_side
      or self._wall_last_side
      or 0
    set_player_position(self, start)
    M.clear_ledge_state(self)
    if side ~= 0 then
      self._on_wall = true
      self._wall_side = side
      self._wall_last_side = side
      self.grounded = false
      return instant_ledge_climb(self, ledge_config(self))
    end
    return false
  end

  if self._ledge_hanging then
    local side = self._ledge_hang_side ~= 0 and self._ledge_hang_side
      or self._wall_side
      or 0
    M.clear_ledge_state(self)
    self._on_wall = side ~= 0
    self._wall_side = side
    self._wall_last_side = side
    self._wall_contact_timer = (self._cfg.wall_climb and self._cfg.wall_climb.contact_grace) or 0.12
    self.grounded = false
    self.vx, self.vy = 0, 0
  end
  return false
end

function M.init(self, overrides)
  -- Merge per-instance overrides with defaults from settings
  self._cfg = setmetatable(overrides or {}, { __index = PS })
  self.vx, self.vy = 0, 0
  self.facing = 1
  self.grounded = false
  self._jump_speed = compute_jump_speed(self._cfg)
  self._extended_jump_speed = compute_extended_jump_speed(self._cfg)
  self._run_gate = false
  self._slide_t = 0
  self._slide_cool = 0
  self._slide_recovery_t = 0
  -- Jump helpers / timers
  self._coyote_t = 0
  self._jump_buffer_t = 0
  self._jump_hold_t = 0
  self._extra_jumps = self._cfg.air_jumps or 0
  self._double_jump_t = 0  -- Timer to track double jump animation
  -- Air dash state
  self._dash_t = 0
  self._dash_cool = 0
  self._last_dash_dir = 0
  self._air_dashes_left = (self._cfg.air_dash and self._cfg.air_dash.max_air_dashes) or 1
  self._last_mode = nil
  self._autorun_nudge_t = 0
  self._autorun_dir = 0
  -- iFrames state
  self._invulnerable = false
  self._parry_iframes_t = 0
  self._stun_t = 0
  -- Backdash
  self._backdash_t = 0
  self._backdash_cool = 0
  -- Roll
  self._roll_t = 0
  self._roll_cool = 0  -- Ground Pound
  self._pound_active = false
  self._pound_recovery_t = 0
  self._pound_cool = 0
  -- Swim state
  self._in_water = false
  -- Runtime gravity multiplier (for gravity fields, etc.)
  self._gravity_mult = 1.0
  -- Wall climb state
  self._on_wall = false
  self._wall_side = 0  -- -1 = left wall, 1 = right wall, 0 = no wall
  self._wall_time = 0
  self._wall_contact_timer = 0  -- Timer to clear wall contact when no longer touching
  self._wall_coyote_t = 0        -- grace to still wall-jump after detaching
  self._wall_reattach_lock_t = 0 -- prevents instant re-stick after wall jump
  -- Optimistically enable the bundled animations, but preserve an explicit
  -- false supplied by a custom renderer. animation_controller revokes this at
  -- runtime if either required animation fails to play.
  if self._ledge_hang_supported == nil then
    self._ledge_hang_supported = true
  end
  M.clear_ledge_state(self)
  -- Extended jump state
  self._extended_jump_active = false
  self._extended_jump_hold_time = 0
  self._extended_jump_hang_time = 0
  self._extended_jump_bonus_applied = false
  -- Grapple
  Grapple.clear(self)
end

--- Refresh cached ability values from config.
-- Call this after abilities are unlocked to update movement capabilities immediately.
function M.refresh_abilities(self)
  if not self._cfg then return end
  if not (self._cfg.slide_to_run and self._cfg.slide_to_run.enabled) then self._run_gate = false end
  
  -- Update extra jumps (double jump capability)
  local new_air_jumps = self._cfg.air_jumps or 0
  if self.grounded then
    -- If grounded, set directly
    self._extra_jumps = new_air_jumps
  elseif new_air_jumps > (self._extra_jumps or 0) then
    -- If in air and new value is higher, increase available jumps
    self._extra_jumps = new_air_jumps
  end
  
  -- Update air dashes
  local new_max_dashes = (self._cfg.air_dash and self._cfg.air_dash.max_air_dashes) or 1
  if self.grounded then
    self._air_dashes_left = new_max_dashes
  elseif new_max_dashes > (self._air_dashes_left or 0) then
    self._air_dashes_left = new_max_dashes
  end
  
  pstate_log(string.format("[PSTATE] Abilities refreshed: air_jumps=%d air_dashes=%d slide=%s wall_climb=%s",
    self._extra_jumps or 0,
    self._air_dashes_left or 0,
    tostring(self._cfg.slide and self._cfg.slide.enabled),
    tostring(self._cfg.wall_climb and self._cfg.wall_climb.enabled)))
end

function M.set_grounded(self, g)
  local was_grounded = self.grounded and true or false
  self.grounded = g and true or false
  if self.grounded then
    self._grapple_carry_t = 0
    self._grapple_flight = false
    -- A floor contact ends wall movement, including the late-jump grace.
    -- Otherwise the next ground jump can reuse the wall push and reattach.
    self._on_wall, self._wall_sliding = false, false
    self._wall_side, self._wall_last_side, self._wall_time = 0, 0, 0
    self._wall_coyote_t, self._wall_contact_timer = 0, 0
    self._wall_reattach_lock_t = 0
    if not was_grounded then
    -- Landed: clear coyote, restore air resources, clamp landing vy
    self._coyote_t = 0
    self._air_dashes_left = (self._cfg.air_dash and self._cfg.air_dash.max_air_dashes) or 1
    self._extra_jumps = self._cfg.air_jumps or 0
    if self.vy < 0 then self.vy = 0 end
    -- SFX: land
    if Audio and Audio.sfx then Audio.sfx("land") end
    -- Clear extended jump state on landing
    if self._extended_jump_active then
      self._extended_jump_active = false
      self._extended_jump_hold_time = 0
      self._extended_jump_hang_time = 0
      self._extended_jump_bonus_applied = false
    end
    -- Buffered jump: if a jump was buffered, perform it now as a ground jump
    if (self._jump_buffer_t or 0) > 0 then
      self.vy = self._jump_speed
      self.grounded = false
      self._coyote_t = 0
      self._jump_buffer_t = 0
      self._jump_hold_t = self._cfg.jump_min_hold_time or 0
    end
    end
  else
    -- Left ground this frame: start coyote timer
    if was_grounded then
      self._coyote_t = self._cfg.coyote_time or 0
    end
  end
  SafeGround.observe(self)
end

function M.request_jump(self, input_opt)
  local input = input_opt or self._last_input or { move_x = 0, move_y = 0, jump_held = false }
  if self._pound_active then
    -- The committed slam cannot be replaced by an air, wall or ledge jump.
    -- Keep the ordinary buffer so a press just before landing can still win.
    self._jump_buffer_t = math.max(self._jump_buffer_t or 0, self._cfg.jump_buffer or 0)
    return false
  end
  if self._grapple_active and Grapple.release_on_jump(ACTIONS.grapple, self._cfg.grapple) then
    return Grapple.release(self, input, ACTIONS.grapple, self._cfg.grapple, "let_go")
  end
  -- A new jump owns the ascent, so its early-release gravity applies again.
  self._grapple_flight = false
  -- Wall jump (takes priority if on wall or within wall coyote window)
  local WC = self._cfg.wall_climb
  local WJ = (WC and type(WC.wall_jump) == "table") and WC.wall_jump or {}
  -- With wall climb, wall jump is on unless explicitly disabled; without it,
  -- wall jump needs its own unlock (wall slide mode).
  local wall_jump_enabled = WC and ((WC.enabled and WJ.enabled ~= false) or (not WC.enabled and WJ.enabled == true))
  local LC = ledge_config(self)
  local move_x = input.move_x or 0
  local move_y = input.move_y or 0
  local away_threshold = (WC and WC.detach_away_threshold) or 0.20

  -- Jump input arrives through on_input() before the frame update. Consume it
  -- here while hanging so the generic wall-jump path cannot clear the hang
  -- before Edge_Climb is requested.
  if self._ledge_climbing then
    return true
  elseif self._ledge_hanging then
    if move_y < -0.8 then
      return M.release_ledge_hang(self, { down_input = move_y })
    end
    if input_is_away_from_wall(self._ledge_hang_side, move_x, away_threshold) then
      return M.release_ledge_hang(self, { jump_away = true })
    end
    return M.start_ledge_climb(self)
  end

  if WC and WC.enabled and self._on_wall and LC.enabled then
    if animated_ledge_hang_enabled(self, LC) then
      local is_lip, center_hit = BonePhysics.probe_ledge_lip(self, self._wall_side)
      if is_lip and M.enter_ledge_hang(self, self._wall_side, center_hit) then
        if move_y < -0.8 then
          return M.release_ledge_hang(self, { down_input = move_y })
        end
        if input_is_away_from_wall(self._ledge_hang_side, move_x, away_threshold) then
          return M.release_ledge_hang(self, { jump_away = true })
        end
        return M.start_ledge_climb(self)
      end
    elseif move_y >= (LC.up_threshold or 0.6) then
      -- Exact legacy up+jump fallback for disabled/unsupported hang animations.
      return instant_ledge_climb(self, LC)
    end
  end

  if wall_jump_enabled and (self._on_wall or (self._wall_coyote_t or 0) > 0) then
    -- Determine the wall side to jump from (use last-known side during coyote)
    local side = (self._on_wall and self._wall_side ~= 0) and self._wall_side or (self._wall_last_side or 0)
    if side == 0 then side = (self.facing ~= 0 and self.facing or 1) end
    -- Enforce input requirement (toward/away/either) for a proper wall jump
    local mode = WJ.input_mode or "toward"
    local th = WJ.input_threshold or 0.25
    local allow_neutral = (WJ.input_allow_neutral ~= false)
    local mx = input.move_x or 0
    local ok = false
    if allow_neutral and math.abs(mx) < th then ok = true end
    if not ok then
      if mode == "toward" then
        ok = (side < 0 and mx <= -th) or (side > 0 and mx >= th)
      elseif mode == "away" then
        ok = (side < 0 and mx >= th) or (side > 0 and mx <= -th)
      else -- either
        ok = math.abs(mx) >= th
      end
    end
    if not ok then
      if self._cfg.debug_movement then
        pstate_log(string.format("%s WALL JUMP BLOCKED: input not %s (move_x=%.2f, th=%.2f)", self._cfg.debug_tag or "[PSTATE]", tostring(mode), mx, th))
      end
      return false
    end
    local dir = side
    local push_h = WJ.push_h or 1400
    local push_v = WJ.push_v or (self._jump_speed)
    -- Push away from wall: wall_side -1 (left wall) -> push right (+), 1 (right wall) -> push left (-)
    self.vx = -dir * push_h
    self.vy = push_v
    self._wall_coyote_t = 0
    self._wall_contact_timer = 0
    self._wall_reattach_lock_t = WJ.reattach_lock or 0.18
    self._on_wall = false
    self._wall_side = 0
    -- Preserve the existing locomotion mode. A wall impulse is not a run unlock.
    if self._cfg.debug_movement then
      pstate_log(string.format("%s WALL JUMP: push_h=%.0f push_v=%.0f", self._cfg.debug_tag or "[PSTATE]", push_h, push_v))
    end
    return true
  end

  -- Ground / coyote jump
  if self.grounded or ((self._coyote_t or 0) > 0) then
    local base_speed = self._jump_speed
    -- Check for extended jump
    if self._cfg.extended_jump and self._cfg.extended_jump.enabled then
      self._extended_jump_active = true
      self._extended_jump_hold_time = 0
      self._extended_jump_hang_time = 0
      self._extended_jump_bonus_applied = false
      if self._cfg.debug_movement then
        pstate_log(string.format("%s Jump started - extended jump tracking enabled (speed=%.1f)", 
          self._cfg.debug_tag or "[PSTATE]", self._extended_jump_speed or 0))
      end
    else
      if self._cfg.debug_movement then
        pstate_log(string.format("%s Jump started - extended jump NOT enabled (cfg=%s, enabled=%s)", 
          self._cfg.debug_tag or "[PSTATE]", 
          tostring(self._cfg.extended_jump ~= nil), 
          tostring(self._cfg.extended_jump and self._cfg.extended_jump.enabled)))
      end
    end
    self.vy = base_speed
    if Audio and Audio.sfx then Audio.sfx("jump") end
    self.grounded = false
    self._coyote_t = 0
    self._jump_hold_t = self._cfg.jump_min_hold_time or 0
    -- Cancel slide on jump if configured
    if self._slide_t > 0 and self._cfg.slide and self._cfg.slide.cancel_on_jump then
      self._slide_t = 0
      self._control_locked = false
    end
    -- Exit wall climbing when jumping (from ground/coyote)
    M.exit_wall_climb(self)
    return true
  end
  -- Air jump if available
  if (self._extra_jumps or 0) > 0 then
    self.vy = self._jump_speed
    if Audio and Audio.sfx then Audio.sfx("double_jump") end
    self._extra_jumps = self._extra_jumps - 1
    self._double_jump_t = 0.4  -- Set timer for double jump animation
    self._jump_hold_t = self._cfg.jump_min_hold_time or 0
    if self._cfg.debug_movement then
      pstate_log(string.format("%s Double jump used! Remaining: %d", 
        self._cfg.debug_tag or "[PSTATE]", self._extra_jumps))
    end
    -- Exit wall climbing when double jumping
    M.exit_wall_climb(self)
    return true
  end
  -- Could not jump now: buffer it
  self._jump_buffer_t = math.max(self._jump_buffer_t or 0, self._cfg.jump_buffer or 0)
  return false
end

-- These are no-ops unless slide gating is enabled
function M.request_slide_press(self, input)
  -- If airborne, handle air dash first (do not early-return due to slide ground requirements).
  local AD = self._cfg.air_dash
  if AD and AD.enabled and not self.grounded then
    -- A committed slam is not steered by a dash, and a dash ending would unlock it.
    if self._pound_active then return end
    if (self._dash_cool or 0) > 0 then return end
    if (self._air_dashes_left or 0) <= 0 then return end
    -- A successful dash takes ownership of movement. Failed requests leave
    -- the hook intact and never spend an air-dash charge.
    Grapple.clear(self)
    self._dash_t   = AD.duration or 0.18
    self._dash_cool= (AD.cooldown or 0.20) + self._dash_t
    local s = AD.speed or 1400
    -- Determine dash direction. While wall-clinging, invert the stick so
    -- that pushing toward the wall (to cling) dashes away from it.
    local dir = (self.facing ~= 0 and self.facing or 1)
    local stick = (input and (input.move_x or 0)) or 0
    local th = (AD.stick_threshold or 0.2)
    if self._on_wall then
      if math.abs(stick) >= th then
        dir = (stick > 0) and -1 or 1 -- invert stick while on wall
      elseif (self._wall_side or 0) ~= 0 then
        -- No decisive stick input: default to away from the wall
        dir = -self._wall_side
      end
    else
      -- Not on wall: prefer stick if decisive, otherwise use facing
      if math.abs(stick) >= th then
        dir = (stick > 0) and 1 or -1
      end
    end
    self.vx = s * dir
    self._last_dash_dir = dir
    if Audio and Audio.sfx then Audio.sfx("air_dash") end
    -- Optional: trigger a dash trail FX hook
    if FX and FX.on_dash then pcall(FX.on_dash, { dir = dir }) end
    self._air_dashes_left = math.max(0, (self._air_dashes_left or 0) - 1)
    self._control_locked = true
    -- Exit wall climbing when air dashing
    M.exit_wall_climb(self)
    return true
  end

  -- Ground slide (only when grounded)
  if (self._cfg.slide and self._cfg.slide.enabled) and self.grounded then
    -- Roll if crouching (down held) and roll enabled
    local R = self._cfg.roll
    if R and R.enabled and (input and (input.move_y or 0) <= -0.5) and (self._roll_cool or 0) <= 0 then
      self._roll_t = R.duration or 0.30
      self._control_locked = true
      self._run_gate = false
      local dir = (self.facing ~= 0 and self.facing or 1)
      self.vx = (R.speed or 1200) * dir
      -- Notify roll start to swap collider
      pcall(msg.post, msg.url(), C.MSG.ROLL_STATE, { active = true })      return true
    end
    if self._cfg.slide.require_grounded and not self.grounded then return end
    if (self._slide_cool or 0) > 0 then return end
    self._slide_t   = self._cfg.slide.duration or 0.28
    self._slide_cool= (self._cfg.slide.cooldown or 0.15) + self._slide_t
    local s = self._cfg.slide.speed or 520
    local dir = (self.facing ~= 0 and self.facing or 1)
    self.vx = s * dir
    if Audio and Audio.sfx then
      Audio.sfx("slide", { cooldown = (self._cfg.slide and self._cfg.slide.sound_cooldown) or 0.3 })
    end
    if self._cfg.slide.lock_control then self._control_locked = true end
    if self._cfg.debug_movement then
      pstate_log(string.format("%s SLIDE STARTED: duration=%.3f, speed=%.0f, facing=%d", 
        self._cfg.debug_tag or "[PSTATE]", self._slide_t, s, dir))
    end
    return true
  end
end

function M.request_slide_release(self)
  -- handled in update (run gate clear)
end

function M.request_backdash(self)
  local BD = self._cfg.backdash
  if not (BD and BD.enabled) then return end
  if not self.grounded then return end
  if (self._backdash_cool or 0) > 0 then return end
  self._backdash_t = BD.duration or 0.16
  self._backdash_cool = (BD.cooldown or 0.30) + self._backdash_t
  self._control_locked = true
  local dir = (self.facing ~= 0 and self.facing or 1)
  self.vx = -(BD.speed or 1800) * dir
end

-- The slam owns the player until it lands. An attack in progress ends (an air
-- attack holds the fall back), and attack presses are spent rather than queued
-- for the landing. Heavy is part of the slam input, so that press is spent too.
local function drop_attacks_for_slam(self)
  if self._attack or (self._combat and self._combat.current) then AttackExecutor.cancel(self) end
  self._light_buffer_count, self._heavy_buffer_count, self._ranged_buffer_count = 0, 0, 0
  self._light_hold_t = 0
end

function M.request_ground_pound(self, input)
  local GP = self._cfg.ground_pound
  if not (GP and GP.enabled) then return end
  if self.grounded then return end
  if (self._pound_active) then return end
  if (self._pound_cool or 0) > 0 then return end
  if self._in_climb or self._in_water or self._grapple_active
    or self._ledge_hanging or self._ledge_kinematic or self._is_dead
    or (self._stun_t or 0) > 0 then return end
  if (self._dash_t or 0) > 0 or (self._slide_t or 0) > 0 then return end
  -- require down input if configured
  local th = GP.require_down_threshold or 0.6
  if input and (input.move_y or 0) > -th then return end
  self._pound_active = true
  self._control_locked = true
  self.vx = 0
  self.vy = - (GP.slam_speed or 2000)
  drop_attacks_for_slam(self)
end

function M.on_ground_impact(self, pos)
  if self._pound_active then
    local GP = self._cfg.ground_pound or {}
    self._pound_active = false
    self.vx = 0
    self._pound_cool = GP.cooldown or 0
    -- set_grounded runs first and may already have consumed a buffered jump.
    -- That player's jump wins over both the automatic pop and its recovery.
    if self.vy > 0 then
      self._pound_recovery_t = 0
    else
      self.vy = GP.impact_bounce or 0
      self._pound_recovery_t = GP.recovery or 0
    end
    -- Dust, shake, freeze-frame and rumble (player_actions ground_pound.feedback).
    PoundFeedback.landed(pos)
  end
end

-- Interrupt a committed slam when an involuntary body state takes control.
-- That state owns its velocities and lock; cancellation only retires the slam.
function M.cancel_ground_pound(self)
  if not self._pound_active then return end
  self._pound_active = false
  self._pound_recovery_t = 0
  self._pound_cool = (self._cfg.ground_pound and self._cfg.ground_pound.cooldown) or 0
end

function M.set_water(self, v)
  if v then M.cancel_ground_pound(self) end
  self._in_water = v and true or false
end

-- Runtime gravity multiplier control
function M.set_gravity_mult(self, k)
  self._gravity_mult = (k and tonumber(k)) or 1.0
end

function M.clear_gravity_mult(self)
  self._gravity_mult = 1.0
end

function M.grapple_should_cast(self, input)
  input = input or {}
  -- These modes suppress fresh presses in player.script or bypass its normal
  -- movement update. A held retry must not bypass the lock or outlive it.
  if self._pound_active or self._is_dead or self._in_water or self._in_climb
    or self._attack or self._ledge_kinematic or self._ledge_climb_completed then
    self._grapple_recast_t = 0
    return false
  end
  -- Use the aggregated hold, just as rope release does: releasing one binding
  -- must not cancel another binding that still holds Grapple.
  if input.grapple_held == false or (input.grapple_held == nil and input.grapple_up) then
    self._grapple_recast_t = 0
  end
  if self._grapple_active then return false end
  return input.grapple_down == true
    or (input.grapple_held == true and (self._grapple_recast_t or 0) > 0)
end

function M.request_grapple(self, input)
  local G = ACTIONS.grapple or {}
  local CG = self._cfg.grapple or {}
  if self._pound_active or self._is_dead or self._in_water or self._in_climb
    or self._attack or self._ledge_kinematic or self._ledge_climb_completed then
    self._grapple_recast_t = 0
    return false
  end
  if (self._grapple_active) then return end
  local dx, dy = Grapple.direction(input, self.facing or 1, G, CG)
  local p = self.pos or go.get_position()
  local range = CG.range_px or G.range_px or 300
  if range <= 0 or not physics or not physics.raycast then return false end
  local groups, latch = resolve_grapple_groups(G, CG)
  local room_manager = Util.require_module("mvtk.map.streaming.room_manager")
  local current_room = room_manager and room_manager.get_current_room()
  local opts = { targets = CG.targets or G.targets or "surfaces", grapple_group = GRAPPLE_GROUP,
    latch = latch, allow_walls = CG.allow_walls == true,
    tolerance_px = CG.occlusion_tolerance_px or G.occlusion_tolerance_px or 8,
    ceiling_normal_min = CG.ceiling_normal_min or G.ceiling_normal_min or 0.5,
    wall_normal_min = CG.wall_normal_min or G.wall_normal_min or 0.7 }
  local function cast(x, y)
    if y < 0 then return false end
    local to = vmath.vector3(p.x + x * range, p.y + y * range, p.z)
    local ok, hits = pcall(physics.raycast, p, to, groups, { all = true })
    if not ok or not hits then return false end
    if hits.position then hits = { hits } end
    local hit = Grapple.pick_target(hits, range, opts)
    if not hit then return false end
    local anchor_room = room_manager and room_manager.get_room_for_position(
      vmath.vector3(hit.position.x - x * 2, hit.position.y - y * 2, hit.position.z))
    if anchor_room and current_room and anchor_room ~= current_room then return false end
    if not Grapple.attach(self, p, hit, G, CG, self.grounded) then return false end
    self._grapple_room_id = current_room
    return true
  end
  if cast(dx, dy) then return true end
  local assist = self.grounded and (CG.aim_assist_deg or G.aim_assist_deg or 12)
    or (CG.aim_assist_air_deg or G.aim_assist_air_deg or 20)
  local step = CG.aim_assist_step_deg or G.aim_assist_step_deg or 6
  local side = input and input.move_x or 0
  if side == 0 then side = self.facing or 1 end
  -- A positive angular rotation points left from straight up.
  local first_sign = side < 0 and 1 or -1
  if step > 0 then
    for angle = step, assist, step do
      for _, sign in ipairs({ first_sign, -first_sign }) do
        local a = math.rad(angle * sign)
        if cast(dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a)) then
          return true
        end
      end
    end
  end
  -- Only an actual missed press opens the hold window. A retry miss cannot
  -- extend it, and releases never come through this path to start one.
  if input and input.grapple_down and input.grapple_held ~= false
    and not (input.grapple_held == nil and input.grapple_up) then
    self._grapple_recast_t = math.max(0, CG.recast_window_s or G.recast_window_s or 0.3)
  end
  return false
end

function M.draw_grapple_rope(self)
  Grapple.draw_rope(self, ACTIONS.grapple, self._cfg and self._cfg.grapple)
end

function M.cancel_grapple(self)
  Grapple.clear(self)
end

function M.grapple_contacts(self, collision)
  return Grapple.on_contacts(self, collision, ACTIONS.grapple, self._cfg.grapple)
end

local function validate_grapple(self, input)
  if not self._grapple_active or not self._grapple_anchor then return end
  local room_manager = Util.require_module("mvtk.map.streaming.room_manager")
  if self._grapple_room_id and room_manager and room_manager.get_current_room() ~= self._grapple_room_id then
    Grapple.release(self, input, ACTIONS.grapple, self._cfg.grapple, "room")
    return
  end
  local G, CG = ACTIONS.grapple or {}, self._cfg.grapple or {}
  local rope_check = CG.rope_check
  if rope_check == nil then rope_check = G.rope_check end
  if rope_check == false then return end
  local p, anchor = self.pos or go.get_position(), self._grapple_anchor
  local dx, dy = anchor.x - p.x, anchor.y - p.y
  local distance = math.sqrt(dx * dx + dy * dy)
  if distance <= 0 then return end
  local tol = CG.occlusion_tolerance_px or G.occlusion_tolerance_px or 8
  local to = vmath.vector3(anchor.x + dx / distance * tol, anchor.y + dy / distance * tol, anchor.z)
  local hit
  if physics and physics.raycast then
    -- Parentheses keep the second return (latch set) out of raycast's options.
    local ok, result = pcall(physics.raycast, p, to, (resolve_grapple_groups(G, CG, true)))
    if ok then hit = result end
  end
  if Grapple.rope_state(hit, distance + tol, distance, tol) == "lost" then
    Grapple.release(self, input, G, CG, "lost")
  end
end

function M.is_invulnerable(self)
  return self._invulnerable
end

function M.is_damage_invulnerable(self)
  return (self._damage_iframes_t or 0) > 0
end

function M.exit_wall_climb(self)
  if self._on_wall or self._ledge_hanging or self._ledge_climbing then
    if self._cfg.debug_movement then
      pstate_log(string.format("%s WALL CLIMB EXIT: manual", self._cfg.debug_tag or "[PSTATE]"))
    end
    M.clear_ledge_state(self)
    self._on_wall = false
    self._wall_side = 0
    self._wall_time = 0
  end
end

function M.set_wall_contact(self, wall_side)
  -- A slam ignores wall attachment, including its momentum-stopping step.
  if self._pound_active then return end
  -- Ladder frames skip the normal wall-detach update. Clear incompatible wall
  -- state here so a nearby lip cannot attach wall-cling or reverse facing.
  if self._in_climb and not self._in_water then
    self._on_wall = false
    self._wall_side = 0
    self._wall_last_side = 0
    self._wall_time = 0
    self._wall_contact_timer = 0
    self._wall_coyote_t = 0
    self._wall_sliding = false
    M.clear_ledge_state(self)
    return
  end
  if wall_side ~= 0 then self._grapple_carry_t = 0 end
  local WC = self._cfg.wall_climb
  -- Wall contact matters for wall climb OR wall jump (wall slide).
  local jump_only = WC and not WC.enabled and type(WC.wall_jump) == "table" and WC.wall_jump.enabled == true
  if not (WC and (WC.enabled or jump_only)) then
    return
  end
  -- The edge-climb path owns position kinematically; wall probes along the
  -- interpolation must not reattach the normal wall-climb state.
  if self._ledge_climbing then
    return
  end

  if self._ledge_hanging then
    if wall_side ~= 0 and not self.grounded then
      self._wall_contact_timer = (self._cfg.wall_climb.contact_grace or 0.12)
      self._wall_side = wall_side
      self._wall_last_side = wall_side
    elseif self.grounded then
      M.clear_ledge_state(self)
      self._on_wall = false
      self._wall_side = 0
      self._wall_time = 0
    end
    return
  end
  
  -- wall_side: -1 = left wall, 1 = right wall, 0 = no wall
  if wall_side ~= 0 and not self.grounded then
    -- Refresh contact grace window
    self._wall_contact_timer = (self._cfg.wall_climb.contact_grace or 0)
    self._wall_last_side = wall_side
    -- Start wall climbing immediately when touching wall in air (unless locked)
    if not self._on_wall and (self._wall_reattach_lock_t or 0) <= 0 then
      if self._cfg.debug_movement then
        pstate_log(string.format("%s WALL CLIMB START: side=%d", self._cfg.debug_tag or "[PSTATE]", wall_side))
      end
      self._on_wall = true
      self._wall_side = wall_side
      self._wall_time = 0
      if not jump_only then
        -- Wall climb: stop all momentum when sticking to wall
        self.vx = 0
        self.vy = 0
      end
    end
    -- Keep updating wall side (in case player moves between walls)
    self._wall_side = wall_side
    self._wall_last_side = wall_side
  else
    -- Clear wall contact only if grounded (detaching in update handles other cases)
    if self.grounded and self._on_wall then
      if self._cfg.debug_movement then
        pstate_log(string.format("%s WALL CLIMB END: grounded", self._cfg.debug_tag or "[PSTATE]"))
      end
      self._on_wall = false
      self._wall_side = 0
      self._wall_time = 0
    end
  end
end


local function shape_walk_speed_by_mode(self, raw)
  local mode = self._cfg.walk_speed_mode or "scaled"
  local is_fixed = (mode == "fixed") or (mode == hash("fixed"))
  if is_fixed then return (raw ~= 0) and Util.sign(raw) or 0 end
  return raw
end

local function update_ledge_hang(self, input)
  local wall_climb = self._cfg.wall_climb or {}
  local cfg = ledge_config(self)
  local move_x = input.move_x or 0
  local move_y = input.move_y or 0
  local away = input_is_away_from_wall(
    self._ledge_hang_side,
    move_x,
    wall_climb.detach_away_threshold or 0.20)

  if (self._wall_contact_timer or 0) <= 0 then
    M.release_ledge_hang(self, { down_input = 0 })
  elseif move_y < -0.8 then
    M.release_ledge_hang(self, { down_input = move_y })
  elseif input.jump_down and away then
    M.release_ledge_hang(self, { jump_away = true })
  elseif move_y >= (cfg.up_threshold or 0.6) or input.jump_down then
    M.start_ledge_climb(self)
  else
    -- A hang is fully kinematic: ignore gravity and ordinary wall-slide speed.
    self.vx, self.vy = 0, 0
    self.facing = self._ledge_hang_side
  end
end

function M.update(self, dt, input)
  if self.grounded or self._on_wall then self._grapple_carry_t = 0 end
  if input and (input.grapple_held == false or (input.grapple_held == nil and input.grapple_up)) then
    self._grapple_recast_t = 0
  else
    self._grapple_recast_t = math.max(0, (self._grapple_recast_t or 0) - dt)
  end
  -- Keep a snapshot of the current input for edge-triggered actions
  self._last_input = input
  -- Update invulnerability based on slide/dash state and temporary iFrames
  local slide_iframes = (self._cfg.slide and self._cfg.slide.iframes) and (self._slide_t or 0) > 0
  local dash_iframes = (self._cfg.air_dash and self._cfg.air_dash.iframes) and (self._dash_t or 0) > 0
  local backdash_iframes = (self._cfg.backdash and self._cfg.backdash.iframes) and (self._backdash_t or 0) > 0
  if (self._parry_iframes_t or 0) > 0 then self._parry_iframes_t = math.max(0, self._parry_iframes_t - dt) end
  if (self._damage_iframes_t or 0) > 0 then self._damage_iframes_t = math.max(0, self._damage_iframes_t - dt) end
  local was_invulnerable = self._invulnerable
  self._invulnerable = slide_iframes or dash_iframes or backdash_iframes
    or ((self._parry_iframes_t or 0) > 0)
    or ((self._damage_iframes_t or 0) > 0)
  
  if self._cfg.debug_movement and self._invulnerable ~= was_invulnerable then
    if self._invulnerable then
      local reason = slide_iframes and "slide" or "air dash"
      pstate_log(string.format("%s iFrames ENABLED (%s)", self._cfg.debug_tag or "[PSTATE]", reason))
    else
      pstate_log(string.format("%s iFrames DISABLED", self._cfg.debug_tag or "[PSTATE]"))
    end
  end
  
  -- timers
  Timers.tick_all(self, POUND_TIMERS, dt)
  -- Runs after this frame's presses are queued and before they are used.
  if self._pound_active then drop_attacks_for_slam(self) end
  if (self._stun_t or 0) > 0 then
    self._stun_t = math.max(0, self._stun_t - dt)
    self._control_locked = true
  elseif self._control_locked
    and not self._grapple_active
    and not self._pound_active
    and (self._pound_recovery_t or 0) <= 0
    and (self._slide_t or 0) <= 0
    and (self._slide_recovery_t or 0) <= 0
    and (self._dash_t or 0) <= 0
    and (self._backdash_t or 0) <= 0
    and (self._roll_t or 0) <= 0 then
    -- release generic lock when not sliding/dashing
    self._control_locked = false
  end
  if (self._slide_cool or 0) > 0 then self._slide_cool = math.max(0, self._slide_cool - dt) end
  if (self._dash_cool or 0) > 0 then self._dash_cool = math.max(0, self._dash_cool - dt) end
  if (self._coyote_t or 0) > 0 then self._coyote_t = math.max(0, self._coyote_t - dt) end
  if (self._jump_buffer_t or 0) > 0 then self._jump_buffer_t = math.max(0, self._jump_buffer_t - dt) end
  if (self._jump_hold_t or 0) > 0 then self._jump_hold_t = math.max(0, self._jump_hold_t - dt) end
  
  -- Extended jump logic
  if self._extended_jump_active then
    if input.jump_held then
      self._extended_jump_hold_time = (self._extended_jump_hold_time or 0) + dt
    else
      -- Jump button released, deactivate extended jump immediately
      local was_hanging = self._extended_jump_hang_time > 0
      self._extended_jump_active = false
      self._extended_jump_hang_time = 0  -- Stop hang time immediately
      if self._cfg.debug_movement then
        local msg = was_hanging and "Extended jump deactivated (button released) - hang time STOPPED" or "Extended jump deactivated (button released)"
        pstate_log(string.format("%s %s", self._cfg.debug_tag or "[PSTATE]", msg))
      end
    end
  end
  -- Wall timers
  Timers.tick_all(self, WALL_TIMERS, dt)
  if self._on_wall then 
    self._wall_time = (self._wall_time or 0) + dt 
  end
  if (self._slide_t or 0) > 0 then
    if self._cfg.debug_movement then
      pstate_log(string.format("%s SLIDE UPDATE: _slide_t=%.4f, dt=%.4f, new_slide_t=%.4f",
        self._cfg.debug_tag or "[PSTATE]", self._slide_t, dt, self._slide_t - dt))
    end
    self._slide_t = math.max(0, self._slide_t - dt)
    if self._slide_t == 0 then
      -- enter brief recovery/vulnerability window
      self._slide_recovery_t = (self._cfg.slide and self._cfg.slide.recovery) or 0
      self._control_locked = (self._slide_recovery_t or 0) > 0
      -- stop movement during recovery
      if self._control_locked then self.vx = 0 end
      if self._cfg.debug_movement then
        pstate_log(string.format("%s SLIDE ENDED: recovery_t=%.3f (cfg.recovery=%s), slide_held=%s",
          self._cfg.debug_tag or "[PSTATE]", self._slide_recovery_t, 
          tostring(self._cfg.slide and self._cfg.slide.recovery), 
          tostring(input and input.slide_held)))
      end
      
      -- If there's no recovery time, immediately check for run gate transition
      if self._slide_recovery_t == 0 then
        if self._cfg.slide_to_run and self._cfg.slide_to_run.enabled and self._cfg.slide_to_run.run_after_slide_when_held and input.slide_held then
          if self._cfg.debug_movement then
            pstate_log(string.format("%s No recovery time - enabling run gate immediately", self._cfg.debug_tag or "[PSTATE]"))
          end
          self._run_gate = true
          -- autorun nudge
          local SL = self._cfg.slide or {}
          self._autorun_nudge_t = SL.autorun_pulse or 0
          local d = (self.facing ~= 0 and self.facing or (self.vx ~= 0 and (self.vx>0 and 1 or -1) or 1))
          self._autorun_dir = d
        else
          -- Ensure run gate is cleared if trigger is not held
          if self._cfg.debug_movement then
            pstate_log(string.format("%s No recovery time - clearing run gate (RT not held)", self._cfg.debug_tag or "[PSTATE]"))
          end
          self._run_gate = false
        end
      end
    end
  end
  if (self._slide_recovery_t or 0) > 0 then
    self._slide_recovery_t = math.max(0, self._slide_recovery_t - dt)
    if self._slide_recovery_t == 0 then
      self._control_locked = false
      -- after recovery, optionally gate into run if still held
      if self._cfg.slide_to_run and self._cfg.slide_to_run.enabled and self._cfg.slide_to_run.run_after_slide_when_held and input.slide_held then
        if self._cfg.debug_movement then
          pstate_log(string.format("%s Slide recovery complete, slide still held - enabling run gate", self._cfg.debug_tag or "[PSTATE]"))
        end
        self._run_gate = true
        -- autorun nudge
        local SL = self._cfg.slide or {}
        self._autorun_nudge_t = SL.autorun_pulse or 0
        local d = (self.facing ~= 0 and self.facing or (self.vx ~= 0 and (self.vx>0 and 1 or -1) or 1))
        self._autorun_dir = d
      else
        -- Ensure run gate is cleared if trigger is not held after recovery
        if self._cfg.debug_movement then
          pstate_log(string.format("%s Slide recovery complete, RT not held - clearing run gate", self._cfg.debug_tag or "[PSTATE]"))
        end
        self._run_gate = false
      end
    end
  end
  if (self._roll_t or 0) > 0 then
    self._roll_t = math.max(0, self._roll_t - dt)
    if self._roll_t == 0 then
      local roll_cfg = self._cfg.roll or {}
      if roll_cfg.end_speed_mult ~= nil then
        self.vx = (self.vx or 0) * roll_cfg.end_speed_mult
      elseif roll_cfg.stop_on_end ~= false then
        self.vx = 0
      end
      if (roll_cfg.cooldown or 0) > 0 then
        self._roll_cool = math.max(self._roll_cool or 0, roll_cfg.cooldown)
      end
      if not ((self._slide_t or 0) > 0 or (self._dash_t or 0) > 0 or (self._backdash_t or 0) > 0 or (self._stun_t or 0) > 0) then
        self._control_locked = false
      end
      pcall(msg.post, msg.url(), C.MSG.ROLL_STATE, { active = false })
    end
  end
  if (self._roll_cool or 0) > 0 then
    self._roll_cool = math.max(0, self._roll_cool - dt)
  end
  if (self._dash_t or 0) > 0 then
    self._dash_t = math.max(0, self._dash_t - dt)
    if self._dash_t == 0 then
      self._control_locked = false
      self._last_dash_dir = 0
      if Audio and Audio.stop_sfx then
        Audio.stop_sfx("air_dash")
      end
    end
  end
  -- Decrement double jump animation timer
  if (self._double_jump_t or 0) > 0 then
    self._double_jump_t = math.max(0, self._double_jump_t - dt)
  end
  if (self._backdash_t or 0) > 0 then
    self._backdash_t = math.max(0, self._backdash_t - dt)
    if self._backdash_t == 0 then
      self._control_locked = false
    end
  end

  if self._cfg.slide_to_run and self._cfg.slide_to_run.enabled and self._cfg.slide_to_run.clear_run_on_release and not input.slide_held then
    if self._cfg.debug_movement and self._run_gate then
      pstate_log(string.format("%s CLEARING RUN GATE: slide released (slide_held=%s)",
        self._cfg.debug_tag or "[PSTATE]", tostring(input.slide_held)))
    end
    self._run_gate = false
  end
  local neutral = self._cfg.walk_stop_deadzone or 0.2
  if math.abs(input.move_x or 0) <= neutral and math.abs(self.vx) < (self._cfg.stop_epsilon or 3.0) and not input.slide_held then
    if self._cfg.debug_movement and self._run_gate then
      pstate_log(string.format("%s CLEARING RUN GATE: Neutral stick + slide not held (move_x=%.3f, vx=%.1f, slide_held=%s)",
        self._cfg.debug_tag or "[PSTATE]", input.move_x or 0, self.vx, tostring(input.slide_held)))
    end
    self._run_gate = false
  end

  -- Grapple owns velocity through the ordinary collision integrator. Running
  -- normal air steering/gravity afterward used to overwrite every pull.
  validate_grapple(self, input)
  if Grapple.update(self, dt, input, ACTIONS.grapple, self._cfg.grapple) then return end

  -- Kinematic ledge movement takes priority over wall movement, gravity and
  -- horizontal input. player.script consumes the public transition flags for
  -- Edge_Idle/Edge_Climb animation selection.
  if self._ledge_climbing then
    advance_ledge_climb(self, dt)
    return
  elseif self._ledge_hanging then
    update_ledge_hang(self, input)
    return
  end

  -- Wall climbing movement - COMPLETELY OVERRIDE GRAVITY AND MOVEMENT
  if not self._pound_active and self._on_wall and self._cfg.wall_climb and self._cfg.wall_climb.enabled then
    local climb_input = input.move_y or 0
    local move_x = input.move_x or 0
    local stick_speed = self._cfg.wall_climb.stick_speed or 0
    local climb_speed = self._cfg.wall_climb.climb_speed or 800
    local toward_required = self._cfg.wall_climb.require_input_toward
    local toward_thresh = self._cfg.wall_climb.input_threshold or 0.25
    local away_thresh = self._cfg.wall_climb.detach_away_threshold or 0.20
    local LC = ledge_config(self)

    -- The normal wall solver already snapped us flush. Probe its centre and
    -- +0.5 samples to recognize the first frame where the wall ends at a lip.
    if animated_ledge_hang_enabled(self, LC) then
      local is_lip, center_hit = BonePhysics.probe_ledge_lip(self, self._wall_side)
      if is_lip and M.enter_ledge_hang(self, self._wall_side, center_hit) then
        update_ledge_hang(self, input)
        return
      end
    end

    -- Detach if we lost contact grace
    if (self._wall_contact_timer or 0) <= 0 then
      if self._cfg.debug_movement then
        pstate_log(string.format("%s WALL CLIMB END: contact grace expired", self._cfg.debug_tag or "[PSTATE]"))
      end
      self._on_wall = false
      self._wall_side = 0
      self._wall_time = 0
      -- start wall coyote to allow late wall jump
      local WJ = self._cfg.wall_climb.wall_jump or {}
      self._wall_coyote_t = WJ.coyote_time or 0
      -- continue with normal movement
    else
      -- Require holding toward the wall to remain attached
      if toward_required then
        local holding_toward = (self._wall_side < 0 and move_x <= -toward_thresh) or (self._wall_side > 0 and move_x >= toward_thresh)
        if not holding_toward then
          -- Not holding toward; start coyote and drop
          if self._cfg.debug_movement then
            pstate_log(string.format("%s WALL CLIMB END: not holding toward (move_x=%.2f)", self._cfg.debug_tag or "[PSTATE]", move_x))
          end
          self._on_wall = false
          self._wall_side = 0
          local WJ = self._cfg.wall_climb.wall_jump or {}
          self._wall_coyote_t = WJ.coyote_time or 0
          -- fall through to normal movement
        end
      end
    end

    if self._on_wall then
      local side = self._wall_side or 0
      local holding_away = side ~= 0 and (
        (side < 0 and move_x >= away_thresh)
        or (side > 0 and move_x <= -away_thresh)
      )
      if holding_away then
        local WJ = self._cfg.wall_climb.wall_jump or {}
        if self._cfg.debug_movement then
          pstate_log(string.format("%s WALL CLIMB END: pushed away (side=%d, move_x=%.2f)",
            self._cfg.debug_tag or "[PSTATE]", side, move_x))
        end
        self._on_wall = false
        self._wall_side = 0
        self._wall_time = 0
        self.vx = -side * (self._cfg.wall_climb.detach_push or 220)
        self._wall_coyote_t = WJ.coyote_time or 0
        self._wall_reattach_lock_t = self._cfg.wall_climb.reattach_lock or (WJ.reattach_lock or 0.18)
      end
    end
    
    if self._on_wall then
      -- Legacy up+jump teleport remains the compatibility path whenever hang
      -- animations are disabled or unavailable for the active renderer.
      if LC.enabled
        and not animated_ledge_hang_enabled(self, LC)
        and input and input.jump_down
        and climb_input >= (LC.up_threshold or 0.6)
      then
        instant_ledge_climb(self, LC)
        return
      end

      -- STICK TO THE WALL - no horizontal movement at all
      self.vx = 0
    
      -- Direct control of vertical movement with left stick
      if math.abs(climb_input) > 0.1 then
        -- Direct control - up/down based on stick input
        self.vy = climb_speed * climb_input
        if self._cfg.debug_movement then
          pstate_log(string.format("%s Wall climb: input=%.2f, vy=%.1f", 
            self._cfg.debug_tag or "[PSTATE]", climb_input, self.vy))
        end
        
        -- If climbing down fast, allow falling off the wall
        if climb_input < -0.8 then
          local WJ = self._cfg.wall_climb.wall_jump or {}
          self._on_wall = false
          self._wall_side = 0
          self._wall_coyote_t = WJ.coyote_time or 0
          return  -- Let gravity take over
        end
      else
        -- Neutral stick - stick to wall (no movement)
        if stick_speed > 0 then
          -- Slow slide down if configured
          self.vy = -stick_speed
        else
          -- Perfect stick - no movement at all
          self.vy = 0
        end
      end
      
      -- Skip all gravity and normal movement when wall climbing
      return
    end
  end

  -- Wall slide: wall jump unlocked without wall climb. Hold toward the wall to
  -- slide down it (fall speed capped after gravity below); release, land or
  -- lose contact to detach, with a short coyote window for a late wall jump.
  self._wall_sliding = false
  if not self._pound_active and self._on_wall and self._cfg.wall_climb and not self._cfg.wall_climb.enabled then
    local WC = self._cfg.wall_climb
    local WJ = WC.wall_jump or {}
    local move_x = input.move_x or 0
    local side = self._wall_side or 0
    local thresh = WC.input_threshold or 0.25
    local holding_toward = (side < 0 and move_x <= -thresh) or (side > 0 and move_x >= thresh)
    if self.grounded or (self._wall_contact_timer or 0) <= 0 or not holding_toward then
      self._on_wall = false
      self._wall_side = 0
      self._wall_time = 0
      self._wall_coyote_t = WJ.slide_coyote_time or 0
    else
      self._wall_sliding = true
      self.vx = 0
    end
  end

  -- Horizontal
  -- If sliding/backdashing/air-dashing/rolling with control lock, keep imposed vx
  if self._control_locked and ((self._slide_t or 0) > 0 or (self._dash_t or 0) > 0 or (self._slide_recovery_t or 0) > 0 or (self._backdash_t or 0) > 0 or (self._roll_t or 0) > 0 or self._pound_active or (self._pound_recovery_t or 0) > 0) then
    if self.vx ~= 0 then self.facing = Util.sign(self.vx) end
  elseif (self._stun_t or 0) > 0 then
    -- During hit-stun: decelerate to zero, ignore input.
    -- This prevents the player from moving freely during stun.
    local stun_decel = math.max(0, tonumber(self._hurt_decel) or tonumber(self._cfg.hurt_decel) or self._cfg.decel or 0)
    local t = 1 - math.exp(-stun_decel * dt)
    self.vx = Util.lerp(self.vx, 0, t)
    if math.abs(self.vx) <= (self._cfg.stop_epsilon or 3.0) then self.vx = 0 end
  elseif not self._on_wall then  -- Don't apply horizontal movement while on wall
    local raw = input.move_x or 0
    -- Apply autorun nudge if active and stick is neutral-ish
    if (self._autorun_nudge_t or 0) > 0 then
      self._autorun_nudge_t = math.max(0, self._autorun_nudge_t - dt)
      if math.abs(raw) < 0.25 then
        local strength = ((self._cfg.slide and self._cfg.slide.autorun_strength) or 0)
        raw = math.max(-1, math.min(1, raw + (self._autorun_dir * strength)))
      end
    end
    if raw ~= 0 then self.facing = Util.sign(raw) end
    local base = (self._run_gate and (self._cfg.run_speed or 2000) or (self._cfg.walk_speed or 1200))
    local shaped = shape_walk_speed_by_mode(self, raw)
    local target_vx = base * shaped
    
    if self._cfg.debug_movement and (self._run_gate or raw ~= 0) then
      pstate_log(string.format("%s MOVEMENT: run_gate=%s, base_speed=%.0f, raw=%.3f, shaped=%.3f, target_vx=%.1f", 
        self._cfg.debug_tag or "[PSTATE]", tostring(self._run_gate), base, raw, shaped, target_vx))
    end

  -- Choose accel/decel with air control multipliers and turn braking
  local on_ground = self.grounded
  local accel = (self._cfg.accel or 18)
  local decel = (self._cfg.decel or 26)
  if not on_ground then
    accel = accel * (self._cfg.air_accel_mult or 1.0)
    decel = decel * (self._cfg.air_decel_mult or 1.0)
  end
  local reversing = (target_vx ~= 0 and self.vx ~= 0 and Util.sign(target_vx) ~= Util.sign(self.vx))
  local turn_brake = (self._cfg.turn_brake_mult or 1.0)
  local slippery_reverse = on_ground and reversing and turn_brake < 0.9999
  if reversing and not slippery_reverse then decel = decel * turn_brake end

  local stop_epsilon = (self._cfg.stop_epsilon or 3.0)
  local move_target_vx = target_vx
  local coasting_reverse = false
  if slippery_reverse then
    -- Let slippery surfaces keep the current slide alive until momentum has
    -- bled down far enough for the new input direction to take over smoothly.
    local walk_speed = (self._cfg.walk_speed or 1200)
    local reverse_takeover_speed = math.max(
      stop_epsilon * 8,
      walk_speed * (0.08 + (0.20 * turn_brake))
    )
    if math.abs(self.vx) > reverse_takeover_speed then
      move_target_vx = 0
      coasting_reverse = true
    end
  end
  local accelerating = (math.abs(move_target_vx) > math.abs(self.vx))
  if coasting_reverse then accelerating = false end
  local rate = accelerating and accel or decel
  local carry_rate
  move_target_vx, carry_rate = Grapple.carry_steering(self, move_target_vx, accelerating,
    decel, ACTIONS.grapple, self._cfg.grapple)
  if carry_rate ~= nil then
    rate = carry_rate
    accelerating = false
  end
  local t = Util.clamp(rate * dt, 0, 1)
  -- Simple easing shaping for approach: >1 biases toward ease-out
  if accelerating then
    local e = (self._cfg.accel_ease_exp or 1.0)
    if e ~= 1.0 then t = 1 - math.pow(1 - t, e) end
  else
    local e = (self._cfg.decel_ease_exp or 1.0)
    if e ~= 1.0 then t = 1 - math.pow(1 - t, e) end
  end
  self.vx = Util.lerp(self.vx, move_target_vx, t)
  if shaped == 0 and math.abs(self.vx) <= stop_epsilon and (self._grapple_carry_t or 0) <= 0 then self.vx = 0 end
  self._grapple_carry_t = math.max(0, (self._grapple_carry_t or 0) - dt)
  end

  -- Vertical
  local base_g = self._cfg.gravity or -1200
  local g = base_g * (self._gravity_mult or 1.0)
  -- Water gravity is configured by game_config.player.swim.
  if self._in_water and (self._cfg.swim and self._cfg.swim.enabled) then
    g = g * (self._cfg.swim.gravity_mult or 1.0)
  end
  local release_g = Grapple.release_gravity(self, g, ACTIONS.grapple, self._cfg.grapple)
  
  -- Extended jump processing
  local extended_jump_hang_active = false
  
  if not release_g and self._extended_jump_active and self._cfg.extended_jump and self._cfg.extended_jump.enabled then
    local hang_time = self._cfg.extended_jump.hang_time or 0.15
    -- Use a reasonable threshold for extended jump detection (when velocity is near zero at apex)
    local extended_jump_threshold = 100  -- Detect when we're near the peak
    
    -- Debug output at apex to see what's happening
    if self._cfg.debug_movement and math.abs(self.vy) <= extended_jump_threshold then
      pstate_log(string.format("%s At apex: vy=%.1f, jump_held=%s, bonus_applied=%s, extended_active=%s", 
        self._cfg.debug_tag or "[PSTATE]", self.vy, tostring(input.jump_held), 
        tostring(self._extended_jump_bonus_applied), tostring(self._extended_jump_active)))
    end
    
    -- Check if we're at the peak and button is still held
    if math.abs(self.vy) <= extended_jump_threshold then
      if input.jump_held and not self._extended_jump_bonus_applied then
        -- At peak with button held - apply extended jump bonus
        self.vy = self.vy + self._extended_jump_speed
        self._extended_jump_bonus_applied = true
        if self._cfg.debug_movement then
          pstate_log(string.format("%s Extended jump activated at peak! +%.1f (total vy=%.1f)", 
            self._cfg.debug_tag or "[PSTATE]", self._extended_jump_speed, self.vy))
        end
      end
      
      -- Handle hang time at apex (ONLY if button is still held)
      if input.jump_held then
        if self._extended_jump_hang_time < hang_time then
          self._extended_jump_hang_time = self._extended_jump_hang_time + dt
          g = g * 0.1  -- Very light gravity during hang time
          extended_jump_hang_active = true
          if self._cfg.debug_movement and self._extended_jump_hang_time < dt then
            pstate_log(string.format("%s Extended jump hang time started", self._cfg.debug_tag or "[PSTATE]"))
          end
        end
      end
    end
  end
  
  -- Grapple release flight lasts only until the apex of the released arc.
  if self._grapple_flight and self.vy <= 0 then self._grapple_flight = false end
  if release_g then
    g = release_g
  else
  -- Extra downward gravity when falling
  if self.vy < 0 then g = g * (self._cfg.fall_gravity_mult or 1.0) end
  -- Apex hang: lighten gravity around peak (if not in extended jump hang)
  local apex_th = (self._cfg.apex_threshold_vy or 0)
  if apex_th > 0 and math.abs(self.vy) <= apex_th and not extended_jump_hang_active then
    g = g * (self._cfg.apex_gravity_mult or 1.0)
  end
  end
  -- Fast-fall when holding down
  if input and (input.move_y or 0) < -((self._cfg.fast_fall_threshold or 0.5)) then
    g = g * (self._cfg.fast_fall_mult or 1.0)
  end
  -- Glide: hold jump to slow descent (does not apply during extended jump hang)
  local debug_glide = glide_debug_enabled()
  do
    local GL = self._cfg.glide
    -- Don't glide during extended jump hang, and check that we're not fast-falling
    local not_fast_falling = (not input) or ((input.move_y or 0) >= -((self._cfg.fast_fall_threshold or 0.5)))

    -- Debug: show when falling (controlled by debug_config.gameplay.glide)
    if debug_glide and not self.grounded and self.vy < 0 then
      local jump_held = input and input.jump_held
      glide_log(string.format("[GLIDE] Falling: vy=%.1f, jump_held=%s, glide_enabled=%s, not_fast_falling=%s, extended_hang=%s",
        self.vy, tostring(jump_held), tostring(GL and GL.enabled), tostring(not_fast_falling), tostring(extended_jump_hang_active)))
    end

    if not self._pound_active and not release_g and GL and GL.enabled and not self.grounded and self.vy < 0 and not_fast_falling and not extended_jump_hang_active then
      local want = (not GL.require_jump_held) or (input and input.jump_held)

      -- Debug: show glide decision (controlled by debug_config.gameplay.glide)
      if debug_glide then
        glide_log(string.format("[GLIDE] Check: want=%s, require_jump_held=%s, jump_held=%s",
          tostring(want), tostring(GL.require_jump_held), tostring(input and input.jump_held)))
      end

      if want then
        g = g * (GL.gravity_mult or 0.22)
        if debug_glide then
          glide_log(string.format("[GLIDE] *** ACTIVE *** gravity mult=%.2f", GL.gravity_mult or 0.22))
        end
        if GL.max_fall_speed and GL.max_fall_speed > 0 then
          -- Clamp downward velocity after applying gravity below
        end
      else
        if debug_glide then glide_log("[GLIDE] NOT active (want=false)") end
      end
    end
  end
  if not release_g then
  -- Early jump release (handled by existing jump_release_gravity_mult) - but not during extended jump,
  -- and never for the rising arc after letting go of a grapple (that ascent is swing momentum).
  if self.vy > 0 and input and not input.jump_held and (self._jump_hold_t or 0) <= 0
    and not self._extended_jump_active and not self._grapple_flight then
    g = g * (self._cfg.jump_release_gravity_mult or 1.0)
  end
  end
  self.vy = self.vy + g * dt
  -- Global max fall speed clamp (terminal velocity)
  do
    local maxfall = (CONFIG and CONFIG.physics and CONFIG.physics.max_fall_speed) or (self._cfg.max_fall_speed)
    if maxfall then
      -- maxfall expected negative (down)
      self.vy = math.max(self.vy, maxfall)
    end
  end

  -- Swim: clamp fall speed in water (game_config.player.swim).
  if self._in_water and (self._cfg.swim and self._cfg.swim.enabled) then
    local maxfall = self._cfg.swim.max_fall_speed or 0
    if maxfall > 0 then self.vy = math.max(self.vy, -maxfall) end
  end

  -- Apply glide max fall speed clamp ONLY when glide is actually active
  do
    local GL = self._cfg.glide
    if not self._pound_active and not release_g and GL and GL.enabled and not self.grounded and self.vy < 0 then
      -- Only apply speed cap if jump button is being held (glide is active)
      local glide_active = (not GL.require_jump_held) or (input and input.jump_held)
      if glide_active and GL.max_fall_speed and GL.max_fall_speed > 0 then
        self.vy = math.max(self.vy, -GL.max_fall_speed)
        if debug_glide then
          glide_log("[GLIDE] *** SPEED CAP APPLIED *** max_fall_speed=" .. GL.max_fall_speed)
        end
      end
    end
  end

  -- Wall slide fall cap (see the wall slide block above).
  if self._wall_sliding and self.vy < 0 then
    local WJ = (self._cfg.wall_climb and self._cfg.wall_climb.wall_jump) or {}
    local max_fall = tonumber(WJ.slide_fall_speed)
    if max_fall and max_fall > 0 then
      self.vy = math.max(self.vy, -max_fall)
    end
  end

  -- If a jump is buffered and we regain a valid jump window (ground or coyote), consume it
  if not self._pound_active and (self._jump_buffer_t or 0) > 0 and (self.grounded or (self._coyote_t or 0) > 0) then
    self.vy = self._jump_speed
    self.grounded = false
    self._coyote_t = 0
    self._jump_buffer_t = 0
    self._jump_hold_t = self._cfg.jump_min_hold_time or 0
  end

  -- HUD: report current movement mode to UI (only when it changes)
  local mode
  if (self._dash_t or 0) > 0 then
    mode = "Air Dash"
  elseif (self._backdash_t or 0) > 0 then
    mode = "Backdash"
  elseif (self._roll_t or 0) > 0 then
    mode = "Roll"
  elseif (self._slide_t or 0) > 0 then
    mode = "Slide"
  elseif (self._slide_recovery_t or 0) > 0 then
    mode = "Recovery"
  elseif self._on_wall then
    mode = "Wall Climb"
  elseif self._extended_jump_active and self._extended_jump_hang_time > 0 then
    mode = "Extended Jump"
  elseif self._in_water then
    mode = "Swim"
  elseif self._run_gate then
    mode = "Run"
  else
    mode = "Walk"
  end
  if mode ~= self._last_mode then
    self._last_mode = mode
    pcall(msg.post, msg.url("main:/mode_hud#mode_hud"), hash("hud_mode"), { mode = mode })
  end
end

-- Recoil replaces movement on the affected axes: running into a hit must not
-- overpower the attacker-directed kick. A zero axis preserves existing motion.
function M.apply_knockback(self, kx, ky)
  M.cancel_ground_pound(self)
  if kx and kx ~= 0 then self.vx = kx end
  if ky and ky ~= 0 then self.vy = ky end
end

-- Lock controls briefly to simulate hit-stun
function M.apply_stun(self, t)
  local tt = tonumber(t) or 0
  if tt > 0 then
    M.cancel_ground_pound(self)
    Grapple.clear(self)
    self._stun_t = math.max(self._stun_t or 0, tt)
    self._control_locked = true
  end
end

-- Grant temporary invulnerability (e.g., after a successful parry)
function M.add_iframes(self, t)
  local tt = tonumber(t) or 0
  if tt > 0 then
    self._parry_iframes_t = math.max(self._parry_iframes_t or 0, tt)
  end
end

return M

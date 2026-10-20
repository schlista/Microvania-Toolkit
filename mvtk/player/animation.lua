-- mvtk/player/animation.lua
-- Runtime player animation helpers used by player.script.

local PlayerAnim = require "mvtk.player.player_animation"
local LadderClimb = require "mvtk.player.movement"
local PoundFeedback = require "mvtk.player.ground_pound_feedback"

local M = {}

local Config
local Debug = { animation = {}, global = {} }
local Util
local SPINE_MIX_BLEND_ADD
local SPINE_MIX_BLEND_REPLACE

function M.configure(opts)
  opts = opts or {}
  Config = opts.Config or Config
  Debug = opts.Debug or Debug
  Util = opts.Util or Util
  SPINE_MIX_BLEND_ADD = opts.SPINE_MIX_BLEND_ADD or SPINE_MIX_BLEND_ADD
  SPINE_MIX_BLEND_REPLACE = opts.SPINE_MIX_BLEND_REPLACE or SPINE_MIX_BLEND_REPLACE
end

local function resolve_player_anim_name(state)
  local overrides = Config
    and Config.player
    and Config.player.animation_overrides
  return PlayerAnim.resolve_anim_name(state, overrides)
end

function M.configured_player_uses_spine()
  local player_type = Config
    and Config.player
    and Config.player.player_type
    or "sprite"
  return tostring(player_type):lower() ~= "sprite"
end

function M.resolve_anim_uses_spine()
  local ok_auto, auto = pcall(go.get, "#anim", "auto_resolve_player_type")
  if ok_auto and (tonumber(auto) or 0) ~= 0 then
    return M.configured_player_uses_spine()
  end
  local ok_use_spine, use_spine = pcall(go.get, "#anim", "use_spine")
  return ok_use_spine and (use_spine ~= nil) and (tonumber(use_spine) or 0) ~= 0
end

-- Use scaled movement settings so changing body/tile scale alone does not
-- change cadence. The caller supplies velocity with conveyor carry removed.
function M.locomotion_rate(state, speed, settings)
  local pace = settings and settings.locomotion_animation
  if (state ~= "walk" and state ~= "run")
    or not pace or pace.enabled == false then return 1 end
  local reference = tonumber(settings.walk_speed) or 0
  if reference <= 0 then return 1 end
  local multiplier = tonumber(pace[state .. "_multiplier"]) or 1
  local minimum = math.max(0, tonumber(pace.min_rate) or 0)
  local maximum = math.max(minimum, tonumber(pace.max_rate) or math.huge)
  return math.max(minimum, math.min(maximum,
    math.abs(tonumber(speed) or 0) / reference * multiplier))
end

-- Footstep phase follows movement, independently of art playback multipliers.
-- Both speeds come from scaled player settings; conveyor carry is excluded by
-- the caller. Above full run speed, keep the configured running cadence.
function M.footstep_interval(speed, settings)
  local steps = settings and settings.footsteps
  if not steps or steps.enabled == false then return nil end
  local walk = tonumber(settings.walk_speed) or 0
  local run = tonumber(settings.run_speed) or walk
  local walk_interval = tonumber(steps.walk_interval) or 0
  local run_interval = tonumber(steps.run_interval) or 0
  local magnitude = math.abs(tonumber(speed) or 0)
  local minimum = math.max(0, tonumber(steps.min_speed_ratio) or 0) * walk
  if walk <= 0 or walk_interval <= 0 or run_interval <= 0
    or magnitude <= minimum then return nil end
  if magnitude <= walk then
    return walk_interval * walk / magnitude
  end
  if run <= walk then return walk_interval end
  local blend = math.min(1, (magnitude - walk) / (run - walk))
  return walk_interval + (run_interval - walk_interval) * blend
end

function M.footstep_due(self, dt, speed, active, settings)
  local interval = active and M.footstep_interval(speed, settings)
  if not interval then
    self._footstep_phase = nil
    return false
  end
  -- A fresh movement starts with one step; a speed change keeps the partial
  -- stride so walking/running transitions cannot restart or double-trigger it.
  if self._footstep_phase == nil then
    self._footstep_phase = 0
    return true
  end
  local phase = self._footstep_phase + math.max(0, tonumber(dt) or 0) / interval
  self._footstep_phase = phase % 1
  -- At most one sound per update, even following a long frame.
  return phase >= 1
end

function M.anim_set(self, state, opts)
  if not state then return end
  -- A committed slam shows its configured pose instead of jump/fall.
  if self._pound_active and (state == "fall" or state == "jump") then
    state = PoundFeedback.slam_pose() or state
  end
  local resolved_state = resolve_player_anim_name(state)
  local rate = opts and opts.playback_rate or 1
  if opts and opts.locomotion_speed ~= nil then
    rate = M.locomotion_rate(state, opts.locomotion_speed, opts.locomotion_config)
  end
  if self._anim_current == resolved_state
    and self._anim_state_managed == true
    and self._anim_playback_rate == rate
    and not (opts and opts.force) then
    return
  end
  self._anim_current = resolved_state
  self._anim_state_managed = true
  self._anim_playback_rate = rate
  if Debug.animation.controller or Debug.global.enable then
    -- Debug disabled
  end
  msg.post("#anim", PlayerAnim.MSG_SET_STATE, {
    state = resolved_state,
    requested_state = state,
    state_managed = true,
    force = opts and opts.force,
    loop  = opts and opts.loop,
    blend = opts and opts.blend,
    playback_rate = rate,
  })
end

local function same_animation_id(a, b)
  if a == nil or b == nil then return false end
  if a == b then return true end
  if type(a) == "string" then a = hash(a) end
  if type(b) == "string" then b = hash(b) end
  return a == b
end

-- The controller owns actual playback and may replace a completed base-track
-- one-shot with its default animation. Keep the player-side request cache from
-- suppressing the authoritative state machine when that happens.
function M.on_animation_done(self, message)
  local track = tonumber(message and message.track) or 1
  if track > 1
    or not (message and message.fallback == true)
    or message.missing == true then
    return false
  end

  local completed = message and message.state
  if completed ~= nil and not same_animation_id(self._anim_current, completed) then
    -- A delayed completion from an older animation must not invalidate a newer
    -- request that is already driving the base track.
    return false
  end

  self._anim_current = nil
  self._anim_state_managed = nil
  return true
end

function M.anim_once(self, state, opts)
  if not state then return end
  local resolved_state = resolve_player_anim_name(state)
  self._anim_current = resolved_state
  self._anim_state_managed = false
  local msgtbl = {
    state = resolved_state,
    requested_state = state,
    blend = opts and opts.blend,
  }
  if opts then
    if opts.track ~= nil then msgtbl.track = opts.track end
    if opts.mix_blend ~= nil then msgtbl.mix_blend = opts.mix_blend end
    if opts.playback_rate ~= nil then msgtbl.playback_rate = opts.playback_rate end
    if opts.offset ~= nil then msgtbl.offset = opts.offset end
  end
  msg.post("#anim", PlayerAnim.MSG_PLAY_ONCE, msgtbl)
end

function M.anim_overlay_once(self, state, opts)
  if not state then return end
  local resolved_state = resolve_player_anim_name(state)
  local msgtbl = {
    state = resolved_state,
    blend = opts and opts.blend,
    overlay = true,
  }
  if opts then
    if opts.track ~= nil then msgtbl.track = opts.track end
    if opts.mix_blend ~= nil then msgtbl.mix_blend = opts.mix_blend end
    if opts.playback_rate ~= nil then msgtbl.playback_rate = opts.playback_rate end
    if opts.offset ~= nil then msgtbl.offset = opts.offset end
  end
  msg.post("#anim", PlayerAnim.MSG_PLAY_ONCE, msgtbl)
end

function M.anim_once_lock(self, state, lock_t, opts)
  M.anim_once(self, state, opts)
  self._anim_lock_t = lock_t or 0
  if opts and opts.allow_movement ~= nil then
    self._anim_lock_allow_movement = opts.allow_movement and true or false
  else
    self._anim_lock_allow_movement = true
  end
end

function M.anim_attack(self, state, lock_t, opts)
  if not state then return end
  self._attack = nil
  local on_ground = self.grounded
  local force_block = opts and opts.allow_movement == false
  if self._anim_is_spine then
    M.anim_overlay_once(self, state, {
      blend = opts and opts.blend,
      track = 2,
      mix_blend = SPINE_MIX_BLEND_REPLACE,
    })
  else
    M.anim_once(self, state, { blend = opts and opts.blend })
  end
  self._attack = {
    elapsed = 0,
    ground  = on_ground or force_block,
  }
end

function M.play_attack_animation_from_def(self, attack)
  if not attack then return end
  local state, blend = PlayerAnim.resolve_attack_anim(attack, self._anim_is_spine, self.grounded, self.vx)

  if self._anim_is_spine then
    M.anim_overlay_once(self, state, {
      blend = blend,
      track = 2,
      mix_blend = SPINE_MIX_BLEND_REPLACE,
    })
  else
    M.anim_once(self, state, { blend = blend })
  end
end

-- Ladder movement owns facing while attached. Wall/ledge contact hints may
-- still be present from the previous frame and must not turn the climb pose.
function M.update_facing(self, input, dt)
  local move_x = input and (input.move_x or 0) or 0
  local turn_input = math.abs(move_x) > 0.1
  if (self._in_climb or self._in_climb_zone)
    and not self._in_water and not self._grapple_active then
    move_x = LadderClimb.climb_horizontal_input(input)
    turn_input = move_x ~= 0
  end
  if self._in_climb and not self._in_water then
    if turn_input then
      self.facing = (move_x >= 0) and 1 or -1
    end
  elseif self._ledge_kinematic then
    local ledge_side = (self._ledge_climbing and self._ledge_climb_side) or self._ledge_hang_side or 0
    if ledge_side ~= 0 then self.facing = ledge_side end
  elseif self._block_grab and (self._block_grab.dir or 0) ~= 0 then
    self.facing = self._block_grab.dir
  elseif self._on_wall and (self._wall_side or 0) ~= 0 then
    self.facing = -self._wall_side
  elseif self._facing_lock_until_input then
    if turn_input then
      self.facing = (move_x >= 0) and 1 or -1
      self._facing_lock_until_input = false
    end
    if (self._facing_lock_t or 0) > 0 then
      self._facing_lock_t = math.max(0, (self._facing_lock_t or 0) - dt)
    end
  elseif (self._facing_lock_t or 0) > 0 then
    self._facing_lock_t = math.max(0, (self._facing_lock_t or 0) - dt)
    if turn_input then
      self.facing = (move_x >= 0) and 1 or -1
    end
  else
    -- Passive world motion must not flip the character. Outside explicit
    -- wall/ledge/grab locks, facing is a player-input decision only.
    if turn_input then
      self.facing = (move_x >= 0) and 1 or -1
    end
  end
end

function M.anim_face(self, dir)
  local d = (dir and dir < 0) and -1 or 1
  if self._anim_facing ~= d then
    if Debug.animation.flip or Debug.global.enable then
      local input = self._input_frame or {}
      local wall = self._cfg and self._cfg.wall_climb or {}
      local pos = self.pos or {}
      print(string.format(
        "[PLAYER_FACING] frame=%d %s->%d input=(%.3f,%.3f) climb=%s zone=%s ladder=%s wall=%s side=%d grounded=%s pos=(%.1f,%.1f) wall_climb=%s wall_jump=%s",
        tonumber(self._frame_counter) or -1, tostring(self._anim_facing), d,
        tonumber(input.move_x) or 0, tonumber(input.move_y) or 0,
        tostring(self._in_climb == true), tostring(self._in_climb_zone == true), tostring(self._climb_ladder_id),
        tostring(self._on_wall == true), tonumber(self._wall_side) or 0, tostring(self.grounded == true),
        tonumber(pos.x) or 0, tonumber(pos.y) or 0,
        tostring(wall.enabled == true), tostring(wall.wall_jump and wall.wall_jump.enabled == true or false)))
    end
    self._anim_facing = d
    msg.post("#anim", PlayerAnim.MSG_SET_FACING, { dir = d })
  end
end

function M.normalize_facing(value)
  local v = tonumber(value)
  if not v then
    local s = tostring(value or ""):lower()
    if s == "left" or s == "-1" then
      v = -1
    else
      v = 1
    end
  end
  if v == 0 then v = 1 end
  return v < 0 and -1 or 1
end

function M.slippery_reverse_facing_dir(self, input, vx)
  if not self or not input or not self.grounded or self._in_water or self._in_climb then
    return nil
  end
  if math.abs(vx or 0) <= 10 then
    return nil
  end
  local raw = tonumber(input.move_x) or 0
  if math.abs(raw) <= 0.1 then
    return nil
  end
  local input_dir = (raw >= 0) and 1 or -1
  local sign = Util and Util.sign or function(value)
    return (value or 0) < 0 and -1 or 1
  end
  if sign(vx) == input_dir then
    return nil
  end
  local turn_brake = ((self._cfg and self._cfg.turn_brake_mult) or 1.0)
  if turn_brake >= 0.9999 then
    return nil
  end
  return input_dir
end

M.MSG_SET_STATE = PlayerAnim.MSG_SET_STATE
M.MSG_PLAY_ONCE = PlayerAnim.MSG_PLAY_ONCE
M.MSG_SET_FACING = PlayerAnim.MSG_SET_FACING
M.MSG_ANIM_DONE = PlayerAnim.MSG_ANIM_DONE
M.MSG_ANIM_MISSING = PlayerAnim.MSG_ANIM_MISSING
M.resolve_player_anim_name = resolve_player_anim_name

return M

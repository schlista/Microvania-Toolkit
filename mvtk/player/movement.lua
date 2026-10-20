-- mvtk/player/movement.lua
-- Player movement helper routines that still operate on player.script state.

local M = {}
local BonePhysics = require "mvtk.player.bone_physics"
local ladder_climb_defaults = require("developer.config.player_settings").ladder_climb

local Debug = { global = {}, gameplay = {} }
local SurfaceClassifier
local sync_player_position
local player_log
local raw_print = print
local ladder_climb = {}

M.ONE_WAY_TRACE = false
M.ONE_WAY_JUMP_PROBE = hash("jump_pass_probe")
M.FORCE_FALL_DEFAULT_FRAMES = 15
M.ONE_WAY_DROP_BYPASS_FRAMES = 20

function M.configure(opts)
  opts = opts or {}
  Debug = opts.Debug or Debug
  SurfaceClassifier = opts.SurfaceClassifier or SurfaceClassifier
  sync_player_position = opts.sync_player_position or sync_player_position
  player_log = opts.player_log or player_log
  raw_print = opts.raw_print or raw_print
  ladder_climb = opts.ladder_climb or ladder_climb
end

local function ground_groups()
  return SurfaceClassifier and SurfaceClassifier.RAYCAST and SurfaceClassifier.RAYCAST.GROUND or nil
end

function M.climb_log(self, fmt, ...)
  if not (Debug.global.enable or Debug.gameplay.player) then
    return
  end
  local pos = self and self.pos or go.get_position()
  local ok, body = pcall(string.format, fmt, ...)
  if not ok then
    body = tostring(fmt)
  end
  raw_print(string.format(
    "[PLAYER_CLIMB frame=%d in=%s zone=%s grounded=%s bg=%d bc=%d vx=%.1f vy=%.1f pos=(%.1f,%.1f)] %s",
    tonumber(self and self._frame_counter) or -1,
    tostring(self and self._in_climb),
    tostring(self and self._in_climb_zone),
    tostring(self and self.grounded),
    tonumber(self and self.bypass_ground_frames) or 0,
    tonumber(self and self.bypass_ceiling_frames) or 0,
    tonumber(self and self.vx) or 0,
    tonumber(self and self.vy) or 0,
    tonumber(pos and pos.x) or 0,
    tonumber(pos and pos.y) or 0,
    body
  ))
end

function M.one_way_log(self, fmt, ...)
  if not M.ONE_WAY_TRACE then
    return
  end
  local pos = self and self.pos or go.get_position()
  local ok, body = pcall(string.format, fmt, ...)
  if not ok then
    body = tostring(fmt)
  end
  raw_print(string.format(
    "[PLAYER_ONE_WAY frame=%d facing=%s grounded=%s vx=%.1f vy=%.1f pos=(%.1f,%.1f)] %s",
    tonumber(self and self._frame_counter) or -1,
    tostring(self and self.facing),
    tostring(self and self.grounded),
    tonumber(self and self.vx) or 0,
    tonumber(self and self.vy) or 0,
    tonumber(pos and pos.x) or 0,
    tonumber(pos and pos.y) or 0,
    body
  ))
end

function M.probe_upward_one_way(self)
  local player_id = go.get_id()
  -- Room streaming can remove the last contacted platform. msg.post queues
  -- delivery, so pcall cannot catch a missing receiver at dispatch time.
  if self and self._one_way and not go.exists(self._one_way) then
    self._one_way = nil
    self._one_way_bounds_bottom = nil
    self._one_way_bounds_top = nil
  end
  if self and self._one_way then
    M.one_way_log(self, "jump_probe cached target=%s", tostring(self._one_way))
    local ok_post = pcall(msg.post, self._one_way, M.ONE_WAY_JUMP_PROBE, {
      other_id = player_id,
      source = msg.url(),
      mode = hash("cached"),
    })
    M.one_way_log(self, "jump_probe cached_post ok=%s target=%s", tostring(ok_post), tostring(self._one_way))
    return
  end

  local half_h = tonumber(self and self.collider_half_height) or 60
  local probe_up = math.max(96, (half_h * 2) + 24)
  local pos = self and self.pos or go.get_position()
  local origin = vmath.vector3(pos.x, pos.y + half_h - 2, pos.z or 0)
  local target = vmath.vector3(origin.x, origin.y + probe_up, origin.z)
  local ok, hit = pcall(physics.raycast, origin, target, ground_groups())
  if not ok then
    M.one_way_log(self, "jump_probe raycast error")
    return
  end
  if not hit then
    M.one_way_log(self, "jump_probe miss origin=(%.1f,%.1f) target=(%.1f,%.1f)", origin.x, origin.y, target.x, target.y)
    return
  end
  M.one_way_log(
    self,
    "jump_probe hit id=%s group=%s pos=(%.1f,%.1f) normal=(%.2f,%.2f)",
    tostring(hit.id),
    tostring(hit.group),
    tonumber(hit.position and hit.position.x) or 0,
    tonumber(hit.position and hit.position.y) or 0,
    tonumber(hit.normal and hit.normal.x) or 0,
    tonumber(hit.normal and hit.normal.y) or 0
  )
  if hit.id and go.exists(hit.id) then
    local ok_post = pcall(msg.post, hit.id, M.ONE_WAY_JUMP_PROBE, {
      other_id = player_id,
      source = msg.url(),
      mode = hash("raycast"),
    })
    M.one_way_log(self, "jump_probe raycast_post ok=%s target=%s", tostring(ok_post), tostring(hit.id))
  end
end

function M.update_ladder_top_pass_through(self, input)
  if not (self and self._in_climb and not self._in_water and self._climb_pass_through_top) then
    if self and self._climb_top_pass_active then
      self._climb_top_pass_active = false
      M.climb_log(self, "top_pass disabled reason=inactive")
    end
    return
  end

  local climb_input = input and (input.move_y or 0) or 0
  if climb_input <= 0.1 then
    if self._climb_top_pass_active then
      self._climb_top_pass_active = false
      M.climb_log(self, "top_pass disabled reason=input move_y=%.2f", climb_input)
    end
    return
  end

  if not self._climb_top_pass_active then
    local center_y = tonumber(self._climb_center_y) or 0
    local ladder_height = tonumber(self._climb_height) or 0
    local ladder_top = center_y + (ladder_height * 0.5)
    local head_y = (self.pos.y or 0) + (self.collider_half_height or 60)
    M.climb_log(self, "top_pass enabled move_y=%.2f head_y=%.1f ladder_top=%.1f", climb_input, head_y, ladder_top)
  end
  self._climb_top_pass_active = true
  self.bypass_ceiling_frames = math.max(self.bypass_ceiling_frames or 0, 1)
end

-- Effective x the climbing player snaps to: the ladder's authored center plus
-- the ladder's climb_offset_x nudge. Returns nil when no ladder is attached so
-- callers keep their existing nil guards.
function M.climb_snap_x(self)
  local cx = tonumber(self and self._climb_center_x)
  if not cx then return nil end
  return cx + (tonumber(self and self._climb_offset_x) or 0)
end

-- Defold's radial stick deadzone retains small X values while holding Up/Down.
-- Use one intent policy for ladder movement, facing and sideways top exits.
function M.climb_horizontal_input(input)
  local move_x = input and (input.move_x or 0) or 0
  local move_y = input and (input.move_y or 0) or 0
  local threshold = tonumber(ladder_climb.side_input_threshold)
    or ladder_climb_defaults.side_input_threshold
  local vertical_ratio = tonumber(ladder_climb.side_input_vertical_ratio)
    or ladder_climb_defaults.side_input_vertical_ratio
  if math.abs(move_x) <= math.max(0, threshold)
    or math.abs(move_x) < math.abs(move_y) * math.max(0, vertical_ratio) then
    return 0
  end
  return move_x
end

-- Filter the player's frame copy, including airborne/grounded zone overlaps.
-- Otherwise a rejected top grab can still turn or move on sideways stick wobble.
function M.filter_climb_input(self, input)
  if input and (self._in_climb or self._in_climb_zone)
    and not self._in_water and not self._grapple_active then
    input.move_x = M.climb_horizontal_input(input)
  end
end

-- Holding Up near the top must not grab the same ladder again, including while
-- jumping or falling onto its landing. Down still attaches to climb back down.
function M.can_enter_climb(self, input)
  if self._pound_active then return false end
  local move_y = input and (input.move_y or 0) or 0
  if math.abs(move_y) <= 0.25 then return false end
  if move_y > 0 and self._climb_center_y then
    local feet_y = self.pos.y - (self.collider_half_height or 60) + (self.foot_floor_adjust or 0)
    local top_y = self._climb_center_y + (self._climb_height or 0) * 0.5
    local top_margin = math.max(24, (self.collider_half_height or 60) * 0.4)
    if feet_y >= top_y - top_margin - 2 then return false end
  end
  return true
end

function M.detect_climb_top_out(self, input)
  if not (self and self._in_climb and self._climb_pass_through_top and not self._in_water) then
    return false, nil, nil
  end

  local climb_input = input and (input.move_y or 0) or 0
  local move_x = M.climb_horizontal_input(input)
  if climb_input < -0.1 or (climb_input <= 0.1 and move_x == 0) then
    return false, nil, nil
  end

  local center_x = M.climb_snap_x(self)
  local center_y = tonumber(self._climb_center_y)
  local ladder_height = tonumber(self._climb_height) or 0
  local ladder_width = tonumber(self._climb_width) or 0
  if not center_x or not center_y or ladder_height <= 0 then
    return false, nil, nil
  end

  local half_height = tonumber(self.collider_half_height) or 60
  local half_width = tonumber(self.collider_half_width) or 30
  local hands_y = (self.pos.y or 0) + half_height * (tonumber(ladder_climb.hand_height_ratio) or 1)
  local ladder_top = center_y + (ladder_height * 0.5)
  local top_margin = math.max(24, half_height * 0.4)
  if hands_y < ladder_top - top_margin then
    return false, nil, nil
  end

  local ctx = self._bone_physics
  if not ctx then return false, nil, nil end
  local floor_adjust = ctx.foot_floor_adjust or 0
  local candidates = {}
  if move_x ~= 0 then
    local side = move_x < 0 and -1 or 1
    -- The platform may start beside the ladder rectangle, not over its centre.
    -- Put the whole collider over that edge; authored ladder size and player
    -- size determine the reach, including the ladder's horizontal art offset.
    candidates[#candidates + 1] = center_x + side * (ladder_width * 0.5 + half_width + 1)
  end
  if climb_input > 0.1 then
    candidates[#candidates + 1] = self.pos.x
  end

  for _, target_x in ipairs(candidates) do
    local target = vmath.vector3(target_x, ladder_top + top_margin + half_height - floor_adjust, self.pos.z or 0)
    local support = BonePhysics.probe_ledge_support(self, target, self.pos, {
      min_surface_y = ladder_top - top_margin,
    })
    if support and support.hit.position.y <= ladder_top + top_margin
      and hands_y >= support.hit.position.y - 2 then
      -- Check room above the landing surface before pulling up. Start just
      -- above the floor so a pass-through platform does not block its own exit.
      local clear = true
      local head_y = support.position.y + math.max(half_height, ctx.head_offset or 0) + (ctx.head_margin or 0)
      for _, sample in ipairs({ -0.8, 0, 0.8 }) do
        local x = target_x + sample * half_width
        local ok, hit = pcall(physics.raycast,
          vmath.vector3(x, support.hit.position.y + 1, self.pos.z or 0),
          vmath.vector3(x, head_y, self.pos.z or 0), ctx.ceiling_groups)
        if not ok or hit then clear = false; break end
      end
      -- Sweep sideways at standing height, after rising through the allowed
      -- ladder top, so a wall between the ladder and landing cannot be skipped.
      local raised = vmath.vector3(self.pos.x, support.position.y, self.pos.z or 0)
      if clear and BonePhysics.sweep_ledge_motion(self, raised, support.position) then
        return true, support.hit.position.y, support.hit.group, support
      end
    end
  end
  return false, nil, nil
end

function M.detect_climb_bottom_out(self, input, prev_pos)
  if not (self and self._in_climb and not self._in_water and prev_pos) then
    return false, nil, nil
  end

  local climb_input = input and (input.move_y or 0) or 0
  if climb_input >= -0.1 then
    return false, nil, nil
  end

  local center_x = M.climb_snap_x(self)
  local center_y = tonumber(self._climb_center_y)
  local ladder_height = tonumber(self._climb_height) or 0
  local ladder_width = tonumber(self._climb_width) or 0
  if not center_x or not center_y or ladder_height <= 0 then
    return false, nil, nil
  end

  local half_height = tonumber(self.collider_half_height) or 60
  local prev_feet_y = (prev_pos.y or 0) - half_height
  local feet_y = (self.pos.y or 0) - half_height
  local ladder_bottom = center_y - (ladder_height * 0.5)
  if feet_y >= prev_feet_y then
    return false, nil, nil
  end

  local descend_span = math.max(16, math.min((prev_feet_y - feet_y) + 12, 48))
  local origin_y = prev_feet_y + 8
  local target_y = feet_y - descend_span
  local best_hit = nil
  local samples = { -0.35, 0.0, 0.35 }
  local ladder_half_width = math.max((ladder_width > 0 and ladder_width or 32) * 0.5, 8)
  local sample_span = math.max(6, ladder_half_width * 0.55)
  local max_slope_angle = self._bone_physics and self._bone_physics.max_slope_angle or nil
  for _, sample in ipairs(samples) do
    local sx = center_x + (sample * sample_span)
    local origin = vmath.vector3(sx, origin_y, self.pos.z or 0)
    local target = vmath.vector3(sx, target_y, self.pos.z or 0)
    -- pcall: same defensive wrapper as detect_climb_top_out (above).
    local ok_rc, hit = pcall(physics.raycast, origin, target, ground_groups())
    if ok_rc and hit and hit.position and SurfaceClassifier.is_ground_collision(hit, max_slope_angle) and (not best_hit or hit.position.y > best_hit.position.y) then
      best_hit = hit
    end
  end

  if not best_hit or not best_hit.position then
    return false, nil, nil
  end

  local surface_y = best_hit.position.y
  local bottom_margin = math.max(12, half_height * 0.2)
  if surface_y > (ladder_bottom + bottom_margin) then
    return false, nil, nil
  end
  local clearance = 2
  if prev_feet_y >= (surface_y - clearance) and feet_y <= (surface_y + clearance) then
    return true, surface_y, best_hit.group
  end
  return false, nil, nil
end

function M.integrate(self, dt)
  self.pos.x = self.pos.x + (self.vx or 0) * dt
  self.pos.y = self.pos.y + (self.vy or 0) * dt
  sync_player_position(self)
end

function M.apply_force_falling(self, message)
  local reason = (message and message.reason) or "external"
  local frames = tonumber(message and message.frames) or M.FORCE_FALL_DEFAULT_FRAMES
  local vy = tonumber(message and message.vy) or -100
  if player_log then
    player_log(string.format("[PLAYER] Force falling reason=%s frames=%d vy=%.1f", tostring(reason), frames, vy))
  end
  M.one_way_log(self, "force_falling reason=%s frames=%d vy=%.1f", tostring(reason), frames, vy)
  self.grounded = false
  self._in_air = true
  self.vy = vy
  self._one_way = nil
  self._ground_normal = nil
  self._ground_is_platform = false
  local teleport = message and (message.pos or message.position)
  if teleport and teleport.x ~= nil and teleport.y ~= nil then
    self.pos = vmath.vector3(teleport.x, teleport.y, self.pos.z or 0)
    sync_player_position(self)
    rawset(_G, "PLAYER_WORLD_POS", go.get_world_position())
  end
  self.bypass_ground_frames = math.max(self.bypass_ground_frames or 0, frames)
  local ctx = self._bone_physics
  if ctx then
    ctx.last_ground_y = nil
    ctx.last_ground_x = nil
    ctx.last_ground_group = nil
    ctx.last_ground_normal = nil
    ctx.stable_ground_y = nil
    ctx.missed_ground_frames = 0
  end
end

return M

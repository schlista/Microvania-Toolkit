-- mvtk/player/bone_physics.lua
-- Bone-driven collision helpers for the player.

local BoneCollision = require "mvtk.animation.bone_collision"
local SurfaceClassifier = require "mvtk.core.surface_classifier"
local CeilingProbe = require "mvtk.player.ceiling_probe"
local SpineVisual = require "mvtk.player.spine_visual"
local ok_tile, TileSettings = pcall(require, "developer.config.tile_settings")
if not ok_tile or type(TileSettings) ~= "table" then
  TileSettings = {}
end

-- Pre-allocated scratch vectors to avoid per-frame allocations in hot physics paths.
-- Each index is dedicated to a specific usage context to prevent clobbering.
local _sv = {}
for _i = 1, 10 do _sv[_i] = vmath.vector3() end

--- Set scratch vector fields in-place and return it. Zero-alloc.
local function sv(idx, x, y, z)
  local v = _sv[idx]; v.x = x; v.y = y; v.z = z or 0; return v
end

local DEFAULT_FEET = { "foot_far", "foot_near" }
local DEFAULT_HEAD = "head"
local DEFAULT_COLLIDER_FOOT_SAMPLES = { -0.45, 0.0, 0.45 }
-- Wall samples: only check at knee height and above to avoid hitting stair steps
-- Values are multiplied by half_height, so 0.0 = center, 0.5 = near top, -0.5 = near bottom
-- Ordered from bottom to top - we check lower first so stair detection logic can work
local DEFAULT_WALL_SAMPLES = { -0.5, 0.0, 0.5 }
local DEFAULT_TILE_HEIGHT = tonumber(TileSettings.height or TileSettings.tile_height) or 128
local DEFAULT_MIN_WALL_CLIMB_TILES = 3

local PLATFORM = SurfaceClassifier.GROUPS.PLATFORM
local GROUND_GROUPS = SurfaceClassifier.RAYCAST.GROUND
-- Exclude the "world" group from wall raycasts: pushable blocks live in that
-- group and must NOT be treated as walls here, otherwise resolve_horizontal
-- zeroes self.vx before the kinematic contact_point_response can compute a
-- push amount (grounded pushes would never be applied, and airborne pushes
-- would be reduced to whatever tiny diagonal component the contact normal
-- happened to have). "world" is still included in ground/ceiling groups so
-- the player can stand on and bonk into blocks normally.
local WORLD_GROUP = SurfaceClassifier.GROUPS.WORLD
local WALL_GROUPS = {}
for _, g in ipairs(SurfaceClassifier.RAYCAST.WALL) do
  if g ~= WORLD_GROUP then
    WALL_GROUPS[#WALL_GROUPS + 1] = g
  end
end
local CEILING_GROUPS = SurfaceClassifier.RAYCAST.CEILING

local function ensure_offsets(self)
  local ctx = self._bone_physics
  if not ctx then return end

  -- Allow disabling bone-driven footing entirely (collider-only grounding)
  if ctx.use_bone_feet == false then return end

  if ctx.use_bone_feet and ctx.offsets_ready then return end

  local frame = self._frame_counter
  if frame == nil then
    ctx.offset_attempts = (ctx.offset_attempts or 0) + 1
    frame = ctx.offset_attempts
  end
  frame = frame or 0
  local interval = ctx.offset_check_interval or 10
  if ctx.next_offset_check and frame < ctx.next_offset_check then
    return
  end
  ctx.next_offset_check = frame + interval

  local root_pos = go.get_position()
  local all_found = true
  ctx.offsets = ctx.offsets or {}
  ctx.missing_foot_log = ctx.missing_foot_log or {}

  local fallback_offset = -(self.collider_half_height or 60)
  for _, name in ipairs(ctx.feet) do
    local pos = BoneCollision.get_bone_position(ctx.spine_url, name)
    if pos then
      ctx.offsets[name] = root_pos.y - pos.y
      if ctx.missing_foot_log[name] then
        ctx.missing_foot_log[name] = nil
        if ctx.debug then print("[BONE PHYSICS] Foot bone resolved:", name) end
      end
    else
      all_found = false
      if ctx.debug and not ctx.missing_foot_log[name] then
        print("[BONE PHYSICS] Missing foot bone:", name)
        ctx.missing_foot_log[name] = true
      end
      ctx.offsets[name] = ctx.offsets[name] or fallback_offset
    end
  end

  if ctx.head then
    local head_pos = BoneCollision.get_bone_position(ctx.spine_url, ctx.head)
    if head_pos then
      ctx.head_offset = head_pos.y - root_pos.y
    elseif not ctx.head_offset then
      ctx.head_offset = self.collider_half_height or 60
    end
  end

  if all_found then
    ctx.use_bone_feet = true
    ctx.offsets_ready = true
    if ctx.debug then print("[BONE PHYSICS] Foot offsets locked from bone data") end
  else
    ctx.offsets_ready = false
  end
end

local function slope_lift_offset(normal, ctx)
  if not (normal and ctx) then return 0 end
  local ny = normal.y or 0
  local nx = math.abs(normal.x or 0)
  if ny >= 0.999 then return 0 end
  -- Lift scales with how tilted the surface is; small but enough to keep feet from sinking.
  local lift = (ctx.slope_lift or 0)
  if lift <= 0 then return 0 end
  return lift * (1 - ny) * math.max(0.25, nx)
end

local function count_ground_support_hits(self, root_x, root_y, expected_root_y, sample_offsets)
  local ctx = self._bone_physics
  if not ctx then return 0 end

  local half_width = self.collider_half_width or 30
  local half_height = self.collider_half_height or 60
  local adjust = ctx.foot_floor_adjust or 0
  local lift = ctx.foot_probe_lift or 12
  local max_probe = math.max(24, math.min(ctx.max_step_up or 132, 64))
  local tolerance = math.max(10, math.min(half_height * 0.2, 16))
  local hits = 0
  local offsets = sample_offsets or { -0.25, 0.0, 0.25 }

  for _, offset in ipairs(offsets) do
    local sample_x = root_x + (half_width * offset)
    local origin = sv(7, sample_x, root_y - half_height + adjust + lift, 0)
    local target = sv(8, sample_x, root_y - half_height + adjust - max_probe, 0)
    local hit = physics.raycast(origin, target, ctx.ground_groups)
    if hit and SurfaceClassifier.is_ground_collision(hit, ctx.max_slope_angle) then
      local candidate_root = hit.position.y + half_height - adjust
      if math.abs(candidate_root - expected_root_y) <= tolerance then
        hits = hits + 1
      end
    end
  end

  return hits
end

local function has_ground_support_span(self, root_x, root_y, expected_root_y, min_hits, sample_offsets)
  return count_ground_support_hits(self, root_x, root_y, expected_root_y, sample_offsets) >= (min_hits or 2)
end

local M = {}

function M.init(self, opts)
  opts = opts or {}
  self._bone_physics = {
    spine_url = opts.spine_url or SpineVisual.resolve(),
    feet = opts.feet or DEFAULT_FEET,
    head = opts.head or DEFAULT_HEAD,
    ground_check = opts.ground_check or 64,
    wall_clearance = opts.wall_clearance or 6,
    ceiling_clearance = opts.ceiling_clearance or 8,
    head_margin = opts.head_margin or 0,
    ground_groups = opts.ground_groups or GROUND_GROUPS,
    wall_groups = opts.wall_groups or WALL_GROUPS,
    ceiling_groups = opts.ceiling_groups or CEILING_GROUPS,
    slope_lift = opts.slope_lift or 2,  -- Small lift on slopes to prevent sinking (2 pixels)
    fallback_max = opts.fallback_max or 1024,
    snap_epsilon = opts.snap_epsilon or 2.5,
    foot_probe_lift = opts.foot_probe_lift or 12,
    foot_samples = opts.foot_samples or DEFAULT_COLLIDER_FOOT_SAMPLES,
    descend_probe_mul = opts.descend_probe_mul or 0.03,
    max_step_down = opts.max_step_down or (opts.fallback_max or 1024),
    max_snap_up = opts.max_snap_up or 132,
    landing_snap_distance = math.max(0, opts.landing_snap_distance or 0),
    max_step_up = opts.max_step_up or 132,  -- Maximum height player can auto-step up (should match tile height ~128)
    max_slope_angle = opts.max_slope_angle or 50,  -- Maximum walkable slope angle in degrees
    offset_check_interval = opts.offset_check_interval or 10,
    foot_floor_adjust = opts.foot_floor_adjust or 0,
    use_bone_feet = (opts.use_bone_feet ~= false),
    -- How close (px) the collider edge must be to the wall before we report a
    -- wall contact (engage cling) and snap flush. The proactive wall ray reaches
    -- farther to zero velocity early; this keeps cling from latching at a gap.
    wall_attach_slop = opts.wall_attach_slop or 3,
    offsets = {},
    offsets_ready = false,
    debug = false,
  }
end

local function dbg(self, fmt, ...)
  local ctx = self._bone_physics
  if ctx and ctx.debug then
    print("[BONE PHYSICS]", string.format(fmt, ...))
  end
end

local function trace_climb(self, fmt, ...)
  if not (self and self._climb_trace) then
    return
  end
  if not (self._in_climb or (self.bypass_ceiling_frames or 0) > 0 or (self.bypass_ground_frames or 0) > 0) then
    return
  end
  local ok, body = pcall(string.format, fmt, ...)
  if not ok then
    body = tostring(fmt)
  end
  print(string.format("[BONE_CLIMB] %s", body))
end

-- Attempt to step up small ledges/slopes that would otherwise block horizontal movement.
-- Returns true if we nudged the player up and forward.
local function try_step_up(self, dir, hit, foot_y)
  local ctx = self._bone_physics
  if not (ctx and hit and hit.position) then return false end

  local max_step = ctx.max_step_up or 112
  local clearance = ctx.wall_clearance or 6
  local half_height = self.collider_half_height or 60
  local half_width = self.collider_half_width or 30
  local step_height = hit.position.y - foot_y
  if step_height <= 1 or step_height > max_step then return false end

  -- Cast down from a point just above/forward of the obstacle to find the top surface
  local lift = (ctx.foot_probe_lift or 12) + max_step
  local origin = vmath.vector3(hit.position.x + dir * math.max(clearance * 0.5, half_width * 0.20, 4), foot_y + lift, 0)
  local target = origin - vmath.vector3(0, max_step + 12, 0)
  local step_hit = physics.raycast(origin, target, ctx.ground_groups)
  if not (step_hit and step_hit.position and SurfaceClassifier.is_walkable_surface(step_hit.normal, ctx.max_slope_angle)) then
    return false
  end

  local desired_y = step_hit.position.y + half_height - (ctx.foot_floor_adjust or 0)
  -- Reject if the step surface is far to the side (prevents climbing through thin vertical walls)
  if math.abs(step_hit.position.x - self.pos.x) > (half_width * 1.1) then
    return false
  end
  local climb = desired_y - self.pos.y
  if math.abs(climb) > max_step then return false end

  local x_nudge = dir * math.max(clearance * 0.35, 0.5)
  local future_x = self.pos.x + x_nudge
  if not has_ground_support_span(self, future_x, desired_y, desired_y, 2, { -0.3, 0.0, 0.3 }) then
    dbg(self, "Rejecting step-up: insufficient support span future=(%.2f,%.2f) hit=(%.2f,%.2f)",
      future_x, desired_y, step_hit.position.x, step_hit.position.y)
    return false
  end

  -- Ease the climb to avoid teleporting up tall steps
  local per_frame = math.max(8, math.min(half_height * 0.22, 18))
  if climb > 0 then
    climb = math.min(climb, per_frame)
  end

  self.pos.y = self.pos.y + climb
  self.pos.x = future_x
  if (self.vy or 0) < 0 then self.vy = 0 end
  ctx.last_ground_y = self.pos.y
  ctx.last_ground_x = self.pos.x
  ctx.last_ground_normal = step_hit.normal
  return true
end

local function resolve_wall_climb_span_requirements(self)
  local wall_climb = self and self._cfg and self._cfg.wall_climb
  local min_tiles = tonumber(wall_climb and (wall_climb.min_wall_height_tiles or wall_climb.min_wall_tiles))
  if min_tiles == nil then
    min_tiles = DEFAULT_MIN_WALL_CLIMB_TILES
  end
  if min_tiles <= 0 then
    return 0, DEFAULT_TILE_HEIGHT
  end

  local tile_h = tonumber(TileSettings.height or TileSettings.tile_height) or DEFAULT_TILE_HEIGHT
  return min_tiles * tile_h, tile_h
end

local function probe_wall_face(ctx, dir, wall_x, sample_y)
  local probe_gap = math.max((ctx.wall_clearance or 6) + 2, 8)
  local probe_depth = math.max((ctx.wall_clearance or 6) + 6, 12)
  local origin = sv(9, wall_x - dir * probe_gap, sample_y, 0)
  local target = sv(10, wall_x + dir * probe_depth, sample_y, 0)
  local hit = physics.raycast(origin, target, ctx.wall_groups)
  if not hit then
    return nil, 0
  end

  local surface_kind = SurfaceClassifier.classify_collision(hit, ctx.max_slope_angle)
  if surface_kind == SurfaceClassifier.KINDS.GROUND then
    return nil, 0
  end

  return hit, SurfaceClassifier.wall_side_from_normal(hit.normal, dir)
end

--- Check whether the player's current wall contact is a ledge lip.
-- A lip has a climbable wall at the collider centre but no wall at the
-- existing +0.5 * half-height wall sample. Keeping this probe here makes the
-- hang state use the same groups, clearance and surface classification as the
-- normal wall solver.
-- @return is_lip, center_hit, top_hit, probe_available
function M.probe_ledge_lip(self, wall_side)
  local ctx = self and self._bone_physics
  local side = tonumber(wall_side) or 0
  if not ctx or side == 0 or not (physics and physics.raycast) then
    return false, nil, nil, false
  end

  side = (side < 0) and -1 or 1
  local half_width = self.collider_half_width or 30
  local half_height = self.collider_half_height or 60
  local wall_x = (self.pos and self.pos.x or go.get_position().x) + (side * half_width)
  local root_y = self.pos and self.pos.y or go.get_position().y

  local center_hit, center_side = probe_wall_face(ctx, side, wall_x, root_y)
  local top_hit, top_side = probe_wall_face(ctx, side, wall_x, root_y + (0.5 * half_height))
  local center_is_wall = center_hit ~= nil and center_side == side
  local top_is_wall = top_hit ~= nil and top_side == side
  return center_is_wall and not top_is_wall, center_hit, top_hit, true
end

local function ledge_raycast(origin, target, groups)
  if not (physics and physics.raycast) then
    return nil, false
  end
  local ok, hit = pcall(physics.raycast, origin, target, groups)
  if not ok then return nil, false end
  return hit, true
end

--- Find stable walkable support below an authored ledge-climb target.
-- The target Y is an upper search bound; the returned root position is snapped
-- to the actual surface so completion cannot fabricate a grounded state.
function M.probe_ledge_support(self, authored_target, hang_start, opts)
  opts = opts or {}
  local ctx = self and self._bone_physics
  if not (ctx and authored_target and hang_start) then
    return nil, "probe_unavailable"
  end

  local half_width = self.collider_half_width or 30
  local half_height = self.collider_half_height or 60
  local floor_adjust = ctx.foot_floor_adjust or 0
  local min_surface_y = tonumber(opts.min_surface_y)
    or (hang_start.y - (half_height * 0.5))
  local max_snap_up = tonumber(opts.max_snap_up) or 8
  local sample_offsets = opts.sample_offsets or { -0.35, 0, 0.35 }
  local candidates = {}

  for _, sample in ipairs(sample_offsets) do
    local sample_x = authored_target.x + (sample * half_width)
    local origin = vmath.vector3(sample_x, authored_target.y + 4, authored_target.z or 0)
    local target = vmath.vector3(sample_x, min_surface_y - 2, authored_target.z or 0)
    local hit, available = ledge_raycast(origin, target, ctx.ground_groups)
    if not available then return nil, "probe_unavailable" end
    if hit and hit.position
      and hit.position.y >= min_surface_y
      and SurfaceClassifier.is_ground_collision(hit, ctx.max_slope_angle)
    then
      local root_y = hit.position.y + half_height - floor_adjust
      if root_y <= authored_target.y + max_snap_up then
        candidates[#candidates + 1] = { hit = hit, root_y = root_y }
      end
    end
  end

  if #candidates == 0 then return nil, "no_support" end
  local best = candidates[1]
  for i = 2, #candidates do
    if candidates[i].root_y > best.root_y then best = candidates[i] end
  end

  local support_tolerance = tonumber(opts.support_tolerance) or math.max(4, half_height * 0.2)
  local support_count = 0
  for _, candidate in ipairs(candidates) do
    if math.abs(candidate.root_y - best.root_y) <= support_tolerance then
      support_count = support_count + 1
    end
  end
  if support_count < (tonumber(opts.min_support_hits) or 2) then
    return nil, "insufficient_support"
  end

  return {
    position = vmath.vector3(authored_target.x, best.root_y, authored_target.z or 0),
    collision = {
      grounded = true,
      ground_normal = best.hit.normal,
      ground_hit = best.hit.position,
      ground_group = best.hit.group,
      wall_contact = 0,
    },
    hit = best.hit,
    support_count = support_count,
  }
end

--- Sweep the player's collider between two kinematic ledge-climb positions.
-- Only leading/top faces are swept so the wall behind the hanging player does
-- not self-block; a destination interior check catches adjacent walls and
-- ceilings. Downward support snapping is intentionally handled separately.
function M.sweep_ledge_motion(self, from_pos, to_pos)
  local ctx = self and self._bone_physics
  if not (ctx and from_pos and to_pos) then return false, "probe_unavailable" end
  local groups = ctx.ceiling_groups or ctx.wall_groups
  if not groups then return false, "probe_unavailable" end

  local half_width = self.collider_half_width or 30
  local half_height = self.collider_half_height or 60
  -- Keep the sweep just inside the collider boundary. Sampling near the real
  -- face corners closes the gap left by proportional samples on tall/wide
  -- colliders, while the one-pixel skin keeps a supported floor from
  -- self-blocking the final destination check.
  local face_x_extent = math.max(1, half_width - 1)
  local face_y_extent = math.max(1, half_height - 1)
  local dx = (to_pos.x or 0) - (from_pos.x or 0)
  local dy = (to_pos.y or 0) - (from_pos.y or 0)
  local epsilon = 0.001

  local function cast_blocked(origin, target, reason)
    local hit, available = ledge_raycast(origin, target, groups)
    if not available then return true, "probe_unavailable" end
    if hit then return true, reason end
    return false
  end

  if math.abs(dx) > epsilon then
    local dir = dx < 0 and -1 or 1
    local face_x = from_pos.x + dir * face_x_extent
    for _, y_offset in ipairs({ -face_y_extent, 0, face_y_extent }) do
      local y = from_pos.y + y_offset
      local blocked, reason = cast_blocked(
        vmath.vector3(face_x, y, from_pos.z or 0),
        vmath.vector3(face_x + dx, y + dy, to_pos.z or 0),
        "wall_blocked")
      if blocked then return false, reason end
    end
  end

  if dy > epsilon then
    local face_y = from_pos.y + face_y_extent
    for _, x_offset in ipairs({ -face_x_extent, 0, face_x_extent }) do
      local x = from_pos.x + x_offset
      local blocked, reason = cast_blocked(
        vmath.vector3(x, face_y, from_pos.z or 0),
        vmath.vector3(x + dx, face_y + dy, to_pos.z or 0),
        "ceiling_blocked")
      if blocked then return false, reason end
    end
  end

  -- Destination interior: stay one pixel inside the collider so a
  -- supported foot touching the floor is not mistaken for penetration.
  for _, y_offset in ipairs({ -face_y_extent, 0, face_y_extent }) do
    local y = to_pos.y + y_offset
    local blocked, reason = cast_blocked(
      vmath.vector3(to_pos.x - face_x_extent, y, to_pos.z or 0),
      vmath.vector3(to_pos.x + face_x_extent, y, to_pos.z or 0),
      "destination_blocked")
    if blocked then return false, reason end
  end
  for _, x_offset in ipairs({ -face_x_extent, 0, face_x_extent }) do
    local x = to_pos.x + x_offset
    local blocked, reason = cast_blocked(
      vmath.vector3(x, to_pos.y - face_y_extent, to_pos.z or 0),
      vmath.vector3(x, to_pos.y + face_y_extent, to_pos.z or 0),
      "destination_blocked")
    if blocked then return false, reason end
  end

  return true
end

local function has_min_climbable_wall_height(self, dir, hit)
  local ctx = self._bone_physics
  if not (ctx and hit and hit.position) then
    return true, 0, 0
  end
  if not (self and self._cfg and self._cfg.wall_climb and self._cfg.wall_climb.enabled) then
    return true, 0, 0
  end

  local required_height, tile_h = resolve_wall_climb_span_requirements(self)
  if required_height <= 0 then
    return true, 0, required_height
  end

  local base_side = SurfaceClassifier.wall_side_from_normal(hit.normal, dir)
  if base_side == 0 then
    return false, 0, required_height
  end

  local sample_step = math.max(8, tile_h * 0.5)
  local max_steps = math.max(1, math.ceil(required_height / sample_step) + 2)
  local wall_x = hit.position.x
  local hit_count = 1

  for i = 1, max_steps do
    local sample_hit, sample_side = probe_wall_face(ctx, dir, wall_x, hit.position.y + (sample_step * i))
    if not sample_hit or sample_side ~= base_side then
      break
    end
    hit_count = hit_count + 1
  end

  for i = 1, max_steps do
    local sample_hit, sample_side = probe_wall_face(ctx, dir, wall_x, hit.position.y - (sample_step * i))
    if not sample_hit or sample_side ~= base_side then
      break
    end
    hit_count = hit_count + 1
  end

  local measured_height = hit_count * sample_step
  return measured_height >= required_height, measured_height, required_height
end

local function resolve_horizontal(self, prev_pos)
  local ctx = self._bone_physics
  local displacement = self.pos - prev_pos
  local dx = displacement.x
  -- Ladder exits validate their own landing; walking step-up must not move or
  -- ground a climber before that transition succeeds.
  local ladder_climbing = self._in_climb and not self._in_water
  
  -- Determine direction from velocity if not moving this frame
  local dir
  if dx == 0 then
    -- Check velocity to determine which way to check for walls
    if (self.vx or 0) > 0 then
      dir = 1
    elseif (self.vx or 0) < 0 then
      dir = -1
    elseif (self._wall_side or 0) ~= 0 then
      -- Wall-clinging zeroes vx, so dx and vx are both 0 here. Keep probing the
      -- known wall side; otherwise the wall "vanishes" the instant we stop, the
      -- cling drops, and the player creeps into the wall on each re-acquire.
      dir = self._wall_side
    elseif (self.facing or 0) ~= 0 then
      dir = self.facing
    else
      return 0, false  -- Not moving and no wall/facing reference
    end
  else
    dir = (dx > 0) and 1 or -1
  end

  local half_width = (self.collider_half_width or 30)
  local half_height = (self.collider_half_height or 60)
  -- Always check a minimum distance ahead for walls, even when standing still
  local min_ray_length = half_width + 32  -- Check at least 32 pixels beyond collider edge
  local ray_length = math.max(math.abs(dx) + half_width + (ctx.wall_clearance or 6), min_ray_length)
  local wall_side = 0
  local blocked = false
  local stepped_up = false
  local block_hit = nil

  -- Key insight: only treat a surface as a "wall" if it's ABOVE our foot level
  -- Anything at or below foot level is potential ground we can walk on
  local foot_y = self.pos.y - half_height
  local max_step = ctx.max_step_up or 140  -- How high can we step up (should match tile height)

  -- Use fewer samples for wall detection - skip lower samples that might hit stairs
  -- Sample at knee height and above to avoid treating stair steps as walls
  local wall_samples = ctx.wall_samples or DEFAULT_WALL_SAMPLES
  
  dbg(self, "H-CHECK: dx=%.2f dir=%d ray_len=%.1f samples=%d pos=(%.1f,%.1f) half_w=%.1f",
    dx, dir, ray_length, #wall_samples, self.pos.x, self.pos.y, half_width)
  
  for _, sample in ipairs(wall_samples) do
    local sample_y = self.pos.y + sample * half_height
    -- Cast from CENTER of collider (not edge) so we can detect walls even when overlapping
    -- Using scratch vectors sv(1)/sv(2) to avoid per-iteration allocations
    local origin = sv(1, self.pos.x, sample_y, 0)
    local target_x = self.pos.x + dir * (ray_length + half_width)
    local target = sv(2, target_x, sample_y, 0)
    local hit = physics.raycast(origin, target, ctx.wall_groups)

    if hit then
      dbg(self, "H-RAY HIT: sample=%.2f origin=(%.1f,%.1f) target=(%.1f,%.1f) hit_pos=(%.1f,%.1f) group=%s normal=(%.2f,%.2f)",
        sample, origin.x, origin.y, target.x, target.y, hit.position.x, hit.position.y, tostring(hit.group), 
        hit.normal and hit.normal.x or 0, hit.normal and hit.normal.y or 0)
    else
      dbg(self, "H-RAY: sample=%.2f origin=(%.1f,%.1f) target=(%.1f,%.1f) hit=NO",
        sample, origin.x, origin.y, target.x, target.y)
    end

    if hit then
      -- Check if this is actually a wall or a walkable slope/stair
      local normal = hit.normal
      local hit_height_above_feet = hit.position.y - foot_y
      
      local surface_kind = SurfaceClassifier.classify_collision(hit, ctx.max_slope_angle)
      local within_step_range = hit_height_above_feet <= max_step and hit_height_above_feet >= -10

      if surface_kind == SurfaceClassifier.KINDS.GROUND then
        -- Walkable slope surface (and not a wall) - don't block
        dbg(self, "Walkable slope (not blocking): sample=%.2f normal=(%.2f,%.2f)",
          sample, normal and normal.x or 0, normal and normal.y or 0)
        -- Continue checking other samples
      elseif not ladder_climbing and within_step_range and try_step_up(self, dir, hit, foot_y) then
        stepped_up = true
        dbg(self, "Stepped up over obstacle: sample=%.2f hit_height=%.1f group=%s", sample, hit_height_above_feet, tostring(hit.group))
        break
      else
        -- This is a blocking surface - too tall to step or not walkable.
        blocked = true
        block_hit = hit

        -- Only correct position if the player's collider edge is actually at or past the wall.
        -- Without this check, the proactive ray range (min_ray_length) would snap the player
        -- toward walls they haven't reached yet.
        local player_edge = self.pos.x + dir * half_width
        local penetration = (player_edge - hit.position.x) * dir  -- positive = overlapping wall
        local attach_slop = ctx.wall_attach_slop or 3
        -- Ladder centering must not attract the player to nearby wall faces.
        -- Otherwise each snap back toward the ladder selects the opposite face
        -- and oscillates between the two lips. Actual overlaps still block.
        local at_wall = penetration > (ladder_climbing and 0 or -attach_slop)
        if at_wall then
          -- Within attach range: snap flush so the player attaches cleanly in one
          -- frame instead of latching at a gap and creeping in over many frames.
          self.pos.x = hit.position.x - dir * (half_width + 0.25)
          if (self.vx or 0) * dir > 0 then
            self.vx = 0
          end
        end
        -- Only engage/report a wall contact (which starts the cling) once the
        -- collider edge is actually at the wall. The proactive ray reaches
        -- farther purely to block/zero velocity early; cling must not latch from
        -- a gap, or it freezes the player in mid-air short of the wall.
        if at_wall then
          wall_side = SurfaceClassifier.wall_side_from_normal(normal, dir)
        end
        if wall_side ~= 0 then
          local climbable, measured_height, required_height = has_min_climbable_wall_height(self, dir, hit)
          if not climbable then
            trace_climb(self, "wall_reject reason=min_height measured=%.1f required=%.1f hit=(%.1f,%.1f) side=%d group=%s",
              measured_height, required_height,
              hit.position.x, hit.position.y, wall_side, tostring(hit.group))
            dbg(self, "Wall contact rejected: measured_height=%.1f required=%.1f side=%d group=%s",
              measured_height, required_height, wall_side, tostring(hit.group))
            wall_side = 0
          end
        end
        local wall_reason = (surface_kind == SurfaceClassifier.KINDS.CEILING) and "ceiling_face" or "blocking_surface"
        trace_climb(self, "wall_block reason=%s sample=%.2f hit=(%.1f,%.1f) foot_y=%.1f normal=(%.2f,%.2f) side=%d group=%s",
          wall_reason, sample, hit.position.x, hit.position.y, foot_y,
          normal and normal.x or 0, normal and normal.y or 0, wall_side, tostring(hit.group))
        dbg(self, "Wall hit (%s): sample=%.2f hit_y=%.2f foot_y=%.2f normal=(%.2f,%.2f) side=%d group=%s",
          wall_reason, sample, hit.position.y, foot_y, normal and normal.x or 0, normal and normal.y or 0, wall_side, tostring(hit.group))
        break
      end
    end
  end

  return wall_side, stepped_up
end

local function ceiling_raycast(sample_x, origin_y, target_y, groups)
  return physics.raycast(
    sv(3, sample_x, origin_y, 0),
    sv(4, sample_x, target_y, 0),
    groups)
end

-- CeilingProbe reads these synchronously and does not retain the options.
local ceiling_options = {
  platform_group = PLATFORM,
  classify = SurfaceClassifier.is_ceiling_collision,
  raycast_fn = ceiling_raycast,
}

local function resolve_ceiling(self, prev_pos)
  local ctx = self._bone_physics
  ceiling_options.pos = self.pos
  ceiling_options.prev_pos = prev_pos
  ceiling_options.vy = self.vy
  ceiling_options.half_width = self.collider_half_width or 30
  ceiling_options.half_height = self.collider_half_height or 60
  ceiling_options.head_offset = ctx.head_offset
  ceiling_options.head_margin = ctx.head_margin
  ceiling_options.clearance = ctx.ceiling_clearance
  ceiling_options.groups = ctx.ceiling_groups
  ceiling_options.max_slope_angle = ctx.max_slope_angle
  local result = CeilingProbe.evaluate(ceiling_options)

  for _, accepted in ipairs(result.hits or {}) do
    local hit = accepted.hit
    trace_climb(self, "ceiling_hit group=%s hit=(%.1f,%.1f) ceiling_y=%.1f pos_y=%.1f prev_y=%.1f vy=%.1f",
      tostring(hit.group), hit.position.x, hit.position.y, accepted.ceiling_y,
      self.pos.y or 0, prev_pos and prev_pos.y or self.pos.y or 0, self.vy or 0)
  end
  if result.clamp_y ~= nil then
    self.pos.y = result.clamp_y
    if result.stop_upward_velocity then self.vy = 0 end
    trace_climb(self, "ceiling_clamp new_pos_y=%.1f", self.pos.y or 0)
  end
  -- NOTE: an upward carrier that keeps moving after this clamp can still
  -- squish the player against the ceiling; ongoing squish handling is separate.
  return result.clamp_y ~= nil
end

local function resolve_corner_correction(self, prev_pos, wall_side)
  local ctx = self._bone_physics
  if wall_side == 0 then return end  -- No wall collision, no corner issue
  -- Ladder movement/top-out owns this transition; walking corner nudges would
  -- fight centering and can undo the ladder's ground/ceiling bypass.
  if self._in_climb and not self._in_water then return end

  -- Check if we're still colliding with ceiling after wall collision
  local half_width = (self.collider_half_width or 30)
  local head_offset = ctx.head_offset or (self.collider_half_height or 60)
  local test_pos = self.pos + vmath.vector3(wall_side * half_width, head_offset, 0)
  
  -- Cast a short ray upward from near the head to check for ceiling
  local hit = physics.raycast(test_pos, test_pos + vmath.vector3(0, 16, 0), ctx.ceiling_groups)
  if hit then
    trace_climb(self, "corner_hit wall_side=%d ceiling_group=%s test=(%.1f,%.1f) hit=(%.1f,%.1f)",
      wall_side, tostring(hit.group), test_pos.x, test_pos.y,
      hit.position and hit.position.x or 0, hit.position and hit.position.y or 0)
    -- We're in a corner! Nudge downward to free the player
    local nudge_distance = 8  -- Small downward movement
    local new_y = self.pos.y - nudge_distance
    
    -- Make sure we don't nudge into ground
    local ground_check_origin = self.pos + vmath.vector3(0, -self.collider_half_height, 0)
    local ground_hit = physics.raycast(ground_check_origin, ground_check_origin - vmath.vector3(0, nudge_distance + 4, 0), ctx.ground_groups)
    
    if not ground_hit then
      self.pos.y = new_y
      trace_climb(self, "corner_nudge axis=y amount=%.1f new_y=%.1f", nudge_distance, new_y)
      dbg(self, "Corner correction applied: nudged down by %.1f to y=%.2f", nudge_distance, new_y)
    else
      -- Can't nudge down safely, try nudging away from wall instead
      local wall_nudge = wall_side * 4  -- Small horizontal nudge away from wall
      local new_x = self.pos.x + wall_nudge
      
      -- Check if horizontal nudge is safe
      local wall_check_origin = vmath.vector3(new_x, self.pos.y, 0) + vmath.vector3(wall_side * half_width, 0, 0)
      local wall_check_hit = physics.raycast(wall_check_origin, wall_check_origin + vmath.vector3(wall_side * 8, 0, 0), ctx.wall_groups)
      
      if not wall_check_hit then
        self.pos.x = new_x
        trace_climb(self, "corner_nudge axis=x amount=%.1f new_x=%.1f", wall_nudge, new_x)
        dbg(self, "Corner correction applied: nudged horizontally by %.1f to x=%.2f", wall_nudge, new_x)
      else
        trace_climb(self, "corner_blocked ground_group=%s wall_group=%s", tostring(ground_hit.group), tostring(wall_check_hit.group))
      end
    end
  end
end

local function resolve_ground(self, prev_pos)
  local ctx = self._bone_physics
  local half_height = (self.collider_half_height or 60)
  local half_width = (self.collider_half_width or 30)
  local snap_eps = ctx.snap_epsilon or 1.0
  local fallback_max = ctx.fallback_max or 1024
  ctx.missed_ground_frames = ctx.missed_ground_frames or 0
  local vy = self.vy or 0
  local vx = self.vx or 0
  local was_grounded = self.grounded and true or false
  local max_snap_up = ctx.max_snap_up or 140
  local landing_snap_distance = ctx.landing_snap_distance or 0
  local ignore_platform = (self._platform_drop_t or 0) > 0 or (vy > 0.1)
  local ground_group = nil

  local function filter_hit(hit)
    if not hit then return nil end
    if ignore_platform and hit.group == PLATFORM then
      return nil
    end
    if not SurfaceClassifier.is_ground_collision(hit, ctx.max_slope_angle) then
      return nil
    end
    return hit
  end

  -- When standing still, tiny variations in raycast hit positions can cause visible "ground jitter"
  -- (especially when the camera snaps to pixels). Stick to the last stable grounded Y within a small epsilon.
  local function stabilize_ground_y()
    local moved_x = math.abs((self.pos.x or 0) - ((prev_pos and prev_pos.x) or (self.pos.x or 0)))
    local moving_h = (math.abs(self.vx or 0) > 10) or (moved_x > 0.1)
    local platform_dy = math.abs(self._platform_delta_y or 0)
    local platform_moving = platform_dy > 0.01
    if moving_h or platform_moving then
      ctx.stable_ground_y = self.pos.y
      return
    end
    if ctx.stable_ground_y == nil then
      ctx.stable_ground_y = self.pos.y
      return
    end
    if math.abs((self.pos.y or 0) - (ctx.stable_ground_y or 0)) <= snap_eps then
      self.pos.y = ctx.stable_ground_y
    else
      ctx.stable_ground_y = self.pos.y
    end
  end

  local best_ground_y, best_normal, best_hit
  local pos_y = self.pos.y
  local adjust = ctx.foot_floor_adjust or 0

  local function consider_ground_hit(hit, candidate_root)
    if not hit then
      return
    end
    candidate_root = candidate_root + slope_lift_offset(hit.normal, ctx)
    if not best_ground_y or candidate_root > best_ground_y then
      best_ground_y = candidate_root
      best_normal = hit.normal
      best_hit = hit
      ground_group = hit.group or ground_group
    end
  end

  if ctx.use_bone_feet and ctx.offsets then
    local lift = ctx.foot_probe_lift or 12
    local extend = (ctx.ground_check or 64) + lift + math.max(0, -vy) * (ctx.descend_probe_mul or 0.03)
    for _, name in ipairs(ctx.feet) do
      local offset = ctx.offsets[name]
      if offset then
        local foot_pos = BoneCollision.get_bone_position(ctx.spine_url, name)
        if foot_pos then
          local origin = foot_pos + vmath.vector3(0, lift, 0)
          local hit = filter_hit(physics.raycast(origin, origin - vmath.vector3(0, extend, 0), ctx.ground_groups))
          if hit then
            local candidate_root = hit.position.y + offset - adjust
            consider_ground_hit(hit, candidate_root)
          end
        end
      end
    end
  end

  if not best_ground_y then
    local lift = ctx.foot_probe_lift or 12
    local extend = (ctx.ground_check or 64) + lift + math.max(0, -vy) * (ctx.descend_probe_mul or 0.03)
    local foot_base_y = pos_y - half_height + adjust
    local samples = ctx.foot_samples or DEFAULT_COLLIDER_FOOT_SAMPLES
    for _, sample in ipairs(samples) do
      local sample_x = self.pos.x + (sample * half_width)
      local origin = sv(7, sample_x, foot_base_y + lift, 0)
      local target = sv(8, sample_x, (foot_base_y + lift) - extend, 0)
      local hit = filter_hit(physics.raycast(origin, target, ctx.ground_groups))
      if hit then
        local candidate_root = hit.position.y + half_height - adjust
        consider_ground_hit(hit, candidate_root)
      end
    end
  end

  if best_ground_y then
    local delta = best_ground_y - self.pos.y
    local max_snap_up = ctx.max_snap_up or 132
    local max_step_down = ctx.max_step_down or (half_height * 3)
    local surface_y = best_hit and best_hit.position and best_hit.position.y or (best_ground_y - half_height + adjust)
    local bottom_y = self.pos.y - half_height + adjust
    -- Calculate required snap based on horizontal movement to handle slopes properly
    -- For steep slopes, we need to snap up proportional to horizontal movement
    local moved_x = math.abs(self.pos.x - prev_pos.x)
    local trying_to_move = math.abs(self.vx or 0) > 10

    -- Base step for gentle slopes or standing still
    local base_step = math.max(16, math.min(half_height * 0.35, 64))

    -- For slopes: allow snapping proportional to horizontal movement
    -- A 45-degree slope needs 1:1 ratio, steeper slopes need more
    -- Use 2.5x multiplier to handle steep slopes (tiles arranged diagonally)
    local slope_snap = moved_x * 2.5
    local max_allowed_snap = math.max(base_step, math.min(slope_snap, max_snap_up))
    local can_land_from_air = (vy <= 0) and (bottom_y <= surface_y + landing_snap_distance)
    -- Ground following must not undo upward jump or rope motion. A taut swing
    -- can start with a tiny rise while last frame still reported floor support.
    local can_step_down_while_grounded = was_grounded and vy <= 0
      and delta < 0 and ((-delta) <= base_step)

    if delta > 0 then
      if moved_x > 0.1 or trying_to_move then
        -- Moving: use slope-aware incremental snap
        local eased = math.min(delta, max_allowed_snap)
        self.pos.y = self.pos.y + eased
        delta = eased
      else
        -- Standing still: snap directly to ground to prevent slow fall
        self.pos.y = best_ground_y
        delta = 0
      end
    end
    local allow_downward_snap = delta >= 0 or can_land_from_air or can_step_down_while_grounded
    if delta <= max_snap_up and delta >= -max_step_down and allow_downward_snap then
      if delta < 0 then
        self.pos.y = self.pos.y + delta
      end
      if vy < 0 then self.vy = 0 end
      dbg(self, "Grounded via feet ray: ground=%.2f pos=%.2f delta=%.2f", best_ground_y, self.pos.y, delta)
      stabilize_ground_y()
      ctx.missed_ground_frames = 0
      ctx.last_ground_y = self.pos.y
      ctx.last_ground_x = self.pos.x
      ctx.last_ground_normal = best_normal
      ground_group = ground_group or (best_hit and best_hit.group)
      ctx.last_ground_group = ground_group
      return true, best_normal, best_hit and best_hit.position or nil, ground_group
    end
  end

  -- Fallback: cast from center (stair lookahead already handled above)
  local prev_root = prev_pos or self.pos
  local distance = half_height + (ctx.ground_check or 64) + math.abs(self.pos.y - prev_root.y) + math.max(0, -vy) * (ctx.descend_probe_mul or 0.03)
  distance = math.min(distance, fallback_max)
  
  local best_fallback_y = nil
  local best_fallback_normal = nil
  local best_fallback_hit = nil
  
  local origin = sv(5, self.pos.x, prev_root.y + half_height, 0)
  local target_down = sv(6, self.pos.x, prev_root.y + half_height - distance, 0)
  local hit = filter_hit(physics.raycast(origin, target_down, ctx.ground_groups))

  if hit then
    local ground_y = hit.position.y + half_height - (ctx.foot_floor_adjust or 0)
    ground_y = ground_y + slope_lift_offset(hit.normal, ctx)
    best_fallback_y = ground_y
    best_fallback_normal = hit.normal
    best_fallback_hit = hit
    ground_group = ground_group or hit.group
  end
  
  if best_fallback_hit then
    local bottom_y = self.pos.y - half_height + (ctx.foot_floor_adjust or 0)
    local ground_y = best_fallback_y
    local max_snap_up = ctx.max_snap_up or 132
    local delta = ground_y - self.pos.y

    -- Allow snapping up to slopes/stairs even when moving horizontally
    local moved_x = math.abs(self.pos.x - prev_pos.x)
    local base_step = math.max(16, math.min(half_height * 0.35, 64))
    local trying_to_move = math.abs(vx) > 10
    if (bottom_y <= best_fallback_hit.position.y + landing_snap_distance and vy <= 0) or
       (was_grounded and vy <= 0 and delta < 0 and (-delta) <= base_step) or
       (delta > 0 and delta <= max_snap_up and trying_to_move) then

      -- Apply same slope-aware snapping logic to fallback ray
      -- Allow snapping proportional to horizontal movement for slopes
      local slope_snap = moved_x * 2.5
      local max_allowed_snap = math.max(base_step, math.min(slope_snap, max_snap_up))

      if delta > 0 then
        if moved_x > 0.1 or trying_to_move then
          -- Moving: use slope-aware incremental snap
          local eased = math.min(delta, max_allowed_snap)
          self.pos.y = self.pos.y + eased
        else
          -- Standing still: snap directly to ground to prevent slow fall
          self.pos.y = ground_y
        end
      elseif delta < 0 then
        self.pos.y = ground_y
      end

      if vy < 0 then
        self.vy = 0
      end
      dbg(self, "Grounded via fallback ray: ground=%.2f pos=%.2f normal=(%.2f,%.2f) delta=%.2f",
        ground_y, self.pos.y, best_fallback_normal and best_fallback_normal.x or 0, best_fallback_normal and best_fallback_normal.y or 0, delta)
      stabilize_ground_y()
      ctx.missed_ground_frames = 0
      ctx.last_ground_y = self.pos.y
      ctx.last_ground_x = self.pos.x
      ctx.last_ground_normal = best_fallback_normal
      ctx.last_ground_group = ground_group
      return true, best_fallback_normal, best_fallback_hit.position, ground_group
    end
  end
  ctx.missed_ground_frames = math.min((ctx.missed_ground_frames or 0) + 1, 30)

  -- Bridge brief raycast misses with a cached ground plane to avoid oscillation/jitter.
  local near_cached_y = ctx.last_ground_y and math.abs((self.pos.y or 0) - ctx.last_ground_y) <= (snap_eps + 2.0)
  -- Do not reuse cached ground when moving upward; only allow during descent/idle
  local shallow_fall = vy <= 0 and vy > -280
  local allow_cached = ctx.last_ground_y and near_cached_y and shallow_fall and (ctx.missed_ground_frames or 0) <= 3

  if allow_cached and not (ignore_platform and ctx.last_ground_group == PLATFORM) then
    self.pos.y = ctx.last_ground_y
    self.vy = math.min(self.vy or 0, 0)
    stabilize_ground_y()
    dbg(self, "Grounded via cached plane: pos=%.2f (missed=%d)", self.pos.y, ctx.missed_ground_frames)
    return true, ctx.last_ground_normal, nil, ctx.last_ground_group
  end

  dbg(self, "No ground detected: pos=(%.2f,%.2f) vy=%.2f", self.pos.x, self.pos.y, vy)
  return false, nil, nil, nil
end

function M.resolve(self, prev_pos)
  local ctx = self._bone_physics
  if not ctx or not ctx.spine_url then
    go.set_position(self.pos)
    return { grounded = self.grounded and true or false, ceiling_contact = false }
  end

  ensure_offsets(self)

  -- Check for bypass_ground_frames - used by crumble platform to prevent
  -- physics from pushing player back onto baked tilemap collision
  local bypass_ground = (self.bypass_ground_frames or 0) > 0
  if bypass_ground then
    self.bypass_ground_frames = self.bypass_ground_frames - 1
    trace_climb(self, "bypass_ground active remaining=%d", self.bypass_ground_frames or 0)
  end
  local bypass_ceiling = (self.bypass_ceiling_frames or 0) > 0
  if bypass_ceiling then
    self.bypass_ceiling_frames = self.bypass_ceiling_frames - 1
    trace_climb(self, "bypass_ceiling active remaining=%d", self.bypass_ceiling_frames or 0)
  end

  -- Slope pre-projection: when grounded and moving horizontally on a slope,
  -- lift Y proportionally to horizontal displacement so the player stays on the
  -- surface instead of tunnelling into it.  Box2D raycasts that start inside a
  -- collision shape will miss it, so we must prevent penetration up-front.
  if self.grounded and ctx.last_ground_normal then
    local nx = ctx.last_ground_normal.x or 0
    local ny = ctx.last_ground_normal.y or 1
    if ny > 0.01 and ny < 0.999 then
      local dx = (self.pos.x or 0) - (prev_pos and prev_pos.x or self.pos.x)
      -- slope_y_per_x = -nx/ny: Y change per unit of X to stay on the surface
      local lift = dx * (-nx / ny)
      self.pos.y = self.pos.y + lift
    end
  end

  -- Resolve horizontal collisions before ground snapping so shared "solid" walls
  -- cannot be mistaken for floor while the player is still overlapping them.
  local wall_side, stepped_up = resolve_horizontal(self, prev_pos)
  if self and (self._in_climb or bypass_ceiling) then
    trace_climb(self, "resolve_horizontal wall_side=%s stepped_up=%s pos=(%.1f,%.1f) prev=(%.1f,%.1f)",
      tostring(wall_side), tostring(stepped_up),
      self.pos.x or 0, self.pos.y or 0, prev_pos and prev_pos.x or 0, prev_pos and prev_pos.y or 0)
  end

  -- Then resolve ground using the horizontally-corrected position.
  local grounded, normal, hit_pos, ground_group
  if bypass_ground then
    -- Skip ground resolution entirely - let player fall through
    grounded = false
    normal = nil
    hit_pos = nil
    ground_group = nil
  else
    grounded, normal, hit_pos, ground_group = resolve_ground(self, prev_pos)
  end
  if self and (self._in_climb or bypass_ceiling) then
    trace_climb(self, "resolve_ground grounded=%s ground_group=%s pos=(%.1f,%.1f)",
      tostring(grounded), tostring(ground_group), self.pos.x or 0, self.pos.y or 0)
  end

  if grounded then
    ctx.no_ground_frames = 0
  else
    ctx.no_ground_frames = (ctx.no_ground_frames or 0) + 1
  end

  -- If we stepped up during horizontal resolution, we are definitely grounded
  if stepped_up then
    grounded = true
    ground_group = ground_group or ctx.last_ground_group
    -- We might want to update normal/hit_pos here if we had access to them from try_step_up
    -- For now, just ensuring grounded=true is enough to fix the animation
  end
  do
    local ctx = self._bone_physics
    if grounded and (not normal) and ctx and ctx.last_ground_normal then
      normal = ctx.last_ground_normal
    end
  end

  local ceiling_contact = false
  if not bypass_ceiling then
    ceiling_contact = resolve_ceiling(self, prev_pos)
  end
  resolve_corner_correction(self, prev_pos, wall_side)

  go.set_position(self.pos)

  return {
    grounded = grounded,
    ground_normal = normal,
    ground_hit = hit_pos,
    ground_group = ground_group,
    wall_contact = wall_side,
    ceiling_contact = ceiling_contact,
  }
end

return M

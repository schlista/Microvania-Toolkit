-- mvtk/enemies/patterns/attack_patterns.lua
-- Enemy attack pattern helpers and behaviours

local C = require "mvtk.core.constants"
local Geometry = require "mvtk.combat.attack_geometry"

local M = {}

local function play_attack_anim(self, state)
  if self and self.play_attack_animation then
    pcall(self.play_attack_animation, self, state or "attack")
  end
end

local function positive_number(value, fallback)
  local n = tonumber(value)
  if n and n > 0 then
    return n
  end
  return fallback
end

local function nonnegative_number(value, fallback)
  local n = tonumber(value)
  if n and n >= 0 then
    return n
  end
  return fallback
end

local function shoot_cooldown(self, fallback)
  return positive_number(self and self.shoot_cooldown, fallback)
end

local function projectile_speed(self, fallback)
  return positive_number(self and self.projectile_speed, fallback)
end

local function enemy_tuning(self, ...)
  local config = self and self.enemy_type_config
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    local value = positive_number(self and self[key], nil)
    if value then
      return value
    end
    value = positive_number(config and config[key], nil)
    if value then
      return value
    end
  end
  return nil
end

local function enemy_nonnegative_tuning(self, ...)
  local config = self and self.enemy_type_config
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    local value = nonnegative_number(self and self[key], nil)
    if value ~= nil then
      return value
    end
    value = nonnegative_number(config and config[key], nil)
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function speed_multiplier(self)
  local instance_mult = positive_number(self and self._speed_mult, 1.0)
  local elite_mult = positive_number(self and self._elite_speed_mult, 1.0)
  return instance_mult * elite_mult
end

local function movement_speed(self, fallback)
  return positive_number(self and self.speed, fallback or 80) * speed_multiplier(self)
end

-- Chase speed has one consistent contract across ground, flying, and ghost
-- movement: authored absolute chase speed (or base movement speed) multiplied
-- by chase_speed_mult and the per-instance speed_mult.
local function effective_chase_speed(self, fallback)
  local config = self and self.enemy_type_config
  local absolute = positive_number(self and self.chase_speed, nil)
    or positive_number(config and config.chase_speed, nil)
    or positive_number(self and self.speed, fallback or 100)
  local chase_mult = positive_number(self and self._chase_speed_mult, nil)
    or positive_number(config and config.chase_speed_mult, 1.0)
  return absolute * chase_mult * speed_multiplier(self)
end

local function scaled_movement_tuning(self, ...)
  local value = enemy_tuning(self, ...)
  return value and (value * speed_multiplier(self)) or nil
end

local function target_within_detection(self, target)
  if not target then return false end
  local detection_range = enemy_tuning(self, "attack_detection_range")
    or positive_number(self and self._detection_range, nil)
    or enemy_tuning(self, "detection_range")
  return not detection_range or Geometry.distance_2d(self.pos, target) <= detection_range
end

local function face_direction(self, direction)
  local x
  if type(direction) == "number" then
    x = direction
  else
    x = tonumber(direction and direction.x) or 0
  end
  if x == 0 then return end
  self.facing = x > 0 and 1 or -1
  pcall(sprite.set_hflip, "#sprite", self.facing < 0)
end

local function player_position()
  local player_url = C.URL and C.URL.PLAYER
  if not player_url then
    return nil
  end
  local ok, pos = pcall(go.get_position, player_url)
  if ok then
    return pos
  end
  return nil
end

function M.idle()
  return { update = function(self, dt) end }
end

function M.patrol_horizontal()
  local dir = 1
  return {
    update = function(self, dt)
      if self._ledge_blocked_dir == dir then dir = -dir end
      local patrol_distance = self.patrol_distance or self.patrol_width
      local span = patrol_distance and patrol_distance * 0.5 or self.patrol_width or 64
      self.vel.x = dir * movement_speed(self, 80)
      if self.pos.x > self.start_pos.x + span then dir = -1 elseif self.pos.x < self.start_pos.x - span then dir = 1 end
    end
  }
end

function M.patrol_vertical()
  local dir = 1
  return {
    update = function(self, dt)
      local height = self.hover_height or self.patrol_height or 48
      self.vel.y = dir * movement_speed(self, 80)
      if self.pos.y > self.start_pos.y + height then dir = -1 elseif self.pos.y < self.start_pos.y - height then dir = 1 end
    end
  }
end

local function update_chase(self, grounded)
  local target = player_position()
  if not target then
    self.vel.x = 0
    self.vel.y = 0
    return
  end
  local len = Geometry.distance_2d(self.pos, target)
  local detection_range = self._detection_range or math.huge
  if len > 0 and len <= detection_range then
    local chase_speed = effective_chase_speed(self, 100)
    if grounded then
      local dx = target.x - self.pos.x
      self.vel.x = dx == 0 and 0 or (dx > 0 and chase_speed or -chase_speed)
      self.vel.y = 0
    else
      local aim = Geometry.aim_vector(self.pos, target)
      self.vel.x = aim.x * chase_speed
      self.vel.y = aim.y * chase_speed
    end
  else
    self.vel.x = 0
    self.vel.y = 0
  end
end

function M.chase_ground()
  return {
    update = function(self, dt)
      update_chase(self, true)
    end
  }
end

function M.chase_flying()
  return {
    update = function(self, dt)
      update_chase(self, false)
    end
  }
end

-- Direct legacy pattern id. New resolution chooses an explicit ground/flying
-- variant, while pattern1 and old scripts retain their historical contract.
function M.chase_player()
  return {
    update = function(self, dt)
      update_chase(self, self._grounded_movement == true)
    end
  }
end

function M.ground_patrol_chase()
  local state = "patrol"
  local patrol_dir = 1

  local function set_state(self, next_state)
    state = next_state
    self._simple_movement_state = next_state
  end

  return {
    update = function(self, dt)
      local target = player_position()
      local detection_range = self._detection_range or 200
      local disengage_range = enemy_tuning(self, "disengage_range", "return_range")
        or (detection_range * 1.25)
      local distance = target and Geometry.distance_2d(self.pos, target) or math.huge

      if target and distance <= detection_range then
        set_state(self, "chase")
      elseif state == "chase" and distance > disengage_range then
        set_state(self, "return")
      end

      if state == "chase" then
        local dx = (target.x or 0) - (self.pos.x or 0)
        local speed = effective_chase_speed(self, 100)
        self.vel.x = dx == 0 and 0 or (dx > 0 and speed or -speed)
        self.vel.y = 0
        return
      end

      local patrol_distance = self.patrol_distance or self.patrol_width
      local span = patrol_distance and patrol_distance * 0.5 or self.patrol_width or 64
      local start_x = (self.start_pos and self.start_pos.x) or self.pos.x

      if state == "return" then
        local dx = start_x - (self.pos.x or 0)
        if math.abs(dx) <= 2 then
          set_state(self, "patrol")
          patrol_dir = patrol_dir < 0 and -1 or 1
        else
          local return_dir = dx > 0 and 1 or -1
          if self._ledge_blocked_dir == return_dir then
            set_state(self, "patrol")
            patrol_dir = -return_dir
          else
            self.vel.x = return_dir * movement_speed(self, 80)
            self.vel.y = 0
            return
          end
        end
      end

      if self._ledge_blocked_dir == patrol_dir then patrol_dir = -patrol_dir end
      self.vel.x = patrol_dir * movement_speed(self, 80)
      self.vel.y = 0
      if self.pos.x > start_x + span then
        patrol_dir = -1
      elseif self.pos.x < start_x - span then
        patrol_dir = 1
      end
      self._simple_movement_state = "patrol"
    end,
  }
end

function M.ghost_float()
  local patrol_dir = 1
  local triggered = false
  return {
    update = function(self, dt)
      local detection_range = self._detection_range or 200
      local speed = movement_speed(self, 80)

      -- Check player distance
      local target = player_position()
      local player_dist = math.huge
      if target then
        player_dist = Geometry.distance_2d(self.pos, target)
      end

      -- Once triggered, chase permanently within the room
      if not triggered and player_dist <= detection_range then
        triggered = true
      end

      if triggered and target then
        -- Chase: float toward player
        if player_dist > 0 then
          local aim = Geometry.aim_vector(self.pos, target)
          local chase_speed = effective_chase_speed(self, 80)
          self.vel.x = aim.x * chase_speed
          self.vel.y = aim.y * chase_speed
        else
          self.vel.x = 0
          self.vel.y = 0
        end

        -- Close players make the ghost evade toward a bounded height above
        -- them. Clamp the last step so the rise cannot overshoot its target;
        -- once it is there, stop adding upward velocity instead of climbing
        -- forever toward the room ceiling.
        local rise_range = enemy_tuning(self, "rise_range", "evade_range") or 72
        if player_dist <= rise_range then
          local rise_height = enemy_tuning(self, "rise_height", "evade_height") or 64
          local rise_speed = scaled_movement_tuning(self, "rise_speed", "evade_speed")
            or math.max(24, speed * 0.75)
          local desired_y = (target.y or 0) + rise_height
          local rise_delta = desired_y - (self.pos.y or 0)
          if rise_delta > 1 then
            local safe_dt = math.max(tonumber(dt) or 0, 0.000001)
            self.vel.y = math.min(rise_speed, rise_delta / safe_dt)
          elseif math.abs(rise_delta) <= 1 then
            self.vel.y = 0
          end
        end
      else
        -- Patrol: horizontal float with gentle sine bob
        local span = self.patrol_width or 64
        self.vel.x = patrol_dir * speed * 0.6
        self.vel.y = math.sin((self.pos.x - self.start_pos.x) * 0.04) * speed * 0.3

        if self.pos.x > self.start_pos.x + span then
          patrol_dir = -1
        elseif self.pos.x < self.start_pos.x - span then
          patrol_dir = 1
        end
      end

      -- Face direction of movement
      if self.vel.x ~= 0 then
        self.facing = self.vel.x > 0 and 1 or -1
        pcall(sprite.set_hflip, "#sprite", self.facing < 0)
      end
    end
  }
end

function M.swoop_attack()
  local timer_epsilon = 0.000001
  local state = "waiting"
  local swoop_dir = vmath.vector3(1, 0, 0)
  local swoop_speed = 0
  local swoop_remaining = 0
  local dart_dir = 1
  local dart_speed = 0
  local dart_interval = 0
  local dart_remaining = 0
  local dart_vertical_speed = 0

  local function apply_swoop_velocity(self)
    self.vel.x = swoop_dir.x * swoop_speed
    self.vel.y = swoop_dir.y * swoop_speed
    face_direction(self, swoop_dir)
  end

  local function apply_dart_velocity(self, target)
    self.vel.x = dart_dir * dart_speed
    if target then
      local dy = (target.y or 0) - (self.pos.y or 0)
      self.vel.y = math.max(-dart_vertical_speed, math.min(dart_vertical_speed, dy))
    else
      self.vel.y = 0
    end
    face_direction(self, dart_dir)
  end

  return {
    update = function(self, dt)
      dt = math.max(0, tonumber(dt) or 0)

      if state == "waiting" then
        self.vel.x = 0
        self.vel.y = 0

        local target = player_position()
        if not target then return end
        local detection_range = enemy_tuning(self, "swoop_detection_range")
          or self._detection_range
          or enemy_tuning(self, "detection_range")
          or 220
        if Geometry.distance_2d(self.pos, target) > detection_range then
          return
        end

        -- Lock the opening dive to the player's position at detection. After
        -- this one 2D swoop, the bat stays awake and darts until it dies.
        swoop_dir = Geometry.aim_vector(self.pos, target)
        swoop_speed = scaled_movement_tuning(self, "swoop_speed", "charge_speed")
          or (movement_speed(self, 80) * 2.5)
        local swoop_duration = enemy_tuning(self, "swoop_duration", "charge_duration") or 0.55
        dart_speed = scaled_movement_tuning(self, "dart_speed") or (movement_speed(self, 80) * 1.5)
        dart_interval = enemy_tuning(self, "dart_interval") or 0.85
        dart_vertical_speed = scaled_movement_tuning(self, "dart_vertical_speed")
          or (movement_speed(self, 80) * 0.6)
        dart_dir = swoop_dir.x < 0 and -1 or 1

        state = "swoop"
        play_attack_anim(self, "attack")
        apply_swoop_velocity(self)
        -- The triggering frame already moves along the locked dive vector.
        swoop_remaining = math.max(0, swoop_duration - dt)
        if swoop_remaining <= timer_epsilon then
          state = "dart"
          dart_remaining = dart_interval
        end
        return
      end

      if state == "swoop" then
        apply_swoop_velocity(self)
        swoop_remaining = swoop_remaining - dt
        if swoop_remaining <= timer_epsilon then
          state = "dart"
          dart_remaining = dart_interval
        end
        return
      end

      -- Darts never pause or return to the perch. Reverse horizontal travel on
      -- the configured interval and gently track the player's current height.
      dart_remaining = dart_remaining - dt
      while dart_remaining <= timer_epsilon do
        dart_dir = -dart_dir
        face_direction(self, dart_dir)
        play_attack_anim(self, "attack")
        dart_remaining = dart_interval + dart_remaining
      end
      apply_dart_velocity(self, player_position())
    end,
  }
end

function M.melee_swipe()
  local timer_epsilon = 0.000001
  local cooldown = 0
  local windup = 0
  local swiping = false
  local swipe_dir = 1
  local swipe_range = 72
  local swipe_height = 56
  local swipe_cooldown = 1.4

  local function target_in_front(self, target)
    local center = vmath.vector3(
      (self.pos.x or 0) + swipe_dir * swipe_range * 0.5,
      self.pos.y or 0,
      self.pos.z or 0
    )
    return Geometry.point_in_box(center, swipe_range * 0.5, swipe_height, target)
  end

  local function finish_swipe(self)
    swiping = false
    local target = player_position()
    if target and target_in_front(self, target) and type(self.strike_player) == "function" then
      self.strike_player(self, {
        direction = swipe_dir,
        damage = enemy_tuning(self, "swipe_damage", "attack_damage", "damage")
          or positive_number(self.contact_damage, 1),
        knockback = enemy_tuning(self, "swipe_knockback", "knockback_force")
          or positive_number(self.contact_knockback_px, 180),
        knockback_y = enemy_nonnegative_tuning(self, "swipe_knockback_y", "attack_knockback_y") or 80,
        stun_t = enemy_nonnegative_tuning(self, "swipe_stun_t", "attack_stun_t") or 0.1,
        damage_type = "physical",
        source_attack = "melee_swipe",
      })
    end
    cooldown = swipe_cooldown
  end

  return {
    update = function(self, dt)
      dt = math.max(0, tonumber(dt) or 0)

      if swiping then
        -- Movement patterns execute first, so explicitly plant the mummy for
        -- every windup frame before delivering exactly one strike callback.
        self.vel.x = 0
        self.vel.y = 0
        windup = windup - dt
        if windup <= timer_epsilon then
          finish_swipe(self)
        end
        return
      end

      if cooldown > 0 then
        cooldown = math.max(0, cooldown - dt)
        return
      end

      local target = player_position()
      if not target then return end

      swipe_range = enemy_tuning(self, "swipe_range", "attack_range", "melee_range") or 72
      swipe_height = enemy_tuning(self, "swipe_height", "attack_height", "melee_height") or 56
      local dx = (target.x or 0) - (self.pos.x or 0)
      local dy = math.abs((target.y or 0) - (self.pos.y or 0))
      if math.abs(dx) > swipe_range or dy > swipe_height then
        return
      end

      swipe_dir = dx < 0 and -1 or 1
      face_direction(self, swipe_dir)
      swipe_cooldown = enemy_nonnegative_tuning(self, "swipe_cooldown", "attack_cooldown")
      if swipe_cooldown == nil then swipe_cooldown = 1.4 end
      windup = enemy_nonnegative_tuning(self, "swipe_windup", "attack_windup")
      if windup == nil then windup = 0.25 end
      -- The triggering update is already a planted windup frame.
      windup = math.max(0, windup - dt)
      swiping = true
      self.vel.x = 0
      self.vel.y = 0
      play_attack_anim(self, "attack")

      if windup <= timer_epsilon then
        finish_swipe(self)
      end
    end,
  }
end

function M.flee_player()
  return {
    update = function(self, dt)
      local target = player_position()
      if target then
        local len = Geometry.distance_2d(target, self.pos)
        if len > 0 then
          local away = Geometry.aim_vector(target, self.pos)
          local speed = movement_speed(self, 100)
          self.vel.x = away.x * speed
          self.vel.y = away.y * speed
        end
      end
    end
  }
end

function M.shoot_straight()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local dir = 1
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = shoot_cooldown(self, 1.0)
          return
        end
        if target.x < self.pos.x then dir = -1 end
        self.spawn_projectile(self, dir, projectile_speed(self, 300))
        cd = shoot_cooldown(self, 1.0)
      end
    end
  }
end

function M.shoot_spread()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = shoot_cooldown(self, 1.2)
          return
        end
        for _, angle in ipairs(Geometry.compute_spread_angles(3, math.deg(0.4), 0)) do
          self.spawn_projectile(self, math.cos(angle) >= 0 and 1 or -1, projectile_speed(self, 300))
        end
        cd = shoot_cooldown(self, 1.2)
      end
    end
  }
end

function M.shoot_burst()
  local cd, shots = 0, 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = shoot_cooldown(self, 2.0)
          return
        end
        self.spawn_projectile(self, 1, projectile_speed(self, 300))
        shots = shots + 1
        if shots >= 5 then
          cd = shoot_cooldown(self, 2.0)
          shots = 0
        else
          cd = 0.1
        end
      end
    end
  }
end

function M.shoot_circle()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = shoot_cooldown(self, 3.0)
          return
        end
        for i=0,7 do
          local angle = i * math.pi * 0.25
          local dir = vmath.vector3(math.cos(angle), math.sin(angle), 0)
          self.spawn_projectile(self, dir, projectile_speed(self, 300))
        end
        cd = shoot_cooldown(self, 3.0)
      end
    end
  }
end

function M.shoot_random()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = shoot_cooldown(self, 0.8)
          return
        end
        local dir = (math.random()<0.5) and -1 or 1
        self.spawn_projectile(self, dir, projectile_speed(self, 300))
        cd = shoot_cooldown(self, 0.8)
      end
    end
  }
end

function M.dash_attack()
  local timer_epsilon = 0.000001
  local cooldown = 0
  local dash_time = 0
  local dash_dir = 1
  local dash_speed = 0
  return {
    update = function(self, dt)
      dt = math.max(0, tonumber(dt) or 0)
      cooldown = cooldown - dt
      if cooldown <= timer_epsilon then cooldown = 0 end

      -- Movement patterns run before attack patterns and may replace velocity
      -- every frame. Reapply the locked dash vector for its full duration.
      if dash_time > 0 then
        self.vel.x = dash_dir * dash_speed
        if self._grounded_movement then
          self.vel.y = 0
        end
        dash_time = dash_time - dt
        if dash_time <= timer_epsilon then dash_time = 0 end
        return
      end

      if cooldown > 0 then
        return
      end

      local target = player_position()
      if not target_within_detection(self, target) then
        return
      end

      play_attack_anim(self, "charge")
      dash_dir = (target.x < self.pos.x) and -1 or 1
      dash_speed = scaled_movement_tuning(self, "dash_speed", "charge_speed")
        or (movement_speed(self, 100) * 4)

      local dash_duration = enemy_tuning(self, "dash_duration", "charge_duration")
      if not dash_duration then
        local dash_distance = enemy_tuning(self, "dash_distance", "charge_distance") or 96
        dash_duration = dash_distance / dash_speed
      end

      self.vel.x = dash_dir * dash_speed
      if self._grounded_movement then
        self.vel.y = 0
      end
      -- The triggering frame already advances at dash speed, so retain only
      -- the remaining time for subsequent updates.
      dash_time = dash_duration - dt
      if dash_time <= timer_epsilon then dash_time = 0 end
      cooldown = enemy_tuning(self, "dash_cooldown", "charge_cooldown") or 2.0
    end
  }
end

function M.jump_attack()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = 0.25
          return
        end
        play_attack_anim(self, "jump")
        self.vel.y = movement_speed(self, 100) * 3
        cd = 2.5
      end
    end
  }
end

function M.teleport_attack()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if target_within_detection(self, target) then
          play_attack_anim(self, "attack")
          self.pos.x = target.x + ((math.random()<0.5) and -64 or 64)
          self.pos.y = target.y
        end
        cd = 3.0
      end
    end
  }
end

function M.rain_attack()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = 4.0
          return
        end
        play_attack_anim(self, "attack")
        for i=1,4 do
          self.spawn_projectile(self, -1 + 0, 0)
        end
        cd = 4.0
      end
    end
  }
end

function M.shield()
  local timer = 0
  return {
    update = function(self, dt)
      timer = timer + dt
      if timer < 2.0 then self.shielded = true else self.shielded = false; if timer>4.0 then timer=0 end end
    end
  }
end

function M.summon_minion()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          -- Poll often enough to react promptly when the player enters range,
          -- without letting an off-screen summoner create minions forever.
          cd = 0.25
          return
        end
        print('[ENEMY] summoning minion')
        cd = 5.0
      end
    end
  }
end

function M.spiral_shot()
  local angle, cd = 0, 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = 0.2
          return
        end
        local dir = math.cos(angle) >= 0 and 1 or -1
        self.spawn_projectile(self, dir, projectile_speed(self, 300))
        angle = angle + 0.3
        cd = 0.2
      end
    end
  }
end

function M.zigzag_move()
  local dir = 1
  return {
    update = function(self, dt)
      if self._ledge_blocked_dir == dir then dir = -dir end
      self.vel.x = dir * movement_speed(self, 80)
      self.vel.y = math.sin(self.pos.x * 0.1) * 40
      if math.abs(self.pos.x - self.start_pos.x) > 96 then dir = -dir end
    end
  }
end

function M.homing_shot()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = 1.5
          return
        end
        self.spawn_projectile(self, 1, projectile_speed(self, 200))
        cd = 1.5
      end
    end
  }
end

function M.charge_shoot()
  local cd = 0
  return {
    update = function(self, dt)
      cd = cd - dt
      if cd <= 0 then
        local target = player_position()
        if not target_within_detection(self, target) then
          cd = 2.0
          return
        end
        play_attack_anim(self, "charge")
        local direction = target.x < self.pos.x and -1 or 1
        local charge_speed = scaled_movement_tuning(self, "charge_speed")
          or (movement_speed(self, 100) * 3)
        self.vel.x = direction * charge_speed
        self.spawn_projectile(self, direction, projectile_speed(self, 300))
        cd = 2.0
      end
    end
  }
end

local REGISTRY = {
  [hash("idle")] = M.idle,
  [hash("patrol_horizontal")] = M.patrol_horizontal,
  [hash("patrol_vertical")] = M.patrol_vertical,
  [hash("ground_patrol_chase")] = M.ground_patrol_chase,
  [hash("chase_ground")] = M.chase_ground,
  [hash("chase_flying")] = M.chase_flying,
  [hash("chase_player")] = M.chase_player,
  [hash("flee_player")] = M.flee_player,
  [hash("shoot_straight")] = M.shoot_straight,
  [hash("shoot_spread")] = M.shoot_spread,
  [hash("shoot_burst")] = M.shoot_burst,
  [hash("shoot_circle")] = M.shoot_circle,
  [hash("shoot_random")] = M.shoot_random,
  [hash("swoop_attack")] = M.swoop_attack,
  [hash("melee_swipe")] = M.melee_swipe,
  [hash("dash_attack")] = M.dash_attack,
  [hash("jump_attack")] = M.jump_attack,
  [hash("teleport_attack")] = M.teleport_attack,
  [hash("rain_attack")] = M.rain_attack,
  [hash("shield")] = M.shield,
  [hash("summon_minion")] = M.summon_minion,
  [hash("spiral_shot")] = M.spiral_shot,
  [hash("zigzag_move")] = M.zigzag_move,
  [hash("homing_shot")] = M.homing_shot,
  [hash("charge_shoot")] = M.charge_shoot,
  [hash("ghost_float")] = M.ghost_float,
}

-- Plain-string helpers are intentionally available for deterministic Lua
-- tests and editor diagnostics; runtime pattern lookup remains hash-based.
REGISTRY._helpers = {
  movement_speed = movement_speed,
  effective_chase_speed = effective_chase_speed,
  target_within_detection = target_within_detection,
}

return REGISTRY

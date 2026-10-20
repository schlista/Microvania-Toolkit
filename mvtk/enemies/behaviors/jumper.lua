--- Jumper Behavior
-- Ground-based enemy that jumps toward the player
-- Waits on ground, then performs arcing jumps
-- Can jump over small obstacles
--
-- @module jumper

local M = {}

local Detection = require "mvtk.enemies.detection"
local SurfaceClassifier = require "mvtk.core.surface_classifier"
local SafeSound = require "mvtk.audio.safe_sound"

--- Initialize jumper behavior
-- @param self The enemy script instance
-- @param config The enemy configuration
function M.init(self, config)
    self.jumper = {
        -- Jump mechanics
        jump_power = config.jump_power or 300,  -- Upward force
        jump_forward_speed = config.jump_forward_speed or 150,  -- Horizontal speed during jump
        jump_cooldown = config.jump_cooldown or 1.5,  -- Time between jumps
        jump_timer = 0,

        -- Idle/waiting
        idle_time = config.idle_time or 0.3,  -- Time to wait on ground before jumping
        idle_timer = 0,

        -- Ground detection
        is_grounded = true,
        gravity = config.gravity or 800,
        current_velocity = vmath.vector3(0, 0, 0),

        -- Targeting
        jump_range = config.jump_range or 200,  -- How far to detect player
        min_jump_distance = config.min_jump_distance or 50,  -- Don't jump if too close
        aim_at_player = config.aim_at_player or true,  -- Aim jumps toward player
    }

    self.state = "idle"  -- "idle", "jumping", "airborne", "landing"
    self.facing = 1
end

--- Update jumper behavior
-- @param self The enemy script instance
-- @param dt Delta time
function M.update(self, dt)
    if not self.jumper then return end

    local pos = go.get_position()
    local player_pos = Detection.get_player_position()

    -- Update timers
    if self.jumper.jump_timer > 0 then
        self.jumper.jump_timer = self.jumper.jump_timer - dt
    end

    if self.jumper.idle_timer > 0 then
        self.jumper.idle_timer = self.jumper.idle_timer - dt
    end

    -- Execute behavior based on state
    if self.state == "idle" then
        M.idle_on_ground(self, dt, pos, player_pos)
    elseif self.state == "jumping" then
        M.prepare_jump(self, dt, pos, player_pos)
    elseif self.state == "airborne" then
        M.in_air(self, dt, pos)
    elseif self.state == "landing" then
        M.land(self, dt, pos)
    end

    -- Apply gravity when not grounded
    if not self.jumper.is_grounded then
        M.apply_gravity(self, dt)
    end
end

--- Idle on ground, waiting to jump
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
-- @param player_pos Player position (can be nil)
function M.idle_on_ground(self, dt, pos, player_pos)
    -- Check if can jump (cooldown expired)
    if self.jumper.jump_timer > 0 then
        return
    end

    -- Check for player in range
    if player_pos then
        local distance = vmath.length(player_pos - pos)
        local detection_range = self.config.detection_range or self.jumper.jump_range

        if distance <= detection_range and distance >= self.jumper.min_jump_distance then
            -- Check if roughly on same level
            local vertical_diff = math.abs(player_pos.y - pos.y)
            if vertical_diff < 100 then
                -- Prepare to jump
                self.state = "jumping"
                self.jumper.idle_timer = self.jumper.idle_time
                return
            end
        end
    end

    -- Just idle
    self.jumper.current_velocity = vmath.vector3(0, 0, 0)
end

--- Prepare to jump (brief windup)
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
-- @param player_pos Player position (can be nil)
function M.prepare_jump(self, dt, pos, player_pos)
    -- Wait for idle timer
    if self.jumper.idle_timer > 0 then
        -- Could show windup animation (crouch down)
        return
    end

    -- Calculate jump direction
    local jump_direction = 1  -- Default: jump forward in facing direction

    if player_pos and self.jumper.aim_at_player then
        -- Aim jump toward player
        local to_player = player_pos - pos
        jump_direction = to_player.x >= 0 and 1 or -1
        self.facing = jump_direction
    end

    -- Perform jump
    self.jumper.current_velocity = vmath.vector3(
        self.jumper.jump_forward_speed * jump_direction,
        self.jumper.jump_power,
        0
    )

    self.jumper.is_grounded = false
    self.state = "airborne"

    -- Play jump sound
    if self.config.audio and self.config.audio.jump then
        SafeSound.play(self.config.audio.jump)
    end
end

--- In air during jump
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
function M.in_air(self, dt, pos)
    -- Apply current velocity
    M.apply_movement(self, self.jumper.current_velocity, dt)

    -- Check if starting to fall (velocity.y becomes negative)
    if self.jumper.current_velocity.y < 0 then
        -- Could change animation to falling
    end
end

--- Landing on ground
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
function M.land(self, dt, pos)
    -- Stop vertical movement
    self.jumper.current_velocity.y = 0
    self.jumper.is_grounded = true

    -- Start cooldown
    self.jumper.jump_timer = self.jumper.jump_cooldown

    -- Return to idle
    self.state = "idle"

    -- Play land sound
    if self.config.audio and self.config.audio.land then
        SafeSound.play(self.config.audio.land)
    end
end

--- Apply gravity to velocity
-- @param self The enemy script instance
-- @param dt Delta time
function M.apply_gravity(self, dt)
    self.jumper.current_velocity.y = self.jumper.current_velocity.y - self.jumper.gravity * dt

    -- Terminal velocity
    if self.jumper.current_velocity.y < -600 then
        self.jumper.current_velocity.y = -600
    end
end

--- Apply movement to enemy
-- @param self The enemy script instance
-- @param velocity Velocity vector
-- @param dt Delta time
function M.apply_movement(self, velocity, dt)
    if self.apply_velocity then
        self:apply_velocity(velocity)
    else
        -- Fallback: direct position update
        local pos = go.get_position()
        pos = pos + velocity * dt
        go.set_position(pos)
    end
end

--- Handle collision events
-- @param self The enemy script instance
-- @param message Collision message
function M.on_collision(self, message)
    local group = message and message.group
    if not SurfaceClassifier.is_terrain_group(group) then
        return
    end

    local surface_kind = SurfaceClassifier.classify_collision(message)

    -- Landing on ground
    if surface_kind == SurfaceClassifier.KINDS.GROUND then
        -- Check if collision from below (landing on top)
        if message.normal.y > 0.7 then
            if self.state == "airborne" then
                self.state = "landing"
                M.land(self, 0, go.get_position())
            end
        end
    end

    -- Hitting wall while jumping
    if surface_kind == SurfaceClassifier.KINDS.WALL then
        if self.state == "airborne" then
            -- Stop horizontal movement
            self.jumper.current_velocity.x = 0
        end
    end

    -- Hitting ceiling
    if surface_kind == SurfaceClassifier.KINDS.CEILING then
        -- Bonk head on ceiling, stop upward movement
        if self.jumper.current_velocity.y > 0 then
            self.jumper.current_velocity.y = 0
        end
    end
end

--- Cleanup behavior
-- @param self The enemy script instance
function M.cleanup(self)
    self.jumper = nil
end

return M

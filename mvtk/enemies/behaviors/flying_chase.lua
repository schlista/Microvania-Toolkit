--- Flying Chase Behavior
-- Flying enemy that hovers and chases the player when detected
-- Moves in 2D space (X and Y) with smooth floating motion
-- Returns to idle position when player is out of range
--
-- @module flying_chase

local M = {}

local Detection = require "mvtk.enemies.detection"
local SurfaceClassifier = require "mvtk.core.surface_classifier"

--- Initialize flying chase behavior
-- @param self The enemy script instance
-- @param config The enemy configuration
function M.init(self, config)
    local pos = go.get_position()

    self.flying = {
        speed = config.speed or 80,
        chase_speed = config.chase_speed or 120,
        idle_pos = vmath.vector3(pos),  -- Starting position
        hover_amplitude = config.hover_amplitude or 10,  -- Vertical hover distance
        hover_speed = config.hover_speed or 2,  -- How fast to bob up/down
        hover_timer = 0,

        -- Return to idle behavior
        return_speed = config.return_speed or 60,
        idle_radius = config.idle_radius or 30,  -- How close to get before stopping

        -- Chase smoothing
        acceleration = config.acceleration or 500,
        deceleration = config.deceleration or 300,
        current_velocity = vmath.vector3(0, 0, 0),
        max_velocity = config.chase_speed or 120,
    }

    self.state = "idle"  -- "idle", "chase", "return"
    self.facing = 1  -- 1 = right, -1 = left
end

--- Update flying chase behavior
-- @param self The enemy script instance
-- @param dt Delta time
function M.update(self, dt)
    if not self.flying then return end

    local pos = go.get_position()
    local player_pos = Detection.get_player_position()

    -- Update hover animation timer
    self.flying.hover_timer = self.flying.hover_timer + dt

    -- Determine state based on player detection
    if not player_pos then
        -- No player, return to idle
        if self.state ~= "return" and self.state ~= "idle" then
            self.state = "return"
        end
    else
        -- Check if player is in detection range
        local distance = vmath.length(player_pos - pos)
        local detection_range = self.config.detection_range or 200

        if distance <= detection_range then
            self.state = "chase"
        else
            self.state = "return"
        end
    end

    -- Execute behavior based on state
    if self.state == "chase" then
        M.chase_player(self, dt, pos, player_pos)
    elseif self.state == "return" then
        M.return_to_idle(self, dt, pos)
    else
        M.idle_hover(self, dt, pos)
    end
end

--- Idle hovering behavior
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
function M.idle_hover(self, dt, pos)
    -- Gentle up/down bobbing motion
    local hover_offset = math.sin(self.flying.hover_timer * self.flying.hover_speed) * self.flying.hover_amplitude

    -- Target position is idle position + hover offset
    local target_y = self.flying.idle_pos.y + hover_offset

    -- Smoothly move to target Y
    local current_y = pos.y
    local new_y = current_y + (target_y - current_y) * dt * 5

    -- Keep X at idle position
    local new_x = self.flying.idle_pos.x

    -- Set position
    go.set_position(vmath.vector3(new_x, new_y, pos.z))

    -- Reset velocity
    self.flying.current_velocity = vmath.vector3(0, 0, 0)
end

--- Chase player behavior with smooth acceleration
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
-- @param player_pos Player position
function M.chase_player(self, dt, pos, player_pos)
    -- Calculate direction to player
    local to_player = player_pos - pos
    local distance = vmath.length(to_player)

    if distance < 1 then
        return  -- Already at player
    end

    local direction = vmath.normalize(to_player)

    -- Calculate desired velocity
    local desired_velocity = direction * self.flying.chase_speed

    -- Smoothly accelerate toward desired velocity
    local velocity_diff = desired_velocity - self.flying.current_velocity
    local acceleration = self.flying.acceleration * dt

    if vmath.length(velocity_diff) > acceleration then
        velocity_diff = vmath.normalize(velocity_diff) * acceleration
    end

    self.flying.current_velocity = self.flying.current_velocity + velocity_diff

    -- Clamp to max velocity
    local current_speed = vmath.length(self.flying.current_velocity)
    if current_speed > self.flying.max_velocity then
        self.flying.current_velocity = vmath.normalize(self.flying.current_velocity) * self.flying.max_velocity
    end

    -- Apply movement
    M.apply_movement(self, self.flying.current_velocity, dt)

    -- Update facing direction
    if to_player.x > 0 then
        self.facing = 1
    elseif to_player.x < 0 then
        self.facing = -1
    end
end

--- Return to idle position
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
function M.return_to_idle(self, dt, pos)
    local to_idle = self.flying.idle_pos - pos
    local distance = vmath.length(to_idle)

    -- If close enough, switch to idle state
    if distance <= self.flying.idle_radius then
        self.state = "idle"
        self.flying.current_velocity = vmath.vector3(0, 0, 0)
        return
    end

    -- Calculate direction to idle position
    local direction = vmath.normalize(to_idle)

    -- Calculate desired velocity
    local desired_velocity = direction * self.flying.return_speed

    -- Smoothly decelerate and move toward idle
    local velocity_diff = desired_velocity - self.flying.current_velocity
    local deceleration = self.flying.deceleration * dt

    if vmath.length(velocity_diff) > deceleration then
        velocity_diff = vmath.normalize(velocity_diff) * deceleration
    end

    self.flying.current_velocity = self.flying.current_velocity + velocity_diff

    -- Apply movement
    M.apply_movement(self, self.flying.current_velocity, dt)

    -- Update facing direction
    if to_idle.x > 0 then
        self.facing = 1
    elseif to_idle.x < 0 then
        self.facing = -1
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
    -- Flying enemies bounce off walls
    local group = message and message.group
    local surface_kind = SurfaceClassifier.classify_collision(message)
    if SurfaceClassifier.is_terrain_group(group) and surface_kind ~= SurfaceClassifier.KINDS.UNKNOWN then
        -- Reflect velocity based on collision normal
        local normal = message.normal
        local velocity = self.flying.current_velocity

        -- Reflect: V_prime = V - 2(V dot N)N
        local dot = vmath.dot(velocity, normal)
        local reflection = velocity - normal * 2 * dot

        self.flying.current_velocity = reflection * 0.5  -- Dampen the reflection
    end
end

--- Cleanup behavior
-- @param self The enemy script instance
function M.cleanup(self)
    self.flying = nil
end

return M

--- Ground Patrol Behavior
-- Simple walking enemy that patrols back and forth
-- Chases player when within detection range
-- Falls off ledges and turns around when hitting walls
--
-- @module ground_patrol

local M = {}

local Detection = require "mvtk.enemies.detection"
local SurfaceClassifier = require "mvtk.core.surface_classifier"

local LEDGE_GROUPS = SurfaceClassifier.RAYCAST.GROUND
local WALL_GROUPS = SurfaceClassifier.RAYCAST.WALL

--- Initialize ground patrol behavior
-- @param self The enemy script instance
-- @param config The enemy configuration
function M.init(self, config)
    self.patrol = {
        direction = 1,  -- 1 = right, -1 = left
        speed = config.speed or 50,
        chase_speed = config.chase_speed or (config.speed * 1.5),
        turn_timer = 0,
        turn_cooldown = 0.2,  -- Prevent rapid turning
        ledge_check_distance = 20,  -- How far ahead to check for ledges
        wall_check_distance = 10,   -- How far ahead to check for walls
    }

    self.state = "patrol"  -- "patrol" or "chase"
    self.facing = 1  -- 1 = right, -1 = left
end

--- Update ground patrol behavior
-- @param self The enemy script instance
-- @param dt Delta time
function M.update(self, dt)
    if not self.patrol then return end

    local pos = go.get_position()
    local player_pos = Detection.get_player_position()

    if not player_pos then
        -- No player, just patrol
        self.state = "patrol"
    else
        -- Check if player is in detection range
        local distance = vmath.length(player_pos - pos)
        local detection_range = self.config.detection_range or 150

        if distance <= detection_range then
            -- Check if player is on same level (within vertical threshold)
            local vertical_diff = math.abs(player_pos.y - pos.y)
            if vertical_diff < 50 then  -- Same platform level
                self.state = "chase"
            else
                self.state = "patrol"
            end
        else
            self.state = "patrol"
        end
    end

    -- Execute behavior based on state
    if self.state == "chase" then
        M.chase_player(self, dt, pos, player_pos)
    else
        M.patrol(self, dt, pos)
    end

    -- Update turn cooldown
    if self.patrol.turn_timer > 0 then
        self.patrol.turn_timer = self.patrol.turn_timer - dt
    end
end

--- Patrol behavior - walk back and forth
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
function M.patrol(self, dt, pos)
    local speed = self.patrol.speed
    local direction = self.patrol.direction

    -- Check for ledges ahead
    if M.check_ledge_ahead(self, pos, direction) then
        M.turn_around(self)
        return
    end

    -- Check for walls ahead
    if M.check_wall_ahead(self, pos, direction) then
        M.turn_around(self)
        return
    end

    -- Move in current direction
    local velocity = vmath.vector3(speed * direction, 0, 0)
    M.apply_movement(self, velocity, dt)

    -- Update facing direction
    self.facing = direction
end

--- Chase player behavior
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
-- @param player_pos Player position
function M.chase_player(self, dt, pos, player_pos)
    -- Defensive: caller normally guarantees player_pos is non-nil, but if
    -- Detection.get_player_position() raced with a room transition we may
    -- still be invoked with nil. Bail out cleanly instead of crashing.
    if not player_pos or not pos then return end
    local speed = self.patrol.chase_speed

    -- Determine direction to player
    local direction = player_pos.x > pos.x and 1 or -1

    -- Check for ledges ahead (still respect ledges while chasing)
    if M.check_ledge_ahead(self, pos, direction) then
        -- Stop at ledge, don't chase off cliff
        return
    end

    -- Check for walls ahead
    if M.check_wall_ahead(self, pos, direction) then
        -- Can't chase through walls
        return
    end

    -- Move toward player
    local velocity = vmath.vector3(speed * direction, 0, 0)
    M.apply_movement(self, velocity, dt)

    -- Update facing and patrol direction
    self.facing = direction
    self.patrol.direction = direction
end

--- Check if there's a ledge ahead
-- @param self The enemy script instance
-- @param pos Current position
-- @param direction Movement direction (1 or -1)
-- @return true if ledge detected
function M.check_ledge_ahead(self, pos, direction)
    local check_distance = self.patrol.ledge_check_distance

    -- Raycast downward from position ahead
    local start_pos = vmath.vector3(
        pos.x + (check_distance * direction),
        pos.y,
        0
    )
    local end_pos = vmath.vector3(
        pos.x + (check_distance * direction),
        pos.y - 30,  -- Check 30 pixels down
        0
    )

    -- Do raycast
    local result = physics.raycast(start_pos, end_pos, LEDGE_GROUPS)

    -- If no walkable surface is detected, there's a ledge
    return not SurfaceClassifier.is_ground_collision(result)
end

--- Check if there's a wall ahead
-- @param self The enemy script instance
-- @param pos Current position
-- @param direction Movement direction (1 or -1)
-- @return true if wall detected
function M.check_wall_ahead(self, pos, direction)
    local check_distance = self.patrol.wall_check_distance

    -- Raycast horizontally ahead
    local start_pos = vmath.vector3(pos.x, pos.y, 0)
    local end_pos = vmath.vector3(
        pos.x + (check_distance * direction),
        pos.y,
        0
    )

    -- Do raycast
    local result = physics.raycast(start_pos, end_pos, WALL_GROUPS)

    return SurfaceClassifier.is_wall_collision(result)
end

--- Turn around (reverse direction)
-- @param self The enemy script instance
function M.turn_around(self)
    -- Check turn cooldown to prevent rapid turning
    if self.patrol.turn_timer > 0 then
        return
    end

    -- Reverse direction
    self.patrol.direction = -self.patrol.direction
    self.facing = self.patrol.direction

    -- Set turn cooldown
    self.patrol.turn_timer = self.patrol.turn_cooldown
end

--- Apply movement to enemy
-- @param self The enemy script instance
-- @param velocity Velocity vector
-- @param dt Delta time
function M.apply_movement(self, velocity, dt)
    -- This will be called by the enemy controller script
    -- The controller handles actual physics/position updates
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

    -- Turn around when hitting a wall
    if SurfaceClassifier.is_wall_collision(message) and math.abs(message.normal.x) > 0.7 then
        M.turn_around(self)
    end
end

--- Cleanup behavior
-- @param self The enemy script instance
function M.cleanup(self)
    self.patrol = nil
end

return M

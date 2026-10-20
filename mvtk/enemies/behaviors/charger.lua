--- Charger Behavior
-- Enemy that rushes at the player at high speed when detected
-- Has a wind-up/telegraph phase before charging
-- Crashes into walls and needs recovery time
--
-- @module charger

local M = {}

local Detection = require "mvtk.enemies.detection"
local SurfaceClassifier = require "mvtk.core.surface_classifier"
local SafeSound = require "mvtk.audio.safe_sound"

--- Initialize charger behavior
-- @param self The enemy script instance
-- @param config The enemy configuration
function M.init(self, config)
    self.charger = {
        -- Movement speeds
        patrol_speed = config.patrol_speed or 30,
        charge_speed = config.charge_speed or 400,

        -- Charge mechanics
        windup_time = config.windup_time or 0.8,  -- Telegraph before charging
        windup_timer = 0,
        charge_duration = config.charge_duration or 1.5,  -- Max time charging
        charge_timer = 0,
        cooldown_time = config.cooldown_time or 2.0,  -- Recovery after charge
        cooldown_timer = 0,

        -- Crash mechanics
        crash_stun_time = config.crash_stun_time or 1.5,  -- Stun when hitting wall
        crash_timer = 0,

        -- Targeting
        charge_range = config.charge_range or 200,  -- How close before charging
        charge_direction = vmath.vector3(0, 0, 0),  -- Direction locked during charge

        -- Patrol (when not charging)
        patrol_direction = 1,  -- 1 = right, -1 = left
    }

    self.state = "patrol"  -- "patrol", "windup", "charging", "crash", "cooldown"
    self.facing = 1
end

--- Update charger behavior
-- @param self The enemy script instance
-- @param dt Delta time
function M.update(self, dt)
    if not self.charger then return end

    local pos = go.get_position()
    local player_pos = Detection.get_player_position()

    -- Execute behavior based on state
    if self.state == "patrol" then
        M.patrol(self, dt, pos, player_pos)
    elseif self.state == "windup" then
        M.windup(self, dt, pos, player_pos)
    elseif self.state == "charging" then
        M.charge(self, dt, pos)
    elseif self.state == "crash" then
        M.crash_recovery(self, dt)
    elseif self.state == "cooldown" then
        M.cooldown(self, dt, pos, player_pos)
    end
end

--- Patrol behavior - walk slowly until player in range
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
-- @param player_pos Player position (can be nil)
function M.patrol(self, dt, pos, player_pos)
    -- Check for player in charge range
    if player_pos then
        local distance = vmath.length(player_pos - pos)
        local detection_range = self.config.detection_range or self.charger.charge_range

        if distance <= detection_range then
            -- Check if on same level (vertical threshold)
            local vertical_diff = math.abs(player_pos.y - pos.y)
            if vertical_diff < 40 then
                -- Start charging sequence
                self.state = "windup"
                self.charger.windup_timer = self.charger.windup_time

                -- Lock charge direction toward player
                local to_player = player_pos - pos
                self.charger.charge_direction = vmath.normalize(to_player)

                return
            end
        end
    end

    -- Simple patrol movement
    local velocity = vmath.vector3(self.charger.patrol_speed * self.charger.patrol_direction, 0, 0)
    M.apply_movement(self, velocity, dt)

    self.facing = self.charger.patrol_direction
end

--- Windup/telegraph before charge
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
-- @param player_pos Player position (can be nil)
function M.windup(self, dt, pos, player_pos)
    -- Count down windup timer
    self.charger.windup_timer = self.charger.windup_timer - dt

    -- Could add visual effects here (shake, change color, etc.)
    -- For now, just stay still during windup

    -- Update charge direction to track player during windup
    if player_pos then
        local to_player = player_pos - pos
        self.charger.charge_direction = vmath.normalize(to_player)
        self.facing = self.charger.charge_direction.x >= 0 and 1 or -1
    end

    -- When windup completes, start charging
    if self.charger.windup_timer <= 0 then
        self.state = "charging"
        self.charger.charge_timer = self.charger.charge_duration

        -- Play charge sound/effect
        if self.config.audio and self.config.audio.charge then
            SafeSound.play(self.config.audio.charge)
        end
    end
end

--- Charge at high speed in locked direction
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
function M.charge(self, dt, pos)
    -- Move at high speed in charge direction
    local velocity = self.charger.charge_direction * self.charger.charge_speed
    M.apply_movement(self, velocity, dt)

    -- Update charge timer
    self.charger.charge_timer = self.charger.charge_timer - dt

    -- End charge after duration
    if self.charger.charge_timer <= 0 then
        self.state = "cooldown"
        self.charger.cooldown_timer = self.charger.cooldown_time
    end
end

--- Recovery after crash into wall
-- @param self The enemy script instance
-- @param dt Delta time
function M.crash_recovery(self, dt)
    -- Stunned, can't move
    self.charger.crash_timer = self.charger.crash_timer - dt

    -- Could show stars/dazed effect

    -- Recover after stun time
    if self.charger.crash_timer <= 0 then
        self.state = "cooldown"
        self.charger.cooldown_timer = self.charger.cooldown_time
    end
end

--- Cooldown after charge (can't charge again yet)
-- @param self The enemy script instance
-- @param dt Delta time
-- @param pos Current position
-- @param player_pos Player position (can be nil)
function M.cooldown(self, dt, pos, player_pos)
    -- Count down cooldown
    self.charger.cooldown_timer = self.charger.cooldown_timer - dt

    -- Resume patrolling during cooldown
    local velocity = vmath.vector3(self.charger.patrol_speed * self.charger.patrol_direction, 0, 0)
    M.apply_movement(self, velocity, dt)

    self.facing = self.charger.patrol_direction

    -- After cooldown, return to patrol state
    if self.charger.cooldown_timer <= 0 then
        self.state = "patrol"
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
    local surface_kind = SurfaceClassifier.classify_collision(message)
    local hit_terrain = SurfaceClassifier.is_terrain_group(group) and surface_kind ~= SurfaceClassifier.KINDS.UNKNOWN

    -- If charging and hit a wall, crash
    if self.state == "charging" then
        if hit_terrain then
            -- Check if collision is from the side (not top/bottom)
            if math.abs(message.normal.x) > 0.7 or math.abs(message.normal.y) > 0.7 then
                -- Crash!
                self.state = "crash"
                self.charger.crash_timer = self.charger.crash_stun_time

                -- Play crash sound/effect
                if self.config.audio and self.config.audio.crash then
                    SafeSound.play(self.config.audio.crash)
                end

                -- Could spawn particle effect
            end
        end
    end

    -- Turn around during patrol if hit wall
    if self.state == "patrol" then
        if surface_kind == SurfaceClassifier.KINDS.WALL and math.abs(message.normal.x) > 0.7 then
            self.charger.patrol_direction = -self.charger.patrol_direction
        end
    end
end

--- Cleanup behavior
-- @param self The enemy script instance
function M.cleanup(self)
    self.charger = nil
end

return M

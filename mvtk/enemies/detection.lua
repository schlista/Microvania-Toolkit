--- Enemy Detection and Aggro System
-- Provides utilities for enemies to detect and track the player
-- Handles line-of-sight checks, distance calculations, and player state tracking
--
-- @module detection

local Time = require "mvtk.core.time"
local C = require "mvtk.core.constants"
local SurfaceClassifier = require "mvtk.core.surface_classifier"

local M = {}

local DEFAULT_LOS_GROUPS = SurfaceClassifier.RAYCAST.TERRAIN

local function normalize_collision_groups(groups)
    if not groups then
        return nil
    end
    if type(groups) ~= "table" then
        return groups
    end
    local out = {}
    for i, g in ipairs(groups) do
        if type(g) == "string" then
            out[i] = hash(g)
        else
            out[i] = g
        end
    end
    if #out == 0 then
        for _, g in pairs(groups) do
            if type(g) == "string" then
                table.insert(out, hash(g))
            else
                table.insert(out, g)
            end
        end
    end
    return out
end

-- Cached player information
local player_data = {
    position = nil,
    velocity = nil,
    last_update = 0,
    is_alive = true,
    game_object_id = nil,
}

-- Configuration
local config = {
    player_url = msg.url("main:/collection2/player#player"),  -- Default player URL
    update_frequency = 0.033,  -- Update player data every ~30fps
}

--- Initialize detection system
-- @param player_url Optional custom player URL
function M.init(player_url)
    if player_url then
        config.player_url = player_url
    end

    -- Request initial player position
    M.update_player_data()
end

--- Update cached player data
-- Called automatically at intervals, or manually by enemies
function M.update_player_data()
    local current_time = Time.gettime()

    -- Throttle updates
    if current_time - player_data.last_update < config.update_frequency then
        return
    end

    local previous_update = player_data.last_update
    player_data.last_update = current_time

    -- Try to get player game object
    if not player_data.game_object_id then
        -- First check explicit config.player_url
        if config.player_url then
            local ok = pcall(function()
                go.get_position(config.player_url)
            end)
            if ok then
                player_data.game_object_id = config.player_url
            end
        end

        -- Next check C.URL.PLAYER (set by player_spawner when player is created)
        if not player_data.game_object_id and C.URL.PLAYER then
            local success = pcall(function()
                go.get_position(C.URL.PLAYER)
            end)
            if success then
                player_data.game_object_id = C.URL.PLAYER
            end
        end
    end

    -- Update position
    if player_data.game_object_id then
        local success, pos = pcall(function()
            return go.get_position(player_data.game_object_id)
        end)

        if success then
            -- Calculate velocity if we have previous position
            if player_data.position then
                local dt = current_time - previous_update
                if dt > 0 then
                    player_data.velocity = (pos - player_data.position) / dt
                end
            end

            player_data.position = pos
            player_data.is_alive = true
        else
            -- Player might be dead or removed
            player_data.is_alive = false
        end
    end
end

--- Get player URL (for damage application)
-- @return Player URL or nil
function M.get_player_url()
    M.update_player_data()
    return player_data.game_object_id or config.player_url
end

--- Get player position
-- @return Player position vector3, or nil if not available
function M.get_player_position()
    M.update_player_data()
    return player_data.position
end

--- Get player velocity
-- @return Player velocity vector3, or nil if not available
function M.get_player_velocity()
    M.update_player_data()
    return player_data.velocity
end

--- Check if player is alive
-- @return true if player is alive and trackable
function M.is_player_alive()
    M.update_player_data()
    return player_data.is_alive
end

--- Get distance to player from position
-- @param pos Position to measure from
-- @return Distance to player, or nil if player not available
function M.get_distance_to_player(pos)
    local player_pos = M.get_player_position()
    if not player_pos then
        return nil
    end

    return vmath.length(player_pos - pos)
end

--- Check if player is within detection range
-- @param pos Enemy position
-- @param range Detection range
-- @return true if player is in range
function M.is_player_in_range(pos, range)
    local distance = M.get_distance_to_player(pos)
    if not distance then
        return false
    end

    return distance <= range
end

--- Check if there's line of sight to player
-- @param from_pos Starting position
-- @param max_distance Optional max distance to check (default: infinite)
-- @param collision_groups Optional table of collision groups to check against (default: terrain/solid layers)
-- @return true if clear line of sight, false otherwise
function M.has_line_of_sight(from_pos, max_distance, collision_groups)
    local player_pos = M.get_player_position()
    if not player_pos then
        return false
    end

    -- Check distance limit
    if max_distance then
        local distance = vmath.length(player_pos - from_pos)
        if distance > max_distance then
            return false
        end
    end

    -- Default collision groups
    collision_groups = normalize_collision_groups(collision_groups) or DEFAULT_LOS_GROUPS

    -- Raycast to check for obstacles
    local result = physics.raycast(from_pos, player_pos, collision_groups)

    -- If raycast hit something, no line of sight
    return result == nil
end

--- Check if player is on similar vertical level (same platform)
-- @param pos Enemy position
-- @param vertical_threshold Max vertical difference to consider "same level" (default: 50)
-- @return true if player is on same level
function M.is_player_on_same_level(pos, vertical_threshold)
    vertical_threshold = vertical_threshold or 50

    local player_pos = M.get_player_position()
    if not player_pos then
        return false
    end

    local vertical_diff = math.abs(player_pos.y - pos.y)
    return vertical_diff <= vertical_threshold
end

--- Get direction to player
-- @param pos Position to measure from
-- @param normalize If true, returns normalized direction vector (default: true)
-- @return Direction vector to player, or nil if player not available
function M.get_direction_to_player(pos, normalize)
    if normalize == nil then
        normalize = true
    end

    local player_pos = M.get_player_position()
    if not player_pos then
        return nil
    end

    local direction = player_pos - pos

    if normalize then
        local length = vmath.length(direction)
        if length > 0 then
            direction = direction / length
        end
    end

    return direction
end

--- Get horizontal direction to player (1 or -1)
-- @param pos Position to measure from
-- @return 1 if player is to the right, -1 if to the left, 0 if player not available
function M.get_horizontal_direction_to_player(pos)
    local player_pos = M.get_player_position()
    if not player_pos then
        return 0
    end

    if player_pos.x > pos.x then
        return 1
    elseif player_pos.x < pos.x then
        return -1
    else
        return 0
    end
end

--- Check if player can be detected (composite check)
-- @param pos Enemy position
-- @param detection_range Max detection range
-- @param require_los If true, requires line of sight (default: true)
-- @param require_same_level If true, requires similar Y position (default: false)
-- @param vertical_threshold Vertical threshold for same level check (default: 50)
-- @return true if player detected, false otherwise
function M.can_detect_player(pos, detection_range, require_los, require_same_level, vertical_threshold)
    require_los = require_los == nil and true or require_los
    require_same_level = require_same_level or false

    -- Check if player is alive
    if not M.is_player_alive() then
        return false
    end

    -- Check range
    if not M.is_player_in_range(pos, detection_range) then
        return false
    end

    -- Check line of sight if required
    if require_los then
        if not M.has_line_of_sight(pos, detection_range) then
            return false
        end
    end

    -- Check same level if required
    if require_same_level then
        if not M.is_player_on_same_level(pos, vertical_threshold) then
            return false
        end
    end

    return true
end

--- Predict where player will be after time
-- @param pos Current enemy position (for reference)
-- @param time_ahead How far ahead to predict (seconds)
-- @return Predicted player position, or current position if velocity unavailable
function M.predict_player_position(pos, time_ahead)
    local player_pos = M.get_player_position()
    if not player_pos then
        return nil
    end

    local player_vel = M.get_player_velocity()
    if not player_vel then
        return player_pos
    end

    -- Predict future position
    return player_pos + player_vel * time_ahead
end

--- Set custom player URL
-- @param player_url URL or path to player game object
function M.set_player_url(player_url)
    config.player_url = player_url
    player_data.game_object_id = nil  -- Force re-search
end

--- Manual position update (for performance optimization)
-- Enemies can call this once per frame instead of each behavior module calling individually
function M.tick()
    M.update_player_data()
end

--- Reset cached player data
-- Call this when player respawns or level changes
function M.reset()
    player_data.position = nil
    player_data.velocity = nil
    player_data.last_update = 0
    player_data.is_alive = true
    player_data.game_object_id = nil
end

return M

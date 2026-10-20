-- mvtk/enemies/ai/bt_conditions.lua
-- ============================================================================
-- Behavior Tree Conditions - Common condition functions
-- ============================================================================
-- Provides reusable condition functions for behavior trees.
-- All conditions return true/false.
--
-- Usage:
--   local Conditions = require "mvtk.enemies.ai.bt_conditions"
--   local BT = require "mvtk.enemies.ai.behavior_tree"
--
--   BT.condition(Conditions.player_in_range(200))

local M = {}

local Detection = require "mvtk.enemies.detection"
local SurfaceClassifier = require "mvtk.core.surface_classifier"

local FACING_WALL_GROUPS = SurfaceClassifier.RAYCAST.WALL
local LEDGE_GROUPS = SurfaceClassifier.RAYCAST.GROUND

-- ============================================================================
-- PLAYER DETECTION CONDITIONS
-- ============================================================================

--- Check if player is within range
-- @param range Detection range in pixels
-- @return Condition function
function M.player_in_range(range)
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        local distance = vmath.length(player_pos - pos)
        context.blackboard.player_distance = distance
        context.blackboard.player_pos = player_pos
        return distance <= range
    end
end

--- Check if player is in attack range
-- @param range Attack range (optional, uses config)
-- @return Condition function
function M.player_in_attack_range(range)
    return function(context, dt)
        local attack_range = range or (context.config and context.config.attack_range) or 100
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        return vmath.length(player_pos - pos) <= attack_range
    end
end

--- Check if player is visible (line of sight)
-- @return Condition function
function M.player_visible()
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        return Detection.has_line_of_sight(pos, player_pos)
    end
end

--- Check if player is on same level (within vertical threshold)
-- @param threshold Vertical threshold in pixels (default 60)
-- @return Condition function
function M.player_on_same_level(threshold)
    threshold = threshold or 60
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        return math.abs(player_pos.y - pos.y) <= threshold
    end
end

--- Check if player is above
-- @param threshold Minimum height difference
-- @return Condition function
function M.player_above(threshold)
    threshold = threshold or 30
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        return (player_pos.y - pos.y) > threshold
    end
end

--- Check if player is below
-- @param threshold Minimum height difference
-- @return Condition function
function M.player_below(threshold)
    threshold = threshold or 30
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        return (pos.y - player_pos.y) > threshold
    end
end

--- Check if player is to the left
-- @return Condition function
function M.player_to_left()
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        return player_pos.x < pos.x
    end
end

--- Check if player is to the right
-- @return Condition function
function M.player_to_right()
    return function(context, dt)
        local pos = go.get_position()
        local player_pos = Detection.get_player_position()
        if not player_pos then return false end

        return player_pos.x > pos.x
    end
end

-- ============================================================================
-- HEALTH CONDITIONS
-- ============================================================================

--- Check if health is above percentage
-- @param percent Health percentage (0-1)
-- @return Condition function
function M.health_above(percent)
    return function(context, dt)
        local health = context.health or 0
        local max_health = context.max_health or 1
        return (health / max_health) > percent
    end
end

--- Check if health is below percentage
-- @param percent Health percentage (0-1)
-- @return Condition function
function M.health_below(percent)
    return function(context, dt)
        local health = context.health or 0
        local max_health = context.max_health or 1
        return (health / max_health) < percent
    end
end

--- Check if at full health
-- @return Condition function
function M.at_full_health()
    return function(context, dt)
        return context.health == context.max_health
    end
end

-- ============================================================================
-- STATE CONDITIONS
-- ============================================================================

--- Check if enemy is grounded
-- @return Condition function
function M.is_grounded()
    return function(context, dt)
        return context.grounded == true
    end
end

--- Check if enemy is airborne
-- @return Condition function
function M.is_airborne()
    return function(context, dt)
        return context.grounded == false
    end
end

--- Check if enemy is stunned
-- @return Condition function
function M.is_stunned()
    return function(context, dt)
        return context.stunned == true
    end
end

--- Check if enemy can attack (not on cooldown)
-- @return Condition function
function M.can_attack()
    return function(context, dt)
        local cooldown = context.attack_cooldown or 0
        return cooldown <= 0
    end
end

--- Check if enemy is invincible
-- @return Condition function
function M.is_invincible()
    return function(context, dt)
        return context.invincible == true
    end
end

--- Check if specific ability is ready
-- @param ability_name Name of the ability
-- @return Condition function
function M.ability_ready(ability_name)
    return function(context, dt)
        local abilities = context.abilities or {}
        local ability = abilities[ability_name]
        if not ability then return false end
        return (ability.cooldown or 0) <= 0
    end
end

-- ============================================================================
-- POSITION CONDITIONS
-- ============================================================================

--- Check if near home position
-- @param threshold Distance threshold
-- @return Condition function
function M.near_home(threshold)
    threshold = threshold or 50
    return function(context, dt)
        local pos = go.get_position()
        local home = context.home_position or context.spawn_position
        if not home then return true end

        return vmath.length(pos - home) <= threshold
    end
end

--- Check if too far from home
-- @param max_distance Maximum distance from home
-- @return Condition function
function M.too_far_from_home(max_distance)
    max_distance = max_distance or 400
    return function(context, dt)
        local pos = go.get_position()
        local home = context.home_position or context.spawn_position
        if not home then return false end

        return vmath.length(pos - home) > max_distance
    end
end

--- Check if at patrol boundary
-- @param patrol_distance Distance from home
-- @return Condition function
function M.at_patrol_boundary(patrol_distance)
    patrol_distance = patrol_distance or 200
    return function(context, dt)
        local pos = go.get_position()
        local home = context.home_position or context.spawn_position
        if not home then return false end

        return vmath.length(pos - home) >= patrol_distance
    end
end

--- Check if facing wall
-- @param distance Check distance
-- @return Condition function
function M.facing_wall(distance)
    distance = distance or 20
    return function(context, dt)
        local pos = go.get_position()
        local facing = context.facing or 1
        local end_pos = vmath.vector3(pos.x + (distance * facing), pos.y, 0)

        local result = physics.raycast(pos, end_pos, FACING_WALL_GROUPS)
        return SurfaceClassifier.is_wall_collision(result)
    end
end

--- Check if at ledge
-- @param distance Check distance ahead
-- @return Condition function
function M.at_ledge(distance)
    distance = distance or 20
    return function(context, dt)
        local pos = go.get_position()
        local facing = context.facing or 1
        local start = vmath.vector3(pos.x + (distance * facing), pos.y, 0)
        local end_pos = vmath.vector3(start.x, pos.y - 30, 0)

        local result = physics.raycast(start, end_pos, LEDGE_GROUPS)
        return not SurfaceClassifier.is_ground_collision(result)  -- No walkable surface = ledge
    end
end

-- ============================================================================
-- GROUP CONDITIONS
-- ============================================================================

--- Check if has nearby allies
-- @param range Detection range
-- @param min_count Minimum ally count
-- @return Condition function
function M.has_allies(range, min_count)
    range = range or 200
    min_count = min_count or 1
    return function(context, dt)
        local ally_count = context.blackboard.ally_count or 0
        return ally_count >= min_count
    end
end

--- Check if is group leader
-- @return Condition function
function M.is_group_leader()
    return function(context, dt)
        return context.is_leader == true
    end
end

--- Check if leader is attacking
-- @return Condition function
function M.leader_is_attacking()
    return function(context, dt)
        return context.blackboard.leader_attacking == true
    end
end

-- ============================================================================
-- RANDOM CONDITIONS
-- ============================================================================

--- Random chance condition
-- @param chance Probability (0-1)
-- @return Condition function
function M.random_chance(chance)
    return function(context, dt)
        return math.random() < chance
    end
end

--- Periodic check (returns true once per interval)
-- @param interval Time between true results
-- @return Condition function
function M.periodic(interval)
    local last_true = 0
    return function(context, dt)
        local current_time = context.blackboard.elapsed_time or 0
        context.blackboard.elapsed_time = current_time + dt

        if current_time - last_true >= interval then
            last_true = current_time
            return true
        end
        return false
    end
end

-- ============================================================================
-- COMBO CONDITIONS
-- ============================================================================

--- All conditions must be true (AND)
-- @param ... Condition functions
-- @return Condition function
function M.all(...)
    local conditions = {...}
    return function(context, dt)
        for _, cond in ipairs(conditions) do
            if not cond(context, dt) then
                return false
            end
        end
        return true
    end
end

--- Any condition must be true (OR)
-- @param ... Condition functions
-- @return Condition function
function M.any(...)
    local conditions = {...}
    return function(context, dt)
        for _, cond in ipairs(conditions) do
            if cond(context, dt) then
                return true
            end
        end
        return false
    end
end

--- Negate condition
-- @param condition Condition function to negate
-- @return Condition function
function M.not_condition(condition)
    return function(context, dt)
        return not condition(context, dt)
    end
end

return M

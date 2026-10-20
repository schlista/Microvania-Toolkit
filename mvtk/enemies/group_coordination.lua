-- mvtk/enemies/group_coordination.lua
-- ============================================================================
-- Group Coordination System - Tactical Enemy Coordination
-- ============================================================================
-- Enables enemies to work together tactically: flanking, coordinated attacks,
-- formation movement, and pack behavior.
--
-- Usage:
--   local GroupCoord = require "mvtk.enemies.group_coordination"
--
--   -- Register enemy with a group
--   GroupCoord.join_group(enemy_id, "pack_alpha")
--
--   -- Get flank position
--   local pos = GroupCoord.get_flank_position(enemy_id, player_pos)
--
--   -- Check if should attack (coordinated)
--   if GroupCoord.should_attack(enemy_id) then ... end

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })

local M = {}

local EnemyManager = require "mvtk.enemies.enemy_manager"
local Detection = require "mvtk.enemies.detection"

-- ============================================================================
-- GROUP REGISTRY
-- ============================================================================

local groups = {}           -- group_id -> group_data
local enemy_groups = {}     -- enemy_id -> group_id
local next_group_id = 1

-- Debug logging
local log = Util.make_debug_log("[GROUP_COORD]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.enemies)
end)

-- ============================================================================
-- GROUP MANAGEMENT
-- ============================================================================

--- Create a new coordination group
-- @param group_id Optional group identifier (auto-generated if nil)
-- @param config Group configuration
-- @return group_id
function M.create_group(group_id, config)
    group_id = group_id or ("group_" .. next_group_id)
    next_group_id = next_group_id + 1

    config = config or {}

    groups[group_id] = {
        id = group_id,
        members = {},           -- enemy_id -> true
        leader = nil,           -- Leader enemy_id
        formation = config.formation or "none",
        attack_mode = config.attack_mode or "individual",  -- individual, coordinated, wave
        flank_style = config.flank_style or "surround",    -- surround, pincer, line

        -- Coordination state
        attack_signal = false,
        attack_cooldown = 0,
        last_attack_time = 0,
        wave_index = 0,

        -- Formation data
        formation_center = nil,
        formation_facing = 1,

        -- Config
        max_simultaneous_attackers = config.max_attackers or 2,
        attack_interval = config.attack_interval or 1.0,
        coordination_range = config.coordination_range or 300,
        formation_spacing = config.formation_spacing or 60,
    }

    log("Created group:", group_id)
    return group_id
end

--- Join an enemy to a group
-- @param enemy_id Enemy identifier
-- @param group_id Group to join (created if doesn't exist)
function M.join_group(enemy_id, group_id)
    if not enemy_id then return end

    -- Leave current group if in one
    M.leave_group(enemy_id)

    -- Create group if needed
    if not groups[group_id] then
        M.create_group(group_id)
    end

    local group = groups[group_id]
    group.members[enemy_id] = true
    enemy_groups[enemy_id] = group_id

    -- Assign leader if first member
    if not group.leader then
        group.leader = enemy_id
    end

    log("Enemy", enemy_id, "joined group", group_id)
end

--- Leave current group
-- @param enemy_id Enemy identifier
function M.leave_group(enemy_id)
    local group_id = enemy_groups[enemy_id]
    if not group_id then return end

    local group = groups[group_id]
    if group then
        group.members[enemy_id] = nil

        -- Reassign leader if needed
        if group.leader == enemy_id then
            group.leader = nil
            for member_id, _ in pairs(group.members) do
                group.leader = member_id
                break
            end
        end

        -- Delete empty groups
        if not next(group.members) then
            groups[group_id] = nil
            log("Deleted empty group:", group_id)
        end
    end

    enemy_groups[enemy_id] = nil
    log("Enemy", enemy_id, "left group", group_id)
end

--- Get group for an enemy
-- @param enemy_id Enemy identifier
-- @return Group data or nil
function M.get_group(enemy_id)
    local group_id = enemy_groups[enemy_id]
    return group_id and groups[group_id] or nil
end

--- Get all members of a group
-- @param group_id Group identifier
-- @return Table of enemy IDs
function M.get_members(group_id)
    local group = groups[group_id]
    if not group then return {} end

    local members = {}
    for enemy_id, _ in pairs(group.members) do
        table.insert(members, enemy_id)
    end
    return members
end

--- Check if enemy is group leader
-- @param enemy_id Enemy identifier
-- @return true if leader
function M.is_leader(enemy_id)
    local group = M.get_group(enemy_id)
    return group and group.leader == enemy_id
end

-- ============================================================================
-- FLANK POSITIONING
-- ============================================================================

--- Get optimal flank position for an enemy
-- @param enemy_id Enemy identifier
-- @param target_pos Target position (usually player)
-- @param base_distance Distance from target
-- @return Flank position vector
function M.get_flank_position(enemy_id, target_pos, base_distance)
    base_distance = base_distance or 100

    local group = M.get_group(enemy_id)
    if not group then
        -- No group - just return position offset to side
        local enemy = EnemyManager.get_enemy(enemy_id)
        if enemy and enemy.position then
            local side = enemy.position.x > target_pos.x and 1 or -1
            return vmath.vector3(
                target_pos.x + (side * base_distance),
                target_pos.y,
                0
            )
        end
        return target_pos
    end

    -- Get member index in group
    local member_index = 0
    local total_members = 0
    for member_id, _ in pairs(group.members) do
        total_members = total_members + 1
        if member_id == enemy_id then
            member_index = total_members
        end
    end

    if total_members == 0 then return target_pos end

    -- Calculate flank position based on style
    local angle_offset = 0
    local distance = base_distance

    if group.flank_style == "surround" then
        -- Spread evenly around target
        local angle_step = (2 * math.pi) / total_members
        angle_offset = angle_step * (member_index - 1)

    elseif group.flank_style == "pincer" then
        -- Two groups on opposite sides
        local side = (member_index % 2 == 0) and math.pi or 0
        local sub_index = math.floor((member_index - 1) / 2)
        local spread = 0.3 * sub_index
        angle_offset = side + spread

    elseif group.flank_style == "line" then
        -- Line perpendicular to player direction
        local offset = (member_index - (total_members / 2) - 0.5) * group.formation_spacing
        return vmath.vector3(
            target_pos.x + offset,
            target_pos.y - base_distance,
            0
        )

    elseif group.flank_style == "arc" then
        -- Arc in front of player
        local arc_span = math.pi * 0.6  -- 108 degree arc
        local angle_step = arc_span / (total_members + 1)
        angle_offset = (math.pi / 2 - arc_span / 2) + (angle_step * member_index)
    end

    -- Calculate final position
    local x = target_pos.x + math.cos(angle_offset) * distance
    local y = target_pos.y + math.sin(angle_offset) * distance

    return vmath.vector3(x, y, 0)
end

--- Get all flank positions for a group
-- @param group_id Group identifier
-- @param target_pos Target position
-- @param base_distance Distance from target
-- @return Table of {enemy_id, position} pairs
function M.get_all_flank_positions(group_id, target_pos, base_distance)
    local positions = {}
    local members = M.get_members(group_id)

    for _, enemy_id in ipairs(members) do
        local pos = M.get_flank_position(enemy_id, target_pos, base_distance)
        table.insert(positions, {
            enemy_id = enemy_id,
            position = pos
        })
    end

    return positions
end

-- ============================================================================
-- COORDINATED ATTACKS
-- ============================================================================

--- Signal group to attack
-- @param group_id_or_enemy_id Group ID or enemy ID
function M.signal_attack(group_id_or_enemy_id)
    local group_id = enemy_groups[group_id_or_enemy_id] or group_id_or_enemy_id
    local group = groups[group_id]
    if not group then return end

    group.attack_signal = true
    group.last_attack_time = os.clock()
    log("Attack signal for group:", group_id)
end

--- Clear attack signal
-- @param group_id Group identifier
function M.clear_attack_signal(group_id)
    local group = groups[group_id]
    if group then
        group.attack_signal = false
    end
end

--- Check if enemy should attack (based on coordination mode)
-- @param enemy_id Enemy identifier
-- @return true if enemy should attack now
function M.should_attack(enemy_id)
    local group = M.get_group(enemy_id)
    if not group then return true end  -- Solo enemies always can attack

    local mode = group.attack_mode

    if mode == "individual" then
        return true

    elseif mode == "coordinated" then
        -- Only attack when signal is given
        return group.attack_signal

    elseif mode == "wave" then
        -- Take turns attacking
        local members = {}
        local index = 0
        for member_id, _ in pairs(group.members) do
            index = index + 1
            members[index] = member_id
        end

        -- Current attacker based on wave index
        local current_attacker = members[(group.wave_index % #members) + 1]
        return enemy_id == current_attacker

    elseif mode == "limited" then
        -- Only N simultaneous attackers
        local attacking_count = 0
        for member_id, _ in pairs(group.members) do
            local member = EnemyManager.get_enemy(member_id)
            if member and member.state == "attack" then
                attacking_count = attacking_count + 1
            end
        end
        return attacking_count < group.max_simultaneous_attackers
    end

    return true
end

--- Advance wave index (call after attack completes)
-- @param group_id Group identifier
function M.advance_wave(group_id)
    local group = groups[group_id]
    if group then
        group.wave_index = group.wave_index + 1
    end
end

--- Notify group that an attack happened
-- @param enemy_id Attacking enemy ID
function M.notify_attack(enemy_id)
    local group = M.get_group(enemy_id)
    if not group then return end

    group.attack_cooldown = group.attack_interval
    group.attack_signal = false

    if group.attack_mode == "wave" then
        M.advance_wave(group.id)
    end
end

-- ============================================================================
-- FORMATION MOVEMENT
-- ============================================================================

local formations = {
    -- No formation - move independently
    none = function(members, center, facing)
        return {}
    end,

    -- Line formation perpendicular to facing
    line = function(members, center, facing, spacing)
        local positions = {}
        local count = #members
        local half = (count - 1) / 2

        for i, member_id in ipairs(members) do
            local offset = (i - 1 - half) * spacing
            positions[member_id] = vmath.vector3(
                center.x + offset,
                center.y,
                0
            )
        end

        return positions
    end,

    -- V formation (wedge)
    wedge = function(members, center, facing, spacing)
        local positions = {}
        local count = #members

        for i, member_id in ipairs(members) do
            local row = math.floor((i - 1) / 2)
            local side = ((i - 1) % 2 == 0) and 1 or -1
            if i == 1 then side = 0 end

            positions[member_id] = vmath.vector3(
                center.x + (side * row * spacing),
                center.y - (row * spacing * 0.7),
                0
            )
        end

        return positions
    end,

    -- Circle formation
    circle = function(members, center, facing, spacing)
        local positions = {}
        local count = #members
        local radius = spacing * count / (2 * math.pi)

        for i, member_id in ipairs(members) do
            local angle = (2 * math.pi / count) * (i - 1)
            positions[member_id] = vmath.vector3(
                center.x + math.cos(angle) * radius,
                center.y + math.sin(angle) * radius,
                0
            )
        end

        return positions
    end,

    -- Square/box formation
    box = function(members, center, facing, spacing)
        local positions = {}
        local count = #members
        local side_count = math.ceil(math.sqrt(count))

        for i, member_id in ipairs(members) do
            local row = math.floor((i - 1) / side_count)
            local col = (i - 1) % side_count
            local offset_x = (col - (side_count - 1) / 2) * spacing
            local offset_y = (row - (side_count - 1) / 2) * spacing

            positions[member_id] = vmath.vector3(
                center.x + offset_x,
                center.y + offset_y,
                0
            )
        end

        return positions
    end,
}

--- Get formation positions for a group
-- @param group_id Group identifier
-- @return Table of enemy_id -> position
function M.get_formation_positions(group_id)
    local group = groups[group_id]
    if not group then return {} end

    local formation_fn = formations[group.formation]
    if not formation_fn then return {} end

    -- Get current members
    local members = M.get_members(group_id)
    if #members == 0 then return {} end

    -- Use leader position as center, or group center
    local center = group.formation_center
    if not center then
        if group.leader then
            local leader = EnemyManager.get_enemy(group.leader)
            if leader and leader.position then
                center = leader.position
            end
        end
    end

    if not center then return {} end

    return formation_fn(members, center, group.formation_facing, group.formation_spacing)
end

--- Set formation center position
-- @param group_id Group identifier
-- @param center_pos Center position
-- @param facing Facing direction (1 or -1)
function M.set_formation_center(group_id, center_pos, facing)
    local group = groups[group_id]
    if group then
        group.formation_center = center_pos
        group.formation_facing = facing or 1
    end
end

-- ============================================================================
-- ALLY AWARENESS
-- ============================================================================

--- Get nearby allies for an enemy
-- @param enemy_id Enemy identifier
-- @param range Detection range
-- @return List of ally enemy data
function M.get_nearby_allies(enemy_id, range)
    range = range or 200

    local enemy = EnemyManager.get_enemy(enemy_id)
    if not enemy or not enemy.position then return {} end

    local group_id = enemy_groups[enemy_id]
    local allies = {}

    local nearby = EnemyManager.get_enemies_in_range(enemy.position, range)

    for _, entry in ipairs(nearby) do
        local other = entry.enemy
        if other.id ~= enemy_id and other.alive then
            -- Check if same group or just nearby
            local other_group = enemy_groups[other.id]
            if not group_id or other_group == group_id then
                table.insert(allies, {
                    enemy = other,
                    distance = entry.distance
                })
            end
        end
    end

    return allies
end

--- Count nearby allies
-- @param enemy_id Enemy identifier
-- @param range Detection range
-- @return Number of nearby allies
function M.count_allies(enemy_id, range)
    return #M.get_nearby_allies(enemy_id, range)
end

--- Check if any ally is attacking
-- @param enemy_id Enemy identifier
-- @param range Check range
-- @return true if an ally is currently attacking
function M.ally_is_attacking(enemy_id, range)
    local allies = M.get_nearby_allies(enemy_id, range)

    for _, ally_data in ipairs(allies) do
        local ally = ally_data.enemy
        if ally.state == "attack" or ally.state == "charging" then
            return true
        end
    end

    return false
end

-- ============================================================================
-- UPDATE
-- ============================================================================

--- Update all groups (call once per frame from game manager)
-- @param dt Delta time
function M.update(dt)
    for group_id, group in pairs(groups) do
        -- Update attack cooldown
        if group.attack_cooldown > 0 then
            group.attack_cooldown = group.attack_cooldown - dt
        end

        -- Auto-clear attack signal after interval
        if group.attack_signal then
            local elapsed = os.clock() - group.last_attack_time
            if elapsed > 0.5 then
                group.attack_signal = false
            end
        end

        -- Clean up dead members
        for enemy_id, _ in pairs(group.members) do
            local enemy = EnemyManager.get_enemy(enemy_id)
            if not enemy or not enemy.alive then
                M.leave_group(enemy_id)
            end
        end
    end
end

--- Clean up all groups
function M.cleanup()
    groups = {}
    enemy_groups = {}
    next_group_id = 1
end

-- ============================================================================
-- AUTO-GROUPING
-- ============================================================================

--- Auto-create groups based on enemy proximity and type
-- @param room_id Room identifier
-- @param grouping_range Distance to consider enemies as group
function M.auto_group_room(room_id, grouping_range)
    grouping_range = grouping_range or 200

    local enemies = EnemyManager.get_all_enemies()
    local processed = {}

    for enemy_id, enemy in pairs(enemies) do
        if enemy.room_id == room_id and enemy.alive and not processed[enemy_id] then
            -- Find nearby enemies of same type
            local nearby = EnemyManager.get_enemies_in_range(enemy.position, grouping_range)
            local group_members = {enemy_id}
            processed[enemy_id] = true

            for _, entry in ipairs(nearby) do
                local other = entry.enemy
                if not processed[other.id] and other.type_id == enemy.type_id then
                    table.insert(group_members, other.id)
                    processed[other.id] = true
                end
            end

            -- Create group if multiple members
            if #group_members > 1 then
                local group_id = M.create_group(nil, {
                    attack_mode = "wave",
                    flank_style = "surround"
                })

                for _, member_id in ipairs(group_members) do
                    M.join_group(member_id, group_id)
                end
            end
        end
    end
end

return M

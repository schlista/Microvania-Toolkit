-- mvtk/bosses/boss_minions.lua
-- ============================================================================
-- Boss Minion Summoning System
-- ============================================================================
-- Handles boss minion spawning, tracking, and coordination.
--
-- Usage:
--   local BossMinions = require "mvtk.bosses.boss_minions"
--
--   BossMinions.setup_boss("forest_boss", {
--       summon_configs = {
--           small_adds = { enemy_type = "forest_sprite", count = 3 },
--           large_add = { enemy_type = "forest_treant", count = 1 },
--       },
--       max_minions = 6,
--   })
--
--   BossMinions.summon(boss_id, "small_adds")

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config")

local M = {}

local EnemyManager = Util.require_module("mvtk.enemies.enemy_manager")
local GroupCoordination = Util.require_module("mvtk.enemies.group_coordination")

-- ============================================================================
-- DATA STRUCTURES
-- ============================================================================

local boss_minions = {}  -- boss_id -> minion_data

-- Debug logging
local log = Util.make_debug_log("[BOSS_MINIONS]", function()
    return Debug.global and Debug.global.enable
end)

-- ============================================================================
-- SETUP
-- ============================================================================

--- Setup minion system for a boss
-- @param boss_id Boss identifier
-- @param config Minion configuration
function M.setup_boss(boss_id, config)
    config = config or {}

    boss_minions[boss_id] = {
        boss_id = boss_id,
        boss_url = nil,
        boss_position = nil,

        -- Summon configurations
        summon_configs = config.summon_configs or {},

        -- Limits
        max_minions = config.max_minions or 10,
        max_per_type = config.max_per_type or {},

        -- Active minions
        active_minions = {},  -- enemy_id -> minion_data
        minion_count = 0,
        type_counts = {},

        -- Spawn settings
        spawn_radius = config.spawn_radius or 150,
        spawn_offset_y = config.spawn_offset_y or 0,
        spawn_animation = config.spawn_animation or "summon",

        -- Behavior
        tether_to_boss = config.tether_to_boss or false,
        tether_range = config.tether_range or 400,
        despawn_on_boss_death = config.despawn_on_boss_death ~= false,
        enrage_on_boss_low = config.enrage_on_boss_low or false,

        -- Callbacks
        on_minion_spawned = config.on_minion_spawned,
        on_minion_killed = config.on_minion_killed,
        on_all_minions_killed = config.on_all_minions_killed,

        -- State
        summon_cooldowns = {},
        group_id = nil,
    }

    -- Create coordination group for minions
    boss_minions[boss_id].group_id = GroupCoordination.create_group("boss_minions_" .. boss_id, {
        attack_mode = "wave",
        flank_style = "surround"
    })

    log("Setup minion system for boss:", boss_id)
end

--- Register boss game object
-- @param boss_id Boss identifier
-- @param boss_url Boss URL
function M.register_boss(boss_id, boss_url)
    local data = boss_minions[boss_id]
    if data then
        data.boss_url = boss_url
        data.boss_position = go.get_position(boss_url)
    end
end

-- ============================================================================
-- SUMMONING
-- ============================================================================

--- Summon minions
-- @param boss_id Boss identifier
-- @param summon_id Summon configuration ID
-- @param override_config Optional config overrides
-- @return Table of spawned enemy IDs
function M.summon(boss_id, summon_id, override_config)
    local data = boss_minions[boss_id]
    if not data then
        log("ERROR: Boss not setup:", boss_id)
        return {}
    end

    local summon_config = data.summon_configs[summon_id]
    if not summon_config then
        log("ERROR: Summon config not found:", summon_id)
        return {}
    end

    -- Check cooldown
    local cooldown = data.summon_cooldowns[summon_id] or 0
    if cooldown > 0 then
        log("Summon on cooldown:", summon_id)
        return {}
    end

    -- Apply overrides
    local config = {}
    for k, v in pairs(summon_config) do
        config[k] = v
    end
    if override_config then
        for k, v in pairs(override_config) do
            config[k] = v
        end
    end

    local enemy_type = config.enemy_type
    local count = config.count or 1

    -- Check limits
    local max_total = data.max_minions
    local max_type = data.max_per_type[enemy_type] or max_total

    local current_total = data.minion_count
    local current_type = data.type_counts[enemy_type] or 0

    local can_spawn = math.min(
        count,
        max_total - current_total,
        max_type - current_type
    )

    if can_spawn <= 0 then
        log("Minion limit reached for:", enemy_type)
        return {}
    end

    -- Get spawn positions
    local spawn_positions = M.get_spawn_positions(data, can_spawn, config)

    -- Spawn minions
    local spawned = {}
    for i, pos in ipairs(spawn_positions) do
        local enemy_id = M.spawn_minion(data, enemy_type, pos, config)
        if enemy_id then
            table.insert(spawned, enemy_id)
        end
    end

    -- Set cooldown
    if config.cooldown then
        data.summon_cooldowns[summon_id] = config.cooldown
    end

    -- Play summon effect
    if config.effect then
        M.play_summon_effect(data, config.effect)
    end

    log("Summoned", #spawned, enemy_type, "for boss", boss_id)

    return spawned
end

--- Spawn a single minion
function M.spawn_minion(data, enemy_type, position, config)
    -- Spawn through enemy manager
    local enemy_config = {
        room_id = data.room_id,
        summoner = data.boss_id,
        is_boss_minion = true,
        health_multiplier = config.health_mult or 1.0,
        damage_multiplier = config.damage_mult or 1.0,
    }

    local enemy_id = EnemyManager.spawn_enemy(enemy_type, position, enemy_config)
    if not enemy_id then return nil end

    -- Track minion
    data.active_minions[enemy_id] = {
        enemy_id = enemy_id,
        enemy_type = enemy_type,
        spawn_time = os.clock(),
        position = position,
    }

    data.minion_count = data.minion_count + 1
    data.type_counts[enemy_type] = (data.type_counts[enemy_type] or 0) + 1

    -- Add to coordination group
    GroupCoordination.join_group(enemy_id, data.group_id)

    -- Callback
    if data.on_minion_spawned then
        data.on_minion_spawned(enemy_id, enemy_type)
    end

    return enemy_id
end

--- Get spawn positions around boss
function M.get_spawn_positions(data, count, config)
    local positions = {}
    local boss_pos = data.boss_position or vmath.vector3()
    local radius = config.spawn_radius or data.spawn_radius
    local offset_y = config.spawn_offset_y or data.spawn_offset_y

    -- Predefined spawn points
    if config.spawn_points then
        for i = 1, math.min(count, #config.spawn_points) do
            local point = config.spawn_points[i]
            table.insert(positions, vmath.vector3(point.x, point.y, 0))
        end
        return positions
    end

    -- Circular spawn
    if config.spawn_pattern == "circle" then
        local angle_step = (2 * math.pi) / count
        for i = 1, count do
            local angle = angle_step * (i - 1)
            local pos = vmath.vector3(
                boss_pos.x + math.cos(angle) * radius,
                boss_pos.y + math.sin(angle) * radius + offset_y,
                0
            )
            table.insert(positions, pos)
        end
        return positions
    end

    -- Line spawn
    if config.spawn_pattern == "line" then
        local spacing = config.spacing or 60
        local start_x = boss_pos.x - (spacing * (count - 1) / 2)
        for i = 1, count do
            local pos = vmath.vector3(
                start_x + spacing * (i - 1),
                boss_pos.y + offset_y,
                0
            )
            table.insert(positions, pos)
        end
        return positions
    end

    -- Random spawn (default)
    for i = 1, count do
        local angle = math.random() * 2 * math.pi
        local dist = radius * (0.5 + math.random() * 0.5)
        local pos = vmath.vector3(
            boss_pos.x + math.cos(angle) * dist,
            boss_pos.y + math.sin(angle) * dist + offset_y,
            0
        )
        table.insert(positions, pos)
    end

    return positions
end

--- Play summon visual effect
function M.play_summon_effect(data, effect_type)
    local boss_pos = data.boss_position or vmath.vector3()

    if effect_type == "portal" then
        factory.create("#summon_portal_factory", boss_pos)
    elseif effect_type == "explosion" then
        factory.create("#summon_explosion_factory", boss_pos)
    elseif effect_type == "magic_circle" then
        factory.create("#magic_circle_factory", boss_pos)
    end
end

-- ============================================================================
-- MINION MANAGEMENT
-- ============================================================================

--- Kill all minions
-- @param boss_id Boss identifier
function M.kill_all_minions(boss_id)
    local data = boss_minions[boss_id]
    if not data then return end

    for enemy_id, _ in pairs(data.active_minions) do
        local enemy = EnemyManager.get_enemy(enemy_id)
        if enemy and enemy.alive then
            EnemyManager.kill_enemy(enemy_id, "boss_command")
        end
    end

    log("Killed all minions for boss:", boss_id)
end

--- Despawn all minions (no drops/xp)
-- @param boss_id Boss identifier
function M.despawn_all_minions(boss_id)
    local data = boss_minions[boss_id]
    if not data then return end

    for enemy_id, _ in pairs(data.active_minions) do
        EnemyManager.remove_enemy(enemy_id)
        M.on_minion_removed(boss_id, enemy_id)
    end

    log("Despawned all minions for boss:", boss_id)
end

--- Enrage all minions (increase stats)
-- @param boss_id Boss identifier
-- @param multiplier Stat multiplier
function M.enrage_minions(boss_id, multiplier)
    local data = boss_minions[boss_id]
    if not data then return end

    multiplier = multiplier or 1.5

    for enemy_id, _ in pairs(data.active_minions) do
        local enemy = EnemyManager.get_enemy(enemy_id)
        if enemy and enemy.alive then
            -- Boost stats
            enemy.config.damage = math.floor(enemy.config.damage * multiplier)
            enemy.config.speed = math.floor(enemy.config.speed * multiplier)

            -- Visual indicator
            if enemy.url then
                pcall(msg.post, enemy.url, "enrage", {multiplier = multiplier})
            end
        end
    end

    log("Enraged minions for boss:", boss_id, "Multiplier:", multiplier)
end

--- Handle minion death notification
-- @param boss_id Boss identifier
-- @param enemy_id Dead minion ID
function M.on_minion_killed(boss_id, enemy_id)
    local data = boss_minions[boss_id]
    if not data then return end

    local minion = data.active_minions[enemy_id]
    if not minion then return end

    -- Update counts
    data.minion_count = data.minion_count - 1
    local enemy_type = minion.enemy_type
    data.type_counts[enemy_type] = (data.type_counts[enemy_type] or 1) - 1

    -- Remove from tracking
    data.active_minions[enemy_id] = nil

    -- Remove from coordination group
    GroupCoordination.leave_group(enemy_id)

    -- Callback
    if data.on_minion_killed then
        data.on_minion_killed(enemy_id, enemy_type)
    end

    -- Check if all minions dead
    if data.minion_count <= 0 then
        if data.on_all_minions_killed then
            data.on_all_minions_killed()
        end

        pcall(msg.post, "/game_manager#game_manager", "boss_minions_cleared", {
            boss_id = boss_id
        })
    end

    log("Minion killed:", enemy_id, "Remaining:", data.minion_count)
end

--- Handle minion removal (non-death)
function M.on_minion_removed(boss_id, enemy_id)
    local data = boss_minions[boss_id]
    if not data then return end

    local minion = data.active_minions[enemy_id]
    if not minion then return end

    data.minion_count = data.minion_count - 1
    local enemy_type = minion.enemy_type
    data.type_counts[enemy_type] = (data.type_counts[enemy_type] or 1) - 1

    data.active_minions[enemy_id] = nil

    -- Remove from coordination group
    GroupCoordination.leave_group(enemy_id)
end

-- ============================================================================
-- UPDATE
-- ============================================================================

--- Update minion system
-- @param dt Delta time
function M.update(dt)
    for boss_id, data in pairs(boss_minions) do
        -- Update boss position
        if data.boss_url then
            data.boss_position = go.get_position(data.boss_url)
        end

        -- Update cooldowns
        for summon_id, cooldown in pairs(data.summon_cooldowns) do
            if cooldown > 0 then
                data.summon_cooldowns[summon_id] = cooldown - dt
            end
        end

        -- Check tethered minions
        if data.tether_to_boss and data.boss_position then
            for enemy_id, minion in pairs(data.active_minions) do
                local enemy = EnemyManager.get_enemy(enemy_id)
                if enemy and enemy.alive and enemy.position then
                    local distance = vmath.length(enemy.position - data.boss_position)
                    if distance > data.tether_range then
                        -- Pull minion back toward boss
                        local dir = vmath.normalize(data.boss_position - enemy.position)
                        enemy.position = enemy.position + dir * 50 * dt
                    end
                end
            end
        end

        -- Clean up dead minions
        for enemy_id, _ in pairs(data.active_minions) do
            local enemy = EnemyManager.get_enemy(enemy_id)
            if not enemy or not enemy.alive then
                M.on_minion_killed(boss_id, enemy_id)
            end
        end
    end
end

-- ============================================================================
-- QUERY
-- ============================================================================

--- Get minion count
function M.get_minion_count(boss_id)
    local data = boss_minions[boss_id]
    return data and data.minion_count or 0
end

--- Get active minions
function M.get_active_minions(boss_id)
    local data = boss_minions[boss_id]
    return data and data.active_minions or {}
end

--- Check if can summon more
function M.can_summon(boss_id, summon_id)
    local data = boss_minions[boss_id]
    if not data then return false end

    -- Check cooldown
    local cooldown = data.summon_cooldowns[summon_id] or 0
    if cooldown > 0 then return false end

    -- Check limit
    return data.minion_count < data.max_minions
end

-- ============================================================================
-- BOSS DEATH HANDLING
-- ============================================================================

--- Handle boss death
function M.on_boss_death(boss_id)
    local data = boss_minions[boss_id]
    if not data then return end

    if data.despawn_on_boss_death then
        M.despawn_all_minions(boss_id)
    end
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

function M.cleanup_boss(boss_id)
    local data = boss_minions[boss_id]
    if data then
        M.despawn_all_minions(boss_id)
        -- Note: Group auto-deletes when all members leave via on_minion_removed
        -- We explicitly set group_id to nil to release the reference
        data.group_id = nil
    end
    boss_minions[boss_id] = nil
end

function M.cleanup()
    for boss_id, _ in pairs(boss_minions) do
        M.cleanup_boss(boss_id)
    end
    boss_minions = {}
end

return M

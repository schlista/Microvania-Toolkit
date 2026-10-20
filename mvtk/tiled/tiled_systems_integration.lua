-- mvtk/tiled/tiled_systems_integration.lua
-- ============================================================================
-- Tiled Systems Integration - Connect all MVTK systems to Tiled editor
-- ============================================================================
-- Parses Tiled object layers and configures MVTK systems automatically.
-- Supports enemy spawning, behaviors, and boss mechanics.
--
-- Usage in Tiled:
--   Create objects in an "objects" or "systems" layer with these types:
--   - "enemy" - Spawn an enemy with template/behavior
--   - "enemy_group" - Spawn a coordinated group of enemies
--   - "boss_arena" - Define boss arena mechanics
--   - "boss" - Spawn a boss with all systems configured
--
-- Lua Usage:
--   local TiledSystems = require "mvtk.tiled.tiled_systems_integration"
--   TiledSystems.process_room(room_id, tiled_data)

local Util = require "mvtk.core.util"
local OP = require "mvtk.tiled.object_props"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })

local M = {}

-- System imports (defensive: these are optional subsystems)
local EnemyManager = Util.require_module("mvtk.enemies.enemy_manager")
local EnemyTemplates = Util.require_module("mvtk.enemies.enemy_templates")
local ComposedBehavior = Util.require_module("mvtk.enemies.behaviors.composed_behavior")
local GroupCoordination = Util.require_module("mvtk.enemies.group_coordination")
local BossArena = Util.require_module("mvtk.bosses.boss_arena")
local BossMinions = Util.require_module("mvtk.bosses.boss_minions")
local BossEnrage = Util.require_module("mvtk.bosses.boss_enrage")

-- Debug logging
local log = Util.make_debug_log("[TILED_SYSTEMS]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.tiled)
end)

-- ============================================================================
-- OBJECT TYPE HANDLERS
-- ============================================================================

local handlers = {}

-- ============================================================================
-- ENEMY HANDLER
-- ============================================================================
-- Tiled Properties:
--   type: "enemy"
--   enemy_type: string - Base enemy type (e.g., "slime")
--   template: string - Template ID from enemy_templates (e.g., "elite_slime")
--   behaviors: string - Comma-separated behavior IDs (e.g., "ground_patrol,melee_attack")
--   behavior_preset: string - Preset name (e.g., "basic_walker", "ranged_shooter")
--   facing: number - Initial facing direction (1 or -1)
--   patrol_distance: number - Patrol range from spawn
--   chase_range: number - Range to start chasing player
--   attack_range: number - Range to attack player
--   group_id: string - Group to join for coordination

handlers.enemy = function(obj, room_id)
    local pos = vmath.vector3(obj.x, obj.y, 0)
    local props = obj.properties or {}

    -- Determine enemy type
    local enemy_type = props.enemy_type or obj.name or "slime"

    -- Apply template if specified
    if props.template then
        local template_config = EnemyTemplates.resolve(props.template)
        if template_config then
            enemy_type = template_config.base_type or enemy_type
        end
    end

    -- Build spawn config
    local spawn_config = {
        room_id = room_id,
        spawned_from_tiled = true,
        facing = props.facing or 1,
        patrol_distance = props.patrol_distance,
        chase_range = props.chase_range,
        attack_range = props.attack_range,
    }

    -- Apply template modifiers
    if props.template then
        spawn_config.template_id = props.template
    end

    -- Create behavior tree from behaviors or preset
    if props.behavior_preset then
        local preset_fn = ComposedBehavior.presets[props.behavior_preset]
        if preset_fn then
            spawn_config.behavior_tree = preset_fn({
                chase_speed = props.chase_speed,
                patrol_speed = props.patrol_speed,
                attack_range = props.attack_range,
                patrol_distance = props.patrol_distance,
            })
        end
    elseif props.behaviors then
        local behavior_ids = {}
        for id in string.gmatch(props.behaviors, "[^,]+") do
            table.insert(behavior_ids, id:match("^%s*(.-)%s*$"))  -- trim whitespace
        end
        spawn_config.behavior_tree = ComposedBehavior.create(behavior_ids, {
            chase_speed = props.chase_speed,
            patrol_speed = props.patrol_speed,
            attack_range = props.attack_range,
        })
    end

    -- Spawn enemy
    local enemy_id = EnemyManager.spawn_enemy(enemy_type, pos, spawn_config)

    if enemy_id then
        -- Join group if specified
        if props.group_id then
            GroupCoordination.join_group(enemy_id, props.group_id)
        end

        log("Spawned enemy:", enemy_type, "at", obj.x, obj.y, "ID:", enemy_id)
    end

    return enemy_id
end

-- ============================================================================
-- ENEMY GROUP HANDLER
-- ============================================================================
-- Tiled Properties:
--   type: "enemy_group"
--   group_id: string - Group identifier
--   enemy_type: string - Enemy type for all members
--   count: number - Number of enemies to spawn
--   formation: string - "line", "wedge", "circle", "box"
--   spacing: number - Space between enemies
--   attack_mode: string - "individual", "coordinated", "wave", "limited"
--   flank_style: string - "surround", "pincer", "line", "arc"
--   behaviors: string - Shared behaviors for all members

handlers.enemy_group = function(obj, room_id)
    local pos = vmath.vector3(obj.x, obj.y, 0)
    local props = obj.properties or {}

    local group_id = props.group_id or ("group_" .. tostring(os.clock()))
    local enemy_type = props.enemy_type or "slime"
    local count = props.count or 3

    -- Create coordination group
    GroupCoordination.create_group(group_id, {
        attack_mode = props.attack_mode or "coordinated",
        flank_style = props.flank_style or "surround",
        formation = props.formation or "line",
    })

    -- Get formation positions
    local formation = props.formation or "line"
    local spacing = props.spacing or 60
    local positions = M.get_formation_positions(pos, count, formation, spacing)

    -- Spawn enemies
    local spawned = {}
    for i, spawn_pos in ipairs(positions) do
        local config = {
            room_id = room_id,
            spawned_from_tiled = true,
            group_id = group_id,
        }

        -- First enemy is leader
        if i == 1 then
            config.is_leader = true
        end

        -- Apply behaviors
        if props.behaviors then
            local behavior_ids = {}
            for id in string.gmatch(props.behaviors, "[^,]+") do
                table.insert(behavior_ids, id:match("^%s*(.-)%s*$"))
            end
            config.behavior_tree = ComposedBehavior.create(behavior_ids)
        end

        local enemy_id = EnemyManager.spawn_enemy(enemy_type, spawn_pos, config)
        if enemy_id then
            GroupCoordination.join_group(enemy_id, group_id)
            table.insert(spawned, enemy_id)
        end
    end

    log("Spawned enemy group:", group_id, "Count:", #spawned)

    return spawned
end

-- ============================================================================
-- BOSS ARENA HANDLER
-- ============================================================================
-- Tiled Properties:
--   type: "boss_arena"
--   arena_id: string - Arena identifier
--   phases: number - Number of boss phases
--   camera_lock: bool - Lock camera to the arena bounds
--   Additional arena behavior is authored through linked boss_phase,
--   arena_boundary, boss_weak_point, and
--   boss_add_spawner objects.

handlers.boss_arena = function(obj, room_id)
    local props = obj.properties or {}

    local arena_id = props.arena_id or ("arena_" .. room_id)
    local config = BossArena.create_from_tiled(props)

    -- Set arena bounds from object
    config.bounds = {
        x = obj.x,
        y = obj.y,
        width = obj.width or 800,
        height = obj.height or 600,
    }

    config.room_id = room_id

    BossArena.setup_arena(arena_id, config)

    log("Created boss arena:", arena_id)

    return arena_id
end

-- ============================================================================
-- BOSS HANDLER
-- ============================================================================
-- Tiled Properties:
--   type: "boss"
--   boss_id: string - Boss identifier
--   boss_type: string - Boss enemy type
--   arena_id: string - Link to boss_arena object
--   enrage_thresholds: string - Enrage configuration
--   summon_configs: string - Minion summon configuration

handlers.boss = function(obj, room_id)
    local pos = vmath.vector3(obj.x, obj.y, 0)
    local props = obj.properties or {}

    local boss_id = props.boss_id or obj.name or ("boss_" .. room_id)
    local boss_type = props.boss_type or "boss_generic"

    -- Setup enrage
    if props.enrage_thresholds then
        local enrage_config = BossEnrage.create_from_tiled(props)
        BossEnrage.setup_boss(boss_id, enrage_config)
    end

    -- Setup minions
    if props.summon_configs then
        local minion_config = M.parse_summon_configs(props.summon_configs, props)
        BossMinions.setup_boss(boss_id, minion_config)
    end

    -- Spawn boss
    local spawn_config = {
        room_id = room_id,
        boss_id = boss_id,
        is_boss = true,
        arena_id = props.arena_id,
        phases = tonumber(props.phases) or 3,
    }

    local enemy_id = EnemyManager.spawn_enemy(boss_type, pos, spawn_config)

    if enemy_id then
        -- Register with boss systems
        local boss_url = EnemyManager.get_enemy_url(enemy_id)
        if boss_url then
            if props.enrage_thresholds then
                BossEnrage.register_boss(boss_id, boss_url)
            end
            if props.summon_configs then
                BossMinions.register_boss(boss_id, boss_url)
            end
        end

        log("Spawned boss:", boss_id, "Type:", boss_type)
    end

    return boss_id, enemy_id
end

-- ============================================================================
-- HAZARD HANDLER
-- ============================================================================
-- Tiled Properties:
--   type: "hazard"
--   hazard_type: string - "floor_spikes", "lava_floor", "laser_beams", etc.
--   arena_id: string - Link to boss_arena (optional)
--   damage: number - Damage per tick
--   interval: number - Damage interval

handlers.hazard = function(obj, room_id)
    local props = obj.properties or {}

    local hazard_config = {
        hazard_type = props.hazard_type or "floor_spikes",
        damage = tonumber(props.damage) or 1,
        interval = tonumber(props.interval) or 0.5,
        position = vmath.vector3(obj.x, obj.y, 0),
        width = obj.width or 64,
        height = obj.height or 64,
        active_phases = props.active_phases,  -- e.g., "2,3"
    }

    -- If linked to arena, add to arena config
    if props.arena_id then
        -- Arena will manage this hazard
        hazard_config.arena_id = props.arena_id
    else
        -- Standalone hazard - spawn directly
        -- This would need a hazard factory
        log("Standalone hazard:", hazard_config.hazard_type)
    end

    return hazard_config
end

-- ============================================================================
-- SPAWN POINT HANDLER
-- ============================================================================
-- Tiled Properties:
--   type: "spawn_point"
--   spawn_id: string - Spawn point identifier
--   enemy_type: string - Enemy type to spawn
--   max_count: number - Maximum simultaneous spawns
--   respawn_delay: number - Time before respawn

handlers.spawn_point = function(obj, room_id)
    local props = obj.properties or {}

    local spawn_point = {
        id = props.spawn_id or obj.name,
        position = vmath.vector3(obj.x, obj.y, 0),
        enemy_type = props.enemy_type or "slime",
        max_count = tonumber(props.max_count) or 1,
        respawn_delay = tonumber(props.respawn_delay) or 5.0,
        behaviors = props.behaviors,
        template = props.template,
        room_id = room_id,
    }

    log("Registered spawn point:", spawn_point.id)

    return spawn_point
end


--- Process all objects in a Tiled room
-- @param room_id Room identifier
-- @param tiled_data Tiled map data (parsed from JSON/Lua)
-- @return Table of created objects/IDs
function M.process_room(room_id, tiled_data)
    if not tiled_data or not tiled_data.layers then
        log("No layers in tiled_data for room:", room_id)
        return {}
    end

    local results = {
        enemies = {},
        groups = {},
        arenas = {},
        bosses = {},
        spawn_points = {},
    }

    -- Process each layer
    for _, layer in ipairs(tiled_data.layers) do
        if layer.type == "objectgroup" then
            M.process_object_layer(room_id, layer, results)
        end
    end

    log("Processed room:", room_id,
        "Enemies:", #results.enemies,
        "Groups:", #results.groups)

    return results
end

--- Process a single object layer
function M.process_object_layer(room_id, layer, results)
    if not layer.objects then return end

    for _, obj in ipairs(layer.objects) do
        local obj_type = obj.type or (obj.properties and obj.properties.type)

        if obj_type and handlers[obj_type] then
            local result = handlers[obj_type](obj, room_id)

            -- Store result based on type
            if obj_type == "enemy" then
                table.insert(results.enemies, result)
            elseif obj_type == "enemy_group" then
                table.insert(results.groups, result)
            elseif obj_type == "boss_arena" then
                table.insert(results.arenas, result)
            elseif obj_type == "boss" then
                table.insert(results.bosses, result)
            elseif obj_type == "spawn_point" then
                table.insert(results.spawn_points, result)
            end
        end
    end
end

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

--- Get formation positions
function M.get_formation_positions(center, count, formation, spacing)
    local positions = {}

    if formation == "line" then
        local start_x = center.x - (spacing * (count - 1) / 2)
        for i = 1, count do
            table.insert(positions, vmath.vector3(
                start_x + spacing * (i - 1),
                center.y,
                0
            ))
        end

    elseif formation == "wedge" then
        table.insert(positions, vmath.vector3(center.x, center.y, 0))  -- Leader at front
        local row = 1
        local placed = 1
        while placed < count do
            local row_count = row + 1
            local start_x = center.x - (spacing * row / 2)
            for i = 1, row_count do
                if placed >= count then break end
                table.insert(positions, vmath.vector3(
                    start_x + spacing * (i - 1),
                    center.y - spacing * row,
                    0
                ))
                placed = placed + 1
            end
            row = row + 1
        end

    elseif formation == "circle" then
        local angle_step = (2 * math.pi) / count
        for i = 1, count do
            local angle = angle_step * (i - 1)
            table.insert(positions, vmath.vector3(
                center.x + math.cos(angle) * spacing,
                center.y + math.sin(angle) * spacing,
                0
            ))
        end

    elseif formation == "box" then
        local side = math.ceil(math.sqrt(count))
        local start_x = center.x - (spacing * (side - 1) / 2)
        local start_y = center.y - (spacing * (side - 1) / 2)
        local placed = 0
        for row = 0, side - 1 do
            for col = 0, side - 1 do
                if placed >= count then break end
                table.insert(positions, vmath.vector3(
                    start_x + spacing * col,
                    start_y + spacing * row,
                    0
                ))
                placed = placed + 1
            end
        end
    end

    return positions
end

--- Parse summon configs from Tiled string
-- Format: "small_adds:forest_sprite:3;large_add:forest_treant:1"
function M.parse_summon_configs(summon_str, props)
    local config = {
        summon_configs = {},
        max_minions = tonumber(props.max_minions) or 6,
    }

    for entry in string.gmatch(summon_str, "[^;]+") do
        local summon_id, enemy_type, count = entry:match("([^:]+):([^:]+):(%d+)")
        if summon_id then
            config.summon_configs[summon_id:match("^%s*(.-)%s*$")] = {
                enemy_type = enemy_type:match("^%s*(.-)%s*$"),
                count = tonumber(count) or 1,
            }
        end
    end

    return config
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

function M.cleanup_room(room_id)
end

function M.cleanup()
end

return M

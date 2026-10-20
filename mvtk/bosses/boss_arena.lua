-- mvtk/bosses/boss_arena.lua
-- ============================================================================
-- Boss Arena System - Phase-Specific Arena Mechanics
-- ============================================================================
-- Manages arena mechanics that change during boss phases:
-- hazards, platforms, environmental effects, and boundaries.
--
-- Usage:
--   local BossArena = require "mvtk.bosses.boss_arena"
--
--   BossArena.setup_arena("forest_boss", {
--       bounds = {x = 0, y = 0, width = 800, height = 400},
--       phases = {
--           [1] = { hazards = {"floor_spikes"}, platforms = {"center"} },
--           [2] = { hazards = {"floor_spikes", "falling_debris"}, platforms = {} },
--           [3] = { hazards = {"lava_floor"}, platforms = {"floating"} },
--       }
--   })

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config")
local ScreenShake = Util.require_module("mvtk.fx.screen_shake")

local M = {}
local Pause = require "mvtk.core.pause"

-- ============================================================================
-- DATA STRUCTURES
-- ============================================================================

local arenas = {}           -- arena_id -> arena_data
local active_arena = nil

-- Hazard types
M.HAZARD_TYPES = {
    FLOOR_SPIKES = "floor_spikes",
    CEILING_SPIKES = "ceiling_spikes",
    WALL_SPIKES = "wall_spikes",
    LAVA_FLOOR = "lava_floor",
    ACID_POOLS = "acid_pools",
    FALLING_DEBRIS = "falling_debris",
    LASER_BEAMS = "laser_beams",
    POISON_GAS = "poison_gas",
    ELECTRIC_FLOOR = "electric_floor",
    WIND_ZONES = "wind_zones",
    DARKNESS = "darkness",
}

-- Debug logging
local log = Util.make_debug_log("[BOSS_ARENA]", function()
    return Debug.global and Debug.global.enable
end)

local function optional_id(value)
    local id = Util.normalize_hash_string(value)
    if id and string.lower(id) == "none" then
        return nil
    end
    return id
end

-- ============================================================================
-- ARENA SETUP
-- ============================================================================

--- Setup a boss arena
-- @param arena_id Unique identifier
-- @param config Arena configuration
function M.setup_arena(arena_id, config)
    config = config or {}

    arenas[arena_id] = {
        id = arena_id,
        boss_id = config.boss_id,
        -- Room whose doors lock during the fight (arena ids are not rooms).
        room_id = config.room_id,

        -- Boundaries. bounds_authored = false means the placeholder below, which
        -- must never be used to confine a boss (see boss_confinement.lua).
        bounds = config.bounds or {x = 0, y = 0, width = 800, height = 400},
        bounds_authored = config.bounds ~= nil,
        -- Phase configurations
        phases = config.phases or {},
        current_phase = 0,

        -- Active elements
        active_hazards = {},
        active_platforms = {},
        active_effects = {},

        -- Hazard definitions
        hazard_configs = config.hazard_configs or {},
        platform_configs = config.platform_configs or {},

        -- Callbacks
        on_phase_change = config.on_phase_change,
        on_hazard_hit = config.on_hazard_hit,

        -- State
        locked = false,
        transition_timer = 0,
        in_transition = false,
    }

    log("Setup arena:", arena_id)
end

--- Activate an arena
-- @param arena_id Arena to activate
function M.activate_arena(arena_id)
    local arena = arenas[arena_id]
    if not arena then
        log("ERROR: Arena not found:", arena_id)
        return false
    end

    active_arena = arena
    arena.locked = true
    arena.current_phase = 0

    -- Lock arena doors
    M.lock_doors(arena)

    log("Activated arena:", arena_id)
    return true
end

--- Deactivate current arena
function M.deactivate_arena()
    if not active_arena then return end

    -- Clear all hazards and platforms
    M.clear_all_hazards()
    M.clear_all_platforms()
    M.clear_all_effects()

    -- Unlock doors
    M.unlock_doors(active_arena)

    active_arena.locked = false
    active_arena.current_phase = 0

    log("Deactivated arena:", active_arena.id)
    active_arena = nil
end

-- ============================================================================
-- PHASE MANAGEMENT
-- ============================================================================

--- Transition to a new phase
-- @param phase_number Phase number to transition to
-- @param transition_time Optional transition duration
function M.transition_to_phase(phase_number, transition_time)
    if Pause.get() then
        local arena = active_arena
        Pause.delay(0, function()
            if active_arena == arena then M.transition_to_phase(phase_number, transition_time) end
        end)
        return
    end
    if not active_arena then return end

    local phase_config = active_arena.phases[phase_number]
    if not phase_config then
        log("WARNING: Phase", phase_number, "not configured")
        return
    end

    transition_time = transition_time or phase_config.transition_time or 1.0

    log("Transitioning to phase", phase_number)

    active_arena.in_transition = true
    active_arena.transition_timer = transition_time

    -- Callback for phase change
    if active_arena.on_phase_change then
        active_arena.on_phase_change(active_arena.current_phase, phase_number)
    end

    -- Start transition effects
    if phase_config.transition_effect then
        M.play_transition_effect(phase_config.transition_effect)
    end

    -- Schedule phase application
    local arena = active_arena
    Pause.delay(transition_time, function()
        if active_arena == arena then M.apply_phase(phase_number) end
    end)
end

--- Apply a phase configuration
-- @param phase_number Phase number to apply
function M.apply_phase(phase_number)
    if not active_arena then return end

    local phase_config = active_arena.phases[phase_number]
    if not phase_config then return end

    active_arena.current_phase = phase_number
    active_arena.in_transition = false

    log("Applying phase", phase_number)

    -- Clear previous hazards/platforms
    M.clear_all_hazards()
    M.clear_all_platforms()

    -- Spawn new hazards
    if phase_config.hazards then
        for _, hazard_id in ipairs(phase_config.hazards) do
            M.spawn_hazard(hazard_id)
        end
    end

    -- Spawn new platforms
    if phase_config.platforms then
        for _, platform_id in ipairs(phase_config.platforms) do
            M.spawn_platform(platform_id)
        end
    end

    -- Apply effects
    if phase_config.effects then
        for _, effect_id in ipairs(phase_config.effects) do
            M.apply_effect(effect_id)
        end
    end

    -- Apply arena modifications
    if phase_config.bounds then
        M.set_arena_bounds(phase_config.bounds)
    end

    if phase_config.gravity then
        M.set_gravity(phase_config.gravity)
    end

    if phase_config.darkness then
        M.set_darkness(phase_config.darkness)
    end

    -- Notify
    pcall(msg.post, "main:/main_go#script", hash("arena_phase_changed"), {
        arena_id = active_arena.id,
        phase = phase_number
    })
end

-- ============================================================================
-- HAZARD MANAGEMENT
-- ============================================================================

--- Spawn a hazard
-- @param hazard_id Hazard identifier
-- @param override_config Optional config override
function M.spawn_hazard(hazard_id, override_config)
    if not active_arena then return end

    local config = active_arena.hazard_configs[hazard_id] or {}
    if override_config then
        for k, v in pairs(override_config) do
            config[k] = v
        end
    end

    local hazard = {
        id = hazard_id,
        type = config.type or hazard_id,
        active = true,
        timer = 0,
        config = config,
        game_objects = {},
    }

    -- Spawn hazard game objects based on type
    local spawn_fn = M.hazard_spawners[hazard.type]
    if spawn_fn then
        hazard.game_objects = spawn_fn(config, active_arena.bounds)
    end

    active_arena.active_hazards[hazard_id] = hazard

    log("Spawned hazard:", hazard_id)
end

--- Remove a hazard
-- @param hazard_id Hazard identifier
function M.remove_hazard(hazard_id)
    if not active_arena then return end

    local hazard = active_arena.active_hazards[hazard_id]
    if not hazard then return end

    -- Delete game objects
    for _, go_id in ipairs(hazard.game_objects) do
        pcall(function() go.delete(go_id) end)
    end

    active_arena.active_hazards[hazard_id] = nil

    log("Removed hazard:", hazard_id)
end

--- Clear all hazards
function M.clear_all_hazards()
    if not active_arena then return end

    for hazard_id, _ in pairs(active_arena.active_hazards) do
        M.remove_hazard(hazard_id)
    end
end

-- Hazard spawner functions
M.hazard_spawners = {
    floor_spikes = function(config, bounds)
        local objects = {}
        local count = config.count or 5
        local spacing = bounds.width / (count + 1)

        for i = 1, count do
            local pos = vmath.vector3(
                bounds.x + spacing * i,
                bounds.y,
                0
            )
            local id = factory.create("#floor_spike_factory", pos, nil, {
                damage = config.damage or 1,
                interval = config.interval or 2.0,
            })
            table.insert(objects, id)
        end

        return objects
    end,

    falling_debris = function(config, bounds)
        -- Falling debris is spawned dynamically during update
        return {}
    end,

    lava_floor = function(config, bounds)
        local pos = vmath.vector3(
            bounds.x + bounds.width / 2,
            bounds.y,
            0
        )
        local id = factory.create("#lava_floor_factory", pos, nil, {
            width = bounds.width,
            damage = config.damage or 2,
            rise_height = config.rise_height or 0,
        })
        return {id}
    end,

    laser_beams = function(config, bounds)
        local objects = {}
        local count = config.count or 3

        for i = 1, count do
            local y = bounds.y + (bounds.height / (count + 1)) * i
            local pos = vmath.vector3(bounds.x, y, 0)

            local id = factory.create("#laser_beam_factory", pos, nil, {
                width = bounds.width,
                damage = config.damage or 1,
                interval = config.interval or 3.0,
                telegraph_time = config.telegraph_time or 1.0,
            })
            table.insert(objects, id)
        end

        return objects
    end,

    poison_gas = function(config, bounds)
        local pos = vmath.vector3(
            bounds.x + bounds.width / 2,
            bounds.y + bounds.height / 2,
            0
        )
        local id = factory.create("#poison_gas_factory", pos, nil, {
            radius = config.radius or 200,
            damage = config.damage or 1,
            interval = config.interval or 1.0,
        })
        return {id}
    end,

    ceiling_spikes = function(config, bounds)
        local objects = {}
        local count = config.count or 5
        local spacing = bounds.width / (count + 1)

        for i = 1, count do
            local pos = vmath.vector3(
                bounds.x + spacing * i,
                bounds.y + bounds.height,
                0
            )
            local id = factory.create("#ceiling_spike_factory", pos, nil, {
                damage = config.damage or 1,
                interval = config.interval or 2.0,
                drop_speed = config.drop_speed or 400,
            })
            table.insert(objects, id)
        end

        return objects
    end,

    wall_spikes = function(config, bounds)
        local objects = {}
        local count = config.count or 4
        local spacing = bounds.height / (count + 1)
        local side = config.side or "both"

        for i = 1, count do
            local y = bounds.y + spacing * i
            if side == "left" or side == "both" then
                local pos = vmath.vector3(bounds.x, y, 0)
                local id = factory.create("#wall_spike_factory", pos, nil, {
                    damage = config.damage or 1,
                    interval = config.interval or 2.0,
                    direction = 1,
                })
                table.insert(objects, id)
            end
            if side == "right" or side == "both" then
                local pos = vmath.vector3(bounds.x + bounds.width, y, 0)
                local id = factory.create("#wall_spike_factory", pos, nil, {
                    damage = config.damage or 1,
                    interval = config.interval or 2.0,
                    direction = -1,
                })
                table.insert(objects, id)
            end
        end

        return objects
    end,

    acid_pools = function(config, bounds)
        local objects = {}
        local count = config.count or 3
        local spacing = bounds.width / (count + 1)
        local pool_width = config.pool_width or 80

        for i = 1, count do
            local pos = vmath.vector3(
                bounds.x + spacing * i,
                bounds.y,
                0
            )
            local id = factory.create("#acid_pool_factory", pos, nil, {
                width = pool_width,
                damage = config.damage or 1,
                interval = config.interval or 0.5,
            })
            table.insert(objects, id)
        end

        return objects
    end,
}

-- ============================================================================
-- PLATFORM MANAGEMENT
-- ============================================================================

--- Spawn a platform
-- @param platform_id Platform identifier
function M.spawn_platform(platform_id)
    if not active_arena then return end

    local config = active_arena.platform_configs[platform_id] or {}

    local platform = {
        id = platform_id,
        type = config.type or "static",
        active = true,
        config = config,
        game_object = nil,
    }

    -- Spawn platform game object
    local pos = vmath.vector3(
        config.x or (active_arena.bounds.x + active_arena.bounds.width / 2),
        config.y or (active_arena.bounds.y + active_arena.bounds.height / 2),
        0
    )

    platform.game_object = factory.create("#platform_factory", pos, nil, {
        width = config.width or 100,
        platform_type = hash(tostring(platform.type or "")),
        move_speed = config.move_speed,
        move_path = hash(tostring(config.move_path or "")),
    })

    active_arena.active_platforms[platform_id] = platform

    log("Spawned platform:", platform_id)
end

--- Remove a platform
-- @param platform_id Platform identifier
function M.remove_platform(platform_id)
    if not active_arena then return end

    local platform = active_arena.active_platforms[platform_id]
    if not platform then return end

    if platform.game_object then
        pcall(function() go.delete(platform.game_object) end)
    end

    active_arena.active_platforms[platform_id] = nil

    log("Removed platform:", platform_id)
end

--- Clear all platforms
function M.clear_all_platforms()
    if not active_arena then return end

    for platform_id, _ in pairs(active_arena.active_platforms) do
        M.remove_platform(platform_id)
    end
end

-- ============================================================================
-- EFFECTS MANAGEMENT
-- ============================================================================

--- Apply an arena effect
-- @param effect_id Effect identifier
function M.apply_effect(effect_id)
    if not active_arena then return end

    local effect_fn = M.effect_handlers[effect_id]
    if effect_fn then
        effect_fn(active_arena)
        active_arena.active_effects[effect_id] = true
        log("Applied effect:", effect_id)
    end
end

--- Remove an arena effect
-- @param effect_id Effect identifier
function M.remove_effect(effect_id)
    if not active_arena then return end

    local remove_fn = M.effect_removers[effect_id]
    if remove_fn then
        remove_fn(active_arena)
    end

    active_arena.active_effects[effect_id] = nil
    log("Removed effect:", effect_id)
end

--- Clear all effects
function M.clear_all_effects()
    if not active_arena then return end

    for effect_id, _ in pairs(active_arena.active_effects) do
        M.remove_effect(effect_id)
    end
end

-- Effect handlers
M.effect_handlers = {
    screen_shake = function(arena)
        pcall(msg.post, "/camera#camera", "shake", {intensity = 0.5, duration = -1})
    end,

    darkness = function(arena)
        pcall(msg.post, "main:/main_go#script", hash("set_darkness"), {level = 0.7})
    end,

    slow_motion = function(arena)
        pcall(msg.post, "main:/main_go#script", hash("set_timescale"), {scale = 0.5})
    end,

    low_gravity = function(arena)
        pcall(msg.post, "main:/main_go#script", hash("set_gravity"), {scale = 0.5})
    end,

    high_gravity = function(arena)
        pcall(msg.post, "main:/main_go#script", hash("set_gravity"), {scale = 1.5})
    end,

    rain = function(arena)
        pcall(msg.post, "/fx#weather", "start_rain", {intensity = 1.0})
    end,

    fire_bg = function(arena)
        pcall(msg.post, "/fx#background", "set_theme", {theme = "fire"})
    end,
}

M.effect_removers = {
    screen_shake = function(arena)
        pcall(msg.post, "/camera#camera", "stop_shake")
    end,

    darkness = function(arena)
        pcall(msg.post, "main:/main_go#script", hash("set_darkness"), {level = 0})
    end,

    slow_motion = function(arena)
        pcall(msg.post, "main:/main_go#script", hash("set_timescale"), {scale = 1.0})
    end,

    low_gravity = function(arena)
        pcall(msg.post, "main:/main_go#script", hash("set_gravity"), {scale = 1.0})
    end,

    high_gravity = function(arena)
        pcall(msg.post, "main:/main_go#script", hash("set_gravity"), {scale = 1.0})
    end,

    rain = function(arena)
        pcall(msg.post, "/fx#weather", "stop_rain")
    end,

    fire_bg = function(arena)
        pcall(msg.post, "/fx#background", "set_theme", {theme = "default"})
    end,
}

-- ============================================================================
-- ARENA MODIFICATIONS
-- ============================================================================

--- Lock arena doors
-- Locking uses the arena's ROOM id. Posting the arena id (e.g.
-- "pt4_arena_26") only logged "no door data"; BossManager.lock_arena already
-- locks by room, and a second lock of the same room is ignored.
function M.lock_doors(arena)
    if not (arena and arena.room_id) then return end
    pcall(msg.post, "main:/room_manager#script", hash("lock_room"), {
        room_id = arena.room_id,
        source = "boss_arena"
    })
end

--- Unlock arena doors
function M.unlock_doors(arena)
    if not (arena and arena.room_id) then return end
    pcall(msg.post, "main:/room_manager#script", hash("unlock_room"), {
        room_id = arena.room_id,
        source = "boss_arena"
    })
end

--- Set arena boundaries
function M.set_arena_bounds(bounds)
    if not active_arena then return end
    active_arena.bounds = bounds
    -- Update any boundary-dependent systems
end

--- Set gravity
function M.set_gravity(scale)
    pcall(msg.post, "main:/main_go#script", hash("set_gravity"), {scale = scale})
end

--- Set darkness level
function M.set_darkness(level)
    pcall(msg.post, "main:/main_go#script", hash("set_darkness"), {level = level})
end

--- Play transition effect
function M.play_transition_effect(effect_type)
    if effect_type == "flash" then
        pcall(msg.post, "/fx#screen", "flash", {color = vmath.vector4(1, 1, 1, 1), duration = 0.3})
    elseif effect_type == "shake" then
        pcall(msg.post, "/camera#camera", "shake", {intensity = 1.0, duration = 0.5})
    elseif effect_type == "fade" then
        pcall(msg.post, "/fx#screen", "fade", {duration = 0.5})
    end
end

-- ============================================================================
-- DYNAMIC HAZARDS
-- ============================================================================

--- Spawn falling debris at random position
function M.spawn_falling_debris(count)
    if not active_arena then return end

    count = count or 1
    local bounds = active_arena.bounds

    for i = 1, count do
        local x = bounds.x + math.random() * bounds.width
        local y = bounds.y + bounds.height + 50

        -- Telegraph
        pcall(msg.post, "/fx#warning", "show_warning", {
            x = x,
            y = bounds.y + bounds.height,
            duration = 0.5
        })

        -- Spawn debris after telegraph
        Pause.delay(0.5, function()
            factory.create("#debris_factory", vmath.vector3(x, y, 0), nil, {
                damage = 2,
                fall_speed = 400
            })
        end)
    end
end

--- Trigger floor sweep hazard
-- @param direction 1 for left-to-right, -1 for right-to-left
-- @param height Height of the sweep
function M.trigger_floor_sweep(direction, height)
    if not active_arena then return end

    direction = direction or 1
    height = height or 50

    local bounds = active_arena.bounds
    local start_x = direction == 1 and bounds.x - 50 or bounds.x + bounds.width + 50
    local end_x = direction == 1 and bounds.x + bounds.width + 50 or bounds.x - 50

    local pos = vmath.vector3(start_x, bounds.y + height, 0)

    factory.create("#sweep_hazard_factory", pos, nil, {
        target_x = end_x,
        speed = 300,
        damage = 2,
        height = height * 2
    })
end

-- ============================================================================
-- UPDATE
-- ============================================================================

--- Update arena system
-- @param dt Delta time
function M.update(dt)
    if not active_arena then return end

    -- Update hazards
    for hazard_id, hazard in pairs(active_arena.active_hazards) do
        hazard.timer = hazard.timer + dt

        -- Dynamic hazard spawning
        if hazard.type == "falling_debris" then
            local interval = hazard.config.interval or 2.0
            if hazard.timer >= interval then
                hazard.timer = 0
                M.spawn_falling_debris(hazard.config.count or 1)
            end
        end
    end

    -- Update transition
    if active_arena.in_transition then
        active_arena.transition_timer = active_arena.transition_timer - dt
    end
end

-- ============================================================================
-- QUERY
-- ============================================================================

--- Get active arena
function M.get_active_arena()
    return active_arena
end

--- Get current phase
function M.get_current_phase()
    return active_arena and active_arena.current_phase or 0
end

--- Check if arena is locked
function M.is_locked()
    return active_arena and active_arena.locked or false
end

--- Check if in transition
function M.is_transitioning()
    return active_arena and active_arena.in_transition or false
end

--- Get arena bounds
function M.get_bounds()
    return active_arena and active_arena.bounds or nil
end

-- ============================================================================
-- TILED INTEGRATION
-- ============================================================================

--- Create arena configuration from Tiled properties.
-- Boss arenas now provide arena metadata only. Phase-driven hazards,
-- platforms, weak points, and other encounter pieces are authored as separate
-- Tiled objects that react to the arena's active phase.
-- @param properties Tiled object properties
-- @return Arena configuration
function M.create_from_tiled(properties)
    local config = {
        phases = {},
        hazard_configs = {},
        platform_configs = {},
    }

    local num_phases = tonumber(properties.phases) or 3

    -- Create empty phase slots so arena phase changes still work even when the
    -- encounter uses only object-driven arena pieces.
    for i = 1, num_phases do
        config.phases[i] = {}
    end

    -- Global settings
    if properties.camera_lock ~= nil then
        config.lock_camera = properties.camera_lock
    end

    local battle_music = optional_id(properties.battle_music) or optional_id(properties.combat_music)
    if battle_music then
        config.battle_music = battle_music
    end

    local victory_music = optional_id(properties.victory_music)
    if victory_music then
        config.victory_music = victory_music
    end

    return config
end

--- Activate hazards for a specific phase (called by enrage system)
-- @param phase Phase number
function M.activate_phase_hazards(phase)
    if not active_arena then return end

    local phase_config = active_arena.phases[phase]
    if not phase_config then return end

    -- Spawn hazards for this phase without clearing existing ones
    if phase_config.hazards then
        for _, hazard_id in ipairs(phase_config.hazards) do
            if not active_arena.active_hazards[hazard_id] then
                M.spawn_hazard(hazard_id)
            end
        end
    end

    log("Activated phase", phase, "hazards")
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

function M.cleanup()
    if active_arena then
        M.deactivate_arena()
    end
    arenas = {}
end

-- ============================================================================
-- COMPATIBILITY API
-- ============================================================================
-- Previously lived in mvtk/bosses/arena_mechanics.lua. That module is now a
-- thin wrapper forwarding to this module; these functions keep arena_mechanics
-- callers working without a parallel state store.

--- Register an arena. Alias for setup_arena that also returns the arena record.
function M.register_arena(arena_id, config)
    M.setup_arena(arena_id, config or {})
    return arenas[arena_id]
end

--- Lock an arena. Registers a minimal arena if the id is unknown so callers
--- that only need door-lock semantics (arena_lock.script) work without prior
--- setup_arena.
function M.lock_arena(arena_id)
    if not arenas[arena_id] then
        M.setup_arena(arena_id, {})
    end
    M.activate_arena(arena_id)
end

--- Unlock an arena. Deactivates the active arena if it matches; otherwise
--- clears the locked flag on the registered record.
function M.unlock_arena(arena_id)
    if active_arena and active_arena.id == arena_id then
        M.deactivate_arena()
        return
    end
    local a = arenas[arena_id]
    if a then a.locked = false end
end

--- Get an arena record by id. Returns a shape compatible with the legacy
--- arena_mechanics `get_arena` return value (fields: id, locked, boss_active,
--- phase, bounds, config).
function M.get_arena(arena_id)
    local a = arenas[arena_id]
    if not a then return nil end
    return {
        id = a.id,
        locked = a.locked,
        boss_active = a.locked,
        phase = a.current_phase or 0,
        bounds = a.bounds,
        config = a,
    }
end

--- Trigger an ad-hoc arena effect.
--- effect_type: "screen_shake" | "flash" | "hazard_pulse" | "spawn_adds" | "moving_platforms"
function M.trigger_arena_effect(arena_id, effect_type, params)
    local a = arenas[arena_id] or active_arena
    if not a then return end
    params = params or {}

    if effect_type == "screen_shake" then
        if ScreenShake and ScreenShake.shake then
            pcall(ScreenShake.shake, params.intensity or "heavy")
        end

    elseif effect_type == "flash" then
        pcall(msg.post, "/camera#camera", "flash_screen", {
            color = params.color or vmath.vector4(1, 1, 1, 0.5),
            duration = params.duration or 0.1,
        })

    elseif effect_type == "hazard_pulse" then
        for _, hazard in pairs(a.active_hazards or {}) do
            for _, go_id in ipairs(hazard.game_objects or {}) do
                if go.exists(go_id) then
                    pcall(msg.post, go_id, "pulse_activate")
                end
            end
        end

    elseif effect_type == "spawn_adds" then
        local EnemyManager = Util.require_module("mvtk.enemies.enemy_manager")
        local bounds = a.bounds
        if EnemyManager and EnemyManager.spawn_enemy and bounds then
            local count = params.count or 3
            local enemy_type = params.enemy_type or "slime"
            local radius = params.spawn_radius or 200
            local cx = bounds.x + (bounds.width or 0) / 2
            local cy = bounds.y + (bounds.height or 0) / 2
            for i = 1, count do
                local angle = (math.pi * 2 / count) * i
                local pos = vmath.vector3(cx + math.cos(angle) * radius,
                                          cy + math.sin(angle) * radius, 0)
                pcall(EnemyManager.spawn_enemy, enemy_type, pos)
            end
        end

    elseif effect_type == "moving_platforms" then
        pcall(msg.post, "/arena_platforms#" .. tostring(arena_id), "activate_movement")
    end

    log("Triggered effect", effect_type, "on arena", arena_id)
end

return M

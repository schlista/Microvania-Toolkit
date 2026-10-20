-- mvtk/bosses/dramatic_transitions.lua
-- Dramatic boss phase transition system
-- Creates memorable moments when bosses change phases

local Motion = require "mvtk.bosses.boss_motion"
local M = {}
local Pause = require "mvtk.core.pause"

local Util = require "mvtk.core.util"
local Hitstop = Util.require_module("mvtk.fx.hitstop")
local ScreenShake = Util.require_module("mvtk.fx.screen_shake")
local BossArena = Util.require_module("mvtk.bosses.boss_arena")
local Audio = Util.require_module("mvtk.audio.audio")

-- Transition types
local TRANSITION_TYPES = {
    -- Standard flash and shake
    standard = {
        hitstop_duration = 0.15,
        shake_intensity = "heavy",
        flash_color = vmath.vector4(1, 1, 1, 0.5),
        flash_duration = 0.2,
        pause_duration = 0.5
    },

    -- Boss enrages with red flash
    rage = {
        hitstop_duration = 0.2,
        shake_intensity = "critical",
        flash_color = vmath.vector4(1, 0.2, 0.2, 0.8),
        flash_duration = 0.3,
        pause_duration = 1.0,
        boss_scale_pulse = 1.2,
        spawn_particles = "rage_aura"
    },

    -- Boss heals/recovers
    heal = {
        hitstop_duration = 0.1,
        shake_intensity = "medium",
        flash_color = vmath.vector4(0.3, 1, 0.3, 0.6),
        flash_duration = 0.3,
        pause_duration = 0.7,
        boss_scale_pulse = 1.1,
        spawn_particles = "heal_effect"
    },

    -- Boss transforms/evolves
    transform = {
        hitstop_duration = 0.25,
        shake_intensity = "critical",
        flash_color = vmath.vector4(0.8, 0.4, 1, 0.9),
        flash_duration = 0.5,
        pause_duration = 1.5,
        boss_disappear = true,
        boss_reappear_delay = 1.0,
        spawn_particles = "transformation",
        music_change = true
    },

    -- Boss teleports away
    teleport = {
        hitstop_duration = 0.1,
        shake_intensity = "light",
        flash_color = vmath.vector4(0.5, 0.5, 1, 0.4),
        flash_duration = 0.15,
        pause_duration = 0.3,
        boss_disappear = true,
        boss_reappear_delay = 0.5,
        spawn_particles = "teleport_out",
        teleport_destination = true
    },

    -- Boss goes invulnerable and summons adds
    summon = {
        hitstop_duration = 0.15,
        shake_intensity = "medium",
        flash_color = vmath.vector4(0.7, 0.3, 0.9, 0.6),
        flash_duration = 0.25,
        pause_duration = 0.8,
        boss_invulnerable = true,
        spawn_adds = true,
        spawn_particles = "summon_circle"
    },

    -- Environmental change (arena hazards activate)
    environmental = {
        hitstop_duration = 0.2,
        shake_intensity = "critical",
        flash_color = vmath.vector4(1, 0.5, 0, 0.7),
        flash_duration = 0.3,
        pause_duration = 1.0,
        activate_hazards = true,
        spawn_particles = "arena_activation"
    }
}

--- Execute a dramatic phase transition
-- @param boss_url Boss game object URL
-- @param transition_type Type of transition
-- @param options Custom options to override preset
-- @param on_complete Callback when transition finishes
function M.execute_transition(boss_url, transition_type, options, on_complete)
    if Pause.get() then
        Pause.delay(0, function()
            if go.exists(boss_url) then M.execute_transition(boss_url, transition_type, options, on_complete) end
        end)
        return
    end
    local preset = TRANSITION_TYPES[transition_type] or TRANSITION_TYPES.standard
    options = options or {}

    -- Merge options with preset
    local config = {}
    for k, v in pairs(preset) do
        config[k] = v
    end
    for k, v in pairs(options) do
        config[k] = v
    end

    print(string.format("[DRAMATIC_TRANSITIONS] Executing '%s' transition", transition_type))

    -- Step 1: Hitstop
    if config.hitstop_duration and config.hitstop_duration > 0 then
        Hitstop.start_hitstop(config.hitstop_duration, config.shake_intensity)
    end

    -- Step 2: Screen shake
    if config.shake_intensity then
        ScreenShake.shake(config.shake_intensity)
    end

    -- Step 3: Screen flash
    if config.flash_color and config.flash_duration then
        pcall(msg.post, "/camera", "flash_screen", {
            color = config.flash_color,
            duration = config.flash_duration
        })
    end

    -- Step 4: Boss effects
    Pause.delay(0.1, function()
        if not go.exists(boss_url) then
            if on_complete then on_complete() end
            return
        end

        -- Scale pulse effect
        if config.boss_scale_pulse then
            local original_scale = go.get_scale(boss_url)
            Motion.scale(boss_url,
                original_scale * config.boss_scale_pulse,
                0.3, "out_quad", true)
        end

        -- Disappear/reappear
        if config.boss_disappear then
            -- Shrink to disappear
            Motion.scale(boss_url,
                vmath.vector3(0, 0, 1),
                0.3, "in_cubic", false, function()

                -- Teleport to new position if specified
                if config.teleport_destination then
                    local new_pos = config.teleport_destination
                    if type(new_pos) == "function" then
                        new_pos = new_pos()
                    end
                    if new_pos then
                        go.set_position(new_pos, boss_url)
                    end
                end

                -- Reappear after delay
                Pause.delay(config.boss_reappear_delay or 0.5, function()
                    if go.exists(boss_url) then
                        Motion.scale(boss_url,
                            vmath.vector3(1, 1, 1),
                            0.3, "out_cubic")

                        -- Reappear particles
                        if config.spawn_particles == "teleport_out" then
                            -- Spawn teleport in effect
                        end
                    end
                end)
            end)
        end

        -- Invulnerability
        if config.boss_invulnerable then
            pcall(msg.post, boss_url, "set_invulnerable", {
                duration = config.pause_duration or 1.0
            })
        end

        -- Spawn particles
        if config.spawn_particles and go.exists(boss_url) then
            local pos = go.get_position(boss_url)
            -- Trigger particle effect at boss position
            -- This would need a particle factory
            pcall(msg.post, "#particle_factory", "spawn_effect", {
                effect_type = config.spawn_particles,
                position = pos
            })
        end

        -- Spawn adds
        if config.spawn_adds then
            local arena_id = options.arena_id
            if arena_id then
                BossArena.trigger_arena_effect(arena_id, "spawn_adds", {
                    count = options.add_count or 3,
                    enemy_type = options.add_type or "slime",
                    spawn_radius = options.spawn_radius or 200
                })
            end
        end

        -- Activate hazards
        if config.activate_hazards then
            local arena_id = options.arena_id
            if arena_id then
                BossArena.trigger_arena_effect(arena_id, "hazard_pulse")
            end
        end

        -- Music change
        if config.music_change and options.new_music then
            Audio.music(options.new_music, {
                -- track removed, passed as first arg
                t = 0.5
            })
        end
    end)

    -- Step 5: Complete after pause duration
    if config.pause_duration then
        Pause.delay(config.pause_duration, function()
            if on_complete then
                on_complete()
            end
        end)
    else
        if on_complete then
            on_complete()
        end
    end
end

--- Create a custom transition type
-- @param name Transition name
-- @param config Transition configuration
function M.register_transition_type(name, config)
    TRANSITION_TYPES[name] = config
    print(string.format("[DRAMATIC_TRANSITIONS] Registered custom transition '%s'", name))
end

--- Get transition preset
-- @param transition_type Type name
-- @return Transition configuration or nil
function M.get_preset(transition_type)
    return TRANSITION_TYPES[transition_type]
end

--- Execute quick transition without full ceremony
-- @param boss_url Boss game object URL
-- @param intensity "light", "medium", "heavy"
function M.quick_transition(boss_url, intensity)
    intensity = intensity or "medium"

    if intensity == "light" then
        Hitstop.on_hit_light()
        ScreenShake.on_hit_light()
    elseif intensity == "heavy" then
        Hitstop.on_hit_heavy()
        ScreenShake.on_hit_heavy()
    else
        Hitstop.on_hit_medium()
        ScreenShake.on_hit_medium()
    end

    print("[DRAMATIC_TRANSITIONS] Quick transition executed")
end

return M

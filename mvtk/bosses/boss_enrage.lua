-- mvtk/bosses/boss_enrage.lua
-- ============================================================================
-- Boss Enrage Mechanics System
-- ============================================================================
-- Handles boss behavior and stat changes when health drops below thresholds.
-- Supports multiple enrage phases with different effects.
--
-- Usage:
--   local BossEnrage = require "mvtk.bosses.boss_enrage"
--
--   BossEnrage.setup_boss("dragon_boss", {
--       thresholds = {
--           { percent = 0.75, effects = {"speed_boost"} },
--           { percent = 0.50, effects = {"attack_boost", "new_pattern"} },
--           { percent = 0.25, effects = {"frenzy", "summon_minions"} },
--       }
--   })
--
--   -- In boss update:
--   BossEnrage.check_health(boss_id, current_health, max_health)

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config")

local M = {}

-- ============================================================================
-- DATA STRUCTURES
-- ============================================================================

local boss_enrage = {}  -- boss_id -> enrage_data

-- Enrage effect types
M.EFFECT = {
    -- Stat modifiers
    SPEED_BOOST = "speed_boost",
    DAMAGE_BOOST = "damage_boost",
    ATTACK_SPEED = "attack_speed",
    DEFENSE_BOOST = "defense_boost",

    -- Behavior changes
    NEW_PATTERN = "new_pattern",
    AGGRESSIVE = "aggressive",
    FRENZY = "frenzy",
    BERSERK = "berserk",

    -- Special abilities
    SUMMON_MINIONS = "summon_minions",
    HEAL_BURST = "heal_burst",
    SHIELD = "shield",
    INVINCIBLE_BURST = "invincible_burst",

    -- Visual/Arena
    VISUAL_CHANGE = "visual_change",
    ARENA_HAZARDS = "arena_hazards",
    SCREEN_EFFECT = "screen_effect",
}

-- Debug logging
local log = Util.make_debug_log("[BOSS_ENRAGE]", function()
    return Debug.global and Debug.global.enable
end)

-- ============================================================================
-- SETUP
-- ============================================================================

--- Setup enrage system for a boss
-- @param boss_id Boss identifier
-- @param config Enrage configuration
function M.setup_boss(boss_id, config)
    config = config or {}

    -- Sort thresholds by percent descending
    local thresholds = config.thresholds or {
        { percent = 0.50, effects = {"speed_boost", "damage_boost"} },
        { percent = 0.25, effects = {"frenzy"} },
    }
    table.sort(thresholds, function(a, b) return a.percent > b.percent end)

    boss_enrage[boss_id] = {
        boss_id = boss_id,
        boss_url = nil,

        -- Thresholds
        thresholds = thresholds,
        triggered_thresholds = {},  -- Track which have been triggered

        -- Current state
        current_level = 0,  -- 0 = not enraged
        active_effects = {},

        -- Base stats (stored when enrage starts)
        base_stats = nil,

        -- Stat multipliers
        speed_mult = config.speed_mult or 1.3,
        damage_mult = config.damage_mult or 1.5,
        attack_speed_mult = config.attack_speed_mult or 1.4,
        defense_mult = config.defense_mult or 1.2,

        -- Frenzy settings
        frenzy_speed_mult = config.frenzy_speed_mult or 1.8,
        frenzy_damage_mult = config.frenzy_damage_mult or 2.0,
        frenzy_attack_speed_mult = config.frenzy_attack_speed_mult or 2.0,

        -- Berserk settings (final phase)
        berserk_speed_mult = config.berserk_speed_mult or 2.0,
        berserk_damage_mult = config.berserk_damage_mult or 2.5,
        berserk_no_cooldown = config.berserk_no_cooldown or false,

        -- Heal burst settings
        heal_percent = config.heal_percent or 0.1,
        heal_duration = config.heal_duration or 2.0,

        -- Shield settings
        shield_duration = config.shield_duration or 3.0,
        shield_health = config.shield_health or 0,  -- 0 = invincible

        -- Minion settings
        minion_summon_id = config.minion_summon_id or "enrage_adds",

        -- Visual settings
        enrage_color = config.enrage_color or vmath.vector4(1, 0.3, 0.3, 1),
        frenzy_color = config.frenzy_color or vmath.vector4(1, 0, 0, 1),

        -- Callbacks
        on_enrage = config.on_enrage,
        on_effect_activated = config.on_effect_activated,
        on_threshold_reached = config.on_threshold_reached,

        -- Transition settings
        transition_time = config.transition_time or 1.0,
        pause_during_transition = config.pause_during_transition or true,

        -- State
        in_transition = false,
        transition_timer = 0,
    }

    log("Setup enrage system for boss:", boss_id, "Thresholds:", #thresholds)
end

--- Register boss game object and store base stats
-- @param boss_id Boss identifier
-- @param boss_url Boss URL
-- @param base_stats Table of base stats to modify during enrage
function M.register_boss(boss_id, boss_url, base_stats)
    local data = boss_enrage[boss_id]
    if data then
        data.boss_url = boss_url
        data.base_stats = base_stats or {
            speed = 100,
            damage = 10,
            attack_cooldown = 1.0,
            defense = 0,
        }
    end
end

-- ============================================================================
-- HEALTH CHECKING
-- ============================================================================

--- Check health and trigger enrage if threshold crossed
-- @param boss_id Boss identifier
-- @param current_health Current boss health
-- @param max_health Maximum boss health
-- @return Table of newly triggered effects (or nil)
function M.check_health(boss_id, current_health, max_health)
    local data = boss_enrage[boss_id]
    if not data then return nil end

    -- Skip during transition
    if data.in_transition then return nil end

    local health_percent = current_health / max_health
    local triggered_effects = {}

    -- Check each threshold
    for i, threshold in ipairs(data.thresholds) do
        if health_percent <= threshold.percent and not data.triggered_thresholds[i] then
            -- Mark as triggered
            data.triggered_thresholds[i] = true
            data.current_level = i

            -- Collect effects
            for _, effect in ipairs(threshold.effects or {}) do
                table.insert(triggered_effects, effect)
            end

            -- Trigger callback
            if data.on_threshold_reached then
                data.on_threshold_reached(threshold.percent, threshold.effects)
            end

            log("Boss", boss_id, "reached enrage threshold:", threshold.percent)
        end
    end

    -- Apply any new effects
    if #triggered_effects > 0 then
        M.apply_effects(boss_id, triggered_effects)
        return triggered_effects
    end

    return nil
end

-- ============================================================================
-- EFFECT APPLICATION
-- ============================================================================

--- Apply enrage effects
-- @param boss_id Boss identifier
-- @param effects Table of effect names
function M.apply_effects(boss_id, effects)
    local data = boss_enrage[boss_id]
    if not data then return end

    -- Start transition
    if data.pause_during_transition then
        M.start_transition(boss_id)
    end

    for _, effect in ipairs(effects) do
        M.apply_single_effect(boss_id, effect)
        data.active_effects[effect] = true

        if data.on_effect_activated then
            data.on_effect_activated(effect)
        end
    end

    -- General enrage callback
    if data.on_enrage then
        data.on_enrage(data.current_level, effects)
    end

    -- Notify boss
    if data.boss_url then
        pcall(msg.post, data.boss_url, "enrage", {
            level = data.current_level,
            effects = effects
        })
    end

    -- Notify game manager
    pcall(msg.post, "/game_manager#game_manager", "boss_enraged", {
        boss_id = boss_id,
        level = data.current_level,
        effects = effects
    })
end

--- Apply a single effect
function M.apply_single_effect(boss_id, effect)
    local data = boss_enrage[boss_id]
    if not data or not data.base_stats then return end

    log("Applying effect:", effect, "to boss:", boss_id)

    if effect == M.EFFECT.SPEED_BOOST then
        M.boost_stat(boss_id, "speed", data.speed_mult)

    elseif effect == M.EFFECT.DAMAGE_BOOST then
        M.boost_stat(boss_id, "damage", data.damage_mult)

    elseif effect == M.EFFECT.ATTACK_SPEED then
        M.boost_stat(boss_id, "attack_cooldown", 1 / data.attack_speed_mult)

    elseif effect == M.EFFECT.DEFENSE_BOOST then
        M.boost_stat(boss_id, "defense", data.defense_mult)

    elseif effect == M.EFFECT.AGGRESSIVE then
        -- More aggressive behavior
        if data.boss_url then
            pcall(msg.post, data.boss_url, "set_aggressive", {enabled = true})
        end

    elseif effect == M.EFFECT.FRENZY then
        M.boost_stat(boss_id, "speed", data.frenzy_speed_mult)
        M.boost_stat(boss_id, "damage", data.frenzy_damage_mult)
        M.boost_stat(boss_id, "attack_cooldown", 1 / data.frenzy_attack_speed_mult)
        M.apply_visual_effect(boss_id, "frenzy")

    elseif effect == M.EFFECT.BERSERK then
        M.boost_stat(boss_id, "speed", data.berserk_speed_mult)
        M.boost_stat(boss_id, "damage", data.berserk_damage_mult)
        if data.berserk_no_cooldown then
            M.set_stat(boss_id, "attack_cooldown", 0.1)
        end
        M.apply_visual_effect(boss_id, "berserk")

    elseif effect == M.EFFECT.NEW_PATTERN then
        if data.boss_url then
            pcall(msg.post, data.boss_url, "unlock_pattern", {level = data.current_level})
        end

    elseif effect == M.EFFECT.SUMMON_MINIONS then
        local BossMinions = Util.require_module("mvtk.bosses.boss_minions")
        if BossMinions and BossMinions.can_summon(boss_id, data.minion_summon_id) then
            BossMinions.summon(boss_id, data.minion_summon_id)
        end

    elseif effect == M.EFFECT.HEAL_BURST then
        M.trigger_heal_burst(boss_id)

    elseif effect == M.EFFECT.SHIELD then
        M.trigger_shield(boss_id)

    elseif effect == M.EFFECT.INVINCIBLE_BURST then
        M.trigger_invincibility(boss_id, 2.0)

    elseif effect == M.EFFECT.VISUAL_CHANGE then
        M.apply_visual_effect(boss_id, "enrage")

    elseif effect == M.EFFECT.ARENA_HAZARDS then
        local BossArena = Util.require_module("mvtk.bosses.boss_arena")
        if BossArena then
            BossArena.activate_phase_hazards(data.current_level)
        end

    elseif effect == M.EFFECT.SCREEN_EFFECT then
        M.trigger_screen_effect(boss_id)
    end
end

-- ============================================================================
-- STAT MODIFICATION
-- ============================================================================

--- Boost a stat by multiplier (from base)
function M.boost_stat(boss_id, stat_name, multiplier)
    local data = boss_enrage[boss_id]
    if not data or not data.base_stats then return end

    local base_value = data.base_stats[stat_name]
    if base_value then
        local new_value = base_value * multiplier
        M.set_stat(boss_id, stat_name, new_value)
    end
end

--- Set a stat to specific value
function M.set_stat(boss_id, stat_name, value)
    local data = boss_enrage[boss_id]
    if not data or not data.boss_url then return end

    pcall(msg.post, data.boss_url, "set_stat", {
        stat = stat_name,
        value = value
    })
end

--- Get current stat multiplier for a stat
function M.get_stat_multiplier(boss_id, stat_name)
    local data = boss_enrage[boss_id]
    if not data then return 1.0 end

    local multiplier = 1.0

    -- Check active effects and accumulate multipliers
    if data.active_effects[M.EFFECT.SPEED_BOOST] and stat_name == "speed" then
        multiplier = multiplier * data.speed_mult
    end
    if data.active_effects[M.EFFECT.DAMAGE_BOOST] and stat_name == "damage" then
        multiplier = multiplier * data.damage_mult
    end
    if data.active_effects[M.EFFECT.FRENZY] then
        if stat_name == "speed" then multiplier = multiplier * data.frenzy_speed_mult end
        if stat_name == "damage" then multiplier = multiplier * data.frenzy_damage_mult end
    end
    if data.active_effects[M.EFFECT.BERSERK] then
        if stat_name == "speed" then multiplier = multiplier * data.berserk_speed_mult end
        if stat_name == "damage" then multiplier = multiplier * data.berserk_damage_mult end
    end

    return multiplier
end

-- ============================================================================
-- SPECIAL EFFECTS
-- ============================================================================

--- Trigger heal burst
function M.trigger_heal_burst(boss_id)
    local data = boss_enrage[boss_id]
    if not data or not data.boss_url then return end

    pcall(msg.post, data.boss_url, "heal_burst", {
        percent = data.heal_percent,
        duration = data.heal_duration
    })

    -- Visual effect
    factory.create("#heal_burst_factory", go.get_position(data.boss_url))

    log("Boss", boss_id, "heal burst:", data.heal_percent * 100, "%")
end

--- Trigger shield
function M.trigger_shield(boss_id)
    local data = boss_enrage[boss_id]
    if not data or not data.boss_url then return end

    pcall(msg.post, data.boss_url, "activate_shield", {
        duration = data.shield_duration,
        health = data.shield_health
    })

    log("Boss", boss_id, "shield activated for", data.shield_duration, "seconds")
end

--- Trigger temporary invincibility
function M.trigger_invincibility(boss_id, duration)
    local data = boss_enrage[boss_id]
    if not data or not data.boss_url then return end

    pcall(msg.post, data.boss_url, "set_invincible", {
        enabled = true,
        duration = duration
    })

    log("Boss", boss_id, "invincible for", duration, "seconds")
end

--- Apply visual effect
function M.apply_visual_effect(boss_id, effect_type)
    local data = boss_enrage[boss_id]
    if not data or not data.boss_url then return end

    local color = data.enrage_color
    if effect_type == "frenzy" or effect_type == "berserk" then
        color = data.frenzy_color
    end

    pcall(msg.post, data.boss_url, "apply_tint", {color = color})

    -- Particle effect
    if effect_type == "frenzy" or effect_type == "berserk" then
        pcall(msg.post, data.boss_url, "enable_enrage_particles", {enabled = true})
    end
end

--- Trigger screen effect
function M.trigger_screen_effect(boss_id)
    local data = boss_enrage[boss_id]
    if not data then return end

    -- Screen shake
    pcall(msg.post, "/camera#camera", "shake", {
        intensity = 5,
        duration = 0.5
    })

    -- Flash effect
    pcall(msg.post, "/ui#ui", "screen_flash", {
        color = data.frenzy_color,
        duration = 0.3
    })
end

-- ============================================================================
-- TRANSITION
-- ============================================================================

--- Start enrage transition
function M.start_transition(boss_id)
    local data = boss_enrage[boss_id]
    if not data then return end

    data.in_transition = true
    data.transition_timer = 0

    -- Pause boss during transition
    if data.boss_url then
        pcall(msg.post, data.boss_url, "pause", {duration = data.transition_time})
    end

    -- Dramatic effect
    pcall(msg.post, "/camera#camera", "shake", {intensity = 3, duration = data.transition_time})

    log("Boss", boss_id, "enrage transition started")
end

--- Update transition
function M.update_transition(boss_id, dt)
    local data = boss_enrage[boss_id]
    if not data or not data.in_transition then return false end

    data.transition_timer = data.transition_timer + dt

    if data.transition_timer >= data.transition_time then
        data.in_transition = false
        data.transition_timer = 0

        log("Boss", boss_id, "enrage transition complete")
        return true
    end

    return false
end

-- ============================================================================
-- QUERY
-- ============================================================================

--- Get current enrage level
function M.get_enrage_level(boss_id)
    local data = boss_enrage[boss_id]
    return data and data.current_level or 0
end

--- Check if boss is enraged
function M.is_enraged(boss_id)
    return M.get_enrage_level(boss_id) > 0
end

--- Check if specific effect is active
function M.has_effect(boss_id, effect)
    local data = boss_enrage[boss_id]
    return data and data.active_effects[effect] or false
end

--- Get all active effects
function M.get_active_effects(boss_id)
    local data = boss_enrage[boss_id]
    if not data then return {} end

    local effects = {}
    for effect, active in pairs(data.active_effects) do
        if active then
            table.insert(effects, effect)
        end
    end
    return effects
end

--- Check if in transition
function M.is_in_transition(boss_id)
    local data = boss_enrage[boss_id]
    return data and data.in_transition or false
end

-- ============================================================================
-- MANUAL TRIGGERS
-- ============================================================================

--- Force trigger enrage level
function M.force_enrage(boss_id, level)
    local data = boss_enrage[boss_id]
    if not data then return end

    local threshold = data.thresholds[level]
    if threshold and not data.triggered_thresholds[level] then
        data.triggered_thresholds[level] = true
        data.current_level = level
        M.apply_effects(boss_id, threshold.effects)
    end
end

--- Reset enrage (for respawning)
function M.reset(boss_id)
    local data = boss_enrage[boss_id]
    if not data then return end

    data.current_level = 0
    data.triggered_thresholds = {}
    data.active_effects = {}
    data.in_transition = false
    data.transition_timer = 0

    -- Reset visual
    if data.boss_url then
        pcall(msg.post, data.boss_url, "apply_tint", {color = vmath.vector4(1, 1, 1, 1)})
        pcall(msg.post, data.boss_url, "enable_enrage_particles", {enabled = false})
    end

    log("Boss", boss_id, "enrage reset")
end

-- ============================================================================
-- UPDATE
-- ============================================================================

--- Update enrage system
-- @param dt Delta time
function M.update(dt)
    for boss_id, data in pairs(boss_enrage) do
        M.update_transition(boss_id, dt)
    end
end

-- ============================================================================
-- TILED INTEGRATION
-- ============================================================================

--- Create enrage config from Tiled properties
-- @param properties Tiled object properties
-- @return Enrage configuration
function M.create_from_tiled(properties)
    local config = {}

    -- Parse thresholds (format: "0.75:speed_boost,damage_boost;0.5:frenzy;0.25:berserk")
    if properties.enrage_thresholds then
        config.thresholds = {}
        for threshold_str in string.gmatch(properties.enrage_thresholds, "[^;]+") do
            local percent_str, effects_str = threshold_str:match("([^:]+):(.+)")
            if percent_str and effects_str then
                local threshold = {
                    percent = tonumber(percent_str),
                    effects = {}
                }
                for effect in string.gmatch(effects_str, "[^,]+") do
                    table.insert(threshold.effects, effect)
                end
                table.insert(config.thresholds, threshold)
            end
        end
    end

    -- Multipliers
    if properties.enrage_speed_mult then
        config.speed_mult = tonumber(properties.enrage_speed_mult)
    end
    if properties.enrage_damage_mult then
        config.damage_mult = tonumber(properties.enrage_damage_mult)
    end
    if properties.enrage_attack_speed_mult then
        config.attack_speed_mult = tonumber(properties.enrage_attack_speed_mult)
    end

    -- Frenzy
    if properties.frenzy_speed_mult then
        config.frenzy_speed_mult = tonumber(properties.frenzy_speed_mult)
    end
    if properties.frenzy_damage_mult then
        config.frenzy_damage_mult = tonumber(properties.frenzy_damage_mult)
    end

    -- Other settings
    if properties.heal_percent then
        config.heal_percent = tonumber(properties.heal_percent)
    end
    if properties.shield_duration then
        config.shield_duration = tonumber(properties.shield_duration)
    end
    if properties.minion_summon_id then
        config.minion_summon_id = properties.minion_summon_id
    end
    if properties.transition_time then
        config.transition_time = tonumber(properties.transition_time)
    end
    if properties.pause_during_transition ~= nil then
        -- Normalize Tiled boolean: strings "false"/"true" and actual booleans
        local val = properties.pause_during_transition
        if type(val) == "string" then
            config.pause_during_transition = (val == "true")
        else
            config.pause_during_transition = (val == true)
        end
    end

    return config
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

function M.cleanup_boss(boss_id)
    boss_enrage[boss_id] = nil
end

function M.cleanup()
    boss_enrage = {}
end

return M

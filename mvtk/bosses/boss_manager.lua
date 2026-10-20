--- Boss Manager
-- Central controller for all boss encounters
-- Handles spawning, phases, health, and defeat
--
-- @module boss_manager

local Util = require "mvtk.core.util"
local SafeSound = require "mvtk.audio.safe_sound"
local CombatFeedback = require "mvtk.combat.combat_feedback"
local Logger = require "mvtk.core.logger"

local M = {}
local log = Logger.get_logger("BOSS_MANAGER")

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.bosses and _Dbg.bosses.manager then
        _orig_print(...)
    end
end

local boss_types = Util.require_config("developer.config.boss_types")
-- Static require so Defold's bundler includes this framework file.
local attack_patterns = require "mvtk.bosses.patterns.attack_patterns"
local AttackScale = require "mvtk.bosses.attack_scale"
local TileSettings = require "developer.config.tile_settings"
local user_pattern_names = {}

-- Merge user-defined patterns from developer/config/attack_patterns.lua on top
-- of the framework patterns. User patterns override framework ones by name.
do
    local user_ok, user_patterns = pcall(require, "developer.config.attack_patterns")
    if user_ok and type(user_patterns) == "table" then
        for name, pat in pairs(user_patterns) do
            attack_patterns[name] = pat
            user_pattern_names[name] = true
        end
    end
end

-- Validate attack pattern library at load-time. Bad patterns surface here
-- instead of as silent failures mid-fight. Validation never throws.
do
    local ok, PatternSchema = pcall(require, "mvtk.bosses.attack_pattern_schema")
    if ok and PatternSchema and PatternSchema.validate_all then
        local count, errors = PatternSchema.validate_all(attack_patterns)
        for _, err in ipairs(errors or {}) do
            _orig_print("[BOSS_MANAGER] attack_patterns: " .. tostring(err))
        end
        if count > 0 and #errors == 0 then
            _orig_print(string.format(
                "[BOSS_MANAGER] validated %d attack patterns OK", count))
        end
    end
end
local BossUI = require "mvtk.bosses.boss_ui"
local BossMusic = require "mvtk.bosses.boss_music"
local InvulnerabilityOk, Invulnerability = pcall(require, "mvtk.combat.invulnerability")
if not InvulnerabilityOk then
    -- Stub so call sites don't need to guard every invocation
    Invulnerability = {
        start = function() end,
        is_invulnerable = function() return false end,
        stop = function() end,
    }
end
local BossDefaults = Util.require_config("developer.config.boss_defaults", {
    iframes_on_hit = 0.2,
    iframes_on_phase_transition = 1.5,
    defeat_cleanup_delay = 2.0,
})
local Time = require "mvtk.core.time"
local Flags = require "mvtk.core.flags"

-- Storage
local active_bosses = {}  -- boss_id -> {type, health, phase, state_machine, etc.}
local boss_id_counter = 0
local encounter_metrics = {
    player_damage_taken = 0,  -- tracks damage during the current live encounter
    tracking_active = false,
}

local function has_undefeated_bosses()
    for _, boss in pairs(active_bosses) do
        if boss and not boss.defeated then
            return true
        end
    end
    return false
end

local function begin_encounter_tracking()
    encounter_metrics.player_damage_taken = 0
    encounter_metrics.tracking_active = true
end

local function stop_encounter_tracking()
    encounter_metrics.tracking_active = false
end

local function reset_encounter_tracking()
    encounter_metrics.player_damage_taken = 0
    encounter_metrics.tracking_active = false
end

-- Configuration
local config = {
    show_health_bar = true,
    enable_phase_transitions = true,
}

local function normalize_health_bar_position(value)
    local raw = Util.trim(value)
    if raw == "" then
        return nil
    end

    local position = string.lower(raw)
    if position == "top" or position == "bottom" then
        return position
    end

    return nil
end

local function boss_health_bar_enabled(boss)
    if not config.show_health_bar then
        return false
    end
    if boss and boss.config and boss.config.show_health_bar ~= nil then
        return Util.to_bool(boss.config.show_health_bar, true)
    end
    return true
end

local function trim_string(value)
    local s = Util.trim(value)
    if s == "" then
        return nil
    end
    return s
end

local function copy_table(value)
    if type(value) ~= "table" then
        return {}
    end
    if Util.deep_copy then
        return Util.deep_copy(value)
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = v
    end
    return copy
end

local function resolve_boss_preset(preset_id)
    local preset = trim_string(preset_id)
    if preset and type(boss_types[preset]) == "table" then
        return preset, copy_table(boss_types[preset])
    end

    if preset then
        print(string.format("[BOSS_MANAGER] Unknown boss preset '%s' - falling back to default authored baseline", preset))
    end

    local default_preset = type(boss_types.default_boss) == "table" and boss_types.default_boss or nil
    if default_preset then
        return nil, copy_table(default_preset)
    end

    return nil, {
        name = "Boss",
        max_health = 100,
        defense = 0,
        damage_resistance = 1.0,
        boss_visual_type = "sprite",
        visual_component = "sprite",
        phases = {
            {
                health_range = { min = 0.0, max = 1.0 },
                attacks = {},
                attack_interval = { min = 2.0, max = 4.0 },
                behavior = "aggressive",
                speed_multiplier = 1.0,
                damage_multiplier = 1.0,
            },
        },
    }
end

local function resolve_boss_display_name(config, preset_id, fallback_id)
    if type(config) ~= "table" then
        return fallback_id or preset_id or "Boss"
    end

    return trim_string(config.name)
        or trim_string(config.boss_name)
        or trim_string(config.display_name)
        or trim_string(config.spawn_name)
        or trim_string(config.boss_id)
        or trim_string(config.spawn_id)
        or trim_string(config.boss_tag)
        or trim_string(preset_id)
        or fallback_id
        or "Boss"
end

local function resolve_boss_identity_id(boss, fallback_id)
    local cfg = boss and boss.config or nil
    return trim_string(cfg and cfg.spawn_id)
        or trim_string(cfg and cfg.boss_id)
        or trim_string(cfg and cfg.boss_tag)
        or trim_string(boss and boss.preset_id)
        or trim_string(boss and boss.type)
        or fallback_id
end

-- Music is now delegated to mvtk/bosses/boss_music.lua.
-- Thin wrappers keep the internal call-sites unchanged.
local function start_boss_music(boss, boss_id)
    if boss and boss.config and boss.config.audio then
        BossMusic.push(boss_id, boss.config.audio)
    end
end

local function stop_active_music(boss_id)
    BossMusic.pop(boss_id)
end

--- Initialize boss manager
-- @param custom_config Optional configuration overrides
function M.init(custom_config)
    if custom_config then
        for k, v in pairs(custom_config) do
            config[k] = v
        end
    end

    print("[BOSS_MANAGER] Initialized")
end

--- Spawn a boss
-- @param boss_type Optional preset id from boss_types.lua. Nil/empty means
--        "spawn a Tiled-authored boss using baseline defaults plus custom_config".
-- @param position World position
-- @param custom_config Optional config overrides
-- @return boss_id or nil if failed
function M.spawn_boss(boss_type, position, custom_config)
    local had_live_bosses = has_undefeated_bosses()

    local preset_id, type_def = resolve_boss_preset(boss_type)

    -- Generate unique ID
    boss_id_counter = boss_id_counter + 1
    local boss_id = "boss_" .. boss_id_counter

    -- Merge configs
    local final_config = copy_table(type_def)
    if custom_config then
        for k, v in pairs(custom_config) do
            if (k == "audio" or k == "on_defeat" or k == "size")
                and type(v) == "table"
                and type(final_config[k]) == "table" then
                local merged = {}
                for kk, vv in pairs(final_config[k]) do
                    merged[kk] = vv
                end
                for kk, vv in pairs(v) do
                    merged[kk] = vv
                end
                final_config[k] = merged
            else
                final_config[k] = v
            end
        end
    end

    final_config.name = resolve_boss_display_name(final_config, preset_id, boss_id)
    final_config.boss_name = final_config.name
    final_config.boss_preset = trim_string(final_config.boss_preset) or preset_id

    -- Create boss data
    local boss = {
        id = boss_id,
        type = trim_string(final_config.spawn_id)
            or trim_string(final_config.boss_id)
            or trim_string(final_config.boss_tag)
            or preset_id
            or boss_id,
        preset_id = preset_id,
        position = position,
        config = final_config,

        -- Stats
        max_health = final_config.max_health or 100,
        health = final_config.max_health or 100,
        defense = final_config.defense or 0,
        damage_resistance = final_config.damage_resistance or 1.0,

        -- State
        invulnerable = false,
        stunned = false,
        defeated = false,

        -- Modifiers (changed by phases)
        speed_multiplier = 1.0,
        damage_multiplier = 1.0,
        available_attacks = {},

        -- Cooldowns
        attack_cooldowns = {},

        -- Spawned time
        spawn_time = Time.gettime(),
    }

    -- Optional tag for external references (Tiled, spawners, triggers)
    boss.tag = final_config.boss_tag or final_config.spawn_id or final_config.boss_id or final_config.tiled_id
    boss.spawn_id = final_config.spawn_id or boss.tag
    boss.boss_type = boss.type

    -- Store boss
    active_bosses[boss_id] = boss
    CombatFeedback.register_boss(boss_id, final_config.player_hit_feedback)

    -- Start a fresh encounter only when no other live boss is active.
    if not had_live_bosses then
        begin_encounter_tracking()
    end

    print(string.format("[BOSS_MANAGER] Spawned %s (%s) at (%.0f, %.0f)",
        tostring(final_config.name), tostring(preset_id or "tiled_authored"), position.x, position.y))

    -- Show boss health bar
    if boss_health_bar_enabled(boss) then
        M.show_boss_health_bar(boss_id)
    end

    -- Play boss music
    start_boss_music(boss, boss_id)

    -- Lock arena doors if configured
    if final_config.arena then
        M.lock_arena(final_config.arena, final_config.room_id)
    end

    -- Auto-setup arena runtime (hazards, platforms, effects) from
    -- developer/config/boss_arenas.lua so users don't have to call
    -- BossArena.setup_arena manually in their room scripts.
    local arena_id = final_config.arena_id or final_config.arena
    if arena_id then
        local ArenaCfg = Util.require_config("developer.config.boss_arenas", {})
        local arena_def = (ArenaCfg.arenas and ArenaCfg.arenas[arena_id]) or ArenaCfg[arena_id]
        local BossArena = Util.require_module("mvtk.bosses.boss_arena")
        local existing_arena = BossArena and BossArena.get_arena and BossArena.get_arena(arena_id) or nil

        -- Prefer a Tiled-authored arena that was already registered during room
        -- import. Fall back to developer/config/boss_arenas.lua only when no
        -- runtime arena record exists yet.
        if not existing_arena and arena_def and BossArena and BossArena.setup_arena then
            pcall(BossArena.setup_arena, arena_id, {
                boss_id = boss_id,
                bounds = arena_def.bounds,
                phases = arena_def.phase_hazards and
                    (function()
                        local phases = {}
                        for idx, hazards in pairs(arena_def.phase_hazards) do
                            phases[idx] = { hazards = hazards }
                        end
                        return phases
                    end)() or arena_def.phases or {},
                hazard_configs = arena_def.hazard_configs,
                on_phase_change = arena_def.on_phase_change,
            })
        end

        if BossArena and BossArena.get_arena and BossArena.get_arena(arena_id) then
            -- Activate the arena so transition_to_phase / apply_phase
            -- actually run (they early-return when active_arena is nil).
            if BossArena.activate_arena then
                pcall(BossArena.activate_arena, arena_id)
            end
            if BossArena.apply_phase then
                pcall(BossArena.apply_phase, 1)
            end
        end
    end

    return boss_id
end

--- Damage a boss
-- @param boss_id Boss identifier
-- @param damage Damage amount
-- @param source Damage source
-- @return true if damage was applied
function M.damage_boss(boss_id, damage, source)
    if require("mvtk.core.pause").get() then return false end
    local boss = active_bosses[boss_id]

    if not boss or boss.defeated then
        return false
    end

    -- Check if vulnerable (timer-driven i-frames or hard flag)
    if Invulnerability.is_invulnerable(boss) or boss.defeated then
        return false
    end

    -- Apply defense
    local final_damage = math.max(1, damage - boss.defense)

    -- Apply global resistance multiplier (from boss_types config)
    final_damage = final_damage * boss.damage_resistance

    -- Apply damage
    boss.health = boss.health - final_damage

    -- Start i-frames so rapid multi-hits can't stunlock / delete health.
    -- Per-attack override: source.iframes_on_hit; else boss config; else defaults.
    local iframes = (type(source) == "table" and source.iframes_on_hit)
        or (boss.config and boss.config.iframes_on_hit)
        or BossDefaults.iframes_on_hit
    if iframes and iframes > 0 then
        Invulnerability.start(boss, iframes, "hit")
    end

    print(string.format("[BOSS_MANAGER] %s took %.1f damage (%.0f / %.0f)",
        boss.id, final_damage, boss.health, boss.max_health))

    -- Update health bar
    if boss_health_bar_enabled(boss) then
        M.update_boss_health_bar(boss_id)
    end

    -- Feedback belongs to accepted damage so weak points also trigger it.
    -- Preserve custom component audio, otherwise use the configured sound bank.
    local feedback = Util.deep_copy(boss.config.boss_hit_feedback or {})
    if not boss.config.boss_hit_feedback and boss.config.audio and boss.config.audio.hurt then
        SafeSound.play(boss.config.audio.hurt)
        feedback.sfx = false
    end
    CombatFeedback.impact("boss_hurt", final_damage, feedback)
    if boss.anim_url then
        local color = feedback.flash_color or boss.config.hurt_flash_color or BossDefaults.hurt_flash_color
        local duration = feedback.flash_duration or boss.config.hurt_flash_duration or BossDefaults.hurt_flash_duration
        if color and duration and duration > 0 then
            msg.post(boss.anim_url, "anim.flash", {
                color = vmath.vector4(color[1], color[2], color[3], color[4]),
                duration = duration,
            })
        end
    end

    -- Check if defeated
    if boss.health <= 0 then
        M.kill_boss(boss_id, source)
    end

    return true
end

--- Kill a boss
-- Two-phase defeat: on_defeat_start fires immediately (cinematic window),
-- then after defeat_cleanup_delay on_defeat_complete fires (rewards, cleanup).
-- @param boss_id Boss identifier
-- @param source What killed the boss
function M.kill_boss(boss_id, source)
    local boss = active_bosses[boss_id]

    if not boss or boss.defeated then
        return
    end

    boss.defeated = true
    boss.health = 0
    boss.defeat_source = source
    boss.defeat_time = Time.gettime()
    boss.encounter_player_damage_taken = encounter_metrics.player_damage_taken

    if not has_undefeated_bosses() then
        stop_encounter_tracking()
    end

    print(string.format("[BOSS_MANAGER] %s defeated!", boss.config.name))

    -- Commit rewards and defeat before any delayed visual cleanup. An exit or
    -- unload during the death animation must never save an unrewarded defeat.
    local boss_type_id = resolve_boss_identity_id(boss, boss_id)
    local CP = require "mvtk.core.checkpoint"
    local saved, save_error = CP.batch("boss_defeated", function()
        M.process_defeat_rewards(boss_id, source)
        Flags.set("boss_defeated_" .. tostring(boss_type_id), true)
    end)
    if not saved then
        log.warn("Boss progress could not be saved: %s", tostring(save_error))
        pcall(msg.post, "main:/toast_gui#toast", "toast", { text = "Progress could not be saved. Try a save point." })
    end

    -- ---- Phase 1: on_defeat_start (cinematic / dramatic pause) ----

    -- Broadcast so listeners (cutscenes, cameras, UI) can react immediately.
    BossUI.send("boss_defeat_start", {
        boss_id = boss_id,
        boss_name = boss.config.name,
    })
    pcall(msg.post, "main:/main_go#script", hash("boss_defeat_start"), {
        boss_id = boss_id,
        boss_type = boss_type_id,
    })

    -- Play death sound / animation cue
    if boss.config.audio and boss.config.audio.death then
        SafeSound.play(boss.config.audio.death)
    end

    -- Stop boss music
    stop_active_music(boss_id)

    -- Optional victory music cue after the boss theme is released.
    if boss.config.audio and boss.config.audio.victory then
        local Audio = Util.require_module("mvtk.audio.audio")
        if Audio and Audio.music then
            pcall(Audio.music, boss.config.audio.victory, { t = 0.3 })
        end
    end

    -- Configurable delay before cleanup (gives cinematic / loot time)
    local cleanup_delay = (boss.config.defeat_cleanup_delay)
        or BossDefaults.defeat_cleanup_delay
        or 2.0

    require("mvtk.core.pause").delay(cleanup_delay, function()
        M._on_defeat_complete(boss_id, source, boss_type_id)
    end)
end

--- Internal: second phase of defeat, called after the cinematic delay.
function M._on_defeat_complete(boss_id, source, boss_type_id)
    local boss = active_bosses[boss_id]
    if not boss then return end

    -- Hide health bar
    if boss_health_bar_enabled(boss) then
        M.hide_boss_health_bar(boss_id)
    end

    -- Unlock arena
    if boss.config.arena then
        M.unlock_arena(boss.config.arena, boss.config.room_id)
    end

    -- Tear down arena hazards / platforms so the defeated room is safe to
    -- walk through (no leftover spikes, lava, etc.).
    local BossArena = Util.require_module("mvtk.bosses.boss_arena")
    if BossArena then
        if BossArena.clear_all_hazards then pcall(BossArena.clear_all_hazards) end
        if BossArena.clear_all_platforms then pcall(BossArena.clear_all_platforms) end
        if BossArena.clear_all_effects then pcall(BossArena.clear_all_effects) end
        if BossArena.deactivate_arena then pcall(BossArena.deactivate_arena) end
    end

    boss.defeat_cleanup_complete = true
    -- Broadcast defeat complete
    BossUI.send("boss_defeat_complete", {
        boss_id = boss_id,
        boss_name = boss.config and boss.config.name,
    })
    pcall(msg.post, "main:/main_go#script", hash("boss_defeated"), {
        boss_id = boss_id,
        boss_type = boss_type_id,
    })
end

--- Process defeat rewards
-- Supports conditional bonus drops based on fight performance:
--   no_hit_bonus   — extra drops if the player took zero damage
--   time_bonus     — extra drops if the fight lasted less than max_time seconds
--   difficulty_bonus — extra drops if difficulty multiplier >= threshold
-- @param boss_id Boss identifier
-- @param source Who defeated the boss
function M.process_defeat_rewards(boss_id, source)
    local boss = active_bosses[boss_id]
    if not boss or boss.rewards_processed then return end
    local rewards = boss.config.on_defeat

    if not rewards then
        return
    end


    -- Award currency
    if rewards.currency then
        local amount = math.random(rewards.currency.min, rewards.currency.max)
        M.award_currency(source, amount)
    end

    -- Spawn standard drops
    if rewards.drops then
        M.spawn_drops(boss.position, rewards.drops)
    end

    -- ---- Conditional bonus drops ----
    local fight_duration = boss.defeat_time and boss.spawn_time
        and (boss.defeat_time - boss.spawn_time) or math.huge

    -- No-hit bonus: extra drops when the player wasn't damaged during the fight.
    -- Config example: no_hit_bonus = { drops = { health_up = { chance = 1, amount = 1 } } }
    -- Call M.on_player_damaged() from your player damage handler to track hits.
    if rewards.no_hit_bonus then
        local player_took_damage = (boss.encounter_player_damage_taken
            or encounter_metrics.player_damage_taken) > 0
        if not player_took_damage and rewards.no_hit_bonus.drops then
            print("[BOSS_MANAGER] No-hit bonus drops!")
            M.spawn_drops(boss.position, rewards.no_hit_bonus.drops)
        end
    end

    -- Time bonus: extra drops when the fight was completed quickly.
    -- Config example: time_bonus = { max_time = 60, drops = { speed_gem = { chance = 1, amount = 1 } } }
    if rewards.time_bonus and rewards.time_bonus.max_time then
        if fight_duration <= rewards.time_bonus.max_time and rewards.time_bonus.drops then
            print(string.format("[BOSS_MANAGER] Time bonus drops! (%.1fs <= %.1fs)",
                fight_duration, rewards.time_bonus.max_time))
            M.spawn_drops(boss.position, rewards.time_bonus.drops)
        end
    end

    -- Difficulty bonus: extra drops on harder difficulties.
    -- Config example: difficulty_bonus = { min_multiplier = 1.5, drops = { rare_gem = { chance = 0.5, amount = 1 } } }
    if rewards.difficulty_bonus and rewards.difficulty_bonus.min_multiplier then
        local ok_diff, Difficulty = pcall(require, "mvtk.core.difficulty")
        local current_mult = ok_diff and Difficulty and Difficulty.get_multiplier and Difficulty.get_multiplier() or 1.0
        if current_mult >= rewards.difficulty_bonus.min_multiplier and rewards.difficulty_bonus.drops then
            print("[BOSS_MANAGER] Difficulty bonus drops!")
            M.spawn_drops(boss.position, rewards.difficulty_bonus.drops)
        end
    end

    -- Set unlock flags
    if rewards.unlock_flag then
        M.set_unlock_flag(rewards.unlock_flag)
    end

    -- Unlock fast travel point
    if rewards.unlock_fast_travel then
        local FastTravel = require "mvtk.core.fast_travel"
        assert(FastTravel.grant_reward(rewards.unlock_fast_travel), "Invalid fast-travel reward")
        Flags.set("fast_travel_" .. tostring(rewards.unlock_fast_travel), true)
        print(string.format("[BOSS_MANAGER] Unlocked fast travel: %s", rewards.unlock_fast_travel))
    end
    boss.rewards_processed = true
end

--- Get boss health percentage
-- @param boss_id Boss identifier
-- @return Health as percentage (0.0 to 1.0)
function M.get_boss_health_percent(boss_id)
    local boss = active_bosses[boss_id]
    if not boss then
        return 0
    end

    return boss.health / boss.max_health
end

--- Get boss data
-- @param boss_id Boss identifier
-- @return Boss data or nil
function M.get_boss(boss_id)
    return active_bosses[boss_id]
end

--- Find an active boss id by tag or type
-- @param criteria table { boss_id?, boss_tag?, boss_type?, id? }
-- @return boss_id or nil
function M.find_boss_id(criteria)
    criteria = criteria or {}
    if criteria.id and active_bosses[criteria.id] then
        return criteria.id
    end

    local tag = criteria.boss_id or criteria.boss_tag or criteria.tag
    local boss_type = criteria.boss_type or criteria.type

    for id, boss in pairs(active_bosses) do
        if tag then
            if boss.tag == tag or boss.spawn_id == tag then
                return id
            end
            if boss.config and (boss.config.boss_tag == tag or boss.config.spawn_id == tag or boss.config.boss_id == tag) then
                return id
            end
        end
        if boss_type and boss.type == boss_type then
            return id
        end
    end

    return nil
end

--- Get boss current phase (for phase controller)
-- @param boss_id Boss identifier
-- @return Phase index
function M.get_boss_phase(boss_id)
    local boss = active_bosses[boss_id]
    if not boss or not boss.phase_controller then
        return 1
    end

    return boss.phase_controller:get_current_phase_index()
end

--- Force a boss to a specific phase (if it has a phase controller)
-- @param boss_id Boss identifier
-- @param phase_index Target phase index (1-based)
-- @return true if forced
function M.force_phase(boss_id, phase_index)
    local boss = active_bosses[boss_id]
    if not boss or not boss.phase_controller or not boss.phase_controller.force_phase then
        return false
    end
    boss.phase_controller:force_phase(phase_index)
    return true
end

--- Remove a boss
-- @param boss_id Boss identifier
function M.remove_boss(boss_id)
    CombatFeedback.remove_boss(boss_id)
    if active_bosses[boss_id] then
        print(string.format("[BOSS_MANAGER][MUSIC] remove_boss clearing music for %s", tostring(boss_id)))
        stop_active_music(boss_id)
        active_bosses[boss_id] = nil
        if not has_undefeated_bosses() then
            stop_encounter_tracking()
        end
        print(string.format("[BOSS_MANAGER] Removed boss %s", boss_id))
    end
end

--- Get attack pattern definition
-- @param pattern_name Pattern name
-- @return Pattern table or nil
function M.get_attack_pattern(pattern_name)
    return attack_patterns[pattern_name]
end

local CHARGE_PATTERN_OVERRIDES = {
    charge_speed = "dash_speed",
    charge_distance = "dash_distance",
    charge_telegraph_time = "telegraph_time",
    charge_duration = "duration",
    charge_cooldown = "cooldown",
    charge_recovery = "recovery",
    charge_edge_padding = "edge_padding",
}

local POSITIVE_CHARGE_OVERRIDES = {
    charge_speed = true,
    charge_distance = true,
}

local function apply_direct_charge_pattern_overrides(pattern, source)
    for source_key, pattern_key in pairs(CHARGE_PATTERN_OVERRIDES) do
        local value = tonumber(source[source_key])
        local accepts_value = value ~= nil and value >= 0
            and (not POSITIVE_CHARGE_OVERRIDES[source_key] or value > 0)
        if accepts_value then
            pattern[pattern_key] = value
        end
    end
end

local function apply_charge_pattern_overrides(pattern, source)
    if type(pattern) ~= "table" or type(source) ~= "table" then
        return
    end

    -- Also accept an explicit attack_tuning table for hand-authored presets.
    -- Tiled class properties are flattened, so their values are applied by
    -- the second pass and take precedence over this optional nested form.
    if type(source.attack_tuning) == "table" then
        apply_direct_charge_pattern_overrides(pattern, source.attack_tuning)
    end
    apply_direct_charge_pattern_overrides(pattern, source)
end

local function resolve_boss_reference(boss_or_id)
    if type(boss_or_id) == "string" then
        return active_bosses[boss_or_id]
    end
    if type(boss_or_id) ~= "table" then
        return nil
    end
    if type(boss_or_id.boss_data) == "table" then
        return boss_or_id.boss_data
    end
    return boss_or_id
end

local function resolve_phase_reference(boss, phase)
    if type(phase) == "table" then
        return phase
    end
    if type(phase) == "number" then
        local phases = boss and boss.config and boss.config.phases
        return type(phases) == "table" and phases[phase] or nil
    end

    local controller = boss and boss.phase_controller
    if controller and controller.get_current_phase then
        return controller:get_current_phase()
    end
    return nil
end

--- Resolve an independent attack pattern for one boss and phase.
-- Precedence is framework pattern < merged boss preset/Tiled instance config
-- < current Tiled phase. The manager's spawn merge already establishes the
-- preset-versus-instance portion of that ordering.
-- @param pattern_name Pattern name
-- @param boss_or_id Boss manager record, boss script instance, or manager id
-- @param phase Optional phase table/index; defaults to the boss's current phase
-- @return A deep-copied resolved pattern, or nil
function M.resolve_attack_pattern(pattern_name, boss_or_id, phase)
    local base_pattern = attack_patterns[pattern_name]
    if type(base_pattern) ~= "table" then
        return nil
    end

    local boss = resolve_boss_reference(boss_or_id)
    local factor = 1
    if not user_pattern_names[pattern_name] or base_pattern.scale_with_tiles == true then
        factor = tonumber(boss and boss.config and boss.config.attack_pixel_scale)
            or TileSettings.width / 64
    end
    local pattern = AttackScale.scale_pattern(base_pattern, factor)
    if pattern.type ~= "charge" then
        return pattern
    end

    -- Authored charge overrides are already in world pixels, so apply them
    -- after converting the framework pattern into this world's tile units.
    apply_charge_pattern_overrides(pattern, boss and boss.config)
    apply_charge_pattern_overrides(pattern, resolve_phase_reference(boss, phase))
    return pattern
end

--- Check if attack is ready (cooldown)
-- @param boss_id Boss identifier
-- @param attack_name Attack name
-- @param resolved_pattern Optional per-boss/per-phase pattern snapshot
-- @return true if ready
function M.is_attack_ready(boss_id, attack_name, resolved_pattern)
    local boss = active_bosses[boss_id]
    if not boss then
        return false
    end

    local pattern = resolved_pattern or M.resolve_attack_pattern(attack_name, boss)
    if not pattern then
        return false
    end

    local last_used = boss.attack_cooldowns[attack_name]
    if last_used == nil then
        return true
    end
    local current_time = Time.gettime()
    local cooldown = tonumber(pattern.cooldown) or 3.0

    return (current_time - last_used) >= cooldown
end

--- Mark attack as used (start cooldown)
-- @param boss_id Boss identifier
-- @param attack_name Attack name
function M.use_attack(boss_id, attack_name)
    local boss = active_bosses[boss_id]
    if not boss then
        return
    end

    local current_time = Time.gettime()
    boss.attack_cooldowns[attack_name] = current_time
end

--[[============================================================================
    INTEGRATION POINTS
==============================================================================]]

--- Show boss health bar
-- @param boss_id Boss identifier
function M.show_boss_health_bar(boss_id)
    local boss = active_bosses[boss_id]
    if not boss then
        return
    end
    if not boss_health_bar_enabled(boss) then
        return
    end

    print(string.format("[BOSS_MANAGER] Showing health bar: %s", boss.config.name))

    BossUI.send("show_boss_health", {
        boss_id = boss_id,
        boss_name = boss.config.name,
        hp = boss.health,
        hp_max = boss.max_health,
        current_phase = boss.phase_controller and boss.phase_controller:get_current_phase_index() or 1,
        total_phases = boss.config.phases and #boss.config.phases or 1,
        health_bar_position = normalize_health_bar_position(boss.config.health_bar_position),
    })

    if BossUI.count() == 0 then
        _orig_print(string.format("[BOSS_MANAGER] WARNING: No boss HUD registered for '%s'. Add a boss health bar GUI or set show_health_bar=false in the boss config.", boss_id))
    end
end

--- Update boss health bar
-- @param boss_id Boss identifier
function M.update_boss_health_bar(boss_id)
    local boss = active_bosses[boss_id]
    if not boss then
        return
    end
    if not boss_health_bar_enabled(boss) then
        return
    end

    BossUI.send("update_boss_health", {
        hp = boss.health,
        hp_max = boss.max_health,
    })
end

--- Hide boss health bar
-- @param boss_id Boss identifier
function M.hide_boss_health_bar(boss_id)
    local boss = active_bosses[boss_id]
    if boss and not boss_health_bar_enabled(boss) then
        return
    end
    print("[BOSS_MANAGER] Hiding health bar")
    BossUI.send("boss_defeated", {})
end

--- Re-send boss health bar state to any newly-registered HUD listeners.
-- Useful when the boss spawns before the GUI script has initialized.
function M.refresh_boss_health_bars()
    for boss_id, boss in pairs(active_bosses) do
        if boss and not boss.defeated and boss_health_bar_enabled(boss) then
            M.show_boss_health_bar(boss_id)
        end
    end
end

--- Lock arena doors
-- @param arena_id Arena identifier (optional, may be prefixed with "arena_")
-- @param room_id Room identifier for door locking (preferred)
function M.lock_arena(arena_id, room_id)
    print(string.format("[BOSS_MANAGER] Locking arena: %s", tostring(arena_id)))

    local target_room = room_id
    if not target_room and type(arena_id) == "string" then
        target_room = arena_id:gsub("^arena_", "")
    end

    if target_room and target_room ~= "" then
        pcall(msg.post, "main:/room_manager#script", hash("lock_room"), {
            room_id = target_room,
            source = "boss_manager",
        })
    else
        print("[BOSS_MANAGER] Warning: no room_id provided for arena lock")
    end
end

--- Unlock arena doors
-- @param arena_id Arena identifier (optional, may be prefixed with "arena_")
-- @param room_id Room identifier for door unlocking (preferred)
function M.unlock_arena(arena_id, room_id)
    print(string.format("[BOSS_MANAGER] Unlocking arena: %s", tostring(arena_id)))

    local target_room = room_id
    if not target_room and type(arena_id) == "string" then
        target_room = arena_id:gsub("^arena_", "")
    end

    if target_room and target_room ~= "" then
        pcall(msg.post, "main:/room_manager#script", hash("unlock_room"), {
            room_id = target_room,
            source = "boss_manager",
        })
    else
        print("[BOSS_MANAGER] Warning: no room_id provided for arena unlock")
    end
end

--- Reset all active bosses (e.g., on player death)
-- @param reason Optional reason string for logging
function M.reset_active_bosses(reason)
    local count = 0
    for boss_id, boss in pairs(active_bosses) do
        if boss and not boss.defeated then
            -- Unlock arena if it was locked
            if boss.config and boss.config.arena then
                M.unlock_arena(boss.config.arena, boss.config.room_id)
            end
            -- Hide health bar and stop music
            if boss_health_bar_enabled(boss) then
                M.hide_boss_health_bar(boss_id)
            end
            stop_active_music(boss_id)
        end
        active_bosses[boss_id] = nil
        count = count + 1
    end
    reset_encounter_tracking()
    print(string.format("[BOSS_MANAGER] Reset active bosses: %d (reason=%s)", count, tostring(reason)))
    return count
end

--- Award currency to player
-- @param player_id Player identifier
-- @param amount Currency amount
function M.award_currency(player_id, amount)
    local value = math.floor(math.max(0, tonumber(amount) or 0))
    if value <= 0 then
        return true
    end

    local Inventory = Util.require_module("mvtk.core.inventory")
    if not (Inventory and Inventory.add_currency) then
        log.warn("Could not award %d currency; inventory backend is unavailable", value)
        return false
    end

    local ok, err = pcall(Inventory.add_currency, value)
    if not ok then
        log.warn("Could not award %d currency: %s", value, tostring(err))
        return false
    end

    print(string.format("[BOSS_MANAGER] Awarded %d currency", value))
    return true
end

--- Spawn drops at position
-- @param position Drop position
-- @param drops Table of drops { item_id = { chance = 0.5, amount = 1 }, ... }
function M.spawn_drops(position, drops)
    print(string.format("[BOSS_MANAGER] Spawning drops at (%.0f, %.0f)", position.x, position.y))

    local CollectibleManager = Util.require_module("mvtk.collectibles.collectible_manager")
    if not CollectibleManager then
        print("[BOSS_MANAGER] Warning: CollectibleManager not available, drops skipped")
        return
    end

    -- Spread drops in a circle around the boss position
    local drop_index = 0
    local max_drops = 0
    for _ in pairs(drops) do max_drops = max_drops + 1 end

    for item_id, drop_config in pairs(drops) do
        local chance = drop_config.chance or 1.0
        local min_amount = tonumber(drop_config.min or drop_config.amount) or 1
        local max_amount = tonumber(drop_config.max or drop_config.amount) or min_amount
        if max_amount < min_amount then
            max_amount = min_amount
        end
        local amount = (max_amount > min_amount) and math.random(min_amount, max_amount) or min_amount

        if math.random() <= chance then
            for i = 1, amount do
                -- Calculate spread position
                local angle = (drop_index / math.max(max_drops, 1)) * math.pi * 2 + (i * 0.3)
                local spread = 30 + (i * 15)  -- Spread further for multiple drops
                local drop_pos = vmath.vector3(
                    position.x + math.cos(angle) * spread,
                    position.y + math.sin(angle) * spread + 20,  -- Slight upward
                    position.z or 0
                )
                
                local id = CollectibleManager.spawn_collectible(item_id, drop_pos, {
                    from_boss = true,
                    boss_drop = true
                })
                
                if id then
                    print(string.format("[BOSS_MANAGER] Dropped: %s at (%.0f, %.0f)", item_id, drop_pos.x, drop_pos.y))
                end
            end
        end
        drop_index = drop_index + 1
    end
end

--- Set unlock flag
-- @param flag_name Flag to set
function M.set_unlock_flag(flag_name)
    print(string.format("[BOSS_MANAGER] Setting unlock flag: %s", flag_name))
    Flags.set(flag_name, true)
end

--[[============================================================================
    UTILITY
==============================================================================]]

--- Get all active bosses
-- @return Table of boss IDs
function M.get_active_bosses()
    local boss_ids = {}
    for boss_id, _ in pairs(active_bosses) do
        table.insert(boss_ids, boss_id)
    end
    return boss_ids
end

--- Get active boss count
-- @return Number of active bosses
function M.get_boss_count()
    local count = 0
    for _ in pairs(active_bosses) do
        count = count + 1
    end
    return count
end

--- Check if any boss is active
-- @return true if at least one boss is active
function M.completion_pending()
    for _,boss in pairs(active_bosses) do
        if not boss.defeated or not boss.defeat_cleanup_complete then return true end
    end
    return false
end
function M.has_active_boss()
    return M.get_boss_count() > 0
end

--- Clear all bosses
function M.clear_all()
    CombatFeedback.clear_bosses()
    print("[BOSS_MANAGER][MUSIC] clear_all -> stop_active_music()")
    stop_active_music()
    active_bosses = {}
    boss_id_counter = 0
    reset_encounter_tracking()
    print("[BOSS_MANAGER] Cleared all bosses")
end

--- Print debug info
function M.print_debug()
    print("=== BOSS MANAGER DEBUG ===")
    print(string.format("Active bosses: %d", M.get_boss_count()))

    for boss_id, boss in pairs(active_bosses) do
        print(string.format("  %s (%s): %.0f / %.0f HP (%.0f%%)",
            boss.config.name, boss_id,
            boss.health, boss.max_health,
            (boss.health / boss.max_health) * 100))
    end

    print("==========================")
end

--- Check if a boss identity has been defeated (persistence check)
-- @param boss_type_id Boss preset id or authored boss_id
-- @return true if boss has been defeated in a previous session
function M.is_boss_defeated(boss_type_id)
    return Flags.get("boss_defeated_" .. tostring(boss_type_id)) == true
end

--- Notify the boss manager that the player took damage while a boss is active.
--- Call this from your player damage handler to enable encounter-scoped
--- no-hit bonus tracking.
function M.on_player_damaged()
    if encounter_metrics.tracking_active then
        encounter_metrics.player_damage_taken = encounter_metrics.player_damage_taken + 1
    end
end

return M

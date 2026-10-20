-- mvtk/bosses/boss_animations.lua
-- ============================================================================
-- Boss Animation Resolver
-- ============================================================================
-- Resolves a runtime semantic key like:
--   walk, hurt, parry, summon, phase_transition
--
-- against the toolkit's standard generic boss animation contract in
-- developer/config/boss_animations.lua.
--
-- Bosses should author this compact contract:
--   idle, move, hit, defend, phase, death, attack_1 .. attack_5
--
-- Resolution order:
--   1. Exact key in the generic contract
--   2. Generic alias slot in the generic contract
--   3. nil
--
-- Returning nil on miss lets callers skip optional animations like `intro`
-- cleanly. For "play something, anything" behavior, use resolve_or_key().
-- ============================================================================

local Util = require "mvtk.core.util"

local M = {}

local Slots = Util.require_config("developer.config.boss_animations", {})

local GENERIC_SLOT_FALLBACKS_BY_KEY = {
    move = { "move" },
    hit = { "hit" },
    defend = { "defend" },
    phase = { "phase" },

    walk = { "move", "idle" },
    run = { "move", "idle" },
    idle_alt = { "idle" },
    jump_start = { "move", "idle" },
    jump_air = { "move", "idle" },
    land = { "move", "idle" },
    hover_idle = { "move", "idle" },
    hover_move = { "move", "idle" },
    fly_takeoff = { "move", "phase" },
    fly_land = { "move", "phase" },
    crawl_idle = { "move", "idle" },
    crawl_move = { "move", "idle" },
    wall_crawl_up = { "move", "idle" },
    wall_crawl_down = { "move", "idle" },
    burrow_idle = { "move", "idle" },
    burrow_out = { "phase", "attack_5", "attack_4" },
    burrow_in = { "phase", "attack_5", "attack_4" },

    flinch = { "hit" },
    hurt = { "hit" },
    stagger = { "hit" },
    stunned = { "hit", "idle" },
    recover = { "hit", "idle" },

    block = { "defend" },
    block_impact = { "defend", "hit" },
    shield_up = { "defend" },
    shield_down = { "defend" },
    parry = { "defend" },
    counter = { "defend", "attack_5" },

    attack = { "attack_1" },
    slash_1 = { "attack_1" },
    vine_attack = { "attack_1" },
    windup_light = { "attack_1" },
    swing = { "attack_1" },

    ranged_attack = { "attack_2" },
    dash_attack = { "attack_2" },
    throw = { "attack_2" },
    barrage = { "attack_2" },
    cast_dark = { "attack_2" },
    shadow_cast = { "attack_2" },
    poison_cast = { "attack_2" },
    fire_cast = { "attack_2" },
    root_attack = { "attack_2" },
    laser_charge = { "attack_2" },
    slash_2 = { "attack_2" },
    vine_fury_2 = { "attack_2" },
    dash_wind = { "attack_2", "move" },
    dash = { "attack_2", "move" },
    charge_loop = { "attack_2", "move" },
    aim = { "attack_2" },
    shoot = { "attack_2" },

    thrust = { "attack_3" },
    slam = { "attack_3" },
    shadow_burst = { "attack_3" },
    laser_sweep = { "attack_3" },
    dark_beam = { "attack_3" },
    blade_storm = { "attack_3" },
    overload = { "attack_3" },
    windup_heavy = { "attack_3" },
    beam_start = { "attack_3" },
    beam_loop = { "attack_3" },
    beam_end = { "attack_3" },
    dash_end = { "attack_3", "move" },
    vine_fury_3 = { "attack_3" },

    summon = { "attack_4", "attack_5" },
    summon_dark = { "attack_4", "attack_5" },
    crystal_summon = { "attack_4", "attack_5" },
    heal = { "attack_4", "attack_5" },
    grab_start = { "attack_4" },
    grab_hold = { "attack_4" },
    grab_throw = { "attack_4" },
    cast_start = { "attack_4" },
    cast_loop = { "attack_4" },
    cast_end = { "attack_4" },
    spawn_minion = { "attack_4", "attack_5" },
    portal_open = { "attack_4", "phase" },
    portal_close = { "attack_4", "phase" },
    vine_fury_4 = { "attack_4", "attack_5" },

    split = { "attack_5", "attack_4" },
    teleport = { "attack_5", "phase" },
    berserk_start = { "attack_5", "phase" },
    ultimate = { "attack_5", "attack_4" },
    roar = { "attack_5", "phase" },
    taunt = { "attack_5", "phase" },
    enrage = { "attack_5", "phase" },
    victory = { "attack_5", "phase" },
    phase_transition = { "phase", "attack_5" },
    teleport_out = { "phase", "attack_5" },
    teleport_in = { "phase", "attack_5" },
}

local function resolve_exact(key)
    local value = Slots[key]
    if value ~= nil and value ~= "" then
        return value
    end
    return nil
end

local function resolve_generic_alias(key)
    local fallbacks = GENERIC_SLOT_FALLBACKS_BY_KEY[key]
    if type(fallbacks) ~= "table" then
        return nil
    end

    for _, slot in ipairs(fallbacks) do
        local resolved = resolve_exact(slot)
        if resolved then
            return resolved
        end
    end

    return nil
end

function M.resolve(_, key)
    if type(key) ~= "string" or key == "" then
        return nil
    end

    local exact = resolve_exact(key)
    if exact then
        return exact
    end

    return resolve_generic_alias(key)
end

-- When a sprite atlas lacks a generic slot name, try these common art names
-- (placeholder atlases use walk/attack/attack_alt rather than move/attack_1/..).
M.ATLAS_ALIASES = {
    idle = { "rest", "hover" },
    move = { "walk", "run", "fly", "hover", "idle" },
    hit = { "hurt", "stagger", "stun" },
    defend = { "block", "shield", "parry" },
    phase = { "phase_transition", "roar", "transform", "enrage" },
    death = { "die", "death_final" },
    attack_1 = { "attack", "slam", "attack_combo" },
    attack_2 = { "attack_alt", "ranged_attack", "attack" },
    attack_3 = { "slam", "attack_combo", "spin_attack", "attack" },
    attack_4 = { "summon", "spawn_minions", "projectile_burst", "attack" },
    attack_5 = { "roar", "enrage", "power_up", "attack" },
}

--- Name to play for `name` on a sprite atlas: itself when present, else the
-- first present alias, else nil (skip; never ask the engine for a clip the
-- atlas lacks). Unknown atlases (not in the bake manifest) pass through.
function M.present_in_atlas(atlas_path, name)
    if not name or name == "" or not atlas_path then return name end
    local ok, AnimIndex = pcall(require, "mvtk.core.anim_index")
    if not ok or not AnimIndex or not AnimIndex.has then return name end
    local present = AnimIndex.has(atlas_path, name)
    if present ~= false then return name end
    for _, alias in ipairs(M.ATLAS_ALIASES[tostring(name)] or {}) do
        if AnimIndex.has(atlas_path, alias) == true then return alias end
    end
    return nil
end

function M.resolve_or_key(boss, key)
    if type(key) ~= "string" or key == "" then
        return key
    end
    return M.resolve(boss, key) or key
end

function M.get_set_name()
    return "generic_boss_slots"
end

return M

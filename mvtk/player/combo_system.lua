-- mvtk/player/combo_system.lua
-- ============================================================================
-- Player Combo Attack System
-- ============================================================================
-- Manages sequential attack combos with timing windows and escalating effects.
-- Tracks combo count and provides damage/knockback/hitstop multipliers based
-- on combo progression. Supports mixed light+heavy combo finishers (togglable).
--
-- All tuning values are read from developer/config/combat_config.lua → combo table.
--
-- Usage:
--   Call M.on_attack() when player light-attacks to advance combo
--   Call M.on_heavy_attack() to check for mixed L+H finisher
--   Use M.get_damage_multiplier() etc. to scale attack effects
--   Call M.update(dt) each frame to handle combo timeout

local M = {}

local Util = require "mvtk.core.util"
local Time = require "mvtk.core.time"

-- Debug-gate prints
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.combat and _Dbg.combat.combo then
        _orig_print(...)
    end
end

-- ============================================================================
-- CONFIGURATION (loaded from developer/config/combat_config.lua → combo)
-- ============================================================================

local CombatCfg = Util.require_config("developer.config.combat_config") or {}
local CFG = CombatCfg.combo or {}

-- Resolve config with defaults
local COMBO_ENABLED     = CFG.enabled ~= false          -- default: true
local COMBO_WINDOW      = CFG.window or 0.5             -- seconds to chain next hit
local MAX_COMBO         = CFG.max_chain or 3             -- max light chain length
local MIXED_COMBOS      = CFG.mixed_combos or false      -- allow L+H finishers

-- Per-step multiplier tables (indexed 1..MAX_COMBO, with defaults)
local DMG_MULT   = CFG.damage_multiplier   or { 1.0, 1.25, 1.5 }
local KB_MULT    = CFG.knockback_multiplier or { 1.0, 1.0, 2.0 }
local HITSTOP    = CFG.hitstop_intensity    or { "light", "medium", "heavy" }
local REACTION   = CFG.reaction_type        or { "light", "light", "medium" }
local ANIMS      = CFG.animations           or {}
local FINISHERS  = CFG.mixed_finishers      or {}

-- ============================================================================
-- STATE
-- ============================================================================

local combo_state = {
    count = 0,              -- Current combo count (1..MAX_COMBO)
    timer = 0,              -- Time remaining in combo window
    last_attack_time = 0,   -- Timestamp of last attack
    enabled = true,         -- Can be temporarily disabled (stun, cutscene)
}

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

-- Initialize/reset the combo system to default state
function M.init()
    combo_state = {
        count = 0,
        timer = 0,
        last_attack_time = 0,
        enabled = COMBO_ENABLED,
    }
end

-- Update combo timer each frame. Resets combo when window expires.
function M.update(dt)
    if combo_state.timer > 0 then
        combo_state.timer = combo_state.timer - dt
        if combo_state.timer <= 0 then
            M.reset()
        end
    end
end

-- ============================================================================
-- COMBO LOGIC
-- ============================================================================

-- Called when player executes a LIGHT attack.
-- Advances the combo chain or resets if window expired.
-- Returns: attack type string ("attack_1", "attack_2", etc.)
function M.on_attack()
    if not combo_state.enabled then return "attack_1" end

    local current_time = Time.gettime()
    local time_since_last = current_time - combo_state.last_attack_time

    if time_since_last > COMBO_WINDOW or combo_state.count <= 0 then
        combo_state.count = 1
    else
        combo_state.count = math.min(combo_state.count + 1, MAX_COMBO)
    end

    combo_state.last_attack_time = current_time
    combo_state.timer = COMBO_WINDOW

    print(string.format("[COMBO] Hit #%d/%d", combo_state.count, MAX_COMBO))

    return M.get_attack_type()
end

-- Called when player executes a HEAVY attack during an active combo.
-- If mixed_combos is enabled and a matching finisher exists, returns the
-- finisher config table. Otherwise returns nil (heavy proceeds normally).
--
-- Returns: finisher config table or nil
--   Finisher table: { anim={spine=,sprite=}, damage_mult=, knockback_mult=,
--                     hitstop=, reaction_type= }
function M.on_heavy_attack()
    if not MIXED_COMBOS then return nil end
    if not combo_state.enabled then return nil end
    if combo_state.count <= 0 or combo_state.timer <= 0 then return nil end

    local key = string.format("L%d_H", combo_state.count)
    local finisher = FINISHERS[key]

    if finisher then
        print(string.format("[COMBO] Mixed finisher %s triggered!", key))
        -- Finisher is a terminal move — reset combo
        M.reset()
        return finisher
    end

    return nil
end

-- Get the attack animation/type identifier based on current combo count
function M.get_attack_type()
    local n = combo_state.count
    if n >= 1 and n <= MAX_COMBO then
        return "attack_" .. n
    end
    return "attack_1"
end

-- ============================================================================
-- COMBO EFFECT MULTIPLIERS
-- ============================================================================

-- Get damage multiplier for current combo step
function M.get_damage_multiplier()
    local n = math.max(1, combo_state.count)
    return DMG_MULT[n] or (1.0 + (n - 1) * 0.25)
end

-- Get knockback multiplier for current combo step
function M.get_knockback_multiplier()
    local n = math.max(1, combo_state.count)
    return KB_MULT[n] or 1.0
end

-- Get hitstop intensity string for current combo step
function M.get_hitstop_intensity()
    local n = math.max(1, combo_state.count)
    return HITSTOP[n] or "light"
end

-- Get hit reaction type for current combo step
function M.get_reaction_type()
    local n = math.max(1, combo_state.count)
    return REACTION[n] or "light"
end

-- Get animation config for current combo step
-- Returns: table { spine = "anim_name", sprite = "anim_name" } or nil
function M.get_animation()
    local n = math.max(1, combo_state.count)
    return ANIMS[n] or nil
end

-- ============================================================================
-- PUBLIC API - QUERY FUNCTIONS
-- ============================================================================

-- Get current combo count (0 = no combo, 1..MAX_COMBO)
function M.get_count()
    return combo_state.count
end

-- Get maximum possible combo count
function M.get_max_combo()
    return MAX_COMBO
end

-- Check if a combo is currently active
function M.is_combo_active()
    return combo_state.count > 0 and combo_state.timer > 0
end

-- Check if mixed combos are enabled
function M.is_mixed_enabled()
    return MIXED_COMBOS
end

-- ============================================================================
-- PUBLIC API - STATE MODIFICATION
-- ============================================================================

-- Reset combo to zero
function M.reset()
    combo_state.count = 0
    combo_state.timer = 0
end

-- Enable or disable the combo system temporarily
function M.set_enabled(enabled)
    combo_state.enabled = enabled
end

return M

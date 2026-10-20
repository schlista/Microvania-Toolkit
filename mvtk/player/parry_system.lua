-- mvtk/player/parry_system.lua
-- Timed parry/counter system for defensive combat mechanics
-- Rewards precise timing with powerful counterattacks

local Util = require "mvtk.core.util"
local CombatConfig = require "mvtk.combat.config"
local CombatFeedback = require "mvtk.combat.combat_feedback"

local M = {}

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.combat and _Dbg.combat.parry then
        _orig_print(...)
    end
end

local function parry_cfg()
    local config = CombatConfig.get()
    return (config and config.parry) or {}
end

local function feature_enabled(name, fallback)
    if CombatConfig.feature_enabled then
        return CombatConfig.feature_enabled(name, fallback)
    end
    local features = CombatConfig.get().features or {}
    local value = features[name]
    if value == nil then
        if fallback == nil then
            return true
        end
        return fallback and true or false
    end
    return value and true or false
end

local PARRY_WINDOW_DURATION = 0.18
local PARRY_COOLDOWN = 0.15
local PARRY_COUNTER_DAMAGE_MULT = 2.0
local PARRY_INVINCIBILITY_FRAMES = 0.30
local PERFECT_PARRY_WINDOW = 0.08
local PARRY_COUNTER_WINDOW = 0.50
local PARRY_STUN_DURATION = 0.60

local function refresh_config()
    local cfg = parry_cfg()
    PARRY_WINDOW_DURATION = tonumber(cfg.window) or PARRY_WINDOW_DURATION
    PARRY_COOLDOWN = tonumber(cfg.cooldown) or PARRY_COOLDOWN
    PARRY_COUNTER_DAMAGE_MULT = tonumber(cfg.counter_damage_mult) or PARRY_COUNTER_DAMAGE_MULT
    PARRY_INVINCIBILITY_FRAMES = tonumber(cfg.iframes) or PARRY_INVINCIBILITY_FRAMES
    PERFECT_PARRY_WINDOW = tonumber(cfg.perfect_window) or PERFECT_PARRY_WINDOW
    PARRY_COUNTER_WINDOW = tonumber(cfg.counter_window) or PARRY_COUNTER_WINDOW
    PARRY_STUN_DURATION = tonumber(cfg.stun_duration) or PARRY_STUN_DURATION
end

-- State
local parry_active = false
local parry_timer = 0
local parry_cooldown = 0
local can_parry = true
local invincible_timer = 0
local last_parry_was_perfect = false
local parry_count = 0  -- Track consecutive parries

--- Initialize parry system
function M.init()
    refresh_config()
    parry_active = false
    parry_timer = 0
    parry_cooldown = 0
    can_parry = true
    invincible_timer = 0
    last_parry_was_perfect = false
    parry_count = 0
end

--- Update parry system
-- @param dt Delta time
function M.update(dt)
    -- Update parry window
    if parry_active then
        parry_timer = parry_timer - dt

        if parry_timer <= 0 then
            -- Parry window expired without successful parry
            parry_active = false
            parry_cooldown = PARRY_COOLDOWN
            can_parry = false
            print("[PARRY] Window expired - missed parry")
            return "parry_missed"
        end
    end

    -- Update cooldown
    if not can_parry then
        parry_cooldown = parry_cooldown - dt

        if parry_cooldown <= 0 then
            can_parry = true
            print("[PARRY] Ready to parry again")
        end
    end

    -- Update invincibility frames
    if invincible_timer > 0 then
        invincible_timer = invincible_timer - dt
    end

    return nil
end

--- Attempt to start a parry
-- @return True if parry started, false if on cooldown
function M.start_parry()
    refresh_config()
    if not feature_enabled("parry", true) then
        return false
    end
    if not can_parry then
        print("[PARRY] On cooldown")
        return false
    end

    if parry_active then
        return false  -- Already parrying
    end

    parry_active = true
    parry_timer = PARRY_WINDOW_DURATION
    print(string.format("[PARRY] Started - Window: %.3fs", PARRY_WINDOW_DURATION))

    return true
end

--- Attempt to parry an incoming attack
-- @param incoming Either a normalized combat payload or a numeric damage amount
-- @param attacker_url Legacy attacker url fallback
-- @return Table with parry result or nil if failed
function M.attempt_parry(incoming, attacker_url)
    if not parry_active then
        return nil  -- Not in parry window
    end
    refresh_config()
    if not feature_enabled("parry", true) then
        return nil
    end

    local attack = incoming
    if type(attack) ~= "table" then
        attack = {
            amount = incoming,
            source_actor = attacker_url,
            parryable = true,
        }
    end

    if attack.parryable == false then
        return nil
    end

    local attack_damage = tonumber(attack.amount or attack.damage) or 0
    local source_actor = attack.source_actor or attack.source or attacker_url

    -- Calculate if this was a perfect parry
    local time_in_window = PARRY_WINDOW_DURATION - parry_timer
    local is_perfect = feature_enabled("perfect_parry", true) and (time_in_window <= PERFECT_PARRY_WINDOW)
    local counter_enabled = feature_enabled("parry_counter", true)

    -- Successful parry!
    parry_active = false
    parry_cooldown = PARRY_COOLDOWN * 0.5  -- Reduced cooldown on success
    can_parry = false
    invincible_timer = PARRY_INVINCIBILITY_FRAMES
    last_parry_was_perfect = is_perfect
    parry_count = parry_count + 1

    if is_perfect then
        CombatFeedback.impact("perfect_parry", attack_damage, { sfx = parry_cfg().success_sfx or "parry_success" })
        print(string.format("[PARRY] * PERFECT PARRY * (%.3fs into window)", time_in_window))
    else
        CombatFeedback.impact("parry", attack_damage, { sfx = parry_cfg().success_sfx or "parry_success" })
        print(string.format("[PARRY] Successful parry (%.3fs into window)", time_in_window))
    end

    return {
        success = true,
        perfect = is_perfect,
        counter_damage = attack_damage * PARRY_COUNTER_DAMAGE_MULT * (is_perfect and 1.5 or 1.0),
        attacker_url = source_actor,
        parry_streak = parry_count,
        iframes = PARRY_INVINCIBILITY_FRAMES,
        counter_window = counter_enabled and PARRY_COUNTER_WINDOW or 0,
        stun_duration = PARRY_STUN_DURATION,
    }
end

--- Check if player is currently invincible from parry
-- @return True if invincible
function M.is_invincible()
    return invincible_timer > 0
end

--- Check if can currently parry
-- @return True if can start parry
function M.can_parry()
    return can_parry
end

--- Check if parry window is active
-- @return True if in parry window
function M.is_parrying()
    return parry_active
end

--- Get current parry window remaining time
-- @return Remaining time or 0
function M.get_parry_time_remaining()
    return parry_active and parry_timer or 0
end

--- Get parry cooldown remaining
-- @return Remaining cooldown or 0
function M.get_cooldown_remaining()
    return not can_parry and parry_cooldown or 0
end

--- Check if last parry was perfect
-- @return True if last parry was perfect
function M.was_last_parry_perfect()
    return last_parry_was_perfect
end

--- Get current parry streak
-- @return Number of consecutive successful parries
function M.get_parry_streak()
    return parry_count
end

--- Reset parry streak (call when player takes damage)
function M.reset_streak()
    parry_count = 0
    print("[PARRY] Streak reset")
end

--- Force end parry window (for interrupts)
function M.cancel_parry()
    if parry_active then
        parry_active = false
        parry_cooldown = PARRY_COOLDOWN
        can_parry = false
        print("[PARRY] Cancelled")
    end
end

--- Get parry system stats for UI
-- @return Stats table
function M.get_stats()
    return {
        can_parry = can_parry,
        is_parrying = parry_active,
        is_invincible = invincible_timer > 0,
        parry_time_remaining = parry_timer,
        cooldown_remaining = parry_cooldown,
        invincibility_remaining = invincible_timer,
        parry_streak = parry_count,
        last_was_perfect = last_parry_was_perfect
    }
end

--- Set parry system parameters
-- @param params Table of parameters to override
function M.set_params(params)
    if params.parry_window then PARRY_WINDOW_DURATION = params.parry_window end
    if params.parry_cooldown then PARRY_COOLDOWN = params.parry_cooldown end
    if params.counter_damage_mult then PARRY_COUNTER_DAMAGE_MULT = params.counter_damage_mult end
    if params.invincibility_frames then PARRY_INVINCIBILITY_FRAMES = params.invincibility_frames end
    if params.perfect_window then PERFECT_PARRY_WINDOW = params.perfect_window end
    if params.counter_window then PARRY_COUNTER_WINDOW = params.counter_window end
    if params.stun_duration then PARRY_STUN_DURATION = params.stun_duration end
end

return M

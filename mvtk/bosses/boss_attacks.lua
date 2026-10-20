--- Boss Attack Execution Module
-- Implements all boss attack types with actual damage application.
-- Used by boss.script to execute attack patterns.
--
-- This module is the boss-flavored entry point for attacks. As of Phase 5
-- step 27, each attack type lives in its own file under
-- `mvtk/bosses/boss_attacks/`. This file is now a thin shim that:
--   * imports each per-type executor,
--   * re-exports them on M as `M.execute_<type>` for back-compat,
--   * owns the `M._dispatch` table and `M.execute_pattern` entry point.
--
-- Geometry math (spread angles, aim vectors, beam/AOE hit-tests) lives in
-- mvtk/combat/attack_geometry.lua. Projectile factory spawning goes through
-- mvtk/combat/projectile_spawner.lua. All numeric defaults read from
-- developer/config/boss_defaults.lua — do not add magic numbers here.
--
-- Adding a new attack type:
--   1. Create mvtk/bosses/boss_attacks/<type>.lua exporting M.execute(boss, pattern).
--   2. Import it below and add it to MODULES.
--   3. Add the entry to M._dispatch.
--
-- @module boss_attacks

local C = require "mvtk.bosses.boss_attacks.common"

local Melee         = require "mvtk.bosses.boss_attacks.melee"
local Projectile    = require "mvtk.bosses.boss_attacks.projectile"
local AOE           = require "mvtk.bosses.boss_attacks.aoe"
local Summon        = require "mvtk.bosses.boss_attacks.summon"
local Beam          = require "mvtk.bosses.boss_attacks.beam"
local Charge        = require "mvtk.bosses.boss_attacks.charge"
local Hazard        = require "mvtk.bosses.boss_attacks.hazard"
local Combo         = require "mvtk.bosses.boss_attacks.combo"
local Special       = require "mvtk.bosses.boss_attacks.special"
local Grab          = require "mvtk.bosses.boss_attacks.grab"
local Heal          = require "mvtk.bosses.boss_attacks.heal"
local Buff          = require "mvtk.bosses.boss_attacks.buff"
local Shield        = require "mvtk.bosses.boss_attacks.shield"
local ParryWindow   = require "mvtk.bosses.boss_attacks.parry_window"
local Environmental = require "mvtk.bosses.boss_attacks.environmental"
local Mine          = require "mvtk.bosses.boss_attacks.mine"
local Wave          = require "mvtk.bosses.boss_attacks.wave"

local M = {}

-- Re-export per-type executors as M.execute_<type> for back-compat with any
-- caller that referenced them on the old monolithic module.
M.execute_melee         = Melee.execute
M.execute_projectile    = Projectile.execute
M.execute_aoe           = AOE.execute
M.execute_summon        = Summon.execute
M.execute_beam          = Beam.execute
M.execute_charge        = Charge.execute
M.execute_hazard        = Hazard.execute
M.execute_combo         = Combo.execute
M.execute_special       = Special.execute
M.execute_grab          = Grab.execute
M.execute_heal          = Heal.execute
M.execute_buff          = Buff.execute
M.execute_shield        = Shield.execute
M.execute_parry_window  = ParryWindow.execute
M.execute_environmental = Environmental.execute
M.execute_mine          = Mine.execute
M.execute_wave          = Wave.execute

-- Pattern.type -> execute_* function. Keep entries in lowercase to match
-- pattern.type values produced by `developer/config/boss_*.lua` and the
-- attack-pattern schema. `special` aliases also land here so older
-- pattern definitions ("charge", "hazard", "combo") keep working.
M._dispatch = {
    melee         = M.execute_melee,
    projectile    = M.execute_projectile,
    aoe           = M.execute_aoe,
    summon        = M.execute_summon,
    beam          = M.execute_beam,
    grab          = M.execute_grab,
    heal          = M.execute_heal,
    buff          = M.execute_buff,
    shield        = M.execute_shield,
    parry_window  = M.execute_parry_window,
    environmental = M.execute_environmental,
    mine          = M.execute_mine,
    wave          = M.execute_wave,
    -- Legacy aliases routed through execute_special for back-compat.
    special       = M.execute_special,
    charge        = M.execute_special,
    hazard        = M.execute_special,
    combo         = M.execute_special,
}

-- Stateful attacks are advanced by the boss state machine after execute().
-- Most attacks are fire-and-forget and therefore need no update/cancel hook.
M._updates = {
    charge = Charge.update,
}

M._active_checks = {
    charge = Charge.is_active,
}

M._cancellers = {
    charge = Charge.cancel,
}

local function execute_pattern(boss, pattern, opts)
    opts = opts or {}
    if not boss or not pattern then
        return
    end

    if opts.play_animation ~= false then
        C.play_pattern_animation(boss, pattern)
    end

    local fn = M._dispatch[pattern.type]
    if fn then
        return fn(boss, pattern)
    end
end

M.execute_pattern = execute_pattern

function M.update_pattern(boss, pattern, dt)
    if not (boss and pattern) then return false end
    local fn = M._updates[pattern.type]
    if fn then
        return fn(boss, pattern, dt)
    end
    return false
end

function M.is_pattern_active(boss, pattern)
    if not (boss and pattern) then return false end
    local fn = M._active_checks[pattern.type]
    return fn and fn(boss, pattern) or false
end

function M.cancel_pattern(boss, pattern)
    if not (boss and pattern) then return end
    local fn = M._cancellers[pattern.type]
    if fn then
        fn(boss, pattern)
    end
end

-- Combo re-enters the dispatcher; bind it on the common module so submodules
-- can call C.execute_pattern() without a circular require.
C.set_execute_pattern(execute_pattern)

return M

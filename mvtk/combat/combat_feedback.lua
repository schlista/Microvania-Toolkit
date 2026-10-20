-- mvtk/combat/combat_feedback.lua
-- Single owner for combat feedback: hitstop, shake, rumble, and SFX.

local Util = require "mvtk.core.util"
local CombatConfig = require "mvtk.combat.config"
local Gamefeel = Util.require_module("mvtk.core.gamefeel")
local Audio = Util.require_module("mvtk.audio.audio")
local ScreenShake = Util.require_module("mvtk.fx.screen_shake")

local M = {}
-- Per-encounter player responses, keyed by the manager id and its hash. Damage
-- messages carry only that id, keeping Defold's message buffer small.
local boss_profiles = {}
local feedback_targets = {}

local DEFAULTS = {
    melee = { shake = 6, hitstop = 0.02, rumble = 0.20, screen_shake = "light" },
    projectile = { shake = 4, hitstop = 0.015, rumble = 0.16, screen_shake = "light" },
    hurt = { shake = 5, hitstop = 0.02, rumble = 0.18, screen_shake = "medium" },
    parry = { shake = 7, hitstop = 0.03, rumble = 0.24, screen_shake = "medium" },
    perfect_parry = { shake = 9, hitstop = 0.05, rumble = 0.30, screen_shake = "heavy" },
}

local function resolve_screen_shake_preset(intensity)
    if type(intensity) == "string" and intensity ~= "" then
        return intensity
    end
    local numeric = tonumber(intensity) or 0
    if numeric >= 1.8 then
        return "critical"
    elseif numeric >= 1.3 then
        return "heavy"
    elseif numeric >= 0.8 then
        return "medium"
    elseif numeric > 0 then
        return "light"
    end
    return "medium"
end

local function resolve(kind, overrides)
    local base = Util.deep_copy(DEFAULTS[kind or "melee"] or DEFAULTS.melee)
    local config = CombatConfig.get()
    local configured = config and config.feedback and config.feedback[kind or "melee"] or nil
    if type(configured) == "table" then
        Util.deep_merge(base, configured)
    end
    if type(overrides) == "table" then
        Util.deep_merge(base, overrides)
    end
    return base
end

function M.impact(kind, amount, overrides)
    local cfg = resolve(kind, overrides)
    if Gamefeel and Gamefeel.impact then
        pcall(Gamefeel.impact, amount or 0, {
            kind = (kind == "perfect_parry") and "parry" or kind,
            shake = cfg.shake,
            hitstop = cfg.hitstop,
            rumble = cfg.rumble,
            rumble_ms = cfg.rumble_ms,
            shake_dur = cfg.shake_dur,
        })
    end
    if ScreenShake and cfg.screen_shake then
        pcall(ScreenShake.shake, cfg.screen_shake)
    end
    if Audio and cfg.sfx then
        pcall(Audio.sfx, cfg.sfx)
    end
end

-- Expose the same resolved settings to actor-specific recovery/visual handling.
function M.profile(kind, overrides)
    return resolve(kind, overrides)
end

function M.register_boss(id, player_profile)
    boss_profiles[id] = player_profile
    boss_profiles[hash(id)] = player_profile
end

function M.remove_boss(id)
    boss_profiles[id], boss_profiles[hash(id)] = nil, nil
end

function M.clear_bosses()
    boss_profiles = {}
end

function M.player_profile(payload)
    local overrides = payload and boss_profiles[payload.boss_id]
    return resolve("hurt", overrides), overrides ~= nil
end

-- Bosses and weak points confirm their own damage before producing feedback.
-- Generic attack effects must not bypass their authored zero/none settings.
function M.set_target_owner(id, enabled)
    feedback_targets[id] = enabled and true or nil
end

function M.attack_impact(kind, amount, source_boss_id, target, overrides)
    if source_boss_id and source_boss_id ~= hash("") then return end
    if feedback_targets[target] then return end
    M.impact(kind, amount, overrides)
end

function M.play_sfx(sound_id)
    if Audio and sound_id then
        pcall(Audio.sfx, sound_id)
    end
end

function M.screen_shake(_duration, intensity)
    if ScreenShake then
        pcall(ScreenShake.shake, resolve_screen_shake_preset(intensity))
    end
end

function M.flash(opts)
    opts = opts or {}
    pcall(msg.post, "/camera#camera", hash("flash_screen"), {
        color = opts.color or vmath.vector4(1, 1, 1, 0.5),
        duration = tonumber(opts.duration) or 0.15,
    })
end

return M

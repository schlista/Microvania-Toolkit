-- mvtk/core/difficulty.lua
-- Central difficulty profile loader and helpers.

local Util = require "mvtk.core.util"

local M = {}

local Config = Util.require_config("developer.config.difficulty_settings")
local current = "normal"
local profiles = {
    normal = {
        damage_taken_mult = 1.0,
        damage_dealt_mult = 1.0,
        enemy_health_mult = 1.0,
        loot_mult = 1.0,
    }
}

local function load()
    profiles = Config.profiles or profiles
    current = Config.current or current
end

load()

function M.set(name)
    if profiles[name] then
        current = name
    end
end

function M.get()
    return current, profiles[current] or profiles.normal
end

function M.damage_taken_mult()
    local _, p = M.get()
    return p.damage_taken_mult or 1.0
end

function M.damage_dealt_mult()
    local _, p = M.get()
    return p.damage_dealt_mult or 1.0
end

function M.enemy_health_mult()
    local _, p = M.get()
    return p.enemy_health_mult or 1.0
end

function M.loot_mult()
    local _, p = M.get()
    return p.loot_mult or 1.0
end

return M

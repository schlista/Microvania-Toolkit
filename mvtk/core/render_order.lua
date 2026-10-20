local Settings = require "developer.config.render_settings"

local M = {}
local CLIP_MIN_Z = -0.99
local CLIP_MAX_Z = 0.99

local function read_number(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local PLAYER_Z = clamp(read_number(Settings.player_z, 0.90), CLIP_MIN_Z, CLIP_MAX_Z)
local FOREGROUND_BASE_Z = clamp(read_number(Settings.foreground_base_z, 0.96), PLAYER_Z, CLIP_MAX_Z)
local FOREGROUND_LAYER_STEP = math.max(0, read_number(Settings.foreground_layer_step, 0.005))
local FOREGROUND_OBJECT_STEP = math.max(0, read_number(Settings.foreground_object_step, 0.00005))

function M.player_z()
    return PLAYER_Z
end

-- Enemies draw above every baked tile layer and below the player.
local ENEMY_Z = clamp(read_number(Settings.enemy_z, 0.50), CLIP_MIN_Z, PLAYER_Z)

function M.enemy_z()
    return ENEMY_Z
end

-- Bosses draw above painted backgrounds, below summoned enemies and the player.
local BOSS_Z = clamp(read_number(Settings.boss_z, 0.45), CLIP_MIN_Z, ENEMY_Z)

function M.boss_z()
    return BOSS_Z
end

function M.imported_foreground_layer_z(layers_above)
    local above = math.max(1, math.floor(read_number(layers_above, 1)))
    return clamp(FOREGROUND_BASE_Z + ((above - 1) * FOREGROUND_LAYER_STEP), FOREGROUND_BASE_Z, CLIP_MAX_Z)
end

function M.imported_foreground_object_step(draw_count)
    local count = math.max(1, math.floor(read_number(draw_count, 1)))
    if FOREGROUND_LAYER_STEP > 0 then
        return math.min(FOREGROUND_OBJECT_STEP, (FOREGROUND_LAYER_STEP * 0.9) / count)
    end
    return FOREGROUND_OBJECT_STEP
end

return M

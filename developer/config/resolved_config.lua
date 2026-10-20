-- developer/config/resolved_config.lua
-- Runtime-resolved project configuration.
--
-- Runtime systems read this merged view instead of checking runtime settings
-- and authored config files separately.

local Util = require("mvtk.core.util")
local GameConfig = require("developer.config.game_config")
local RuntimeSettings = require("developer.config.runtime_settings")

local RUNTIME_SECTION_MAP = {
    player = "player",
    camera = "camera",
    visual = "visual",
    progression = "progression",
}

local function merge_runtime_section(config, runtime, runtime_key, config_key)
    local section = runtime[runtime_key]
    if type(section) ~= "table" then
        return
    end
    config[config_key] = config[config_key] or {}
    Util.deep_merge(config[config_key], section)
end

local Config = Util.deep_copy(GameConfig)
local Runtime = RuntimeSettings.load() or {}

for runtime_key, config_key in pairs(RUNTIME_SECTION_MAP) do
    merge_runtime_section(Config, Runtime, runtime_key, config_key)
end

Config.camera = Config.camera or {}
if Config.camera.pull_from_go == nil then
    Config.camera.pull_from_go = true
else
    Config.camera.pull_from_go = Util.to_bool(Config.camera.pull_from_go, true)
end

-- ----------------------------------------------------------------------
-- Spine-bone-driven player physics gate.
-- Returns true ONLY when player_type == "spine" AND the spine_physics
-- block exists and is enabled. Fail-safe: any missing structure returns
-- false so sprite mode is never accidentally affected.
-- Read once at player init; do not poll mid-session in v1.
-- ----------------------------------------------------------------------
function Config.is_spine_physics_active()
    local player = Config.player
    if type(player) ~= "table" then
        return false
    end
    if tostring(player.player_type or ""):lower() ~= "spine" then
        return false
    end
    local sp = player.spine_physics
    if type(sp) ~= "table" then
        return false
    end
    return Util.to_bool(sp.enabled, false) == true
end

return Config

-- mvtk/core/logger.lua
-- Professional logging system with configurable levels and filtering

local M = {}

-- Log levels
M.LEVEL = {
    TRACE = 1,
    DEBUG = 2,
    INFO = 3,
    WARN = 4,
    ERROR = 5,
    FATAL = 6,
    OFF = 99
}

-- Configuration
local config = {
    global_level = M.LEVEL.INFO,  -- Only log INFO and above by default
    module_levels = {},  -- Per-module overrides
    output_file = nil,  -- Optional file logging
    include_timestamp = true,
    include_module = true,
    colored_output = false
}

-- Level names for display
local level_names = {
    [M.LEVEL.TRACE] = "TRACE",
    [M.LEVEL.DEBUG] = "DEBUG",
    [M.LEVEL.INFO] = "INFO",
    [M.LEVEL.WARN] = "WARN",
    [M.LEVEL.ERROR] = "ERROR",
    [M.LEVEL.FATAL] = "FATAL"
}

--- Configure logging system
-- @param cfg Configuration table
function M.configure(cfg)
    for k, v in pairs(cfg) do
        config[k] = v
    end
end

--- Set global log level
-- @param level Log level constant
function M.set_level(level)
    config.global_level = level
end

--- Set log level for specific module
-- @param module Module name
-- @param level Log level constant
function M.set_module_level(module, level)
    config.module_levels[module] = level
end

--- Check if level is enabled for module
-- @param module Module name
-- @param level Log level to check
-- @return true if should log
local function should_log(module, level)
    local module_level = config.module_levels[module]
    local threshold = module_level or config.global_level
    return level >= threshold
end

-- Use shared time module for consistent timing across the framework
local ok_time, Time = pcall(require, "mvtk.core.time")

--- Get current timestamp (compatible with Defold)
-- Delegates to mvtk.core.time for consistent timing across the framework
-- @return Timestamp in seconds
local function get_timestamp()
    if ok_time and Time and Time.gettime then
        return Time.gettime()
    end
    return os.clock()
end

--- Format log message
-- @param level Log level
-- @param module Module name
-- @param message Message string
-- @return Formatted string
local function format_message(level, module, message)
    local parts = {}

    if config.include_timestamp then
        table.insert(parts, string.format("[%.3f]", get_timestamp()))
    end

    table.insert(parts, string.format("[%s]", level_names[level] or "UNKNOWN"))

    if config.include_module and module then
        table.insert(parts, string.format("[%s]", module))
    end

    table.insert(parts, message)

    return table.concat(parts, " ")
end

--- Core logging function
-- @param level Log level
-- @param module Module name
-- @param fmt Format string
-- @param ... Format arguments
local function log(level, module, fmt, ...)
    if not should_log(module, level) then
        return
    end

    local message = string.format(fmt, ...)
    local formatted = format_message(level, module, message)

    print(formatted)

    -- Optional file output
    if config.output_file then
        local file = io.open(config.output_file, "a")
        if file then
            file:write(formatted .. "\n")
            file:close()
        end
    end
end

--- Create module logger
-- @param module_name Module name for logging
-- @return Logger instance with level methods
function M.get_logger(module_name)
    return {
        trace = function(fmt, ...) log(M.LEVEL.TRACE, module_name, fmt, ...) end,
        debug = function(fmt, ...) log(M.LEVEL.DEBUG, module_name, fmt, ...) end,
        info = function(fmt, ...) log(M.LEVEL.INFO, module_name, fmt, ...) end,
        warn = function(fmt, ...) log(M.LEVEL.WARN, module_name, fmt, ...) end,
        error = function(fmt, ...) log(M.LEVEL.ERROR, module_name, fmt, ...) end,
        fatal = function(fmt, ...) log(M.LEVEL.FATAL, module_name, fmt, ...) end
    }
end

--- Enable debug mode (show all logs)
function M.enable_debug()
    config.global_level = M.LEVEL.TRACE
end

--- Enable production mode (only warnings and errors)
function M.enable_production()
    config.global_level = M.LEVEL.WARN
end

--- Configure module log levels from a developer/config/debug_config.lua table.
--
-- The debug_config.lua schema is a flat table of category → flag → boolean,
-- e.g. Debug.gameplay.player = true. Each category.flag pair maps to a
-- module name "category.flag" used by callers of get_logger().
--
-- Many existing get_logger() calls use unrelated module names such as
-- "GAME_MANAGER" or "COLLECTIBLE". Aliases let those names share the same
-- gating flag. Pass `opts.aliases = { ["gameplay.game_manager"] = {"GAME_MANAGER"} }`
-- to wire them up. A built-in default alias map covers the common modules.
--
-- Semantics (matches the legacy `Debug.global.enable or Debug.cat.flag`
-- pattern used by Util.make_debug_log):
--   * If debug_config.global.enable is true, every module is set to DEBUG.
--   * Otherwise, modules whose flag is true are set to DEBUG, and modules
--     whose flag is false are set to WARN.
--
-- @param debug_cfg The loaded debug_config table. If nil, the module is
--   loaded via require("developer.config.debug_config") under pcall.
-- @param opts (optional) { aliases = { ["category.flag"] = {"NAME_A","NAME_B"} } }
-- @return true on success, false if debug_cfg could not be loaded
local DEFAULT_ALIASES = {
    ["gameplay.game_manager"]  = { "GAME_MANAGER" },
    ["gameplay.player"]        = { "PLAYER" },
    ["gameplay.player_state"]  = { "PSTATE", "PLAYER_STATE" },
    ["gameplay.checkpoint"]    = { "CHECKPOINT" },
    ["gameplay.save_manager"]  = { "SAVE_MANAGER" },
    ["gameplay.spawner"]       = { "SPAWNER" },
    ["gameplay.npcs"]          = { "NPC_MANAGER" },
    ["gameplay.interaction"]   = { "INTERACTION" },
    ["gameplay.ability_manager"] = { "ABILITY_MANAGER", "ABILITY_PICKUP" },
    ["gameplay.gates"]         = { "GATE" },
    ["gameplay.fast_travel"]   = { "FAST_TRAVEL" },
    ["combat.damage"]          = { "DAMAGE" },
    ["combat.melee"]           = { "MELEE" },
    ["combat.ranged"]          = { "RANGED" },
    ["combat.parry"]           = { "PARRY" },
    ["enemies.ai"]             = { "ENEMY_AI" },
    ["enemies.spawner"]        = { "ENEMY_MGR" },
    ["bosses.manager"]         = { "BOSS_MANAGER" },
    ["rooms.room_manager"]     = { "ROOM_MANAGER" },
    ["rooms.stream_manager"]   = { "STREAM_MANAGER" },
    ["rooms.transitions"]      = { "ROOM_TRANSITION" },
    ["rooms.loading"]          = { "ROOM_LOAD" },
    ["audio.controller"]       = { "AUDIO" },
    ["audio.music"]            = { "MUSIC" },
    ["audio.sfx"]              = { "SFX" },
    ["fx.particles"]           = { "FX_MANAGER" },
    ["fx.screen_shake"]        = { "SCREEN_SHAKE" },
    ["collectibles.pickup"]    = { "COLLECTIBLE", "PICKUP" },
    ["ui.hud"]                 = { "HUD" },
    ["ui.simple_menu"]         = { "MENU_MANAGER" },
    ["boot.simple_manager"]    = { "BOOT_SIMPLE", "BOOT" },
    ["tiled.spawner"]          = { "TILED_SPAWNER" },
    ["tiled.parser"]           = { "TILED_PARSER" },
    ["tiled.adapter"]          = { "TILED_ADAPTER" },
}

function M.configure_from_debug_config(debug_cfg, opts)
    if debug_cfg == nil then
        local ok, loaded = pcall(require, "developer.config.debug_config")
        if not ok or type(loaded) ~= "table" then
            return false
        end
        debug_cfg = loaded
    end

    if type(debug_cfg) ~= "table" then
        return false
    end

    opts = opts or {}
    local aliases = opts.aliases
    -- Merge user-provided aliases over defaults.
    local effective = {}
    for k, v in pairs(DEFAULT_ALIASES) do effective[k] = v end
    if type(aliases) == "table" then
        for k, v in pairs(aliases) do effective[k] = v end
    end

    local global_enable = debug_cfg.global and debug_cfg.global.enable == true

    local function apply(module_name, enabled)
        config.module_levels[module_name] = enabled
            and M.LEVEL.DEBUG
            or M.LEVEL.WARN
    end

    for category, flags in pairs(debug_cfg) do
        if category ~= "global" and type(flags) == "table" then
            for flag, value in pairs(flags) do
                local key = tostring(category) .. "." .. tostring(flag)
                local enabled = global_enable or value == true
                apply(key, enabled)
                local alias_list = effective[key]
                if type(alias_list) == "table" then
                    for _, alias in ipairs(alias_list) do
                        apply(alias, enabled)
                    end
                end
            end
        end
    end

    -- If global.enable is on, also lower the global threshold so unmapped
    -- modules emit at DEBUG level (matches the legacy Debug.global.enable behaviour).
    if global_enable then
        config.global_level = M.LEVEL.DEBUG
    end

    return true
end

return M

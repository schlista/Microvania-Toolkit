-- mvtk/enemies/enemy_override_registry.lua
-- Registry for per-instance enemy override tables (avoids JSON serialization).

local M = {}

local registry = {}
local EMPTY_HASH = hash("")
local static_overrides = nil
local static_loaded = false

local Util = nil
local function get_util()
    if Util == nil then
        local ok, mod = pcall(require, "mvtk.core.util")
        if ok then Util = mod end
    end
    return Util
end

local function load_static_overrides()
    if static_loaded then
        return
    end
    static_loaded = true

    local ok, overrides = pcall(require, "developer.config.tiled_enemy_overrides")
    if ok and type(overrides) == "table" then
        static_overrides = overrides
    else
        static_overrides = {}
    end
end

local function normalize_key(value)
    if value == nil or value == EMPTY_HASH then
        return nil
    end
    if type(value) == "userdata" then
        return value
    end
    return tostring(value)
end

function M.register(key, config)
    local k = normalize_key(key)
    if not k or type(config) ~= "table" then
        return false
    end
    registry[k] = config
    return true
end

function M.consume(key)
    local k = normalize_key(key)
    if not k then
        return nil
    end
    local cfg = registry[k]
    registry[k] = nil
    if cfg ~= nil then
        return cfg
    end

    load_static_overrides()
    if static_overrides and static_overrides[k] then
        local util = get_util()
        if util and util.deep_copy then
            return util.deep_copy(static_overrides[k])
        end
        return static_overrides[k]
    end

    return nil
end

function M.clear(key)
    local k = normalize_key(key)
    if not k then return end
    registry[k] = nil
end

function M.clear_all()
    registry = {}
end

return M

-- mvtk/core/flags.lua
-- ============================================================================
-- Global Flag Store
-- ============================================================================
-- Persistent key-value store for game state flags (story progress, unlocks, etc.).
-- Automatically persists through checkpoint system.
--
-- Flags can store any value (boolean, number, string, table) but are commonly
-- used as boolean flags to track story progress, unlocked areas, defeated bosses, etc.
--
-- Usage:
--   Flags.set("boss_defeated", true)
--   if Flags.has("boss_defeated") then ... end
--   local count = Flags.get("enemy_kills", 0)
--
-- Automatically integrates with save/load system.

local Util = require "mvtk.core.util"

local M = {}

-- ============================================================================
-- STATE
-- ============================================================================

-- Internal flag storage (key-value pairs)
local _flags = {}
local revision = 0
function M.revision() return revision end

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Set a flag value
-- key: Flag identifier (any type, commonly string)
-- value: Value to store (any type, defaults to true if nil)
--
-- Example:
--   Flags.set("has_sword", true)
--   Flags.set("enemy_count", 10)
function M.set(key, value)
    local old_value = _flags[key]
    if value == nil then value = true end
    _flags[key] = value
    if old_value ~= value then revision = revision + 1 end
    
end

-- Get a flag value
-- key: Flag identifier
-- default: Value to return if flag not set (defaults to nil)
-- Returns: Flag value or default
--
-- Example:
--   local has_key = Flags.get("has_key", false)
function M.get(key, default)
    local v = _flags[key]
    if v == nil then return default end
    return v
end

-- Check if a flag is set (exists and is truthy)
-- key: Flag identifier
-- Returns: true if flag exists and is truthy, false otherwise
--
-- For boolean flags, returns the boolean value.
-- For other types, returns true if flag exists.
function M.has(key)
    local v = _flags[key]
    if v == nil then return false end
    if type(v) == "boolean" then return v end
    return true  -- Non-nil, non-boolean values are considered "set"
end

-- Clear a flag (remove it completely)
-- key: Flag identifier
function M.clear(key)
    if _flags[key] ~= nil then revision = revision + 1 end
    _flags[key] = nil
end

-- Reset all flags (clear entire flag store)
-- Use when starting a new game or resetting to defaults.
function M.reset()
    _flags = {}
    revision = revision + 1
end

-- ============================================================================
-- SAVE/LOAD SUPPORT
-- ============================================================================

-- Export flags for saving
-- Returns: Shallow copy of all flags
function M.export()
    return Util.shallow_copy(_flags)
end

-- Import flags from save data
-- data: Table of flag key-value pairs
--
-- Clears existing flags and loads from data.
function M.import(data)
    _flags = {}
    revision = revision + 1
    if type(data) ~= "table" then return end
    for k, v in pairs(data) do
        _flags[k] = v
    end
end

-- Get all flags as a table
-- Returns: Shallow copy of all flags
--
-- Useful for debugging or displaying all flags in dev tools.
function M.all()
    return Util.shallow_copy(_flags)
end

-- ============================================================================
-- CHECKPOINT INTEGRATION
-- ============================================================================

Util.register_checkpoint_provider("flags", {
    capture = function()
        return M.export()
    end,
    apply = function(data)
        M.import(data)
    end,
    defaults = function()
        M.reset()
    end,
    version = 1,
    order = 20,
    mirror_key = "flags",
    description = "Global flag store",
})

return M

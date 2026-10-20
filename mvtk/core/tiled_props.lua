------------------------------------------------------------------------
-- mvtk/core/tiled_props.lua
-- ============================================================================
-- Shared Tiled Property Helpers
-- ============================================================================
-- Centralized utility functions for parsing and normalizing Tiled object
-- properties. Previously duplicated across boss.script, arena_lock.script,
-- arena_boundary.script, and others.
--
-- normalize_hash_string(value)    - Convert hash/string/nil to a plain string
-- to_bool(value, default)         - Parse a bool/string/number to boolean
-- parse_phase_set(csv)            - "1,3" -> {[1]=true, [3]=true}
-- parse_csv_list(s)               - "a,b,c" -> {"a","b","c"}
-- resolve_preset_or_override(override, preset, zero_means_preset)
--     - Encodes the "0/empty = use preset" convention explicitly
------------------------------------------------------------------------

local Util = require "mvtk.core.util"

local M = {}

--- Convert a hash or string value to a plain string, returning nil for
--- empty, unknown, or zero hashes. Delegates to Util.normalize_hash_string.
-- @param value  hash, string, or nil
-- @return string or nil
function M.normalize_hash_string(value)
    return Util.normalize_hash_string(value)
end

--- Parse a value to boolean. Handles booleans, numbers, and common
--- string representations ("true"/"false", "1"/"0", "yes"/"no").
-- @param value   The value to convert
-- @param default Boolean to return when value is nil or unrecognized
-- @return boolean
function M.to_bool(value, default)
    if value == nil then return default end
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end
    if type(value) == "string" then
        local v = value:lower()
        if v == "true" or v == "1" or v == "yes" then return true end
        if v == "false" or v == "0" or v == "no" then return false end
    end
    return default
end

--- Parse a CSV string of phase numbers into a set table.
--- Example: "1,3" -> {[1]=true, [3]=true}
-- @param value  CSV string of integers, or nil/empty
-- @return table  Set of phase numbers (may be empty)
function M.parse_phase_set(value)
    local set = {}
    if type(value) == "string" then
        for phase in string.gmatch(value, "(%d+)") do
            set[tonumber(phase)] = true
        end
    end
    return set
end

--- Parse a generic CSV string into a list of trimmed strings.
--- Example: "sword_combo, dash_slash" -> {"sword_combo", "dash_slash"}
-- @param s  CSV string, or nil/empty
-- @return table  Ordered list of strings (may be empty)
function M.parse_csv_list(s)
    local list = {}
    if type(s) ~= "string" or s == "" then return list end
    for item in s:gmatch("([^,]+)") do
        local trimmed = item:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            list[#list + 1] = trimmed
        end
    end
    return list
end

--- Resolve a Tiled override vs a preset value using the "0/empty = use preset"
--- convention. For numbers, 0 means "use preset". For strings, "" means "use
--- preset". For nil, always use preset.
-- @param override          The Tiled-authored value (may be 0, "", or nil)
-- @param preset            The value from boss_types.lua or defaults
-- @param zero_means_preset If true (default), treat 0/"" as "use preset"
-- @return The resolved value
function M.resolve_preset_or_override(override, preset, zero_means_preset)
    if zero_means_preset == nil then zero_means_preset = true end

    if override == nil then
        return preset
    end

    if zero_means_preset then
        if type(override) == "number" and override == 0 then
            return preset
        end
        if type(override) == "string" and override == "" then
            return preset
        end
        -- Hash check: empty hash
        if type(override) == "userdata" then
            local s = M.normalize_hash_string(override)
            if s == nil or s == "" then
                return preset
            end
        end
    end

    return override
end

return M

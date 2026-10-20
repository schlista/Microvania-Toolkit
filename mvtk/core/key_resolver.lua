-- mvtk/core/key_resolver.lua
-- Runtime key resolution helpers.
--
-- Defold script properties often use hashes, while configs frequently use string keys.
-- This module builds hash->string lookup tables once and exposes resolver helpers.

local M = {}

local function build_hash_to_key_map(config_table)
    local map = {}
    for key, _ in pairs(config_table or {}) do
        if type(key) == "string" then
            map[hash(key)] = key
        end
    end
    return map
end

local Util = require "mvtk.core.util"

-- Collectibles: developer/config/collectible_types.lua
local collectible_types = Util.require_config("developer.config.collectible_types")
local collectible_hash_to_key = build_hash_to_key_map(collectible_types)

--- Resolve a collectible type to the canonical string key.
-- @param value string|hash
-- @return string|nil
function M.resolve_collectible_type(value)
    if type(value) == "string" then
        return value
    end
    if type(value) == "userdata" then
        return collectible_hash_to_key[value]
    end
    return nil
end

return M

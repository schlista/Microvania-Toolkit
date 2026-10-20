-- mvtk/world/chest_inline_registry.lua
-- Registry for inline chest contents hashed into loot_table properties.

local Util = require "mvtk.core.util"

local M = {}

local inline_map = {}
local initialized = false

local function register_value(value)
    if type(value) ~= "string" then
        return
    end
    local trimmed = Util.trim(value)
    if trimmed == "" then
        return
    end
    inline_map[hash(trimmed)] = trimmed
end

function M.init_from_config()
    if initialized then
        return
    end
    initialized = true
    local cfg = Util.require_config("developer.config.chest_inline_contents")
    if type(cfg) == "table" then
        for _, value in ipairs(cfg) do
            register_value(value)
        end
    end
end

function M.register_inline(value)
    register_value(value)
end

function M.resolve(value)
    if type(value) == "string" and value ~= "" then return value end
    return inline_map[value]
end

return M

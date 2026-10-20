-- mvtk/core/optional_require.lua
--
-- Compatibility wrapper around mvtk.core.safe_require. New code should require
-- mvtk.core.safe_require directly; this module keeps existing optional_require
-- call sites and cached/quiet variants working while Phase 1 migration proceeds.

local SafeRequire = require "mvtk.core.safe_require"

local M = {}

local function optional_require(path, caller)
    return SafeRequire.safe_require(path, caller)
end

function M.quiet(path, caller)
    return SafeRequire.quiet(path, caller)
end

local _cache = {}
function M.cached(path, caller)
    local entry = _cache[path]
    if entry ~= nil then
        return entry[1], entry[2]
    end

    local ok, mod_or_err = optional_require(path, caller)
    _cache[path] = { ok, mod_or_err }
    return ok, mod_or_err
end

function M.reset_cache()
    _cache = {}
end

setmetatable(M, {
    __call = function(_, path, caller)
        return optional_require(path, caller)
    end,
})

return M

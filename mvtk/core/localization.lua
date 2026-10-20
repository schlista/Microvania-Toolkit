-- mvtk/core/localization.lua
-- Lightweight string table loader with locale switching.

local Util = require "mvtk.core.util"
local Config = Util.require_config("developer.config.localization")

local current = "en"
local locales = { en = {} }

local function load()
    if Config then
        current = Config.default_locale or current
        locales = Config.locales or locales
    end
end

load()

local M = {}

function M.set_locale(locale)
    if locales[locale] then current = locale end
end

function M.get_locale()
    return current
end

function M.t(key)
    local loc = locales[current] or locales.en or {}
    local val = Util.get_nested(loc, key)
    if val then return val end
    local fallback = Util.get_nested(locales.en or {}, key)
    return fallback or key
end

return M

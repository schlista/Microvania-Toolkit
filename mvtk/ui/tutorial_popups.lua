-- mvtk/ui/tutorial_popups.lua
-- Config-driven tutorial popup dispatcher.

local FlagsOk, Flags = pcall(require, "mvtk.core.flags")
local ConfigOk, Config = pcall(require, "developer.config.tutorial_popups")
local LocalizationOk, L10n = pcall(require, "mvtk.core.localization")
local C = require "mvtk.core.constants"

local popups = {}
local shown = {}

local function load()
    if ConfigOk and Config and Config.popups then
        popups = Config.popups
    end
end

load()

local M = {}

local function localized(key, fallback)
    if not (LocalizationOk and key and key ~= "") then return fallback end
    local lookup = "ui." .. key
    local value = L10n.t(lookup)
    return value and value ~= lookup and value or fallback
end

function M.reset()
    shown = {}
end

function M.on_event(event_name)
    for id, def in pairs(popups) do
        local matches_event = def.condition and def.condition.event == event_name
        local already_shown = def.trigger_flag and FlagsOk and Flags.get and Flags.get(def.trigger_flag)
        if matches_event and not already_shown then
            local title = localized(def.title_key, def.title)
            local body = localized(def.body_key, def.body)
            local hud = C.url and C.url("MODE_HUD")
            if hud then pcall(msg.post, hud, "show_tutorial", { id = id, title = title, description = body, position = def.position or "top" }) end
            shown[id] = true
            if def.trigger_flag and FlagsOk and Flags.set then
                pcall(Flags.set, def.trigger_flag, true)
            end
        end
    end
end

return M

-- developer/config/secret_settings.lua
-- Defaults for breakable walls and secret discovery behavior.

local M = {
    wall_defaults = {
        wall_type = "cracked",
        health = 3,
        required_ability = nil, -- e.g. "bomb", "power_beam"
        reveals_secret = nil,   -- secret id to reveal on break
        audio = {
            wrong_ability = nil,
            hit = nil,
            break_sound = nil,
        },
        visual = {
            intact = nil,
            damaged = nil,
            heavily_damaged = nil,
        },
    },
}

return M

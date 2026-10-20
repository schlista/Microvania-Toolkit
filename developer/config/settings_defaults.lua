-- developer/config/settings_defaults.lua
-- Default player-facing settings for audio, graphics, and gameplay.
-- Adjust these instead of editing mvtk/core/settings.lua.

local M = {
    audio = {
        master_volume = 0.8,
        music_volume = 0.7,
        sfx_volume = 0.8,
        muted = false,
    },
    graphics = {
        window_mode = "windowed",          -- "windowed", "fullscreen_windowed", "fullscreen"
        vsync = true,
        resolution_scale = 1.0,            -- 0.5 to 2.0
        pixel_perfect = false,
        show_fps = false,
    },
    gameplay = {
        camera_shake = true,
        rumble = true,
        damage_numbers = false,
        number_options = {
            enemies = true,
            player  = true,
            heal    = true,
            crit    = true,
        },
        auto_save = true,
        icon_theme = "xbox",   -- "xbox", "playstation", or "switch"
    },
    language = "en",
}

return M

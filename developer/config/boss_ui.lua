-- developer/config/boss_ui.lua
-- Visual configuration for the boss HUD (health bar, name, boss phase indicator).
--
-- Change these values to restyle the boss UI without editing the gui_script.
-- The gui_script reads this via Util.require_config and falls back to safe
-- defaults if any key is missing.
--
-- Colors are {r, g, b, a} in the 0..1 range (matching vmath.vector4).
-- Dimensions are in pixels.

return {
    -- ---- Layout ------------------------------------------------------------

    -- Full health-bar width at 100% hp.
    bar_width      = 600,

    -- Health-bar thickness.
    bar_height     = 24,

    -- Default boss health-bar position when a boss template does not
    -- override it. Valid values: "top" or "bottom".
    health_bar_position = "top",

    -- Pixels between the top of the screen and the top of the bar.
    margin_top     = 40,

    -- Pixels between the bottom of the screen and the bottom of the bar.
    margin_bottom  = 40,

    -- Vertical offset from the bar anchor to the boss name label.
    name_offset_y  = 20,

    -- Vertical gap below the bar before the boss phase label.
    phase_offset_y = 10,

    -- Padding between the background frame and the foreground fill.
    bar_padding    = 2,

    -- ---- Colors ------------------------------------------------------------

    -- Boss name text.
    color_name     = { 1.0, 1.0, 0.7, 1.0 },

    -- Dark frame behind the health fill.
    color_bg       = { 0.1, 0.1, 0.1, 0.8 },

    -- Health percentage text.
    color_hp_text  = { 1.0, 1.0, 1.0, 1.0 },

    -- Boss phase indicator ("Phase 2 / 3").
    color_phase    = { 1.0, 0.5, 0.5, 0.9 },

    -- Flash tint shown briefly when the boss phase changes.
    color_phase_flash = { 1.0, 1.0, 0.0, 1.0 },

    -- Health-bar fill color tiers. The fill is drawn in whichever color
    -- matches the current fraction — highest matching `above` wins.
    health_fill_tiers = {
        { above = 0.6, color = { 0.9, 0.2, 0.2, 1.0 } },  -- red (healthy)
        { above = 0.3, color = { 0.9, 0.5, 0.1, 1.0 } },  -- orange (wounded)
        { above = 0.0, color = { 0.9, 0.9, 0.1, 1.0 } },  -- yellow (low)
    },

    -- ---- Animation --------------------------------------------------------

    -- Duration for fade-in when the HUD appears.
    fade_in_duration  = 0.3,

    -- Duration for fade-out on boss defeat.
    fade_out_duration = 1.0,

    -- Duration of the color pulse on boss phase change.
    phase_flash_duration = 0.5,
}

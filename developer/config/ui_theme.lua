-- developer/config/ui_theme.lua
-- Centralized UI styling for the entire framework
-- Developers can easily customize the look and feel by modifying this file
--
-- THEME: Dark Metroidvania
-- A polished, atmospheric theme with cool blue accents on deep midnight backgrounds.
-- All menus read from this file — change colors here and every menu updates.
-- Want to try other themes? See developer/config/ui_theme_examples.lua

return {
  -- Color palette for UI elements
  -- Format: {r, g, b, a} where values are 0.0 to 1.0
  colors = {
    -- HUD bar colors - Classic Metroidvania style
    health      = {0.85, 0.20, 0.15, 0.95},  -- Deep atmospheric red
    health_bg   = {0.15, 0.05, 0.05, 0.75},  -- Very dark red
    energy      = {0.25, 0.60, 0.95, 0.95},  -- Bright magical blue
    energy_bg   = {0.05, 0.15, 0.25, 0.75},  -- Dark blue
    stamina     = {0.30, 0.85, 0.35, 0.95},  -- Vibrant nature green
    stamina_bg  = {0.05, 0.20, 0.05, 0.75},  -- Dark green

    -- Boss health bar - dramatic and threatening
    boss_health    = {0.95, 0.10, 0.10, 1.0},
    boss_health_bg = {0.25, 0.05, 0.05, 0.9},

    -- Text colors - high contrast for readability
    text_primary   = {0.88, 0.88, 0.90, 1.0},  -- Soft white (easy on the eyes)
    text_secondary = {0.65, 0.65, 0.70, 0.9},  -- Medium lavender-gray
    text_highlight = {0.50, 0.75, 1.0, 1.0},   -- Bright blue highlight
    text_disabled  = {0.45, 0.45, 0.45, 0.7},  -- Dimmed gray

    -- UI element colors - thematic and readable
    currency       = {0.95, 0.85, 0.30, 1.0},  -- Rich gold for coins
    abilities      = {0.60, 0.80, 1.0, 0.95},  -- Cool blue for abilities
    interact_hint  = {0.90, 0.90, 0.70, 0.9},  -- Warm white for hints

    ---------------------------------------------------------------------------
    -- MENU COLORS — used by all menu .gui files and scripts
    -- Edit these to re-skin every menu at once.
    ---------------------------------------------------------------------------

    -- Backgrounds & panels
    menu_backdrop       = {0.0,  0.0,  0.0,  0.85},  -- Black overlay behind modals
    menu_background     = {0.08, 0.08, 0.12, 0.94},  -- Deep midnight panel fill
    menu_root_bg        = {0.06, 0.06, 0.10, 1.0},   -- Full-screen backgrounds (boot)

    -- Title / headings
    menu_title          = {0.50, 0.75, 1.0,  1.0},   -- Cool blue title text

    -- Buttons / list rows
    btn_normal_bg       = {0.22, 0.22, 0.28, 1.0},   -- Dark slate button
    btn_selected_bg     = {0.12, 0.25, 0.50, 1.0},   -- Deep blue selection
    btn_normal_text     = {0.88, 0.88, 0.90, 1.0},   -- Soft white label
    btn_selected_text   = {1.0,  1.0,  1.0,  1.0},   -- White selected label

    -- Tabs
    tab_active_bg       = {0.12, 0.25, 0.50, 1.0},   -- Active tab (blue-tinted)
    tab_active_text     = {1.0,  1.0,  1.0,  1.0},   -- Active tab label (white)
    tab_inactive_bg     = {0.22, 0.22, 0.28, 1.0},   -- Inactive tab
    tab_inactive_text   = {0.65, 0.65, 0.70, 1.0},   -- Inactive tab label

    -- Rows / dynamic lists
    row_normal_bg       = {0.12, 0.12, 0.16, 0.75},  -- Slightly lighter than panel
    row_selected_bg     = {0.26, 0.50, 0.88, 0.30},  -- Blue tint on selected row
    row_text_owned      = {0.62, 0.62, 0.62, 1.0},   -- Dimmed for owned/used items
    row_text_locked     = {0.95, 0.58, 0.50, 1.0},   -- Reddish for locked items

    -- Hint bar
    menu_hint           = {0.55, 0.55, 0.62, 0.85},  -- Muted lavender-gray

    -- Separator / decoration
    menu_separator      = {0.25, 0.25, 0.30, 0.50},  -- Subtle line between sections

    -- Status / feedback
    status_good         = {0.30, 0.85, 0.40, 1.0},   -- Vibrant green
    status_bad          = {0.90, 0.25, 0.20, 1.0},    -- Alarming red

    -- Accent
    accent_blue         = {0.30, 0.50, 0.80, 1.0},   -- Cool blue accent

    -- Feedback colors - punchy and clear
    flash_cooldown = {0.95, 0.95, 0.30, 1.0},  -- Bright yellow
    damage_player  = {1.0, 0.25, 0.20, 1.0},   -- Alarming red
    damage_enemy   = {0.95, 0.70, 0.30, 1.0},  -- Satisfying orange
    heal           = {0.30, 0.95, 0.40, 1.0},  -- Refreshing green
    critical       = {1.0, 0.50, 0.10, 1.0},   -- Fiery orange

    -- Warning colors - attention-grabbing
    low_health     = {0.95, 0.10, 0.10, 0.40}, -- Strong red vignette
    low_stamina    = {0.95, 0.75, 0.10, 0.30}, -- Yellow caution
  },

  -- Font definitions
  fonts = {
    hud      = "main",    -- HUD text font
    menu     = "main",    -- Menu text font
    dialogue = "main",    -- Dialogue text font
    title    = "main",    -- Title/header font
  },

  -- Spacing constants (in pixels) - comfortable and organized
  spacing = {
    margin_left   = 12,   -- Comfortable margin for HUD elements
    margin_top    = 12,
    margin_right  = 12,
    margin_bottom = 12,

    bar_spacing   = 3,    -- Nice spacing between bars
    element_gap   = 20,   -- Clear separation between HUD sections

    menu_padding  = 24,   -- Generous padding inside menus
    button_spacing = 12,  -- Clear button separation
  },

  -- Animation durations (in seconds) - smooth and polished
  animations = {
    menu_fade_in  = 0.25,  -- Smooth fade in
    menu_fade_out = 0.18,  -- Quick fade out
    menu_slide    = 0.30,  -- Smooth slide animation

    bar_update    = 0.15,  -- Smooth bar transitions
    flash_duration = 0.40, -- Noticeable flash effect

    toast_fade_in  = 0.15, -- Quick toast appearance
    toast_fade_out = 0.40, -- Gentle toast fade
  },

  -- Size constants - clear and readable
  sizes = {
    -- HUD bar dimensions - larger for better visibility
    health_bar_width  = 200,
    health_bar_height = 16,

    energy_bar_width  = 140,
    energy_bar_height = 12,

    stamina_bar_width  = 140,
    stamina_bar_height = 10,

    -- Boss health bar - prominent and dramatic
    boss_bar_height = 24,
    boss_bar_min_width = 400,
    boss_bar_screen_percent = 0.65,  -- 65% of screen width

    -- Bar border/padding
    bar_border = 2,  -- Inner padding for foreground bars

    -- Menu button size - comfortable click targets
    menu_button_width  = 220,
    menu_button_height = 45,
  },

  -- Warning thresholds (0.0 to 1.0) - balanced for challenge
  warnings = {
    low_health_threshold  = 0.25,  -- Warning at 25% health
    low_stamina_threshold = 0.20,  -- Warning at 20% stamina
    low_energy_threshold  = 0.20,  -- Warning at 20% energy
  },

  -- HUD visibility settings
  visibility = {
    show_health   = true,
    show_energy   = true,   -- Will auto-hide if max_energy == 0
    show_stamina  = true,   -- Will auto-hide if max_stamina == 0
    show_currency = true,
    show_abilities = true,
    show_interact_hint = true,
    show_minimap  = true,
    show_boss_bar = true,
  },
}

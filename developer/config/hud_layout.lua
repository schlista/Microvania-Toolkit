-- developer/config/hud_layout.lua
-- HUD element positioning and layout configuration
-- Developers can easily customize HUD placement by modifying this file
--
-- DEMO LAYOUT: Classic Metroidvania (Top-Left)
-- This is optimized for the Classic theme with comfortable spacing
-- Want to try other layouts? See developer/config/hud_layout_examples.lua

-- Position reference:
-- - anchor: "top_left", "top_right", "bottom_left", "bottom_right", "center"
-- - offset: {x, y} offset from anchor point (in pixels)
-- - For top/left anchors: positive values move right/down
-- - For bottom/right anchors: positive values move left/up

return {
  theme_preset = "authored", -- authored, classic, neon, minimal, retro or horror; HUD/prompt palette.
  -- Global HUD settings
  global = {
    scale = 1,               -- Uniform element scale; anchors stay on screen edges.
    anchor = "top_left",      -- Default anchor for all HUD elements
    margin = 12,              -- Comfortable margin from screen edges
  },

  -- Movement mode label (e.g., "Normal", "Swim")
  mode_label = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -30},  -- Below menu button
    visible = true,
  },

  -- Health bar (most important, prominent position)
  health_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -54},  -- Below mode label
    visible = true,
    show_text = false,           -- Show numeric health value
    text_format = "%d/%d",       -- Format string for health display
  },

  -- Energy bar (auto-hides if max_energy == 0)
  energy_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -74},  -- Below health bar
    visible = true,
    auto_hide = true,            -- Hide when max_energy is 0
    show_text = false,
  },

  -- Stamina bar (auto-hides if max_stamina == 0)
  stamina_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -90},  -- Below energy bar
    visible = true,
    auto_hide = true,            -- Hide when max_stamina is 0
    show_text = false,
  },

  -- Currency display
  currency = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -112},  -- Clear gap after bars
    visible = true,
    format = "$ %d",              -- Format string for currency
  },

  -- Unlocked abilities display (compact list)
  abilities = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -134},  -- Below currency
    visible = true,
    format = "compact",           -- "compact" or "icons" (future)
  },


  -- Interact hint (contextual prompt)
  interact_hint = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -178},  -- Below abilities
    visible = true,
    fade_duration = 0.25,
  },

  -- Cooldown flash (temporary ability feedback)
  cooldown_flash = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 140, y = -54},  -- To the right of health bar
    visible = true,
    duration = 0.40,
  },

  -- Boss health bar (prominent top-center placement)
  boss_health_bar = {
    enabled = true,
    anchor = "top_center",
    offset = {x = 0, y = -70},   -- Larger offset for new boss bar size
    visible = true,
    show_name = true,
    name_offset = {x = 0, y = 10},  -- Name above the bar
  },

  -- Minimap
  minimap = {
    enabled = true,
    anchor = "bottom_right",
    offset = {x = -20, y = 20},
    visible = true,
    default_mode = "panel",     -- "off", "panel", "fullscreen"
    panel_size = {w = 200, h = 150},
  },

  -- Damage numbers (floating combat text)
  damage_numbers = {
    enabled = true,
    visible = true,
    lifetime = 1.0,             -- How long numbers stay on screen
    rise_speed = 50,            -- Pixels per second upward
    fade_start = 0.5,           -- When to start fading (0-1)
  },

  -- Low health warning (screen vignette)
  low_health_warning = {
    enabled = true,
    visible = true,
    pulse_speed = 2.0,          -- Pulse frequency
    threshold = 0.25,           -- Show below 25% health
  },

  -- Menu button (top-left corner)
  menu_button = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 8, y = -8},
    visible = true,
    label = "Menu",
  },

  -- Layout presets
  -- Developers can switch between these or create custom ones
  presets = {
    -- Default layout (standard placement)
    default = {
      -- Uses the positions defined above
    },

    -- Minimal layout (reduced clutter)
    minimal = {
      mode_label = { visible = false },
      abilities = { visible = false },
      currency = { visible = false },
    },

    -- Bottom-left layout (bars at bottom)
    bottom_left = {
      health_bar = { anchor = "bottom_left", offset = {x = 8, y = 80} },
      energy_bar = { anchor = "bottom_left", offset = {x = 8, y = 64} },
      stamina_bar = { anchor = "bottom_left", offset = {x = 8, y = 52} },
      currency = { anchor = "bottom_left", offset = {x = 8, y = 32} },
    },

    -- Centered layout (bars at bottom center)
    centered = {
      health_bar = { anchor = "bottom_center", offset = {x = 0, y = 60} },
      energy_bar = { anchor = "bottom_center", offset = {x = -100, y = 40} },
      stamina_bar = { anchor = "bottom_center", offset = {x = 100, y = 40} },
    },
  },

  -- Active preset (change this to switch layouts)
  active_preset = "default",
}

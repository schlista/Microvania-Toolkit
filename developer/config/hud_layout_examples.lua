-- developer/config/hud_layout_examples.lua
-- Example HUD layout presets for different play styles
-- Copy one of these into hud_layout.lua to use it

local layouts = {}

-----------------------------------------------------------
-- LAYOUT 1: CLASSIC TOP-LEFT (Default Metroidvania)
-----------------------------------------------------------
layouts.classic = {
  global = {
    anchor = "top_left",
    margin = 12,
  },

  mode_label = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -30},
    visible = true,
  },

  health_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -54},
    visible = true,
    show_text = false,
  },

  energy_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -72},
    visible = true,
    auto_hide = true,
    show_text = false,
  },

  stamina_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -86},
    visible = true,
    auto_hide = true,
    show_text = false,
  },

  currency = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -106},
    visible = true,
    format = "$ %d",
  },

  abilities = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -128},
    visible = true,
    format = "compact",
  },


  interact_hint = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -172},
    visible = true,
    fade_duration = 0.25,
  },

  cooldown_flash = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 140, y = -54},
    visible = true,
    duration = 0.35,
  },

  boss_health_bar = {
    enabled = true,
    anchor = "top_center",
    offset = {x = 0, y = -70},
    visible = true,
    show_name = true,
    name_offset = {x = 0, y = 10},
  },

  minimap = {
    enabled = true,
    anchor = "bottom_right",
    offset = {x = -20, y = 20},
    visible = true,
    default_mode = "panel",
    panel_size = {w = 200, h = 150},
  },

  damage_numbers = {
    enabled = true,
    visible = true,
    lifetime = 1.0,
    rise_speed = 50,
    fade_start = 0.5,
  },

  low_health_warning = {
    enabled = true,
    visible = true,
    pulse_speed = 2.0,
    threshold = 0.25,
  },

  menu_button = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 12, y = -12},
    visible = true,
    label = "Menu",
  },

  active_preset = "default",
}

-----------------------------------------------------------
-- LAYOUT 2: BOTTOM-CENTERED (Console/Couch Gaming)
-----------------------------------------------------------
layouts.console = {
  global = {
    anchor = "bottom_center",
    margin = 20,
  },

  mode_label = {
    enabled = false,  -- Hide mode label for cleaner look
    visible = false,
  },

  health_bar = {
    enabled = true,
    anchor = "bottom_center",
    offset = {x = 0, y = 80},
    visible = true,
    show_text = false,
  },

  energy_bar = {
    enabled = true,
    anchor = "bottom_center",
    offset = {x = -130, y = 55},  -- Left side
    visible = true,
    auto_hide = true,
    show_text = false,
  },

  stamina_bar = {
    enabled = true,
    anchor = "bottom_center",
    offset = {x = 130, y = 55},  -- Right side (mirrored)
    visible = true,
    auto_hide = true,
    show_text = false,
  },

  currency = {
    enabled = true,
    anchor = "bottom_right",
    offset = {x = -20, y = 25},
    visible = true,
    format = "$ %d",
  },

  abilities = {
    enabled = true,
    anchor = "bottom_left",
    offset = {x = 20, y = 25},
    visible = true,
    format = "compact",
  },


  interact_hint = {
    enabled = true,
    anchor = "center",
    offset = {x = 0, y = -120},  -- Center screen
    visible = true,
    fade_duration = 0.25,
  },

  cooldown_flash = {
    enabled = true,
    anchor = "center",
    offset = {x = 0, y = 60},
    visible = true,
    duration = 0.35,
  },

  boss_health_bar = {
    enabled = true,
    anchor = "top_center",
    offset = {x = 0, y = -60},
    visible = true,
    show_name = true,
    name_offset = {x = 0, y = 10},
  },

  minimap = {
    enabled = true,
    anchor = "top_right",
    offset = {x = -20, y = -20},
    visible = true,
    default_mode = "panel",
    panel_size = {w = 180, h = 135},
  },

  damage_numbers = {
    enabled = true,
    visible = true,
    lifetime = 1.2,
    rise_speed = 45,
    fade_start = 0.6,
  },

  low_health_warning = {
    enabled = true,
    visible = true,
    pulse_speed = 2.5,
    threshold = 0.25,
  },

  menu_button = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 20, y = -20},
    visible = true,
    label = "Menu",
  },

  active_preset = "centered",
}

-----------------------------------------------------------
-- LAYOUT 3: MINIMAL (Hardcore/Immersive)
-----------------------------------------------------------
layouts.minimal = {
  global = {
    anchor = "bottom_left",
    margin = 8,
  },

  mode_label = {
    enabled = false,
    visible = false,
  },

  health_bar = {
    enabled = true,
    anchor = "bottom_left",
    offset = {x = 8, y = 60},
    visible = true,
    show_text = false,
  },

  energy_bar = {
    enabled = true,
    anchor = "bottom_left",
    offset = {x = 8, y = 44},
    visible = true,
    auto_hide = true,
    show_text = false,
  },

  stamina_bar = {
    enabled = true,
    anchor = "bottom_left",
    offset = {x = 8, y = 32},
    visible = true,
    auto_hide = true,
    show_text = false,
  },

  currency = {
    enabled = false,  -- Hide for immersion
    visible = false,
  },

  abilities = {
    enabled = false,  -- Hide for immersion
    visible = false,
  },


  interact_hint = {
    enabled = true,
    anchor = "center",
    offset = {x = 0, y = -80},
    visible = true,
    fade_duration = 0.20,
  },

  cooldown_flash = {
    enabled = false,  -- Hide for immersion
    visible = false,
  },

  boss_health_bar = {
    enabled = true,
    anchor = "top_center",
    offset = {x = 0, y = -40},
    visible = true,
    show_name = true,
    name_offset = {x = 0, y = 8},
  },

  minimap = {
    enabled = false,  -- Hide for immersion (toggle only)
    visible = false,
    default_mode = "off",
  },

  damage_numbers = {
    enabled = false,  -- Hide for immersion
    visible = false,
  },

  low_health_warning = {
    enabled = true,
    visible = true,
    pulse_speed = 3.0,  -- More urgent
    threshold = 0.30,   -- Warn earlier
  },

  menu_button = {
    enabled = false,  -- Hide for immersion
    visible = false,
  },

  active_preset = "minimal",
}

-----------------------------------------------------------
-- LAYOUT 4: CORNER CLUSTERS (Organized by Type)
-----------------------------------------------------------
layouts.corners = {
  global = {
    anchor = "top_left",
    margin = 16,
  },

  -- TOP LEFT: Player stats
  mode_label = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 16, y = -32},
    visible = true,
  },

  health_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 16, y = -56},
    visible = true,
    show_text = true,
    text_format = "%d/%d",
  },

  energy_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 16, y = -76},
    visible = true,
    auto_hide = true,
    show_text = true,
  },

  stamina_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 16, y = -92},
    visible = true,
    auto_hide = true,
    show_text = true,
  },

  -- TOP RIGHT: Equipment & abilities
  abilities = {
    enabled = true,
    anchor = "top_right",
    offset = {x = -16, y = -32},
    visible = true,
    format = "compact",
  },


  cooldown_flash = {
    enabled = true,
    anchor = "top_right",
    offset = {x = -16, y = -76},
    visible = true,
    duration = 0.35,
  },

  -- BOTTOM LEFT: Resources
  currency = {
    enabled = true,
    anchor = "bottom_left",
    offset = {x = 16, y = 50},
    visible = true,
    format = "Gold: %d",
  },

  -- BOTTOM RIGHT: Map
  minimap = {
    enabled = true,
    anchor = "bottom_right",
    offset = {x = -16, y = 16},
    visible = true,
    default_mode = "panel",
    panel_size = {w = 220, h = 165},
  },

  -- CENTER: Interactions
  interact_hint = {
    enabled = true,
    anchor = "center",
    offset = {x = 0, y = -100},
    visible = true,
    fade_duration = 0.25,
  },

  boss_health_bar = {
    enabled = true,
    anchor = "top_center",
    offset = {x = 0, y = -70},
    visible = true,
    show_name = true,
    name_offset = {x = 0, y = 12},
  },

  damage_numbers = {
    enabled = true,
    visible = true,
    lifetime = 1.0,
    rise_speed = 55,
    fade_start = 0.5,
  },

  low_health_warning = {
    enabled = true,
    visible = true,
    pulse_speed = 2.0,
    threshold = 0.25,
  },

  menu_button = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 16, y = -16},
    visible = true,
    label = "Menu",
  },

  active_preset = "default",
}

-----------------------------------------------------------
-- LAYOUT 5: MOBILE/HANDHELD (Larger Touch Targets)
-----------------------------------------------------------
layouts.mobile = {
  global = {
    anchor = "bottom_center",
    margin = 24,
  },

  mode_label = {
    enabled = false,
    visible = false,
  },

  health_bar = {
    enabled = true,
    anchor = "top_center",
    offset = {x = 0, y = -40},
    visible = true,
    show_text = true,
    text_format = "%d",
  },

  energy_bar = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 24, y = -40},
    visible = true,
    auto_hide = true,
    show_text = false,
  },

  stamina_bar = {
    enabled = true,
    anchor = "top_right",
    offset = {x = -24, y = -40},
    visible = true,
    auto_hide = true,
    show_text = false,
  },

  currency = {
    enabled = true,
    anchor = "top_left",
    offset = {x = 24, y = -65},
    visible = true,
    format = "$%d",
  },

  abilities = {
    enabled = true,
    anchor = "top_right",
    offset = {x = -24, y = -65},
    visible = true,
    format = "compact",
  },


  interact_hint = {
    enabled = true,
    anchor = "center",
    offset = {x = 0, y = 0},  -- Dead center
    visible = true,
    fade_duration = 0.30,
  },

  cooldown_flash = {
    enabled = true,
    anchor = "center",
    offset = {x = 0, y = 80},
    visible = true,
    duration = 0.40,
  },

  boss_health_bar = {
    enabled = true,
    anchor = "top_center",
    offset = {x = 0, y = -90},
    visible = true,
    show_name = true,
    name_offset = {x = 0, y = 14},
  },

  minimap = {
    enabled = true,
    anchor = "bottom_left",
    offset = {x = 24, y = 120},
    visible = true,
    default_mode = "panel",
    panel_size = {w = 140, h = 105},  -- Smaller on mobile
  },

  damage_numbers = {
    enabled = true,
    visible = true,
    lifetime = 1.5,  -- Longer on mobile
    rise_speed = 40,
    fade_start = 0.7,
  },

  low_health_warning = {
    enabled = true,
    visible = true,
    pulse_speed = 2.2,
    threshold = 0.30,
  },

  menu_button = {
    enabled = true,
    anchor = "top_right",
    offset = {x = -24, y = -24},
    visible = true,
    label = "|||",  -- Hamburger menu icon
  },

  active_preset = "centered",
}

return layouts

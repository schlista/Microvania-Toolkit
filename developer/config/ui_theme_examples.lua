-- developer/config/ui_theme_examples.lua
-- Example UI themes for different visual styles
-- Copy one of these into ui_theme.lua to use it

local themes = {}

-----------------------------------------------------------
-- THEME 1: CLASSIC METROIDVANIA (Dark, Atmospheric)
-----------------------------------------------------------
themes.classic = {
  colors = {
    -- Status bars - muted, atmospheric colors
    health      = {0.85, 0.20, 0.15, 0.95},  -- Deep red
    health_bg   = {0.15, 0.05, 0.05, 0.75},  -- Very dark red
    energy      = {0.25, 0.60, 0.95, 0.95},  -- Bright blue
    energy_bg   = {0.05, 0.15, 0.25, 0.75},  -- Dark blue
    stamina     = {0.30, 0.85, 0.35, 0.95},  -- Vibrant green
    stamina_bg  = {0.05, 0.20, 0.05, 0.75},  -- Dark green

    -- Boss health bar - dramatic red
    boss_health = {0.95, 0.10, 0.10, 1.0},
    boss_health_bg = {0.25, 0.05, 0.05, 0.9},

    -- Text - high contrast for readability
    text_primary   = {0.95, 0.95, 0.95, 1.0},  -- Off-white
    text_secondary = {0.75, 0.75, 0.75, 0.9},  -- Gray
    text_highlight = {1.0, 0.90, 0.30, 1.0},   -- Gold
    text_disabled  = {0.45, 0.45, 0.45, 0.7},

    -- UI elements
    currency       = {0.95, 0.85, 0.30, 1.0},  -- Gold coins
    abilities      = {0.60, 0.80, 1.0, 0.95},  -- Light blue
    interact_hint  = {0.90, 0.90, 0.70, 0.9},  -- Warm white

    -- Menus - dark with warm highlights
    menu_background = {0.08, 0.08, 0.12, 0.85}, -- Dark blue-gray

    -- Feedback - punchy colors
    flash_cooldown = {0.95, 0.95, 0.30, 1.0},
    damage_player  = {1.0, 0.25, 0.20, 1.0},   -- Bright red
    damage_enemy   = {0.95, 0.70, 0.30, 1.0},  -- Orange
    heal           = {0.30, 0.95, 0.40, 1.0},  -- Bright green
    critical       = {1.0, 0.50, 0.10, 1.0},   -- Fiery orange

    -- Warnings
    low_health     = {0.95, 0.10, 0.10, 0.40},
    low_stamina    = {0.95, 0.75, 0.10, 0.30},
  },

  fonts = { hud = "main", menu = "main", dialogue = "main", title = "main" },

  spacing = {
    margin_left = 12, margin_top = 12, margin_right = 12, margin_bottom = 12,
    bar_spacing = 3, element_gap = 20, menu_padding = 24, button_spacing = 12,
  },

  sizes = {
    health_bar_width = 200, health_bar_height = 16,
    energy_bar_width = 140, energy_bar_height = 12,
    stamina_bar_width = 140, stamina_bar_height = 10,
    bar_border = 2,
    boss_bar_height = 24, boss_bar_min_width = 400, boss_bar_screen_percent = 0.65,
    menu_button_width = 220, menu_button_height = 45,
  },

  animations = {
    menu_fade_in = 0.25, menu_fade_out = 0.18, menu_slide = 0.30,
    bar_update = 0.15, flash_duration = 0.40,
    toast_fade_in = 0.15, toast_fade_out = 0.40,
  },

  warnings = {
    low_health_threshold = 0.25, low_stamina_threshold = 0.20, low_energy_threshold = 0.20,
  },

  visibility = {
    show_health = true, show_energy = true, show_stamina = true,
    show_currency = true, show_abilities = true,
    show_interact_hint = true, show_minimap = true, show_boss_bar = true,
  },
}

-----------------------------------------------------------
-- THEME 2: NEON CYBERPUNK (Vibrant, High-Tech)
-----------------------------------------------------------
themes.neon = {
  colors = {
    health      = {1.0, 0.10, 0.50, 1.0},    -- Hot pink
    health_bg   = {0.20, 0.05, 0.15, 0.85},
    energy      = {0.10, 0.90, 1.0, 1.0},    -- Cyan
    energy_bg   = {0.05, 0.20, 0.25, 0.85},
    stamina     = {0.50, 1.0, 0.30, 1.0},    -- Lime green
    stamina_bg  = {0.10, 0.25, 0.10, 0.85},

    boss_health = {1.0, 0.20, 0.20, 1.0},    -- Neon red
    boss_health_bg = {0.30, 0.05, 0.10, 0.9},

    text_primary   = {0.10, 0.95, 1.0, 1.0}, -- Cyan text
    text_secondary = {0.60, 0.80, 0.90, 0.9},
    text_highlight = {1.0, 0.30, 0.90, 1.0}, -- Magenta
    text_disabled  = {0.40, 0.50, 0.55, 0.7},

    currency       = {0.95, 0.95, 0.30, 1.0},
    abilities      = {0.50, 0.90, 1.0, 1.0},
    interact_hint  = {0.30, 1.0, 0.80, 0.95},

    menu_background = {0.05, 0.08, 0.12, 0.90},

    flash_cooldown = {0.30, 1.0, 0.90, 1.0},
    damage_player  = {1.0, 0.10, 0.40, 1.0},
    damage_enemy   = {0.95, 0.60, 0.10, 1.0},
    heal           = {0.30, 1.0, 0.60, 1.0},
    critical       = {1.0, 0.20, 0.90, 1.0},

    low_health     = {1.0, 0.10, 0.50, 0.45},
    low_stamina    = {0.90, 0.90, 0.10, 0.35},
  },

  fonts = { hud = "main", menu = "main", dialogue = "main", title = "main" },

  spacing = {
    margin_left = 16, margin_top = 16, margin_right = 16, margin_bottom = 16,
    bar_spacing = 4, element_gap = 22, menu_padding = 28, button_spacing = 14,
  },

  sizes = {
    health_bar_width = 220, health_bar_height = 18,
    energy_bar_width = 160, energy_bar_height = 14,
    stamina_bar_width = 160, stamina_bar_height = 12,
    bar_border = 3,
    boss_bar_height = 26, boss_bar_min_width = 450, boss_bar_screen_percent = 0.70,
    menu_button_width = 240, menu_button_height = 50,
  },

  animations = {
    menu_fade_in = 0.18, menu_fade_out = 0.12, menu_slide = 0.22,
    bar_update = 0.10, flash_duration = 0.30,
    toast_fade_in = 0.10, toast_fade_out = 0.25,
  },

  warnings = {
    low_health_threshold = 0.30, low_stamina_threshold = 0.25, low_energy_threshold = 0.25,
  },

  visibility = {
    show_health = true, show_energy = true, show_stamina = true,
    show_currency = true, show_abilities = true,
    show_interact_hint = true, show_minimap = true, show_boss_bar = true,
  },
}

-----------------------------------------------------------
-- THEME 3: MINIMAL CLEAN (Modern, Sleek)
-----------------------------------------------------------
themes.minimal = {
  colors = {
    health      = {0.95, 0.30, 0.30, 0.90},
    health_bg   = {0.90, 0.90, 0.90, 0.30},  -- Light gray
    energy      = {0.30, 0.50, 0.95, 0.90},
    energy_bg   = {0.90, 0.90, 0.90, 0.30},
    stamina     = {0.30, 0.80, 0.40, 0.90},
    stamina_bg  = {0.90, 0.90, 0.90, 0.30},

    boss_health = {0.90, 0.25, 0.25, 0.95},
    boss_health_bg = {0.85, 0.85, 0.85, 0.50},

    text_primary   = {0.15, 0.15, 0.15, 1.0},  -- Dark gray (readable on light)
    text_secondary = {0.45, 0.45, 0.45, 0.95},
    text_highlight = {0.95, 0.50, 0.20, 1.0},  -- Orange accent
    text_disabled  = {0.65, 0.65, 0.65, 0.7},

    currency       = {0.90, 0.70, 0.20, 1.0},
    abilities      = {0.40, 0.60, 0.95, 0.95},
    interact_hint  = {0.30, 0.30, 0.30, 0.85},

    menu_background = {0.95, 0.95, 0.95, 0.95},  -- Light mode!

    flash_cooldown = {0.95, 0.60, 0.20, 1.0},
    damage_player  = {0.95, 0.25, 0.25, 1.0},
    damage_enemy   = {0.90, 0.55, 0.20, 1.0},
    heal           = {0.30, 0.85, 0.35, 1.0},
    critical       = {0.95, 0.40, 0.10, 1.0},

    low_health     = {0.95, 0.20, 0.20, 0.35},
    low_stamina    = {0.95, 0.70, 0.10, 0.25},
  },

  fonts = { hud = "main", menu = "main", dialogue = "main", title = "main" },

  spacing = {
    margin_left = 20, margin_top = 20, margin_right = 20, margin_bottom = 20,
    bar_spacing = 6, element_gap = 28, menu_padding = 32, button_spacing = 16,
  },

  sizes = {
    health_bar_width = 160, health_bar_height = 12,
    energy_bar_width = 120, energy_bar_height = 10,
    stamina_bar_width = 120, stamina_bar_height = 8,
    bar_border = 2,
    boss_bar_height = 20, boss_bar_min_width = 350, boss_bar_screen_percent = 0.60,
    menu_button_width = 200, menu_button_height = 42,
  },

  animations = {
    menu_fade_in = 0.20, menu_fade_out = 0.15, menu_slide = 0.25,
    bar_update = 0.12, flash_duration = 0.35,
    toast_fade_in = 0.12, toast_fade_out = 0.30,
  },

  warnings = {
    low_health_threshold = 0.25, low_stamina_threshold = 0.20, low_energy_threshold = 0.20,
  },

  visibility = {
    show_health = true, show_energy = true, show_stamina = true,
    show_currency = false,  -- Minimal: hide currency
    show_abilities = false, -- Minimal: hide abilities list
    show_interact_hint = true, show_minimap = true, show_boss_bar = true,
  },
}

-----------------------------------------------------------
-- THEME 4: RETRO PIXEL (8-bit inspired)
-----------------------------------------------------------
themes.retro = {
  colors = {
    health      = {0.90, 0.15, 0.15, 1.0},   -- Pure red
    health_bg   = {0.20, 0.05, 0.05, 0.90},
    energy      = {0.10, 0.40, 0.90, 1.0},   -- Pure blue
    energy_bg   = {0.05, 0.10, 0.25, 0.90},
    stamina     = {0.15, 0.90, 0.15, 1.0},   -- Pure green
    stamina_bg  = {0.05, 0.25, 0.05, 0.90},

    boss_health = {0.95, 0.10, 0.10, 1.0},
    boss_health_bg = {0.30, 0.05, 0.05, 0.95},

    text_primary   = {1.0, 1.0, 1.0, 1.0},   -- Pure white
    text_secondary = {0.75, 0.75, 0.75, 1.0},
    text_highlight = {1.0, 1.0, 0.0, 1.0},   -- Pure yellow
    text_disabled  = {0.50, 0.50, 0.50, 0.8},

    currency       = {1.0, 0.85, 0.0, 1.0},
    abilities      = {0.50, 0.80, 1.0, 1.0},
    interact_hint  = {1.0, 1.0, 0.60, 1.0},

    menu_background = {0.0, 0.0, 0.0, 0.90},  -- Pure black

    flash_cooldown = {1.0, 1.0, 0.0, 1.0},
    damage_player  = {1.0, 0.0, 0.0, 1.0},
    damage_enemy   = {1.0, 0.60, 0.0, 1.0},
    heal           = {0.0, 1.0, 0.0, 1.0},
    critical       = {1.0, 0.40, 0.0, 1.0},

    low_health     = {1.0, 0.0, 0.0, 0.50},
    low_stamina    = {1.0, 1.0, 0.0, 0.40},
  },

  fonts = { hud = "main", menu = "main", dialogue = "main", title = "main" },

  spacing = {
    margin_left = 8, margin_top = 8, margin_right = 8, margin_bottom = 8,
    bar_spacing = 2, element_gap = 16, menu_padding = 16, button_spacing = 8,
  },

  sizes = {
    health_bar_width = 180, health_bar_height = 14,
    energy_bar_width = 100, energy_bar_height = 10,
    stamina_bar_width = 100, stamina_bar_height = 8,
    bar_border = 2,
    boss_bar_height = 20, boss_bar_min_width = 300, boss_bar_screen_percent = 0.60,
    menu_button_width = 200, menu_button_height = 40,
  },

  animations = {
    menu_fade_in = 0.15, menu_fade_out = 0.10, menu_slide = 0.20,
    bar_update = 0.08, flash_duration = 0.25,
    toast_fade_in = 0.08, toast_fade_out = 0.20,
  },

  warnings = {
    low_health_threshold = 0.25, low_stamina_threshold = 0.20, low_energy_threshold = 0.20,
  },

  visibility = {
    show_health = true, show_energy = true, show_stamina = true,
    show_currency = true, show_abilities = true,
    show_interact_hint = true, show_minimap = true, show_boss_bar = true,
  },
}

-----------------------------------------------------------
-- THEME 5: HORROR DARK (Survival, Tense)
-----------------------------------------------------------
themes.horror = {
  colors = {
    health      = {0.70, 0.10, 0.10, 0.85},  -- Dark blood red
    health_bg   = {0.10, 0.05, 0.05, 0.95},
    energy      = {0.15, 0.30, 0.60, 0.85},  -- Muted blue
    energy_bg   = {0.05, 0.08, 0.15, 0.95},
    stamina     = {0.50, 0.50, 0.50, 0.80},  -- Gray (exhaustion)
    stamina_bg  = {0.08, 0.08, 0.08, 0.95},

    boss_health = {0.80, 0.05, 0.05, 0.95},
    boss_health_bg = {0.15, 0.03, 0.03, 0.98},

    text_primary   = {0.85, 0.85, 0.80, 0.95}, -- Dirty white
    text_secondary = {0.60, 0.60, 0.55, 0.90},
    text_highlight = {0.85, 0.75, 0.50, 0.95}, -- Dusty gold
    text_disabled  = {0.35, 0.35, 0.35, 0.7},

    currency       = {0.75, 0.70, 0.50, 0.95},
    abilities      = {0.50, 0.55, 0.70, 0.90},
    interact_hint  = {0.80, 0.75, 0.60, 0.85},

    menu_background = {0.05, 0.05, 0.05, 0.95}, -- Nearly black

    flash_cooldown = {0.80, 0.70, 0.40, 0.95},
    damage_player  = {0.90, 0.15, 0.10, 1.0},
    damage_enemy   = {0.80, 0.50, 0.30, 0.95},
    heal           = {0.40, 0.70, 0.40, 0.90},
    critical       = {0.85, 0.30, 0.10, 1.0},

    low_health     = {0.70, 0.05, 0.05, 0.55}, -- Strong vignette
    low_stamina    = {0.40, 0.40, 0.40, 0.40},
  },

  fonts = { hud = "main", menu = "main", dialogue = "main", title = "main" },

  spacing = {
    margin_left = 10, margin_top = 10, margin_right = 10, margin_bottom = 10,
    bar_spacing = 2, element_gap = 18, menu_padding = 20, button_spacing = 10,
  },

  sizes = {
    health_bar_width = 180, health_bar_height = 14,
    energy_bar_width = 120, energy_bar_height = 10,
    stamina_bar_width = 120, stamina_bar_height = 8,
    bar_border = 2,
    boss_bar_height = 22, boss_bar_min_width = 380, boss_bar_screen_percent = 0.65,
    menu_button_width = 210, menu_button_height = 42,
  },

  animations = {
    menu_fade_in = 0.30, menu_fade_out = 0.22, menu_slide = 0.35,
    bar_update = 0.18, flash_duration = 0.45,
    toast_fade_in = 0.18, toast_fade_out = 0.45,
  },

  warnings = {
    low_health_threshold = 0.35,  -- Warn earlier in horror
    low_stamina_threshold = 0.30,
    low_energy_threshold = 0.30,
  },

  visibility = {
    show_health = true, show_energy = true, show_stamina = true,
    show_currency = true, show_abilities = true,
    show_interact_hint = true, show_minimap = true, show_boss_bar = true,
  },
}

return themes

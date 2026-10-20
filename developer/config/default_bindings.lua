-- developer/config/default_bindings.lua
-- Default high-level game action bindings mapped to low-level input actions
-- defined in `developer/input/game.input_binding`. Users can override/rebind at runtime.

local M = {
  -- Persistable low-level actions emitted by game.input_binding. Keep this
  -- allowlist synchronized when adding or renaming a physical input action.
  inputs = {
    "key_delete", "key_backspace", "text", "marked_text",
    "editor_rescan", "editor_save", "editor_load", "editor_export",
    "key_lctrl", "key_rctrl", "key_lshift", "key_rshift",
    "mouse_button_1", "mouse_button_2", "mouse_button_3",
    "mouse_wheel_up", "mouse_wheel_down", "click", "touch",
    "key_tab",
    "gamepad_connected", "gamepad_disconnected",
    "gamepad_lpad_left", "gamepad_lpad_right", "gamepad_lpad_up", "gamepad_lpad_down",
    "gamepad_rpad_left", "gamepad_rpad_right", "gamepad_rpad_up", "gamepad_rpad_down",
    "gamepad_lshoulder", "gamepad_rshoulder", "gamepad_ltrigger", "gamepad_rtrigger",
    "gamepad_lstick_left", "gamepad_lstick_right", "gamepad_lstick_up", "gamepad_lstick_down",
    "gamepad_lstick_click",
    "gamepad_rstick_left", "gamepad_rstick_right", "gamepad_rstick_up", "gamepad_rstick_down",
    "gamepad_rstick_click", "gamepad_start", "gamepad_back", "gamepad_guide",
    "key_escape", "key_p",
    "key_up", "key_down", "key_left", "key_right",
    "key_w", "key_s", "key_a", "key_d",
    "key_m", "key_z", "key_y", "key_x", "key_c", "key_enter",
    "key_f1", "key_f2", "key_f3", "key_f4", "key_f5", "key_f6", "key_f7", "key_f9", "key_f12",
    "key_g", "key_r", "key_space", "key_v", "key_j", "key_k", "key_i", "key_q", "key_u", "key_e",
  },

  actions = {
    -- Movement is handled directly in input_controller for now.

    -- Core actions
    JUMP              = { "key_space", "gamepad_rpad_down" },
    SLIDE             = { "key_v", "gamepad_rtrigger" },       -- slide / air dash
    PARRY             = { "key_q", "gamepad_ltrigger" },
    GRAPPLE           = { "key_tab", "gamepad_lshoulder" },    -- Tab / left shoulder
    BACKDASH          = { },
    LIGHT_MELEE       = { "key_j", "gamepad_rpad_left" },
    HEAVY_MELEE       = { "key_k", "key_y", "gamepad_rpad_up" },
    GROUND_POUND      = { },
    RANGED            = { "key_i", "gamepad_rpad_right" },
    MORPH_TOGGLE      = { },
    INTERACT          = { "key_e", "key_u", "gamepad_rshoulder" },

    -- Utility / UI
    MINIMAP_TOGGLE    = { "key_m", "gamepad_rstick_click" }, -- M / R3 cycles map display
    WORLD_MAP_TOGGLE  = { "gamepad_lpad_up" },       -- D-pad Up for world map
    INVENTORY_TOGGLE  = { "gamepad_lpad_left" },     -- D-pad Left for inventory
    MAP_MARKER        = { "key_f12", "gamepad_lpad_down" }, -- Screenshot marker
    POTION            = { },                         -- Unassigned - can be mapped by user

    -- Camera look (analog right-stick direction values)
    CAMERA_UP         = { "gamepad_rstick_up" },
    CAMERA_DOWN       = { "gamepad_rstick_down" },

    -- Settings
    SETTINGS_TOGGLE   = { },

    -- Pause
    PAUSE_TOGGLE      = {
      "key_escape", "key_p",
      "gamepad_start", "gamepad_back",
    },
  }
}

return M

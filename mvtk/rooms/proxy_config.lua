-- mvtk/developer/rooms/proxy_config.lua
-- Central configuration for the proxy launcher and HUD. All tweakable values live here.

local M = {}

M.MODES = { GAME = hash("game"), EDITOR = hash("editor") }

M.DEFAULTS = {
    start_in_menu   = true,             -- start at launcher menu
    default_mode    = M.MODES.GAME,     -- if start_in_menu = false
    reload_if_same  = false,            -- clicking current mode forces reload?

    -- Keep mode collections in memory after disable?
    keep_loaded = {
        [M.MODES.GAME]   = false,      -- unload GAME mode completely to ensure fresh state
        [M.MODES.EDITOR] = false,
    },

    -- How to hide the launcher GUI: "component" is safest (disables GUI component)
    menu_hide_method = "component",     -- "component" | "node"

    -- Optional "save before unload" handshake with an agent inside the active mode.
    -- If the mode doesn't register an agent, switching continues after timeout.
    pre_unload = {
        enabled    = true,
        timeout_s  = 0.50,
        request_id = hash("mode_prepare_unload"),
        ready_id   = hash("mode_ready_to_unload"),
    },
}

-- The proxy component ids on the GO /mvtk/boot/proxy_host
M.PROXY_COMPONENT_IDS = {
    [M.MODES.GAME]   = hash("game_cp"),
    [M.MODES.EDITOR] = hash("editor_cp"),
}

-- Launcher GUI (menu) node ids/text
M.MENU_GUI = {
    component_id = hash("gui"),       -- GUI component id on /mvtk/boot/proxy_menu.go
    node_ids = {
        root         = "root",
        btn_game     = "btn_game",
        btn_editor   = "btn_editor",
        label_title  = "title",
        label_status = "status",
    },
    text = {
        title   = "MV Toolkit - Mode Select",
        game    = "Play / Test",
        editor  = "Layout Editor",
        loading = "Loading...",
    }
}

return M



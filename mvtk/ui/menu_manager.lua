-- mvtk/developer/ui/menu_manager.lua
-- Unified menu management system with stack-based navigation
-- Handles menu opening, closing, transitions, and input focus

local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })

local M = {}

local Pause = require "mvtk.core.pause"
local InputCtl = require "mvtk.rooms.input_controller"
local AudioOk, Audio = pcall(require, "mvtk.audio.audio")

-- Menu stack for hierarchical navigation
local menu_stack = {}

-- Active menu reference
local current_menu = nil

-- Menu registry (menu_id -> menu_url)
local registered_menus = {}

-- State
local is_menu_open = false
local input_blocked = false

-- Hardening (Phase 3 step 21):
-- * MAX_STACK_DEPTH guards against runaway open_menu loops where a menu
--   reopens itself on close. Pushes beyond the limit are refused.
-- * STUCK_TIMEOUT_S guards against a menu that stops responding to
--   menu_close (e.g. crashed GUI script). Callers must drive M.tick(dt) for
--   the timeout to advance; menu scripts that don't tick are unchanged.
-- * URL validation: open_menu / replace_menu now verify the registered URL
--   resolves with go.exists before posting, so a stale registration cannot
--   cause an engine error storm.
local MAX_STACK_DEPTH = 16
local STUCK_TIMEOUT_S = 30.0
local clock_s = 0
local current_menu_opened_at = 0

local function url_resolves(url)
    if url == nil then return false end
    if type(go) ~= "table" or type(go.exists) ~= "function" then
        -- Outside Defold runtime (tests): accept anything truthy.
        return true
    end
    local ok, exists = pcall(go.exists, url)
    return ok and exists == true
end

-- Debug logging
local menu_log = Util.make_debug_log("[MENU_MANAGER]", function()
    return M.debug_enabled or (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.ui)
end)

local function ui_sfx(id)
  if AudioOk and Audio and Audio.sfx then
    pcall(Audio.sfx, id or "ui_click")
  end
end

-----------------------------------------------------------
-- Public API
-----------------------------------------------------------

-- Initialize the menu manager
function M.init()
  menu_stack = {}
  current_menu = nil
  is_menu_open = false
  input_blocked = false
  menu_log("Menu manager initialized")
end

-- Register a menu with the system
-- @param menu_id: string - Unique identifier for the menu
-- @param menu_url: string or url - URL of the menu GUI script
function M.register_menu(menu_id, menu_url)
  if not menu_id then
    menu_log("ERROR: Cannot register menu with nil ID")
    return false
  end

  registered_menus[menu_id] = menu_url
  menu_log("Registered menu:", menu_id, "->", tostring(menu_url))
  return true
end

-- Unregister a menu
function M.unregister_menu(menu_id)
  if registered_menus[menu_id] then
    registered_menus[menu_id] = nil
    menu_log("Unregistered menu:", menu_id)
    return true
  end
  return false
end

-- Get menu URL from registry
function M.get_menu_url(menu_id)
  return registered_menus[menu_id]
end

-- Open a menu (pushes to stack)
-- @param menu_id: string - Menu identifier (must be registered)
-- @param data: table - Optional data to pass to the menu
-- @param transition: string - Transition type ("fade", "slide", "instant")
function M.open_menu(menu_id, data, transition)
  if not menu_id then
    menu_log("ERROR: Cannot open menu with nil ID")
    return false
  end

  local menu_url = registered_menus[menu_id]
  if not menu_url then
    menu_log("ERROR: Menu not registered:", menu_id)
    return false
  end

  -- Validate the URL still resolves; a stale registration would otherwise
  -- cause an engine error on every msg.post call below.
  if not url_resolves(menu_url) then
    menu_log("ERROR: Menu URL no longer resolves:", menu_id, tostring(menu_url))
    registered_menus[menu_id] = nil
    return false
  end

  -- Stack-depth safety: refuse to push beyond MAX_STACK_DEPTH so a menu that
  -- reopens itself on close cannot grow the stack without bound.
  if current_menu and #menu_stack >= MAX_STACK_DEPTH then
    menu_log("ERROR: Menu stack at MAX_STACK_DEPTH; refusing to open", menu_id)
    return false
  end

  menu_log("Opening menu:", menu_id)

  -- Push current menu to stack if one is open
  if current_menu then
    table.insert(menu_stack, current_menu)
    menu_log("Pushed to stack:", current_menu.id, "Stack depth:", #menu_stack)
  end

  -- Set as current menu
  current_menu = {
    id = menu_id,
    url = menu_url,
    data = data or {},
    transition = transition or "fade"
  }
  current_menu_opened_at = clock_s

  -- Block input and pause game
  if not is_menu_open then
    M.block_game_input(true)
    M.set_pause(true)
    is_menu_open = true
  end

  ui_sfx("ui_click")

  -- Send open message to menu
  local ok = Util.safe_post(menu_url, hash("menu_open"), data or {}, {
    on_error = function(err)
      menu_log("ERROR: Failed to open menu:", menu_id, err)
    end,
  })
  if not ok then
    return false
  end

  return true
end

-- Close the current menu (pops from stack)
-- @param transition: string - Transition type
function M.close_menu(transition)
  if not current_menu then
    menu_log("WARNING: No menu to close")
    return false
  end

  ui_sfx("ui_back")

  menu_log("Closing menu:", current_menu.id)

  -- Send close message to current menu
  Util.safe_post(current_menu.url, hash("menu_close"), {}, {
    on_error = function(err) menu_log("ERROR: Failed to close menu:", err) end,
  })

  -- Pop previous menu from stack
  if #menu_stack > 0 then
    current_menu = table.remove(menu_stack)
    menu_log("Restored from stack:", current_menu.id, "Stack depth:", #menu_stack)

    -- Reopen the previous menu
    Util.safe_post(current_menu.url, hash("menu_open"), current_menu.data or {}, {
      on_error = function() menu_log("ERROR: Failed to restore menu from stack") end,
    })
  else
    -- No more menus in stack, close completely
    current_menu = nil
    M.block_game_input(false)
    M.set_pause(false)
    is_menu_open = false
    menu_log("Menu system closed")
  end

  return true
end

-- Close all menus (clears entire stack)
function M.close_all_menus()
  menu_log("Closing all menus")
  ui_sfx("ui_back")

  -- Close current menu
  if current_menu then
    Util.safe_post(current_menu.url, hash("menu_close"), {}, {
      on_error = function() menu_log("ERROR: Failed to close current menu") end,
    })
  end

  -- Close all menus in stack
  for i = #menu_stack, 1, -1 do
    local menu = menu_stack[i]
    Util.safe_post(menu.url, hash("menu_close"), {}, {
      on_error = function() menu_log("ERROR: Failed to close stacked menu:", menu.id) end,
    })
  end

  -- Clear state
  menu_stack = {}
  current_menu = nil
  M.block_game_input(false)
  M.set_pause(false)
  is_menu_open = false

  menu_log("All menus closed")
end

-- Go back to previous menu (same as close_menu but more explicit)
function M.back()
  return M.close_menu()
end

-- Check if any menu is currently open
function M.is_open()
  return is_menu_open
end

-- Get current menu ID
function M.get_current_menu()
  return current_menu and current_menu.id or nil
end

-- Get menu stack depth
function M.get_stack_depth()
  return #menu_stack
end

-- Block game input while menu is open
function M.block_game_input(blocked)
  input_blocked = blocked
  if InputCtl and InputCtl.set_blocked then
    InputCtl.set_blocked(blocked)
  end
  menu_log("Game input blocked:", blocked)
end

-- Set game pause state
function M.set_pause(paused)
  if Pause and Pause.set then
    Pause.set(paused)
  end
  menu_log("Game paused:", paused)
end

-- Handle back button press (for menu navigation)
function M.on_back_pressed()
  if is_menu_open then
    M.back()
    return true  -- Consumed
  end
  return false  -- Not consumed
end

-----------------------------------------------------------
-- Menu State Queries
-----------------------------------------------------------

-- Check if a specific menu is currently open
function M.is_menu_active(menu_id)
  return current_menu and current_menu.id == menu_id
end

-- Check if a menu is in the stack
function M.is_menu_in_stack(menu_id)
  for _, menu in ipairs(menu_stack) do
    if menu.id == menu_id then
      return true
    end
  end
  return false
end

-- Get data for current menu
function M.get_menu_data()
  return current_menu and current_menu.data or {}
end

-- Update data for current menu
function M.set_menu_data(data)
  if current_menu then
    current_menu.data = data or {}
  end
end

-----------------------------------------------------------
-- Advanced Features
-----------------------------------------------------------

-- Replace current menu without adding to stack
function M.replace_menu(menu_id, data, transition)
  if not current_menu then
    return M.open_menu(menu_id, data, transition)
  end

  menu_log("Replacing menu:", current_menu.id, "->", menu_id)

  -- Close current without popping stack
  Util.safe_post(current_menu.url, hash("menu_close"), {}, {
    on_error = function() menu_log("ERROR: Failed to close menu for replacement") end,
  })

  -- Open new menu
  local menu_url = registered_menus[menu_id]
  if not menu_url then
    menu_log("ERROR: Menu not registered:", menu_id)
    return false
  end

  if not url_resolves(menu_url) then
    menu_log("ERROR: Replacement menu URL no longer resolves:", menu_id)
    registered_menus[menu_id] = nil
    return false
  end

  current_menu = {
    id = menu_id,
    url = menu_url,
    data = data or {},
    transition = transition or "fade"
  }
  current_menu_opened_at = clock_s

  local ok2 = Util.safe_post(menu_url, hash("menu_open"), data or {}, {
    on_error = function() menu_log("ERROR: Failed to open replacement menu") end,
  })
  if not ok2 then
    return false
  end

  return true
end

-- Clear stack but keep current menu open
function M.clear_stack()
  menu_log("Clearing menu stack, current menu:", current_menu and current_menu.id or "none")
  menu_stack = {}
end

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------

-- Enable/disable debug logging
M.debug_enabled = false

function M.set_debug(enabled)
  M.debug_enabled = enabled
  menu_log("Debug logging:", enabled and "enabled" or "disabled")
end

-----------------------------------------------------------
-- Utility Functions for Menu Scripts
-----------------------------------------------------------

-- Helper for menu scripts to send messages to menu manager
function M.post_to_manager(message_id, data)
  -- This could be used for future communication back to manager
  -- For now, menus directly call M.open_menu(), M.close_menu(), etc.
  menu_log("Message from menu:", message_id)
end

-- Get menu configuration from a config file
function M.load_menu_config(config_path)
  local ok, config = pcall(require, config_path)
  if ok and config then
    return config
  end
  menu_log("WARNING: Failed to load menu config:", config_path)
  return {}
end

-- Drive watchdog timeout. Optional: callers that want stuck-menu recovery
-- should call this from a script update(). No-op when no menu is open.
function M.tick(dt)
  clock_s = clock_s + (tonumber(dt) or 0)
  if not current_menu then return end
  if (clock_s - current_menu_opened_at) >= STUCK_TIMEOUT_S then
    menu_log("WARNING: Menu '" .. tostring(current_menu.id) ..
      "' exceeded stuck timeout; force-closing")
    M.close_all_menus()
  end
end

-- Reset internal timers; intended for tests / hot-reload.
function M.reset_timers()
  clock_s = 0
  current_menu_opened_at = 0
end

return M

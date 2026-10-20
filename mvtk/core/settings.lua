-- mvtk/core/settings.lua
-- Comprehensive settings management system
-- Handles audio, graphics, and gameplay settings. Input bindings are stored
-- independently by mvtk.core.input_bindings.

local Util = require "mvtk.core.util"
local C = require "mvtk.core.constants"
local SafeRequire = require "mvtk.core.safe_require"
local Gamefeel = Util.require_module('mvtk.core.gamefeel')
local SettingsDefaults = Util.require_config("developer.config.settings_defaults")
local Config = Util.require_config("developer.config.resolved_config")
local RuntimeSettings = Util.require_config("developer.config.runtime_settings")
local SavePaths = require "mvtk.core.save_paths"
local Migrations = require "mvtk.core.save_migrations"

local M = {}
local SAVE_KEY = 'mvtk_settings'

-- Default settings structure
local _s = {}

local function base_defaults()
  if type(SettingsDefaults) == "table" and next(SettingsDefaults) then
    return Util.deep_merge({}, SettingsDefaults)
  end
  return {
    audio = {
      master_volume = 0.8,
      music_volume = 0.7,
      sfx_volume = 0.8,
      muted = false,
    },
    graphics = {
      window_mode = "windowed",  -- "windowed", "fullscreen_windowed", "fullscreen"
      vsync = true,
      resolution_scale = 1.0,  -- 0.5 to 2.0
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
      icon_theme = "xbox",
    },
    language = 'en',
  }
end

_s = base_defaults()

function M.load()
  _s = base_defaults()
  -- Creator overrides supply defaults; explicit player preferences win below.
  if RuntimeSettings and RuntimeSettings.get_game_settings then
    local wizard = RuntimeSettings.get_game_settings() or {}
    for _, key in ipairs({ "camera_shake", "damage_numbers", "icon_theme" }) do
      if wizard[key] ~= nil then _s.gameplay[key] = wizard[key] end
    end
  end
  local ok, data = pcall(sys.load, SavePaths.path(SAVE_KEY))
  local had_settings = ok and type(data) == "table" and next(data) ~= nil
  local reason
  if ok then data, reason = Migrations.preferences(data) end
  M.last_save_error = not ok and "unreadable_settings" or reason
  if ok and type(data) == 'table' then
    -- Load only current top-level settings. Controller bindings have their own
    -- versioned store and unknown settings sections are intentionally ignored.
    for key, default_value in pairs(_s) do
      local saved_value = data[key]
      if type(default_value) == "table" and type(saved_value) == "table" then
        _s[key] = Util.deep_merge(default_value, saved_value)
      elseif saved_value ~= nil and type(saved_value) == type(default_value) then
        _s[key] = saved_value
      end
    end
  end

  return _s, had_settings and data ~= nil
end

function M.save()
  local path = SavePaths.path(SAVE_KEY)
  local readable, previous = pcall(sys.load, path)
  local supported, reason
  if readable then supported, reason = Migrations.preferences(previous) end
  if not readable or not supported then
    M.last_save_error = reason or "unreadable_settings"
    return false, M.last_save_error
  end
  if next(previous) and previous.version == nil then
    local backup = path .. "_pre_upgrade_v0"
    local read_ok, saved = pcall(sys.load, backup)
    if not read_ok then return false, "Cannot read settings backup" end
    if not next(saved) then
      local wrote, result = pcall(sys.save, backup, previous)
      if not wrote or result == false then return false, "Cannot preserve settings backup" end
      local checked, copy = pcall(sys.load, backup)
      if not checked or not Migrations.equal(previous,copy) then return false, "Settings backup verification failed" end
    elseif not Migrations.preferences(saved) then
      return false, "Unsupported settings backup; original preserved"
    end
  end
  local payload = Migrations.copy(_s)
  payload.version = 1
  local ok, err = pcall(sys.save, path, payload)
  ok = ok and err ~= false
  M.last_save_error = not ok and tostring(err) or nil
  return ok, M.last_save_error
end

-- SaveManager and the menu use the same live preferences, including after reload.
function M.data() return _s end

function M.get(path)
  -- path like "gameplay.rumble"
  return Util.get_nested(_s, path)
end

function M.set(path, value)
  local parts = {}
  for seg in tostring(path or ''):gmatch('[^%.]+') do table.insert(parts, seg) end
  if #parts == 0 then return end
  local ref = _s
  for i=1,#parts-1 do
    local seg = parts[i]
    ref[seg] = ref[seg] or {}
    ref = ref[seg]
  end
  ref[parts[#parts]] = value
end

function M.apply_gamefeel()
  if not Gamefeel then return end
  local gp = _s.gameplay or {}
  Gamefeel.enabled = (gp.camera_shake ~= false)
  Gamefeel.rumble_enabled = (gp.rumble ~= false)
  Gamefeel.enable_damage_numbers(gp.damage_numbers and true or false)
  if gp.number_options then Gamefeel.set_number_options(gp.number_options) end
end

-- Apply audio settings to the engine
function M.apply_audio()
  local audio = _s.audio or {}
  local Audio = Util.require_module("mvtk.audio.audio")

  local function clamp01(v)
    return math.max(0, math.min(1, tonumber(v) or 0))
  end
  local function safe_set_group_gain(group_hash, value)
    if not group_hash then return end
    pcall(sound.set_group_gain, group_hash, clamp01(value))
  end

  -- There is no guaranteed engine-level "master" group in game.project.
  -- Apply master as a multiplier to concrete groups instead.
  local master = audio.muted and 0 or clamp01(audio.master_volume or 0.8)

  -- Apply music volume (master * music)
  local music = audio.muted and 0 or (master * clamp01(audio.music_volume or 0.7))
  safe_set_group_gain(C.AUDIO_GROUP.MUSIC, music)
  if Audio and Audio.set_volume then
    Audio.set_volume("music", music)
  end

  -- Apply SFX volume (master * sfx)
  local sfx = audio.muted and 0 or (master * clamp01(audio.sfx_volume or 0.8))
  safe_set_group_gain(C.AUDIO_GROUP.SFX, sfx)
  if Audio and Audio.set_volume then
    Audio.set_volume("sfx", sfx)
  end

  -- Ambient follows master because there is no dedicated ambient slider yet.
  safe_set_group_gain(C.AUDIO_GROUP.AMBIENT, master)
  if Audio and Audio.set_volume then
    Audio.set_volume("ambient", master)
  end
end

-- Apply graphics settings to the engine
function M.apply_graphics()
  local gfx = _s.graphics or {}
  -- Debug disabled: apply_graphics inputs

  -- Load defos extension. quiet() because defos is a third-party native
  -- extension that's only present when the user installs it; absence is normal.
  local defos_ok, defos = SafeRequire.quiet("defos", "mvtk.core.settings.apply_graphics")
  -- Debug disabled: defos availability
  -- Debug disabled: defos load status

  if not defos_ok or not defos then
    return
  end

  -- Apply window mode
  if gfx.window_mode then
    local mode = gfx.window_mode
    -- Debug disabled: window mode

    if mode == "fullscreen" then
      -- Fullscreen exclusive mode
      defos.set_fullscreen(true)

    elseif mode == "fullscreen_windowed" then
      -- Fullscreen windowed mode (window at native resolution with title bar)
      -- Exit exclusive fullscreen first
      defos.set_fullscreen(false)

      -- Get primary display size
      local displays = defos.get_displays()
      local primary_display = displays and displays[1]
      local screen_width = 1920
      local screen_height = 1080

      if primary_display then
        screen_width = primary_display.bounds.width
        screen_height = primary_display.bounds.height
      end

      -- Set window to cover entire screen
      defos.set_window_size(0, 0, screen_width, screen_height)

    else  -- "windowed"
      -- Regular windowed mode at a fixed 1080p target (clamped to the display)
      -- Exit fullscreen
      defos.set_fullscreen(false)

      -- Get primary display size
      local displays = defos.get_displays()
      local primary_display = displays and displays[1]
      local screen_width = 1920
      local screen_height = 1080

      if primary_display then
        screen_width = primary_display.bounds.width
        screen_height = primary_display.bounds.height
      end

      -- Target 1080p to avoid ultrawide stretching; clamp down if screen is smaller
      local target_w = (Config.window and Config.window.target_width) or 1920
      local target_h = (Config.window and Config.window.target_height) or 1080
      local scale = math.min(screen_width / target_w, screen_height / target_h, 1.0)
      local win_width = math.floor(target_w * scale + 0.5)
      local win_height = math.floor(target_h * scale + 0.5)

      -- Center the window on screen
      local win_x = math.floor((screen_width - win_width) / 2)
      local win_y = math.floor((screen_height - win_height) / 2)

      defos.set_window_size(win_x, win_y, win_width, win_height)
      -- Debug disabled: windowed size log
    end
  end

  -- VSync handling - engine system message (documented socket is @system:,
  -- not the render script, which silently ignored it).
  if gfx.vsync ~= nil then
    local vsync_value = gfx.vsync and 1 or 0
    msg.post("@system:", "set_vsync", { swap_interval = vsync_value })
  end

  -- Show FPS is handled by the HUD system reading M.get("graphics.show_fps")
end

-- Apply all settings
function M.apply_all()
  M.apply_audio()
  M.apply_graphics()
  M.apply_gamefeel()
end

-- Convenience functions for audio
function M.get_master_volume()
  return M.get("audio.master_volume") or 0.8
end

function M.set_master_volume(volume, opts)
  M.set("audio.master_volume", math.max(0, math.min(1, volume)))
  M.apply_audio()
  if not (opts and opts.save == false) then M.save() end
end

function M.get_music_volume()
  return M.get("audio.music_volume") or 0.7
end

function M.set_music_volume(volume, opts)
  M.set("audio.music_volume", math.max(0, math.min(1, volume)))
  M.apply_audio()
  if not (opts and opts.save == false) then M.save() end
end

function M.get_sfx_volume()
  return M.get("audio.sfx_volume") or 0.8
end

function M.set_sfx_volume(volume, opts)
  M.set("audio.sfx_volume", math.max(0, math.min(1, volume)))
  M.apply_audio()
  if not (opts and opts.save == false) then M.save() end
end

function M.is_muted()
  return M.get("audio.muted") or false
end

function M.set_muted(muted)
  M.set("audio.muted", muted)
  M.apply_audio()
  M.save()
end

function M.toggle_mute()
  M.set_muted(not M.is_muted())
end

-- Convenience functions for graphics
-- Window mode functions
function M.get_window_mode()
  return M.get("graphics.window_mode") or "windowed"
end

function M.set_window_mode(mode)
  -- Valid modes: "windowed", "fullscreen_windowed", "fullscreen"
  if mode == "windowed" or mode == "fullscreen_windowed" or mode == "fullscreen" then
    M.set("graphics.window_mode", mode)
    -- Debug disabled: window mode set
    M.apply_graphics()
    M.save()
  else
  end
end

function M.cycle_window_mode()
  local current = M.get_window_mode()
  local modes = { "windowed", "fullscreen_windowed", "fullscreen" }
  for i, m in ipairs(modes) do
    if m == current then
      local next_mode = modes[(i % #modes) + 1]
      M.set_window_mode(next_mode)
      return
    end
  end
end

function M.get_vsync()
  return M.get("graphics.vsync")
end

function M.set_vsync(enabled)
  M.set("graphics.vsync", enabled)
  M.apply_graphics()
  M.save()
end

function M.get_show_fps()
  return M.get("graphics.show_fps") or false
end

function M.set_show_fps(enabled)
  M.set("graphics.show_fps", enabled)
  M.save()
end

-- Controller remapping has one source of truth: mvtk.core.input_bindings.
-- Settings owns presentation and delegates persistence to that service.
local CONTROL_ACTIONS = {
  jump = "JUMP",
  dash = "SLIDE",
  attack = "LIGHT_MELEE",
  special = "HEAVY_MELEE",
  ranged = "RANGED",
  interact = "INTERACT",
  map = "MINIMAP_TOGGLE",
  inventory = "INVENTORY_TOGGLE",
}

local function get_input_bindings(context)
  local ok, InputBindings = SafeRequire("mvtk.core.input_bindings", context)
  if ok then return InputBindings end
  return nil
end

function M.get_control_bindings()
  local InputBindings = get_input_bindings("mvtk.core.settings.get_control_bindings")
  local bindings = {}
  if not InputBindings then return bindings end
  for friendly_name, action_name in pairs(CONTROL_ACTIONS) do
    bindings[friendly_name] = InputBindings.get_controller_binding(action_name)
  end
  return bindings
end

function M.set_control_binding(action, button)
  local action_name = CONTROL_ACTIONS[action]
  local InputBindings = get_input_bindings("mvtk.core.settings.set_control_binding")
  if not action_name or not InputBindings then return false end
  if button ~= nil and not InputBindings.CONTROLLER_INPUTS[button] then return false end
  if not InputBindings.set_controller_binding(action_name, button) then return false end
  return InputBindings.save()
end

function M.reset_control_bindings()
  local InputBindings = get_input_bindings("mvtk.core.settings.reset_control_bindings")
  return InputBindings and InputBindings.reset() or false
end

function M.reset_to_defaults(category)
  -- Reset specific category or all if nil
  if category then
    _s[category] = Util.deep_merge({}, M.get_defaults()[category])
  else
    _s = Util.deep_merge({}, M.get_defaults())
  end
  M.apply_all()
  M.save()
end

-- Controller icon theme helpers
local VALID_ICON_THEMES = {xbox = true, playstation = true, switch = true}

function M.get_icon_theme()
  local theme = M.get("gameplay.icon_theme")
  return VALID_ICON_THEMES[theme] and theme or "xbox"
end

function M.set_icon_theme(theme)
  if VALID_ICON_THEMES[theme] then
    M.set("gameplay.icon_theme", theme)
  else
    M.set("gameplay.icon_theme", "xbox")
  end
  M.save()
end

function M.toggle_icon_theme()
  local order = {"xbox", "playstation", "switch"}
  local current = M.get_icon_theme()
  for i, t in ipairs(order) do
    if t == current then
      M.set_icon_theme(order[(i % #order) + 1])
      return
    end
  end
  M.set_icon_theme("xbox")
end

function M.get_defaults()
  -- Return a copy of the original default settings
  return base_defaults()
end

return M

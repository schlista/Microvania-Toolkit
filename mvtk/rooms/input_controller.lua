-- mvtk/rooms/input_controller.lua
-- Unified keyboard and Defold 1.13.2+ SDL game-controller input.

local Util = require "mvtk.core.util"
local RuntimeSettings = require "developer.config.runtime_settings"
local PS = RuntimeSettings.get_player_settings()
local Bindings = require "mvtk.core.input_bindings"
local Debug = Util.require_config("developer.config.debug_config")
local C = require "mvtk.core.constants"
local TutorialPopups = require "mvtk.ui.tutorial_popups"

local M = {}

local function debug_enabled()
  return (Debug.global and Debug.global.enable)
    or (Debug.gameplay and Debug.gameplay.input)
end

local input_log = Util.make_debug_log("[INPUT]", debug_enabled)

local KEYBOARD_DIRECTIONS = {
  [hash("key_left")] = "left",
  [hash("key_a")] = "left",
  [hash("key_right")] = "right",
  [hash("key_d")] = "right",
  [hash("key_up")] = "up",
  [hash("key_w")] = "up",
  [hash("key_down")] = "down",
  [hash("key_s")] = "down",
}

M.input_state = {
  move_x = 0, move_y = 0, left_mag = 0,

  jump_down = false, jump_held = false, jump_up = false,
  slide_down = false, slide_held = false, slide_up = false,

  light_down = false, heavy_down = false,
  light_up = false, heavy_up = false, light_held = false, heavy_held = false,
  ranged_down = false,
  parry_down = false,
  grapple_down = false, grapple_held = false, grapple_up = false,
  interact_down = false, interact_held = false,
  potion_down = false,
  marker_down = false,

  backdash_down = false,
  ground_pound_down = false,
  morph_toggle_down = false,

  camera_y = 0,
}

local sources = {
  digital = { left = {}, right = {}, up = {}, down = {} },
  left_stick = { left = 0, right = 0, up = 0, down = 0 },
  camera = { up = 0, down = 0 },
}

local held_sources = {
  jump_held = { keyboard = {}, gamepads = {} },
  slide_held = { keyboard = {}, gamepads = {} },
  light_held = { keyboard = {}, gamepads = {} },
  heavy_held = { keyboard = {}, gamepads = {} },
  interact_held = { keyboard = {}, gamepads = {} },
  grapple_held = { keyboard = {}, gamepads = {} },
}

local EDGE_FIELDS = {
  "jump_down", "jump_up",
  "slide_down", "slide_up",
  "light_down", "light_up",
  "heavy_down", "heavy_up",
  "ranged_down", "parry_down", "grapple_down", "grapple_up", "interact_down",
  "potion_down", "marker_down",
  "backdash_down", "ground_pound_down", "morph_toggle_down",
}

local edge_sources = {}
for _, field in ipairs(EDGE_FIELDS) do
  edge_sources[field] = { keyboard = false, gamepads = {} }
end

local controllers = {}
local active_gamepad = nil
local UI_BLOCK = false
local CFG = nil

local function reset_frame_flags(state)
  for field, source in pairs(edge_sources) do
    source.keyboard = false
    source.gamepads = {}
    state[field] = false
  end
end

local function clear_axis_sources()
  local digital = sources.digital
  digital.left, digital.right, digital.up, digital.down = {}, {}, {}, {}
  local stick = sources.left_stick
  stick.left, stick.right, stick.up, stick.down = 0, 0, 0, 0
  sources.camera.up, sources.camera.down = 0, 0
end

local function direction_active(direction_sources)
  return next(direction_sources) ~= nil
end

local function signed_axis(negative_digital, positive_digital, negative_analog, positive_analog)
  local digital = (positive_digital and 1 or 0) - (negative_digital and 1 or 0)
  local analog = (positive_analog or 0) - (negative_analog or 0)
  if math.abs(digital) >= math.abs(analog) then return digital end
  return analog
end

local function refresh_axes()
  local state = M.input_state
  local digital = sources.digital
  local stick = sources.left_stick
  state.move_x = signed_axis(
    direction_active(digital.left),
    direction_active(digital.right),
    stick.left,
    stick.right
  )
  state.move_y = signed_axis(
    direction_active(digital.down),
    direction_active(digital.up),
    stick.down,
    stick.up
  )
  state.camera_y = (sources.camera.up or 0) - (sources.camera.down or 0)
  state.left_mag = math.min(1, math.sqrt(state.move_x * state.move_x + state.move_y * state.move_y))
end

local function action_magnitude(action)
  if action.released then return 0 end
  local value = math.abs(tonumber(action.value) or 0)
  if value == 0 and action.pressed then value = 1 end
  return math.min(1, value)
end

local function copy_table(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = item end
  return out
end

local function controller_is_selectable(record)
  return record ~= nil and record.unknown ~= true
end

local function remember_controller(action)
  local index = tonumber(action and action.gamepad)
  if index == nil then return nil end
  local existing = controllers[index] or { index = index }
  if action.gamepad_name ~= nil then existing.name = action.gamepad_name end
  if action.gamepad_guid ~= nil then existing.guid = action.gamepad_guid end
  if action.gamepad_guid_info ~= nil then
    existing.guid_info = copy_table(action.gamepad_guid_info)
  end
  if action.userid ~= nil then existing.userid = action.userid end
  if action.gamepad_unknown ~= nil then
    existing.unknown = action.gamepad_unknown and true or false
  end
  controllers[index] = existing
  if active_gamepad == nil and controller_is_selectable(existing) then
    active_gamepad = index
  end
  return index
end

local function first_connected_gamepad()
  local first = nil
  for index, record in pairs(controllers) do
    if controller_is_selectable(record) and (first == nil or index < first) then
      first = index
    end
  end
  return first
end

local function refresh_held_state(field)
  local source = held_sources[field]
  local held = next(source.keyboard) ~= nil
  if not held then
    for _, inputs in pairs(source.gamepads) do
      if next(inputs) ~= nil then
        held = true
        break
      end
    end
  end
  M.input_state[field] = held and true or false
end

local function set_held_state(field, action_id, action, held)
  local source = held_sources[field]
  local index = tonumber(action and action.gamepad)
  if index == nil then
    source.keyboard[action_id] = held and true or nil
  else
    local inputs = source.gamepads[index]
    if held then
      inputs = inputs or {}
      inputs[action_id] = true
      source.gamepads[index] = inputs
    elseif inputs then
      inputs[action_id] = nil
      if next(inputs) == nil then source.gamepads[index] = nil end
    end
  end
  refresh_held_state(field)
end

local function clear_held_state(include_keyboard)
  for field, source in pairs(held_sources) do
    if include_keyboard then source.keyboard = {} end
    source.gamepads = {}
    refresh_held_state(field)
  end
end

local function refresh_edge_state(field)
  local source = edge_sources[field]
  local active = source.keyboard
  if not active then
    for _, gamepad_edge in pairs(source.gamepads) do
      if gamepad_edge then
        active = true
        break
      end
    end
  end
  M.input_state[field] = active and true or false
end

local function set_edge_state(field, action)
  local source = edge_sources[field]
  local index = tonumber(action and action.gamepad)
  if index == nil then
    source.keyboard = true
  else
    source.gamepads[index] = true
  end
  M.input_state[field] = true
end

local function clear_edge_state(include_keyboard)
  for field, source in pairs(edge_sources) do
    if include_keyboard then source.keyboard = false end
    source.gamepads = {}
    refresh_edge_state(field)
  end
end

local function clear_gamepad_state()
  local stick = sources.left_stick
  stick.left, stick.right, stick.up, stick.down = 0, 0, 0, 0
  sources.camera.up, sources.camera.down = 0, 0
  clear_held_state(false)
  clear_edge_state(false)
  refresh_axes()
end

local function handle_gamepad_lifecycle(action_id, action)
  if action_id == C.INPUT.GAMEPAD_CONNECTED then
    local index = remember_controller(action)
    if index ~= nil then
      local record = controllers[index]
      input_log(string.format(
        "[INPUT] gamepad %d connected: %s%s",
        index,
        tostring(record.name or record.guid or "unknown controller"),
        record.unknown and " (unmapped)" or ""
      ))
    end
    return true
  end

  if action_id == C.INPUT.GAMEPAD_DISCONNECTED then
    local index = tonumber(action and action.gamepad)
    if index ~= nil then
      controllers[index] = nil
      if active_gamepad == index then
        clear_gamepad_state()
        active_gamepad = first_connected_gamepad()
      end
      input_log(string.format("[INPUT] gamepad %d disconnected", index))
    end
    return true
  end

  return false
end

function M.accepts_gamepad(action)
  local index = tonumber(action and action.gamepad)
  if index == nil then return true end
  remember_controller(action)
  return index == active_gamepad
end

function M.get_active_gamepad()
  return active_gamepad
end

function M.set_active_gamepad(index)
  if index == nil then
    clear_gamepad_state()
    active_gamepad = nil
    return true
  end
  index = tonumber(index)
  if index == nil or not controller_is_selectable(controllers[index]) then return false end
  if active_gamepad ~= index then clear_gamepad_state() end
  active_gamepad = index
  return true
end

function M.get_connected_gamepads()
  local out = {}
  for index, record in pairs(controllers) do
    out[#out + 1] = {
      index = index,
      name = record.name,
      guid = record.guid,
      guid_info = copy_table(record.guid_info),
      userid = record.userid,
      unknown = record.unknown and true or false,
      active = index == active_gamepad,
    }
  end
  table.sort(out, function(a, b) return a.index < b.index end)
  return out
end

function M.reset_controllers()
  controllers = {}
  active_gamepad = nil
  clear_gamepad_state()
end

function M.clear_all()
  local state = M.input_state
  clear_axis_sources()
  reset_frame_flags(state)
  clear_held_state(true)
  state.move_x, state.move_y, state.left_mag = 0, 0, 0
  state.camera_y = 0
end

function M.set_blocked(blocked)
  local next_state = blocked and true or false
  if UI_BLOCK ~= next_state and debug_enabled() then
    input_log(string.format("[INPUT] set_blocked -> %s", tostring(next_state)))
  end
  UI_BLOCK = next_state
  if UI_BLOCK then M.clear_all() end
end

function M.get_blocked()
  return UI_BLOCK
end

function M.set_config(config)
  CFG = config
end

function M.begin_frame()
  reset_frame_flags(M.input_state)
end

local function set_digital_direction(action_id, action)
  local digital = sources.digital
  local name = KEYBOARD_DIRECTIONS[action_id]
  if not name then return false end
  if action.pressed then digital[name][action_id] = true end
  if action.released then digital[name][action_id] = nil end
  refresh_axes()
  return true
end

local function set_left_stick_direction(action_id, action)
  local stick = sources.left_stick
  local name = nil
  if action_id == C.INPUT.GAMEPAD_LSTICK_LEFT then name = "left"
  elseif action_id == C.INPUT.GAMEPAD_LSTICK_RIGHT then name = "right"
  elseif action_id == C.INPUT.GAMEPAD_LSTICK_UP then name = "up"
  elseif action_id == C.INPUT.GAMEPAD_LSTICK_DOWN then name = "down"
  end
  if not name then return false end
  stick[name] = action_magnitude(action)
  refresh_axes()
  return true
end

function M.on_input(action_id, action)
  action = action or {}

  -- Lifecycle events must be processed even while a UI blocks gameplay.
  if handle_gamepad_lifecycle(action_id, action) then return false end
  if not M.accepts_gamepad(action) then return false end

  -- Pause and settings remain available while another UI owns gameplay input.
  if action.pressed then
    if Bindings.is("PAUSE_TOGGLE", action_id) then
      pcall(msg.post, msg.url("main:/pause_gui#pause"), hash("toggle_pause"), {})
      return false
    end
    if Bindings.is("SETTINGS_TOGGLE", action_id) then
      pcall(msg.post, msg.url("main:/ui#settings"), hash("toggle_settings"), {})
      return false
    end
  end

  if M.get_blocked() then return false end

  if action.pressed and debug_enabled() then
    local labels = {}
    if KEYBOARD_DIRECTIONS[action_id] == "up" or action_id == C.INPUT.GAMEPAD_LSTICK_UP then labels[#labels + 1] = "UP" end
    if Bindings.is("JUMP", action_id) then labels[#labels + 1] = "JUMP" end
    if Bindings.is("SLIDE", action_id) then labels[#labels + 1] = "SLIDE" end
    if Bindings.is("LIGHT_MELEE", action_id) then labels[#labels + 1] = "LIGHT_MELEE" end
    if Bindings.is("HEAVY_MELEE", action_id) then labels[#labels + 1] = "HEAVY_MELEE" end
    if Bindings.is("RANGED", action_id) then labels[#labels + 1] = "RANGED" end
    if Bindings.is("PARRY", action_id) then labels[#labels + 1] = "PARRY" end
    if Bindings.is("GRAPPLE", action_id) then labels[#labels + 1] = "GRAPPLE" end
    if Bindings.is("INTERACT", action_id) then labels[#labels + 1] = "INTERACT" end
    if Bindings.is("POTION", action_id) then labels[#labels + 1] = "POTION" end
    if Bindings.is("MAP_MARKER", action_id) then labels[#labels + 1] = "MAP_MARKER" end
    if Bindings.is("BACKDASH", action_id) then labels[#labels + 1] = "BACKDASH" end
    if Bindings.is("GROUND_POUND", action_id) then labels[#labels + 1] = "GROUND_POUND" end
    if Bindings.is("MORPH_TOGGLE", action_id) then labels[#labels + 1] = "MORPH_TOGGLE" end
    if Bindings.is("MINIMAP_TOGGLE", action_id) then labels[#labels + 1] = "MINIMAP_TOGGLE" end
    if Bindings.is("WORLD_MAP_TOGGLE", action_id) then labels[#labels + 1] = "WORLD_MAP_TOGGLE" end
    if Bindings.is("INVENTORY_TOGGLE", action_id) then labels[#labels + 1] = "INVENTORY_TOGGLE" end
    if #labels > 0 then
      input_log(string.format("[INPUT] pressed id=%s -> %s", tostring(action_id), table.concat(labels, ",")))
    end
  end

  set_digital_direction(action_id, action)
  set_left_stick_direction(action_id, action)

  if Bindings.is("JUMP", action_id) then
    if action.pressed then
      set_edge_state("jump_down", action); set_held_state("jump_held", action_id, action, true)
      TutorialPopups.on_event("first_jump")
    end
    if action.released then set_edge_state("jump_up", action); set_held_state("jump_held", action_id, action, false) end
  end

  if Bindings.is("SLIDE", action_id) then
    if action.pressed then
      set_edge_state("slide_down", action); set_held_state("slide_held", action_id, action, true)
      TutorialPopups.on_event("first_dash")
    end
    if action.released then set_edge_state("slide_up", action); set_held_state("slide_held", action_id, action, false) end
  end

  if Bindings.is("INTERACT", action_id) then
    if action.pressed then set_edge_state("interact_down", action); set_held_state("interact_held", action_id, action, true) end
    if action.released then set_held_state("interact_held", action_id, action, false) end
  end

  if Bindings.is("GRAPPLE", action_id) then
    if action.pressed then set_edge_state("grapple_down", action); set_held_state("grapple_held", action_id, action, true) end
    if action.released then set_edge_state("grapple_up", action); set_held_state("grapple_held", action_id, action, false) end
  end

  if action.pressed then
    if Bindings.is("LIGHT_MELEE", action_id) then set_edge_state("light_down", action); set_held_state("light_held", action_id, action, true) end
    if Bindings.is("HEAVY_MELEE", action_id) then set_edge_state("heavy_down", action); set_held_state("heavy_held", action_id, action, true) end
    if Bindings.is("RANGED", action_id) then set_edge_state("ranged_down", action) end
    if Bindings.is("PARRY", action_id) then set_edge_state("parry_down", action) end
    if Bindings.is("POTION", action_id) then set_edge_state("potion_down", action) end
    if Bindings.is("MAP_MARKER", action_id) then set_edge_state("marker_down", action) end
    if Bindings.is("BACKDASH", action_id) then set_edge_state("backdash_down", action) end
    if Bindings.is("GROUND_POUND", action_id) then set_edge_state("ground_pound_down", action) end
    if Bindings.is("MORPH_TOGGLE", action_id) then set_edge_state("morph_toggle_down", action) end
    if Bindings.is("MINIMAP_TOGGLE", action_id) then
      pcall(msg.post, msg.url("main:/main_go#script"), hash("cycle_map"), {})
    end
    if Bindings.is("WORLD_MAP_TOGGLE", action_id) then
      TutorialPopups.on_event("opened_map")
      pcall(msg.post, msg.url("main:/world_map_gui#world_map"), hash("toggle_world_map"), {})
    end
    if Bindings.is("INVENTORY_TOGGLE", action_id) then
      pcall(msg.post, msg.url("main:/inventory_gui#inventory"), hash("open_inventory"), {})
    end
  end

  if action.released then
    if Bindings.is("LIGHT_MELEE", action_id) then set_edge_state("light_up", action); set_held_state("light_held", action_id, action, false) end
    if Bindings.is("HEAVY_MELEE", action_id) then set_edge_state("heavy_up", action); set_held_state("heavy_held", action_id, action, false) end
  end

  if Bindings.is("CAMERA_UP", action_id) then
    sources.camera.up = action_magnitude(action)
    refresh_axes()
  elseif Bindings.is("CAMERA_DOWN", action_id) then
    sources.camera.down = action_magnitude(action)
    refresh_axes()
  end

  return true
end

function M.end_frame(_dt)
  local state = M.input_state
  refresh_axes()
  local debug_movement = (CFG and CFG.debug_movement) or PS.debug_movement
  if debug_movement and state.slide_held then
    input_log(string.format("[INPUT] slide_held=%s, move_x=%.3f",
      tostring(state.slide_held), state.move_x))
  end
  return state
end

function M.get_state()
  return M.input_state
end

return M

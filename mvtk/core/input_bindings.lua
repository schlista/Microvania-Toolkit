-- mvtk/core/input_bindings.lua
-- Current-only high-level input bindings for Defold 1.13.2+.

local Util = require "mvtk.core.util"
local DEFAULTS = Util.require_config("developer.config.default_bindings")
local SavePaths = require "mvtk.core.save_paths"

local M = {}

local SAVE_FILE = "mvtk_bindings_v2"
local SAVE_VERSION = 2

M.SAVE_FILE = SAVE_FILE
M.SAVE_VERSION = SAVE_VERSION

-- Digital controller actions offered by the in-game remapping UI. Analog
-- stick directions are intentionally excluded from button remapping.
local CONTROLLER_INPUTS = {
  gamepad_lpad_left = true,
  gamepad_lpad_right = true,
  gamepad_lpad_up = true,
  gamepad_lpad_down = true,
  gamepad_rpad_left = true,
  gamepad_rpad_right = true,
  gamepad_rpad_up = true,
  gamepad_rpad_down = true,
  gamepad_lshoulder = true,
  gamepad_rshoulder = true,
  gamepad_ltrigger = true,
  gamepad_rtrigger = true,
  gamepad_lstick_click = true,
  gamepad_rstick_click = true,
  gamepad_start = true,
  gamepad_back = true,
  gamepad_guide = true,
}

M.CONTROLLER_INPUTS = CONTROLLER_INPUTS

-- Every persisted input must exist in the current input binding asset. Adding
-- a new low-level action is an explicit schema change in the creator-owned
-- default_bindings config and binding asset.
local CURRENT_INPUTS = {}
for _, input_name in ipairs(DEFAULTS.inputs or {}) do
  if type(input_name) == "string" and input_name ~= "" then
    CURRENT_INPUTS[input_name] = true
  end
end

M.CURRENT_INPUTS = CURRENT_INPUTS

local map = {}
local map_hash = {}

local function current_action_name(action_name)
  if type(action_name) ~= "string" or (DEFAULTS.actions or {})[action_name] == nil then
    return nil
  end
  return action_name
end

local function normalize_list(value)
  if type(value) ~= "table" then return nil end
  local out = {}
  local seen = {}
  for index = 1, #value do
    local input_name = value[index]
    if type(input_name) ~= "string"
      or input_name == ""
      or not CURRENT_INPUTS[input_name]
    then
      return nil
    end
    if not seen[input_name] then
      seen[input_name] = true
      out[#out + 1] = input_name
    end
  end
  return out
end

local function current_config(saved_bindings)
  local defaults = DEFAULTS.actions or {}
  local config = {}
  local saved_actions = {}
  for action_name, default_list in pairs(defaults) do
    local saved_list = saved_bindings and normalize_list(saved_bindings[action_name])
    config[action_name] = saved_list or normalize_list(default_list) or {}
    if saved_list then saved_actions[action_name] = true end
  end
  return config, saved_actions
end

local function build_maps(source, preferred_actions)
  map, map_hash = {}, {}
  for action_name, value in pairs(source or {}) do
    local action = tostring(action_name)
    local list = normalize_list(value) or {}
    map[action] = {}
    map_hash[action] = {}
    for _, input_name in ipairs(list) do
      map[action][input_name] = true
      map_hash[action][hash(input_name)] = true
    end
  end

  -- A physical controller button has one semantic owner. This also repairs a
  -- malformed current-version payload deterministically on load.
  local action_names = {}
  for action_name in pairs(map) do action_names[#action_names + 1] = action_name end
  table.sort(action_names, function(a, b)
    local a_preferred = preferred_actions and preferred_actions[a] or false
    local b_preferred = preferred_actions and preferred_actions[b] or false
    if a_preferred ~= b_preferred then return a_preferred end
    return a < b
  end)
  local owners = {}
  for _, action_name in ipairs(action_names) do
    for input_name in pairs(map[action_name]) do
      if CONTROLLER_INPUTS[input_name] then
        if owners[input_name] then
          map[action_name][input_name] = nil
          map_hash[action_name][hash(input_name)] = nil
        else
          owners[input_name] = action_name
        end
      end
    end
  end
end

local function remove_controller_owner(input_name, keep_action)
  if not CONTROLLER_INPUTS[input_name] then return end
  for action_name, inputs in pairs(map) do
    if action_name ~= keep_action and inputs[input_name] then
      inputs[input_name] = nil
      map_hash[action_name][hash(input_name)] = nil
    end
  end
end

local function save_path()
  return SavePaths.path(SAVE_FILE)
end

function M.load()
  local ok_path, path = pcall(save_path)
  local ok_load, payload = false, nil
  if ok_path then
    ok_load, payload = pcall(sys.load, path)
  end

  local saved_bindings = nil
  if ok_load
    and type(payload) == "table"
    and payload.version == SAVE_VERSION
    and type(payload.bindings) == "table"
  then
    saved_bindings = payload.bindings
  end

  local config, saved_actions = current_config(saved_bindings)
  build_maps(config, saved_actions)
end

function M.save()
  local bindings = {}
  for action_name, set in pairs(map) do
    local list = {}
    for input_name, enabled in pairs(set) do
      if enabled then list[#list + 1] = input_name end
    end
    table.sort(list)
    bindings[action_name] = list
  end

  local ok_path, path = pcall(save_path)
  if not ok_path then return false end
  local readable, previous = pcall(sys.load, path)
  if not readable or type(previous) ~= "table" then return false end
  if next(previous) and previous.version ~= SAVE_VERSION then return false end
  local ok_save, result = pcall(sys.save, path, {
    version = SAVE_VERSION,
    bindings = bindings,
  })
  return ok_save and result ~= false
end

function M.bind(action_name, input_names)
  local action = current_action_name(action_name)
  if not action then return false end
  local raw_list = type(input_names) == "table" and input_names or { input_names }
  local list = normalize_list(raw_list)
  if not list then return false end
  for _, input_name in ipairs(list) do
    remove_controller_owner(input_name, action)
  end
  map[action], map_hash[action] = {}, {}
  for _, input_name in ipairs(list) do
    map[action][input_name] = true
    map_hash[action][hash(input_name)] = true
  end
  return true
end

function M.add(action_name, input_name)
  if type(input_name) ~= "string"
    or input_name == ""
    or not CURRENT_INPUTS[input_name]
  then
    return false
  end
  local action = current_action_name(action_name)
  if not action then return false end
  remove_controller_owner(input_name, action)
  map[action] = map[action] or {}
  map_hash[action] = map_hash[action] or {}
  map[action][input_name] = true
  map_hash[action][hash(input_name)] = true
  return true
end

function M.remove(action_name, input_name)
  local action = current_action_name(action_name)
  if not action then return false end
  local name = tostring(input_name)
  if map[action] then map[action][name] = nil end
  if map_hash[action] then map_hash[action][hash(name)] = nil end
  return true
end

function M.is(action_name, action_id)
  local action = current_action_name(action_name)
  local set = action and map_hash[action]
  return set and set[action_id] and true or false
end

function M.get(action_name)
  local out = {}
  local action = current_action_name(action_name)
  local set = action and map[action]
  if set then
    for input_name, enabled in pairs(set) do
      if enabled then out[#out + 1] = input_name end
    end
  end
  table.sort(out)
  return out
end

function M.get_controller_binding(action_name)
  for _, input_name in ipairs(M.get(action_name)) do
    if CONTROLLER_INPUTS[input_name] then return input_name end
  end
  return nil
end

function M.set_controller_binding(action_name, input_name)
  if input_name ~= nil and not CONTROLLER_INPUTS[input_name] then return false end
  local action = current_action_name(action_name)
  if not action then return false end
  map[action] = map[action] or {}
  map_hash[action] = map_hash[action] or {}
  for existing in pairs(map[action]) do
    if CONTROLLER_INPUTS[existing] then
      map[action][existing] = nil
      map_hash[action][hash(existing)] = nil
    end
  end
  if input_name then
    remove_controller_owner(input_name, action)
    map[action][input_name] = true
    map_hash[action][hash(input_name)] = true
  end
  return true
end

function M.reset()
  build_maps(current_config(nil))
  return M.save()
end

function M.refresh_from_defaults(action_name)
  local action = current_action_name(action_name)
  if not action then return false end
  local default_bindings = (DEFAULTS.actions or {})[action]
  if default_bindings then return M.bind(action, default_bindings) end
  return false
end

M.load()

return M

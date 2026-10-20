-- mvtk/core/constants.lua
local SafeRequire = require "mvtk.core.safe_require"

return (function()
  -- moved from modules/core/constants.lua
  local M = {}

  local function to_url(path)
    if not path then return nil end
    local ok, url = pcall(msg.url, path)
    return ok and url or path
  end

  -- Optional project-level overrides live in developer/config/url_map.lua.
  -- Use quiet() because the override file is intentionally optional --
  -- end users only create it when they need URL remapping.
  local function load_overrides()
    local ok, overrides = SafeRequire.quiet("developer.config.url_map", "mvtk.core.constants")
    if ok and type(overrides) == "table" then
      return overrides
    end
    return {}
  end

  local function merge_url_overrides(target, overrides)
    for key, value in pairs(overrides or {}) do
      if type(value) == "table" and type(target[key]) == "table" then
        merge_url_overrides(target[key], value)
      else
        target[key] = to_url(value)
      end
    end
  end

  local function get_nested_url(root, key)
    local node = root
    for token in string.gmatch(tostring(key or ""), "[^%.]+") do
      if type(node) ~= "table" then return nil end
      node = node[token]
    end
    return node
  end

  local function set_nested_url(root, key, value)
    local parts = {}
    for token in string.gmatch(tostring(key or ""), "[^%.]+") do
      parts[#parts + 1] = token
    end
    if #parts == 0 then return end
    local node = root
    for i = 1, #parts - 1 do
      local part = parts[i]
      if type(node[part]) ~= "table" then
        node[part] = {}
      end
      node = node[part]
    end
    node[parts[#parts]] = to_url(value)
  end

  local ATTACK_FACTORIES_COLLECTION = "main:/attack" .. "_factories"

  local DEFAULT_URLS = {
    CAMERA           = nil,
    FADE_GUI         = nil,
    ROOM_MANAGER     = nil,  -- set by room_manager.script on init
    AUDIO            = nil,  -- set by audio_controller.script on init
    PARALLAX         = nil,  -- set by parallax_controller.script on init
    FX               = nil,  -- set by FX manager on init; override via developer/config/url_map.lua
    OVERLAY          = nil,  -- set by overlay/HUD manager on init; override via developer/config/url_map.lua
    DIALOGUE_MANAGER = to_url("main:/dialogue_manager#dialogue"),
    DIALOGUE_GUI     = to_url("main:/dialogue_gui#dialogue"),
    CUTSCENE_MANAGER = to_url("main:/cutscene_manager#cutscene"),
    MODE_HUD         = to_url("main:/mode_hud#mode_hud"),
    PLAYER           = to_url("main:/collection2/player#player"),
    -- Factories live in main.collection by default. Override here or in developer/config/url_map.lua if your project nests them differently.
    FACTORY          = {
      melee            = to_url(ATTACK_FACTORIES_COLLECTION .. "#melee_factory"),
      melee_circle     = to_url(ATTACK_FACTORIES_COLLECTION .. "#melee_circle_factory"),
      projectile       = to_url(ATTACK_FACTORIES_COLLECTION .. "#projectile_factory"),
      enemy_projectile = to_url(ATTACK_FACTORIES_COLLECTION .. "#enemy_projectile_factory"),
    },
  }

  -- Apply optional overrides from developer/config/url_map.lua
  merge_url_overrides(DEFAULT_URLS, load_overrides())

  -- URL table that falls back to defaults when unset
  M.URL = setmetatable({}, {
    __index = function(_, key)
      return DEFAULT_URLS[key]
    end
  })

  function M.set_url(key, value)
    if not key then return end
    if type(key) == "string" and key:find(".", 1, true) then
      set_nested_url(M.URL, key, value)
      return
    end
    M.URL[key] = to_url(value)
  end

  function M.url(key)
    if type(key) == "string" and key:find(".", 1, true) then
      return get_nested_url(M.URL, key)
    end
    return M.URL[key]
  end

  M.GROUPS = {
    PLAYER = hash("player"),
    WORLD  = hash("world"),
    PUSHABLE = hash("pushable"),
    SENSOR = hash("sensor"),
    ENEMY  = hash("enemy"),
    ATTACK = hash("attack"),
  }

  M.MSG = {
    ROOM_LOAD        = hash("mvtk_room_load"),
    ROOM_WILL_UNLOAD = hash("mvtk_room_will_unload"),
    ROOM_DID_LOAD    = hash("mvtk_room_did_load"),
    ROOM_CLEAN       = hash("mvtk_room_clean"),

    TRANSITION_GO    = hash("mvtk_transition_go"),
    FADE_TO_BLACK    = hash("mvtk_fade_to_black"),
    FADE_FROM_BLACK  = hash("mvtk_fade_from_black"),

    CHECKPOINT       = hash("mvtk_checkpoint"),
    RESET_MOTION     = hash("mvtk_reset_motion"),
    REQUEST_RESPAWN  = hash("mvtk_request_respawn"),
    PLAYER_DIED      = hash("mvtk_player_died"),
    GRANT_ABILITY    = hash("mvtk_grant_ability"),
    RESTORE_HEALTH   = hash("mvtk_restore_health"),

    SET_POSITION     = hash("mvtk_set_position"),
    ROLL_STATE       = hash("mvtk_roll_state"),
    HUD_CURRENCY     = hash("hud_currency"),
    TOAST            = hash("toast"),
    TAKE_DAMAGE      = hash("take_damage"),
    KILLED           = hash("killed"),
    ENEMY_KILLED     = hash("enemy_killed"),
    FAST_TRAVEL_UNLOCKED = hash("fast_travel_unlocked"),
    START_DIALOGUE   = hash("start_dialogue"),
    SET_VOLUME       = hash("set_volume"),
    PLAY_SOUND       = hash("play_sound"),
    STOP_SOUND       = hash("stop_sound"),
  }

  -- Pre-cached input hashes (used every frame in input_controller)
  M.INPUT = {
    GAMEPAD_CONNECTED       = hash("gamepad_connected"),
    GAMEPAD_DISCONNECTED    = hash("gamepad_disconnected"),
    GAMEPAD_LSTICK_LEFT     = hash("gamepad_lstick_left"),
    GAMEPAD_LSTICK_RIGHT    = hash("gamepad_lstick_right"),
    GAMEPAD_LSTICK_UP       = hash("gamepad_lstick_up"),
    GAMEPAD_LSTICK_DOWN     = hash("gamepad_lstick_down"),
  }

  -- Pre-cached audio group hashes
  M.AUDIO_GROUP = {
    MASTER = hash("master"),
    MUSIC  = hash("music"),
    SFX    = hash("sfx"),
    AMBIENT = hash("ambient"),
  }

  return M
end)()

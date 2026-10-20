-- mvtk/core/config_schemas.lua
-- Validation schemas for all config files
-- Defines required fields, types, and validation rules

local SafeRequire = require "mvtk.core.safe_require"
local PlayerScale = require "mvtk.player.player_scale"
local Number = require "mvtk.editor.settings_number"

local M = {}
M.game_completion={
    name="Game Completion",file="config/game_completion.lua",allow_unknown=true,
    required={enabled={type="boolean"},id={type="string"},condition={type="string"},
        continue_policy={type="string"},title={type="string"},body={type="string"},credits={type="string"}},
    custom_validate=function(config)
        local errors={}
        if config.condition~="region" and config.condition~="flag" and config.condition~="boss" then errors[#errors+1]="Ending condition must be region, flag, or boss" end
        if config.continue_policy~="explore" and config.continue_policy~="completed" then errors[#errors+1]="Ending Continue policy must be explore or completed" end
        if type(config.id)~="string" or not config.id:match("^[%w_%-]+$") then errors[#errors+1]="Ending ID needs letters, digits, underscores or hyphens" end
        if config.enabled and config.condition=="flag" and config.flag=="" then errors[#errors+1]="Flag ending requires a flag" end
        if config.enabled and config.condition=="boss" and config.boss_id=="" then errors[#errors+1]="Boss ending requires a boss ID" end
        for _,key in ipairs({"return_x","return_y"}) do
            local n=config[key]; if type(n)~="number" or n~=n or n==math.huge or n==-math.huge then errors[#errors+1]=key.." must be finite" end
        end
        for _,key in ipairs({"flag","boss_id","return_room","music","artwork","reward_flag","font"}) do
            if type(config[key])~="string" then errors[#errors+1]=key.." must be a string" end
        end
        if type(config.credits_per_page)~="number" or config.credits_per_page<1 or config.credits_per_page>8 or config.credits_per_page%1~=0 then errors[#errors+1]="credits_per_page must be an integer from 1 to 8" end
        if type(config.text_scale)~="number" or config.text_scale<=0 or config.text_scale>1 then errors[#errors+1]="text_scale must be above zero and at most 1" end
        return errors,{}
    end,
}

M.persistence_settings = {
  name = "Persistence Settings", file = "config/persistence_settings.lua", allow_unknown = true,
  required = {game_id={type="string"}},
  custom_validate = function(config)
    if type(config.game_id)=="string" and (config.game_id=="" or config.game_id:match("^[%w_.-]+$")) then return {},{} end
    return {"game_id must contain only letters, digits, _, . or -"},{}
  end,
}

M.save_migrations = {
  name = "Save Migrations", file = "config/save_migrations.lua", allow_unknown = true,
  required = {version={type="number"},identifier_aliases={type="table"}},
  custom_validate = function(config)
    if config.version~=1 then return {"Unsupported save migration settings version"},{} end
    local ok,err=pcall(require("mvtk.core.save_migrations").validate_aliases,config.identifier_aliases)
    return ok and {} or {tostring(err)},{}
  end,
}

M.creator_settings = {
  name = "Creator Settings",
  file = "config/creator_settings.lua",
  allow_unknown = true,
  required = {
    version = { type = "number" },
    overrides = { type = "table" },
  },
  optional = { published = { type = "boolean" }, player_units = { type = "number", values = {1, 2} } },
  custom_validate = function(config)
    local ok, err = pcall(require("mvtk.core.creator_settings_model").validate, config)
    return ok and {} or { tostring(err) }, {}
  end,
}

-- Game Settings baselines use the same field contract as their editor tabs.
for _,section in ipairs({"player_art","movement_test"}) do
  local section_name=section
  M[section_name]={name=section_name,file="config/"..section_name..".lua",allow_unknown=true,
    custom_validate=function(config)
      local Model=require "mvtk.core.creator_settings_model"
      local values={}
      for key,spec in pairs(Model.fields) do
        if spec.path:sub(1,#section_name+1)==section_name.."." then
          values[key]=Model.get({[section_name]=config},spec.path)
          if values[key]==nil then return {"Missing "..spec.path},{} end
        end
      end
      local ok,err=pcall(Model.from_controls,values)
      return ok and {} or {tostring(err)},{}
    end}
end

-- Helper to check if a value is a valid file path
local function is_valid_path(path)
  if type(path) ~= "string" then return false end
  -- Check if file exists (basic check)
  return path:match("^/") or path:match("^[a-zA-Z]:") -- Starts with / or drive letter
end

-- Helper to check if value is a number in range
local function in_range(min, max)
  return function(value)
    return type(value) == "number" and value >= min and value <= max
  end
end

-- Helper to check if value is one of allowed values
local function one_of(...)
  local allowed = {...}
  return function(value)
    for _, v in ipairs(allowed) do
      if value == v then return true end
    end
    return false
  end
end

-----------------------------------------------------------
-- PLAYER SETTINGS SCHEMA
-----------------------------------------------------------
M.player_settings = {
  name = "Player Settings",
  file = "config/player_settings.lua",
  -- Player settings carries many ability/tuning sub-tables (slide, air_dash,
  -- wall_climb, glide, jump curve tuning, etc.). The required/optional lists
  -- below cover the load-bearing fields; everything else is intentional.
  allow_unknown = true,
  required = {
    -- Movement
    walk_speed = { type = "number", range = {100, 8750}, description = "Player walking speed (pixels/second)" },
    run_speed = { type = "number", range = {200, 8750}, description = "Player running speed (pixels/second)" },
    accel = { type = "number", range = {1, 100}, description = "Acceleration rate" },
    decel = { type = "number", range = {1, 100}, description = "Deceleration rate" },

    -- Jumping
    gravity = { type = "number", range = {-8750, 0}, description = "Gravity force (negative number)" },
    jump_height = { type = "number", range = {50, 1750}, description = "Base jump height (pixels)" },
    coyote_time = { type = "number", range = {0, 1.0}, description = "Coyote time (seconds)" },
    jump_buffer = { type = "number", range = {0, 1.0}, description = "Jump buffer time (seconds)" },

    -- Stats
    max_health = { type = "number", range = {1, 100}, description = "Maximum health" },
    max_energy = { type = "number", range = {0, 100}, description = "Maximum energy" },
    max_stamina = { type = "number", range = {0, 1000}, description = "Maximum stamina" },
  },
  optional = {
    units_version = { type = "number", values = {1, 2}, description = "Pixel-unit generation; absent means old units (1)" },
    player_scale = { type = "number", range = {PlayerScale.MIN_SCALE, PlayerScale.MAX_SCALE}, description = "Uniform player body and pixel-value scale" },
    scale_movement = { type = "boolean", description = "Scale movement pixel values with player_scale" },
    walk_speed_mode = { type = "string", values = {"scaled", "constant"} },
    run_mode = { type = "string", values = {"hold_button", "toggle"} },
    run_threshold = { type = "number", range = {0, 1.0} },
    walk_stop_deadzone = { type = "number", range = {0, 1.0}, description = "Neutral movement threshold used to clear the run gate" },
    extended_jump_height = { type = "number", range = {0, 875} },
    air_jumps = { type = "number", range = {0, 10} },
    collider_half_height = { type = "number", range = {10, 350} },
    collider_half_width = { type = "number", range = {10, 350} },
    head_margin = { type = "number", range = {0, 350}, description = "Extra head clearance in base pixels" },
    collision_response = { type = "table" },
    spine_physics = { type = "table", fields = {
      bone_map = { type = "table", fields = {
        body = { type = "string" },
        foot_l = { type = "string" },
        foot_r = { type = "string" },
        head = { type = "string" },
      }},
    }},
    wall_climb = { type = "table", fields = {
      contact_grace = { type = "number", range = {0, 1.0} },
      ledge_climb = { type = "table", fields = {
        enabled = { type = "boolean" },
        climb_x = { type = "number", range = {0, 1750} },
        climb_y = { type = "number", range = {0, 1750} },
        up_threshold = { type = "number", range = {0, 1.0} },
        climb_time = { type = "number", range = {0.05, 5.0} },
        hang_enabled = { type = "boolean" },
      }},
    }},
    block_grab = { type = "table", fields = {
      enabled = { type = "boolean" },
      pull_speed = { type = "number", range = {0, 8750} },
      release_grace = { type = "number", range = {0, 1.0} },
    }},
  }
}

-----------------------------------------------------------
-- PLAYER ACTIONS SCHEMA
-----------------------------------------------------------
M.player_actions = {
  name = "Player Actions",
  file = "config/player_actions.lua",
  -- Action tuning lives in many optional sub-tables (parry, interact, potion,
  -- grapple, contact attacks, etc.). Validate the load-bearing actions and
  -- allow extra ones without warning.
  allow_unknown = true,
  required = {
    melee_light = { type = "table", fields = {
      damage = { type = "number", range = {0, 100} },
      cooldown = { type = "number", range = {0, 5.0} },
      active = { type = "number", range = {0, 2.0} },
    }},
    melee_heavy = { type = "table", fields = {
      damage = { type = "number", range = {0, 100} },
      cooldown = { type = "number", range = {0, 5.0} },
      active = { type = "number", range = {0, 2.0} },
    }},
  },
  optional = {
    ranged = { type = "table" },
    down_strike = { type = "table" },
    charge_attack = { type = "table" },
    air_dash = { type = "table" },
    slide = { type = "table" },
    backdash = { type = "table" },
    ground_pound = { type = "table" },
  }
}

-----------------------------------------------------------
-- ENEMY SETTINGS SCHEMA
-----------------------------------------------------------
M.enemy_settings = {
  name = "Enemy Settings",
  file = "config/enemy_settings.lua",
  allow_unknown = true,
  optional = {
    global_difficulty_mult = { type = "number", range = {0.1, 10.0} },
    global_health_mult = { type = "number", range = {0.1, 10.0} },
    global_damage_mult = { type = "number", range = {0.1, 10.0} },
    global_speed_mult = { type = "number", range = {0.1, 10.0} },
  }
}

-----------------------------------------------------------
-- GAMEPLAY CONSTANTS SCHEMA
-----------------------------------------------------------
M.gameplay_constants = {
  name = "Gameplay Constants",
  file = "config/gameplay_constants.lua",
  -- Top-level groups (player, audio, physics, ui, rooms, tiles, combat)
  -- are intentionally open-ended tuning buckets.
  allow_unknown = true,
  optional = {
    TILE_SIZE = { type = "number", range = {8, 128} },
    PIXELS_PER_METER = { type = "number", range = {10, 1000} },
    TARGET_FPS = { type = "number", range = {30, 144} },
  }
}

-----------------------------------------------------------
-- DEFAULT BINDINGS SCHEMA
-----------------------------------------------------------
M.default_bindings = {
  name = "Default Bindings",
  file = "config/default_bindings.lua",
  required = {
    inputs = { type = "table", description = "Allowlist of low-level actions emitted by the input binding asset" },
    actions = { type = "table", description = "Physical keyboard and controller inputs mapped to high-level actions" },
  }
}

-----------------------------------------------------------
-- DEBUG CONFIG SCHEMA
-----------------------------------------------------------
M.debug_config = {
  name = "Debug Config",
  file = "config/debug_config.lua",
  -- Per-subsystem debug toggles (gameplay/rendering/audio/ui/physics/etc.)
  -- are open-ended; only `global` is required.
  allow_unknown = true,
  required = {
    global = { type = "table", fields = {
      enable = { type = "boolean" },
    }},
  },
  optional = {
    gameplay = { type = "table" },
    rendering = { type = "table" },
    audio = { type = "table" },
  }
}

-----------------------------------------------------------
-- ADDITIONAL CRITICAL CONFIGS
-----------------------------------------------------------

M.enemy_types = {
  name = "Enemy Types",
  file = "developer/config/enemy_types.lua",
  entries = {
    required = {
      health = { type = "number", range = {1, 10000}, description = "Base health points" },
      damage = { type = "number", range = {0, 1000}, description = "Base damage dealt" },
      speed = { type = "number", range = {0, 2000}, description = "Movement speed" },
    },
    optional = {
      behavior = { type = "string", description = "AI behavior type" },
      stop_at_ledges = { type = "boolean", description = "Ground movers stop at drops; overrides enemy_defaults" },
      ledge_margin = { type = "number", description = "World pixels from the enemy centre to the edge; overrides enemy_defaults" },
      drops = { type = "table", description = "Loot drop table reference" },
      abilities = { type = "table", description = "Special enemy abilities" },
      spawn_fx = { type = "string", description = "Spawn effect name" },
      death_fx = { type = "string", description = "Death effect name" },
      collision_groups = { type = "table", description = "Physics collision groups" },
      hitbox_width = { type = "number", range = {1, 500}, description = "Hitbox width in pixels" },
      hitbox_height = { type = "number", range = {1, 500}, description = "Hitbox height in pixels" },
    },
    allow_unknown = true, -- allow extra tuning fields
  },
}

M.room_enemies = {
  name = "Room Enemies",
  file = "developer/config/room_enemies.lua",
  entries = {
    required = {
      enemies = { type = "table", description = "Array of enemy spawn configs" },
    },
    optional = {
      difficulty_tier = { type = "number", range = {1, 10}, description = "Room difficulty level" },
      spawn_delay = { type = "number", range = {0, 60}, description = "Delay before spawning (seconds)" },
      max_active = { type = "number", range = {1, 100}, description = "Maximum concurrent enemies" },
    },
    allow_unknown = true,
  },
}

M.tile_settings = {
  name = "Tile Settings",
  file = "developer/config/tile_settings.lua",
  -- Tile authors may add derived helpers (half_width, half_height, size_half).
  allow_unknown = true,
  required = {},
  optional = {
    tile_width = { type = "number", range = {8, 512}, description = "Tile width in pixels" },
    tile_height = { type = "number", range = {8, 512}, description = "Tile height in pixels" },
    width = { type = "number", range = {8, 512}, description = "Alias for tile_width" },
    height = { type = "number", range = {8, 512}, description = "Alias for tile_height" },
    size = { type = "number", range = {8, 512}, description = "Alias for square tile size" },
    tileset_path = { type = "string", description = "Path to tileset image" },
    collision_layer = { type = "string", description = "Default collision layer name" },
    tile_mappings = { type = "table", description = "Tile ID to type mappings" },
  },
  custom_validate = function(cfg)
    local errs, warns = {}, {}
    if type(cfg) ~= "table" then return {"tile_settings: expected table"}, warns end
    local w = cfg.tile_width or cfg.width or cfg.size
    local h = cfg.tile_height or cfg.height or cfg.size
    if not w then table.insert(errs, "tile_settings missing tile_width (set tile_width or width/size)") end
    if not h then table.insert(errs, "tile_settings missing tile_height (set tile_height or height/size)") end
    return errs, warns
  end,
}

M.collectible_types = {
  name = "Collectible Types",
  file = "developer/config/collectible_types.lua",
  entries = {
    required = {},
    optional = {
      type = { type = {"string"}, values = {"health", "energy", "currency", "key", "upgrade", "lore", "progression", "ability"}, description = "Collectible category" },
      category = { type = {"string"}, description = "Alias for type/category" },
      on_collect = { type = {"string", "function"}, description = "Handler function name or callback function" },
      value = { type = "number", range = {0, 10000}, description = "Numeric value (health, currency, etc.)" },
      notification = { type = {"boolean", "string"}, description = "Show pickup notification (bool or message)" },
      sfx = { type = "string", description = "Pickup sound effect" },
      sprite_path = { type = "string", description = "Visual sprite asset path" },
      flag_set = { type = "string", description = "Flag to set on collection" },
    },
    allow_unknown = true,
  },
  custom_validate = function(cfg)
    local errs, warns = {}, {}
    if type(cfg) ~= "table" then return {"collectible_types: expected table"}, warns end
    for id, entry in pairs(cfg) do
      if type(entry) == "table" then
        local t = entry.type or entry.category
        if not t then
          table.insert(errs, string.format("collectible_types[%s]: provide 'type' (or 'category') to describe the collectible category", tostring(id)))
        end
      end
    end
    return errs, warns
  end,
}

M.loot_tables = {
  name = "Loot Tables",
  file = "developer/config/loot_tables.lua",
  entries = {
    required = {
      items = { type = "table", description = "Array of drop entries" },
    },
    optional = {
      drop_limit = { type = "number", range = {1, 100}, description = "Maximum items to drop" },
    },
    allow_unknown = true,
  },
  custom_validate = function(cfg)
    local errs, warns = {}, {}
    if type(cfg) ~= "table" then return {"loot_tables: expected table"}, warns end
    for table_id, entry in pairs(cfg) do
      if type(entry) == "table" and type(entry.items) == "table" then
        for i, drop in ipairs(entry.items) do
          if type(drop) ~= "table" then
            table.insert(errs, string.format("loot_tables[%s].items[%d] must be a table", tostring(table_id), i))
          elseif not drop.type then
            table.insert(errs, string.format("loot_tables[%s].items[%d] missing 'type'", tostring(table_id), i))
          end
        end
      end
    end
    return errs, warns
  end,
}

M.gates = {
  name = "Gates",
  file = "developer/config/gates.lua",
  entries = {
    required = {
      gate_type = { type = "string", description = "Gate type id from gate_types.lua" },
    },
    optional = {
      required_action = { type = "string", description = "Action tag needed to open action barriers" },
      required_ability = { type = "string", description = "Ability needed to open gate" },
      required_item = { type = "string", description = "Item needed to open gate" },
      required_flag = { type = "string", description = "Flag that must be set" },
      position = { type = "table", description = "Gate world position {x, y}" },
      one_way = { type = "boolean", description = "Can only pass in one direction" },
      locked_message = { type = "string", description = "Message shown when locked" },
    },
    allow_unknown = true,
  },
  custom_validate = function(cfg)
    local errs, warns = {}, {}
    local ok_types, gate_types = SafeRequire("developer.config.gate_types", "mvtk.core.config_schemas")
    local valid = {}
    if ok_types and type(gate_types) == "table" then
      for id, _ in pairs(gate_types) do
        valid[id] = true
      end
    end

    for idx, entry in pairs(cfg or {}) do
      if type(entry) == "table" then
        local gate_type = entry.gate_type
        if gate_type and not valid[gate_type] then
          table.insert(errs, string.format("gates[%s] uses unknown gate_type '%s' (define in developer/config/gate_types.lua)", tostring(entry.id or idx), tostring(gate_type)))
        end
      end
    end

    return errs, warns
  end,
}

M.biomes = {
  name = "Biomes",
  file = "developer/config/biomes.lua",
  entries = {
    required = {
      name = { type = "string", description = "Human-readable biome name" },
    },
    optional = {
      tileset = { type = "string", description = "Tileset used for this biome" },
      music_track = { type = "string", description = "Background music track" },
      ambient_sound = { type = "string", description = "Ambient sound loop" },
      enemy_spawn_table = { type = "string", description = "Reference to enemy spawn config" },
      lighting = { type = "table", description = "Biome lighting settings" },
      parallax_layers = { type = "table", description = "Background parallax layers" },
      hazards = { type = "table", description = "Environmental hazards (spikes, lava, etc.)" },
    },
    allow_unknown = true,
  },
}

M.abilities = {
  name = "Abilities",
  file = "developer/config/abilities.lua",
  required = {
    abilities = { type = "table", description = "Ability definitions keyed by id" },
  },
  optional = {
    stamina = { type = "table", description = "Stamina defaults" },
  },
  custom_validate = function(cfg)
    local errs, warns = {}, {}
    local defs = cfg.abilities or {}
    for id, def in pairs(defs) do
      if type(def) ~= "table" then
        table.insert(errs, string.format("abilities[%s] must be a table", tostring(id)))
      else
        if not def.name then table.insert(errs, string.format("abilities[%s] missing 'name'", tostring(id))) end
        if def.cooldown and type(def.cooldown) ~= "number" then
          table.insert(errs, string.format("abilities[%s].cooldown must be number", tostring(id)))
        end
      end
    end
    return errs, warns
  end,
}

M.items = {
  name = "Items",
  file = "developer/config/items.lua",
  entries = {
    required = {
      name = { type = "string", description = "Display name" },
    },
    optional = {
      desc = { type = "string", description = "Short description" },
    },
    allow_unknown = true,
  },
}

M.npc_types = {
  name = "NPC Types",
  file = "developer/config/npc_types.lua",
  entries = {
    required = {
      name = { type = "string", description = "Display name" },
    },
    optional = {
      sprite = { type = "string" },
      dialogue_id = { type = "string" },
    },
    allow_unknown = true,
  },
}

M.map_markers = {
  name = "Map Markers",
  file = "developer/config/map_markers.lua",
  custom_validate = function(cfg)
    local errs, warns = {}, {}
    if type(cfg) ~= "table" then return {"map_markers.lua must return a table"}, warns end
    for room_id, markers in pairs(cfg) do
      if type(markers) == "table" then
        for i, m in ipairs(markers) do
          if type(m) ~= "table" then
            table.insert(errs, string.format("map_markers[%s][%d] must be a table", tostring(room_id), i))
          else
            if not m.x or not m.y then
              table.insert(errs, string.format("map_markers[%s][%d] missing x/y", tostring(room_id), i))
            end
          end
        end
      end
    end
    return errs, warns
  end,
}

M.tiled_object_config = {
  name = "Tiled Object Config",
  file = "developer/config/tiled_object_config.lua",
  required = {
    paths = { type = "table" },
    y_offsets = { type = "table" },
  },
  optional = {},
}

local function loose_table_schema(name, file)
  return {
    name = name,
    file = file,
    allow_unknown = true,
    required = {},
    optional = {},
  }
end

M.ability_defaults = loose_table_schema("Ability Defaults", "developer/config/ability_defaults.lua")
M.gate_types = loose_table_schema("Gate Types", "developer/config/gate_types.lua")
M.hazard_types = loose_table_schema("Hazard Types", "developer/config/hazard_types.lua")
M.secret_settings = loose_table_schema("Secret Settings", "developer/config/secret_settings.lua")
M.secret_types = loose_table_schema("Secret Types", "developer/config/secret_types.lua")
M.secret_rooms = loose_table_schema("Secret Rooms", "developer/config/secret_rooms.lua")
M.tileset_mapping = loose_table_schema("Tileset Mapping", "developer/config/tileset_mapping.lua")
M.rooms_config = loose_table_schema("Rooms Config", "developer/config/rooms_config.lua")
M.stream_settings = loose_table_schema("Stream Settings", "developer/config/stream_settings.lua")
M.sound_bank = loose_table_schema("Sound Bank", "developer/config/sound_bank.lua")
M.ambience_tracks = loose_table_schema("Ambience Tracks", "developer/config/ambience_tracks.lua")
M.ambient_zones = loose_table_schema("Ambient Zones", "developer/config/ambient_zones.lua")
M.hud_layout = loose_table_schema("HUD Layout", "developer/config/hud_layout.lua")
M.ui_theme = loose_table_schema("UI Theme", "developer/config/ui_theme.lua")
M.settings_defaults = loose_table_schema("Settings Defaults", "developer/config/settings_defaults.lua")
M.game_config = loose_table_schema("Game Config", "developer/config/game_config.lua")

M.display_settings = {
  name = "Display Settings", file = "developer/config/display_settings.lua",
  required = { letterbox_color = { type = "table" } },
  custom_validate = function(config)
    local errors = {}
    local rgb = config.letterbox_color
    if type(rgb) == "table" then
      for _, key in ipairs({ "r", "g", "b" }) do
        local value = rgb[key]
        if type(value) ~= "number" or value ~= value or value < 0 or value > 1 then
          errors[#errors + 1] = "letterbox_color." .. key .. " must be a finite number from 0 to 1"
        end
      end
      for key in pairs(rgb) do
        if key ~= "r" and key ~= "g" and key ~= "b" then
          errors[#errors + 1] = "letterbox_color only accepts r, g and b (bars are always opaque)"
        end
      end
    end
    for key in pairs(config) do
      if key ~= "letterbox_color" then
        errors[#errors + 1] = "display_settings only accepts letterbox_color"
      end
    end
    return errors, {}
  end,
}

M.narrative_dialogues = loose_table_schema("Narrative Dialogues", "developer/config/narrative/dialogues.lua")
M.combat_config = loose_table_schema("Combat Config", "config/combat_config.lua")
M.combat_overrides = loose_table_schema("Combat Overrides", "config/combat_overrides.lua")
for _, kind in ipairs({ "combat_config", "combat_overrides", "player_art" }) do
  M[kind].optional = M[kind].optional or {}
  M[kind].optional.units_version = { type = "number", values = {1, 2},
    description = "Pixel-unit generation; absent means old units (1)" }
end

-----------------------------------------------------------
-- VALIDATION HELPERS
-----------------------------------------------------------

-- Validate a single field against schema
function M.validate_field(value, field_schema, field_name)
  local errors = {}

  -- Check type
  if field_schema.type then
    local actual_type = type(value)
    local expected = field_schema.type
    local function matches_expected()
      if type(expected) == "table" then
        for _, t in ipairs(expected) do
          if actual_type == t then return true end
        end
        return false
      else
        return actual_type == expected
      end
    end
    if not matches_expected() then
      local expected_str = type(expected) == "table" and table.concat(expected, " | ") or tostring(expected)
      table.insert(errors, string.format(
        "Field '%s': Expected %s, got %s",
        field_name, expected_str, actual_type
      ))
      return errors -- Type mismatch, can't do further validation
    end
  end

  -- Check range (for numbers)
  if field_schema.range and type(value) == "number" then
    local min, max = field_schema.range[1], field_schema.range[2]
    if value < min or value > max then
      table.insert(errors, string.format(
        "Field '%s': Value %s out of range [%s, %s]",
        field_name, Number.fixed(value, 2), Number.fixed(min, 2), Number.fixed(max, 2)
      ))
    end
  end

  -- Check allowed values
  if field_schema.values then
    local found = false
    for _, allowed in ipairs(field_schema.values) do
      if value == allowed then
        found = true
        break
      end
    end
    if not found then
      table.insert(errors, string.format(
        "Field '%s': Invalid value '%s'. Allowed: %s",
        field_name, tostring(value), table.concat(field_schema.values, ", ")
      ))
    end
  end

  -- Check boolean
  if field_schema.type == "boolean" and type(value) ~= "boolean" then
    table.insert(errors, string.format(
      "Field '%s': Expected boolean, got %s",
      field_name, type(value)
    ))
  end

  -- Check nested table fields
  if field_schema.fields and type(value) == "table" then
    for nested_name, nested_schema in pairs(field_schema.fields) do
      local nested_value = value[nested_name]
      if nested_value == nil then
        table.insert(errors, string.format(
          "Field '%s.%s': Missing required field",
          field_name, nested_name
        ))
      else
        local nested_errors = M.validate_field(nested_value, nested_schema, field_name .. "." .. nested_name)
        for _, err in ipairs(nested_errors) do
          table.insert(errors, err)
        end
      end
    end
  end

  return errors
end

-- Get human-readable description of expected type
function M.get_type_description(field_schema)
  local desc
  if type(field_schema.type) == "table" then
    desc = table.concat(field_schema.type, " | ")
  else
    desc = field_schema.type or "any"
  end

  if field_schema.range then
    desc = desc .. string.format(" [%s - %s]", Number.fixed(field_schema.range[1], 1), Number.fixed(field_schema.range[2], 1))
  end

  if field_schema.values then
    desc = desc .. " (" .. table.concat(field_schema.values, " | ") .. ")"
  end

  if field_schema.description then
    desc = desc .. " - " .. field_schema.description
  end

  return desc
end

return M

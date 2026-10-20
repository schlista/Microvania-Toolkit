-- mvtk/enemies/enemy_overrides.lua
-- Pure normalization for enemy Tiled properties used by baked and runtime paths.

local Util = require "mvtk.core.util"
local PropertyFlattener = require "mvtk.tiled.property_flattener"

local M = {}

-- Tiled 1.12 displays custom properties alphabetically and does not support a
-- creator-defined order. The enemy template keeps `art` and `enemy_type` at
-- the top level and groups the remaining authoring fields into class-valued
-- properties whose names sort after it.  Old maps still export the original
-- flat keys, so normalization accepts both shapes.
M.TILED_PROPERTY_GROUPS = {
    movement_and_attacks = {
        "attack_pattern",
        "attack_pattern2",
        "chase_speed",
        "chase_speed_mult",
        "detection_range",
        "facing",
        "hover_height",
        "movement",
        "patrol_distance",
        "patrol_height",
        "patrol_route",
    },
    rewards = {
        "drops",
        "loot_table",
    },
    stats = {
        "ally_detection_range",
        "contact_damage",
        "contact_damage_cooldown",
        "damage_mult",
        "difficulty",
        "elite",
        "faction",
        "group_id",
        "health_mult",
        "iframes_on_hit",
        "knockback_force",
        "speed_mult",
    },
    tuning = {
        "attack_cooldown",
        "attack_detection_range",
        "attack_height",
        "attack_range",
        "attack_windup",
        "charge_cooldown",
        "charge_distance",
        "charge_duration",
        "charge_speed",
        "dart_interval",
        "dart_speed",
        "dart_vertical_speed",
        "projectile_damage",
        "projectile_speed",
        "rise_height",
        "rise_range",
        "rise_speed",
        "shoot_cooldown",
        "swoop_detection_range",
        "swoop_duration",
        "swoop_speed",
    },
}

local TILED_GROUP_BY_FIELD = {}
for group_name, fields in pairs(M.TILED_PROPERTY_GROUPS) do
    for _, field in ipairs(fields) do
        TILED_GROUP_BY_FIELD[field] = group_name
    end
end

M.DEFAULT_BEHAVIOR_BY_TYPE = {
    slime = "ground_patrol_chase",
    crawler = "ground_patrol_chase",
    screecher = "chase",
    marksman = "ranged_patrol",
    charger = "dash",
    bruiser = "ground_patrol_chase",
    bat = "chase",
    bat_enemy = "swoop_attack",
    bomber = "bomber",
    ghost = "ghost_float,shoot_random",
    ghost_enemy = "ghost_float",
    goblin = "patrol,dash",
    skeleton = "ranged_patrol",
    knight = "guardian,dash",
    mummy_enemy = "chase_player,melee_swipe",
    spider = "patrol",
    wizard = "ranged_patrol",
    flying_patrol = "hover",
    patrol_flying = "hover",
}

local enemy_hash_to_key = nil
local skin_hash_to_id = nil
local behavior_hash_map = nil
local movement_hash_map = nil
local attack_pattern_hash_map = nil
local difficulty_hash_map = nil
local difficulty_profiles = nil

local function trim(s)
    if s == nil then return "" end
    return (tostring(s):match("^%s*(.-)%s*$"))
end

local function is_inherit_token(value)
    if value == nil then return true end
    if type(value) ~= "string" then return false end
    local token = trim(value):lower()
    return token == "" or token == "type_default" or token == "inherit"
end

local function grouped_value_is_inherit(field, value)
    if is_inherit_token(value) then return true end

    if field == "movement" or field == "attack_pattern" or field == "attack_pattern2" then
        return type(value) == "string" and trim(value):lower() == "none"
    end
    if field == "difficulty" then
        return type(value) == "string" and trim(value):lower() == "none"
    end
    if field == "elite" then
        return value == false or value == 0 or tostring(value):lower() == "false"
    end
    if field == "facing" then
        return tonumber(value) == 0
    end

    -- All grouped numeric tuning defaults use -1 as the inheritance sentinel.
    local number = tonumber(value)
    return number ~= nil and number < 0
end

-- Return a canonical flat property table without mutating the Tiled export.
-- Explicit grouped values win.  A grouped inheritance sentinel deliberately
-- falls back to the matching legacy flat key, keeping existing TMX/Lua exports
-- compatible while new templates can use collapsible property groups.
function M.flatten_tiled_properties(properties)
    return PropertyFlattener.flatten(properties, {
        groups = M.TILED_PROPERTY_GROUPS,
        detect_groups = false,
        load_registry = false,
        ignore_grouped_value = function(context)
            return grouped_value_is_inherit(context.field, context.grouped_value)
        end,
    })
end

function M.tiled_property_group(field)
    return TILED_GROUP_BY_FIELD[field]
end

function M.is_inherit_token(value)
    return is_inherit_token(value)
end

local function hash_key(value)
    if type(_G.hash) == "function" then
        return _G.hash(value)
    end
    return value
end

-- Hash strings are stripped in release builds. Resolve only against synced
-- manifest keys, without interpreting tostring(hash).
function M.resolve_skin_id(value)
    if value == nil then return nil end
    if skin_hash_to_id == nil then
        skin_hash_to_id = {}
        local manifest = Util.require_config("developer.config.enemy_skins_generated", { skins = {} })
        for id in pairs(type(manifest.skins) == "table" and manifest.skins or {}) do
            if type(id) == "string" and id ~= "" then
                skin_hash_to_id[id] = id
                skin_hash_to_id[hash_key(id)] = id
            end
        end
    end
    return skin_hash_to_id[value]
end

-- The resolved preset is shared. Only its instance copy may carry linked art;
-- nested behavior, animation aliases and audio keep their preset references.
function M.apply_skin_override(self, overrides, warn)
    local cfg = self.enemy_type_config
    if overrides.skin and type(cfg) == "table" then
        local instance = {}
        for key, value in pairs(cfg) do instance[key] = value end
        instance.skin = overrides.skin
        self.enemy_type_config = instance
    elseif overrides.unsynced_skin ~= nil
        and self._missing_instance_skin_warning ~= overrides.unsynced_skin then
        (warn or print)(string.format(
            "[ENEMY] Warning: requested skin '%s' is not synced; keeping preset skin '%s'.",
            tostring(overrides.unsynced_skin), tostring(type(cfg) == "table" and cfg.skin or "default")))
        self._missing_instance_skin_warning = overrides.unsynced_skin
    end
end

local function is_hash_hex_string(value)
    if type(value) ~= "string" then return false end
    if not value:match("^[0-9a-fA-F]+$") then return false end
    local len = #value
    return len == 16 or len == 32
end

function M.normalize_hash_string(value)
    local text = Util.normalize_hash_string(value)
    if text == "00000000000000000000000000000000" then return nil end
    return text
end

local function optional_string(value)
    local s = M.normalize_hash_string(value)
    if not s then return nil end
    if s:lower() == "none" then return nil end
    if is_hash_hex_string(s) then return nil end
    return s
end

function M.to_bool(value, default)
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end
    if type(value) == "string" then
        local v = value:lower()
        if v == "true" or v == "1" or v == "yes" then return true end
        if v == "false" or v == "0" or v == "no" then return false end
    end
    return default
end

function M.to_number(value, default)
    local n = tonumber(value)
    if n == nil then return default end
    return n
end

local function positive_number(value)
    local n = M.to_number(value, nil)
    return (n and n > 0) and n or nil
end

local function nonnegative_number(value)
    local n = M.to_number(value, nil)
    return (n and n >= 0) and n or nil
end

local function build_enemy_hash_map()
    if enemy_hash_to_key ~= nil then return enemy_hash_to_key end
    enemy_hash_to_key = {}

    local function add_types(types)
        if type(types) ~= "table" then return end
        for key, _ in pairs(types) do
            enemy_hash_to_key[hash_key(key)] = key
        end
    end

    local function add_skin_ids(manifest)
        local skins = type(manifest) == "table" and manifest.skins or nil
        if type(skins) ~= "table" then return end
        for id, skin in pairs(skins) do
            local skin_id = id
            if type(id) == "number" and type(skin) == "table" then
                skin_id = skin.skin_id or skin.id
            end
            if type(skin_id) == "string" and skin_id ~= "" then
                enemy_hash_to_key[hash_key(skin_id)] = skin_id
            end
        end
    end

    for key, _ in pairs(M.DEFAULT_BEHAVIOR_BY_TYPE) do
        enemy_hash_to_key[hash_key(key)] = key
    end

    local ok, types = pcall(require, "developer.config.enemy_types")
    if ok then add_types(types) end
    local ok_defaults, defaults = pcall(require, "mvtk.enemies.default_enemy_types")
    if ok_defaults then add_types(defaults) end
    add_skin_ids(Util.require_config("developer.config.enemy_skins_generated", { skins = {} }))

    return enemy_hash_to_key
end

function M.resolve_enemy_type(value)
    if value == nil then return nil end
    if type(value) == "string" then
        local resolved = optional_string(value)
        return resolved
    end
    if type(value) == "userdata" then
        local map = build_enemy_hash_map()
        if map and map[value] then
            return map[value]
        end
        local resolved = optional_string(value)
        return resolved
    end
    return optional_string(value)
end

local function build_value_hash_map(values)
    local map = {}
    for _, value in ipairs(values) do
        map[hash_key(value)] = value
    end
    return map
end

local function build_behavior_hash_map()
    if behavior_hash_map ~= nil then return behavior_hash_map end
    behavior_hash_map = build_value_hash_map({
        "idle", "patrol_horizontal", "patrol_vertical", "chase_player", "flee_player",
        "shoot_straight", "shoot_spread", "shoot_burst", "shoot_circle", "shoot_random",
        "swoop_attack", "melee_swipe", "dash_attack", "jump_attack", "teleport_attack", "rain_attack", "shield",
        "summon_minion", "spiral_shot", "zigzag_move", "homing_shot", "charge_shoot",
        "patrol", "patrol_h", "patrol_v", "wander", "hover", "chase", "follow",
        "flee", "run_away", "zigzag", "shoot", "ranged", "spread", "shotgun",
        "burst", "circle", "radial", "random", "spiral", "homing", "swoop", "dart", "swipe", "melee", "dash",
        "charge", "lunge", "jump", "leap", "teleport", "blink", "defend",
        "block", "summon", "spawn", "rain", "ranged_patrol", "ranged_chase",
        "sniper", "bomber", "swarmer", "guardian", "summoner", "boss_basic",
        "ghost_float", "ghost", "ghost_float,shoot_random", "patrol,dash", "guardian,dash",
        "chase_player,melee_swipe",
    })
    return behavior_hash_map
end

local function resolve_enum_value(value, map)
    if value == nil then return nil end
    if type(value) == "userdata" then
        if map and map[value] then
            return map[value]
        end
    end
    local resolved = optional_string(value)
    if resolved and not is_hash_hex_string(resolved) then
        return resolved
    end
    return nil
end

function M.resolve_behavior(value)
    if value == nil then return nil end
    if type(value) == "userdata" then
        local map = build_behavior_hash_map()
        if map and map[value] then
            return map[value]
        end
    end
    return optional_string(value)
end

function M.resolve_movement(value)
    if movement_hash_map == nil then
        movement_hash_map = build_value_hash_map({
            "type_default", "inherit", "disabled", "none",
            "stationary", "ground_patrol", "ground_patrol_chase", "ground_chase",
            "flying_chase", "vertical_patrol", "hover", "flee", "zigzag", "ghost_float",
            -- Internal runtime names are also accepted when supplied by older
            -- hand-authored exports or scripts.
            "idle", "patrol_horizontal", "patrol_vertical", "chase_player", "flee_player", "zigzag_move",
            -- Legacy creator-facing aliases remain valid for existing maps.
            "patrol", "chase",
        })
    end
    return resolve_enum_value(value, movement_hash_map)
end

function M.resolve_attack_pattern(value)
    if attack_pattern_hash_map == nil then
        attack_pattern_hash_map = build_value_hash_map({
            "type_default", "inherit", "disabled", "none", "contact_only", "no_attack",
            "shoot_straight", "shoot_spread", "shoot_burst",
            "shoot_circle", "shoot_random", "spiral_shot", "homing_shot",
            "swoop_attack", "melee_swipe", "dash_attack", "jump_attack", "charge_shoot", "teleport_attack",
            "rain_attack", "summon_minion", "shield",
        })
    end
    return resolve_enum_value(value, attack_pattern_hash_map)
end

local function optional_enum(value)
    if value == nil then return nil end
    local normalized = trim(value):lower()
    if normalized == "" or normalized == "none" or normalized == "type_default" or normalized == "inherit" then
        return nil
    end
    return value
end

local function build_difficulty_hash_map()
    if difficulty_hash_map ~= nil then return difficulty_hash_map end
    difficulty_hash_map = {}
    local ok, cfg = pcall(require, "developer.config.difficulty_settings")
    local profiles = ok and cfg and cfg.profiles or nil
    if type(profiles) == "table" then
        for name, _ in pairs(profiles) do
            local key = tostring(name)
            difficulty_hash_map[hash_key(key)] = key
        end
    end
    difficulty_hash_map[hash_key("easy")] = "easy"
    difficulty_hash_map[hash_key("normal")] = "normal"
    difficulty_hash_map[hash_key("hard")] = "hard"
    return difficulty_hash_map
end

function M.resolve_difficulty_value(value)
    if value == nil then return nil end
    if type(value) == "number" then
        return value
    end
    if type(value) == "userdata" then
        local map = build_difficulty_hash_map()
        if map and map[value] then
            return map[value]
        end
    end
    local resolved = optional_string(value)
    if not resolved then return nil end
    local numeric = tonumber(resolved)
    return numeric or resolved
end

function M.resolve_difficulty_scaling(value)
    value = M.resolve_difficulty_value(value)
    if value == nil or value == "" then
        return nil
    end
    if type(value) == "number" then
        return { health_mult = value, damage_mult = value }
    end
    if type(value) == "string" then
        local num = tonumber(value)
        if num then
            return { health_mult = num, damage_mult = num }
        end
        if difficulty_profiles == nil then
            local ok, cfg = pcall(require, "developer.config.difficulty_settings")
            difficulty_profiles = ok and cfg and cfg.profiles or false
        end
        if difficulty_profiles and type(difficulty_profiles) == "table" then
            local key = value:lower()
            for name, profile in pairs(difficulty_profiles) do
                if tostring(name):lower() == key then
                    local health_mult = tonumber(profile.enemy_health_mult) or 1.0
                    local damage_mult = tonumber(profile.damage_taken_mult) or 1.0
                    return { health_mult = health_mult, damage_mult = damage_mult }
                end
            end
        end
    end
    return nil
end

function M.parse_drops_string(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local drops = {}
    for token in raw:gmatch("[^,;]+") do
        local parts = {}
        for part in token:gmatch("[^:]+") do
            parts[#parts + 1] = trim(part)
        end
        local drop_id = parts[1] or ""
        if drop_id ~= "" then
            local min, max = 1, 1
            local range = parts[2]
            if range and range ~= "" then
                local a, b = range:match("^(%-?%d+)%s*%-%s*(%-?%d+)$")
                if a and b then
                    min = tonumber(a) or min
                    max = tonumber(b) or min
                else
                    local single = tonumber(range)
                    if single then
                        min, max = single, single
                    end
                end
            end
            local chance = tonumber(parts[3] or "") or 1.0
            drops[drop_id] = { min = min, max = max, chance = chance }
        end
    end
    if next(drops) == nil then return nil end
    return drops
end

function M.normalize(raw)
    raw = M.flatten_tiled_properties(raw or {})

    local enemy_type = M.resolve_enemy_type(raw.enemy_type)
    local skin = M.resolve_skin_id(raw.skin)
    local unsynced_skin
    if raw.skin ~= nil and raw.skin ~= "" and raw.skin ~= hash_key("") and not skin then
        unsynced_skin = raw.skin
    end
    local difficulty_value = M.resolve_difficulty_value(raw.difficulty_override or raw.difficulty)
    local difficulty_scale = M.resolve_difficulty_scaling(difficulty_value)
    local already_scaled = raw.difficulty_applied == true

    -- Tiled templates author -1 as "inherit from enemy_types.lua". Multipliers
    -- must be positive; any sentinel or invalid value means "no change" (1.0).
    local health_mult = positive_number(raw.health_mult or raw.health_multiplier) or 1.0
    local damage_mult = positive_number(raw.damage_mult or raw.damage_multiplier) or 1.0
    local speed_mult = positive_number(raw.speed_mult or raw.speed_multiplier) or 1.0

    if difficulty_scale and not already_scaled then
        health_mult = health_mult * (difficulty_scale.health_mult or 1.0)
        damage_mult = damage_mult * (difficulty_scale.damage_mult or 1.0)
    end

    local drops_value = raw.drops
    if type(drops_value) ~= "table" then
        local drops_string = M.normalize_hash_string(drops_value)
        if drops_string and drops_string:lower() == "none" then
            drops_value = {}
        else
            drops_value = M.parse_drops_string(drops_string or "")
        end
    end

    local patrol_height = nonnegative_number(raw.patrol_height_override)
    if patrol_height == nil and raw.patrol_height_override == nil then
        patrol_height = nonnegative_number(raw.patrol_height)
    end

    local movement_value = optional_enum(M.resolve_movement(raw.movement))
    local attack_pattern_value = optional_enum(M.resolve_attack_pattern(raw.attack_pattern))
    local attack_pattern2_value = optional_enum(M.resolve_attack_pattern(raw.attack_pattern2))

    return {
        enemy_type = enemy_type,
        skin = skin,
        unsynced_skin = unsynced_skin,
        room_id = optional_string(raw.room_id),
        loot_table = optional_string(raw.loot_table),
        drops = drops_value,
        difficulty_override = difficulty_value,
        difficulty_applied = difficulty_scale ~= nil or already_scaled,
        elite = M.to_bool(raw.elite, false),
        patrol_route = optional_string(raw.patrol_route),
        behavior = M.resolve_behavior(raw.behavior),
        movement = movement_value,
        attack_pattern = attack_pattern_value,
        attack_pattern2 = attack_pattern2_value,
        patrol_height = patrol_height,
        patrol_distance = positive_number(raw.patrol_distance),
        hover_height = positive_number(raw.hover_height),
        faction = optional_string(raw.faction),
        group_id = optional_string(raw.group_id),
        ally_detection_range = nonnegative_number(raw.ally_detection_range),
        detection_range = nonnegative_number(raw.detection_range),
        chase_speed = nonnegative_number(raw.chase_speed),
        chase_speed_mult = nonnegative_number(raw.chase_speed_mult),
        health_mult = health_mult,
        damage_mult = damage_mult,
        speed_mult = speed_mult,
        health_multiplier = health_mult,
        damage_multiplier = damage_mult,
        contact_damage_multiplier = damage_mult,
        contact_damage = nonnegative_number(raw.contact_damage),
        knockback_force = nonnegative_number(raw.knockback_force),
        contact_damage_cooldown = nonnegative_number(raw.contact_damage_cooldown),
        shoot_cooldown = nonnegative_number(raw.shoot_cooldown),
        projectile_damage = nonnegative_number(raw.projectile_damage),
        projectile_speed = nonnegative_number(raw.projectile_speed),
        charge_speed = nonnegative_number(raw.charge_speed),
        charge_distance = nonnegative_number(raw.charge_distance),
        charge_duration = nonnegative_number(raw.charge_duration),
        charge_cooldown = nonnegative_number(raw.charge_cooldown),
        attack_detection_range = nonnegative_number(raw.attack_detection_range),
        swoop_detection_range = nonnegative_number(raw.swoop_detection_range),
        swoop_speed = nonnegative_number(raw.swoop_speed),
        swoop_duration = nonnegative_number(raw.swoop_duration),
        dart_speed = nonnegative_number(raw.dart_speed),
        dart_interval = nonnegative_number(raw.dart_interval),
        dart_vertical_speed = nonnegative_number(raw.dart_vertical_speed),
        rise_range = nonnegative_number(raw.rise_range),
        rise_height = nonnegative_number(raw.rise_height),
        rise_speed = nonnegative_number(raw.rise_speed),
        attack_range = nonnegative_number(raw.attack_range),
        attack_height = nonnegative_number(raw.attack_height),
        attack_windup = nonnegative_number(raw.attack_windup),
        attack_cooldown = nonnegative_number(raw.attack_cooldown),
        facing = raw.facing,
        max_enemies_per_room = raw.max_enemies_per_room,
        iframes_on_hit = nonnegative_number(raw.iframes_on_hit),
    }
end

return M

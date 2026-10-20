--- Tiled Object Spawner
-- Spawns game objects from Tiled object layers
-- Supports various object types: collectibles, enemies, triggers, spawn points, etc.
--
-- Usage:
--   1. In Tiled, create object layers and add objects
--   2. Set object "type" property to define what to spawn
--   3. Add custom properties for configuration
--   4. Use spawner to process objects and create game objects
--
-- @module object_spawner

local Util = require "mvtk.core.util"
local TriggerPayloads = require "mvtk.shared.trigger_payloads"
local SpawnerRegistry = require "mvtk.tiled.spawner_registry"
local KeyIds = require "mvtk.core.key_ids"
local PropertyFlattener = require "mvtk.tiled.property_flattener"
local EnemyOverrides = require "mvtk.enemies.enemy_overrides"
local RetiredTypes = require "mvtk.tiled.retired_types"

local M = {}

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.tiled and _Dbg.tiled.spawner then
        _orig_print(...)
    end
end

local SIZE_DEBUG_TYPES = {
    bounce_pad = true,
    checkpoint = true,
    fast_travel = true,
}

-- ============================================================================
-- OPTIONAL RUNTIME SERVICES
-- ============================================================================
-- Services are registered by mvtk.tiled.spawner_registry so this core can
-- dispatch objects without owning lazy require caches for every subsystem.

local ok_cm, CollectibleManager = pcall(require, "mvtk.collectibles.collectible_manager")
if not ok_cm then CollectibleManager = nil end
local ok_em, EnemyManager = pcall(require, "mvtk.enemies.enemy_manager")
if not ok_em then EnemyManager = nil end
local TiledParser = require "mvtk.tiled.tiled_parser"
local TileSnap = nil
do
    local ok, mod = pcall(require, "mvtk.tiled.tile_snap")
    if ok and type(mod) == "table" then
        TileSnap = mod
    end
end
local CollisionBox = nil
do
    local ok, mod = pcall(require, "mvtk.tiled.collision_box")
    if ok and type(mod) == "table" then
        CollisionBox = mod
    end
end

local function get_spawner_service(name)
    return SpawnerRegistry.get_service(name)
end

local function get_gate_manager()
    return get_spawner_service("gate_manager")
end

local function get_room_manager()
    return get_spawner_service("room_manager")
end

local function get_boss_arena()
    return get_spawner_service("boss_arena")
end

local function get_chest_inline_registry()
    return get_spawner_service("chest_inline_registry")
end

local function get_tiled_object_config()
    return get_spawner_service("tiled_object_config")
end

local function get_point_y_offset(object_type)
    local cfg = get_tiled_object_config()
    if cfg and type(cfg) == "table" then
        local offsets = cfg.y_offsets
        if type(offsets) == "table" then
            local offset = offsets[object_type]
            if offset == nil then
                offset = offsets.default
            end
            return tonumber(offset) or 0
        end
    end
    return 0
end

local function get_tile_settings()
    return get_spawner_service("tile_settings")
end

-- Get the baked collection origin used by room-local Tiled coordinates.
local function get_room_world_offset(room_id)
    local rm = get_room_manager()
    if not rm then return 0, 0 end
    local data = rm.get_room_data(room_id)
    if not data then return 0, 0 end
    return require("mvtk.map.streaming.room_geometry").compute_spawn_xy(data)
end

local to_bool = Util.to_bool
local OP = require "mvtk.tiled.object_props"

-- ============================================================================
-- TYPE DETECTION AND PROPERTY NORMALIZATION
-- ============================================================================
-- Tiled templates frequently export blank type/class values. These helpers
-- infer stable runtime types from explicit ids, property groups, and names.

local function normalize_object_type(value)
    if value == nil then
        return nil
    end
    local s = tostring(value):lower()
    s = s:gsub("[%s%-]+", "_")
    s = s:gsub("[^%w_]", "")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    if s == "" then
        return nil
    end
    return s
end

local function ambient_component_name(sound_id)
    local normalized = normalize_object_type(sound_id)
    if not normalized then
        return ""
    end
    return "ambient_" .. normalized
end

local function infer_object_type(object)
    if type(object) ~= "table" then
        return nil
    end

    local props = PropertyFlattener.flatten(object.properties)
    local name = normalize_object_type(object.name)

    local function has(key)
        local value = props[key]
        return value ~= nil and tostring(value) ~= ""
    end

    -- Elevator camera/motion properties overlap camera-zone and platform
    -- vocabulary. Resolve the strong cross-map identities first and keep this
    -- order in lockstep with hooks/core/tiled_objects.lua.
    if has("elevator_id") and has("node_id") then
        return "elevator_node"
    end
    if has("elevator_id") then
        return "elevator"
    end

    -- Enemy templates export blank type/class; enemy_type is the discriminating
    -- property and must win before the generic stat props below (the enemy
    -- template's damage_mult otherwise trips the boss_weak_point rule, which is
    -- a build-time-skipped type — the enemy then silently never spawns).
    -- Mirrors the editor-side rule in hooks/core/tiled_objects.lua.
    if has("enemy_type") then
        return "enemy"
    end

    -- Camera zones are frequently authored via templates with blank type/class.
    -- Keep this strict to avoid stealing other zone-like objects.
    local has_camera_settings =
        has("camera_mode") or
        has("zoom_level") or
        has("deadzone_width") or
        has("deadzone_height") or
        has("bounds_padding") or
        has("smooth_follow") or
        has("transition_speed")
    if has_camera_settings then
        return "camera_zone"
    end
    if has("zone_id") and (has("focus_x") or has("focus_y") or has("lock_x") or has("lock_y")) then
        return "camera_zone"
    end

    if has("teleporter_id") or has("pair_id") then
        return "teleporter"
    end
    -- Keep these high-confidence template keys ahead of the identity block,
    -- matching hooks/core/tiled_objects.lua.
    if props.spawn_type ~= nil then
        return "spawn_point"
    end
    if has("collectible_type") then
        return "collectible"
    end
    if has("chest_type") or has("contents") then
        return "chest"
    end
    -- Template identity properties. Each drop-in template has a stable unique id
    -- property; resolve on those before generic/greedy property heuristics below.
    -- Mirrors hooks/core/tiled_objects.lua infer_object_type (keep in lockstep).
    if has("lore_id") then
        return "lore_item"
    end
    if has("hint_id") then
        return "hint_stone"
    end
    if has("sign_id") then
        return "sign"
    end
    if has("secret_id") or has("secret_type") or has("reveals_on") then
        return "secret"
    end
    if has("gate_id") or has("gate_type") then
        return "gate"
    end
    if has("water_id") or has("water_type")
        or props.swim_enabled ~= nil or props.buoyancy ~= nil or props.oxygen_drain ~= nil
    then
        return "water_volume"
    end
    if has("surface_id")
        or props.jump_force_x ~= nil or props.jump_force_y ~= nil
        or props.allow_slide ~= nil or props.slide_speed ~= nil
    then
        return "wall_jump_surface"
    end
    if has("wall_id") then
        return "breakable_wall"
    end
    if has("checkpoint_id")
        or props.respawn_facing ~= nil
        or (name and name:find("checkpoint", 1, true))
    then
        return "checkpoint"
    end
    if has("bounce_speed")
        or (name and name:find("bounce", 1, true) and name:find("pad", 1, true))
    then
        return "bounce_pad"
    end
    if has("station_id") and (props.heal_amount ~= nil or props.heal_percent ~= nil
        or props.recharge_time ~= nil or props.cost_currency ~= nil)
    then
        return "health_station"
    end
    if has("station_id") and (props.restore_amount ~= nil or props.restore_percent ~= nil
        or has("resource_type"))
    then
        return "energy_station"
    end
    if has("station_id") and (has("reveal_area") or props.reveal_radius ~= nil
        or props.reveal_full_biome ~= nil)
    then
        return "map_station"
    end
    if has("station_id") then
        return "fast_travel"
    end
    local icon = normalize_object_type(props.icon)
    if (props.auto_unlock ~= nil
            or props.unlock_cost ~= nil
            or has("station_name")
            or has("station_description"))
        and ((name and name:find("fast", 1, true) and name:find("travel", 1, true))
            or (icon and icon:find("fast", 1, true) and icon:find("travel", 1, true)))
    then
        return "fast_travel"
    end
    if has("crumble_delay")
        or has("shake_before_crumble")
        or has("sound_crumble")
        or has("sound_respawn")
    then
        return "crumble_platform"
    end
    if has("use_joint") and (has("motor_speed") or has("path_dx") or has("path_dy")) then
        return "joint_platform"
    end
    if has("platform_type") or (has("distance") and has("speed")) then
        return "platform"
    end
    if has("path_name")
        or has("player_parent")
        or has("mode")
        or (has("start_delay") and has("wait_time") and has("trigger_id"))
        or (has("platform_id") and not has("respawn_delay"))
    then
        return "moving_platform"
    end

    -- Dialogue Trigger carries an optional npc_id *link*; it must not classify
    -- as npc. Mirrors hooks/core/tiled_objects.lua (keep this before npc_type).
    if has("dialogue_id") and not has("npc_type")
        and (has("trigger_id") or props.auto_play ~= nil or props.consume_on_fire ~= nil)
    then
        return "dialogue_trigger"
    end
    -- NPC objects from templates often have blank type; detect via npc_type property.
    if has("npc_type") then
        return "npc"
    end
    -- Ability/collectible pickup objects from templates; detect via ability_id property.
    if has("ability_id") then
        return "ability"
    end
    if has("phase_id")
        or props.health_min ~= nil
        or props.health_max ~= nil
        or props.attack_interval_min ~= nil
        or props.attack_interval_max ~= nil
        or props.transition_type ~= nil
        or props.transition_duration ~= nil
    then
        return "boss_phase"
    end
    if has("trigger_id")
        and props.phase ~= nil
        and (props.transition_time ~= nil or props.set_flag ~= nil or props.requires_flag ~= nil)
        and (has("boss_id") or has("boss_preset") or has("boss_type") or has("arena_id"))
    then
        return "boss_phase_trigger"
    end
    if has("point_id")
        or props.damage_mult ~= nil
        or props.vulnerable ~= nil
    then
        return "boss_weak_point"
    end
    if has("boundary_id")
        or props.enabled_when_locked ~= nil
        or props.start_enabled ~= nil
    then
        return "arena_boundary"
    end
    if props.is_boss_arena ~= nil
        or props.camera_lock ~= nil
        or props.phases ~= nil
    then
        return "boss_arena"
    end
    if has("boss_id")
        or has("boss_preset")
        or has("boss_type")
        or props.boss_visual_type ~= nil
        or props.visual_component ~= nil
        or props.attack_pattern_ids ~= nil
        or props.arena_lock ~= nil
    then
        return "boss"
    end
    if has("arena_id")
        and (props.lock_on_enter ~= nil or props.unlock_on_clear ~= nil or has("encounter_id"))
    then
        return "arena_lock"
    end

    local template_file = tostring(props.template_file or "")
    if template_file ~= "" then
        local template_name = normalize_object_type(template_file:match("([^/\\]+)%.tx$") or template_file)
        if template_name and M.handlers and M.handlers[template_name] then
            return template_name
        end
    end

    if name == "action_barrier" then
        return "gate"
    end
    if name and name:find("camera", 1, true) and name:find("zone", 1, true) then
        return "camera_zone"
    end
    if name == "elevator_node" then
        return "elevator_node"
    end
    if name == "elevator" then
        return "elevator"
    end
    if name and name:find("crumble", 1, true) and name:find("platform", 1, true) then
        return "crumble_platform"
    end
    if name and name:find("rail", 1, true) and (name:find("platform", 1, true) or name:find("elevator", 1, true)) then
        return "joint_platform"
    end
    if name == "joint_platform" or name == "rail_elevator" then
        return "joint_platform"
    end
    if name and name:find("horizontal", 1, true) and name:find("platform", 1, true) then
        return "platform"
    end
    if name and name:find("vertical", 1, true) and name:find("platform", 1, true) then
        return "platform"
    end
    if name and name:find("path", 1, true) and name:find("platform", 1, true) then
        return "platform"
    end
    if name and name:find("moving", 1, true) and name:find("platform", 1, true) then
        return "moving_platform"
    end
    if name and name:find("fast", 1, true) and name:find("travel", 1, true) then
        return "fast_travel"
    end

    -- Static collision authored as a bare rectangle tagged with a `solid` flag,
    -- for users who prefer a property over the Solid Box template.
    if props.solid ~= nil and to_bool(props.solid, false) then
        return "collision_box"
    end

    if name and M.handlers and M.handlers[name] then
        return name
    end

    return nil
end

local function resolve_object_type(object)
    if type(object) ~= "table" then
        return nil, "missing"
    end

    local explicit = normalize_object_type(object.type)
    if not explicit then
        explicit = normalize_object_type(object.class)
    end
    if not explicit then
        explicit = normalize_object_type(object.className)
    end
    if explicit then
        return explicit, "explicit"
    end

    local inferred = infer_object_type(object)
    if inferred then
        return inferred, "inferred"
    end

    return nil, "missing"
end

-- Normalize before both inference and handler consumption. Enemy templates
-- retain their established inheritance-sentinel precedence on top of the
-- shared shape normalizer.
local function normalize_and_resolve_object(object)
    if type(object) ~= "table" then
        return nil, "missing"
    end
    local raw_properties = object.properties
    object.properties = PropertyFlattener.flatten(raw_properties)
    local resolved, source = resolve_object_type(object)
    if resolved == "enemy" then
        object.properties = EnemyOverrides.flatten_tiled_properties(raw_properties)
    end
    return resolved, source
end

local function resolve_rect_size_pixels(width, height, tile_w, tile_h)
    local tile = get_tile_settings()
    local fallback_w = tonumber(tile and (tile.width or tile.tile_width or tile.size)) or 128
    local fallback_h = tonumber(tile and (tile.height or tile.tile_height or tile.size)) or fallback_w
    local tw = tonumber(tile_w) or fallback_w
    local th = tonumber(tile_h) or tw
    if TileSnap and TileSnap.normalize_tile_size then
        tw, th = TileSnap.normalize_tile_size(tw, th, fallback_w, fallback_h)
    else
        if tw <= 0 then tw = fallback_w end
        if th <= 0 then th = tw end
    end

    local w = tonumber(width) or 0
    local h = tonumber(height) or 0
    if w <= 0 then w = tw end
    if h <= 0 then h = th end
    return w, h
end

local function rect_scale_from_size(width, height, base_half_w, base_half_h, fallback_w, fallback_h)
    if CollisionBox and CollisionBox.scale_from_full_size then
        return CollisionBox.scale_from_full_size(width, height, base_half_w, base_half_h, fallback_w, fallback_h)
    end

    local fw = tonumber(width) or tonumber(fallback_w) or 128
    local fh = tonumber(height) or tonumber(fallback_h) or fw
    if fw <= 0 then fw = tonumber(fallback_w) or 128 end
    if fh <= 0 then fh = tonumber(fallback_h) or fw end

    local base_hw = tonumber(base_half_w) or 64
    local base_hh = tonumber(base_half_h) or base_hw
    if base_hw <= 0 then base_hw = 64 end
    if base_hh <= 0 then base_hh = base_hw end

    local sx = fw / (base_hw * 2)
    local sy = fh / (base_hh * 2)
    return sx, sy, fw, fh
end

local function resolve_breakable_swap_extent(raw_value, snapped_extent, tile_extent)
    local extent = tonumber(raw_value)
    if not extent or extent <= 0 then
        return snapped_extent
    end

    local tile_size = tonumber(tile_extent) or 0
    if tile_size > 0 and snapped_extent > tile_size and math.abs(extent - tile_size) < 0.001 then
        return snapped_extent
    end

    return extent
end

local function sanitize_spawn_properties(props)
    if type(props) ~= "table" then
        return props
    end
    local out = {}
    for key, value in pairs(props) do
        -- Callers provide the script's scalar types. Text must remain text,
        -- including values such as "123" and "true" and authored whitespace.
        if type(value) ~= "table" then
            out[key] = value
        end
    end
    return out
end

local function create_factory_instance(factory_url, position, rotation, properties, scale)
    return pcall(factory.create, factory_url, position, rotation, sanitize_spawn_properties(properties), scale)
end

local function create_collection_instance(factory_url, position, rotation, properties, scale)
    return pcall(collectionfactory.create, factory_url, position, rotation, sanitize_spawn_properties(properties), scale)
end

local function parse_color_string(value)
    if type(value) ~= "string" then return nil end
    local s = value:gsub("%s+", "")
    if s == "" then return nil end
    if s:sub(1, 1) == "#" then
        local hex = s:sub(2)
        if #hex == 6 or #hex == 8 then
            local r = tonumber(hex:sub(1, 2), 16) or 0
            local g = tonumber(hex:sub(3, 4), 16) or 0
            local b = tonumber(hex:sub(5, 6), 16) or 0
            local a = 255
            if #hex == 8 then
                a = tonumber(hex:sub(7, 8), 16) or 255
            end
            return vmath.vector4(r / 255, g / 255, b / 255, a / 255)
        end
        return nil
    end
    if s:find(",") then
        local parts = {}
        for part in string.gmatch(s, "([^,]+)") do
            parts[#parts + 1] = tonumber(part)
        end
        if #parts >= 3 then
            local r, g, b = parts[1], parts[2], parts[3]
            local a = parts[4] or 1
            local max = math.max(r, g, b, a)
            if max and max > 1 then
                r, g, b, a = r / 255, g / 255, b / 255, a / 255
            end
            return vmath.vector4(r or 1, g or 1, b or 1, a or 1)
        end
    end
    return nil
end

local function non_empty_string(value)
    if value == nil then return nil end
    local s = tostring(value)
    if s:match("^%s*$") then
        return nil
    end
    return s
end

local DEFAULT_BOSS_TEMPLATE_NAME = "Boss Spawn"

local function resolve_boss_preset(props)
    if type(props) ~= "table" then
        return nil
    end
    return non_empty_string(props.boss_preset) or non_empty_string(props.boss_type)
end

local function resolve_boss_display_name(object, props, fallback_id)
    local explicit_name = type(props) == "table" and non_empty_string(props.boss_name) or nil
    if explicit_name then
        return explicit_name
    end

    local object_name = object and non_empty_string(object.name) or nil
    if object_name and object_name ~= DEFAULT_BOSS_TEMPLATE_NAME then
        return object_name
    end

    return fallback_id or "Boss"
end

local gate_types = {}
do
    gate_types = Util.require_config("developer.config.gate_types")
end

-- ============================================================================
-- GEOMETRY AND SPAWN HELPERS
-- ============================================================================
-- These helpers convert Tiled coordinates into Defold positions, normalize
-- rectangle sizing, and wrap factory calls with consistent diagnostics.

--- Safely get the properties table from a Tiled object (never returns nil).
local function get_props(object)
    if type(object) == "table" and type(object.properties) == "table" then
        return object.properties
    end
    return {}
end

--- Generate an object ID from properties, object name, or auto-generated fallback.
-- @param props     Properties table (from get_props)
-- @param id_key    Property key to look for (e.g. "gate_id", "save_id")
-- @param prefix    Fallback prefix (e.g. "gate", "save")
-- @param object    Tiled object (uses .name as second fallback)
-- @param room_id   Room identifier
-- @return string   Unique object ID
local function make_id(props, id_key, prefix, object, room_id)
    return non_empty_string(props[id_key])
        or non_empty_string(object.name)
        or string.format("%s_%s_%d", prefix, tostring(room_id), tonumber(object.id) or 0)
end

--- Compute world position for a point object (no centering).
-- @param object    Tiled object
-- @param room_id   Room identifier
-- @return world_x, world_y, pos (vmath.vector3)
local function world_point(object, room_id)
    local ox, oy = get_room_world_offset(room_id)
    local wx = (object.x or 0) + ox
    local wy = (object.y or 0) + oy
    return wx, wy, vmath.vector3(wx, wy, 0)
end

--- Compute centered world position for a rectangle object.
-- Uses CollisionBox.center_from_bottom_left when available.
-- @param object     Tiled object (must have .x, .y; .width/.height optional)
-- @param room_id    Room identifier
-- @param default_w  Fallback width if object has none (default = tile width)
-- @param default_h  Fallback height if object has none (default = default_w)
-- @return world_x, world_y, pos (vmath.vector3), width, height
local function world_rect(object, room_id, default_w, default_h)
    local ox, oy = get_room_world_offset(room_id)
    local tile = get_tile_settings()
    local tile_w = tonumber(tile and (tile.width or tile.tile_width or tile.size)) or 128
    local dw = tonumber(default_w) or tile_w
    local dh = tonumber(default_h) or dw
    local w = tonumber(object.width) or 0
    local h = tonumber(object.height) or 0
    if w <= 0 then w = dw end
    if h <= 0 then h = dh end
    local wx, wy
    if CollisionBox and CollisionBox.center_from_bottom_left then
        wx, wy = CollisionBox.center_from_bottom_left(
            (object.x or 0) + ox, (object.y or 0) + oy,
            w, h, w, h)
    else
        wx = (object.x or 0) + ox + (w * 0.5)
        wy = (object.y or 0) + oy + (h * 0.5)
    end
    return wx, wy, vmath.vector3(wx, wy, 0), w, h
end

--- Create a game object from a factory with standard error handling.
-- @param factory_name Factory component name (e.g. "gate_factory")
-- @param pos          Spawn position (vmath.vector3)
-- @param spawn_props  Properties table (will be sanitized by create_factory_instance)
-- @param scale        Scale: number, vmath.vector3, or nil (defaults to 1)
-- @param label        Handler label for error messages
-- @return instance_url or nil
local function spawn_factory(factory_name, pos, spawn_props, scale, label)
    local factory_url = msg.url("main:/room_manager#" .. factory_name)
    local ok, instance = create_factory_instance(factory_url, pos, nil, spawn_props, scale or 1)
    if not ok then
        print(string.format("[OBJECT_SPAWNER] Failed to create %s: %s",
            label or factory_name, tostring(instance)))
        return nil
    end
    return instance
end

--- Create game objects from a collection factory with standard error handling.
-- @param factory_name Factory component name (e.g. "enemy_factory")
-- @param pos          Spawn position (vmath.vector3)
-- @param spawn_props  Properties table
-- @param scale        Scale (defaults to 1)
-- @param label        Handler label for error messages
-- @return table of created instances, or nil on failure
local function spawn_collection(factory_name, pos, spawn_props, scale, label)
    local factory_url = msg.url("main:/room_manager#" .. factory_name)
    local ok, result = create_collection_instance(factory_url, pos, nil, spawn_props, scale or 1)
    if not ok then
        print(string.format("[OBJECT_SPAWNER] Failed to create %s: %s",
            label or factory_name, tostring(result)))
        return nil
    end
    return result
end

local function post_collectible_tiled_overrides(instance_url, collectible_type, collectible_id, room_id, props, extras)
    if not instance_url then
        return
    end

    props = type(props) == "table" and props or {}
    extras = type(extras) == "table" and extras or {}

    local message = {
        collectible_type = collectible_type,
        collectible_id = collectible_id,
        room_id = room_id,
    }

    local passthrough_keys = {
        "amount",
        "respawns",
        "show_popup",
        "item_id",
        "key_id",
        "lore_id",
        "lore_text",
        "relic_id",
        "relic_name",
        "relic_description",
        "area_id",
        "area_name",
        "reveal_radius",
        "ability_id",
        "sprite_atlas",
        "animation",
        "popup_title",
        "popup_description",
        "set_flag_on_collect",
    }

    for _, key in ipairs(passthrough_keys) do
        if props[key] ~= nil then
            message[key] = props[key]
        end
    end

    for key, value in pairs(extras) do
        if value ~= nil then
            message[key] = value
        end
    end

    msg.post(instance_url, hash("apply_tiled_overrides"), message)
end

--- Apply rect scale to an existing instance (post-creation).
-- Only modifies scale when the computed scale differs from 1.0.
-- @param instance      Game object URL
-- @param width         Actual width (pixels)
-- @param height        Actual height (pixels)
-- @param base_hw       Base half-width of the prefab collision
-- @param base_hh       Base half-height of the prefab collision
-- @param fallback_w    Fallback full width
-- @param fallback_h    Fallback full height
local function apply_scale(instance, width, height, base_hw, base_hh, fallback_w, fallback_h)
    if not instance then return end
    local sx, sy = rect_scale_from_size(width, height, base_hw, base_hh, fallback_w, fallback_h)
    if math.abs(sx - 1) > 0.001 or math.abs(sy - 1) > 0.001 then
        go.set_scale(vmath.vector3(sx, sy, 1), instance)
    end
end

--- Build a vmath.vector3 scale from rect dimensions.
-- @return vmath.vector3
local function make_scale(width, height, base_hw, base_hh, fallback_w, fallback_h)
    local sx, sy = rect_scale_from_size(width, height, base_hw, base_hh, fallback_w, fallback_h)
    return vmath.vector3(sx, sy, 1)
end

--- Send the apply_tiled_props message to an instance (safe, pcall-wrapped).
-- @param instance Game object URL
-- @param props    Properties table
local function send_tiled_props(instance, props)
    if instance and props then
        pcall(msg.post, instance, hash("apply_tiled_props"), { properties = props })
    end
end

--- Log a successful spawn.
-- @param type_label Handler/type name for the log
-- @param obj_id     Object identifier
-- @param x          World X position
-- @param y          World Y position
-- @param extra      Optional extra info string
local function log_spawn(type_label, obj_id, x, y, extra)
    local s = string.format("[OBJECT_SPAWNER] Spawned %s '%s' at (%.0f, %.0f)",
        type_label, tostring(obj_id), x, y)
    if extra then s = s .. " " .. extra end
    print(s)
end

--- Log a registration (for msg.post-based handlers that don't spawn a factory GO).
local function log_register(type_label, obj_id, x, y, extra)
    local s = string.format("[OBJECT_SPAWNER] Registered %s '%s' at (%.0f, %.0f)",
        type_label, tostring(obj_id), x, y)
    if extra then s = s .. " " .. extra end
    print(s)
end

local function fmt_diag_value(value)
    if value == nil then
        return "nil"
    end
    return tostring(value)
end

local function log_size_diag(stage, room_id, object, obj_type, extra)
    local resolved_type = obj_type or (object and object.type)
    if not SIZE_DEBUG_TYPES[resolved_type] then
        return
    end

    local s = string.format(
        "[OBJECT_SPAWNER] SIZE_DIAG stage=%s room=%s type=%s id=%s name='%s' x=%s y=%s w=%s h=%s point=%s",
        tostring(stage),
        tostring(room_id),
        tostring(resolved_type),
        fmt_diag_value(object and object.id),
        tostring(object and object.name or ""),
        fmt_diag_value(object and object.x),
        fmt_diag_value(object and object.y),
        fmt_diag_value(object and object.width),
        fmt_diag_value(object and object.height),
        tostring(object and (object.point or object.shape == "point") or false)
    )
    if extra and extra ~= "" then
        s = s .. " " .. extra
    end
    print(s)
end

--- Get a type string from properties, supporting both direct and Tiled metadata format.
-- Tiled metadata format: { Name="type_key", Type="string", Value="some_value" }
-- @param props     Properties table
-- @param type_key  Property key (e.g. "enemy_type", "collectible_type")
-- @param object    Tiled object (uses .name as fallback)
-- @return string or nil
local function get_type_prop(props, type_key, object)
    local value = props[type_key]
    if not value and props.Name == type_key then
        value = props.Value
    end
    if not value or value == "" then
        value = object.name
    end
    if not value or value == "" then
        return nil
    end
    return value
end

--- Object type to spawn handler mapping
-- You can register custom handlers for specific object types
M.handlers = {}

-- ============================================================================
-- HANDLER HELPERS (exposed for external handler modules)
-- ============================================================================
-- External handler category files (mvtk/tiled/spawner_handlers/*.lua) can use
-- these shared helpers via the context table passed to their register function.
-- Built lazily so all local functions are defined before first access.
M._helpers = nil

-- Forward declarations: get_helpers() (below) references these helpers before
-- their definitions further down. Without forward locals, those references bind
-- to globals (nil) at parse time, so the exported context table would carry nil
-- entries and split spawner modules would crash calling them.
local polyline_registry
local record_error, safe_delete_instance
local normalize_gate_type_name, normalize_gate_item_name
local parse_drops_string, resolve_chest_loot_table, resolve_difficulty_scaling

local function get_helpers()
  if not M._helpers then
    M._helpers = {
      M = M,
      Util = Util,
      TriggerPayloads = TriggerPayloads,
      CollectibleManager = CollectibleManager,
      EnemyManager = EnemyManager,
      TileSnap = TileSnap,
      get_spawner_service = get_spawner_service,
      get_gate_manager = get_gate_manager,
      gate_types = gate_types,
      get_room_manager = get_room_manager,
      get_boss_arena = get_boss_arena,
      get_chest_inline_registry = get_chest_inline_registry,
      get_tiled_object_config = get_tiled_object_config,
      get_point_y_offset = get_point_y_offset,
      get_tile_settings = get_tile_settings,
      get_room_world_offset = get_room_world_offset,
      to_bool = to_bool,
      normalize_object_type = normalize_object_type,
      ambient_component_name = ambient_component_name,
      infer_object_type = infer_object_type,
      resolve_object_type = resolve_object_type,
      resolve_rect_size_pixels = resolve_rect_size_pixels,
      rect_scale_from_size = rect_scale_from_size,
      resolve_breakable_swap_extent = resolve_breakable_swap_extent,
      sanitize_spawn_properties = sanitize_spawn_properties,
      create_factory_instance = create_factory_instance,
      create_collection_instance = create_collection_instance,
      parse_color_string = parse_color_string,
      non_empty_string = non_empty_string,
      resolve_boss_preset = resolve_boss_preset,
      resolve_boss_display_name = resolve_boss_display_name,
      get_props = get_props,
      make_id = make_id,
      world_point = world_point,
      world_rect = world_rect,
      spawn_factory = spawn_factory,
      spawn_collection = spawn_collection,
      post_collectible_tiled_overrides = post_collectible_tiled_overrides,
      apply_scale = apply_scale,
      make_scale = make_scale,
      send_tiled_props = send_tiled_props,
      log_spawn = log_spawn,
      log_register = log_register,
      log_size_diag = log_size_diag,
      get_type_prop = get_type_prop,
      record_error = record_error,
      safe_delete_instance = safe_delete_instance,
      normalize_gate_type_name = normalize_gate_type_name,
      normalize_gate_item_name = normalize_gate_item_name,
      parse_drops_string = parse_drops_string,
      resolve_chest_loot_table = resolve_chest_loot_table,
      resolve_difficulty_scaling = resolve_difficulty_scaling,
      print = print,
      polyline_registry = polyline_registry,
    }
  end
  return M._helpers
end

function M.get_handler_context()
  return get_helpers()
end

--- Load handler modules through the canonical registry.
function M.load_handler_modules()
  if M._registry_handlers_loaded then
    return true
  end
  SpawnerRegistry.install(M, get_helpers())
  return true
end

-- Track spawned objects per room
-- Structure: room_id -> { object_id -> { instance_id, type, spawn_id } }
local room_objects = {}  -- room_id -> { object_id -> instance_data }

-- Track validation/preflight errors (cleared per map load)
local last_errors = {}

-- Polyline registry for path references
-- Structure: room_id -> { polyline_name -> polyline_data }
polyline_registry = {}
local room_id_alias = {}

-- Current map height for coordinate conversion
local current_map_height = 0

-- ============================================================================
-- VALIDATION AND DIAGNOSTICS
-- ============================================================================
-- Errors collected here are preflight-friendly: callers can inspect them after
-- map processing without scraping log text.

function record_error(msg)
    print("[OBJECT_SPAWNER][ERROR] " .. tostring(msg))
    last_errors[#last_errors + 1] = tostring(msg)
end

local function levenshtein(a, b)
    if a == b then return 0 end
    local len_a, len_b = #a, #b
    if len_a == 0 then return len_b end
    if len_b == 0 then return len_a end

    local matrix = {}
    for i = 0, len_a do
        matrix[i] = {[0] = i}
    end
    for j = 0, len_b do
        matrix[0][j] = j
    end

    for i = 1, len_a do
        for j = 1, len_b do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            matrix[i][j] = math.min(
                matrix[i-1][j] + 1,       -- deletion
                matrix[i][j-1] + 1,       -- insertion
                matrix[i-1][j-1] + cost   -- substitution
            )
        end
    end
    return matrix[len_a][len_b]
end

function safe_delete_instance(instance_url, object_id, room_id)
    if not instance_url then return false end
    local label = string.format("object_id=%s room=%s", tostring(object_id), tostring(room_id))
    if type(instance_url) == "userdata" then
        local ok, err = pcall(function()
            if go.exists(instance_url) then
                go.delete(instance_url)
                return true
            end
            return false
        end)
        if not ok then
            record_error(string.format("Failed to delete instance (%s): %s", label, tostring(err)))
            return false
        end
        return err == true  -- err holds return value from pcall'd function
    elseif type(instance_url) == "string" then
        local ok, err = pcall(function()
            local url = msg.url(instance_url)
            if go.exists(url) then
                go.delete(url)
                return true
            end
            return false
        end)
        if not ok then
            record_error(string.format("Failed to delete instance (%s): %s", label, tostring(err)))
            return false
        end
        return err == true
    end
    return false
end

function normalize_gate_type_name(value)
    return Util.trim(value)
end

function normalize_gate_item_name(value)
    local item = Util.trim(value)
    if item == "" then
        return ""
    end
    return KeyIds.canonicalize(item) or item
end

-- Parse drops string from Tiled (e.g., "currency:5-10:0.9,gem:1:0.2")
-- Returns table keyed by drop_id with {min,max,chance}
function parse_drops_string(raw, context)
    if type(raw) ~= "string" or raw == "" then return nil end
    local drops = {}
    for token in raw:gmatch("[^,;]+") do
        local parts = {}
        for part in token:gmatch("[^:]+") do parts[#parts + 1] = Util.trim(part) end
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
        else
            record_error(string.format("Invalid drops token '%s'%s", tostring(token), context and (" (" .. context .. ")") or ""))
        end
    end
    if next(drops) == nil then return nil end
    return drops
end

local function looks_inline_contents(value)
    if type(value) ~= "string" then return false end
    return value:find(":", 1, true) or value:find(",", 1, true) or value:find(";", 1, true)
end

local function parse_inline_contents(raw)
    if type(raw) ~= "string" then return nil end
    local items = {}
    for token in raw:gmatch("[^,;]+") do
        local item, amount = token:match("^%s*([^:]+)%s*:%s*(%d+)%s*$")
        if not item then
            item = token:match("^%s*([^:]+)%s*$")
        end
        item = Util.trim(item)
        if item ~= "" then
            local qty = tonumber(amount) or 1
            items[#items + 1] = string.format("%s:%d", item, qty)
        end
    end
    if #items == 0 then
        return nil
    end
    return table.concat(items, ",")
end

function resolve_chest_loot_table(props)
    if not props then
        return "common"
    end
    local contents = OP.get(props, "contents")
    if type(contents) == "string" then
        contents = Util.trim(contents)
        if contents ~= "" then
            if looks_inline_contents(contents) then
                local normalized = parse_inline_contents(contents) or contents
                local registry = get_chest_inline_registry()
                if registry and registry.register_inline and normalized and normalized ~= "" then
                    registry.register_inline(normalized)
                end
                return normalized
            end
            return contents
        end
    end
    return "common"
end

local difficulty_profiles = nil
function resolve_difficulty_scaling(value)
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
            local cfg = Util.require_config("developer.config.difficulty_settings")
            difficulty_profiles = cfg.profiles or false
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

function M.clear_errors()
    last_errors = {}
end

function M.get_errors()
    return last_errors
end

-- ============================================================================
-- MAP PROCESSING AND HANDLER DISPATCH
-- ============================================================================
-- Default domain handlers are installed by mvtk.tiled.spawner_registry. This
-- module owns the shared dispatch path, object tracking, and cleanup lifecycle.

--- Register a custom object handler
-- @param object_type Type name (matches Tiled object "type" property)
-- @param handler Function(object, room_id) -> spawn_id
function M.register_handler(object_type, handler)
    M.handlers[object_type] = handler
    print("[OBJECT_SPAWNER] Registered handler for type:", object_type)
end

--- Spawn a single object
-- @param object Object data from Tiled
-- @param room_id ID of the room this object belongs to
-- @return Spawned instance ID or nil
function M.spawn_object(object, room_id)
    if not M._registry_handlers_loaded then
        pcall(M.load_handler_modules)
    end
    local resolved_type, type_source = normalize_and_resolve_object(object)
    if resolved_type then
        object.type = resolved_type
        if type_source ~= "explicit" then
            _orig_print(string.format("[OBJECT_SPAWNER] Inferred type '%s' for object id=%s name='%s'",
                tostring(resolved_type), tostring(object and object.id), tostring(object and object.name)))
        end
    end
    if not object or not object.type or object.type == "" then
        record_error("Object missing type/class property (id=" .. tostring(object and object.id) .. ")")
        return nil
    end

    log_size_diag("pre_convert", room_id, object, object.type, "coords=tiled")

    -- Convert Tiled coordinates to Defold coordinates
    -- Tiled uses top-left origin, Defold uses bottom-left
    if current_map_height > 0 then
        local defold_x, defold_y = TiledParser.tiled_to_defold(object.x, object.y, current_map_height)
        object.x = defold_x
        object.y = defold_y
        -- For rectangle/ellipse objects, Tiled y is top-left. Convert to bottom-left in Defold.
        -- Skip tile objects (gid) and polyline/polygon/point objects where y is an origin for points.
        local is_point = object.point or object.shape == "point"
        if not object.gid and not object.polyline and not object.polygon and not is_point then
            if (object.width or 0) > 0 and (object.height or 0) > 0 then
                object.y = object.y - object.height
            end
        end
        if is_point then
            -- Point objects are authored at their base; offset to match centered sprites.
            local y_offset = get_point_y_offset(object.type)
            if y_offset ~= 0 then
                object.y = object.y + y_offset
            end
        end
    end

    log_size_diag("post_convert", room_id, object, object.type, "coords=defold")

    -- DEBUG: Print full object structure
    print("[OBJECT_SPAWNER] ========== SPAWNING OBJECT ==========")
    print("[OBJECT_SPAWNER] ID:", object.id)
    print("[OBJECT_SPAWNER] Name:", object.name)
    print("[OBJECT_SPAWNER] Type:", object.type)
    print("[OBJECT_SPAWNER] Position (Defold):", object.x, object.y)
    print("[OBJECT_SPAWNER] Properties:")
    if object.properties then
        for k, v in pairs(object.properties) do
            print(string.format("[OBJECT_SPAWNER]   %s = %s (type: %s)", tostring(k), tostring(v), type(v)))
        end
    else
        print("[OBJECT_SPAWNER]   (no properties)")
    end
    print("[OBJECT_SPAWNER] ===================================")

    -- Check visibility
    if object.visible == false then
        print("[OBJECT_SPAWNER] Skipping invisible object:", object.id)
        return nil
    end

    -- Explain retired map objects through the existing missing-handler path.
    if RetiredTypes.is_object_type(object.type) then
        _orig_print("[OBJECT_SPAWNER][WARNING] " .. RetiredTypes.warning(object, room_id))
        return nil
    end

    if object.type == "gate" then
        local warning = RetiredTypes.required_ability_warning(object, room_id, (object.properties or {}).required_ability)
        if warning then _orig_print("[OBJECT_SPAWNER][WARNING] " .. warning) end
    end

    -- Find handler for this object type
    local handler = M.handlers[object.type]
    if not handler then
        local available = {}
        for k in pairs(M.handlers) do available[#available + 1] = k end
        table.sort(available)

        -- Fuzzy suggestion
        local best, best_dist = nil, math.huge
        for _, candidate in ipairs(available) do
            local d = levenshtein(tostring(object.type), candidate)
            if d < best_dist then
                best_dist = d
                best = candidate
            end
        end

        local suggestion = ""
        if best and best_dist <= 3 then
            suggestion = string.format(" Did you mean '%s'?", best)
        end

        record_error(string.format("No handler for object type '%s' (id=%s).%s", tostring(object.type), tostring(object.id), suggestion))
        print("[OBJECT_SPAWNER] Available handlers:", table.concat(available, ", "))
        return nil
    end

    -- Call handler
    local success, result = pcall(handler, object, room_id)
    if not success then
        print("[OBJECT_SPAWNER] Handler error:", result)
        return nil
    end

    -- Track spawned object with extended metadata
    -- Handler may return either:
    --   1. A simple value (legacy: spawn_id or instance_url)
    --   2. A table with { spawn_id, instance_url } for proper cleanup
    room_objects[room_id] = room_objects[room_id] or {}
    
    local spawn_id, instance_url
    if type(result) == "table" and result.spawn_id then
        -- New format: separate spawn_id and instance_url
        spawn_id = result.spawn_id
        instance_url = result.instance_url
    else
        -- Legacy format: single value (could be either spawn_id or instance_url)
        spawn_id = result
        instance_url = result
    end
    
    room_objects[room_id][object.id] = {
        instance_id = instance_url,  -- Game object URL for deletion
        instance_url = instance_url, -- Explicit field for clarity
        object_type = object.type,
        spawn_id = spawn_id,  -- Data ID for manager notifications
    }

    return result
end

--- Spawn all objects from a Tiled object layer
-- @param objects Array of object data from Tiled
-- @param room_id ID of the room
-- @param filter_type Optional: only spawn objects of this type
-- @param ignore_types Optional: table set of object types to skip (type -> true)
-- @return Number of objects spawned
function M.spawn_from_layer(objects, room_id, filter_type, ignore_types)
    if not objects or #objects == 0 then
        print("[OBJECT_SPAWNER] No objects to spawn")
        return 0
    end

    local spawned_count = 0
    local ignored_by_type = {}

    for _, object in ipairs(objects) do
        local obj_type, _ = normalize_and_resolve_object(object)
        if object and obj_type then
            object.type = obj_type
        end
        local skip = ignore_types and obj_type and ignore_types[obj_type]
        if not skip then
            -- Check type filter
            if not filter_type or obj_type == filter_type then
                log_size_diag("queue", room_id, object, obj_type, "reason=spawn")
                local result = M.spawn_object(object, room_id)
                if result then
                    spawned_count = spawned_count + 1
                end
            end
        elseif obj_type then
            ignored_by_type[obj_type] = (ignored_by_type[obj_type] or 0) + 1
            log_size_diag("skip", room_id, object, obj_type, "reason=ignore_types")
        end
    end

    if next(ignored_by_type) then
        local parts = {}
        for obj_type, count in pairs(ignored_by_type) do
            parts[#parts + 1] = string.format("%s x%d", obj_type, count)
        end
        table.sort(parts)
        print(string.format("[OBJECT_SPAWNER] Ignored %s in room '%s' (baked at build time / skip_spawn)",
            table.concat(parts, ", "), room_id))
    end

    print(string.format("[OBJECT_SPAWNER] Spawned %d objects in room '%s'", spawned_count, room_id))
    return spawned_count
end

--- Process all object layers from a Tiled map
-- @param tiled_map Loaded Tiled map data
-- @param room_id ID of the room
-- @param layer_filter Optional: only process layers with this name
-- @param options Optional: table with { ignore_types = { [type] = true } }
-- @return Number of objects spawned
function M.process_map(tiled_map, room_id, layer_filter, options)
    if not tiled_map or not tiled_map.layers then
        print("[OBJECT_SPAWNER] Invalid map data")
        return 0
    end

    M.clear_errors()

    -- Load external handler modules on first map process
    if not M._external_handlers_loaded then
        M._external_handlers_loaded = true
        pcall(M.load_handler_modules)
    end

    -- Store map height for coordinate conversion
    current_map_height = (tiled_map.height or 0) * (tiled_map.tileheight or 0)
    print("[OBJECT_SPAWNER] Map height for coordinate conversion:", current_map_height)

    -- Pre-register polylines for path references
    M.register_polylines_from_map(tiled_map, room_id)
    M.detect_polyline_cycles(room_id)

    print("[OBJECT_SPAWNER] ========== PROCESSING MAP ==========")
    print("[OBJECT_SPAWNER] Room ID:", room_id)
    print("[OBJECT_SPAWNER] Total layers:", #tiled_map.layers)
    print("[OBJECT_SPAWNER] Layer filter:", layer_filter or "none")

    local total_spawned = 0
    local object_layer_count = 0

    local ignore_types = options and options.ignore_types or nil

    for i, layer in ipairs(tiled_map.layers) do
        print(string.format("[OBJECT_SPAWNER] Layer %d: name='%s' type='%s'", i, layer.name or "?", layer.type or "?"))

        if layer.type == "objectgroup" then
            object_layer_count = object_layer_count + 1
            local num_objects = layer.objects and #layer.objects or 0
            print(string.format("[OBJECT_SPAWNER]   -> Object layer found! Contains %d objects", num_objects))

            -- Check layer filter
            if not layer_filter or layer.name == layer_filter then
                print("[OBJECT_SPAWNER]   -> Processing objects...")
                local count = M.spawn_from_layer(layer.objects, room_id, nil, ignore_types)
                total_spawned = total_spawned + count
            else
                print("[OBJECT_SPAWNER]   -> Skipped (layer filter mismatch)")
            end
        end
    end

    print(string.format("[OBJECT_SPAWNER] Found %d object layers, spawned %d total objects", object_layer_count, total_spawned))
    print("[OBJECT_SPAWNER] =====================================")

    return total_spawned
end

--- Register a polyline object for path references
-- @param room_id Room identifier
-- @param polyline_name Name or ID of the polyline
-- @param polyline_object Tiled polyline object data
function M.register_polyline(room_id, polyline_name, polyline_object)
    if not room_id or not polyline_name or not polyline_object then return end
    
    polyline_registry[room_id] = polyline_registry[room_id] or {}
    local bucket = polyline_registry[room_id]
    bucket[polyline_name] = polyline_object
    if type(polyline_name) == "string" and polyline_name ~= "" then
        bucket[hash(polyline_name)] = polyline_object
    end

    if type(room_id) == "string" and room_id ~= "" then
        polyline_registry[hash(room_id)] = bucket
        room_id_alias[hash(room_id)] = room_id
    end
    
    print(string.format("[OBJECT_SPAWNER] Registered polyline '%s' in room '%s'", polyline_name, room_id))
end

--- Get a polyline object by name/ID
-- @param room_id Room identifier
-- @param polyline_name Name or ID of the polyline
-- @return Polyline object data or nil
function M.get_polyline(room_id, polyline_name)
    if not polyline_registry[room_id] then return nil end
    return polyline_registry[room_id][polyline_name]
end

--- Resolve hashed room_id back to string when available
function M.get_room_id_string(room_id)
    if type(room_id) == "string" then
        return room_id
    end
    return room_id_alias[room_id]
end

--- Pre-process map to register polyline objects
-- Should be called before spawning other objects
-- @param tiled_map Loaded Tiled map data
-- @param room_id Room identifier
function M.register_polylines_from_map(tiled_map, room_id)
    if not tiled_map or not tiled_map.layers then return end

    if type(room_id) == "string" and room_id ~= "" then
        room_id_alias[hash(room_id)] = room_id
    end
    
    local count = 0
    for _, layer in ipairs(tiled_map.layers) do
        if layer.type == "objectgroup" and layer.objects then
            for _, object in ipairs(layer.objects) do
                -- Register polylines and polygons by name for reference
                if (object.polyline or object.polygon) and object.name and object.name ~= "" then
                    -- Convert coordinates if needed
                    if current_map_height > 0 then
                        local defold_x, defold_y = TiledParser.tiled_to_defold(object.x, object.y, current_map_height)
                        object.x = defold_x
                        object.y = defold_y
                    end
                    
                    M.register_polyline(room_id, object.name, object)
                    count = count + 1
                end
            end
        end
    end
    
    if count > 0 then
        print(string.format("[OBJECT_SPAWNER] Registered %d polylines for room '%s'", count, room_id))
    end
end

-- Detect circular path references via polyline properties.path_id
function M.detect_polyline_cycles(room_id)
    local registry = polyline_registry[room_id]
    if not registry then return end

    local visiting, visited = {}, {}

    local function dfs(name, path)
        if visiting[name] then
            record_error(string.format("Circular polyline reference detected in room '%s': %s -> %s", tostring(room_id), table.concat(path, " -> "), name))
            return
        end
        if visited[name] then return end
        visiting[name] = true
        path[#path + 1] = name

        local obj = registry[name]
        local next_id = obj and obj.properties and obj.properties.path_id
        if next_id and registry[next_id] then
            dfs(next_id, path)
        end

        visiting[name] = nil
        visited[name] = true
        path[#path] = nil
    end

    for name, _ in pairs(registry) do
        dfs(name, {})
    end
end

--- Clear all spawned objects for a room
-- @param room_id ID of the room
function M.clear_room(room_id)
    if not room_objects[room_id] then return end

    local count = 0
    local enemies_cleared = {}
    local collectibles_cleared = {}
    local gates_cleared = {}
    
    for object_id, spawn_data in pairs(room_objects[room_id]) do
        local instance_url = spawn_data.instance_url or spawn_data.instance_id
        local object_type = spawn_data.object_type
        local spawn_id = spawn_data.spawn_id
        
        -- Track what we're clearing for manager notifications
        if object_type == "enemy" and spawn_id then
            table.insert(enemies_cleared, spawn_id)
        elseif object_type == "collectible" or object_type == "ability" then
            if spawn_id then
                table.insert(collectibles_cleared, spawn_id)
            end
        elseif object_type == "gate" and spawn_id then
            table.insert(gates_cleared, spawn_id)
        end
        
        -- Delete the actual game object if it exists (with error logging on malformed URLs)
        if instance_url then
            local deleted = safe_delete_instance(instance_url, object_id, room_id)
            if deleted then
                count = count + 1
            end
        end
    end

    -- Notify EnemyManager to clean up enemy data
    if #enemies_cleared > 0 then
        for _, enemy_id in ipairs(enemies_cleared) do
            pcall(EnemyManager.unregister_enemy_instance, enemy_id)
        end
        print(string.format("[OBJECT_SPAWNER] Notified EnemyManager to unload %d enemies from room '%s'", #enemies_cleared, room_id))
    end
    
    -- Notify CollectibleManager to clean up collectible data
    if #collectibles_cleared > 0 then
        pcall(CollectibleManager.unload_room, room_id)
        print(string.format("[OBJECT_SPAWNER] Notified CollectibleManager to unload room '%s'", room_id))
    end

    if #gates_cleared > 0 then
        local gm = get_gate_manager()
        if gm then
            for _, gate_id in ipairs(gates_cleared) do
                if gm.despawn_gate then
                    pcall(gm.despawn_gate, gate_id)
                elseif gm.unregister_gate_instance then
                    pcall(gm.unregister_gate_instance, gate_id)
                end
            end
        end
        print(string.format("[OBJECT_SPAWNER] Notified GateManager to unload %d gates from room '%s'", #gates_cleared, room_id))
    end

    room_objects[room_id] = nil
    polyline_registry[room_id] = nil  -- Also clear polylines
    room_id_alias[room_id] = nil
    if type(room_id) == "string" and room_id ~= "" then
        room_id_alias[hash(room_id)] = nil
    end
    print(string.format("[OBJECT_SPAWNER] Cleared %d objects from room '%s'", count, room_id))
end

--- Clear all spawned objects
function M.clear_all()
    for room_id, _ in pairs(room_objects) do
        M.clear_room(room_id)
    end
    print("[OBJECT_SPAWNER] Cleared all objects")
end

--- Get spawned objects for a room
-- @param room_id ID of the room
-- @return Table of object_id -> instance_id
function M.get_room_objects(room_id)
    return room_objects[room_id] or {}
end

--- Helper: Convert Tiled Y coordinate to Defold Y coordinate
-- Tiled uses top-left origin, Defold uses bottom-left
-- @param tiled_y Y position from Tiled
-- @param map_height Total height of the map in pixels
-- @return Defold Y coordinate
function M.convert_y(tiled_y, map_height)
    return map_height - tiled_y
end

--- Debug: Print all registered handlers
function M.debug_print_handlers()
    print("[OBJECT_SPAWNER] Registered handlers:")
    for object_type, _ in pairs(M.handlers) do
        print("  -", object_type)
    end
end

return M

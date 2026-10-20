-- editor_generators.lua
-- Part 2 of the editor hook scripts (loaded after editor_script.lua).
-- Contains gen_collection() - the main room collection generator.
--
-- All shared state is read from hooks.core.context, populated by
-- editor_core.lua and editor_script.lua.

local Context = require "hooks.core.context"
local OP = require "mvtk.tiled.object_props"
local Validation = require "hooks.core.validation"
local EnemySkinSync = require "mvtk.enemies.enemy_skin_sync"
local EnemyTypeOverlay = require "mvtk.enemies.enemy_type_overlay"
local EnemyOverrides = require "mvtk.enemies.enemy_overrides"
local PropertyFlattener = require "mvtk.tiled.property_flattener"
local BossFeedbackSettings = require "mvtk.bosses.feedback_settings"
local _C = Context.require_context("hooks/editor_generators.lua")

-- Keep these helpers on the shared context: gen_collection is already at Lua
-- 5.1's direct-upvalue ceiling, while the context itself is an existing
-- upvalue used throughout the function.
_C.RetiredTypes = require "mvtk.tiled.retired_types"
_C.ElevatorManifest = require "hooks.core.elevator_manifest"
_C.ElevatorResources = require "hooks.core.elevator_resources"
_C.ElevatorConfig = require "hooks.core.elevator_config"
_C.ElevatorContract = require "mvtk.elevators.elevator_contract"
_C.PlatformResources = require "hooks.core.platform_resources"
_C.ParallaxBake = require "hooks.core.parallax_bake"
_C.GrappleLayerBake = require "hooks.core.grapple_layer_bake"
_C.GrappleObjectBake = require "hooks.core.grapple_object_bake"

-- High-frequency symbols from editor_core.lua
local normalize = _C.normalize
local editor_api = _C.editor_api
local HEADLESS = _C.HEADLESS
local info = _C.info
local ROOT = _C.ROOT
local DIR_SEP = _C.DIR_SEP
local to_os_path = _C.to_os_path
local PATH = _C.PATH
local TileSnap = _C.TileSnap
local CollisionBox = _C.CollisionBox
local lfs_ok = _C.lfs_ok
local lfs = _C.lfs
local TILED_CONFIG = _C.TILED_CONFIG
local join = _C.join
local ensure_dir = _C.ensure_dir
local copy_file_basic = _C.copy_file_basic
local copy_directory_filesystem = _C.copy_directory_filesystem
local list_dir_filesystem = _C.list_dir_filesystem
local read_text = _C.read_text
local file_exists = _C.file_exists
local file_exists_any = _C.file_exists_any
local read_binary_any = _C.read_binary_any
local write_if_changed = _C.write_if_changed
local resolve_tilesource_collision_resource = _C.resolve_tilesource_collision_resource
local fmt_num = _C.fmt_num
local get_prop_value = _C.get_prop_value
local get_tiled_property = _C.get_tiled_property
local load_tiled_export = _C.load_tiled_export
local list_room_ids = _C.list_room_ids
local path_dirname = _C.path_dirname
local path_basename = _C.path_basename
local sanitize_asset_name = _C.sanitize_asset_name
local resolve_source_file = _C.resolve_source_file
local resolve_half_extents = _C.resolve_half_extents
local sprite_scale_from_base = _C.sprite_scale_from_base
local tiled_image_layer_to_defold_pos = _C.tiled_image_layer_to_defold_pos
local resolve_object_type = _C.resolve_object_type
local is_background_visual_object_candidate = _C.is_background_visual_object_candidate
local update_all_tilemap_tilesources = _C.update_all_tilemap_tilesources
local get_selected_tilemap_ids = _C.get_selected_tilemap_ids
local prepare_export_game_project = _C.prepare_export_game_project
local gen_level_go = _C.gen_level_go
local gen_pushable_block_go = _C.gen_pushable_block_go
local gen_hazard_zone_go = _C.gen_hazard_zone_go
local gen_ladder_go = _C.gen_ladder_go
local sanitize_collision_group_text = _C.sanitize_collision_group_text
local run_validate_all = _C.run_validate_all
local sync_tilesheet_images = _C.sync_tilesheet_images
local delete_all_room_files = _C.delete_all_room_files
local remove_path_filesystem = _C.remove_path_filesystem
local profiler = _C.profiler

-- Symbols from editor_script.lua (stored in hooks.core.context at end of that file)
local _visual = _C.visual_helpers
local gen_one_way_platform_go = _C.gen_one_way_platform_go
local gen_pressure_plate_go = _C.gen_pressure_plate_go
local gen_torch_holder_go = _C.gen_torch_holder_go
local gen_gate_go = _C.gen_gate_go
local gen_breakable_wall_go = _C.gen_breakable_wall_go
local gen_teleporter_go = _C.gen_teleporter_go
local gen_water_volume_go = _C.gen_water_volume_go
local gen_bounce_pad_go = _C.gen_bounce_pad_go
local gen_collision_zone_go = _C.gen_collision_zone_go
local gen_checkpoint_go = _C.gen_checkpoint_go
local gen_screen_effect_zone_go = _C.gen_screen_effect_zone_go
local flatten_tiled_layers = _C.flatten_tiled_layers
local collect_room_background_sprite_components = _C.collect_room_background_sprite_components
local get_room_background_atlas_paths = _C.get_room_background_atlas_paths
local proto_escape = _C.proto_escape
local bool_to_proto = _C.bool_to_proto
local number_to_proto = _C.number_to_proto
local object_rect_center = _C.object_rect_center
local resolve_rect_size_pixels = _C.resolve_rect_size_pixels
local scale_from_full_size = _C.scale_from_full_size
local resolve_breakable_swap_extent = _C.resolve_breakable_swap_extent
local rect_center_and_scale = _C.rect_center_and_scale
local snapped_rect_center_and_scale = _C.snapped_rect_center_and_scale
local gen_sized_rect_instance_go = _C.gen_sized_rect_instance_go
local append_component_properties = _C.append_component_properties
local add_prefab_instance = _C.add_prefab_instance
local text_prop = _C.text_prop
local static_dialogue_exists = _C.static_dialogue_exists
local collectible_type_exists = _C.collectible_type_exists
local bool_prop = _C.bool_prop
local number_prop = _C.number_prop
local Prop = { text = text_prop, number = number_prop, bool = bool_prop }
local normalize_string_enum = _C.normalize_string_enum
local build_tiled_loader_props = _C.build_tiled_loader_props
local add_rect_prefab_instance = _C.add_rect_prefab_instance
local generated_object_id = _C.generated_object_id
local ensure_pushable_bake_context = _C.ensure_pushable_bake_context
local bake_pushable_chunk_tilemap = _C.bake_pushable_chunk_tilemap
local flush_pushable_bake_context = _C.flush_pushable_bake_context
local standardize_tilesource_collision_setup = _C.standardize_tilesource_collision_setup

local function load_project_lua_table(rel_path)
    local abs = join(ROOT, rel_path)
    local text = read_text(abs)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local load_fn = loadstring or load
    if type(load_fn) ~= "function" then
        return nil
    end
    local chunk = load_fn(text, "@" .. rel_path)
    if not chunk then
        return nil
    end
    local ok, result = pcall(chunk)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

-- gen_collection already sits at Lua 5.1's 60-upvalue limit. Expose this
-- loader through the context so it can refresh content config without adding
-- another direct upvalue to that function.
_C.load_project_lua_table = load_project_lua_table

local function resolve_enemy_prefab_skin(enemy_type, exported_skin)
    local manifest = load_project_lua_table("developer/config/enemy_skins_generated.lua") or { skins = {} }
    local skins = type(manifest.skins) == "table" and manifest.skins or {}
    local instance_skin = EnemySkinSync.normalize_skin_id(exported_skin)
    if instance_skin and skins[instance_skin] ~= nil then
        return instance_skin
    end
    local requested_type = EnemySkinSync.normalize_skin_id(enemy_type)
    local enemy_types = load_project_lua_table("developer/config/enemy_types.lua") or {}
    local cfg = nil
    if requested_type then
        cfg = EnemyTypeOverlay.resolve(requested_type, enemy_types, manifest)
    end
    if type(cfg) == "table" then
        local resolved = EnemySkinSync.resolve_active_skin_id(cfg.skin, manifest, EnemySkinSync.DEFAULT_SKIN)
        if resolved then
            return resolved
        end
    end

    local fallback = EnemySkinSync.resolve_active_skin_id(nil, manifest, EnemySkinSync.DEFAULT_SKIN)
    return fallback or EnemySkinSync.DEFAULT_SKIN
end

local function write_sized_rect_generated_go(target_path, source_resource, full_w, full_h, base_half_w, base_half_h, fallback_w, fallback_h, options)
    local source_text = read_text(source_resource)
    if type(source_text) ~= "string" or source_text == "" then
        return nil, string.format("source prefab empty: %s", tostring(source_resource))
    end

    local sized_text, err = gen_sized_rect_instance_go(
        source_text,
        full_w,
        full_h,
        base_half_w,
        base_half_h,
        fallback_w,
        fallback_h,
        options
    )
    if not sized_text then
        return nil, err
    end

    local changed = write_if_changed(target_path, sized_text)
    return true, changed
end
_C.write_sized_rect_generated_go = write_sized_rect_generated_go

local AuthoredProxy = (function()
    local M = {}

    local OPTIONAL_BOSS_SPAWN_TEXT_FIELDS = {
        music_track = true,
        victory_music = true,
    }
    local OPTIONAL_BOSS_PHASE_TEXT_FIELDS = {
        transition_new_music = true,
    }

    local function optional_id(value)
        if value == nil then return "" end
        local text = tostring(value):match("^%s*(.-)%s*$")
        if text == "" or string.lower(text) == "none" then return "" end
        return value
    end

    local function append_text_props_from_object(props, obj, field_ids, optional_fields)
        for _, field_id in ipairs(field_ids) do
            local value = get_prop_value(obj, field_id)
            if value == nil then value = BossFeedbackSettings.defaults[field_id] end
            if optional_fields and optional_fields[field_id] then
                value = optional_id(value)
            end
            props[#props + 1] = text_prop(field_id, value or "")
        end
    end

    local function infer_boss_visual_type(component_id)
        if type(component_id) ~= "string" or component_id == "" then
            return nil
        end
        local lower = string.lower(component_id)
        if string.match(lower, "^spine") then
            return "spine"
        end
        if string.match(lower, "^sprite") then
            return "sprite"
        end
        return nil
    end

    local DEFAULT_BOSS_TEMPLATE_NAME = "Boss Spawn"

    local function append_boss_spawn_text_props_from_object(props, obj, field_ids, room_id)
        append_text_props_from_object(props, obj, field_ids, OPTIONAL_BOSS_SPAWN_TEXT_FIELDS)

        local boss_preset = OP.get_via(get_prop_value, obj, "boss_preset", "")
        if boss_preset == nil or tostring(boss_preset) == "" or tostring(boss_preset) == "none" then
            boss_preset = OP.get_via(get_prop_value, obj, "boss_type", "")
        end
        local boss_name = obj.name or ""
        if boss_name == DEFAULT_BOSS_TEMPLATE_NAME then
            boss_name = ""
        end
        local visual_type = get_prop_value(obj, "boss_visual_type") or ""
        local visual_component = get_prop_value(obj, "visual_component") or ""
        if visual_type == "" then
            visual_type = infer_boss_visual_type(visual_component) or ""
        end
        if visual_type == "spine" then
            require("hooks.spine_addon").require_on({root=ROOT,read=read_text},
                "developer/assets/tiled/maps/" .. tostring(room_id) .. ".lua (boss object " .. tostring(obj.id) .. ")")
        end

        props[#props + 1] = text_prop("boss_preset", boss_preset)
        props[#props + 1] = text_prop("boss_type", boss_preset)
        props[#props + 1] = text_prop("boss_name", boss_name)
        props[#props + 1] = text_prop("boss_visual_type", visual_type or "")
        props[#props + 1] = text_prop("visual_component", visual_component or "")
    end

    local function append_number_props_from_object(props, obj, field_defaults)
        for _, spec in ipairs(field_defaults) do
            props[#props + 1] = number_prop(spec[1], get_prop_value(obj, spec[1]), spec[2])
        end
    end

    local function append_bool_props_from_object(props, obj, field_defaults)
        for _, spec in ipairs(field_defaults) do
            props[#props + 1] = bool_prop(spec[1], get_prop_value(obj, spec[1]), spec[2])
        end
    end

    local boss_spawn_text_fields = {
        "boss_id",
        "boss_tag",
        "phase_config",
        "attack_pattern_ids",
        "arena_id",
        "intro_cutscene",
        "defeat_flag",
        "health_bar_position",
        "music_track",
        "victory_music",
        "reward_drops",
        "reward_loot_table",
        "reward_unlock_flag",
        "reward_unlock_fast_travel",
        "intro_animation",
    }

    local boss_spawn_number_fields = {
        { "max_health", 0 },
        { "defense", 0 },
        { "damage_resistance", 0 },
        -- Per-instance movement/charge tuning. A negative value means the
        -- selected boss preset / attack pattern remains authoritative.
        { "chase_speed", -1 },
        { "charge_speed", -1 },
        { "charge_distance", -1 },
        { "charge_telegraph_time", -1 },
        { "charge_duration", -1 },
        { "charge_cooldown", -1 },
        { "charge_recovery", -1 },
        { "reward_currency_min", 0 },
        { "reward_currency_max", 0 },
        -- Contact damage (body collision)
        { "contact_damage", 0 },
        { "contact_knockback_x", -1 },
        { "contact_knockback_y", -1 },
        { "contact_stun_t", -1 },
    }

    local boss_spawn_bool_fields = {
        { "arena_lock", true },
        { "show_health_bar", true },
    }

    for _, field in ipairs(BossFeedbackSettings.hash_fields) do
        boss_spawn_text_fields[#boss_spawn_text_fields + 1] = field
    end
    for _, field in ipairs(BossFeedbackSettings.number_fields) do
        boss_spawn_number_fields[#boss_spawn_number_fields + 1] = { field, BossFeedbackSettings.defaults[field] }
    end
    for _, field in ipairs(BossFeedbackSettings.bool_fields) do
        boss_spawn_bool_fields[#boss_spawn_bool_fields + 1] = { field, BossFeedbackSettings.defaults[field] }
    end

    local boss_phase_text_fields = {
        "phase_id",
        "boss_id",
        "arena_id",
        "attacks",
        "behavior",
        "transition_type",
        "transition_animation",
        "transition_spawn_hazards",
        "transition_teleport_to",
        "transition_new_music",
        -- Movement profile (see mvtk/bosses/movement_strategies.lua)
        "movement_profile",
    }

    local boss_phase_number_fields = {
        { "phase", 1 },
        { "health_min", -1 },
        { "health_max", -1 },
        { "attack_interval_min", 2 },
        { "attack_interval_max", 4 },
        -- Phase-local overrides use the same -1 inheritance contract as the
        -- boss object. This lets a later phase accelerate only its charge.
        { "chase_speed", -1 },
        { "charge_speed", -1 },
        { "charge_distance", -1 },
        { "charge_telegraph_time", -1 },
        { "charge_duration", -1 },
        { "charge_cooldown", -1 },
        { "charge_recovery", -1 },
        { "speed_multiplier", 1 },
        { "damage_multiplier", 1 },
        { "transition_duration", 0 },
        { "transition_iframes", 0 },
        { "transition_camera_intensity", 0 },
        { "transition_camera_duration", 0 },
        -- Movement profile numeric knobs
        { "hover_height", 0 },
        { "jump_height", 0 },
        { "jump_speed", 0 },
        { "leash_radius", 0 },
        { "attack_range", 0 },
    }

    local boss_phase_bool_fields = {
        { "transition_flash", false },
        { "transition_arena_darkness", false },
        { "facing_lock", false },
    }

    function M.build_spawn_point_marker_props(obj, room_id, registration_id)
        local is_default = get_prop_value(obj, "is_default")
        if is_default == nil then
            is_default = get_prop_value(obj, "default")
        end
        return {
            text_prop("registration_id", registration_id),
            text_prop("spawn_name", obj.name or "Spawn Point"),
            text_prop("spawn_type", get_prop_value(obj, "spawn_type") or "player"),
            number_prop("facing", get_prop_value(obj, "facing"), 1),
            bool_prop("is_default", is_default, false),
            text_prop("checkpoint_id", get_prop_value(obj, "checkpoint_id") or ""),
            text_prop("room_id", room_id),
        }
    end

    function M.build_boss_spawn_marker_props(obj, room_id, registration_id)
        local props = {
            text_prop("registration_id", registration_id),
            number_prop("object_id", obj.id, 0),
            text_prop("room_id", room_id),
        }
        append_boss_spawn_text_props_from_object(props, obj, boss_spawn_text_fields, room_id)
        append_number_props_from_object(props, obj, boss_spawn_number_fields)
        append_bool_props_from_object(props, obj, boss_spawn_bool_fields)
        return props
    end

    function M.build_boss_phase_marker_props(obj, room_id, registration_id)
        local boss_preset = OP.get_via(get_prop_value, obj, "boss_preset", "")
        if boss_preset == nil or tostring(boss_preset) == "" or tostring(boss_preset) == "none" then
            boss_preset = OP.get_via(get_prop_value, obj, "boss_type", "")
        end
        local props = {
            text_prop("registration_id", registration_id),
            number_prop("object_id", obj.id, 0),
            text_prop("room_id", room_id),
            text_prop("boss_preset", boss_preset),
            text_prop("boss_type", boss_preset),
        }
        append_text_props_from_object(props, obj, boss_phase_text_fields, OPTIONAL_BOSS_PHASE_TEXT_FIELDS)
        append_number_props_from_object(props, obj, boss_phase_number_fields)
        append_bool_props_from_object(props, obj, boss_phase_bool_fields)
        return props
    end

    function M.build_boss_arena_marker_props(obj, room_id, registration_id, width, height)
        local boss_preset = OP.get_via(get_prop_value, obj, "boss_preset", "")
        if boss_preset == nil or tostring(boss_preset) == "" or tostring(boss_preset) == "none" then
            boss_preset = OP.get_via(get_prop_value, obj, "boss_type", "")
        end
        return {
            text_prop("registration_id", registration_id),
            number_prop("object_id", obj.id, 0),
            text_prop("arena_id", get_prop_value(obj, "arena_id") or ""),
            text_prop("boss_id", get_prop_value(obj, "boss_id") or ""),
            text_prop("boss_preset", boss_preset),
            text_prop("boss_type", boss_preset),
            text_prop("battle_music", optional_id(get_prop_value(obj, "battle_music"))),
            text_prop("victory_music", optional_id(get_prop_value(obj, "victory_music"))),
            bool_prop("is_boss_arena", get_prop_value(obj, "is_boss_arena"), true),
            bool_prop("lock_on_enter", get_prop_value(obj, "lock_on_enter"), true),
            bool_prop("unlock_on_clear", get_prop_value(obj, "unlock_on_clear"), true),
            bool_prop("camera_lock", get_prop_value(obj, "camera_lock"), false),
            number_prop("camera_priority", get_prop_value(obj, "camera_priority"), 10),
            number_prop("phases", get_prop_value(obj, "phases"), 1),
            number_prop("charge_edge_padding", get_prop_value(obj, "charge_edge_padding"), -1),
            number_prop("zone_width", width, 1024),
            number_prop("zone_height", height, 768),
            text_prop("room_id", room_id),
        }
    end

    function M.build_arena_lock_marker_props(obj, room_id, registration_id, width, height)
        local boss_preset = OP.get_via(get_prop_value, obj, "boss_preset", "")
        if boss_preset == nil or tostring(boss_preset) == "" or tostring(boss_preset) == "none" then
            boss_preset = OP.get_via(get_prop_value, obj, "boss_type", "")
        end
        return {
            text_prop("registration_id", registration_id),
            text_prop("arena_id", get_prop_value(obj, "arena_id") or ""),
            text_prop("boss_id", get_prop_value(obj, "boss_id") or ""),
            text_prop("boss_preset", boss_preset),
            text_prop("boss_type", boss_preset),
            text_prop("encounter_id", get_prop_value(obj, "encounter_id") or ""),
            bool_prop("lock_on_enter", get_prop_value(obj, "lock_on_enter"), true),
            bool_prop("unlock_on_clear", get_prop_value(obj, "unlock_on_clear"), true),
            number_prop("zone_width", width, 512),
            number_prop("zone_height", height, 384),
            text_prop("room_id", room_id),
        }
    end

    return M
end)()

local function gen_collection(rid)
    local collectible_template_text
    local KeyIds = require "mvtk.core.key_ids"
    local collectible_types_config = _C.load_project_lua_table("developer/config/collectible_types.lua") or {}
    -- Tiled enums use "none" as their user-selectable unset value. Keep this
    -- helper local to the baker so it does not add another Lua 5.1 upvalue to
    -- the already large generator function.
    local function opt(value)
        if value == nil then return "" end
        local text = tostring(value)
        if text == "" or text == "none" then return "" end
        return value
    end

    -- Keep this helper local: gen_collection already sits at Lua 5.1's
    -- 60-upvalue limit. It checks the authored Tiled-space rectangle against a
    -- named tile layer and supports nested group offsets plus encoded exports.
    local function rect_has_authored_tile(map, object, rect_w, rect_h, target_name)
        local tile_w = tonumber(map and map.tilewidth) or 0
        local tile_h = tonumber(map and map.tileheight) or tile_w
        if tile_w <= 0 or tile_h <= 0 then
            return false
        end

        local object_x = tonumber(object and object.x) or 0
        local object_y = tonumber(object and object.y) or 0
        local object_w = tonumber(rect_w) or tonumber(object and object.width) or tile_w
        local object_h = tonumber(rect_h) or tonumber(object and object.height) or tile_h
        if object_w <= 0 then object_w = tile_w end
        if object_h <= 0 then object_h = tile_h end

        local wanted = tostring(target_name or ""):lower():gsub("[%s%-]+", "_")
        local function walk(layers, parent_offset_x, parent_offset_y)
            for _, layer in ipairs(layers or {}) do
                if type(layer) == "table" then
                    local offset_x = (tonumber(parent_offset_x) or 0) + (tonumber(layer.offsetx) or 0)
                    local offset_y = (tonumber(parent_offset_y) or 0) + (tonumber(layer.offsety) or 0)
                    if layer.type == "group" and type(layer.layers) == "table" then
                        if walk(layer.layers, offset_x, offset_y) then
                            return true
                        end
                    elseif layer.type == "tilelayer" then
                        local layer_name = tostring(layer.name or ""):lower():gsub("[%s%-]+", "_")
                        if layer_name == wanted then
                            local data = layer.data
                            if type(data) ~= "table" then
                                local ok_module, TilemapRegen = pcall(require, "mvtk.editor.tilemap_regen")
                                if ok_module and type(TilemapRegen) == "table"
                                    and type(TilemapRegen.decode_tiled_layer_data) == "function" then
                                    local ok_decode, decoded = pcall(
                                        TilemapRegen.decode_tiled_layer_data,
                                        layer,
                                        tostring(rid),
                                        tostring(layer.name or target_name)
                                    )
                                    if ok_decode then data = decoded end
                                end
                            end

                            local layer_w = tonumber(layer.width) or tonumber(map.width) or 0
                            local layer_h = tonumber(layer.height) or tonumber(map.height) or 0
                            if type(data) == "table" and layer_w > 0 and layer_h > 0 then
                                local layer_x = offset_x + ((tonumber(layer.x) or 0) * tile_w)
                                local layer_y = offset_y + ((tonumber(layer.y) or 0) * tile_h)
                                local min_col = math.floor((object_x - layer_x) / tile_w)
                                local max_col = math.ceil((object_x + object_w - layer_x) / tile_w) - 1
                                local min_row = math.floor((object_y - layer_y) / tile_h)
                                local max_row = math.ceil((object_y + object_h - layer_y) / tile_h) - 1
                                min_col = math.max(0, min_col)
                                min_row = math.max(0, min_row)
                                max_col = math.min(layer_w - 1, max_col)
                                max_row = math.min(layer_h - 1, max_row)

                                for row = min_row, max_row do
                                    for col = min_col, max_col do
                                        local gid = data[(row * layer_w) + col + 1]
                                        if type(gid) == "table" then
                                            gid = gid.gid or gid.tile or gid.value
                                        end
                                        if (tonumber(gid) or 0) ~= 0 then
                                            return true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            return false
        end

        return walk(map and map.layers, 0, 0)
    end

    local proto = string.format('/developer/rooms/generated/%s_level.go', rid)
    local rows = {
        string.format('name: "%s_col"', rid),
        'instances {',
        '  id: "level"',
        '  prototype: "' .. proto .. '"',
        '}',
        'instances {',
        '  id: "tilecol"',
        '  prototype: "/developer/rooms/generated/' .. rid .. '_tilecol.go"',
        '}',
        'instances {',
        '  id: "spawn_a"',
        '  prototype: "/developer/rooms/prefabs/empty.go"',
        '}',
        'instances {',
        '  id: "spawn_locator"',
        '  prototype: "/developer/rooms/prefabs/spawn_locator.go"',
        '}',
        'instances {',
        '  id: "boot"',
        '  prototype: "/developer/rooms/prefabs/boot.go"',
        '}',
    }
    if rid:match('^room_03') then
        rows[#rows + 1] = 'instances {'
        rows[#rows + 1] = '  id: "save_point"'
        rows[#rows + 1] = '  prototype: "/developer/game/prefabs/save_point.go"'
        rows[#rows + 1] = '  position {'
        rows[#rows + 1] = '    x: 512.0'
        rows[#rows + 1] = '    y: 192.0'
        rows[#rows + 1] = '    z: 0.0'
        rows[#rows + 1] = '  }'
        rows[#rows + 1] = '  rotation {'
        rows[#rows + 1] = '    x: 0.0'
        rows[#rows + 1] = '    y: 0.0'
        rows[#rows + 1] = '    z: 0.0'
        rows[#rows + 1] = '    w: 1.0'
        rows[#rows + 1] = '  }'
        rows[#rows + 1] = '}'
    end

    -- Fast travel stations (use descriptive instance IDs that the script can parse)
    if rid == 'room_04' then
        rows[#rows + 1] = 'instances {'
        rows[#rows + 1] = '  id: "fast_travel_room_04"'
        rows[#rows + 1] = '  prototype: "/developer/game/prefabs/fast_travel_bench.go"'
        rows[#rows + 1] = '  position {'
        rows[#rows + 1] = '    x: 512.0'
        rows[#rows + 1] = '    y: 192.0'
        rows[#rows + 1] = '    z: 0.0'
        rows[#rows + 1] = '  }'
        rows[#rows + 1] = '  rotation {'
        rows[#rows + 1] = '    x: 0.0'
        rows[#rows + 1] = '    y: 0.0'
        rows[#rows + 1] = '    z: 0.0'
        rows[#rows + 1] = '    w: 1.0'
        rows[#rows + 1] = '  }'
        rows[#rows + 1] = '}'
    elseif rid == 'graveyard_double_slide_slime' then
        rows[#rows + 1] = 'instances {'
        rows[#rows + 1] = '  id: "fast_travel_graveyard"'
        rows[#rows + 1] = '  prototype: "/developer/game/prefabs/fast_travel_bench.go"'
        rows[#rows + 1] = '  position {'
        rows[#rows + 1] = '    x: 192.0'
        rows[#rows + 1] = '    y: 64.0'
        rows[#rows + 1] = '    z: 0.0'
        rows[#rows + 1] = '  }'
        rows[#rows + 1] = '  rotation {'
        rows[#rows + 1] = '    x: 0.0'
        rows[#rows + 1] = '    y: 0.0'
        rows[#rows + 1] = '    z: 0.0'
        rows[#rows + 1] = '    w: 1.0'
        rows[#rows + 1] = '  }'
        rows[#rows + 1] = '}'
    end

    -- Auto-add Tiled loader if a Tiled export exists for this room
    profiler.start("    load_tiled_export [" .. rid .. "]")
    local tiled_data, tiled_source_or_err = load_tiled_export(rid)
    profiler.stop("    load_tiled_export [" .. rid .. "]")
    if tiled_data then
        require("mvtk.editor.object_art").prepare(_C, tiled_data, tiled_source_or_err)
        info(string.format("gen_collection: Adding Tiled loader for room %s (source: %s)", rid, tostring(tiled_source_or_err)))

        -- Calculate map height for coordinate conversion
        local map_width = (tiled_data.width or 0) * (tiled_data.tilewidth or 0)
        local map_height = (tiled_data.height or 0) * (tiled_data.tileheight or 0)
        local map_tile_w = tonumber(tiled_data.tilewidth) or 128
        local map_tile_h = tonumber(tiled_data.tileheight) or map_tile_w
        if map_tile_w <= 0 then map_tile_w = 128 end
        if map_tile_h <= 0 then map_tile_h = map_tile_w end
        
        -- Get sprite components from both image layers and background visual tile objects
        profiler.start("    background_sprites [" .. rid .. "]")
        local sprite_components = collect_room_background_sprite_components(tiled_data, map_width, map_height, rid, tiled_source_or_err)
        _C.ParallaxBake.sprites(_C, rows, rid, tiled_data, sprite_components)
        _C.ParallaxBake.append_tiles(_C, rows, rid, tiled_data)
        _C.GrappleLayerBake.append(_C, rows, rid, tiled_data)
        profiler.stop("    background_sprites [" .. rid .. "]")
        
        -- Add Tiled loader instance (without embedded components)
        rows[#rows + 1] = 'instances {'
        rows[#rows + 1] = '  id: "tiled_loader"'
        rows[#rows + 1] = '  prototype: "/developer/rooms/prefabs/tiled_loader_template.go"'
        append_component_properties(rows, "tiled_room_loader", build_tiled_loader_props(rid))
        rows[#rows + 1] = '}'

        if tiled_data.layers then
            local map_height = (tiled_data.height or 0) * (tiled_data.tileheight or 0)
            local object_count = 0
            local known_types = _C.load_object_type_set()
            local pushable_bake_ctx = nil
            local pushable_bake_failed = false
            local background_bake_failed = false
            -- Boss validation: track boss-related objects for cross-referencing
            local boss_validation = {
                bosses = {},        -- [boss_id] = {boss_preset=, arena_id=}
                arenas = {},        -- [arena_id] = true
                phases = {},        -- [arena_id] = count
                triggers = {},      -- [arena_id] = true
            }
            profiler.start("    flatten_tiled_layers [" .. rid .. "]")
            local flattened_layers = flatten_tiled_layers(tiled_data.layers)
            profiler.stop("    flatten_tiled_layers [" .. rid .. "]")

            local skipped_enemy_warnings = Validation.collect_skipped_enemy_import_warnings(tiled_data, {
                process_group_layers = true,
                resolve_object_type = function(object)
                    return resolve_object_type(object, known_types)
                end,
            })
            for _, warning in ipairs(skipped_enemy_warnings) do
                local reason = "move it to a processed object layer such as 'templates'."
                if warning.reason == "object_hidden" then
                    reason = "make it visible or move a visible enemy object to a processed object layer such as 'templates'."
                elseif warning.reason == "group_layer_not_processed" then
                    reason = "move it to the top-level 'templates' object layer."
                end
                info(string.format(
                    "[CREATE ROOMS][WARNING] map '%s': enemy object id=%s on layer '%s' will NOT be imported - %s",
                    tostring(rid),
                    tostring(warning.object_id or "?"),
                    tostring(warning.layer or "?"),
                    reason
                ))
            end

            profiler.start("    object_iteration [" .. rid .. "]")
            for _, entry in ipairs(flattened_layers) do
                local layer = entry.layer
                if entry.visible ~= false and layer and layer.type == "objectgroup" and type(layer.objects) == "table" then
                    local layer_offset_x = tonumber(entry.offsetx) or 0
                    local layer_offset_y = tonumber(entry.offsety) or 0
                    for _, raw_obj in ipairs(layer.objects) do
                        if raw_obj and raw_obj.visible ~= false then
                            local obj = {}
                            for k, v in pairs(raw_obj) do
                                obj[k] = v
                            end
                            local raw_properties = raw_obj.properties
                            obj.properties = PropertyFlattener.flatten(raw_properties)
                            obj.x = (tonumber(raw_obj.x) or 0) + layer_offset_x
                            obj.y = (tonumber(raw_obj.y) or 0) + layer_offset_y
                            local obj_type = resolve_object_type(obj, known_types)
                            if obj_type == "gate" then
                                local warning = _C.RetiredTypes.required_ability_warning(obj, rid, obj.properties.required_ability)
                                if warning then info("[CREATE ROOMS][WARNING] " .. warning) end
                            end
                            if obj_type == "enemy" then
                                -- Enemy grouped defaults use domain-specific
                                -- inheritance sentinels; retain that precedence
                                -- while sharing the generic shape normalizer.
                                obj.properties = EnemyOverrides.flatten_tiled_properties(raw_properties)
                            end
                            if is_background_visual_object_candidate(obj, layer.name) then
                                obj_type = "background_visual"
                            end
                            obj.type = obj_type or obj.type
                            local obj_id = generated_object_id(rid, obj_type, obj.id)

                        -- Convert Tiled Y to Defold Y
                        -- For point objects, add offset to account for centered collision shapes
                        local defold_y = map_height - obj.y

                        -- Apply configured Y offsets only for point-like objects.
                        -- Rectangle objects already carry explicit width/height and are centered later.
                        local obj_w = tonumber(obj and obj.width) or 0
                        local obj_h = tonumber(obj and obj.height) or 0
                        local is_point_like = (obj_w <= 0 and obj_h <= 0) or (obj and (obj.point == true or obj.shape == "point"))
                        local y_offset = 0
                        if is_point_like then
                            y_offset = TILED_CONFIG.y_offsets[obj_type] or TILED_CONFIG.y_offsets.default or 0
                            defold_y = defold_y + y_offset
                        end
                        info(string.format("gen_collection: obj_type=%s, Tiled Y=%.2f, defold_y_before=%.2f, point_like=%s, offset=%d, defold_y_after=%.2f",
                            obj_type or "nil", obj.y, (map_height - obj.y), tostring(is_point_like), y_offset, defold_y))

                        if entry.visible == false
                            and (obj_type == "elevator" or obj_type == "elevator_node")
                        then
                            info(string.format(
                                "gen_collection: Skipped hidden elevator marker %s object id=%s",
                                tostring(obj_type), tostring(obj.id)
                            ))

                        elseif obj_type == "object_art" or obj.type == "object_art" or obj_type == "background_visual" or obj_type == "background" then
                            -- Visual-only tile objects are imported to atlas and emitted as
                            -- embedded sprite components in the room backgrounds GO.

                        elseif obj_type == "collectible" or obj_type == "ability" then
                            local collectible_type = get_prop_value(obj, "collectible_type")
                            local ability_id = opt(get_prop_value(obj, "ability_id"))
                            if collectible_type ~= nil and tostring(collectible_type) == "none" then
                                info(string.format(
                                    "[CREATE ROOMS][WARNING] map '%s': collectible object id=%s has collectible_type=none; skipping it.",
                                    tostring(rid), tostring(obj.id)
                                ))
                            elseif obj_type == "ability" and ability_id == "" then
                                info(string.format(
                                    "[CREATE ROOMS][WARNING] map '%s': ability pickup object id=%s has no ability_id; skipping it.",
                                    tostring(rid), tostring(obj.id)
                                ))
                            else
                                collectible_type = opt(collectible_type)
                                if collectible_type == "" then
                                    if ability_id ~= "" then
                                        collectible_type = "ability_" .. tostring(ability_id)
                                    elseif get_prop_value(obj, "relic_id") ~= nil
                                        or get_prop_value(obj, "relic_name") ~= nil
                                        or get_prop_value(obj, "relic_description") ~= nil
                                        or tostring(obj.name or "") == "Relic" then
                                        collectible_type = "relic"
                                    end
                                end
                                if collectible_type ~= nil and tostring(collectible_type):match("^relic_")
                                    and not collectible_type_exists(collectible_type) then
                                    collectible_type = "relic"
                                end
                                if collectible_type == nil or tostring(collectible_type) == "" then
                                    collectible_type = "health_container"
                                end

                                local collectible_config = collectible_types_config[tostring(collectible_type)] or {}
                                local default_collectible_atlas = "/developer/assets/atlas/gameplay_visuals.atlas"
                                local authored_atlas = opt(get_prop_value(obj, "sprite_atlas"))
                                local resolved_atlas = authored_atlas ~= ""
                                    and tostring(authored_atlas)
                                    or tostring(collectible_config.sprite or default_collectible_atlas)
                                resolved_atlas = resolved_atlas:gsub("\\", "/")
                                if resolved_atlas:sub(1, 1) ~= "/" then
                                    resolved_atlas = "/" .. resolved_atlas
                                end
                                local authored_animation = opt(get_prop_value(obj, "animation"))
                                local resolved_animation = authored_animation ~= ""
                                    and tostring(authored_animation)
                                    or tostring(collectible_config.animation or "prop_base")

                                local collectible_props = {
                                    Prop.text("collectible_type", collectible_type),
                                    Prop.text("collectible_id", opt(get_prop_value(obj, "collectible_id")) ~= "" and get_prop_value(obj, "collectible_id") or obj_id),
                                    Prop.text("sprite_atlas", resolved_atlas),
                                    Prop.text("animation", resolved_animation),
                                }

                                local function push_text_prop(prop_id)
                                    local value = opt(get_prop_value(obj, prop_id))
                                    if value ~= "" then
                                        collectible_props[#collectible_props + 1] = Prop.text(prop_id, value)
                                    end
                                end

                            local function push_number_prop(prop_id)
                                local value = get_prop_value(obj, prop_id)
                                if value ~= nil and tostring(value) ~= "" then
                                    collectible_props[#collectible_props + 1] = Prop.number(prop_id, value, 0)
                                end
                            end

                            local function push_bool_override(prop_id, override_id)
                                local value = get_prop_value(obj, prop_id)
                                if value ~= nil and tostring(value) ~= "" then
                                    collectible_props[#collectible_props + 1] = Prop.bool(prop_id, value, false)
                                    collectible_props[#collectible_props + 1] = Prop.bool(override_id, true, false)
                                end
                            end

                            push_number_prop("amount")
                            local item_id = opt(get_prop_value(obj, "item_id"))
                            local key_id = opt(get_prop_value(obj, "key_id"))
                            local canonical_item_id = KeyIds.canonicalize(item_id)
                            local canonical_key_id = KeyIds.canonicalize(key_id)
                            if canonical_item_id and canonical_item_id ~= "" then
                                collectible_props[#collectible_props + 1] = Prop.text("item_id", canonical_item_id)
                            end
                            if canonical_key_id and canonical_key_id ~= "" then
                                collectible_props[#collectible_props + 1] = Prop.text("key_id", canonical_key_id)
                                if not canonical_item_id or canonical_item_id == "" then
                                    collectible_props[#collectible_props + 1] = Prop.text("item_id", canonical_key_id)
                                end
                            end
                            push_text_prop("lore_id")
                            push_text_prop("lore_text")
                            push_text_prop("relic_id")
                            push_text_prop("relic_name")
                            push_text_prop("relic_description")
                            push_text_prop("area_id")
                            push_text_prop("area_name")
                            push_number_prop("reveal_radius")
                            push_text_prop("ability_id")
                            push_text_prop("popup_title")
                            push_text_prop("popup_description")
                            push_text_prop("set_flag_on_collect")
                            push_bool_override("respawns", "respawns_override")
                            push_bool_override("show_popup", "show_popup_override")

                            local collectible_proto = "/developer/game/prefabs/collectible_generic.go"
                            if _visual.uses_defold_sprite(obj, obj_type) and resolved_atlas ~= default_collectible_atlas then
                                local collectible_go_name = string.format("%s_collectible_%d.go", rid, obj.id)
                                local collectible_go_path = join(PATH.generated_go, collectible_go_name)
                                collectible_template_text = collectible_template_text or _C.read_text(_C.join(
                                    _C.ROOT,
                                    "developer/game/prefabs/collectible_generic.go"
                                ))
                                local template_text = collectible_template_text
                                local CollectiblePrefabGenerator = require "mvtk.editor.collectible_prefab_generator"
                                local collectible_go_text, collectible_go_err = CollectiblePrefabGenerator.generate(
                                    template_text,
                                    resolved_atlas,
                                    resolved_animation
                                )
                                if not collectible_go_text then
                                    error(string.format(
                                        "[CREATE ROOMS] map '%s' collectible object id=%s cannot bake atlas '%s': %s",
                                        tostring(rid),
                                        tostring(obj.id),
                                        tostring(resolved_atlas),
                                        tostring(collectible_go_err)
                                    ))
                                end
                                if write_if_changed(collectible_go_path, collectible_go_text) then
                                    info("Created " .. collectible_go_path)
                                end
                                collectible_proto = "/developer/rooms/generated/" .. collectible_go_name
                            end
                            collectible_proto = _visual.resolve_visual_proto(rid, obj, obj_type, collectible_proto)

                            add_prefab_instance(
                                rows,
                                obj_id,
                                collectible_proto,
                                obj.x,
                                defold_y,
                                nil,
                                nil,
                                "collectible",
                                collectible_props
                            )
                            object_count = object_count + 1
                            end

                        elseif obj_type == "npc" then
                            local npc_type = get_prop_value(obj, "npc_type")
                            if npc_type == nil then
                                npc_type = ""
                            end
                            local npc_runtime_id = get_prop_value(obj, "npc_id")
                            if npc_runtime_id == nil or tostring(npc_runtime_id) == "" then
                                npc_runtime_id = obj_id
                            end
                            local dialogue_id = get_prop_value(obj, "dialogue_id")
                            local dialogue_text = get_prop_value(obj, "dialogue_text")
                            if dialogue_text ~= nil and tostring(dialogue_text) ~= "" then
                                if dialogue_id == nil or tostring(dialogue_id) == ""
                                    or not static_dialogue_exists(dialogue_id) then
                                    dialogue_id = tostring(npc_runtime_id) .. "_dialogue"
                                end
                            end

                            local npc_props = {
                                Prop.text("npc_id", npc_runtime_id),
                                Prop.text("npc_type", npc_type),
                                Prop.text("room_id", rid),
                            }

                            local function push_npc_text_prop(prop_id)
                                local value = get_prop_value(obj, prop_id)
                                if value ~= nil and tostring(value) ~= "" then
                                    npc_props[#npc_props + 1] = Prop.text(prop_id, value)
                                end
                            end

                            local function push_npc_number_prop(prop_id, default)
                                local value = get_prop_value(obj, prop_id)
                                if value ~= nil and tostring(value) ~= "" then
                                    npc_props[#npc_props + 1] = Prop.number(prop_id, value, default)
                                end
                            end

                            local function push_npc_bool_prop(prop_id, default)
                                local value = get_prop_value(obj, prop_id)
                                if value ~= nil and tostring(value) ~= "" then
                                    npc_props[#npc_props + 1] = Prop.bool(prop_id, value, default)
                                end
                            end

                            push_npc_text_prop("npc_name")
                            push_npc_text_prop("npc_sprite")
                            if dialogue_id ~= nil and tostring(dialogue_id) ~= "" then
                                npc_props[#npc_props + 1] = Prop.text("dialogue_id", dialogue_id)
                            end
                            push_npc_text_prop("despawn_flag")
                            push_npc_number_prop("facing", 1)
                            push_npc_bool_prop("can_move", false)
                            push_npc_number_prop("interaction_range", 48)

                            add_prefab_instance(
                                rows,
                                obj_id,
                                _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/npc.go"),
                                obj.x,
                                defold_y,
                                nil,
                                nil,
                                "npc",
                                npc_props
                            )
                            object_count = object_count + 1

                        elseif obj_type == "dialogue_trigger" then
                            -- The trigger registry treats positions as the lower-left
                            -- corner of the authored rectangle, matching the legacy
                            -- runtime handler after Tiled-to-Defold conversion.
                            local trigger_w, trigger_h = resolve_rect_size_pixels(
                                tonumber(obj and obj.width) or 0,
                                tonumber(obj and obj.height) or 0,
                                map_tile_w,
                                map_tile_h,
                                map_tile_w,
                                map_tile_h
                            )
                            local px = tonumber(obj and obj.x) or 0
                            local py = (tonumber(defold_y) or 0) - trigger_h
                            local trigger_id = opt(get_prop_value(obj, "trigger_id"))
                            local dialogue_id = opt(get_prop_value(obj, "dialogue_id"))
                            local dialogue_obj_id = string.format("%s_dialogue_trigger_%d", rid, obj.id)
                            add_prefab_instance(
                                rows,
                                dialogue_obj_id,
                                "/developer/game/prefabs/dialogue_trigger.go",
                                px,
                                py,
                                nil,
                                nil,
                                "script",
                                {
                                    Prop.text("trigger_id", trigger_id),
                                    Prop.text("dialogue_id", dialogue_id),
                                    Prop.text("npc_id", opt(get_prop_value(obj, "npc_id"))),
                                    Prop.bool("trigger_once", get_prop_value(obj, "trigger_once"), true),
                                    Prop.bool("persist_once", get_prop_value(obj, "persist_once"), true),
                                    Prop.text("once_flag", opt(get_prop_value(obj, "once_flag"))),
                                    Prop.bool("consume_on_fire", get_prop_value(obj, "consume_on_fire"), true),
                                    Prop.bool("auto_play", get_prop_value(obj, "auto_play"), true),
                                    Prop.number("delay", get_prop_value(obj, "delay"), 0),
                                    Prop.text("requires_flag", opt(get_prop_value(obj, "requires_flag"))),
                                    Prop.text("skip_if_flag", opt(get_prop_value(obj, "skip_if_flag"))),
                                    Prop.text("set_flag", opt(get_prop_value(obj, "set_flag"))),
                                    Prop.number("width", trigger_w, map_tile_w),
                                    Prop.number("height", trigger_h, map_tile_h),
                                    Prop.text("room_id", rid),
                                    Prop.number("object_id", obj.id, 0),
                                }
                            )
                            object_count = object_count + 1

                        elseif obj_type == "enemy" then
                            local px = (tonumber(obj.x) or 0) + ((tonumber(obj.width) or 0) * 0.5)
                            local py = (tonumber(defold_y) or 0) - ((tonumber(obj.height) or 0) * 0.5)
                            local flat_enemy_props = obj.properties or {}
                            local function enemy_prop(name)
                                return get_prop_value(flat_enemy_props, name)
                            end
                            local enemy_type = enemy_prop("enemy_type") or "slime"
                            local exported_skin = opt(enemy_prop("skin"))
                            local prefab_skin = resolve_enemy_prefab_skin(enemy_type, exported_skin)
                            local enemy_prefab = "/developer/game/prefabs/generated/enemy_" .. prefab_skin .. ".go"
                            local enemy_props = {
                                Prop.text("enemy_type", enemy_type),
                                Prop.number("facing", enemy_prop("facing"), 1),
                                Prop.bool("elite", enemy_prop("elite"), false),
                                Prop.text("difficulty", opt(enemy_prop("difficulty"))),
                                Prop.text("drops", enemy_prop("drops") or ""),
                                Prop.text("loot_table", enemy_prop("loot_table") or ""),
                                Prop.text("faction", enemy_prop("faction") or ""),
                                Prop.text("group_id", enemy_prop("group_id") or ""),
                                Prop.number("ally_detection_range", enemy_prop("ally_detection_range"), 200),
                                Prop.number("health_mult", enemy_prop("health_mult"), 1.0),
                                Prop.number("damage_mult", enemy_prop("damage_mult"), 1.0),
                                Prop.number("speed_mult", enemy_prop("speed_mult"), 1.0),
                                Prop.number("detection_range", enemy_prop("detection_range"), -1),
                                Prop.number("chase_speed", enemy_prop("chase_speed"), -1),
                                Prop.number("chase_speed_mult", enemy_prop("chase_speed_mult"), -1),
                                Prop.number("contact_damage", enemy_prop("contact_damage"), -1),
                                Prop.number("knockback_force", enemy_prop("knockback_force"), -1),
                                Prop.number("contact_damage_cooldown", enemy_prop("contact_damage_cooldown"), -1),
                                Prop.text("patrol_route", enemy_prop("patrol_route") or ""),
                                Prop.text("movement", enemy_prop("movement") or ""),
                                Prop.text("attack_pattern", enemy_prop("attack_pattern") or ""),
                                Prop.text("attack_pattern2", enemy_prop("attack_pattern2") or ""),
                                Prop.number("patrol_height_override", enemy_prop("patrol_height"), -1),
                                Prop.number("patrol_distance", enemy_prop("patrol_distance"), -1),
                                Prop.number("hover_height", enemy_prop("hover_height"), -1),
                                Prop.number("shoot_cooldown", enemy_prop("shoot_cooldown"), -1),
                                Prop.number("projectile_damage", enemy_prop("projectile_damage"), -1),
                                Prop.number("projectile_speed", enemy_prop("projectile_speed"), -1),
                                Prop.number("charge_speed", enemy_prop("charge_speed"), -1),
                                Prop.number("charge_distance", enemy_prop("charge_distance"), -1),
                                Prop.number("charge_duration", enemy_prop("charge_duration"), -1),
                                Prop.number("charge_cooldown", enemy_prop("charge_cooldown"), -1),
                                Prop.number("attack_detection_range", enemy_prop("attack_detection_range"), -1),
                                Prop.number("swoop_detection_range", enemy_prop("swoop_detection_range"), -1),
                                Prop.number("swoop_speed", enemy_prop("swoop_speed"), -1),
                                Prop.number("swoop_duration", enemy_prop("swoop_duration"), -1),
                                Prop.number("dart_speed", enemy_prop("dart_speed"), -1),
                                Prop.number("dart_interval", enemy_prop("dart_interval"), -1),
                                Prop.number("dart_vertical_speed", enemy_prop("dart_vertical_speed"), -1),
                                Prop.number("rise_range", enemy_prop("rise_range"), -1),
                                Prop.number("rise_height", enemy_prop("rise_height"), -1),
                                Prop.number("rise_speed", enemy_prop("rise_speed"), -1),
                                Prop.number("attack_range", enemy_prop("attack_range"), -1),
                                Prop.number("attack_height", enemy_prop("attack_height"), -1),
                                Prop.number("attack_windup", enemy_prop("attack_windup"), -1),
                                Prop.number("attack_cooldown", enemy_prop("attack_cooldown"), -1),
                                Prop.text("room_id", rid),
                                Prop.number("iframes_on_hit", enemy_prop("iframes_on_hit"), -1.0),
                            }
                            if exported_skin ~= "" then
                                enemy_props[#enemy_props + 1] = Prop.text("skin", exported_skin)
                            end

                            add_prefab_instance(
                                rows,
                                obj_id,
                                enemy_prefab,
                                px,
                                py,
                                nil,
                                nil,
                                "enemy",
                                enemy_props
                            )
                            object_count = object_count + 1

                        elseif obj_type == "save_point" then
                            local save_id = get_prop_value(obj, "save_id")
                            if save_id == nil or tostring(save_id) == "" then
                                save_id = obj.name or obj_id
                            end
                            add_prefab_instance(rows, obj_id, _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/save_point.go"), obj.x, defold_y, nil, nil, "save_point", {
                                Prop.text("display_name", get_prop_value(obj, "display_name") or "Save Point"),
                                Prop.bool("heal_on_save", get_prop_value(obj, "heal_on_save"), true),
                                Prop.bool("restore_energy", get_prop_value(obj, "restore_energy"), true),
                                Prop.bool("is_fast_travel", get_prop_value(obj, "is_fast_travel"), false),
                                Prop.bool("show_on_map", get_prop_value(obj, "show_on_map"), true),
                                Prop.bool("requires_interact", get_prop_value(obj, "requires_interact"), true),
                                Prop.text("save_id", save_id),
                                Prop.text("room_id", rid),
                                Prop.text("sound_id", opt(get_prop_value(obj, "sound_id"))),
                                Prop.text("particle_id", opt(get_prop_value(obj, "particle_id"))),
                            })
                            object_count = object_count + 1

                        elseif obj_type == "checkpoint" then
                            local checkpoint_id = get_prop_value(obj, "checkpoint_id")
                            if checkpoint_id == nil or tostring(checkpoint_id) == "" then
                                checkpoint_id = obj_id
                            end
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 32, 32, 64, 64)
                            local checkpoint_go_name = string.format("%s_checkpoint_%d.go", rid, obj.id)
                            local checkpoint_go_path = join(PATH.generated_go, checkpoint_go_name)
                            local checkpoint_proto = string.format("/developer/rooms/generated/%s", checkpoint_go_name)
                            if write_if_changed(checkpoint_go_path, gen_checkpoint_go(w, h)) then
                                info("Created " .. checkpoint_go_path)
                            end
                            local checkpoint_sound_id = opt(get_prop_value(obj, "sound_id"))
                            if checkpoint_sound_id == "" then
                                checkpoint_sound_id = "save_point"
                            end
                            add_prefab_instance(rows, obj_id, checkpoint_proto, px, py, nil, nil, "script", {
                                Prop.text("checkpoint_id", checkpoint_id),
                                Prop.number("respawn_facing", get_prop_value(obj, "respawn_facing"), 1),
                                Prop.bool("trigger_once", get_prop_value(obj, "trigger_once"), false),
                                -- `checkpoint` is not a sound-bank id; use the shipped save-point sound.
                                Prop.text("sound_id", checkpoint_sound_id),
                                Prop.text("particle_id", get_prop_value(obj, "particle_id") or "checkpoint_glow"),
                                Prop.text("room_id", rid),
                                Prop.text("requires_flag", get_prop_value(obj, "requires_flag") or ""),
                                Prop.text("set_flag", get_prop_value(obj, "set_flag") or ""),
                            })
                            object_count = object_count + 1

                        elseif obj_type == "fast_travel" then
                            local station_id = get_prop_value(obj, "station_id")
                            if station_id == nil or tostring(station_id) == "" then
                                station_id = obj_id
                            end
                            local station_name = get_prop_value(obj, "station_name")
                            if station_name == nil or tostring(station_name) == "" then
                                station_name = obj.name or "Travel Point"
                            end
                            add_prefab_instance(rows, obj_id, "/developer/game/prefabs/fast_travel_bench.go", obj.x, defold_y, nil, nil, "bench", {
                                Prop.text("station_id", station_id),
                                Prop.text("station_name", station_name),
                                Prop.text("station_description", get_prop_value(obj, "station_description") or ""),
                                Prop.text("room_id", rid),
                                Prop.bool("auto_unlock", get_prop_value(obj, "auto_unlock"), false),
                                Prop.number("unlock_cost", get_prop_value(obj, "unlock_cost"), 0),
                                Prop.bool("show_on_map", get_prop_value(obj, "show_on_map"), true),
                                Prop.text("icon", get_prop_value(obj, "icon") or "fast_travel"),
                                Prop.number("facing", get_prop_value(obj, "facing"), 1),
                            })
                            object_count = object_count + 1

                        elseif obj_type == "chest" then
                            -- Get chest properties from Tiled
                            local chest_type = "wooden"
                            local chest_id = ""
                            local contents = "currency:25"
                            local locked = false
                            local requires_key = ""
                            local single_use = true
                            if obj.properties then
                                if obj.properties.chest_id then chest_id = obj.properties.chest_id end
                                if obj.properties.chest_type then chest_type = obj.properties.chest_type end
                                if obj.properties.contents then contents = obj.properties.contents end
                                if obj.properties.locked ~= nil then locked = obj.properties.locked end
                                if obj.properties.requires_key then requires_key = obj.properties.requires_key end
                                if obj.properties.single_use ~= nil then single_use = obj.properties.single_use end
                            end
                            requires_key = KeyIds.canonicalize(opt(requires_key)) or ""

                            if chest_id == nil or tostring(chest_id) == "" then
                                chest_id = obj_id
                            end

                            rows[#rows + 1] = 'instances {'
                            rows[#rows + 1] = string.format('  id: "%s"', obj_id)
                            rows[#rows + 1] = '  prototype: "' .. _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/chest.go") .. '"'
                            rows[#rows + 1] = '  position {'
                            rows[#rows + 1] = '    x: ' .. fmt_num(obj.x)
                            rows[#rows + 1] = '    y: ' .. fmt_num(defold_y)
                            rows[#rows + 1] = '    z: 0.0'
                            rows[#rows + 1] = '  }'
                            rows[#rows + 1] = '  component_properties {'
                            rows[#rows + 1] = '    id: "chest"'
                            rows[#rows + 1] = '    properties {'
                            rows[#rows + 1] = '      id: "chest_id"'
                            rows[#rows + 1] = string.format('      value: "%s"', proto_escape(chest_id))
                            rows[#rows + 1] = '      type: PROPERTY_TYPE_TEXT'
                            rows[#rows + 1] = '    }'
                            rows[#rows + 1] = '    properties {'
                            rows[#rows + 1] = '      id: "chest_type"'
                            rows[#rows + 1] = string.format('      value: "%s"', proto_escape(chest_type))
                            rows[#rows + 1] = '      type: PROPERTY_TYPE_TEXT'
                            rows[#rows + 1] = '    }'
                            rows[#rows + 1] = '    properties {'
                            rows[#rows + 1] = '      id: "loot_table"'
                            rows[#rows + 1] = string.format('      value: "%s"', proto_escape(contents))
                            rows[#rows + 1] = '      type: PROPERTY_TYPE_TEXT'
                            rows[#rows + 1] = '    }'
                            rows[#rows + 1] = '    properties {'
                            rows[#rows + 1] = '      id: "locked"'
                            rows[#rows + 1] = string.format('      value: "%s"', tostring(locked))
                            rows[#rows + 1] = '      type: PROPERTY_TYPE_BOOLEAN'
                            rows[#rows + 1] = '    }'
                            rows[#rows + 1] = '    properties {'
                            rows[#rows + 1] = '      id: "key_required"'
                            rows[#rows + 1] = string.format('      value: "%s"', proto_escape(requires_key))
                            rows[#rows + 1] = '      type: PROPERTY_TYPE_TEXT'
                            rows[#rows + 1] = '    }'
                            rows[#rows + 1] = '    properties {'
                            rows[#rows + 1] = '      id: "single_use"'
                            rows[#rows + 1] = string.format('      value: "%s"', tostring(single_use))
                            rows[#rows + 1] = '      type: PROPERTY_TYPE_BOOLEAN'
                            rows[#rows + 1] = '    }'
                            rows[#rows + 1] = '    properties {'
                            rows[#rows + 1] = '      id: "room_id"'
                            rows[#rows + 1] = string.format('      value: "%s"', proto_escape(rid))
                            rows[#rows + 1] = '      type: PROPERTY_TYPE_TEXT'
                            rows[#rows + 1] = '    }'
                            rows[#rows + 1] = '  }'
                            rows[#rows + 1] = '}'
                            object_count = object_count + 1
                        elseif obj_type == "gate" then
                            local gate_id = get_prop_value(obj, "gate_id")
                            if gate_id == nil or tostring(gate_id) == "" then
                                gate_id = obj_id
                            end
                            local px, py, _, _, gate_w, gate_h = rect_center_and_scale(
                                obj,
                                defold_y,
                                map_tile_w,
                                map_tile_h,
                                64,
                                64,
                                128,
                                128
                            )
                            local gate_go_name = string.format("%s_gate_%d.go", rid, obj.id)
                            local gate_go_path = join(PATH.generated_go, gate_go_name)
                            local gate_proto = string.format("/developer/rooms/generated/%s", gate_go_name)
                            if write_if_changed(gate_go_path, gen_gate_go(gate_w, gate_h, _visual.uses_defold_sprite(obj, obj_type))) then
                                info("Created " .. gate_go_path)
                            end
                            add_prefab_instance(rows, obj_id, gate_proto, px, py, nil, nil, "gate", {
                                Prop.text("gate_id", gate_id),
                                Prop.text("gate_type", get_prop_value(obj, "gate_type") or "ability_requirement"),
                                Prop.text("room_id", rid),
                                Prop.text("required_ability", opt(get_prop_value(obj, "required_ability"))),
                                Prop.text("required_action", opt(get_prop_value(obj, "required_action"))),
                                Prop.text("required_item", KeyIds.canonicalize(opt(get_prop_value(obj, "required_item"))) or ""),
                                Prop.text("required_key", KeyIds.canonicalize(opt(get_prop_value(obj, "required_key"))) or ""),
                                Prop.number("required_energy", get_prop_value(obj, "required_energy"), -1),
                                Prop.text("open_message", get_prop_value(obj, "open_message") or ""),
                                Prop.bool("starts_open", get_prop_value(obj, "starts_open"), false),
                                Prop.bool("stays_open", get_prop_value(obj, "stays_open"), true),
                                Prop.bool("persist_unlock", get_prop_value(obj, "persist_unlock"), true),
                                Prop.bool("persist_unlock_override", get_prop_value(obj, "persist_unlock") ~= nil, false),
                            })
                            object_count = object_count + 1
                            info(string.format("gen_collection: Baked gate prefab (%s) size=%sx%s", obj_id, tostring(gate_w), tostring(gate_h)))
                        elseif obj_type == "health_station" then
                            local station_id = get_prop_value(obj, "station_id")
                            if station_id == nil or tostring(station_id) == "" then
                                station_id = obj_id
                            end
                            local health_require_interact = get_prop_value(obj, "require_interact")
                            if health_require_interact == nil then
                                health_require_interact = get_prop_value(obj, "requires_interact")
                            end
                            add_prefab_instance(rows, obj_id, _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/health_station.go"), obj.x, defold_y, nil, nil, "script", {
                                Prop.text("station_id", station_id),
                                Prop.text("label", get_prop_value(obj, "prompt_text") or get_prop_value(obj, "label") or ""),
                                Prop.number("range", get_prop_value(obj, "range"), 96),
                                Prop.number("heal_amount", get_prop_value(obj, "heal_amount"), 0),
                                Prop.number("heal_percent", get_prop_value(obj, "heal_percent"), 0),
                                Prop.number("uses", get_prop_value(obj, "uses"), 0),
                                Prop.number("recharge_time", OP.get_via(get_prop_value, obj, "recharge_time"), 0),
                                Prop.number("cost_currency", OP.get_via(get_prop_value, obj, "cost_currency"), 0),
                                Prop.bool("require_interact", health_require_interact, true),
                                Prop.text("requires_flag", get_prop_value(obj, "requires_flag") or ""),
                                Prop.text("sound_id", get_prop_value(obj, "sound_id") or "heal"),
                                Prop.text("particle_id", get_prop_value(obj, "particle_id") or "heal_sparkle"),
                            })
                            object_count = object_count + 1
                        elseif obj_type == "energy_station" then
                            local station_id = get_prop_value(obj, "station_id")
                            if station_id == nil or tostring(station_id) == "" then
                                station_id = obj_id
                            end
                            local energy_require_interact = get_prop_value(obj, "require_interact")
                            if energy_require_interact == nil then
                                energy_require_interact = get_prop_value(obj, "requires_interact")
                            end
                            add_prefab_instance(rows, obj_id, _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/energy_station.go"), obj.x, defold_y, nil, nil, "script", {
                                Prop.text("station_id", station_id),
                                Prop.text("prompt_text", get_prop_value(obj, "prompt_text") or ""),
                                Prop.number("restore_amount", OP.get_via(get_prop_value, obj, "restore_amount"), 0),
                                Prop.number("restore_percent", OP.get_via(get_prop_value, obj, "restore_percent"), 0),
                                Prop.text("resource_type", get_prop_value(obj, "resource_type") or "energy"),
                                Prop.number("uses", get_prop_value(obj, "uses"), -1),
                                Prop.number("cooldown", OP.get_via(get_prop_value, obj, "cooldown"), 0),
                                Prop.number("cost", OP.get_via(get_prop_value, obj, "cost"), 0),
                                Prop.bool("require_interact", energy_require_interact, true),
                                Prop.text("sound_id", opt(get_prop_value(obj, "sound_id"))),
                                Prop.text("particle_id", opt(get_prop_value(obj, "particle_id"))),
                                Prop.number("range", get_prop_value(obj, "range"), 96),
                            })
                            object_count = object_count + 1
                        elseif obj_type == "map_station" then
                            local station_id = get_prop_value(obj, "station_id")
                            if station_id == nil or tostring(station_id) == "" then
                                station_id = obj_id
                            end
                            local reveal_full_biome = get_prop_value(obj, "reveal_full_biome")
                            add_prefab_instance(rows, obj_id, _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/map_station.go"), obj.x, defold_y, nil, nil, "script", {
                                Prop.text("reveal_area", get_prop_value(obj, "reveal_area") or "current"),
                                Prop.text("prompt_text", get_prop_value(obj, "prompt_text") or ""),
                                Prop.number("reveal_radius", get_prop_value(obj, "reveal_radius"), 320),
                                Prop.bool("reveal_full_biome", reveal_full_biome, true),
                                Prop.number("cost", get_prop_value(obj, "cost"), 0),
                                Prop.bool("trigger_once", get_prop_value(obj, "trigger_once"), true),
                                Prop.text("station_id", station_id),
                                Prop.text("sound_id", get_prop_value(obj, "sound_id") or "map_reveal"),
                                Prop.text("particle_id", get_prop_value(obj, "particle_id") or "map_sparkle"),
                                Prop.number("range", get_prop_value(obj, "range"), 96),
                            })
                            object_count = object_count + 1
                        elseif obj_type == "breakable_wall" then
                            local px, py, _, _, w, h = snapped_rect_center_and_scale(
                                obj,
                                defold_y,
                                map_tile_w,
                                map_tile_h,
                                32,
                                32,
                                map_tile_w,
                                map_tile_h
                            )
                            local wall_go_name = string.format("%s_breakable_wall_%d.go", rid, obj.id)
                            local wall_go_path = join(PATH.generated_go, wall_go_name)
                            local wall_proto = string.format("/developer/rooms/generated/%s", wall_go_name)
                            if write_if_changed(wall_go_path, gen_breakable_wall_go(w, h, _visual.uses_defold_sprite(obj, obj_type))) then
                                info("Created " .. wall_go_path)
                            end
                            local wall_id = get_prop_value(obj, "wall_id")
                            if wall_id == nil or tostring(wall_id) == "" then
                                wall_id = obj_id
                            end
                            local swap_width = resolve_breakable_swap_extent(
                                OP.get_via(get_prop_value, obj, "swap_width"),
                                w,
                                map_tile_w
                            )
                            local swap_height = resolve_breakable_swap_extent(
                                OP.get_via(get_prop_value, obj, "swap_height"),
                                h,
                                map_tile_h
                            )

                            add_prefab_instance(rows, obj_id, wall_proto, px, py, nil, nil, "breakable_wall", {
                                Prop.text("wall_id", wall_id),
                                Prop.text("wall_type", get_prop_value(obj, "wall_type") or "cracked"),
                                Prop.text("required_ability", opt(get_prop_value(obj, "required_ability"))),
                                Prop.number("health", get_prop_value(obj, "health"), 3),
                                Prop.text("room_id", rid),
                                Prop.text("reveals_secret", get_prop_value(obj, "reveals_secret") or ""),
                                Prop.text("drop_collectible", opt(get_prop_value(obj, "drop_collectible"))),
                                Prop.bool("swap_tiles_on_break", get_prop_value(obj, "swap_tiles_on_break"), true),
                                Prop.text("wall_layer", get_prop_value(obj, "wall_layer") or "wall"),
                                Prop.text("broken_wall_layer", get_prop_value(obj, "broken_wall_layer") or "broken_wall"),
                                Prop.number("swap_width", swap_width, w),
                                Prop.number("swap_height", swap_height, h),
                                Prop.text("particle_effect_name", get_prop_value(obj, "particle_effect_name") or "hit_impact"),
                                Prop.text("sound_break", get_prop_value(obj, "sound_break") or "wall_break"),
                            })
                            object_count = object_count + 1
                        elseif obj_type == "hazard" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 32, 128, 64)
                            local hazard_go_name = string.format("%s_hazard_%d.go", rid, obj.id)
                            local hazard_go_path = join(PATH.generated_go, hazard_go_name)
                            local hazard_proto = string.format("/developer/rooms/generated/%s", hazard_go_name)
                            if write_if_changed(hazard_go_path, gen_hazard_zone_go(w, h)) then
                                info("Created " .. hazard_go_path)
                            end
                            local hazard_id = get_prop_value(obj, "hazard_id") or obj.name or string.format("hazard_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, hazard_proto, px, py, nil, nil, "hazard_zone", {
                                { id = "hazard_id", value = hazard_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "hazard_type", value = get_prop_value(obj, "hazard_type") or "spikes", type = "PROPERTY_TYPE_TEXT" },
                                { id = "damage", value = number_to_proto(get_prop_value(obj, "damage"), 1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "damage_interval", value = number_to_proto(get_prop_value(obj, "damage_interval"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "stun_t", value = number_to_proto(get_prop_value(obj, "stun_t"), -1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "knockback_force", value = number_to_proto(OP.get_via(get_prop_value, obj, "knockback_force"), 300), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "required_resistance", value = opt(OP.get_via(get_prop_value, obj, "required_resistance", "")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "instant_kill", value = bool_to_proto(get_prop_value(obj, "instant_kill"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "enabled", value = bool_to_proto(get_prop_value(obj, "enabled"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "sound_on_hit", value = get_prop_value(obj, "sound_on_hit") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "retractable", value = bool_to_proto(get_prop_value(obj, "retractable"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "retract_time", value = number_to_proto(get_prop_value(obj, "retract_time"), 2.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "extend_time", value = number_to_proto(get_prop_value(obj, "extend_time"), 2.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "start_retracted", value = bool_to_proto(get_prop_value(obj, "start_retracted"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "arena_id", value = get_prop_value(obj, "arena_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "active_phases", value = get_prop_value(obj, "active_phases") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "pattern", value = opt(get_prop_value(obj, "pattern")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "pattern_speed", value = number_to_proto(get_prop_value(obj, "pattern_speed"), 1.0), type = "PROPERTY_TYPE_NUMBER" },
                                -- Retract visuals (painted spike tiles) need the zone size and layer.
                                { id = "zone_width", value = number_to_proto(w, 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "zone_height", value = number_to_proto(h, 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "retract_visual_layer", value = get_prop_value(obj, "retract_visual_layer") or "player", type = "PROPERTY_TYPE_TEXT" },
                                { id = "retract_hides_tiles", value = bool_to_proto(get_prop_value(obj, "retract_hides_tiles"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "light_source" then
                            local obj_w = tonumber(obj and obj.width) or 0
                            local obj_h = tonumber(obj and obj.height) or 0
                            local is_point_light = (obj_w <= 0 and obj_h <= 0) or (obj and (obj.point == true or obj.shape == "point"))

                            local px, py, sx, sy, w, h
                            if is_point_light then
                                px = tonumber(obj and obj.x) or 0
                                py = map_height - (tonumber(obj and obj.y) or 0)
                                sx, sy = 1, 1
                                w, h = 0, 0
                            else
                                px, py, sx, sy, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 16, 16, 32, 32)
                            end

                            local light_id = get_prop_value(obj, "light_id") or obj.name or string.format("light_%s_%d", rid, obj.id)
                            local configured_radius = tonumber(OP.get_via(get_prop_value, obj, "radius")) or 200
                            local derived_radius = configured_radius
                            if not is_point_light then
                                derived_radius = math.max(configured_radius, math.max(tonumber(w) or 0, tonumber(h) or 0) * 0.5)
                            end
                            add_prefab_instance(rows, obj_id, "/developer/game/prefabs/light_source.go", px, py, sx, sy, "script", {
                                { id = "light_id", value = light_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "radius", value = number_to_proto(derived_radius, 200), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "intensity", value = number_to_proto(get_prop_value(obj, "intensity"), 1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "enabled", value = bool_to_proto(get_prop_value(obj, "enabled"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "track_position", value = bool_to_proto(get_prop_value(obj, "track_position"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "joint_platform" or obj_type == "rail_elevator" then
                            local px, py, sx, sy, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 16, 128, 32)
                            local platform_id = get_prop_value(obj, "platform_id") or obj.name or string.format("rail_%s_%d", rid, obj.id)
                            local platform_type = tostring(get_prop_value(obj, "platform_type") or ""):lower()
                            local distance = tonumber(get_prop_value(obj, "distance")) or 0
                            local path_dx = tonumber(get_prop_value(obj, "path_dx")) or 0
                            local path_dy = tonumber(get_prop_value(obj, "path_dy")) or 0
                            if path_dx == 0 and path_dy == 0 then
                                if platform_type == "horizontal" then
                                    path_dx = distance ~= 0 and distance or 200
                                else
                                    path_dy = distance ~= 0 and distance or 160
                                end
                            end
                            local loop_mode = normalize_string_enum(
                                OP.get_via(get_prop_value, obj, "loop_mode"),
                                "pingpong",
                                { pingpong = true, loop = true }
                            )
                            add_prefab_instance(rows, obj_id, "/developer/game/prefabs/joint_platform.go", px, py, sx, sy, "script", {
                                Prop.text("room_id", rid),
                                Prop.number("path_dx", path_dx, 0),
                                Prop.number("path_dy", path_dy, 160),
                                Prop.number("duration", get_prop_value(obj, "duration"), 2),
                                Prop.number("wait", OP.get_via(get_prop_value, obj, "wait"), 0),
                                Prop.bool("enabled", get_prop_value(obj, "enabled"), true),
                                Prop.text("loop_mode", loop_mode),
                            })
                            object_count = object_count + 1
                            info(string.format("gen_collection: Baked rail platform %s size=%.0fx%.0f", tostring(platform_id), w, h))

                        elseif obj_type == "elevator" then
                            local elevator_id = opt(get_prop_value(obj, "elevator_id"))
                            if elevator_id == "" then
                                error(string.format(
                                    "[CREATE ROOMS] map '%s' elevator controller object id=%s requires elevator_id",
                                    tostring(rid), tostring(obj.id)
                                ))
                            end

                            local manifest_entry = _C.elevator_manifest
                                and _C.elevator_manifest.elevators
                                and _C.elevator_manifest.elevators[tostring(elevator_id)]
                                or nil
                            local controller_entry = manifest_entry and manifest_entry.controller or nil
                            local settings = manifest_entry and manifest_entry.settings or obj.properties or {}
                            local resource_key = manifest_entry and manifest_entry.resource_key
                                or _C.ElevatorManifest.resource_key(elevator_id)
                            local raw_w = tonumber(obj and obj.width) or 0
                            local raw_h = tonumber(obj and obj.height) or 0
                            local w, h = resolve_rect_size_pixels(
                                raw_w, raw_h, map_tile_w, map_tile_h, map_tile_w, map_tile_h)
                            local px = tonumber(controller_entry and controller_entry.local_x)
                                or tonumber(obj and obj.x) or 0
                            local py = tonumber(controller_entry and controller_entry.local_y)
                                or ((tonumber(defold_y) or 0) - h)

                            local source_tilemap_path = join(PATH.tilemaps, rid .. ".tilemap")
                            local source_tilemap_text = read_text(source_tilemap_path)
                            if type(source_tilemap_text) ~= "string" or source_tilemap_text == "" then
                                error(string.format(
                                    "[CREATE ROOMS] map '%s' elevator '%s' cannot read regenerated room tilemap %s",
                                    tostring(rid), tostring(elevator_id), tostring(source_tilemap_path)
                                ))
                            end

                            local source_layer = opt(settings.source_layer or get_prop_value(obj, "source_layer"))
                            if source_layer == "" then source_layer = "environment" end
                            local clear_source_tiles = settings.clear_source_tiles ~= false
                            local extraction, extraction_err = _C.ElevatorResources.extract_cabin(
                                source_tilemap_text,
                                {
                                    x = tonumber(controller_entry and controller_entry.tiled_x) or obj.x,
                                    y = tonumber(controller_entry and controller_entry.tiled_y) or obj.y,
                                    width = w,
                                    height = h,
                                    tile_width = map_tile_w,
                                    tile_height = map_tile_h,
                                    map_width = tiled_data.width,
                                    map_height = tiled_data.height,
                                    layer_name = source_layer,
                                }
                            )
                            if not extraction then
                                error(string.format(
                                    "[CREATE ROOMS] map '%s' elevator '%s' object id=%s cannot bake cabin art (%s). "
                                        .. "Snap the rectangle to the tile grid and paint its cabin tiles on the '%s' layer.",
                                    tostring(rid), tostring(elevator_id), tostring(obj.id),
                                    tostring(extraction_err or "unknown error"), tostring(source_layer)
                                ))
                            end

                            local cabin_bundle, cabin_bundle_err =
                                _C.ElevatorContract.resource_bundle(
                                    resource_key, _C.GENERATED_ROOMS_RESOURCE_DIR)
                            if not cabin_bundle then
                                error(string.format(
                                    "[CREATE ROOMS] elevator '%s' has no valid generated resource key: %s",
                                    tostring(elevator_id), tostring(cabin_bundle_err)
                                ))
                            end
                            local elevator_generated_dir = join(
                                PATH.generated_go, _C.ElevatorContract.RESOURCE_SUBDIR)
                            local elevator_collections_dir = join(
                                PATH.collections, _C.ElevatorContract.RESOURCE_SUBDIR)
                            local elevator_factories_dir = join(
                                PATH.factories, _C.ElevatorContract.RESOURCE_SUBDIR)
                            _C.ensure_dir(elevator_generated_dir)
                            _C.ensure_dir(elevator_collections_dir)
                            _C.ensure_dir(elevator_factories_dir)

                            local cabin_tilemap_path = join(
                                elevator_generated_dir, cabin_bundle.tilemap_name)
                            local cabin_go_path = join(
                                elevator_generated_dir, cabin_bundle.cabin_go_name)
                            local collision_go_path = join(
                                elevator_generated_dir, cabin_bundle.collision_go_name)
                            local cabin_collection_path = join(
                                elevator_collections_dir, cabin_bundle.collection_name)
                            local cabin_factory_path = join(
                                elevator_factories_dir, cabin_bundle.factory_name)
                            local cabin_tilemap_resource = cabin_bundle.tilemap_resource
                            local cabin_go_resource = cabin_bundle.cabin_go_resource
                            local collision_go_resource = cabin_bundle.collision_go_resource
                            local cabin_collection_resource = cabin_bundle.collection_resource

                            if clear_source_tiles
                                and write_if_changed(source_tilemap_path, extraction.source_tilemap)
                            then
                                info(string.format(
                                    "Updated %s (removed %d persistent elevator cabin tile(s))",
                                    source_tilemap_path, extraction.removed_cells or 0
                                ))
                            end
                            if write_if_changed(cabin_tilemap_path, extraction.cabin_tilemap) then
                                info("Created " .. cabin_tilemap_path)
                            end
                            if write_if_changed(cabin_go_path,
                                _C.ElevatorResources.generate_cabin_go(cabin_tilemap_resource))
                            then
                                info("Created " .. cabin_go_path)
                            end
                            local collision_height = tonumber(settings.collision_height) or h
                            local co_y_offset = tonumber(settings.co_y_offset) or 0
                            local sensor_y_offset = tonumber(settings.sensor_y_offset) or 0
                            local collision_go_text, collision_go_err =
                                _C.ElevatorContract.generate_collision_go({
                                    width = w,
                                    height = collision_height,
                                    co_y_offset = co_y_offset,
                                    sensor_y_offset = sensor_y_offset,
                                })
                            if not collision_go_text then
                                error(string.format(
                                    "[CREATE ROOMS] elevator '%s' cannot generate rider collision: %s",
                                    tostring(elevator_id), tostring(collision_go_err)
                                ))
                            end
                            if write_if_changed(collision_go_path, collision_go_text) then
                                info("Created " .. collision_go_path)
                            end

                            local cabin_collection_text, cabin_collection_err =
                                _C.ElevatorResources.generate_cabin_collection({
                                    resource_key = resource_key,
                                    root_resource = cabin_go_resource,
                                    collision_resource = collision_go_resource,
                                    elevator_id = elevator_id,
                                    trigger_id = opt(settings.trigger_id),
                                    width = w,
                                    height = h,
                                    carry_player = settings.carry_player ~= false,
                                    enabled = settings.enabled ~= false,
                                })
                            if not cabin_collection_text then
                                error(string.format(
                                    "[CREATE ROOMS] elevator '%s' cannot generate persistent collection: %s",
                                    tostring(elevator_id), tostring(cabin_collection_err)
                                ))
                            end
                            if write_if_changed(cabin_collection_path, cabin_collection_text) then
                                info("Created " .. cabin_collection_path)
                            end
                            local cabin_factory_text = _C.ElevatorResources.generate_collection_factory(
                                cabin_collection_resource)
                            if write_if_changed(cabin_factory_path, cabin_factory_text) then
                                info("Created " .. cabin_factory_path)
                            end

                            local seam_y = tonumber(settings.seam_y) or 0
                            local seam_authored = settings.seam_y_authored == true
                                or settings.auto_seam == false
                            local home_stop = manifest_entry and manifest_entry.start_node
                                and manifest_entry.start_node.stop or nil
                            home_stop = opt(home_stop)
                            if home_stop == "" then home_stop = "bottom" end
                            add_prefab_instance(
                                rows,
                                obj_id,
                                "/mvtk/prefabs/elevator_controller.go",
                                px,
                                py,
                                nil,
                                nil,
                                "script",
                                {
                                    Prop.text("elevator_id", elevator_id),
                                    Prop.text("trigger_id", opt(settings.trigger_id)),
                                    Prop.text("cabin_resource_key", resource_key),
                                    Prop.text("start_node_id",
                                        opt(controller_entry and controller_entry.start_node_id
                                            or get_prop_value(obj, "start_node_id"))),
                                    Prop.text("home_stop", home_stop),
                                    Prop.number("speed", settings.speed, 96),
                                    Prop.number("acceleration", settings.acceleration, 384),
                                    Prop.number("deceleration", settings.deceleration, 384),
                                    Prop.number("endpoint_wait", settings.endpoint_wait, 0.35),
                                    Prop.number("start_delay", settings.start_delay, 0),
                                    Prop.number("close_time", settings.close_time, 0.25),
                                    Prop.number("open_time", settings.open_time, 0.25),
                                    Prop.number("ready_timeout", settings.ready_timeout, 5),
                                    Prop.number("seam_y", seam_y, 0),
                                    Prop.bool("seam_y_authored", seam_authored, false),
                                    Prop.number("camera_priority", settings.camera_priority, 50),
                                    Prop.text("route_mode", settings.route_mode or "pingpong"),
                                    Prop.text("activation_mode", settings.activation_mode or "on_board"),
                                    Prop.bool("require_interact", settings.require_interact, false),
                                    Prop.number("floor_offset", settings.floor_offset, h),
                                    Prop.bool("carry_player", settings.carry_player, true),
                                    Prop.bool("carry_enemies", settings.carry_enemies, false),
                                    Prop.bool("carry_pushables", settings.carry_pushables, true),
                                    Prop.bool("require_rider", settings.require_rider, true),
                                    Prop.number("shaft_clearance", settings.shaft_clearance, 0),
                                    Prop.number("shaft_tolerance", settings.shaft_tolerance, 0.5),
                                    Prop.bool("camera_follow", settings.camera_follow, true),
                                    Prop.bool("camera_lock_x", settings.camera_lock_x, true),
                                    Prop.number("camera_look_ahead", settings.camera_look_ahead, 96),
                                    Prop.number("camera_blend_time", settings.camera_blend_time, 0.2),
                                    Prop.bool("persist_landing", settings.persist_landing, true),
                                    Prop.bool("restore_to_last_landing", settings.restore_to_last_landing, true),
                                    Prop.number("width", w, 128),
                                    Prop.number("height", h, 32),
                                    Prop.bool("enabled", settings.enabled, true),
                                }
                            )
                            object_count = object_count + 1
                            info(string.format(
                                "gen_collection: Baked persistent elevator '%s' resource=%s art_tiles=%d size=%.0fx%.0f",
                                tostring(elevator_id), tostring(resource_key),
                                extraction.copied_cells or 0, w, h
                            ))

                        elseif obj_type == "elevator_node" then
                            local elevator_id = opt(get_prop_value(obj, "elevator_id"))
                            local node_id = opt(get_prop_value(obj, "node_id"))
                            if elevator_id == "" or node_id == "" then
                                error(string.format(
                                    "[CREATE ROOMS] map '%s' elevator_node object id=%s requires elevator_id and node_id",
                                    tostring(rid), tostring(obj.id)
                                ))
                            end
                            local manifest_entry = _C.elevator_manifest
                                and _C.elevator_manifest.elevators
                                and _C.elevator_manifest.elevators[tostring(elevator_id)]
                                or nil
                            local source_key = tostring(rid) .. ":" .. tostring(obj.id)
                            local node_entry = nil
                            for _, candidate in ipairs((manifest_entry and manifest_entry.nodes) or {}) do
                                if candidate.source_key == source_key then node_entry = candidate break end
                            end
                            local stop = tostring((node_entry and node_entry.stop)
                                or get_prop_value(obj, "stop") or ""):lower()
                            if stop == "none" then stop = "" end
                            local node_kind = tostring((node_entry and node_entry.kind)
                                or get_prop_value(obj, "node_kind") or "landing"):lower()
                            if node_kind == "pass_through" or node_kind == "passthrough" then
                                stop = ""
                            end
                            add_prefab_instance(
                                rows,
                                obj_id,
                                "/mvtk/prefabs/elevator_node.go",
                                tonumber(node_entry and node_entry.local_x) or tonumber(obj and obj.x) or 0,
                                tonumber(node_entry and node_entry.local_y) or tonumber(defold_y) or 0,
                                nil,
                                nil,
                                "script",
                                {
                                    Prop.text("elevator_id", elevator_id),
                                    Prop.text("node_id", node_id),
                                    Prop.text("node_kind", node_kind),
                                    Prop.text("stop", stop),
                                    Prop.text("room_id", rid),
                                    Prop.text("door_id", opt(get_prop_value(obj, "door_id"))),
                                }
                            )
                            object_count = object_count + 1

                        elseif obj_type == "platform" or obj_type == "moving_platform" then
                            local raw_x = tonumber(obj and obj.x) or 0
                            local raw_y = tonumber(defold_y) or 0
                            local raw_w = tonumber(obj and obj.width) or 0
                            local raw_h = tonumber(obj and obj.height) or 0
                            local w, h = resolve_rect_size_pixels(raw_w, raw_h, map_tile_w, map_tile_h, map_tile_w, map_tile_h)
                            local px = raw_x
                            local py = raw_y - h
                            local collision_h = tonumber(get_prop_value(obj, "collision_height")) or h
                            local co_y_offset = tonumber(get_prop_value(obj, "co_y_offset")) or 0
                            local sensor_y_offset = tonumber(get_prop_value(obj, "sensor_y_offset")) or 0
                            local platform_go_name = string.format("%s_moving_platform_%d.go", rid, obj.id)
                            local platform_go_path = join(PATH.generated_go, platform_go_name)
                            local platform_collision_go_name = string.format("%s_moving_platform_%d_collision.go", rid, obj.id)
                            local platform_collision_go_path = join(PATH.generated_go, platform_collision_go_name)
                            local platform_tilemap_name = string.format("%s_moving_platform_%d.tilemap", rid, obj.id)
                            local platform_tilemap_path = join(PATH.generated_go, platform_tilemap_name)
                            local platform_tilemap_resource = string.format("/developer/rooms/generated/%s", platform_tilemap_name)
                            local platform_proto = string.format("/developer/rooms/generated/%s", platform_go_name)
                            local platform_collision_proto = string.format("/developer/rooms/generated/%s", platform_collision_go_name)
                            local baked_art = _C.PlatformResources.capture(
                                read_text(join(PATH.tilemaps, rid .. ".tilemap")), {
                                    x = px, y = py, width = w, height = h,
                                    tile_width = map_tile_w, tile_height = map_tile_h,
                                    source_layer = opt(get_prop_value(obj, "source_layer") or get_prop_value(obj, "visual_layer")),
                                })
                            if baked_art then
                                px, py = baked_art.x, baked_art.y
                                w, h = baked_art.width, baked_art.height
                                collision_h = tonumber(get_prop_value(obj, "collision_height")) or h
                            end
                            local platform_tilesource, tilesource_err = _visual.resolve_room_tilesource_resource(rid)
                            if not platform_tilesource then
                                error(string.format(
                                    "[CREATE ROOMS] map '%s' moving_platform object id=%s cannot resolve an existing tilesource: %s",
                                    tostring(rid), tostring(obj.id), tostring(tilesource_err or "unknown error")
                                ))
                            end
                            local platform_tilemap_text, platform_tilemap_err = _visual.gen_platform_tilemap(platform_tilesource, w, h, map_tile_w, map_tile_h)
                            if baked_art then platform_tilemap_text = baked_art.tilemap end
                            if not platform_tilemap_text then
                                error(string.format(
                                    "[CREATE ROOMS] map '%s' moving_platform object id=%s cannot generate its tilemap: %s",
                                    tostring(rid), tostring(obj.id), tostring(platform_tilemap_err or "unknown error")
                                ))
                            end
                            if not baked_art then
                                info(string.format(
                                    "[CREATE ROOMS][WARNING] map '%s' moving_platform object id=%s has no tiles under its rectangle on art/player (or legacy environment); draw platform tiles there in Tiled or the platform will be invisible.",
                                    tostring(rid), tostring(obj.id)
                                ))
                            end
                            if write_if_changed(platform_tilemap_path, platform_tilemap_text) then
                                info("Created " .. platform_tilemap_path)
                            end
                            if write_if_changed(platform_go_path, _visual.gen_tile_platform_go(w, h, collision_h, co_y_offset, sensor_y_offset, platform_tilemap_resource)) then
                                info("Created " .. platform_go_path)
                            end
                            if write_if_changed(platform_collision_go_path, _visual.gen_tile_platform_collision_go(w, h, collision_h, co_y_offset, sensor_y_offset)) then
                                info("Created " .. platform_collision_go_path)
                            end

                            local platform_id = opt(get_prop_value(obj, "platform_id"))
                            if platform_id == "" then
                                platform_id = string.format("platform_%s_%d", rid, obj.id)
                            end
                            local path_name = get_prop_value(obj, "path_name") or ""
                            local platform_type = tostring(get_prop_value(obj, "platform_type") or ""):lower()
                            if platform_type == "" then
                                local obj_name = tostring(obj.name or ""):lower()
                                if obj_name:find("vertical", 1, true) then
                                    platform_type = "vertical"
                                elseif obj_name:find("horizontal", 1, true) then
                                    platform_type = "horizontal"
                                elseif obj_name:find("path", 1, true) or tostring(path_name) ~= "" then
                                    platform_type = "path"
                                elseif obj_type == "moving_platform" then
                                    platform_type = "path"
                                else
                                    platform_type = "horizontal"
                                end
                            end
                            platform_type = normalize_string_enum(platform_type, "horizontal", {
                                horizontal = true,
                                vertical = true,
                                path = true,
                                circular = true,
                            })

                            local distance = tonumber(get_prop_value(obj, "distance")) or 0
                            local path_dx = 0
                            local path_dy = 0
                            if platform_type == "horizontal" then
                                path_dx = distance
                            elseif platform_type == "vertical" then
                                path_dy = distance
                            elseif platform_type == "path" and tostring(path_name) == "" then
                                info(string.format(
                                    "gen_collection: platform '%s' has no path_name; it will remain stationary until authored in Tiled",
                                    platform_go_name
                                ))
                            end

                            local platform_obj_id = string.format("%s_moving_platform_%d", rid, obj.id)
                            local platform_collision_obj_id = platform_obj_id .. "_collision"
                            local loop_mode = normalize_string_enum(
                                OP.get_via(get_prop_value, obj, "loop_mode"),
                                "pingpong",
                                { pingpong = true, loop = true, once = true }
                            )
                            add_prefab_instance(rows, platform_obj_id, platform_proto, px, py, nil, nil, "script", {
                                Prop.text("platform_id", platform_id),
                                Prop.number("object_id", obj.id, 0),
                                Prop.text("platform_type", platform_type),
                                Prop.text("path_name", path_name),
                                Prop.number("path_dx", path_dx, 0),
                                Prop.number("path_dy", path_dy, 0),
                                Prop.number("speed", get_prop_value(obj, "speed"), 0),
                                Prop.number("wait", OP.get_via(get_prop_value, obj, "wait"), 0),
                                Prop.text("loop_mode", loop_mode),
                                Prop.bool("enabled", get_prop_value(obj, "enabled"), true),
                                Prop.number("start_delay", get_prop_value(obj, "start_delay"), 0),
                                Prop.text("trigger_id", get_prop_value(obj, "trigger_id") or ""),
                                Prop.bool("player_parent", get_prop_value(obj, "player_parent"), true),
                                Prop.text("room_id", rid),
                                Prop.bool("tiles_baked", baked_art ~= nil, false),
                                Prop.text("source_layer", baked_art and baked_art.source_layer or "environment"),
                                Prop.number("width", w, 128),
                                Prop.number("height", h, 128),
                            }, nil, { platform_collision_obj_id })
                            add_prefab_instance(rows, platform_collision_obj_id, platform_collision_proto, 0, 0)
                            object_count = object_count + 1

                        elseif obj_type == "crumble_platform" then
                            local raw_x = tonumber(obj and obj.x) or 0
                            local raw_y = tonumber(defold_y) or 0
                            local raw_w = tonumber(obj and obj.width) or 0
                            local raw_h = tonumber(obj and obj.height) or 0
                            local w, h = resolve_rect_size_pixels(raw_w, raw_h, map_tile_w, map_tile_h, map_tile_w, map_tile_h)
                            local px = raw_x
                            local py = raw_y - h
                            local co_y_offset = tonumber(get_prop_value(obj, "co_y_offset")) or 0
                            local sensor_y_offset = tonumber(get_prop_value(obj, "sensor_y_offset")) or 0
                            local crumble_go_name = string.format("%s_crumble_platform_%d.go", rid, obj.id)
                            local crumble_go_path = join(PATH.generated_go, crumble_go_name)
                            local crumble_collision_go_name = string.format("%s_crumble_platform_%d_collision.go", rid, obj.id)
                            local crumble_collision_go_path = join(PATH.generated_go, crumble_collision_go_name)
                            local crumble_tilemap_name = string.format("%s_crumble_platform_%d.tilemap", rid, obj.id)
                            local crumble_tilemap_path = join(PATH.generated_go, crumble_tilemap_name)
                            local crumble_tilemap_resource = string.format("/developer/rooms/generated/%s", crumble_tilemap_name)
                            local crumble_proto = string.format("/developer/rooms/generated/%s", crumble_go_name)
                            local crumble_collision_proto = string.format("/developer/rooms/generated/%s", crumble_collision_go_name)
                            local crumble_tilesource, tilesource_err = _visual.resolve_room_tilesource_resource(rid)
                            if not crumble_tilesource then
                                error(string.format(
                                    "[CREATE ROOMS] map '%s' crumble_platform object id=%s cannot resolve an existing tilesource: %s",
                                    tostring(rid), tostring(obj.id), tostring(tilesource_err or "unknown error")
                                ))
                            end
                            local crumble_tilemap_text, crumble_tilemap_err = _visual.gen_platform_tilemap(crumble_tilesource, w, h, map_tile_w, map_tile_h)
                            if not crumble_tilemap_text then
                                error(string.format(
                                    "[CREATE ROOMS] map '%s' crumble_platform object id=%s cannot generate its tilemap: %s",
                                    tostring(rid), tostring(obj.id), tostring(crumble_tilemap_err or "unknown error")
                                ))
                            end
                            local crumble_visual_layer = get_prop_value(obj, "visual_layer") or "environment"
                            if not rect_has_authored_tile(tiled_data, obj, w, h, crumble_visual_layer) then
                                info(string.format(
                                    "[CREATE ROOMS][WARNING] map '%s' crumble_platform object id=%s has no tiles under its rectangle on the '%s' layer; draw platform tiles there in Tiled or the platform will be invisible.",
                                    tostring(rid), tostring(obj.id), tostring(crumble_visual_layer)
                                ))
                            end
                            if write_if_changed(crumble_tilemap_path, crumble_tilemap_text) then
                                info("Created " .. crumble_tilemap_path)
                            end
                            if write_if_changed(crumble_go_path, _visual.gen_crumble_platform_go(w, h, co_y_offset, sensor_y_offset, crumble_tilemap_resource)) then
                                info("Created " .. crumble_go_path)
                            end
                            if write_if_changed(crumble_collision_go_path, _visual.gen_crumble_platform_collision_go(w, h, co_y_offset, sensor_y_offset)) then
                                info("Created " .. crumble_collision_go_path)
                            end
                            local platform_id = get_prop_value(obj, "platform_id") or string.format("crumble_%s_%d", rid, obj.id)
                            local crumble_obj_id = string.format("%s_crumble_platform_%d", rid, obj.id)
                            local crumble_collision_obj_id = crumble_obj_id .. "_collision"
                            add_prefab_instance(rows, crumble_obj_id, crumble_proto, px, py, nil, nil, "script", {
                                { id = "platform_id", value = platform_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "crumble_delay", value = number_to_proto(get_prop_value(obj, "crumble_delay"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "respawn_delay", value = number_to_proto(get_prop_value(obj, "respawn_delay"), 3.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "shake_before_crumble", value = bool_to_proto(get_prop_value(obj, "shake_before_crumble"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "one_way", value = bool_to_proto(get_prop_value(obj, "one_way"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "clear_visual_layer_tiles", value = bool_to_proto(get_prop_value(obj, "clear_visual_layer_tiles"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "visual_layer", value = get_prop_value(obj, "visual_layer") or "environment", type = "PROPERTY_TYPE_TEXT" },
                                { id = "co_y_offset", value = number_to_proto(co_y_offset, 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "sensor_y_offset", value = number_to_proto(sensor_y_offset, 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "width", value = number_to_proto(w, 128), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "height", value = number_to_proto(h, 128), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                                { id = "collision_url", value = crumble_collision_obj_id .. "#co", type = "PROPERTY_TYPE_URL" },
                                -- The old fallback ids were not shipped in sound_bank.lua.
                                { id = "sound_crumble", value = opt(get_prop_value(obj, "sound_crumble")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_respawn", value = opt(get_prop_value(obj, "sound_respawn")), type = "PROPERTY_TYPE_TEXT" },
                            }, nil, { crumble_collision_obj_id })
                            add_prefab_instance(rows, crumble_collision_obj_id, crumble_collision_proto, 0, 0)
                            object_count = object_count + 1

                        elseif obj_type == "bounce_pad" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 32, 8, 64, 16)
                            local bounce_go_name = string.format("%s_bounce_pad_%d.go", rid, obj.id)
                            local bounce_go_path = join(PATH.generated_go, bounce_go_name)
                            local bounce_proto = string.format("/developer/rooms/generated/%s", bounce_go_name)
                            if write_if_changed(bounce_go_path, gen_bounce_pad_go(w, h, nil, nil, nil, nil, nil, nil, nil, nil, _visual.uses_defold_sprite(obj, obj_type))) then
                                info("Created " .. bounce_go_path)
                            end
                            add_prefab_instance(rows, obj_id, bounce_proto, px, py, nil, nil, "script", {
                                Prop.number("bounce_speed", get_prop_value(obj, "bounce_speed"), 900),
                                Prop.number("cooldown", get_prop_value(obj, "cooldown"), 0.2),
                                Prop.bool("require_interact", get_prop_value(obj, "require_interact"), false),
                                Prop.text("label", get_prop_value(obj, "label") or "Bounce"),
                                Prop.text("sound_id", opt(get_prop_value(obj, "sound_id"))),
                                Prop.number("range", get_prop_value(obj, "range"), 80),
                            })
                            object_count = object_count + 1

                        elseif obj_type == "conveyor" then
                            local conveyor_id = get_prop_value(obj, "conveyor_id")
                            if conveyor_id == nil or tostring(conveyor_id) == "" then
                                conveyor_id = obj.name or string.format("conveyor_%s_%d", rid, obj.id)
                            end
                            local px, py, _, _, w, h = rect_center_and_scale(
                                obj,
                                defold_y,
                                map_tile_w,
                                map_tile_h,
                                64,
                                64,
                                128,
                                16,
                                { use_defold_sprite = _visual.uses_defold_sprite(obj, obj_type) }
                            )
                            local conveyor_go_name = string.format("%s_conveyor_%d.go", rid, obj.id)
                            local conveyor_go_path = join(PATH.generated_go, conveyor_go_name)
                            local conveyor_proto = string.format("/developer/rooms/generated/%s", conveyor_go_name)
                            local direction = normalize_string_enum(get_prop_value(obj, "direction"), "right", {
                                left = true,
                                right = true,
                                up = true,
                                down = true,
                            })
                            local conveyor_props = {
                                Prop.text("conveyor_id", conveyor_id),
                                Prop.text("direction", direction),
                                Prop.number("speed", get_prop_value(obj, "speed"), 100),
                                Prop.number("width", w, 128),
                                Prop.number("height", h, 16),
                                Prop.bool("affects_enemies", get_prop_value(obj, "affects_enemies"), true),
                                Prop.bool("affects_items", get_prop_value(obj, "affects_items"), false),
                                Prop.bool("enabled", get_prop_value(obj, "enabled"), true),
                                Prop.number("animation_speed", get_prop_value(obj, "animation_speed"), 1.0),
                                Prop.text("room_id", rid),
                            }
                            local baked_ok, baked_result = write_sized_rect_generated_go(
                                conveyor_go_path,
                                "/developer/game/prefabs/conveyor.go",
                                w,
                                h,
                                64,
                                8,
                                128,
                                16,
                                { use_defold_sprite = _visual.uses_defold_sprite(obj, obj_type) }
                            )
                            if baked_ok then
                                if baked_result then
                                    info("Created " .. conveyor_go_path)
                                end
                                add_prefab_instance(rows, obj_id, conveyor_proto, px, py, nil, nil, "script", conveyor_props)
                            else
                                info(string.format(
                                    "[ROOM_GEN] Conveyor sizing helper failed for %s: %s; falling back to scaled prefab instance",
                                    conveyor_go_name,
                                    tostring(baked_result)
                                ))
                                add_rect_prefab_instance(
                                    rows,
                                    obj_id,
                                    _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/conveyor.go"),
                                    obj,
                                    defold_y,
                                    map_tile_w,
                                    map_tile_h,
                                    64,
                                    8,
                                    128,
                                    16,
                                    "script",
                                    conveyor_props
                                )
                            end
                            object_count = object_count + 1

                        elseif obj_type == "one_way_platform" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 128, 16, 256, 32)
                            local one_way_go_name = string.format("%s_one_way_platform_%d.go", rid, obj.id)
                            local one_way_go_path = join(PATH.generated_go, one_way_go_name)
                            local one_way_proto = string.format("/developer/rooms/generated/%s", one_way_go_name)
                            local direction = normalize_string_enum(get_prop_value(obj, "direction"), "down", {
                                up = true,
                                down = true,
                            })
                            if write_if_changed(one_way_go_path, gen_one_way_platform_go(w, h, direction, rid, _visual.uses_defold_sprite(obj, obj_type))) then
                                info("Created " .. one_way_go_path)
                            end
                            add_prefab_instance(rows, obj_id, one_way_proto, px, py, nil, nil, "script", {
                                Prop.text("direction", direction),
                                Prop.text("room_id", rid),
                            })
                            object_count = object_count + 1

                        elseif obj_type == "teleporter" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            local teleporter_go_name = string.format("%s_teleporter_%d.go", rid, obj.id)
                            local teleporter_go_path = join(PATH.generated_go, teleporter_go_name)
                            local teleporter_proto = string.format("/developer/rooms/generated/%s", teleporter_go_name)
                            if write_if_changed(teleporter_go_path, gen_teleporter_go(w, h, _visual.uses_defold_sprite(obj, obj_type))) then
                                info("Created " .. teleporter_go_path)
                            end
                            local teleporter_id = get_prop_value(obj, "teleporter_id") or obj.name or string.format("teleporter_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, teleporter_proto, px, py, nil, nil, "script", {
                                { id = "teleporter_id", value = teleporter_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "pair_id", value = get_prop_value(obj, "pair_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "target_id", value = get_prop_value(obj, "target_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                                { id = "requires_flag", value = get_prop_value(obj, "requires_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "hide_when_locked", value = bool_to_proto(get_prop_value(obj, "hide_when_locked"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "active_effect_id", value = get_prop_value(obj, "active_effect_id") or "collectible_sparkle", type = "PROPERTY_TYPE_TEXT" },
                                { id = "unlock_effect_id", value = opt(get_prop_value(obj, "unlock_effect_id")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "require_interact", value = bool_to_proto(get_prop_value(obj, "require_interact"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "cooldown", value = number_to_proto(get_prop_value(obj, "cooldown"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "transition_time", value = number_to_proto(get_prop_value(obj, "transition_time"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "preserve_velocity", value = bool_to_proto(get_prop_value(obj, "preserve_velocity"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "facing", value = number_to_proto(get_prop_value(obj, "facing"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "label", value = get_prop_value(obj, "label") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "fade_out", value = number_to_proto(get_prop_value(obj, "fade_out"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "fade_in", value = number_to_proto(get_prop_value(obj, "fade_in"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "one_way", value = bool_to_proto(get_prop_value(obj, "one_way"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "pressure_plate" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 16, 128, 32)
                            local plate_go_name = string.format("%s_pressure_plate_%d.go", rid, obj.id)
                            local plate_go_path = join(PATH.generated_go, plate_go_name)
                            local plate_proto = string.format("/developer/rooms/generated/%s", plate_go_name)
                            if write_if_changed(plate_go_path, gen_pressure_plate_go(w, h, _visual.uses_defold_sprite(obj, obj_type))) then
                                info("Created " .. plate_go_path)
                            end
                            local plate_id = get_prop_value(obj, "plate_id") or obj.name or string.format("plate_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, plate_proto, px, py, nil, nil, "script", {
                                { id = "plate_id", value = plate_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "target_id", value = get_prop_value(obj, "target_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "required_count", value = number_to_proto(get_prop_value(obj, "required_count"), 1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "allow_player", value = bool_to_proto(get_prop_value(obj, "allow_player"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "allow_world", value = bool_to_proto(get_prop_value(obj, "allow_world"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "allow_enemy", value = bool_to_proto(get_prop_value(obj, "allow_enemy"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "stays_pressed", value = bool_to_proto(get_prop_value(obj, "stays_pressed"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "message_on", value = get_prop_value(obj, "message_on") or "activate", type = "PROPERTY_TYPE_TEXT" },
                                { id = "message_off", value = get_prop_value(obj, "message_off") or "deactivate", type = "PROPERTY_TYPE_TEXT" },
                                { id = "set_flag", value = get_prop_value(obj, "set_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_on", value = opt(get_prop_value(obj, "sound_on")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_off", value = opt(get_prop_value(obj, "sound_off")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "anim_tilemap", value = get_prop_value(obj, "anim_tilemap") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "anim_layer", value = get_prop_value(obj, "anim_layer") or "", type = "PROPERTY_TYPE_TEXT" },
                                -- Convert plate world position to tilemap cell (1-based) plus user offset.
                                { id = "anim_tile_x", value = math.floor(px / map_tile_w) + 1 + (tonumber(get_prop_value(obj, "anim_offset_x")) or 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "anim_tile_y", value = math.floor(py / map_tile_h) + 1 + (tonumber(get_prop_value(obj, "anim_offset_y")) or 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "tile_on", value = number_to_proto(get_prop_value(obj, "tile_on"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "tile_off", value = number_to_proto(get_prop_value(obj, "tile_off"), 0), type = "PROPERTY_TYPE_NUMBER" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "timed_door" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 32, 64, 64, 128)
                            local door_go_name = string.format("%s_timed_door_%d.go", rid, obj.id)
                            local door_go_path = join(PATH.generated_go, door_go_name)
                            local door_proto = string.format("/developer/rooms/generated/%s", door_go_name)
                            local ok_sized, sized_err = write_sized_rect_generated_go(
                                door_go_path,
                                "/developer/game/prefabs/timed_door.go",
                                w, h, 64, 64, 128, 128,
                                { use_defold_sprite = _visual.uses_defold_sprite(obj, obj_type) }
                            )
                            if not ok_sized then
                                info(string.format("timed_door: failed to generate sized prefab for %s: %s", obj_id, tostring(sized_err)))
                            elseif ok_sized then
                                info("Created " .. door_go_path)
                            end
                            local door_id = get_prop_value(obj, "door_id") or obj.name or string.format("door_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, door_proto, px, py, nil, nil, "script", {
                                { id = "door_id", value = door_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "open_duration", value = number_to_proto(get_prop_value(obj, "open_duration"), 2.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "starts_open", value = bool_to_proto(get_prop_value(obj, "starts_open"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "auto_close", value = bool_to_proto(get_prop_value(obj, "auto_close"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "close_on_release", value = bool_to_proto(get_prop_value(obj, "close_on_release"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "message_on", value = get_prop_value(obj, "message_on") or "activate", type = "PROPERTY_TYPE_TEXT" },
                                { id = "message_off", value = get_prop_value(obj, "message_off") or "deactivate", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_open", value = get_prop_value(obj, "sound_open") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_close", value = get_prop_value(obj, "sound_close") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "hide_when_open", value = bool_to_proto(get_prop_value(obj, "hide_when_open"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "locked_door" then
                            info(string.format("[locked_door] begin rid=%s obj.id=%s name=%s raw=(x=%s,y=%s,w=%s,h=%s)",
                                tostring(rid), tostring(obj.id), tostring(obj.name),
                                tostring(obj.x), tostring(obj.y), tostring(obj.width), tostring(obj.height)))
                            local px, py, sx, sy, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            info(string.format("[locked_door] rect_center_and_scale -> px=%.2f py=%.2f sx=%.3f sy=%.3f w=%.2f h=%.2f",
                                px, py, sx, sy, w, h))
                            local door_go_name = string.format("%s_locked_door_%d.go", rid, obj.id)
                            local door_go_path = join(PATH.generated_go, door_go_name)
                            local door_proto = string.format("/developer/rooms/generated/%s", door_go_name)
                            info(string.format("[locked_door] writing sized prefab %s from door_blocker.go (full %dx%d, base_half 64x64)",
                                door_go_path, math.floor(w + 0.5), math.floor(h + 0.5)))
                            local ok_sized, sized_err = write_sized_rect_generated_go(
                                door_go_path,
                                "/developer/game/prefabs/door_blocker.go",
                                w, h, 64, 64, 128, 128
                            )
                            if not ok_sized then
                                info(string.format("[locked_door] FAILED to generate sized prefab for %s: %s", obj_id, tostring(sized_err)))
                            else
                                info("[locked_door] Created " .. door_go_path)
                            end
                            local door_id = get_prop_value(obj, "door_id") or obj.name or string.format("locked_door_%s_%d", rid, obj.id)
                            info(string.format("[locked_door] door_id=%s require_ability=%s require_key=%s require_item=%s consume_key=%s starts_locked=%s",
                                tostring(door_id),
                                tostring(get_prop_value(obj, "require_ability")),
                                tostring(get_prop_value(obj, "require_key")),
                                tostring(get_prop_value(obj, "require_item")),
                                tostring(get_prop_value(obj, "consume_key")),
                                tostring(get_prop_value(obj, "starts_locked"))))
                            add_prefab_instance(rows, obj_id, door_proto, px, py, nil, nil, "door_blocker", {
                                { id = "door_id", value = door_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "require_ability", value = opt(get_prop_value(obj, "require_ability")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "require_key", value = KeyIds.canonicalize(opt(get_prop_value(obj, "require_key"))) or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "require_item", value = KeyIds.canonicalize(opt(get_prop_value(obj, "require_item"))) or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "consume_key", value = bool_to_proto(get_prop_value(obj, "consume_key"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "unlock_message", value = get_prop_value(obj, "unlock_message") or "unlock", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_locked", value = opt(get_prop_value(obj, "sound_locked")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_unlock", value = opt(get_prop_value(obj, "sound_unlock")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "starts_locked", value = bool_to_proto(get_prop_value(obj, "starts_locked"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "spawn_point" or obj_type == "player_spawn" or obj_type == "player_start" or obj_type == "respawn_point" then
                            add_prefab_instance(
                                rows,
                                obj_id,
                                "/developer/game/prefabs/spawn_point_marker.go",
                                obj.x,
                                defold_y,
                                nil,
                                nil,
                                "script",
                                AuthoredProxy.build_spawn_point_marker_props(obj, rid, obj_id)
                            )
                            object_count = object_count + 1

                        elseif obj_type == "boss" then
                            add_prefab_instance(
                                rows,
                                obj_id,
                                "/developer/game/prefabs/boss_spawn_marker.go",
                                obj.x,
                                defold_y,
                                nil,
                                nil,
                                "script",
                                AuthoredProxy.build_boss_spawn_marker_props(obj, rid, obj_id)
                            )
                            object_count = object_count + 1

                        elseif obj_type == "boss_phase" then
                            add_prefab_instance(
                                rows,
                                obj_id,
                                "/developer/game/prefabs/boss_phase_marker.go",
                                obj.x,
                                defold_y,
                                nil,
                                nil,
                                "script",
                                AuthoredProxy.build_boss_phase_marker_props(obj, rid, obj_id)
                            )
                            object_count = object_count + 1

                        elseif obj_type == "end_game" then
                            local px,py,_,_,w,h=rect_center_and_scale(obj,defold_y,map_tile_w,map_tile_h,64,64,128,128)
                            local go_name=string.format("%s_end_game_%d.go",rid,obj.id)
                            assert(write_sized_rect_generated_go(join(PATH.generated_go,go_name),"/developer/game/prefabs/end_game.go",w,h,64,64,128,128))
                            add_prefab_instance(rows,obj_id,"/developer/rooms/generated/"..go_name,px,py,nil,nil,"script",{
                                {id="completion_id",value=get_prop_value(obj,"completion_id") or "ending",type="PROPERTY_TYPE_TEXT"},
                                {id="room_id",value=rid,type="PROPERTY_TYPE_TEXT"},
                                {id="zone_width",value=tostring(w),type="PROPERTY_TYPE_NUMBER"},
                                {id="zone_height",value=tostring(h),type="PROPERTY_TYPE_NUMBER"},
                            })
                            object_count=object_count+1
                        elseif obj_type == "boss_arena" then
                            local px, py, sx, sy, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            add_prefab_instance(
                                rows,
                                obj_id,
                                "/developer/game/prefabs/boss_arena_marker.go",
                                px,
                                py,
                                sx,
                                sy,
                                "script",
                                AuthoredProxy.build_boss_arena_marker_props(obj, rid, obj_id, w, h)
                            )
                            object_count = object_count + 1

                        elseif obj_type == "arena_lock" then
                            local px, py, sx, sy, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            add_prefab_instance(
                                rows,
                                obj_id,
                                "/developer/game/prefabs/arena_lock_marker.go",
                                px,
                                py,
                                sx,
                                sy,
                                "script",
                                AuthoredProxy.build_arena_lock_marker_props(obj, rid, obj_id, w, h)
                            )
                            object_count = object_count + 1

                        elseif obj_type == "arena_boundary" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 32, 32, 64, 64)
                            local go_name = string.format("%s_arena_boundary_%d.go", rid, obj.id)
                            local go_path = join(PATH.generated_go, go_name)
                            local proto = string.format("/developer/rooms/generated/%s", go_name)
                            local ok_sized, sized_err = write_sized_rect_generated_go(
                                go_path, "/developer/game/prefabs/arena_boundary.go",
                                w, h, 32, 32, 64, 64
                            )
                            if not ok_sized then
                                info(string.format("arena_boundary: failed to generate sized prefab for %s: %s", obj_id, tostring(sized_err)))
                            else
                                info("Created " .. go_path)
                            end
                            local boundary_id = get_prop_value(obj, "boundary_id") or obj.name or string.format("boundary_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, proto, px, py, nil, nil, "script", {
                                { id = "boundary_id", value = boundary_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "arena_id", value = get_prop_value(obj, "arena_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "active_phases", value = get_prop_value(obj, "active_phases") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "enabled_when_locked", value = bool_to_proto(get_prop_value(obj, "enabled_when_locked"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "start_enabled", value = bool_to_proto(get_prop_value(obj, "start_enabled"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "poll_interval", value = number_to_proto(get_prop_value(obj, "poll_interval"), 0.25), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "boss_phase_trigger" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            local go_name = string.format("%s_boss_phase_trigger_%d.go", rid, obj.id)
                            local go_path = join(PATH.generated_go, go_name)
                            local proto = string.format("/developer/rooms/generated/%s", go_name)
                            local ok_sized, sized_err = write_sized_rect_generated_go(
                                go_path, "/developer/game/prefabs/boss_phase_trigger.go",
                                w, h, 64, 64, 128, 128
                            )
                            if not ok_sized then
                                info(string.format("boss_phase_trigger: failed to generate sized prefab for %s: %s", obj_id, tostring(sized_err)))
                            else
                                info("Created " .. go_path)
                            end
                            local trigger_id = get_prop_value(obj, "trigger_id") or obj.name or string.format("phase_trigger_%s_%d", rid, obj.id)
                            local boss_type = OP.get_via(get_prop_value, obj, "boss_preset", "")
                            if boss_type == nil or tostring(boss_type) == "" or tostring(boss_type) == "none" then
                                boss_type = OP.get_via(get_prop_value, obj, "boss_type", "")
                            end
                            add_prefab_instance(rows, obj_id, proto, px, py, nil, nil, "script", {
                                { id = "trigger_id", value = trigger_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "boss_id", value = get_prop_value(obj, "boss_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "boss_type", value = boss_type, type = "PROPERTY_TYPE_TEXT" },
                                { id = "arena_id", value = get_prop_value(obj, "arena_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "phase", value = number_to_proto(get_prop_value(obj, "phase"), 2), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "transition_time", value = number_to_proto(get_prop_value(obj, "transition_time"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "trigger_once", value = bool_to_proto(get_prop_value(obj, "trigger_once"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "requires_flag", value = get_prop_value(obj, "requires_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "set_flag", value = get_prop_value(obj, "set_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "delay", value = number_to_proto(get_prop_value(obj, "delay"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "boss_weak_point" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 32, 32, 64, 64)
                            local go_name = string.format("%s_boss_weak_point_%d.go", rid, obj.id)
                            local go_path = join(PATH.generated_go, go_name)
                            local proto = string.format("/developer/rooms/generated/%s", go_name)
                            local ok_sized, sized_err = write_sized_rect_generated_go(
                                go_path, "/developer/game/prefabs/boss_weak_point.go",
                                w, h, 32, 32, 64, 64,
                                { use_defold_sprite = _visual.uses_defold_sprite(obj, obj_type) }
                            )
                            if not ok_sized then
                                info(string.format("boss_weak_point: failed to generate sized prefab for %s: %s", obj_id, tostring(sized_err)))
                            else
                                info("Created " .. go_path)
                            end
                            local point_id = get_prop_value(obj, "point_id") or obj.name or string.format("weak_point_%s_%d", rid, obj.id)
                            local boss_type = OP.get_via(get_prop_value, obj, "boss_preset", "")
                            if boss_type == nil or tostring(boss_type) == "" or tostring(boss_type) == "none" then
                                boss_type = OP.get_via(get_prop_value, obj, "boss_type", "")
                            end
                            add_prefab_instance(rows, obj_id, proto, px, py, nil, nil, "script", {
                                { id = "point_id", value = point_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "boss_id", value = get_prop_value(obj, "boss_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "boss_type", value = boss_type, type = "PROPERTY_TYPE_TEXT" },
                                { id = "damage_mult", value = number_to_proto(get_prop_value(obj, "damage_mult"), 2.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "health", value = number_to_proto(get_prop_value(obj, "health"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "active_phases", value = get_prop_value(obj, "active_phases") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "vulnerable", value = bool_to_proto(get_prop_value(obj, "vulnerable"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "destroy_flag", value = get_prop_value(obj, "destroy_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "requires_flag", value = get_prop_value(obj, "requires_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "poll_interval", value = number_to_proto(get_prop_value(obj, "poll_interval"), 0.2), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "attach_to_boss", value = bool_to_proto(get_prop_value(obj, "attach_to_boss"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "show_sprite", value = bool_to_proto(_visual.uses_defold_sprite(obj, obj_type), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "wall_jump_surface" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 16, 64, 32, 128)
                            local go_name = string.format("%s_wall_jump_surface_%d.go", rid, obj.id)
                            local go_path = join(PATH.generated_go, go_name)
                            local proto = string.format("/developer/rooms/generated/%s", go_name)
                            local ok_sized, sized_err = write_sized_rect_generated_go(
                                go_path, "/developer/game/prefabs/wall_jump_surface.go",
                                w, h, 64, 64, 128, 128,
                                { use_defold_sprite = _visual.uses_defold_sprite(obj, obj_type) }
                            )
                            if not ok_sized then
                                info(string.format("wall_jump_surface: failed to generate sized prefab for %s: %s", obj_id, tostring(sized_err)))
                            else
                                info("Created " .. go_path)
                            end
                            local surface_id = get_prop_value(obj, "surface_id") or obj.name or string.format("wall_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, proto, px, py, nil, nil, "script", {
                                { id = "surface_id", value = surface_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "allow_slide", value = bool_to_proto(get_prop_value(obj, "allow_slide"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "allow_jump", value = bool_to_proto(get_prop_value(obj, "allow_jump"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "allow_climb", value = bool_to_proto(get_prop_value(obj, "allow_climb"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "slide_speed", value = number_to_proto(get_prop_value(obj, "slide_speed"), 0.3), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "jump_force_x", value = number_to_proto(get_prop_value(obj, "jump_force_x"), 400), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "jump_force_y", value = number_to_proto(get_prop_value(obj, "jump_force_y"), 500), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "facing", value = number_to_proto(get_prop_value(obj, "facing"), 1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "require_ability", value = opt(get_prop_value(obj, "require_ability")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "surface_type", value = get_prop_value(obj, "surface_type") or "stone", type = "PROPERTY_TYPE_TEXT" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "sign" then
                            local px = (tonumber(obj.x) or 0) + ((tonumber(obj.width) or 0) * 0.5)
                            local py = (tonumber(defold_y) or 0) - ((tonumber(obj.height) or 0) * 0.5)
                            local sign_id = get_prop_value(obj, "sign_id") or obj.name or string.format("sign_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/sign.go"), px, py, nil, nil, "script", {
                                { id = "object_id", value = number_to_proto(obj.id, 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "sign_id", value = sign_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "label", value = get_prop_value(obj, "label") or "Read", type = "PROPERTY_TYPE_TEXT" },
                                { id = "range", value = number_to_proto(get_prop_value(obj, "range"), 96), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "text", value = get_prop_value(obj, "text") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "title", value = get_prop_value(obj, "title") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "display_mode", value = get_prop_value(obj, "display_mode") or "toast", type = "PROPERTY_TYPE_TEXT" },
                                { id = "dialogue_id", value = get_prop_value(obj, "dialogue_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "duration", value = number_to_proto(get_prop_value(obj, "duration"), 2.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "trigger_once", value = bool_to_proto(get_prop_value(obj, "trigger_once"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "set_flag", value = get_prop_value(obj, "set_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "requires_flag", value = get_prop_value(obj, "requires_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_id", value = opt(get_prop_value(obj, "sound_id")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "lever" then
                            local px = (tonumber(obj.x) or 0) + ((tonumber(obj.width) or 0) * 0.5)
                            local py = (tonumber(defold_y) or 0) - ((tonumber(obj.height) or 0) * 0.5)
                            local lever_id = get_prop_value(obj, "lever_id") or obj.name or string.format("lever_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/lever.go"), px, py, nil, nil, "script", {
                                { id = "lever_id", value = lever_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "target_id", value = get_prop_value(obj, "target_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "starts_on", value = bool_to_proto(get_prop_value(obj, "starts_on"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "toggle", value = bool_to_proto(get_prop_value(obj, "toggle"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "message_on", value = get_prop_value(obj, "message_on") or "activate", type = "PROPERTY_TYPE_TEXT" },
                                { id = "message_off", value = get_prop_value(obj, "message_off") or "deactivate", type = "PROPERTY_TYPE_TEXT" },
                                { id = "label_on", value = get_prop_value(obj, "label_on") or "Switch On", type = "PROPERTY_TYPE_TEXT" },
                                { id = "label_off", value = get_prop_value(obj, "label_off") or "Switch Off", type = "PROPERTY_TYPE_TEXT" },
                                { id = "range", value = number_to_proto(get_prop_value(obj, "range"), 96), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "cooldown", value = number_to_proto(get_prop_value(obj, "cooldown"), 0.2), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "set_flag_on", value = get_prop_value(obj, "set_flag_on") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "set_flag_off", value = get_prop_value(obj, "set_flag_off") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "requires_flag", value = get_prop_value(obj, "requires_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_on", value = get_prop_value(obj, "sound_on") or "lever_on", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_off", value = get_prop_value(obj, "sound_off") or "lever_off", type = "PROPERTY_TYPE_TEXT" },
                                { id = "on_animation", value = get_prop_value(obj, "on_animation") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "off_animation", value = get_prop_value(obj, "off_animation") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "reset_delay", value = number_to_proto(get_prop_value(obj, "reset_delay"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "hint_stone" then
                            local px = (tonumber(obj.x) or 0) + ((tonumber(obj.width) or 0) * 0.5)
                            local py = (tonumber(defold_y) or 0) - ((tonumber(obj.height) or 0) * 0.5)
                            local hint_id = get_prop_value(obj, "hint_id") or obj.name or string.format("hint_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/hint_stone.go"), px, py, nil, nil, "script", {
                                { id = "hint_id", value = hint_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "label", value = get_prop_value(obj, "label") or "Inspect", type = "PROPERTY_TYPE_TEXT" },
                                { id = "range", value = number_to_proto(get_prop_value(obj, "range"), 96), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "title", value = get_prop_value(obj, "title") or "Hint", type = "PROPERTY_TYPE_TEXT" },
                                { id = "body", value = get_prop_value(obj, "body") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "position", value = get_prop_value(obj, "position") or "top", type = "PROPERTY_TYPE_TEXT" },
                                { id = "duration", value = number_to_proto(get_prop_value(obj, "duration"), 4.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "trigger_once", value = bool_to_proto(get_prop_value(obj, "trigger_once"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "set_flag", value = get_prop_value(obj, "set_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "requires_flag", value = get_prop_value(obj, "requires_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_id", value = opt(get_prop_value(obj, "sound_id")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "lore_item" then
                            local px = (tonumber(obj.x) or 0) + ((tonumber(obj.width) or 0) * 0.5)
                            local py = (tonumber(defold_y) or 0) - ((tonumber(obj.height) or 0) * 0.5)
                            local lore_id = get_prop_value(obj, "lore_id") or obj.name or string.format("lore_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/lore_item.go"), px, py, nil, nil, "script", {
                                { id = "lore_id", value = lore_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "prompt_text", value = get_prop_value(obj, "prompt_text") or "Read", type = "PROPERTY_TYPE_TEXT" },
                                { id = "range", value = number_to_proto(get_prop_value(obj, "range"), 96), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "title", value = get_prop_value(obj, "title") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "text", value = get_prop_value(obj, "text") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "category", value = get_prop_value(obj, "category") or "notes", type = "PROPERTY_TYPE_TEXT" },
                                { id = "auto_pickup", value = bool_to_proto(get_prop_value(obj, "auto_pickup"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "destroyable", value = bool_to_proto(get_prop_value(obj, "destroyable"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "trigger_once", value = bool_to_proto(get_prop_value(obj, "trigger_once"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "requires_flag", value = get_prop_value(obj, "requires_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "unlock_flag", value = get_prop_value(obj, "unlock_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_id", value = opt(get_prop_value(obj, "sound_id")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "particle_id", value = opt(get_prop_value(obj, "particle_id")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "grapple_surface" then
                            -- A raycast-only static rectangle tags a whole
                            -- authored surface. Its self-mask keeps it visible
                            -- to raycasts; an empty mask is ignored by Defold.
                            -- Excluding player avoids duplicate terrain contacts.
                            local px, py, _, _, w, h = rect_center_and_scale(
                                obj, defold_y, map_tile_w, map_tile_h, 128, 8, 256, 16)
                            local go_name = string.format("%s_grapple_surface_%d.go", rid, obj.id)
                            assert(write_sized_rect_generated_go(join(PATH.generated_go, go_name),
                                "/developer/game/prefabs/grapple_surface.go", w, h, 128, 8, 256, 16))
                            add_prefab_instance(rows, obj_id, "/developer/rooms/generated/" .. go_name,
                                px, py, nil, nil, nil, nil)
                            object_count = object_count + 1

                        elseif obj_type == "grapple_box" or obj_type == "grapple_slope" then
                            -- Exact authored grapple shapes: one editable static
                            -- gameobject per object, hull-baked like Solid Box/Slope.
                            if _C.GrappleObjectBake.append(_C, rows, rid, obj, obj_type, obj_id, map_height) then
                                object_count = object_count + 1
                            end

                        elseif obj_type == "grapple_point" then
                            local px = (tonumber(obj.x) or 0) + ((tonumber(obj.width) or 0) * 0.5)
                            local py = map_height - (tonumber(obj.y) or 0) - ((tonumber(obj.height) or 0) * 0.5)
                            -- Fixed anchors expose a sprite and a grapple collider only.
                            add_prefab_instance(rows, obj_id, "/developer/game/prefabs/grapple_point.go",
                                px, py, nil, nil, nil, nil)
                            object_count = object_count + 1

                        elseif obj_type == "pushable_block" then
                            local raw_x = tonumber(obj and obj.x) or 0
                            local raw_y = tonumber(defold_y) or 0
                            local raw_w = tonumber(obj and obj.width) or 0
                            local raw_h = tonumber(obj and obj.height) or 0
                            local resolved_w, resolved_h = resolve_rect_size_pixels(raw_w, raw_h, map_tile_w, map_tile_h, map_tile_w, map_tile_h)
                            local px = raw_x + (resolved_w * 0.5)
                            local py = raw_y - (resolved_h * 0.5)
                            local block_id = get_prop_value(obj, "block_id") or obj.name or string.format("block_%s_%d", rid, obj.id)
                            local pushable_go_name = string.format("%s_pushable_block_%d.go", rid, obj.id)
                            local pushable_go_path = join(PATH.generated_go, pushable_go_name)
                            local pushable_proto = string.format("/developer/rooms/generated/%s", pushable_go_name)
                            local baked_chunk_proto = nil
                            local chunk_baked = false
                            local chunk_offset_x = 0
                            local chunk_offset_y = 0
                            if not pushable_bake_failed then
                                if not pushable_bake_ctx then
                                    pushable_bake_ctx = ensure_pushable_bake_context(rid, map_tile_w, map_tile_h)
                                    if not pushable_bake_ctx then
                                        pushable_bake_failed = true
                                    end
                                end
                                if pushable_bake_ctx then
                                    baked_chunk_proto, chunk_baked, chunk_offset_x, chunk_offset_y = bake_pushable_chunk_tilemap(pushable_bake_ctx, rid, obj, defold_y, resolved_w, resolved_h)
                                end
                            end
                            local mass_prop = get_prop_value(obj, "mass")
                            if write_if_changed(pushable_go_path, gen_pushable_block_go(resolved_w, resolved_h, baked_chunk_proto, chunk_baked, chunk_offset_x, chunk_offset_y, mass_prop)) then
                                info("Created " .. pushable_go_path)
                            end
                            local move_embedded_tiles_prop = get_prop_value(obj, "move_embedded_tiles")
                            local gravity_scale_prop = get_prop_value(obj, "gravity_scale")
                            if chunk_baked == true then
                                -- Import-time baked chunks already own the visual; runtime tile capture/move must stay off.
                                move_embedded_tiles_prop = false
                            end
                            add_prefab_instance(rows, obj_id, pushable_proto, px, py, nil, nil, "script", {
                                { id = "block_id", value = block_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                                { id = "reset_on_room_load", value = bool_to_proto(get_prop_value(obj, "reset_on_room_load"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "gravity_scale", value = number_to_proto(gravity_scale_prop, 1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "mass", value = number_to_proto(mass_prop, 1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "move_embedded_tiles", value = bool_to_proto(move_embedded_tiles_prop, not chunk_baked), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "chunk_baked", value = bool_to_proto(chunk_baked, false), type = "PROPERTY_TYPE_BOOLEAN" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "secret" then
                            local secret_id = get_prop_value(obj, "secret_id")
                            if secret_id == nil or tostring(secret_id) == "" then
                                secret_id = string.format("secret_%s_%d", rid, obj.id)
                            end
                            local secret_w, secret_h = resolve_rect_size_pixels(
                                tonumber(obj and obj.width) or 0,
                                tonumber(obj and obj.height) or 0,
                                map_tile_w,
                                map_tile_h,
                                64,
                                64
                            )
                            local reveals_on = normalize_string_enum(get_prop_value(obj, "reveals_on"), "touch", {
                                touch = true,
                                attack = true,
                                ability = true,
                                interact = true,
                            })
                            local _, _, _, _, w, h = add_rect_prefab_instance(
                                rows,
                                obj_id,
                                _visual.resolve_visual_proto(rid, obj, obj_type, "/developer/game/prefabs/secret.go"),
                                obj,
                                defold_y,
                                map_tile_w,
                                map_tile_h,
                                32,
                                32,
                                64,
                                64,
                                "script",
                                {
                                    Prop.text("secret_id", secret_id),
                                    Prop.text("secret_type", get_prop_value(obj, "secret_type") or "illusory_wall"),
                                    Prop.text("reveals_on", reveals_on),
                                    Prop.text("required_ability", opt(get_prop_value(obj, "required_ability"))),
                                    Prop.number("width", secret_w, 64),
                                    Prop.number("height", secret_h, 64),
                                    Prop.bool("hide_tiles", get_prop_value(obj, "hide_tiles"), true),
                                    Prop.bool("notification", get_prop_value(obj, "notification"), true),
                                    Prop.text("notification_text", get_prop_value(obj, "notification_text") or "Secret Found!"),
                                    Prop.text("reward_type", opt(get_prop_value(obj, "reward_type"))),
                                    Prop.number("reward_amount", get_prop_value(obj, "reward_amount"), 0),
                                    Prop.bool("map_reveal", get_prop_value(obj, "map_reveal"), true),
                                    Prop.text("room_id", rid),
                                }
                            )
                            object_count = object_count + 1
                            info(string.format("gen_collection: Baked secret prefab (%s)", obj_id))

                        elseif obj_type == "torch_holder" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 32, 64, 64, 128)
                            local torch_go_name = string.format("%s_torch_holder_%d.go", rid, obj.id)
                            local torch_go_path = join(PATH.generated_go, torch_go_name)
                            local torch_proto = string.format("/developer/rooms/generated/%s", torch_go_name)
                            if write_if_changed(torch_go_path, gen_torch_holder_go(w, h)) then
                                info("Created " .. torch_go_path)
                            end
                            local torch_id = get_prop_value(obj, "torch_id") or obj.name or string.format("torch_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, torch_proto, px, py, nil, nil, "script", {
                                { id = "torch_id", value = torch_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                                { id = "starts_lit", value = bool_to_proto(get_prop_value(obj, "starts_lit"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "require_interact", value = bool_to_proto(get_prop_value(obj, "require_interact"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "allow_extinguish", value = bool_to_proto(get_prop_value(obj, "allow_extinguish"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "light_radius", value = number_to_proto(OP.get_via(get_prop_value, obj, "light_radius"), 220), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "light_intensity", value = number_to_proto(OP.get_via(get_prop_value, obj, "light_intensity"), 1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "label", value = get_prop_value(obj, "label") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "label_lit", value = get_prop_value(obj, "label_lit") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "set_flag", value = get_prop_value(obj, "set_flag") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "lit_animation", value = get_prop_value(obj, "lit_animation") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "unlit_animation", value = get_prop_value(obj, "unlit_animation") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_on", value = get_prop_value(obj, "sound_on") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "sound_off", value = get_prop_value(obj, "sound_off") or "", type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "water_volume" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            local water_go_name = string.format("%s_water_volume_%d.go", rid, obj.id)
                            local water_go_path = join(PATH.generated_go, water_go_name)
                            local water_proto = string.format("/developer/rooms/generated/%s", water_go_name)
                            if write_if_changed(water_go_path, gen_water_volume_go(w, h, _visual.uses_defold_sprite(obj, obj_type))) then
                                info("Created " .. water_go_path)
                            end
                            local water_id = get_prop_value(obj, "water_id") or obj.name or string.format("water_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, water_proto, px, py, nil, nil, "script", {
                                { id = "water_id", value = water_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "water_type", value = get_prop_value(obj, "water_type") or "water", type = "PROPERTY_TYPE_TEXT" },
                                { id = "width", value = number_to_proto(w, 128), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "height", value = number_to_proto(h, 128), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "swim_enabled", value = bool_to_proto(get_prop_value(obj, "swim_enabled"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "swim_speed_mult", value = number_to_proto(get_prop_value(obj, "swim_speed_mult"), 0.7), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "damage", value = number_to_proto(get_prop_value(obj, "damage"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "damage_interval", value = number_to_proto(get_prop_value(obj, "damage_interval"), 1.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "current_direction", value = get_prop_value(obj, "current_direction") or "none", type = "PROPERTY_TYPE_TEXT" },
                                { id = "current_strength", value = number_to_proto(get_prop_value(obj, "current_strength"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                                { id = "buoyancy", value = number_to_proto(get_prop_value(obj, "buoyancy"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "water_drag", value = number_to_proto(get_prop_value(obj, "water_drag"), 0.85), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "oxygen_drain", value = bool_to_proto(get_prop_value(obj, "oxygen_drain"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "oxygen_drain_rate", value = number_to_proto(get_prop_value(obj, "oxygen_drain_rate"), 1.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "surface_y_offset", value = number_to_proto(get_prop_value(obj, "surface_y_offset"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "splash_effect", value = bool_to_proto(get_prop_value(obj, "splash_effect"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "tint_color", value = get_prop_value(obj, "tint_color") or "", type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "particle_emitter" then
                            local px, py = object_rect_center(obj, defold_y)
                            local emitter_id = get_prop_value(obj, "emitter_id")
                            if emitter_id == nil or tostring(emitter_id) == "" then
                                emitter_id = obj.name or string.format("emitter_%s_%d", rid, obj.id)
                            end
                            add_prefab_instance(rows, obj_id, "/developer/game/prefabs/particle_emitter.go", px, py, nil, nil, "script", {
                                { id = "emitter_id", value = emitter_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "effect_id", value = get_prop_value(obj, "effect_id") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "auto_play", value = bool_to_proto(get_prop_value(obj, "auto_play"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "loop", value = bool_to_proto(get_prop_value(obj, "loop"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "start_delay", value = number_to_proto(get_prop_value(obj, "start_delay"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "loop_interval", value = number_to_proto(get_prop_value(obj, "loop_interval"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "run_duration", value = number_to_proto(get_prop_value(obj, "run_duration"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "debug_marker", value = bool_to_proto(get_prop_value(obj, "debug_marker"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "debug_follow_player", value = bool_to_proto(get_prop_value(obj, "debug_follow_player"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "ambience_zone" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            local zone_go_name = string.format("%s_ambience_zone_%d.go", rid, obj.id)
                            local zone_go_path = join(PATH.generated_go, zone_go_name)
                            local zone_proto = string.format("/developer/rooms/generated/%s", zone_go_name)
                            if write_if_changed(zone_go_path, gen_collision_zone_go("/mvtk/prefabs/ambience_zone.script", w, h, 128, 128, nil, nil, nil, {
                                { id = "zone_id", value = "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "ambience_id", value = "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "ambience_component", value = "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "gain", value = "1.0", type = "PROPERTY_TYPE_NUMBER" },
                                { id = "music_volume_percent", value = "100.0", type = "PROPERTY_TYPE_NUMBER" },
                                { id = "stop_on_exit", value = "true", type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "trigger_once", value = "false", type = "PROPERTY_TYPE_BOOLEAN" },
                            })) then
                                info("Created " .. zone_go_path)
                            end
                            local zone_id = get_prop_value(obj, "zone_id")
                            if zone_id == nil or tostring(zone_id) == "" then
                                zone_id = obj.name or string.format("ambience_%s_%d", rid, obj.id)
                            end
                            local ambience_id = opt(OP.get_via(get_prop_value, obj, "ambience_id", ""))
                            local ambience_component = ""
                            if ambience_id ~= nil and tostring(ambience_id) ~= "" then
                                ambience_component = "ambient_" .. sanitize_asset_name(tostring(ambience_id))
                            end
                            add_prefab_instance(rows, obj_id, zone_proto, px, py, nil, nil, "script", {
                                { id = "zone_id", value = zone_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "ambience_id", value = ambience_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "ambience_component", value = ambience_component, type = "PROPERTY_TYPE_TEXT" },
                                { id = "gain", value = number_to_proto(OP.get_via(get_prop_value, obj, "gain"), 1.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "music_volume_percent", value = number_to_proto(get_prop_value(obj, "music_volume_percent"), 100.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "stop_on_exit", value = bool_to_proto(get_prop_value(obj, "stop_on_exit"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "trigger_once", value = bool_to_proto(get_prop_value(obj, "trigger_once"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "music_trigger" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            local zone_go_name = string.format("%s_music_trigger_%d.go", rid, obj.id)
                            local zone_go_path = join(PATH.generated_go, zone_go_name)
                            local zone_proto = string.format("/developer/rooms/generated/%s", zone_go_name)
                            if write_if_changed(zone_go_path, gen_collision_zone_go("/mvtk/prefabs/music_trigger.script", w, h, 128, 128, nil, nil, nil, {
                                { id = "trigger_id", value = "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "music_id", value = "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "area_theme", value = "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "fade_time", value = "0.5", type = "PROPERTY_TYPE_NUMBER" },
                                { id = "stop_on_exit", value = "true", type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "exit_music", value = "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "exit_area", value = "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "trigger_once", value = "false", type = "PROPERTY_TYPE_BOOLEAN" },
                            })) then
                                info("Created " .. zone_go_path)
                            end
                            local trigger_id = get_prop_value(obj, "trigger_id")
                            if trigger_id == nil or tostring(trigger_id) == "" then
                                trigger_id = obj.name or string.format("music_%s_%d", rid, obj.id)
                            end
                            add_prefab_instance(rows, obj_id, zone_proto, px, py, nil, nil, "script", {
                                { id = "trigger_id", value = trigger_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "music_id", value = opt(get_prop_value(obj, "music_id")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "area_theme", value = opt(get_prop_value(obj, "area_theme")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "fade_time", value = number_to_proto(get_prop_value(obj, "fade_time"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "stop_on_exit", value = bool_to_proto(get_prop_value(obj, "stop_on_exit"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "exit_music", value = opt(get_prop_value(obj, "exit_music")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "exit_area", value = opt(get_prop_value(obj, "exit_area")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "trigger_once", value = bool_to_proto(get_prop_value(obj, "trigger_once"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "screen_effect_zone" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            local zone_go_name = string.format("%s_screen_effect_zone_%d.go", rid, obj.id)
                            local zone_go_path = join(PATH.generated_go, zone_go_name)
                            local zone_proto = string.format("/developer/rooms/generated/%s", zone_go_name)
                            if write_if_changed(zone_go_path, gen_screen_effect_zone_go(w, h)) then
                                info("Created " .. zone_go_path)
                            end
                            local zone_id = get_prop_value(obj, "zone_id")
                            if zone_id == nil or tostring(zone_id) == "" then
                                zone_id = obj.name or string.format("screenfx_%s_%d", rid, obj.id)
                            end
                            add_prefab_instance(rows, obj_id, zone_proto, px, py, nil, nil, "script", {
                                { id = "zone_id", value = zone_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "effect_type", value = get_prop_value(obj, "effect_type") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "intensity", value = number_to_proto(OP.get_via(get_prop_value, obj, "intensity"), 0.5), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "tint_color", value = get_prop_value(obj, "tint_color") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "duration", value = number_to_proto(get_prop_value(obj, "duration"), 0.3), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "trigger_once", value = bool_to_proto(get_prop_value(obj, "trigger_once"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "exit_darkness", value = number_to_proto(get_prop_value(obj, "exit_darkness"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "exit_tint", value = get_prop_value(obj, "exit_tint") or "", type = "PROPERTY_TYPE_TEXT" },
                                { id = "underwater_overlay", value = bool_to_proto(get_prop_value(obj, "underwater_overlay"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "map_marker" then
                            local px = tonumber(obj and obj.x) or 0
                            local py = tonumber(defold_y) or 0
                            local marker_id = get_prop_value(obj, "marker_id")
                            if marker_id == nil or tostring(marker_id) == "" then
                                marker_id = string.format("map_marker_%s_%d", rid, obj.id)
                            end
                            local marker_label = get_prop_value(obj, "marker_label")
                            if marker_label == nil or tostring(marker_label) == "" then
                                marker_label = obj.name or ""
                            end

                            add_prefab_instance(rows, obj_id, "/developer/game/prefabs/map_marker.go", px, py, nil, nil, "script", {
                                { id = "marker_id", value = marker_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "marker_type", value = get_prop_value(obj, "marker_type") or "poi", type = "PROPERTY_TYPE_TEXT" },
                                { id = "marker_icon", value = get_prop_value(obj, "marker_icon") or "marker_default", type = "PROPERTY_TYPE_TEXT" },
                                { id = "marker_label", value = marker_label, type = "PROPERTY_TYPE_TEXT" },
                                { id = "facing", value = number_to_proto(get_prop_value(obj, "facing"), 1), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "show_on_minimap", value = bool_to_proto(get_prop_value(obj, "show_on_minimap"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "show_on_world_map", value = bool_to_proto(get_prop_value(obj, "show_on_world_map"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "visible_from_start", value = bool_to_proto(get_prop_value(obj, "visible_from_start"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "discovery_radius", value = number_to_proto(get_prop_value(obj, "discovery_radius"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "camera_zone" then
                            -- Marker sprite uses props_base.png (128x128), so scale against that
                            -- base size to keep IDE coverage aligned with the authored Tiled rect.
                            local px, py, sx, sy, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 64, 64, 128, 128)
                            local zone_id = get_prop_value(obj, "zone_id")
                            if zone_id == nil or tostring(zone_id) == "" then
                                zone_id = string.format("camera_%s_%d", tostring(rid), tonumber(obj.id) or 0)
                            end
                            local camera_mode = get_prop_value(obj, "camera_mode") or "follow"

                            add_prefab_instance(rows, obj_id, "/developer/rooms/prefabs/camera_zone_marker.go", px, py, sx, sy, "script", {
                                { id = "zone_id", value = zone_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                                { id = "camera_mode", value = camera_mode, type = "PROPERTY_TYPE_TEXT" },
                                { id = "zoom_level", value = number_to_proto(get_prop_value(obj, "zoom_level"), 1.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "transition_speed", value = number_to_proto(get_prop_value(obj, "transition_speed"), 1.0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "bounds_padding", value = number_to_proto(get_prop_value(obj, "bounds_padding"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "lock_x", value = bool_to_proto(get_prop_value(obj, "lock_x"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "lock_y", value = bool_to_proto(get_prop_value(obj, "lock_y"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "focus_x", value = number_to_proto(get_prop_value(obj, "focus_x"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "focus_y", value = number_to_proto(get_prop_value(obj, "focus_y"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "parallax_override", value = opt(get_prop_value(obj, "parallax_override")), type = "PROPERTY_TYPE_TEXT" },
                                { id = "smooth_follow", value = bool_to_proto(get_prop_value(obj, "smooth_follow"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "deadzone_width", value = number_to_proto(get_prop_value(obj, "deadzone_width"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "deadzone_height", value = number_to_proto(get_prop_value(obj, "deadzone_height"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "auto_fit", value = bool_to_proto(get_prop_value(obj, "auto_fit"), false), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "width", value = number_to_proto(w, 256), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "height", value = number_to_proto(h, 256), type = "PROPERTY_TYPE_NUMBER" },
                            })
                            object_count = object_count + 1

                        elseif obj_type == "ladder" then
                            local px, py, _, _, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, 16, 64, 32, 128)
                            local ladder_go_name = string.format("%s_ladder_%d.go", rid, obj.id)
                            local ladder_go_path = join(PATH.generated_go, ladder_go_name)
                            local ladder_proto = string.format("/developer/rooms/generated/%s", ladder_go_name)
                            if write_if_changed(ladder_go_path, gen_ladder_go(w, h)) then
                                info("Created " .. ladder_go_path)
                            end
                            local ladder_id = get_prop_value(obj, "ladder_id") or string.format("ladder_%s_%d", rid, obj.id)
                            add_prefab_instance(rows, obj_id, ladder_proto, px, py, nil, nil, "script", {
                                { id = "ladder_id", value = ladder_id, type = "PROPERTY_TYPE_TEXT" },
                                { id = "ladder_type", value = get_prop_value(obj, "ladder_type") or "ladder", type = "PROPERTY_TYPE_TEXT" },
                                { id = "climb_speed", value = number_to_proto(get_prop_value(obj, "climb_speed"), 400), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "can_jump_off", value = bool_to_proto(get_prop_value(obj, "can_jump_off"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "snap_to_center", value = bool_to_proto(get_prop_value(obj, "snap_to_center"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "climb_offset_x", value = number_to_proto(get_prop_value(obj, "climb_offset_x"), 0), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "pass_through_top", value = bool_to_proto(get_prop_value(obj, "pass_through_top"), true), type = "PROPERTY_TYPE_BOOLEAN" },
                                { id = "grab_extend_down", value = number_to_proto(get_prop_value(obj, "grab_extend_down"), 128), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "grab_extend_up", value = number_to_proto(get_prop_value(obj, "grab_extend_up"), 128), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "width", value = number_to_proto(w, 32), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "height", value = number_to_proto(h, 128), type = "PROPERTY_TYPE_NUMBER" },
                                { id = "room_id", value = rid, type = "PROPERTY_TYPE_TEXT" },
                            })
                            object_count = object_count + 1

                        elseif _C.RetiredTypes.is_object_type(obj_type) then
                            -- Preflight reports the retirement warning. Do not bake a
                            -- marker that implies this object is still supported.
                        else
                            -- Fallback for new/unknown Tiled template object types.
                            -- Keep them visible in the collection as marker game objects
                            -- so template updates never silently disappear from room assets.
                            if obj_type and obj_type ~= "" then
                                local marker_x = tonumber(obj.x) or 0
                                local marker_y = tonumber(defold_y) or 0
                                local w = tonumber(obj.width) or 0
                                local h = tonumber(obj.height) or 0
                                if w > 0 then
                                    marker_x = marker_x + (w * 0.5)
                                end
                                if h > 0 then
                                    marker_y = marker_y - (h * 0.5)
                                end

                                rows[#rows + 1] = 'instances {'
                                rows[#rows + 1] = string.format('  id: "%s"', obj_id)
                                rows[#rows + 1] = '  prototype: "/developer/rooms/prefabs/empty.go"'
                                rows[#rows + 1] = '  position {'
                                rows[#rows + 1] = '    x: ' .. fmt_num(marker_x)
                                rows[#rows + 1] = '    y: ' .. fmt_num(marker_y)
                                rows[#rows + 1] = '    z: 0.0'
                                rows[#rows + 1] = '  }'
                                rows[#rows + 1] = '}'
                                object_count = object_count + 1
                                info(string.format("gen_collection: Added fallback marker for type '%s' (%s)", obj_type, obj_id))
                            end
                        end
                        end
                    end
                end
            end

            profiler.stop("    object_iteration [" .. rid .. "]")

            profiler.start("    flush_bake_contexts [" .. rid .. "]")
            flush_pushable_bake_context(pushable_bake_ctx)
            profiler.stop("    flush_bake_contexts [" .. rid .. "]")

            info(string.format("gen_collection: Added %d Tiled object instances for room %s", object_count, rid))

            -- â”€â”€ Boss validation pass â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            -- Cross-reference boss-related objects and warn about misconfigurations.
            do
                local bv_arenas = {}      -- arena_id -> true
                local bv_bosses = {}      -- boss_id -> { arena_id=, boss_preset= }
                local bv_phases = {}      -- arena_id -> count
                local bv_entry_locks = {} -- arena_id -> true

                for _, entry2 in ipairs(flattened_layers) do
                    local layer2 = entry2.layer
                    if layer2 and layer2.type == "objectgroup" and type(layer2.objects) == "table" then
                        for _, o in ipairs(layer2.objects) do
                            if o and o.visible ~= false then
                                local ot = resolve_object_type(o, known_types)
                                if ot == "boss" then
                                    local bid = get_prop_value(o, "boss_id") or o.name or ""
                                    local aid = get_prop_value(o, "arena_id") or ""
                                    local bt = get_prop_value(o, "boss_preset") or get_prop_value(o, "boss_type") or ""
                                    if bid ~= "" then
                                        bv_bosses[tostring(bid)] = { arena_id = tostring(aid), boss_preset = tostring(bt) }
                                    end
                                elseif ot == "boss_arena" then
                                    local aid = get_prop_value(o, "arena_id") or ""
                                    if tostring(aid) ~= "" then
                                        bv_arenas[tostring(aid)] = true
                                        bv_entry_locks[tostring(aid)] = true
                                    end
                                elseif ot == "arena_lock" then
                                    local aid = get_prop_value(o, "arena_id") or ""
                                    if tostring(aid) ~= "" then
                                        bv_arenas[tostring(aid)] = true
                                        bv_entry_locks[tostring(aid)] = true
                                    end
                                elseif ot == "boss_phase_trigger" or ot == "boss_phase" then
                                    local aid = get_prop_value(o, "arena_id") or ""
                                    if tostring(aid) ~= "" then
                                        bv_phases[tostring(aid)] = (bv_phases[tostring(aid)] or 0) + 1
                                    end
                                end
                            end
                        end
                    end
                end

                -- Warn: boss with arena_id that has no matching arena/trigger
                for bid, binfo in pairs(bv_bosses) do
                    if binfo.arena_id ~= "" and not bv_arenas[binfo.arena_id] and not bv_entry_locks[binfo.arena_id] then
                        info(string.format("[BOSS_VALIDATION] WARNING: Boss '%s' references arena_id '%s' but no boss_arena / arena_lock with that ID was found in room %s",
                            bid, binfo.arena_id, rid))
                    end
                end

                -- Warn: boss with no authored entry-lock object to start the encounter.
                for bid, binfo in pairs(bv_bosses) do
                    if binfo.arena_id ~= "" and not bv_entry_locks[binfo.arena_id] then
                        info(string.format("[BOSS_VALIDATION] WARNING: Boss '%s' has arena_id '%s' but no boss_arena / arena_lock was found. The boss fight won't auto-start on player entry in room %s",
                            bid, binfo.arena_id, rid))
                    end
                end
            end
        end
    elseif tiled_source_or_err then
        info(string.format("gen_collection: No Tiled export for room %s (%s)", rid, tostring(tiled_source_or_err)))
    end

    rows[#rows + 1] = ''
    local result = table.concat(rows, '\n')
    if tiled_data then
        result = require("mvtk.editor.object_art").finish(_C, rid, tiled_data, tiled_source_or_err, result)
    end
    return result
end



-- â”€â”€ Share gen_collection with subsequent hook files â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Context.require_context("hooks/editor_generators.lua exports").gen_collection = gen_collection

return true

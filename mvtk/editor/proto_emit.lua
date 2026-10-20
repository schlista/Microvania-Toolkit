-- mvtk/editor/proto_emit.lua
-- Leaf proto emitters used by generated room collection assembly.

local proto_utils = require("mvtk.editor.proto_utils")
local TileSnap = require("mvtk.tiled.tile_snap")
local CollisionBox = require("mvtk.tiled.collision_box")

local M = {}

local fmt_num = proto_utils.fmt_num
local proto_escape = proto_utils.proto_escape
local bool_to_proto = proto_utils.bool_to_proto
local number_to_proto

-- proto_escape and bool_to_proto are imported from mvtk.editor.proto_utils
-- at the top of this file.

number_to_proto = function(value, default)
    local n = tonumber(value)
    if n == nil then
        n = tonumber(default) or 0
    end
    return fmt_num(n)
end

local function object_rect_center(obj, defold_y)
    local x = tonumber(obj and obj.x) or 0
    local y = tonumber(defold_y) or 0
    local w = tonumber(obj and obj.width) or 0
    local h = tonumber(obj and obj.height) or 0
    if w > 0 then
        x = x + (w * 0.5)
    end
    if h > 0 then
        y = y - (h * 0.5)
    end
    return x, y, w, h
end

local function resolve_rect_size_pixels(width, height, tile_w, tile_h, default_w, default_h)
    local fallback_w = tonumber(default_w) or 128
    local fallback_h = tonumber(default_h) or fallback_w
    if TileSnap and TileSnap.normalize_tile_size then
        fallback_w, fallback_h = TileSnap.normalize_tile_size(tile_w, tile_h, fallback_w, fallback_h)
    else
        fallback_w = tonumber(tile_w) or fallback_w
        fallback_h = tonumber(tile_h) or fallback_h
        if fallback_w <= 0 then fallback_w = 128 end
        if fallback_h <= 0 then fallback_h = fallback_w end
    end

    local raw_w = tonumber(width) or 0
    local raw_h = tonumber(height) or 0
    if raw_w <= 0 then raw_w = fallback_w end
    if raw_h <= 0 then raw_h = fallback_h end
    return raw_w, raw_h
end

local function scale_from_full_size(full_w, full_h, base_half_w, base_half_h)
    if CollisionBox and CollisionBox.scale_from_full_size then
        local sx, sy = CollisionBox.scale_from_full_size(full_w, full_h, base_half_w, base_half_h, full_w, full_h)
        return sx, sy
    end
    local bw = (tonumber(base_half_w) or 64) * 2
    local bh = (tonumber(base_half_h) or 64) * 2
    if bw <= 0 then bw = 128 end
    if bh <= 0 then bh = 128 end
    return (tonumber(full_w) or bw) / bw, (tonumber(full_h) or bh) / bh
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

local function rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, base_half_w, base_half_h, fallback_w, fallback_h)
    local raw_x = tonumber(obj and obj.x) or 0
    local raw_y = tonumber(defold_y) or 0
    local raw_w = tonumber(obj and obj.width) or 0
    local raw_h = tonumber(obj and obj.height) or 0
    local full_w, full_h = resolve_rect_size_pixels(raw_w, raw_h, map_tile_w, map_tile_h, fallback_w, fallback_h)
    local px = raw_x + (full_w * 0.5)
    local py = raw_y - (full_h * 0.5)
    local sx, sy = scale_from_full_size(full_w, full_h, base_half_w, base_half_h)
    return px, py, sx, sy, full_w, full_h
end

local function snapped_rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, base_half_w, base_half_h, fallback_w, fallback_h)
    local raw_x = tonumber(obj and obj.x) or 0
    local raw_top = tonumber(defold_y) or 0
    local raw_w = tonumber(obj and obj.width) or 0
    local raw_h = tonumber(obj and obj.height) or 0
    local full_w, full_h = resolve_rect_size_pixels(raw_w, raw_h, map_tile_w, map_tile_h, fallback_w, fallback_h)

    local snapped_x = raw_x
    local snapped_bottom = raw_top - full_h
    local snapped_w = full_w
    local snapped_h = full_h

    if TileSnap and TileSnap.snap_rect_bounds_to_tile then
        snapped_x, snapped_bottom, snapped_w, snapped_h = TileSnap.snap_rect_bounds_to_tile(
            raw_x,
            raw_top - full_h,
            full_w,
            full_h,
            map_tile_w,
            map_tile_h,
            fallback_w,
            fallback_h
        )
    end

    local px = snapped_x + (snapped_w * 0.5)
    local py = snapped_bottom + (snapped_h * 0.5)
    local sx, sy = scale_from_full_size(snapped_w, snapped_h, base_half_w, base_half_h)
    return px, py, sx, sy, snapped_w, snapped_h
end

local function append_component_properties(rows, component_id, props)
    if not component_id or not props or #props == 0 then
        return
    end
    rows[#rows + 1] = '  component_properties {'
    rows[#rows + 1] = string.format('    id: "%s"', component_id)
    for _, prop in ipairs(props) do
        rows[#rows + 1] = '    properties {'
        rows[#rows + 1] = string.format('      id: "%s"', prop.id)
        rows[#rows + 1] = string.format('      value: "%s"', proto_escape(prop.value))
        rows[#rows + 1] = string.format('      type: %s', prop.type)
        rows[#rows + 1] = '    }'
    end
    rows[#rows + 1] = '  }'
end

local function add_prefab_instance(rows, obj_id, prototype, pos_x, pos_y, scale_x, scale_y, component_id, props, pos_z, children)
    rows[#rows + 1] = 'instances {'
    rows[#rows + 1] = string.format('  id: "%s"', obj_id)
    rows[#rows + 1] = string.format('  prototype: "%s"', prototype)
    rows[#rows + 1] = '  position {'
    rows[#rows + 1] = '    x: ' .. fmt_num(pos_x)
    rows[#rows + 1] = '    y: ' .. fmt_num(pos_y)
    rows[#rows + 1] = '    z: ' .. fmt_num(pos_z or 0.0)
    rows[#rows + 1] = '  }'
    if scale_x and scale_y and (math.abs(scale_x - 1.0) > 0.001 or math.abs(scale_y - 1.0) > 0.001) then
        rows[#rows + 1] = '  scale3 {'
        rows[#rows + 1] = '    x: ' .. fmt_num(scale_x)
        rows[#rows + 1] = '    y: ' .. fmt_num(scale_y)
        rows[#rows + 1] = '    z: 1.0'
        rows[#rows + 1] = '  }'
    end
    if component_id and props and #props > 0 then
        append_component_properties(rows, component_id, props)
    end
    if type(children) == "string" then
        rows[#rows + 1] = string.format('  children: "%s"', children)
    elseif type(children) == "table" then
        for _, child_id in ipairs(children) do
            if child_id and child_id ~= "" then
                rows[#rows + 1] = string.format('  children: "%s"', child_id)
            end
        end
    end
    rows[#rows + 1] = '}'
end

local function text_prop(id, value, default)
    local resolved = value
    if resolved == nil then
        resolved = default or ""
    end
    return { id = id, value = tostring(resolved), type = "PROPERTY_TYPE_TEXT" }
end

local STATIC_DIALOGUES_CACHE = nil
local COLLECTIBLE_TYPES_CACHE = nil

local function static_dialogue_exists(dialogue_id)
    local key = tostring(dialogue_id or "")
    if key == "" then
        return false
    end
    if STATIC_DIALOGUES_CACHE == nil then
        local ok, cfg = pcall(require, "developer.config.narrative.dialogues")
        STATIC_DIALOGUES_CACHE = (ok and type(cfg) == "table") and cfg or false
    end
    return type(STATIC_DIALOGUES_CACHE) == "table" and STATIC_DIALOGUES_CACHE[key] ~= nil
end

local function collectible_type_exists(type_id)
    local key = tostring(type_id or "")
    if key == "" then
        return false
    end
    if COLLECTIBLE_TYPES_CACHE == nil then
        local ok, cfg = pcall(require, "developer.config.collectible_types")
        COLLECTIBLE_TYPES_CACHE = (ok and type(cfg) == "table") and cfg or false
    end
    return type(COLLECTIBLE_TYPES_CACHE) == "table" and COLLECTIBLE_TYPES_CACHE[key] ~= nil
end

local function bool_prop(id, value, default)
    return { id = id, value = bool_to_proto(value, default), type = "PROPERTY_TYPE_BOOLEAN" }
end

local function number_prop(id, value, default)
    return { id = id, value = number_to_proto(value, default), type = "PROPERTY_TYPE_NUMBER" }
end

local function normalize_string_enum(value, default_value, allowed_values)
    local normalized = tostring(value or ""):lower()
    if allowed_values[normalized] then
        return normalized
    end
    return default_value
end

local BUILD_TIME_SKIP_SPAWN_TYPES = {
    "spawn_point",
    "boss",
    "boss_phase",
    "boss_arena",
    "arena_lock",
    "arena_boundary",
    "boss_phase_trigger",
    "boss_weak_point",
    "enemy",
    "collectible",
    "chest",
    "ability",
    "lore_item",
    "npc",
    "dialogue_trigger",
    "save_point",
    "gate",
    "health_station",
    "energy_station",
    "map_station",
    "breakable_wall",
    "light_source",
    "torch_holder",
    "pushable_block",
    "pressure_plate",
    "sign",
    "lever",
    "hint_stone",
    "one_way_platform",
    "platform",
    "moving_platform",
    "elevator",
    "elevator_node",
    "crumble_platform",
    "bounce_pad",
    "conveyor",
    "ladder",
    "teleporter",
    "timed_door",
    "wall_jump_surface",
    "grapple_point",
    "grapple_surface",
    "grapple_box",
    "grapple_slope",
    "ambience_zone",
    "music_trigger",
    "particle_emitter",
    "screen_effect_zone",
    "hazard",
    "water_volume",
    "secret",
    "map_marker",
    "checkpoint",
    "fast_travel",
    "joint_platform",
    "rail_elevator",
    "collision_box",
    "locked_door",
    "end_game",
    "collision_slope",
}

local function build_tiled_loader_props(room_id)
    local props = {
        text_prop("room_id", room_id),
        text_prop("skip_spawn_types", "object_art,item_art"),
        -- Generated scenery has independent baked parallax controllers. The
        -- legacy room-wide manager must not also try to control their motion.
        bool_prop("auto_setup_parallax", false, true),
    }
    for _, obj_type in ipairs(BUILD_TIME_SKIP_SPAWN_TYPES) do
        props[#props + 1] = bool_prop("skip_spawn_" .. obj_type, true, false)
    end
    return props
end

local function add_rect_prefab_instance(rows, obj_id, prototype, obj, defold_y, map_tile_w, map_tile_h, base_half_w, base_half_h, fallback_w, fallback_h, component_id, props, pos_z)
    local px, py, sx, sy, w, h = rect_center_and_scale(obj, defold_y, map_tile_w, map_tile_h, base_half_w, base_half_h, fallback_w, fallback_h)
    add_prefab_instance(rows, obj_id, prototype, px, py, sx, sy, component_id, props, pos_z)
    return px, py, sx, sy, w, h
end

local function generated_object_id(room_id, obj_type, object_id)
    local resolved_room_id = tostring(room_id or "room")
    local resolved_type = tostring(obj_type or "obj")
    local resolved_object_id = math.floor(tonumber(object_id) or 0)
    return string.format("%s_%s_%d", resolved_room_id, resolved_type, resolved_object_id)
end


M.number_to_proto = number_to_proto
M.object_rect_center = object_rect_center
M.resolve_rect_size_pixels = resolve_rect_size_pixels
M.scale_from_full_size = scale_from_full_size
M.resolve_breakable_swap_extent = resolve_breakable_swap_extent
M.rect_center_and_scale = rect_center_and_scale
M.snapped_rect_center_and_scale = snapped_rect_center_and_scale
M.append_component_properties = append_component_properties
M.add_prefab_instance = add_prefab_instance
M.text_prop = text_prop
M.static_dialogue_exists = static_dialogue_exists
M.collectible_type_exists = collectible_type_exists
M.bool_prop = bool_prop
M.number_prop = number_prop
M.normalize_string_enum = normalize_string_enum
M.BUILD_TIME_SKIP_SPAWN_TYPES = BUILD_TIME_SKIP_SPAWN_TYPES
M.build_tiled_loader_props = build_tiled_loader_props
M.add_rect_prefab_instance = add_rect_prefab_instance
M.generated_object_id = generated_object_id

return M

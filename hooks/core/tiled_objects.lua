-- hooks/core/tiled_objects.lua
--
-- Tiled object property helpers, type inference, and preflight validation for
-- editor-time room generation.

local PropertyFlattener = require "mvtk.tiled.property_flattener"
local RetiredTypes = require "mvtk.tiled.retired_types"

local M = {}

-- Retain the public helper name used by older editor modules/tests while the
-- shared flattener owns the implementation.
local unwrap_tiled_prop_value = PropertyFlattener.unwrap

local config = {
    info = function() end,
    load_tiled_export = nil,
    require_table_module = nil,
}

local function default_require_table_module(module_name)
    local mod = require(module_name)
    assert(type(mod) == "table", module_name .. " must return a table")
    return mod
end

function M.configure(deps)
    deps = deps or {}
    for key, value in pairs(deps) do
        config[key] = value
    end
end

local function info(msg)
    return (config.info or function() end)(msg)
end

local function require_table_module(module_name)
    return (config.require_table_module or default_require_table_module)(module_name)
end

local function load_tiled_export(room_id)
    assert(config.load_tiled_export, "hooks.core.tiled_objects requires load_tiled_export")
    return config.load_tiled_export(room_id)
end

local function load_object_type_set()
    local types = {}
    local spawner = require_table_module("mvtk.tiled.object_spawner")
    for name in pairs(spawner.handlers or {}) do
        types[name] = true
    end
    -- Baked-only collider types (e.g. collision_slope / "Solid Slope") have no
    -- runtime handler but are still valid object types the build validator must
    -- accept. Pull the spawner registry's canonical build-time list so they
    -- resolve even though no handler is registered for them.
    local ok, registry = pcall(require_table_module, "mvtk.tiled.spawner_registry")
    if ok and type(registry) == "table"
        and type(registry.get_canonical_build_time_skip_types) == "function" then
        local got, skip_types = pcall(registry.get_canonical_build_time_skip_types)
        if got and type(skip_types) == "table" then
            for _, name in ipairs(skip_types) do
                types[name] = true
            end
        end
    end
    return types
end

local REQUIRED_OBJECT_FIELDS = {
    enemy = { {"enemy_type", "name"} },
    collectible = { {"collectible_type", "name"} },
    ability = { {"ability_id", "name"} },
    boss = { {"boss_id", "boss_preset", "name"} },
    npc = { {"npc_type", "name"} },
    cutscene = { {"cutscene_id", "name"} },
    fast_travel = { {"station_id", "name"} },
    map_marker = { {"marker_type", "name", "marker_label"} },
}

-- Build-time-only types are expected to generate real prefabs into collections.
-- Keep the table for future guardrails, but the currently supported set should
-- not be blocked by preflight.
local UNSUPPORTED_BUILD_TIME_ONLY_TYPES = {}

local function to_optional_bool(value)
    if value == nil then
        return nil
    end
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        if value == 0 then return false end
        if value == 1 then return true end
        return nil
    end
    local s = tostring(value):lower()
    if s == "true" or s == "1" then
        return true
    end
    if s == "false" or s == "0" then
        return false
    end
    return nil
end

local function get_prop_value(object_or_props, field)
    if field == nil then
        return nil
    end

    local props = object_or_props
    if type(object_or_props) == "table" and object_or_props.properties ~= nil then
        props = object_or_props.properties
    end
    if type(props) ~= "table" then
        return nil
    end

    -- PropertyFlattener.get also returns diagnostics. Do not leak that second
    -- value into calls such as tonumber(get_prop_value(...)), where Lua would
    -- interpret it as tonumber's optional numeric base.
    local value = PropertyFlattener.get(props, field)
    return value
end

local function has_prop(object, field)
    if field == "name" then
        return object.name and tostring(object.name) ~= ""
    end
    local value = get_prop_value(object, field)
    return value ~= nil and value ~= ""
end

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

local function is_background_layer_name(layer_name)
    local name = normalize_object_type(layer_name)
    if not name then
        return false
    end
    if name == "background" or name == "backgrounds" or name == "bg" then
        return true
    end
    if name:find("background", 1, true) then
        return true
    end
    if name:find("foreground", 1, true) then
        return true
    end
    if name:find("scenery", 1, true) then
        return true
    end
    return false
end

local function is_background_visual_object_candidate(object, layer_name)
    if object and (object.type == "object_art" or object.class == "object_art"
        or get_prop_value(object, "owner_ref") ~= nil and tonumber(get_prop_value(object, "owner_ref")) ~= 0) then
        return false
    end
    if type(object) ~= "table" or not object.gid then
        return false
    end

    local explicit = normalize_object_type(object.type)
    if not explicit then explicit = normalize_object_type(object.class) end
    if not explicit then explicit = normalize_object_type(object.className) end

    if explicit == "background_visual" or explicit == "background" then
        return true
    end

    local marker = get_prop_value(object, "background_visual")
    local marker_bool = to_optional_bool(marker)
    if marker_bool == true then
        return true
    end
    if type(marker) == "string" then
        local marker_name = normalize_object_type(marker)
        if marker_name == "background_visual" or marker_name == "background" then
            return true
        end
    end

    return is_background_layer_name(layer_name)
end

-- Drop-in static-collider templates ("Solid Box"/"Solid Slope" and their
-- synonyms) export from Tiled with a blank type/class, identified only by name.
-- These name sets mirror the runtime spawner aliases (mvtk/tiled/spawners/
-- environment.lua) and the build-time collision baker
-- (hooks/core/tilesource.lua resolve_solid_collision_object_type), so build-time
-- type resolution agrees with both.
local SOLID_BOX_NAME_TYPES = {
    solid_box = true,
    collision_box = true,
    solid = true,
    ground = true,
    collision = true,
}
local SOLID_SLOPE_NAME_TYPES = {
    solid_slope = true,
    collision_slope = true,
    slope = true,
}
local GRAPPLE_NAME_TYPES = {
    grapple_box = "grapple_box",
    grapple_slope = "grapple_slope",
}

local function infer_object_type(object)
    local props = object and object.properties or {}
    local name = normalize_object_type(object and object.name or nil)

    local function prop(key)
        return get_prop_value(props, key)
    end

    local function has(key)
        local v = prop(key)
        return v ~= nil and v ~= ""
    end

    -- Resolve the Solid Box/Slope collider templates by name up-front, before any
    -- property rule can hijack them -- e.g. a "Solid Slope" carries a `direction`
    -- property that would otherwise mis-infer as one_way_platform. Matches the
    -- runtime spawner, which dispatches these by name (object_spawner_core).
    if name then
        if SOLID_BOX_NAME_TYPES[name] then return "collision_box" end
        if SOLID_SLOPE_NAME_TYPES[name] then return "collision_slope" end
        if GRAPPLE_NAME_TYPES[name] then return GRAPPLE_NAME_TYPES[name] end
    end

    -- Player spawn/start objects export with blank type from Tiled templates.
    if prop("spawn_type") ~= nil then return "spawn_point" end
    if has("collectible_type") then return "collectible" end
    if has("chest_type") or has("contents") then return "chest" end

    -- Template identity properties. Each drop-in template has a stable unique id
    -- property; resolve on those before any generic/greedy property rule below.
    -- Mirrors mvtk/tiled/object_spawner_core.lua infer_object_type (keep in lockstep).
    if has("lore_id") then return "lore_item" end
    if has("hint_id") then return "hint_stone" end
    if has("sign_id") then return "sign" end
    if has("secret_id") or has("secret_type") or has("reveals_on") then return "secret" end
    if has("gate_id") or has("gate_type") then return "gate" end
    if has("water_id") or has("water_type")
        or prop("swim_enabled") ~= nil or prop("buoyancy") ~= nil or prop("oxygen_drain") ~= nil
    then
        return "water_volume"
    end
    if has("surface_id")
        or prop("jump_force_x") ~= nil or prop("jump_force_y") ~= nil
        or prop("allow_slide") ~= nil or prop("slide_speed") ~= nil
    then
        return "wall_jump_surface"
    end

    if has("save_id") or prop("heal_on_save") ~= nil or prop("is_fast_travel") ~= nil then return "save_point" end
    if has("checkpoint_id")
        or prop("respawn_facing") ~= nil
        or (name and name:find("checkpoint", 1, true))
    then
        return "checkpoint"
    end
    if has("bounce_speed")
        or (name and name:find("bounce", 1, true) and name:find("pad", 1, true))
    then
        return "bounce_pad"
    end
    if has("station_id") and (prop("heal_amount") ~= nil or prop("heal_percent") ~= nil
        or prop("recharge_time") ~= nil or prop("cost_currency") ~= nil)
    then
        return "health_station"
    end
    if has("station_id") and (prop("restore_amount") ~= nil or prop("restore_percent") ~= nil
        or has("resource_type"))
    then
        return "energy_station"
    end
    if has("station_id") and (has("reveal_area") or prop("reveal_radius") ~= nil
        or prop("reveal_full_biome") ~= nil)
    then
        return "map_station"
    end
    if has("station_id") then return "fast_travel" end
    local icon = normalize_object_type(prop("icon"))
    if (prop("auto_unlock") ~= nil
            or prop("unlock_cost") ~= nil
            or has("station_name")
            or has("station_description"))
        and ((name and name:find("fast", 1, true) and name:find("travel", 1, true))
            or (icon and icon:find("fast", 1, true) and icon:find("travel", 1, true)))
    then
        return "fast_travel"
    end
    if has("block_id") or prop("move_embedded_tiles") ~= nil or prop("gravity_scale") ~= nil then return "pushable_block" end
    if has("enemy_type") then return "enemy" end
    if has("phase_id")
        or prop("health_min") ~= nil
        or prop("health_max") ~= nil
        or prop("attack_interval_min") ~= nil
        or prop("attack_interval_max") ~= nil
        or prop("transition_type") ~= nil
        or prop("transition_duration") ~= nil
    then
        return "boss_phase"
    end
    if has("trigger_id")
        and prop("phase") ~= nil
        and (prop("transition_time") ~= nil or prop("set_flag") ~= nil or prop("requires_flag") ~= nil)
        and (has("boss_id") or has("boss_preset") or has("boss_type") or has("arena_id"))
    then
        return "boss_phase_trigger"
    end
    if has("point_id")
        or prop("damage_mult") ~= nil
        or prop("vulnerable") ~= nil
    then
        return "boss_weak_point"
    end
    if has("boundary_id")
        or prop("enabled_when_locked") ~= nil
        or prop("start_enabled") ~= nil
    then
        return "arena_boundary"
    end
    if prop("is_boss_arena") ~= nil
        or prop("camera_lock") ~= nil
        or prop("phases") ~= nil
    then
        return "boss_arena"
    end
    if has("arena_id")
        and (prop("lock_on_enter") ~= nil or prop("unlock_on_clear") ~= nil or has("encounter_id"))
    then
        return "arena_lock"
    end
    if has("boss_id") or has("boss_preset") or has("boss_type") then return "boss" end
    -- Dialogue Trigger carries an optional npc_id *link*; it must not classify as npc.
    -- npc detection keys on npc_type only (name == "npc" fallback already exists below).
    if has("dialogue_id") and not has("npc_type")
        and (has("trigger_id") or prop("auto_play") ~= nil or prop("consume_on_fire") ~= nil)
    then
        return "dialogue_trigger"
    end
    if has("npc_type") then return "npc" end
    if has("lever_id") then return "lever" end
    if has("plate_id")
        or prop("required_count") ~= nil
        or prop("allow_player") ~= nil
        or prop("allow_world") ~= nil
        or prop("allow_enemy") ~= nil
        or prop("stays_pressed") ~= nil
    then
        return "pressure_plate"
    end
    if has("door_id") and (
            prop("starts_locked") ~= nil
            or prop("require_ability") ~= nil
            or prop("require_key") ~= nil
            or prop("require_item") ~= nil
            or prop("consume_key") ~= nil
            or prop("unlock_message") ~= nil
        )
    then
        return "locked_door"
    end
    if has("door_id") and (prop("open_duration") ~= nil or prop("close_on_release") ~= nil or prop("auto_close") ~= nil) then return "timed_door" end
    if prop("ambience_id") ~= nil then return "ambience_zone" end
    if prop("music_id") ~= nil
        or prop("area_theme") ~= nil
        or prop("exit_music") ~= nil
        or prop("exit_area") ~= nil
    then
        return "music_trigger"
    end
    if has("marker_type") or has("marker_icon") or has("marker_label") then return "map_marker" end
    if has("ability_id") then return "ability" end
    -- Cross-room elevators are matched globally by elevator_id. Nodes must
    -- win before the controller rule because both object types intentionally
    -- share that identity property.
    if has("elevator_id") and has("node_id") then return "elevator_node" end
    if has("elevator_id") then return "elevator" end
    if has("conveyor_id") or (has("speed") and has("direction")) then return "conveyor" end
    if has("ladder_type") or has("climb_speed") then return "ladder" end
    if has("wall_type") or has("wall_id") then return "breakable_wall" end
    if has("hazard_type") or prop("instant_kill") ~= nil then return "hazard" end
    if has("teleporter_id") or has("pair_id") or has("target_id") then return "teleporter" end
    if has("crumble_delay")
        or has("shake_before_crumble")
        or has("sound_crumble")
        or has("sound_respawn")
    then
        return "crumble_platform"
    end
    if has("direction")
        and not has("speed")
        and not has("strength")
        and not has("hazard_type")
        and not has("damage")
        and not has("knockback_force")
        and not has("platform_type")
        and not has("path_name")
    then
        local shape = normalize_object_type(object and object.shape or nil)
        if shape == "rectangle" or shape == nil then
            return "one_way_platform"
        end
    end
    if has("use_joint") and (has("motor_speed") or has("path_dx") or has("path_dy")) then return "joint_platform" end
    if has("platform_type") or (has("distance") and has("speed")) then return "platform" end
    if has("path_name")
        or has("player_parent")
        or has("mode")
        or (has("start_delay") and has("wait_time") and has("trigger_id"))
        or (has("platform_id") and not has("respawn_delay"))
    then
        return "moving_platform"
    end
    if prop("effect_type") ~= nil and prop("zone_id") ~= nil then return "screen_effect_zone" end
    if has("camera_mode")
        or prop("zoom_level") ~= nil
        or prop("focus_x") ~= nil
        or prop("focus_y") ~= nil
        or prop("lock_x") ~= nil
        or prop("lock_y") ~= nil
        or prop("bounds_padding") ~= nil
        or prop("deadzone_width") ~= nil
        or prop("deadzone_height") ~= nil
        or prop("smooth_follow") ~= nil
        or prop("transition_speed") ~= nil
        or prop("auto_fit") ~= nil
    then
        return "camera_zone"
    end
    if has("light_id") or has("track_position") or has("intensity") then return "light_source" end
    -- Particle emitters are often authored with blank type and driven by effect_id.
    -- Infer the type from the canonical emitter properties so preflight doesn't block generation.
    if has("effect_id") or has("emitter_id") then return "particle_emitter" end

    if not name then
        return nil
    end

    if name == "dialogue_trigger" then return "dialogue_trigger" end
    if name == "npc" then return "npc" end
    if name == "health_station" then return "health_station" end
    if name == "energy_station" then return "energy_station" end
    if name == "map_station" then return "map_station" end
    if name == "water_volume" then return "water_volume" end
    if name == "secret" or name == "secret_area" then return "secret" end
    if name == "gate" then return "gate" end
    if name == "wall_jump_surface" then return "wall_jump_surface" end
    if name == "lore_item" then return "lore_item" end
    if name == "hint_stone" then return "hint_stone" end
    if name == "sign" then return "sign" end
    if name == "player_start" or name == "player_spawn" or name == "respawn_point" then return "spawn_point" end
    if name:find("player", 1, true) and (name:find("start", 1, true) or name:find("spawn", 1, true)) then return "spawn_point" end
    if name == "save_point" or name == "savepoint" then return "save_point" end
    if name == "checkpoint" or name:find("checkpoint", 1, true) then return "checkpoint" end
    if name:find("boss", 1, true) and name:find("spawn", 1, true) then return "boss" end
    if name:find("chest", 1, true) then return "chest" end
    if name == "lever" then return "lever" end
    if name:find("pressure", 1, true) and name:find("plate", 1, true) then return "pressure_plate" end
    if name:find("timed", 1, true) and name:find("door", 1, true) then return "timed_door" end
    if name:find("locked", 1, true) and name:find("door", 1, true) then return "locked_door" end
    if name == "collectible" or name:find("coin", 1, true) or name:find("gem", 1, true) then return "collectible" end
    if name == "map_marker" then return "map_marker" end
    if name:find("fast", 1, true) and name:find("travel", 1, true) then return "fast_travel" end
    if name:find("bounce", 1, true) and name:find("pad", 1, true) then return "bounce_pad" end
    if name:find("conveyor", 1, true) then return "conveyor" end
    if name:find("ladder", 1, true) then return "ladder" end
    if name:find("breakable", 1, true) and name:find("wall", 1, true) then return "breakable_wall" end
    if name:find("teleporter", 1, true) then return "teleporter" end
    if name == "elevator_node" then return "elevator_node" end
    if name == "elevator" then return "elevator" end
    if name:find("crumble", 1, true) then return "crumble_platform" end
    if name:find("horizontal", 1, true) and name:find("platform", 1, true) then return "platform" end
    if name:find("vertical", 1, true) and name:find("platform", 1, true) then return "platform" end
    if name:find("rail", 1, true) and (name:find("platform", 1, true) or name:find("elevator", 1, true)) then return "joint_platform" end
    if name == "joint_platform" or name == "rail_elevator" then return "joint_platform" end
    if name:find("path", 1, true) and name:find("platform", 1, true) then return "platform" end
    if name:find("moving", 1, true) and name:find("platform", 1, true) then return "moving_platform" end
    if name == "one_way_platform"
        or name:find("one_way_platform", 1, true)
        or (name:find("one_way", 1, true) and name:find("platform", 1, true))
        or (name:find("oneway", 1, true) and name:find("platform", 1, true))
    then
        return "one_way_platform"
    end
    if name:find("pushable", 1, true) and name:find("block", 1, true) then return "pushable_block" end
    if name:find("screen", 1, true) and name:find("effect", 1, true) then return "screen_effect_zone" end
    if name:find("ambience", 1, true) and name:find("zone", 1, true) then return "ambience_zone" end
    if name:find("music", 1, true) and name:find("trigger", 1, true) then return "music_trigger" end
    if name == "light_source" or (name:find("light", 1, true) and name:find("source", 1, true)) then return "light_source" end
    if name:find("particle", 1, true) and name:find("emitter", 1, true) then return "particle_emitter" end
    if name:find("ability", 1, true) then return "ability" end

    return nil
end

local function resolve_object_type(object, known_types)
    if object and object.gid and (tonumber(get_prop_value(object, "owner_ref")) or 0) > 0 then
        return "object_art", "explicit"
    end
    local explicit = normalize_object_type(object and object.type or nil)
    if not explicit then
        explicit = normalize_object_type(object and object.class or nil)
    end
    if not explicit then
        explicit = normalize_object_type(object and object.className or nil)
    end
    if not explicit then
        explicit = normalize_object_type(get_prop_value(object, "class"))
    end

    if explicit then
        if RetiredTypes.is_object_type(explicit) then return explicit, "retired" end
        if (not known_types) or known_types[explicit] then
            return explicit, "explicit"
        end
    end

    local inferred = infer_object_type(object)
    if inferred and ((not known_types) or known_types[inferred]) then
        if explicit then
            return inferred, "inferred_from_properties"
        end
        return inferred, "inferred"
    end

    -- Future templates whose default name already matches a registered type
    -- should resolve without requiring another bespoke property heuristic.
    local normalized_name = normalize_object_type(object and object.name or nil)
    if not inferred and normalized_name and known_types and known_types[normalized_name] then
        return normalized_name, "inferred_from_name"
    end

    if explicit then
        return explicit, "unknown_explicit"
    end
    return nil, "missing"
end

-- Object types whose runtime script copies the room tiles under its rectangle
-- onto the platform's own tilemap and clears the source room tiles. Static
-- collision for those cells must therefore be omitted from the room bake.
local TILE_COPY_PLATFORM_TYPES = {
    platform = true,
    moving_platform = true,
    crumble_platform = true,
    -- Elevator cabin art is extracted into its persistent generated tilemap.
    -- The source room must not retain stationary collision under that art.
    elevator = true,
}

-- Visit objects in every objectgroup, including objectgroups nested in Tiled
-- group layers. The callback receives the object, its objectgroup, and an
-- independent per-object state containing inherited layer offsets, effective
-- Tiled-map coordinates, and inherited/object visibility.
local function for_each_tiled_object(tiled_data, callback)
    local function visit(layers, inherited)
        inherited = inherited or { offsetx = 0, offsety = 0, visible = true }
        for _, layer in ipairs(layers or {}) do
            if type(layer) == "table" then
                local state = {
                    offsetx = (tonumber(inherited.offsetx) or 0) + (tonumber(layer.offsetx) or 0),
                    offsety = (tonumber(inherited.offsety) or 0) + (tonumber(layer.offsety) or 0),
                    visible = inherited.visible ~= false and layer.visible ~= false,
                }
                if layer.type == "objectgroup" then
                    for _, object in ipairs(layer.objects or {}) do
                        if type(object) == "table" then
                            callback(object, layer, {
                                offsetx = state.offsetx,
                                offsety = state.offsety,
                                effective_x = (tonumber(object.x) or 0) + state.offsetx,
                                effective_y = (tonumber(object.y) or 0) + state.offsety,
                                visible = state.visible ~= false and object.visible ~= false,
                            })
                        end
                    end
                end
                if type(layer.layers) == "table" then
                    visit(layer.layers, state)
                end
            end
        end
    end
    visit(tiled_data and tiled_data.layers, nil)
end

-- Return positive-area rectangles for objects whose runtime platform scripts
-- copy and clear room tiles. Coordinates stay in Tiled pixel space (Y down).
local function collect_tile_copy_platform_rects(tiled_data, known_types)
    local rects = {}
    for_each_tiled_object(tiled_data, function(object, _, object_state)
        local object_type = resolve_object_type(object, known_types)
        if object_state.visible ~= false and TILE_COPY_PLATFORM_TYPES[object_type] then
            local width = tonumber(object.width) or 0
            local height = tonumber(object.height) or 0
            if width > 0 and height > 0 then
                rects[#rects + 1] = {
                    x = object_state.effective_x,
                    y = object_state.effective_y,
                    width = width,
                    height = height,
                    id = object.id,
                    type = object_type,
                }
            else
                info(string.format(
                    "collect_tile_copy_platform_rects: skipping degenerate %s id=%s (%sx%s)",
                    tostring(object_type), tostring(object.id), tostring(width), tostring(height)))
            end
        end
    end)
    return rects
end

-- Convert Tiled-space platform rectangles to the 0-based, Y-up cell keys used
-- in generated Defold .tilemap text. floor/ceil deliberately includes every
-- partially covered cell, matching tile_platform.script's runtime copy.
local function tile_copy_platform_cell_exclusions(tiled_data, rects, tile_width, tile_height)
    local excluded = {}
    local ranges = {}
    local tw = tonumber(tile_width) or tonumber(tiled_data and tiled_data.tilewidth) or 0
    local th = tonumber(tile_height) or tonumber(tiled_data and tiled_data.tileheight) or 0
    if tw <= 0 or th <= 0 then
        return excluded, ranges
    end
    local map_h_px = (tonumber(tiled_data and tiled_data.height) or 0)
        * (tonumber(tiled_data and tiled_data.tileheight) or th)
    for _, rect in ipairs(rects or {}) do
        local left = tonumber(rect.x) or 0
        local bottom = map_h_px - (tonumber(rect.y) or 0) - (tonumber(rect.height) or 0)
        local min_cx = math.floor(left / tw)
        local max_cx = math.ceil((left + (tonumber(rect.width) or 0)) / tw) - 1
        local min_cy = math.floor(bottom / th)
        local max_cy = math.ceil((bottom + (tonumber(rect.height) or 0)) / th) - 1
        ranges[#ranges + 1] = {
            min_cx = min_cx, max_cx = max_cx,
            min_cy = min_cy, max_cy = max_cy,
            rect = rect,
        }
        for cy = min_cy, max_cy do
            for cx = min_cx, max_cx do
                excluded[cx .. "," .. cy] = true
            end
        end
    end
    return excluded, ranges
end

local function validate_object_fields(object, errors_out)
    local req_sets = REQUIRED_OBJECT_FIELDS[object.type]
    if not req_sets then return end
    for _, set in ipairs(req_sets) do
        local ok = false
        for _, field in ipairs(set) do
            if has_prop(object, field) then
                ok = true
                break
            end
        end
        if not ok then
            errors_out[#errors_out + 1] = string.format("object id=%s type=%s missing required property (%s)", tostring(object.id), tostring(object.type), table.concat(set, " | "))
        end
    end
end

local function preflight_tiled_map(room_id, known_types)
    local errors, warnings = {}, {}
    local tiled_data, load_err = load_tiled_export(room_id)
    if not tiled_data then
        errors[#errors + 1] = string.format("failed to load tiled export: %s", tostring(load_err))
        return errors, warnings
    end
    if not tiled_data.layers then
        return errors, warnings
    end
    for_each_tiled_object(tiled_data, function(object, layer)
                local obj_type, type_source = resolve_object_type(object, known_types)
                local is_helper_geometry = object.polyline or object.polygon
                local is_background_visual = is_background_visual_object_candidate(object, layer.name)
                if RetiredTypes.is_object_type(obj_type) then
                    warnings[#warnings + 1] = RetiredTypes.warning(object, room_id)
                elseif is_background_visual then
                    object.type = "background_visual"
                elseif not obj_type or obj_type == "" then
                    if not is_helper_geometry then
                        errors[#errors + 1] = string.format("object id=%s in layer '%s' is missing a type/class", tostring(object.id), tostring(layer.name))
                    end
                elseif type_source == "unknown_explicit" or not known_types[obj_type] then
                    errors[#errors + 1] = string.format("object id=%s has unknown type '%s' (layer '%s')", tostring(object.id), tostring(obj_type), tostring(layer.name))
                else
                    object.type = obj_type
                    local unsupported_reason = UNSUPPORTED_BUILD_TIME_ONLY_TYPES[obj_type]
                    if unsupported_reason then
                        errors[#errors + 1] = string.format(
                            "object id=%s type=%s in layer '%s' is not safe to use yet: %s",
                            tostring(object.id),
                            tostring(obj_type),
                            tostring(layer.name),
                            tostring(unsupported_reason)
                        )
                    end
                    if obj_type == "gate" then
                        local warning = RetiredTypes.required_ability_warning(object, room_id, get_prop_value(object, "required_ability"))
                        if warning then warnings[#warnings + 1] = warning end
                    end
                    validate_object_fields(object, errors)
                end
    end)
    return errors, warnings
end

local function preflight_tiled_maps(room_ids)
    local known_types = load_object_type_set()
    local all_errors = {}
    for _, rid in ipairs(room_ids) do
        local errs, warnings = preflight_tiled_map(rid, known_types)
        for _, warning in ipairs(warnings or {}) do
            info("[TILED PREFLIGHT][WARNING] " .. warning)
        end
        for _, e in ipairs(errs) do
            all_errors[#all_errors + 1] = string.format("%s: %s", rid, e)
        end
    end
    if #all_errors > 0 then
        info("[TILED PREFLIGHT] Found issues in Tiled exports:")
        for _, e in ipairs(all_errors) do
            info("  - " .. e)
        end
        info("[TILED PREFLIGHT] See tiled/templates/README.html for valid object types and properties.")
        info("[TILED PREFLIGHT] WARNING: Continuing generation despite " .. tostring(#all_errors) .. " issues. Objects missing a type will get fallback markers.")
    end
end


M.REQUIRED_OBJECT_FIELDS = REQUIRED_OBJECT_FIELDS
M.load_object_type_set = load_object_type_set
M.unwrap_tiled_prop_value = unwrap_tiled_prop_value
M.to_optional_bool = to_optional_bool
M.get_prop_value = get_prop_value
M.has_prop = has_prop
M.normalize_object_type = normalize_object_type
M.is_background_layer_name = is_background_layer_name
M.is_background_visual_object_candidate = is_background_visual_object_candidate
M.infer_object_type = infer_object_type
M.resolve_object_type = resolve_object_type
M.TILE_COPY_PLATFORM_TYPES = TILE_COPY_PLATFORM_TYPES
M.for_each_tiled_object = for_each_tiled_object
M.collect_tile_copy_platform_rects = collect_tile_copy_platform_rects
M.tile_copy_platform_cell_exclusions = tile_copy_platform_cell_exclusions
M.validate_object_fields = validate_object_fields
M.preflight_tiled_map = preflight_tiled_map
M.preflight_tiled_maps = preflight_tiled_maps

return M

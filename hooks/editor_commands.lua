-- editor_commands.lua
-- Part 3 of the editor hook scripts (loaded after editor_generators.lua).
-- Contains room generation orchestration, export, and the M module table
-- returned to Defold as the editor_script interface.
--
-- All shared state is read from hooks.core.context, populated by
-- editor_core.lua, editor_script.lua, and editor_generators.lua.

local Context = require "hooks.core.context"
local _C = Context.require_context("hooks/editor_commands.lua")

-- High-frequency symbols from editor_core.lua
local normalize = _C.normalize
local editor_api = _C.editor_api
local HEADLESS = _C.HEADLESS
local info = _C.info
local ROOT = _C.ROOT
local DIR_SEP = _C.DIR_SEP
local to_os_path = _C.to_os_path
local PATH = _C.PATH
local TILED_MAPS_RESOURCE_DIR = _C.TILED_MAPS_RESOURCE_DIR or "/developer/assets/tiled/maps"
local TileSnap = _C.TileSnap
local CollisionBox = _C.CollisionBox
local lfs_ok = _C.lfs_ok
local lfs = _C.lfs
local get_tiled_paths = _C.get_tiled_paths
local join = _C.join
local ensure_dir = _C.ensure_dir
local copy_file_basic = _C.copy_file_basic
local copy_file_any = _C.copy_file_any
local copy_directory_filesystem = _C.copy_directory_filesystem
local list_dir_filesystem = _C.list_dir_filesystem
local read_text = _C.read_text
local file_exists = _C.file_exists
local file_exists_any = _C.file_exists_any
local read_binary_any = _C.read_binary_any
local write_if_changed = _C.write_if_changed
local write_binary_if_changed = _C.write_binary_if_changed
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
local relink_prefab_tilemaps = _C.relink_prefab_tilemaps
local get_selected_tilemap_ids = _C.get_selected_tilemap_ids
local prepare_export_game_project = _C.prepare_export_game_project
local gen_level_go = _C.gen_level_go
local gen_backgrounds_go = _C.gen_backgrounds_go
local gen_pushable_block_go = _C.gen_pushable_block_go
local gen_hazard_zone_go = _C.gen_hazard_zone_go
local gen_ladder_go = _C.gen_ladder_go
local sanitize_collision_group_text = _C.sanitize_collision_group_text
local run_validate_all = _C.run_validate_all
local sync_tilesheet_images = _C.sync_tilesheet_images
local regenerate_all_tilemaps_from_lua = _C.regenerate_all_tilemaps_from_lua
local delete_my_room_files = _C.delete_my_room_files
local reset_project_to_empty = _C.reset_project_to_empty
local remove_path_filesystem = _C.remove_path_filesystem
local profiler = _C.profiler
local TileSettings = require "developer.config.tile_settings"
local MusicSync = require "mvtk.audio.music_sync"
local BakeAudit = require "hooks.core.bake_audit"
local ProtoEmit = require "mvtk.editor.proto_emit"
local PlayerScaleWriter = require "mvtk.editor.player_scale_writer"
local STANDARD_TILE_COLLISION_FIRST = _C.STANDARD_TILE_COLLISION_FIRST or 2
local STANDARD_TILE_COLLISION_LAST = _C.STANDARD_TILE_COLLISION_LAST or 20

-- Symbols from editor_script.lua
local _visual = _C.visual_helpers
local standardize_tilesource_collision_setup = _C.standardize_tilesource_collision_setup
local collect_room_background_sprite_components = _C.collect_room_background_sprite_components
local take_background_import_warnings = _C.take_background_import_warnings
local get_room_background_atlas_paths = _C.get_room_background_atlas_paths
local flatten_tiled_layers = _C.flatten_tiled_layers

-- Symbols from editor_generators.lua
local gen_collection = _C.gen_collection

local function gen_factory_holder(ids, elevator_manifest)
    local parts = {}
    for _, rid in ipairs(ids) do
        parts[#parts + 1] = table.concat({
            "components {",
            string.format("  id: \"room_factory_%s\"", rid),
            string.format("  component: \"/developer/rooms/factories/%s_factory.collectionfactory\"", rid),
            "}",
            "",
        }, "\n")
    end
    for _, elevator_id in ipairs((elevator_manifest and elevator_manifest.ordered_ids) or {}) do
        local elevator = elevator_manifest.elevators and elevator_manifest.elevators[elevator_id]
        if elevator and elevator.valid ~= false and elevator.resource_key then
            local bundle = _C.ElevatorContract.resource_bundle(
                elevator.resource_key, _C.GENERATED_ROOMS_RESOURCE_DIR)
            parts[#parts + 1] = table.concat({
                "components {",
                string.format("  id: \"%s\"",
                    _C.ElevatorContract.factory_component_id(elevator.resource_key)),
                string.format("  component: \"%s\"", bundle.factory_resource),
                "}",
                "",
            }, "\n")
        end
    end
    return table.concat(parts, "\n")
end

function _C.scan_elevator_manifest(room_ids, phase)
    local manifest, diagnostics = _C.ElevatorManifest.build(room_ids, function(room_id)
        return load_tiled_export(room_id)
    end)
    for _, diagnostic in ipairs(diagnostics or {}) do
        info(string.format(
            "[ELEVATOR_MANIFEST][%s][%s] elevator=%s room=%s object=%s: %s",
            tostring(diagnostic.severity or "info"):upper(),
            tostring(diagnostic.code or "unknown"),
            tostring(diagnostic.elevator_id or "-"),
            tostring(diagnostic.room_id or "-"),
            tostring(diagnostic.object_id or "-"),
            tostring(diagnostic.message or "")
        ))
    end
    if _C.ElevatorManifest.has_errors(diagnostics) then
        error(string.format(
            "%s found %d invalid cross-room elevator authoring error(s). "
                .. "Fix the reported elevator/elevator_node objects in Tiled and run Prepare & Check again.",
            tostring(phase or "Create Rooms"), tonumber(manifest and manifest.error_count) or 1
        ), 0)
    end
    _C.elevator_manifest = manifest
    return manifest
end

local function gen_rooms_config(ids)
    local lines = {
        "-- developer/config/rooms_config.lua (generated by hooks.editor_script)",
        "-- Maps room collection IDs to factory component URLs included in main.collection",
        "local M = { factories = {",
    }
    for _, rid in ipairs(ids) do
        lines[#lines + 1] = string.format("    [\"developer/rooms/%s\"] = \"main:/room_factories#room_factory_%s\",", rid, rid)
    end
    lines[#lines + 1] = "}}"
    lines[#lines + 1] = "return M"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function sanitize_instance_id(rid)
    local safe = rid:gsub("[^%w_]", "_")
    if safe == "" then
        safe = "room"
    elseif safe:match("^[^%a_]") then
        safe = "room_" .. safe
    end
    return safe
end

local function gen_manifest(ids)
    local out = {}
    out[#out + 1] = "name: \"rooms_manifest\""
    out[#out + 1] = "embedded_instances {"
    out[#out + 1] = "  id: \"rooms_manifest\""
    out[#out + 1] = "  data: \"components {\\n\""
    out[#out + 1] = "  \"  id: \\\"rooms_manifest\\\"\\n\""
    out[#out + 1] = "  \"  component: \\\"/mvtk/editor_host/rooms_manifest.script\\\"\\n\""
    out[#out + 1] = "  \"}\\n\""
    out[#out + 1] = "  \"\""
    out[#out + 1] = "}"
    local used_ids = {}
    for _, rid in ipairs(ids) do
        local tm = string.format("%s/%s.tilemap", TILED_MAPS_RESOURCE_DIR:gsub("/+$", ""), rid)
        local instance_id = sanitize_instance_id(rid)
        local base = instance_id
        local counter = 2
        while used_ids[instance_id] do
            instance_id = string.format("%s_%d", base, counter)
            counter = counter + 1
        end
        used_ids[instance_id] = true
        out[#out + 1] = "embedded_instances {"
        out[#out + 1] = string.format("  id: \"%s\"", instance_id)
        out[#out + 1] = "  data: \"components {\\n\""
        out[#out + 1] = "  \"  id: \\\"rooms_manifest_item\\\"\\n\""
        out[#out + 1] = "  \"  component: \\\"/mvtk/editor_host/rooms_manifest_item.script\\\"\\n\""
        out[#out + 1] = "  \"}\\n\""
        out[#out + 1] = "  \"components {\\n\""
        out[#out + 1] = "  \"  id: \\\"tilemap\\\"\\n\""
        out[#out + 1] = string.format("  \"  component: \\\"%s\\\"\\n\"", tm)
        out[#out + 1] = "  \"}\\n\""
        out[#out + 1] = "  \"\""
        out[#out + 1] = "}"
    end
    out[#out + 1] = ""
    return table.concat(out, "\n")
end

-- ============================================================================
-- AMBIENT SOUND CONFIG GENERATION
-- ============================================================================
-- Scans Tiled room ambience and ambience_zone objects and updates the config
-- with any new ambience IDs found. This allows devs to define sounds in Tiled
-- without touching code.

local function collect_ambient_sounds_from_tiled(room_ids)
    local sound_ids = {}  -- Set of room and zone ambience IDs
    local function add_sound_id(value)
        local sound_id = value ~= nil and tostring(value) or nil
        if sound_id and sound_id ~= "" and sound_id ~= "none" then
            sound_ids[sound_id] = true
        end
    end

    for _, rid in ipairs(room_ids) do
        local data = load_tiled_export(rid)
        if data then
            add_sound_id(get_prop_value(data, "ambient_sound"))
            local function scan_layers(layers)
                for _, layer in ipairs(layers or {}) do
                    if layer.type == "objectgroup" and layer.objects then
                        for _, obj in ipairs(layer.objects) do
                            if resolve_object_type(obj) == "ambience_zone" then
                                add_sound_id(get_prop_value(obj, "ambience_id"))
                            end
                        end
                    elseif layer.type == "group" and layer.layers then
                        scan_layers(layer.layers)
                    end
                end
            end
            scan_layers(data.layers)
        end
    end

    return sound_ids
end

local function update_ambient_sounds_config(room_ids)
    local config_path = ROOT .. "/developer/config/ambient_sounds.lua"

    local function escape_lua_string(s)
        s = tostring(s or "")
        s = s:gsub("\\", "\\\\")
        s = s:gsub('"', '\\"')
        return s
    end

    local function to_component_id(sound_id)
        local token = tostring(sound_id or ""):lower()
        token = token:gsub("[^%w]+", "_")
        token = token:gsub("^_+", "")
        token = token:gsub("_+$", "")
        if token == "" then
            token = "sound"
        end
        return "ambient_" .. token
    end

    -- Collect room and zone ambience IDs from all Tiled exports
    local found_ids = collect_ambient_sounds_from_tiled(room_ids)

    -- Read existing config to preserve user edits
    local existing = {}
    local file = io.open(config_path, "r")
    if file then
        local content = file:read("*a")
        file:close()

        -- Parse existing entries from either ["key"] = { ... } or bare key = { ... }.
        for sound_id in content:gmatch('%[%s*"([^"]+)"%s*%]%s*=%s*{') do
            existing[sound_id] = true
        end
        for sound_id in content:gmatch('\n%s*([_%a][_%w]*)%s*=%s*{') do
            if sound_id ~= "M" then
                existing[sound_id] = true
            end
        end
    end

    -- Find new sound_ids that need to be added
    local new_ids = {}
    for sound_id in pairs(found_ids) do
        if not existing[sound_id] then
            new_ids[#new_ids + 1] = sound_id
        end
    end

    if #new_ids == 0 then
        return  -- No new sounds to add
    end

    -- Sort for consistent ordering
    table.sort(new_ids)

    -- Generate new config file content
    local out = {}
    out[#out + 1] = "-- developer/config/ambient_sounds.lua"
    out[#out + 1] = "-- Maps ambient sound IDs (from Tiled) to sound component names in the audio game object."
    out[#out + 1] = "--"
    out[#out + 1] = "-- HOW TO USE:"
    out[#out + 1] = "-- 1. Add a sound component to your audio game object (main:/audio)"
    out[#out + 1] = '-- 2. Name it something like "ambient_waterfall"'
    out[#out + 1] = "-- 3. Map the Tiled ambience_id or room ambient_sound value to that component name"
    out[#out + 1] = "--"
    out[#out + 1] = "-- The editor script detects ambience_zone IDs and room ambience from your Tiled maps"
    out[#out + 1] = "-- and adds placeholder entries here. You just need to:"
    out[#out + 1] = "-- 1. Create the sound components in Defold"
    out[#out + 1] = "-- 2. Update the component_name to match"
    out[#out + 1] = "--"
    out[#out + 1] = "-- Example Tiled object:"
    out[#out + 1] = "--   Type: ambience_zone"
    out[#out + 1] = "--   ambience_id: waterfall"
    out[#out + 1] = "--"
    out[#out + 1] = '-- This config maps "waterfall" -> "ambient_waterfall" component'
    out[#out + 1] = ""
    out[#out + 1] = "local M = {"
    out[#out + 1] = '    -- Format: [sound_id] = { component = "component_name", group = "ambient" }'
    out[#out + 1] = "    --"
    out[#out + 1] = "    -- sound_id: The Tiled ambience_id or room ambient_sound value"
    out[#out + 1] = "    -- component: The name of the sound component in the audio game object"
    out[#out + 1] = '    -- group: (optional) Sound group for volume control, defaults to "ambient"'
    out[#out + 1] = ""

    -- Collect all sound_ids (existing + new)
    local all_ids = {}
    for id in pairs(existing) do all_ids[#all_ids + 1] = id end
    for id in pairs(found_ids) do
        if not existing[id] then
            all_ids[#all_ids + 1] = id
        end
    end
    table.sort(all_ids)

    for _, sound_id in ipairs(all_ids) do
        local is_new = not existing[sound_id]
        local component_name = to_component_id(sound_id)
        local key_escaped = escape_lua_string(sound_id)
        local component_escaped = escape_lua_string(component_name)
        if is_new then
            out[#out + 1] = string.format("    -- NEW: Auto-added from Tiled export")
        end
        out[#out + 1] = string.format('    ["%s"] = {', key_escaped)
        out[#out + 1] = string.format('        component = "%s",', component_escaped)
        out[#out + 1] = '        group = "ambient",'
        out[#out + 1] = "    },"
        out[#out + 1] = ""
    end

    out[#out + 1] = "    -- Add more ambient sounds here as needed"
    out[#out + 1] = "    -- The editor script will auto-add entries when it finds new sound_ids in Tiled"
    out[#out + 1] = "}"
    out[#out + 1] = ""
    out[#out + 1] = "return M"

    local content = table.concat(out, "\n")
    if write_if_changed(config_path, content) then
        info("Updated ambient_sounds.lua with " .. #new_ids .. " new sound(s): " .. table.concat(new_ids, ", "))
    end
end

local function trim_string(value)
    if value == nil then
        return nil
    end
    local s = tostring(value)
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    if s == "" then
        return nil
    end
    return s
end

local function escape_lua_string(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\r", "\\r")
    s = s:gsub("\n", "\\n")
    return s
end

local function decode_tiled_gid_value(gid)
    local value = tonumber(gid) or 0
    if value >= _visual.TILED_FLIP_H then
        value = value - _visual.TILED_FLIP_H
    end
    if value >= _visual.TILED_FLIP_V then
        value = value - _visual.TILED_FLIP_V
    end
    if value >= _visual.TILED_FLIP_D then
        value = value - _visual.TILED_FLIP_D
    end
    if value < 0 then value = 0 end
    if value > _visual.TILED_GID_MASK then
        value = value % (_visual.TILED_GID_MASK + 1)
    end
    return value
end

local function find_primary_tileset_for_tilemap(tiled_data)
    if type(tiled_data) ~= "table" or type(tiled_data.tilesets) ~= "table" then
        return nil
    end

    local primary_tileset = nil
    local biome = get_tiled_property(tiled_data.properties, "biome")
    if biome and biome ~= "" then
        local wanted = tostring(biome):lower()
        for _, ts in ipairs(tiled_data.tilesets) do
            if tostring(ts and ts.name or ""):lower() == wanted then
                primary_tileset = ts
                break
            end
        end
    end

    if not primary_tileset then
        primary_tileset = tiled_data.tilesets[1]
    end

    return primary_tileset
end

local function find_tileset_lastgid(tilesets, target_tileset, fallback_tilecount)
    local firstgid = tonumber(target_tileset and target_tileset.firstgid)
    if not firstgid or firstgid <= 0 then
        return nil
    end

    local next_firstgid = nil
    for _, ts in ipairs(tilesets or {}) do
        if ts ~= target_tileset then
            local other_firstgid = tonumber(ts and ts.firstgid)
            if other_firstgid and other_firstgid > firstgid then
                if not next_firstgid or other_firstgid < next_firstgid then
                    next_firstgid = other_firstgid
                end
            end
        end
    end

    if next_firstgid then
        return next_firstgid - 1
    end

    local tilecount = tonumber(fallback_tilecount)
    if tilecount and tilecount > 0 then
        return firstgid + tilecount - 1
    end

    return _visual.TILED_GID_MASK
end

local function build_tileset_gid_ranges(tiled_data)
    local ranges = {}
    for _, ts in ipairs((tiled_data and tiled_data.tilesets) or {}) do
        local firstgid = tonumber(ts and ts.firstgid)
        if firstgid and firstgid > 0 then
            ranges[#ranges + 1] = {
                firstgid = firstgid,
                lastgid = find_tileset_lastgid(tiled_data.tilesets, ts, tonumber(ts.tilecount)),
                name = tostring(ts.name or ""),
            }
        end
    end
    table.sort(ranges, function(a, b) return a.firstgid < b.firstgid end)
    return ranges
end

local function normalize_tiled_layer_name(name)
    local normalized = tostring(name or ""):lower()
    normalized = normalized:gsub("[%s%-]+", "_")
    normalized = normalized:gsub("[^%w_]", "_")
    normalized = normalized:gsub("_+", "_")
    normalized = normalized:gsub("^_+", "")
    normalized = normalized:gsub("_+$", "")
    return normalized
end

local SOLID_COLLISION_OBJECT_TYPES = {
    collision_box = true,
    solid_box = true,
    solid = true,
    ground = true,
    collision = true,
    collision_slope = true,
    solid_slope = true,
    slope = true,
}

local function normalize_tiled_object_type(value)
    if value == nil then
        return nil
    end
    local normalized = normalize_tiled_layer_name(value)
    if normalized == "" then
        return nil
    end
    return normalized
end

local function get_object_property(object, key)
    local props = type(object) == "table" and object.properties or nil
    if type(props) ~= "table" then
        return nil
    end
    if props[key] ~= nil then
        return props[key]
    end
    for _, entry in ipairs(props) do
        if type(entry) == "table" and (entry.name == key or entry.Name == key) then
            if entry.value ~= nil then return entry.value end
            if entry.Value ~= nil then return entry.Value end
        end
    end
    return nil
end

local function object_has_solid_collision_type(object)
    local candidates = {
        object and object.type,
        object and object.class,
        object and object.className,
    }
    local template_file = get_object_property(object, "template_file")
    if template_file ~= nil then
        candidates[#candidates + 1] = tostring(template_file):match("([^/\\]+)%.tx$") or template_file
    end
    candidates[#candidates + 1] = object and object.name

    for _, value in ipairs(candidates) do
        local normalized = normalize_tiled_object_type(value)
        if normalized and SOLID_COLLISION_OBJECT_TYPES[normalized] then
            return true
        end
    end

    local solid = get_object_property(object, "solid")
    if solid == true then
        return true
    end
    if solid ~= nil then
        local s = tostring(solid):lower()
        return s == "true" or s == "1" or s == "yes" or s == "on"
    end
    return false
end

local function count_collision_sources(tiled_data, tiled_export_path)
    local counts = {
        shaped_tiles = 0,
        solid_objects = 0,
        painted_solid_tiles = 0,
    }

    local primary_tileset = find_primary_tileset_for_tilemap(tiled_data)
    local meta = nil
    local firstgid = nil
    local lastgid = nil
    if type(primary_tileset) == "table" and _C.get_tileset_meta then
        meta = _C.get_tileset_meta(primary_tileset, tiled_export_path)
        firstgid = tonumber(primary_tileset.firstgid)
        lastgid = find_tileset_lastgid(tiled_data.tilesets, primary_tileset, meta and meta.tilecount)
    end

    for _, entry in ipairs(flatten_tiled_layers(tiled_data.layers) or {}) do
        local layer = entry.layer
        local layer_name = normalize_tiled_layer_name(layer and layer.name or "")
        if layer and layer.type == "tilelayer" then
            for _, raw_gid in ipairs(layer.data or {}) do
                local gid = decode_tiled_gid_value(raw_gid)
                if gid > 0 then
                    if layer_name == "solid" then
                        counts.painted_solid_tiles = counts.painted_solid_tiles + 1
                    end
                    if meta and meta.tile_collision and firstgid and lastgid and gid >= firstgid and gid <= lastgid then
                        local local_tile_id = gid - firstgid
                        if meta.tile_collision[local_tile_id] then
                            counts.shaped_tiles = counts.shaped_tiles + 1
                        end
                    end
                end
            end
        elseif layer and layer.type == "objectgroup" and type(layer.objects) == "table" then
            for _, object in ipairs(layer.objects) do
                if object and object.visible ~= false and object_has_solid_collision_type(object) then
                    counts.solid_objects = counts.solid_objects + 1
                end
            end
        end
    end

    return counts
end

local function warn_missing_room_collision(room_ids)
    for _, rid in ipairs(room_ids or {}) do
        local tiled_data, tiled_export_path_or_err = load_tiled_export(rid)
        if type(tiled_data) ~= "table" then
            info(string.format("[WARN] Room '%s': could not inspect collision sources (%s).",
                tostring(rid), tostring(tiled_export_path_or_err)))
        else
            local counts = count_collision_sources(tiled_data, tiled_export_path_or_err)
            if counts.shaped_tiles == 0
                and counts.solid_objects == 0
                and counts.painted_solid_tiles == 0
            then
                info(string.format(
                    "[WARN] Room '%s': no collision authored. Add Tile Collision Editor shapes, Solid Box/Slope objects, or a painted solid layer before playtesting. See the gen_room_tile_collision coverage summary above for painted tile ids without collision.",
                    tostring(rid)
                ))
            end
        end
    end
end

local function collect_tilemap_animation_defs_for_room(room_id)
    local tiled_data, tiled_export_path = load_tiled_export(room_id)
    if not tiled_data or type(tiled_data.layers) ~= "table" then
        return {}
    end

    local primary_tileset = find_primary_tileset_for_tilemap(tiled_data)
    if type(primary_tileset) ~= "table" then
        return {}
    end

    local meta = _C.get_tileset_meta(primary_tileset, tiled_export_path)
    if type(meta) ~= "table" or meta.collection then
        return {}
    end

    local tile_animations = meta.tile_animations or {}
    if next(tile_animations) == nil then
        return {}
    end

    local firstgid = tonumber(primary_tileset.firstgid)
    local lastgid = find_tileset_lastgid(tiled_data.tilesets, primary_tileset, meta.tilecount)
    if not firstgid or firstgid <= 0 or not lastgid or lastgid < firstgid then
        return {}
    end

    local defs = {}
    local flattened_layers = flatten_tiled_layers(tiled_data.layers)

    for _, entry in ipairs(flattened_layers) do
        local layer = entry.layer
        if layer and layer.type == "tilelayer" and type(layer.data) == "table" then
            local used_local_ids = {}

            for _, raw_gid in ipairs(layer.data) do
                local gid = decode_tiled_gid_value(raw_gid)
                if gid >= firstgid and gid <= lastgid then
                    local local_tile_id = gid - firstgid
                    if tile_animations[local_tile_id] then
                        used_local_ids[local_tile_id] = true
                    end
                end
            end

            local ordered_local_ids = {}
            for local_tile_id in pairs(used_local_ids) do
                ordered_local_ids[#ordered_local_ids + 1] = local_tile_id
            end
            table.sort(ordered_local_ids)

            for _, local_tile_id in ipairs(ordered_local_ids) do
                local animation = tile_animations[local_tile_id]
                if type(animation) == "table" and type(animation.frames) == "table" and #animation.frames >= 2 then
                    local frames = {}
                    local durations_ms = {}

                    for i, frame_local_id in ipairs(animation.frames) do
                        frames[#frames + 1] = (tonumber(frame_local_id) or 0) + 1
                        durations_ms[#durations_ms + 1] = math.floor((tonumber(animation.durations_ms and animation.durations_ms[i]) or 100) + 0.5)
                    end

                    defs[#defs + 1] = {
                        layer = tostring(layer.name or ""),
                        seed_tile = local_tile_id + 1,
                        frames = frames,
                        frame_durations_ms = durations_ms,
                        match_any_frame = false,
                        source = string.format("tsx:%s#tile:%d", tostring(primary_tileset.name or "tileset"), local_tile_id),
                    }
                end
            end
        end
    end

    table.sort(defs, function(a, b)
        if a.layer ~= b.layer then
            return a.layer < b.layer
        end
        return (a.seed_tile or 0) < (b.seed_tile or 0)
    end)

    return defs
end

local function render_lua_number_array(values)
    local items = {}
    for _, value in ipairs(values or {}) do
        items[#items + 1] = tostring(math.floor((tonumber(value) or 0) + 0.5))
    end
    return "{ " .. table.concat(items, ", ") .. " }"
end

local function gen_tilemap_animation_config(room_ids)
    local lines = {
        "-- developer/config/tilemap_animations_generated.lua (generated by hooks.editor_script)",
        "-- Auto-generated tile animation definitions derived from Tiled tileset animations.",
        "-- Do not edit this file. Use developer/config/tilemap_animations.lua for manual overrides.",
        "",
        "local M = {",
        "    defaults = {},",
        "    rooms = {",
    }

    for _, room_id in ipairs(room_ids or {}) do
        local defs = collect_tilemap_animation_defs_for_room(room_id)
        if #defs > 0 then
            lines[#lines + 1] = string.format('        ["%s"] = {', escape_lua_string(room_id))
            for _, def in ipairs(defs) do
                lines[#lines + 1] = "            {"
                lines[#lines + 1] = string.format('                layer = "%s",', escape_lua_string(def.layer))
                lines[#lines + 1] = string.format("                seed_tile = %d,", tonumber(def.seed_tile) or 1)
                lines[#lines + 1] = string.format("                frames = %s,", render_lua_number_array(def.frames))
                lines[#lines + 1] = string.format("                frame_durations_ms = %s,", render_lua_number_array(def.frame_durations_ms))
                lines[#lines + 1] = string.format("                match_any_frame = %s,", tostring(def.match_any_frame == true))
                lines[#lines + 1] = string.format('                source = "%s",', escape_lua_string(def.source))
                lines[#lines + 1] = "            },"
            end
            lines[#lines + 1] = "        },"
        end
    end

    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return M"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function update_generated_tilemap_animation_config(room_ids)
    local config_path = ROOT .. "/developer/config/tilemap_animations_generated.lua"
    local content = gen_tilemap_animation_config(room_ids)
    if write_if_changed(config_path, content) then
        info("Updated tilemap_animations_generated.lua")
    end
end

local function should_generate_cutscene_entry(props)
    if type(props) ~= "table" then
        return false
    end
    if props.generate_cutscene == true then
        return true
    end
    return trim_string(props.video_id)
        or trim_string(props.video_uri)
        or trim_string(props.video_editor_uri)
        or trim_string(props.cutscene_dialogue_id)
        or trim_string(props.dialogue_id)
end

local function collect_generated_cutscenes_from_tiled(room_ids)
    local entries = {}
    local ordered_ids = {}
    local seen_ids = {}

    local function register_cutscene(entry)
        if not entry or not entry.id then
            return
        end
        if not seen_ids[entry.id] then
            seen_ids[entry.id] = true
            ordered_ids[#ordered_ids + 1] = entry.id
        end
        entries[entry.id] = entry
    end

    for _, rid in ipairs(room_ids) do
        local data = load_tiled_export(rid)
        if data and data.layers then
            local flattened_layers = flatten_tiled_layers(data.layers)
            for _, entry in ipairs(flattened_layers) do
                local layer = entry.layer
                if layer and layer.type == "objectgroup" and type(layer.objects) == "table" then
                    for _, obj in ipairs(layer.objects) do
                        if obj and obj.visible ~= false and resolve_object_type(obj) == "cutscene" then
                            local props = obj.properties or {}
                            if should_generate_cutscene_entry(props) then
                                local cutscene_id = trim_string(props.cutscene_id)
                                    or trim_string(props.cutscene_name)
                                    or trim_string(obj.name)
                                    or string.format("tiled_cutscene_%s_%s", tostring(rid), tostring(obj.id or "0"))

                                local dialogue_id = trim_string(props.cutscene_dialogue_id)
                                    or trim_string(props.dialogue_id)
                                local video_id = trim_string(props.video_id)
                                local video_uri = trim_string(props.video_uri)
                                local video_editor_uri = trim_string(props.video_editor_uri)
                                local steps = {}

                                if props.cutscene_use_fade ~= false then
                                    steps[#steps + 1] = { type = "fade", to = "in" }
                                    steps[#steps + 1] = { type = "wait", t = tonumber(props.cutscene_wait) or 0.2 }
                                    steps[#steps + 1] = { type = "fade", to = "out" }
                                end

                                if video_id or video_uri or video_editor_uri then
                                    local video_step = { type = "video" }
                                    if video_id then
                                        video_step.video_id = video_id
                                    else
                                        video_step.id = cutscene_id
                                    end
                                    if video_uri then
                                        video_step.uri = video_uri
                                    end
                                    if video_editor_uri then
                                        video_step.editor_uri = video_editor_uri
                                    end
                                    if props.video_play_sound ~= nil then
                                        video_step.play_sound = props.video_play_sound and true or false
                                    end
                                    if props.video_timeout ~= nil then
                                        video_step.timeout = tonumber(props.video_timeout) or 12
                                    end
                                    steps[#steps + 1] = video_step
                                end

                                if dialogue_id then
                                    steps[#steps + 1] = {
                                        type = "dialogue",
                                        id = dialogue_id,
                                    }
                                end

                                if #steps > 0 then
                                    register_cutscene({
                                        id = cutscene_id,
                                        room_id = rid,
                                        object_id = obj.id,
                                        trigger_id = trim_string(props.trigger_id),
                                        steps = steps,
                                    })
                                else
                                    info(string.format(
                                        "Skipped generated cutscene for room %s object %s (no video/dialogue steps found)",
                                        tostring(rid), tostring(obj.id)))
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(ordered_ids)
    return entries, ordered_ids
end

local function append_lua_scalar_line(out, key, value, indent)
    indent = indent or ""
    local value_type = type(value)
    if value_type == "string" then
        out[#out + 1] = string.format('%s%s = "%s",', indent, key, escape_lua_string(value))
    elseif value_type == "boolean" then
        out[#out + 1] = string.format("%s%s = %s,", indent, key, value and "true" or "false")
    else
        out[#out + 1] = string.format("%s%s = %s,", indent, key, fmt_num(tonumber(value) or 0))
    end
end

local function update_generated_cutscenes_config(room_ids)
    local config_path = ROOT .. "/developer/config/narrative/cutscenes_generated.lua"
    local entries, ordered_ids = collect_generated_cutscenes_from_tiled(room_ids)

    local out = {}
    out[#out + 1] = "-- developer/config/narrative/cutscenes_generated.lua (generated by hooks.editor_script)"
    out[#out + 1] = "-- Source: Tiled objects with type='cutscene'"
    out[#out + 1] = "-- DO NOT EDIT: regenerate rooms from Tiled to update this file."
    out[#out + 1] = "--"
    out[#out + 1] = "-- Supported Tiled properties for generated cutscenes:"
    out[#out + 1] = "--   cutscene_id (string): generated cutscene id and runtime trigger target."
    out[#out + 1] = "--   cutscene_name (string): generated id when cutscene_id is blank."
    out[#out + 1] = "--   video_id (string): video clip id from developer/config/narrative/videos.lua."
    out[#out + 1] = "--   video_uri (string): optional direct video URI (bundle/runtime path)."
    out[#out + 1] = "--   video_editor_uri (string): optional editor-only video URI."
    out[#out + 1] = "--   video_play_sound (bool): optional sound toggle for video playback."
    out[#out + 1] = "--   video_timeout (number): optional timeout seconds for video playback."
    out[#out + 1] = "--   cutscene_dialogue_id (string): optional dialogue id step (dialogue_id is accepted too)."
    out[#out + 1] = "--   cutscene_use_fade (bool): include fade in/wait/out wrapper (default true)."
    out[#out + 1] = "--   cutscene_wait (number): wait duration between fade in/out (default 0.20)."
    out[#out + 1] = "return {"

    for _, cutscene_id in ipairs(ordered_ids) do
        local entry = entries[cutscene_id]
        out[#out + 1] = string.format('    ["%s"] = {', escape_lua_string(cutscene_id))
        out[#out + 1] = string.format("        -- room=%s object_id=%s trigger_id=%s",
            tostring(entry.room_id), tostring(entry.object_id), tostring(entry.trigger_id or ""))
        for _, step in ipairs(entry.steps) do
            out[#out + 1] = "        {"
            append_lua_scalar_line(out, "type", step.type, "            ")
            if step.to ~= nil then
                append_lua_scalar_line(out, "to", step.to, "            ")
            end
            if step.id ~= nil then
                append_lua_scalar_line(out, "id", step.id, "            ")
            end
            if step.video_id ~= nil then
                append_lua_scalar_line(out, "video_id", step.video_id, "            ")
            end
            if step.uri ~= nil then
                append_lua_scalar_line(out, "uri", step.uri, "            ")
            end
            if step.editor_uri ~= nil then
                append_lua_scalar_line(out, "editor_uri", step.editor_uri, "            ")
            end
            if step.play_sound ~= nil then
                append_lua_scalar_line(out, "play_sound", step.play_sound, "            ")
            end
            if step.timeout ~= nil then
                append_lua_scalar_line(out, "timeout", step.timeout, "            ")
            end
            if step.t ~= nil then
                append_lua_scalar_line(out, "t", step.t, "            ")
            end
            out[#out + 1] = "        },"
        end
        out[#out + 1] = "    },"
    end

    out[#out + 1] = "}"
    out[#out + 1] = ""

    if write_if_changed(config_path, table.concat(out, "\n")) then
        info("Updated cutscenes_generated.lua with " .. tostring(#ordered_ids) .. " generated cutscene(s)")
    end
end

-- ── Generation cache ────────────────────────────────────────────────
-- Tracks mtime of each room's Tiled inputs so we can skip unchanged rooms.
-- Cache file lives alongside generated output so it's easy to wipe.
local GENERATION_CACHE_PATH = join(PATH.generated_go, ".generation_cache")

local function load_generation_cache()
    local text = read_text(GENERATION_CACHE_PATH)
    if not text then return {} end
    local cache = {}
    for line in text:gmatch("[^\r\n]+") do
        local rid, lua_mt, tm_mt = line:match("^([^|]+)|([^|]+)|(.+)$")
        if rid then
            cache[rid] = { lua_mtime = tonumber(lua_mt), tilemap_mtime = tonumber(tm_mt) }
        end
    end
    return cache
end

local function save_generation_cache(cache)
    local lines = {}
    local sorted_ids = {}
    for rid in pairs(cache) do sorted_ids[#sorted_ids + 1] = rid end
    table.sort(sorted_ids)
    for _, rid in ipairs(sorted_ids) do
        local e = cache[rid]
        lines[#lines + 1] = string.format("%s|%s|%s", rid, tostring(e.lua_mtime or 0), tostring(e.tilemap_mtime or 0))
    end
    write_if_changed(GENERATION_CACHE_PATH, table.concat(lines, "\n") .. "\n")
end

local function list_room_ids_checked(context, world_manifest)
    profiler.start("list_room_ids")
    local ok_ids, ids_or_err = pcall(list_room_ids)
    profiler.stop("list_room_ids")
    if not ok_ids then
        error(string.format("[%s] Failed to list room ids: %s", tostring(context), tostring(ids_or_err)), 0)
    end
    if type(ids_or_err) ~= "table" then
        error(string.format("[%s] list_room_ids() returned %s", tostring(context), type(ids_or_err)), 0)
    end
    return require("developer.tools.world_layout").generation_room_ids({root=ROOT,world_manifest=world_manifest},ids_or_err)
end

local function get_room_input_mtimes(room_id)
    if not lfs_ok or not lfs then return nil, nil end
    local tiled_maps_path, tiled_tilemaps_path = get_tiled_paths()
    local lua_path = normalize(join(ROOT, tiled_maps_path, room_id .. ".lua"))
    local tm_path = normalize(join(ROOT, tiled_tilemaps_path, room_id .. ".tilemap"))
    local lua_mt = lfs.attributes(lua_path, "modification")
    local tm_mt = lfs.attributes(tm_path, "modification")
    return lua_mt, tm_mt
end

-- Returns the list of room ids whose Tiled inputs have changed since
-- the last cached generation, plus a boolean indicating whether the
-- room list itself changed (additions/removals).
local function compute_changed_rooms(all_ids)
    local cache = load_generation_cache()
    local changes = {
        changed = {},
        lua_changed = {},
        tilemap_changed = {},
        new_rooms = {},
        list_changed = false,
    }
    local seen = {
        changed = {},
        lua_changed = {},
        tilemap_changed = {},
        new_rooms = {},
    }

    local function add(which, rid)
        local list = changes[which]
        local set = seen[which]
        if not set[rid] then
            set[rid] = true
            list[#list + 1] = rid
        end
    end

    local current_set = {}

    for rid in pairs(cache) do
        current_set[rid] = false
    end

    -- Detect new or modified rooms. Treat .lua and .tilemap changes
    -- separately so tilemap-only edits can take the lighter path.
    for _, rid in ipairs(all_ids) do
        current_set[rid] = true
        local lua_mt, tm_mt = get_room_input_mtimes(rid)
        local lua_stamp = lua_mt or 0
        local tm_stamp = tm_mt or 0
        local prev = cache[rid]
        local prev_lua = prev and (prev.lua_mtime or 0) or 0
        local prev_tm = prev and (prev.tilemap_mtime or 0) or 0
        local is_new = prev == nil
        local lua_changed = is_new or (lua_stamp ~= prev_lua)
        local tilemap_changed = is_new or (tm_stamp ~= prev_tm)

        if is_new then
            add("new_rooms", rid)
            changes.list_changed = true
        end
        if lua_changed then
            add("lua_changed", rid)
        end
        if tilemap_changed then
            add("tilemap_changed", rid)
        end
        if is_new or lua_changed or tilemap_changed then
            add("changed", rid)
        end
    end

    -- Detect removed rooms (present in cache but no longer in all_ids).
    for rid, present in pairs(current_set) do
        if present == false then
            changes.list_changed = true
            break
        end
    end

    return changes
end

local function update_cache_for_rooms(cache, room_ids)
    for _, rid in ipairs(room_ids) do
        local lua_mt, tm_mt = get_room_input_mtimes(rid)
        cache[rid] = { lua_mtime = lua_mt or 0, tilemap_mtime = tm_mt or 0 }
    end
end

local function has_tiled_room_exports()
    local dir = PATH.tilemaps
    if lfs_ok and lfs then
        local attr = lfs.attributes(dir, "mode")
        if attr == "directory" then
            for file in lfs.dir(dir) do
                if file:match("%.lua$") or file:match("%.tilemap$") then
                    return true
                end
            end
        end
    else
        local _, files = list_dir_filesystem(dir)
        for _, file in ipairs(files or {}) do
            if file:match("%.lua$") or file:match("%.tilemap$") then
                return true
            end
        end
    end
    return false
end

-- Cross-check every visible object on the Tiled `templates` layer against the
-- generated collection, then compare sibling TMX template basenames with the
-- resolved object type. This is deliberately shared by Create Rooms and the
-- consolidated Import Assets report so a skipped bake can never be silent.
local function audit_baked_rooms(room_ids, opts)
    opts = opts or {}
    local result = {
        rooms = 0,
        objects = 0,
        errors = 0,
        warnings = 0,
        error_messages = {},
        warning_messages = {},
    }

    local ok_known, known_types = pcall(_C.load_object_type_set)
    if not ok_known or type(known_types) ~= "table" then
        local message = "baked-object audit could not load the registered Tiled object types: "
            .. tostring(known_types)
        info("[BUILD]   ERROR " .. message)
        result.errors = 1
        result.error_messages[1] = message
        return result
    end

    for _, rid in ipairs(room_ids or {}) do
        local collection_path = join(PATH.collections, tostring(rid) .. ".collection")
        local collection_text = read_text(collection_path)
        if type(collection_text) ~= "string" or collection_text == "" then
            if opts.require_collections then
                local message = string.format(
                    "room '%s' has no generated collection to audit at '%s'",
                    tostring(rid), tostring(collection_path)
                )
                info("[BUILD]   ERROR " .. message)
                result.errors = result.errors + 1
                result.error_messages[#result.error_messages + 1] = message
            end
        else
            local tiled_map, map_err = load_tiled_export(rid)
            if type(tiled_map) ~= "table" then
                local message = string.format(
                    "room '%s' baked-object audit could not load its Tiled Lua export: %s",
                    tostring(rid), tostring(map_err or "unknown error")
                )
                info("[BUILD]   ERROR " .. message)
                result.errors = result.errors + 1
                result.error_messages[#result.error_messages + 1] = message
            else
                local tmx_text = read_text(join(PATH.tilemaps, tostring(rid) .. ".tmx"))
                local ok_audit, report = pcall(BakeAudit.audit_room, {
                    room_id = rid,
                    tiled_map = tiled_map,
                    collection_text = collection_text,
                    tmx_text = tmx_text,
                    known_types = known_types,
                    resolve_object_type = resolve_object_type,
                    build_time_skip_types = ProtoEmit.BUILD_TIME_SKIP_SPAWN_TYPES,
                    read_resource = read_text,
                })
                result.rooms = result.rooms + 1
                if not ok_audit or type(report) ~= "table" then
                    local message = string.format(
                        "room '%s' baked-object audit failed unexpectedly: %s",
                        tostring(rid), tostring(report)
                    )
                    info("[BUILD]   ERROR " .. message)
                    result.errors = result.errors + 1
                    result.error_messages[#result.error_messages + 1] = message
                else
                    result.objects = result.objects + #(report.objects or {})
                    for _, finding in ipairs(report.errors or {}) do
                        local message = tostring(finding.message or finding.code or "unknown bake-audit error")
                        info("[BUILD]   ERROR " .. message)
                        result.errors = result.errors + 1
                        result.error_messages[#result.error_messages + 1] = message
                    end
                    for _, finding in ipairs(report.warnings or {}) do
                        local message = tostring(finding.message or finding.code or "unknown bake-audit warning")
                        info("[BUILD]   WARN  " .. message)
                        result.warnings = result.warnings + 1
                        result.warning_messages[#result.warning_messages + 1] = message
                    end
                end
            end
        end
    end

    if result.errors == 0 and result.warnings == 0 then
        info(string.format(
            "[BUILD] Baked object audit: %d templates-layer object(s) mapped across %d room(s)",
            result.objects, result.rooms
        ))
    else
        info(string.format(
            "[BUILD] Baked object audit: %d error(s), %d warning(s) across %d room(s)",
            result.errors, result.warnings, result.rooms
        ))
    end
    return result
end

-- ── generate (full) ─────────────────────────────────────────────────
-- Called by menu commands and the room-build workflow.
-- Always processes all (or selected) rooms regardless of cache.
local function generate(selected_ids, world_manifest, opts)
    opts=opts or {}
    if not opts.profile_session then profiler.reset() end
    profiler.start("TOTAL generate()")
    _C.clear_ensure_dir_cache()
    _C.begin_resource_write_batch()
    require("hooks.core.filesystem").begin_tilemap_staging()

    profiler.start("ensure_dirs")
    ensure_dir(PATH.generated_go)
    ensure_dir(PATH.generated_scenery_tiles)
    ensure_dir(PATH.collections)
    ensure_dir(PATH.factories)
    profiler.stop("ensure_dirs")

    local all_ids = list_room_ids_checked("generate", world_manifest)
    info("generate: ROOT=" .. ROOT)
    info("Rooms: " .. table.concat(all_ids, ", "))
    if #all_ids == 0 then
        local err = "No Tiled room exports found in " .. PATH.tilemaps
            .. ". If you just ran Delete My Rooms, export fresh .lua/.tilemap room files from Tiled here before regenerating rooms."
        info("generate: " .. err)
        error(err, 0)
    end

    local ids = nil
    if not selected_ids or #selected_ids == 0 then
        ids = all_ids
    else
        ids = {}
        for _, rid in ipairs(selected_ids) do ids[#ids + 1] = rid end
        info("generate: selected rooms=" .. table.concat(ids, ", "))
    end

    -- Elevators are a world-level feature: every controller and route node
    -- must be validated together even when Create Rooms was invoked for a
    -- selected subset. Store the manifest on the shared editor context so the
    -- per-room generator can use its collision-proof resource keys.
    profiler.start("scan_elevator_manifest")
    local elevator_manifest = _C.scan_elevator_manifest(all_ids, "Create Rooms")
    profiler.stop("scan_elevator_manifest")

    -- A generated holder must never point at a cabin factory that has not
    -- been materialized. Selected-room generation therefore includes every
    -- elevator controller room; node-only rooms remain scoped to the user's
    -- selection because their canonical route data lives in the global index.
    if selected_ids and #selected_ids > 0 then
        local included = {}
        for _, rid in ipairs(ids) do included[rid] = true end
        for _, elevator_id in ipairs(elevator_manifest.ordered_ids or {}) do
            local elevator = elevator_manifest.elevators[elevator_id]
            local controller_room = elevator and elevator.controller and elevator.controller.room_id
            if controller_room and not included[controller_room] then
                included[controller_room] = true
                ids[#ids + 1] = controller_room
                info(string.format(
                    "generate: included elevator controller room '%s' for persistent factory '%s'",
                    tostring(controller_room), tostring(elevator.resource_key or elevator_id)
                ))
            end
        end
        table.sort(ids)
    end

    -- Regenerate .tilemap files from Tiled .lua exports so the .lua is the
    -- single source of truth (users no longer need to export .tilemap separately).
    profiler.start("regenerate_all_tilemaps_from_lua")
    if not opts.tilemaps_regenerated then regenerate_all_tilemaps_from_lua(ids) end
    profiler.stop("regenerate_all_tilemaps_from_lua")

    -- Validate Tiled exports before generating rooms
    profiler.start("preflight_tiled_maps")
    _C.preflight_tiled_maps(ids)
    profiler.stop("preflight_tiled_maps")

    profiler.start("per-room level_go + collection")
    require("mvtk.editor.object_art").catalog(_C, all_ids)
    for _, rid in ipairs(ids) do
        profiler.start("  gen_level_go [" .. rid .. "]")
        local lvl_path = join(PATH.generated_go, rid .. "_level.go")
        if write_if_changed(lvl_path, sanitize_collision_group_text(gen_level_go(rid, _C.ParallaxBake.prepare_tiles(_C, rid)))) then
            info("Wrote " .. lvl_path)
        end
        -- Subsequent bakers read pending resources through file_utils. Commit
        -- the complete set once, before the disk-based audit below.

        local tilecol_path = join(PATH.generated_go, rid .. "_tilecol.go")
        if write_if_changed(tilecol_path, _C.gen_level_tilecol_go(rid)) then
            info("Wrote " .. tilecol_path)
        end
        profiler.stop("  gen_level_go [" .. rid .. "]")

        profiler.start("  gen_collection [" .. rid .. "]")
        local col_path = join(PATH.collections, rid .. ".collection")
        if write_if_changed(col_path, gen_collection(rid)) then
            info("Wrote " .. col_path)
        end
        profiler.stop("  gen_collection [" .. rid .. "]")
    end
    profiler.stop("per-room level_go + collection")

    profiler.start("per-room factories")
    for _, rid in ipairs(all_ids) do
        local fpath = join(PATH.factories, rid .. "_factory.collectionfactory")
        local text = string.format("prototype: \"/developer/rooms/collections/%s.collection\"\nload_dynamically: true\n", rid)
        if write_if_changed(fpath, text) then
            info("Wrote " .. fpath)
        end
    end
    profiler.stop("per-room factories")

    profiler.start("gen_factory_holder + config + manifest")
    if write_if_changed(PATH.holder_go, gen_factory_holder(all_ids, elevator_manifest)) then
        info("Updated factory holder")
    end
    if write_if_changed(PATH.config_lua, gen_rooms_config(all_ids)) then
        info("Updated rooms_config.lua")
    end
    do
        -- Runtime layer-existence manifest (Defold cannot list tilemap layers).
        local TilemapLayers = require "hooks.core.tilemap_layers"
        local layers = TilemapLayers.build(all_ids, function(rid)
            return _C.ParallaxBake.main_tilemap_text(_C, rid)
        end)
        if write_if_changed(join(ROOT, TilemapLayers.MANIFEST_PATH), TilemapLayers.generate(layers)) then
            info("Updated " .. TilemapLayers.MANIFEST_PATH)
        end
        -- Inline chest contents are baked as hashes; list every string so
        -- release builds (no reverse hashes) can resolve them.
        local ChestInline = require "hooks.core.chest_inline_contents"
        local inline = {}
        for _, rid in ipairs(all_ids) do
            ChestInline.collect(read_text(join(PATH.collections, rid .. ".collection")), inline)
        end
        if write_if_changed(join(ROOT, ChestInline.CONFIG_PATH), ChestInline.generate(inline)) then
            info("Updated " .. ChestInline.CONFIG_PATH)
        end
    end
    if write_if_changed(PATH.manifest_col, gen_manifest(all_ids)) then
        info("Updated rooms_manifest.collection")
    end
    if write_if_changed(PATH.elevator_config_lua, _C.ElevatorConfig.generate(elevator_manifest)) then
        info("Updated elevators_generated.lua")
    end
    profiler.stop("gen_factory_holder + config + manifest")

    -- Auto-update ambient_sounds.lua config with any new sound_ids from Tiled
    profiler.start("update_ambient_sounds_config")
    update_ambient_sounds_config(all_ids)
    profiler.stop("update_ambient_sounds_config")

    profiler.start("update_generated_cutscenes_config")
    update_generated_cutscenes_config(all_ids)
    profiler.stop("update_generated_cutscenes_config")

    profiler.start("update_generated_tilemap_animation_config")
    update_generated_tilemap_animation_config(all_ids)
    profiler.stop("update_generated_tilemap_animation_config")

    -- Heal the bundled prefab tilemaps so the project still compiles after a
    -- destructive reset wiped their hardcoded sample tilesource. Non-fatal.
    pcall(relink_prefab_tilemaps, all_ids)

    -- Make every queued collection/factory/config visible before the audit.
    _C.end_resource_write_batch()

    profiler.start("post_bake_object_audit")
    local bake_audit = audit_baked_rooms(ids, { require_collections = true })
    profiler.stop("post_bake_object_audit")
    if bake_audit.errors > 0 then
        error(string.format(
            "Create Rooms baked-object audit found %d error(s); see the Defold Console for object ids and fixes.",
            bake_audit.errors
        ), 0)
    end

    profiler.start("reconcile generated elevator resources")
    local elevator_reconcile, elevator_reconcile_err =
        _C.ElevatorResources.reconcile_generated_resources(elevator_manifest, {
            generated = join(PATH.generated_go, _C.ElevatorContract.RESOURCE_SUBDIR),
            collections = join(PATH.collections, _C.ElevatorContract.RESOURCE_SUBDIR),
            factories = join(PATH.factories, _C.ElevatorContract.RESOURCE_SUBDIR),
        }, {
            list_dir = _C.list_dir_filesystem,
            remove = _C.remove_path_filesystem,
            exists = _C.file_exists_any,
            join = _C.join,
            info = _C.info,
        })
    profiler.stop("reconcile generated elevator resources")
    if not elevator_reconcile then
        error("Could not reconcile generated elevator resources: "
            .. tostring(elevator_reconcile_err), 0)
    end

    -- Commit the input cache only after generation, audit, and stale-resource
    -- reconciliation have all succeeded. A failed cleanup must retry.
    profiler.start("save_generation_cache")
    local new_cache = {}
    update_cache_for_rooms(new_cache, all_ids)
    save_generation_cache(new_cache)
    profiler.stop("save_generation_cache")

    profiler.stop("TOTAL generate()")
    if not opts.profile_session then profiler.report() end
end

-- Wrapper that ensures profiler.report() runs even if generate() throws
local _original_generate = generate
generate = function(selected_ids, world_manifest, opts)
    local ok, err = pcall(_original_generate, selected_ids, world_manifest, opts)
    if not ok then
        _C.cancel_resource_write_batch()
        -- Ensure timing data is captured and reported even on failure
        profiler.stop("TOTAL generate()")
        if not (opts and opts.profile_session) then profiler.report() end
        error(err, 0)
    end
end

-- ── generate_incremental ────────────────────────────────────────────
-- Called by on_build_started. Only processes rooms whose Tiled inputs
-- have changed since the last generation, and only runs maintenance
-- steps (sync images, relink tilesources, etc.) for those rooms.
local function generate_incremental()
    _C.clear_ensure_dir_cache()
    ensure_dir(PATH.generated_go)
    ensure_dir(PATH.generated_scenery_tiles)
    ensure_dir(PATH.collections)
    ensure_dir(PATH.factories)

    require("developer.tools.relationship_project").require_valid({
        root=ROOT, list_dir_filesystem=list_dir_filesystem, log=info, publish_report=true,
    })
    local all_ids = list_room_ids_checked("generate_incremental")
    if #all_ids == 0 then
        info("generate_incremental: no rooms found")
        return
    end

    local changes = compute_changed_rooms(all_ids)
    local changed = changes.changed
    local lua_changed = changes.lua_changed
    local tilemap_changed = changes.tilemap_changed
    local new_rooms = changes.new_rooms
    local list_changed = changes.list_changed

    -- Tile animations live in external TSX files, which may change without
    -- touching the room .lua/.tilemap exports. Regenerate this config on every
    -- build so saved Tiled animation edits are always picked up.
    update_generated_tilemap_animation_config(all_ids)

    if #changed == 0 and not list_changed then
        info("generate_incremental: nothing changed, skipping (" .. #all_ids .. " rooms up to date)")
        return
    end

    info("generate_incremental: " .. #changed .. "/" .. #all_ids .. " rooms changed"
        .. string.format(" [lua=%d tilemap=%d new=%d]", #lua_changed, #tilemap_changed, #new_rooms)
        .. (list_changed and " (room list changed)" or ""))

    local elevator_manifest = _C.elevator_manifest
    if #lua_changed > 0 then
        for k in pairs(_visual.TILESOURCE_METADATA_CACHE) do _visual.TILESOURCE_METADATA_CACHE[k] = nil end
        -- Regenerate before the world-level scan and cabin extraction so the
        -- Tiled Lua export remains the single source of truth.
        regenerate_all_tilemaps_from_lua(lua_changed)
        sync_tilesheet_images(lua_changed)
        _C.preflight_tiled_maps(lua_changed)
    end
    if list_changed or #lua_changed > 0 then
        elevator_manifest = _C.scan_elevator_manifest(all_ids, "Incremental room generation")
    end

    -- The world-level holder publishes every valid persistent elevator
    -- factory. If a node-only room is the file that made a route valid, its
    -- unchanged controller room still has to be regenerated in this same
    -- transaction so the referenced cabin collection/factory exists.
    local generation_lua_ids = lua_changed
    local forced_controller_ids = {}
    if list_changed or #lua_changed > 0 then
        generation_lua_ids, forced_controller_ids =
            _C.ElevatorManifest.expand_generation_rooms(lua_changed, elevator_manifest)
        for _, controller_room in ipairs(forced_controller_ids) do
            info(string.format(
                "generate_incremental: included elevator controller room '%s' for persistent factory generation",
                tostring(controller_room)
            ))
        end
    end

    if #forced_controller_ids > 0 then
        regenerate_all_tilemaps_from_lua(forced_controller_ids)
        sync_tilesheet_images(forced_controller_ids)
        _C.preflight_tiled_maps(forced_controller_ids)
    end

    local generation_changed = {}
    local changed_seen = {}
    for _, rid in ipairs(changed) do
        changed_seen[rid] = true
        generation_changed[#generation_changed + 1] = rid
    end
    for _, rid in ipairs(forced_controller_ids) do
        if not changed_seen[rid] then
            changed_seen[rid] = true
            generation_changed[#generation_changed + 1] = rid
        end
    end
    table.sort(generation_changed)

    -- Lua-export changes affect collection generation, validation, and
    -- tilesheet syncing. Tilemap-only changes only need tile_set relinking.
    if #generation_changed > 0 then
        require("mvtk.editor.object_art").catalog(_C, list_room_ids())
        update_all_tilemap_tilesources(generation_changed)

        -- Collision standardization is cheap and global, keep it tied
        -- to room-related edits so we still auto-heal stale tilesources.
        standardize_tilesource_collision_setup()

        -- Object and collision data come from the Tiled Lua export, so update
        -- both level prototypes whenever it changes (not just for new rooms).
        for _, rid in ipairs(generation_lua_ids) do
            local lvl_path = join(PATH.generated_go, rid .. "_level.go")
            if write_if_changed(lvl_path, sanitize_collision_group_text(gen_level_go(rid, _C.ParallaxBake.prepare_tiles(_C, rid)))) then
                info("Wrote " .. lvl_path)
            end

            local tilecol_path = join(PATH.generated_go, rid .. "_tilecol.go")
            if write_if_changed(tilecol_path, _C.gen_level_tilecol_go(rid)) then
                info("Wrote " .. tilecol_path)
            end
        end

        for _, rid in ipairs(generation_lua_ids) do
            local col_path = join(PATH.collections, rid .. ".collection")
            if write_if_changed(col_path, gen_collection(rid)) then
                info("Wrote " .. col_path)
            end
        end
    end

    -- Room factories/config depend on the room list; the persistent factory
    -- holder and elevator index also change when elevator objects are edited.
    if list_changed then
        for _, rid in ipairs(all_ids) do
            local fpath = join(PATH.factories, rid .. "_factory.collectionfactory")
            local text = string.format("prototype: \"/developer/rooms/collections/%s.collection\"\nload_dynamically: true\n", rid)
            if write_if_changed(fpath, text) then
                info("Wrote " .. fpath)
            end
        end

    end
    if list_changed or #lua_changed > 0 then
        if write_if_changed(PATH.holder_go, gen_factory_holder(all_ids, elevator_manifest)) then
            info("Updated factory holder")
        end
        if write_if_changed(PATH.config_lua, gen_rooms_config(all_ids)) then
            info("Updated rooms_config.lua")
        end
        if write_if_changed(PATH.manifest_col, gen_manifest(all_ids)) then
            info("Updated rooms_manifest.collection")
        end
        if write_if_changed(PATH.elevator_config_lua, _C.ElevatorConfig.generate(elevator_manifest)) then
            info("Updated elevators_generated.lua")
        end
    end

    -- ambient_sounds.lua only auto-adds new IDs, so scanning rooms whose
    -- Tiled Lua export changed is enough during incremental builds.
    if #lua_changed > 0 then
        update_ambient_sounds_config(lua_changed)
    end

    if list_changed or #lua_changed > 0 then
        update_generated_cutscenes_config(all_ids)
    end

    if #generation_lua_ids > 0 then
        local bake_audit = audit_baked_rooms(generation_lua_ids, { require_collections = true })
        if bake_audit.errors > 0 then
            error(string.format(
                "Incremental room generation baked-object audit found %d error(s); see the Defold Console for details.",
                bake_audit.errors
            ), 0)
        end
    end

    if list_changed or #lua_changed > 0 then
        local elevator_reconcile, elevator_reconcile_err =
            _C.ElevatorResources.reconcile_generated_resources(elevator_manifest, {
                generated = join(PATH.generated_go, _C.ElevatorContract.RESOURCE_SUBDIR),
                collections = join(PATH.collections, _C.ElevatorContract.RESOURCE_SUBDIR),
                factories = join(PATH.factories, _C.ElevatorContract.RESOURCE_SUBDIR),
            }, {
                list_dir = _C.list_dir_filesystem,
                remove = _C.remove_path_filesystem,
                exists = _C.file_exists_any,
                join = _C.join,
                info = _C.info,
            })
        if not elevator_reconcile then
            error("Could not reconcile generated elevator resources: "
                .. tostring(elevator_reconcile_err), 0)
        end
    end

    -- Update cache
    local new_cache = {}
    update_cache_for_rooms(new_cache, all_ids)
    save_generation_cache(new_cache)
end

local show_perf_report_completion_dialog
local sync_tiled_template_defaults
local sync_music_core
local sync_enemy_art_core

-- Keep the runtime animation index on the same editor-bake path as room
-- generation.  Enemy art is synced before this runs, and room generation may
-- create project atlases of its own, so invoke it after both phases have
-- settled their source files.
local function safe_generate(selected_ids, opts)
    opts = opts or {}
    if not opts.exports_checked then
    require("developer.tools.preparation").require_exports({root=ROOT,list_dir_filesystem=list_dir_filesystem,world_manifest=opts.world_manifest})
    end
    require("developer.tools.relationship_project").require_valid({
        root=ROOT, list_dir_filesystem=list_dir_filesystem, log=info, publish_report=true,
        check_generated=false, -- This command rebuilds the generated chest lookup.
    })
    if selected_ids and #selected_ids > 0 then
        info("safe_generate: starting for selection: " .. table.concat(selected_ids, ", "))
    else
        info("safe_generate: starting for all rooms")
    end
    pcall(sync_tiled_template_defaults)

    -- Register custom enemy art before room generation so Create Rooms is the
    -- only command needed after dropping enemy skin PNGs into the project.
    -- Non-fatal: bad art should be surfaced in the console without blocking
    -- room rebuilds.
    local eok, enemy_core_ok, enemy_result = pcall(sync_enemy_art_core)
    if opts.strict then assert(eok and enemy_core_ok,"Enemy art synchronization failed: "..tostring(enemy_result or enemy_core_ok)) end
    if not eok then
        info("[ENEMY_ART] Skipped during Create Rooms (error): " .. tostring(enemy_core_ok))
    elseif not enemy_core_ok then
        info("[ENEMY_ART] Skipped during Create Rooms: " .. tostring(enemy_result))
    elseif type(enemy_result) == "table" then
        for _, issue in ipairs(enemy_result.issues or {}) do
            info("[ENEMY_ART] " .. tostring(issue.message or issue.reason or issue.filename or issue.type))
        end
        if enemy_result.changed_files and #enemy_result.changed_files > 0 then
            info("[ENEMY_ART] Registered enemy art; updated: " .. table.concat(enemy_result.changed_files, ", "))
        end
    end

    local ok, err = pcall(generate, selected_ids, opts.world_manifest, opts)
    if not ok then
        info("Generation failed: " .. tostring(err))
        error(err, 0)
    end

    local manifest_call_ok, manifest_ok, manifest_result = pcall(function()
        local AtlasManifest = require "hooks.core.atlas_manifest"
        return AtlasManifest.sync_core({
            root = ROOT,
            join = join,
            to_os_path = to_os_path,
            list_dir_filesystem = list_dir_filesystem,
            read_text = read_text,
            write_if_changed = write_if_changed,
        })
    end)
    if not manifest_call_ok then
        error("Atlas animation manifest generation failed: " .. tostring(manifest_ok), 0)
    elseif not manifest_ok then
        error("Atlas animation manifest generation failed: " .. tostring(manifest_result), 0)
    elseif type(manifest_result) == "table" then
        local changed = manifest_result.changed_files or {}
        if #changed > 0 then
            info(string.format("[ATLAS_MANIFEST] Indexed %d atlas(es), %d animation(s); updated: %s",
                tonumber(manifest_result.atlas_count) or 0,
                tonumber(manifest_result.animation_count) or 0,
                table.concat(changed, ", ")))
        else
            info(string.format("[ATLAS_MANIFEST] Indexed %d atlas(es), %d animation(s); manifest already current.",
                tonumber(manifest_result.atlas_count) or 0,
                tonumber(manifest_result.animation_count) or 0))
        end
    end

    -- Copy/register room music as part of Create Rooms so a creator only ever
    -- needs ONE command after setting a map `music` file property.
    -- Non-fatal: a music-sync problem must never break room generation.
    local pok, core_ok, music_result = pcall(sync_music_core)
    if opts.strict then
        assert(pok and core_ok,"Music synchronization failed: "..tostring(music_result or core_ok))
        local music_errors=type(music_result)=="table" and music_result.map_music and music_result.map_music.errors or {}
        if #music_errors>0 then
            local messages={}; for _,problem in ipairs(music_errors) do messages[#messages+1]=tostring(problem) end
            error("Room music sources could not be synchronized: "..table.concat(messages,"; "),0)
        end
    end
    if not pok then
        info("[MUSIC_SYNC] Skipped during Create Rooms (error): " .. tostring(core_ok))
    elseif not core_ok then
        info("[MUSIC_SYNC] Skipped during Create Rooms: " .. tostring(music_result))
    elseif type(music_result) == "table" then
        local map_music = music_result.map_music or {}
        for _, err in ipairs(map_music.errors or {}) do
            info("[MUSIC_SYNC] " .. tostring(err))
        end
        if map_music.copied and #map_music.copied > 0 then
            info("[MUSIC_SYNC] Copied map music: " .. table.concat(map_music.copied, ", "))
        end
        if map_music.unchanged and #map_music.unchanged > 0 then
            info("[MUSIC_SYNC] Map music already copied: " .. table.concat(map_music.unchanged, ", "))
        end
        if music_result.changed_files and #music_result.changed_files > 0 then
            info("[MUSIC_SYNC] Registered music; updated: " .. table.concat(music_result.changed_files, ", "))
        end
    end

    -- Intentionally avoid editor_api.save() here.
    -- Saving editor buffers after generation can write stale in-memory data
    -- back over freshly generated collection/map files.
    if opts.open_perf_report ~= false then
        local context = (selected_ids and #selected_ids > 0) and "Generate Room From Tilemap" or "Create Rooms"
        show_perf_report_completion_dialog(context)
    end
    return true
end


-- Trigger room generation when the editor loads so rooms stay in sync
local function run_initial_room_generation()
    local ok, err = pcall(safe_generate)
    if not ok then
        info("Initial room generation failed: " .. tostring(err))
    end
end

-- DISABLED: Don't run at script load time - causes "Cannot use long-running editor function in immediate context" error
-- Room generation is explicit through menu commands; on_build_started validates authored relationships.
-- run_initial_room_generation()

-- Minimap generation removed - focusing on standalone build export only

-- Layout export to runtime removed - not needed for standalone build

local PERF_REPORT_RESOURCE = "/perf_report.txt"

local function read_perf_report_preview()
    local raw = read_text(PERF_REPORT_RESOURCE)
    if not raw or raw == "" then
        return nil, nil
    end

    raw = tostring(raw):gsub("\r\n", "\n")

    local total_line = nil
    local preview_lines = {}
    for line in raw:gmatch("[^\n]+") do
        if not total_line and line:find("TOTAL ", 1, true) then
            total_line = line
        end
        if line ~= "" and #preview_lines < 8 then
            preview_lines[#preview_lines + 1] = line
        end
    end

    local preview = table.concat(preview_lines, "\n")
    return total_line, preview ~= "" and preview or nil
end

local function show_editor_status_dialog(title, body_lines, opts)
    if HEADLESS then
        return false
    end

    local ui = editor_api and editor_api.ui or nil
    if not (ui and ui.dialog and ui.dialog_button and ui.paragraph and ui.vertical and ui.show_dialog) then
        info(string.format("[EDITOR_UI] Dialog API unavailable for '%s'", tostring(title or "Status")))
        return false
    end

    local buttons = {
        ui.dialog_button({
            text = tostring((opts and opts.cancel_text) or "Close"),
            cancel = true,
            default = true,
            result = tostring((opts and opts.cancel_result) or "close"),
        }),
    }

    if opts and opts.extra_buttons then
        for _, button in ipairs(opts.extra_buttons) do
            buttons[#buttons + 1] = button
        end
    end

    local children = {}
    for _, line in ipairs(body_lines or {}) do
        if line and tostring(line) ~= "" then
            children[#children + 1] = ui.paragraph({ text = tostring(line) })
        end
    end

    local ok_dialog, result_or_err = pcall(ui.show_dialog, ui.dialog({
        title = tostring(title or "Status"),
        content = ui.vertical({
            padding = 12,
            spacing = 8,
            children = children,
        }),
        buttons = buttons,
    }))
    if not ok_dialog then
        info(string.format("[EDITOR_UI] Failed to show dialog '%s': %s",
            tostring(title or "Status"), tostring(result_or_err)))
        return false
    end

    return result_or_err
end

show_perf_report_completion_dialog = function(context)
    if HEADLESS then
        return false
    end

    local resource_path = PERF_REPORT_RESOURCE
    local total_line, preview = read_perf_report_preview()
    local summary = string.format("%s finished.\n%s", tostring(context or "Operation"), total_line or "Performance report saved.")
    local detail = string.format("Saved %s in the project root.", resource_path)

    local ui = editor_api and editor_api.ui or nil
    local can_open_external = editor_api and editor_api.open_external_file and ui and ui.dialog_button
    local extra_buttons = nil
    if can_open_external then
        extra_buttons = {
            ui.dialog_button({
                text = "Open Report",
                result = "open_external",
            }),
        }
    end

    local body_lines = { summary, detail }
    if preview then
        body_lines[#body_lines + 1] = preview
    end

    local result_or_err = show_editor_status_dialog(
        string.format("%s Complete", tostring(context or "Operation")),
        body_lines,
        { extra_buttons = extra_buttons }
    )
    if result_or_err == false then
        return false
    end

    if result_or_err == "open_external" and can_open_external then
        local abs_path = to_os_path((ROOT or ".") .. "/perf_report.txt")
        local ok_open, err = pcall(editor_api.open_external_file, abs_path)
        if not ok_open then
            info(string.format("[PERF] Failed to open %s externally after %s: %s",
                abs_path, tostring(context or "operation"), tostring(err)))
            return false
        end
    end

    return true
end

local function show_menu_command_failure(action_label, err, intro_line)
    show_editor_status_dialog(string.format("%s Failed", tostring(action_label or "Command")), {
        tostring(intro_line or (tostring(action_label or "Command") .. " did not complete.")),
        tostring(err),
        "See debug_output.txt in the project root for full hook output.",
    })
end

local function run_menu_command(action_label, fn, opts)
    local ok, result, extra = pcall(fn)
    if ok and result ~= false then
        return true, result, extra
    end

    local err = ok and extra or result
    info(string.format("%s failed: %s", tostring(action_label or "Command"), tostring(err)))
    if not (opts and opts.suppress_dialog) then
        show_menu_command_failure(action_label, err, opts and opts.intro_line)
    end
    return false, err
end

local function confirm_editor_action(title, body_lines, action_text, result_value)
    if HEADLESS then
        info("[EDITOR_UI] Refusing confirmation-only command while headless: " .. tostring(title))
        return false
    end

    local ui = editor_api and editor_api.ui or nil
    if not (ui and ui.dialog_button) then
        info("[EDITOR_UI] Dialog button API unavailable for confirmation: " .. tostring(title))
        return false
    end

    local wanted = tostring(result_value or "confirm")
    local result = show_editor_status_dialog(title, body_lines, {
        cancel_text = "Cancel",
        cancel_result = "cancel",
        extra_buttons = {
            ui.dialog_button({
                text = tostring(action_text or "Confirm"),
                result = wanted,
            }),
        },
    })
    return result == wanted
end

local function run_delete_my_rooms()
    if not confirm_editor_action("Delete My Rooms?", {
        "This removes your exported room .lua/.tilemap files and generated room outputs.",
        "Bundled tilesets, tilesheets, and atlases are kept.",
        "Removed files are moved to developer/.trash for recovery.",
    }, "Delete My Rooms", "delete_my_rooms") then
        info("Delete My Rooms: cancelled.")
        return true
    end

    local total, trash_path, summary = delete_my_room_files()
    local failures = summary and #(summary.failed or {}) or 0
    if failures > 0 then
        return false, string.format(
            "%d room cleanup target(s) could not be removed; see debug_output.txt and the trash backup at %s.",
            failures,
            tostring(trash_path or "developer/.trash")
        )
    end
    info("Delete My Rooms: complete. Cleanup items moved: " .. tostring(total)
        .. " | Trash: " .. tostring(trash_path))
    local moved_text = summary
        and string.format("Moved %d file(s) and %d directory tree(s) to trash.",
            tonumber(summary.moved_files) or 0,
            tonumber(summary.moved_directories) or 0)
        or ("Moved " .. tostring(total or 0) .. " cleanup item(s) to trash.")
    show_editor_status_dialog("Delete My Rooms Complete", {
        moved_text,
        tostring(trash_path or "developer/.trash"),
        "Bundled tilesets and tilesheets were kept.",
    })
    return true
end

local function run_reset_project_to_empty()
    if not confirm_editor_action("Reset Project to Empty?", {
        "This is the destructive reset.",
        "It removes exported Tiled copies, generated rooms, imported tiles/backgrounds, synced music, biome atlases, layouts/minimap data, and standalone export output.",
        "Tiled originals must be verified outside this project. Missing originals or edited project copies block reset before any files move.",
        "It also clears saved play state, Project > Game Settings... overrides, gameplay settings, and input bindings on the next launch.",
        "Framework files are restored to a buildable empty-project baseline.",
        "Removed files are moved to developer/.trash for recovery.",
    }, "Reset Project", "reset_project") then
        info("Reset Project to Empty: cancelled.")
        return true
    end

    local total, trash_path, summary = reset_project_to_empty()
    local failures = summary and #(summary.failed or {}) or 0
    if failures > 0 then
        return false, string.format(
            "%d reset target(s) could not be removed. No slow per-file retry was attempted; see debug_output.txt and the trash backup at %s.",
            failures,
            tostring(trash_path or "developer/.trash")
        )
    end

    info("Reset Project to Empty: complete. Cleanup items moved: " .. tostring(total)
        .. " | Trash: " .. tostring(trash_path))
    local moved_text = summary
        and string.format("Moved %d file(s) and %d directory tree(s) to trash.",
            tonumber(summary.moved_files) or 0,
            tonumber(summary.moved_directories) or 0)
        or ("Moved " .. tostring(total or 0) .. " cleanup item(s) to trash.")
    show_editor_status_dialog("Reset Project Complete", {
        moved_text,
        string.format("Restored %d build-safe baseline file(s).",
            tonumber(summary and summary.baseline_writes) or 0),
        tostring(trash_path or "developer/.trash"),
        "Export fresh rooms from Tiled, then run Prepare & Check.",
    })
    return true
end

local ExportPackager = require("mvtk.editor.export_packager")
ExportPackager.configure({
    root = ROOT,
    dir_sep = DIR_SEP,
    logger = function(msg) info(msg) end,
    profiler = profiler,
    editor_api = editor_api,
    to_os_path = to_os_path,
    join = join,
    ensure_dir = ensure_dir,
    remove_path_filesystem = remove_path_filesystem,
    safe_generate = safe_generate,
    read_text = read_text,
    write_if_changed = write_if_changed,
    copy_file_basic = copy_file_basic,
    file_exists_any = file_exists_any,
    list_dir_filesystem = list_dir_filesystem,
    copy_directory_filesystem = copy_directory_filesystem,
    run_process = _C.run_process,
})

local profile_step = ExportPackager.profile_step
local profile_isolated_step = ExportPackager.profile_isolated_step
local export_game_assets = ExportPackager.export_game_assets

local M = {}
local export_activity={open=false,running=false}

local function current_tile_size_defaults()
    -- Import Assets re-derives tile_settings.lua from the art (hooks/core/
    -- tilesource.lua). The module-level TileSettings is whatever was cached
    -- when the editor first loaded it, so resizing templates from it stamps a
    -- stale tile size after a world switch and invalidates the Tiled export.
    package.loaded["developer.config.tile_settings"] = nil
    local tile = require "developer.config.tile_settings"
    local width = tonumber(tile.width or tile.tile_width)
    local height = tonumber(tile.height or tile.tile_height)
    if not width or width <= 0 then
        error("developer.config.tile_settings.width must be a positive number", 0)
    end
    if not height or height <= 0 then
        error("developer.config.tile_settings.height must be a positive number", 0)
    end
    return math.floor(width + 0.5), math.floor(height + 0.5)
end

local function sync_template_object_size(template_path, width, height)
    local text = read_text(template_path)
    if not text or text == "" then
        info("[TEMPLATES] Missing template: " .. tostring(template_path))
        return false
    end

    local width_text = tostring(math.floor(tonumber(width) or 0))
    local height_text = tostring(math.floor(tonumber(height) or 0))
    local width_replaced = false
    local height_replaced = false

    local updated = text:gsub('(<object[^>]-width=")([^"]+)(")', function(prefix, _, suffix)
        width_replaced = true
        return prefix .. width_text .. suffix
    end, 1)
    updated = updated:gsub('(<object[^>]-height=")([^"]+)(")', function(prefix, _, suffix)
        height_replaced = true
        return prefix .. height_text .. suffix
    end, 1)

    if not width_replaced or not height_replaced then
        info("[TEMPLATES] Failed to update object size for " .. tostring(template_path))
        return false
    end

    return write_if_changed(template_path, updated)
end

sync_tiled_template_defaults = function()
    local tile_w, tile_h = current_tile_size_defaults()
    local template_paths = {
        join(ROOT, "tiled/templates/interaction/breakable_wall.tx"),
    }

    local changed = false
    for _, template_path in ipairs(template_paths) do
        if sync_template_object_size(template_path, tile_w, tile_h) then
            info(string.format("[TEMPLATES] Synced %s to %dx%d",
                tostring(template_path), tile_w, tile_h))
            changed = true
        end
    end
    return changed
end

-- Import image layers and background visual tile objects from a Tiled Lua export
-- into the room biome atlas.
local function import_tiled_images(map_path, biome)
    local room_id = path_basename(map_path):gsub("%.lua$", "")
    local map, load_err = load_tiled_export(room_id)
    if type(map) ~= "table" then
        info("[IMPORT] Failed to load map " .. map_path .. ": " .. tostring(load_err))
        return
    end

    if biome and biome ~= "" then
        map.properties = map.properties or {}
        if not map.properties.biome or map.properties.biome == "" then
            map.properties.biome = biome
        end
    end

    local map_width = (tonumber(map.width) or 0) * (tonumber(map.tilewidth) or 0)
    local map_height = (tonumber(map.height) or 0) * (tonumber(map.tileheight) or 0)
    local components = collect_room_background_sprite_components(map, map_width, map_height, room_id, map_path)
    if #components == 0 then
        info("[IMPORT] No image/background visual assets found in " .. map_path)
        return
    end

    local atlas_path = components[1] and components[1].atlas_path or get_room_background_atlas_paths(map, room_id)
    local unique_animations = {}
    for _, comp in ipairs(components) do
        if comp.animation_name and comp.animation_name ~= "" then
            unique_animations[comp.animation_name] = true
        end
    end

    local animation_count = 0
    for _ in pairs(unique_animations) do
        animation_count = animation_count + 1
    end

    local effective_biome = get_tiled_property(map.properties, "biome") or biome or "n/a"
    info(string.format(
        "[IMPORT] Map: %s | Biome: %s | Atlas: %s | Sprites: %d | Animations: %d",
        map_path, tostring(effective_biome), tostring(atlas_path), #components, animation_count
    ))
end

-- Import assets: relink tilemaps, import background images/visuals into biome atlases, then scan assets.
-- Consolidated end-of-build report. Replaces the scattered per-object scenery
-- warnings and silent validation with ONE place a creator looks after a build:
-- always logged to the console, and shown as a single dialog only when there is
-- something to act on (a clean build stays quiet). Never throws.
local function report_build_results(room_ids, opts)
    info("[BUILD] === Build report ===")
    info(string.format("[BUILD] Rooms processed: %d", #(room_ids or {})))

    local dialog_lines = { string.format("Rooms processed: %d", #(room_ids or {})) }
    local show_dialog = false

    -- 1. Scenery picture-objects that produced no sprite, aggregated into one
    --    line instead of one log entry per object.
    if take_background_import_warnings then
        local ok_bw, bw = pcall(take_background_import_warnings)
        if ok_bw and type(bw) == "table" and (bw.skipped or 0) > 0 then
            show_dialog = true
            local where = (#(bw.rooms or {}) > 0)
                and (" (rooms: " .. table.concat(bw.rooms, ", ") .. ")") or ""
            local msg = string.format(
                "%d scenery object(s) did not render%s. Usually the tileset has no tilesource yet: "
                .. "re-run Prepare & Check, and confirm the tileset's image exported to "
                .. "developer/assets/tilesheets/.",
                bw.skipped, where)
            info("[BUILD] " .. msg)
            dialog_lines[#dialog_lines + 1] = msg
        end
    end

    -- 2. Schema-validate the creator's Tiled exports (reuses the CLI validator).
    --    Only the per-map errors/warnings are surfaced; the validator's
    --    toolkit-internal spawner-service check is left to "Validate All".
    local ok_mod, Validator = pcall(require, "tools.validate_tiled_export")
    if ok_mod and Validator and Validator.validate_dir then
        -- Import Assets reports before Create Rooms syncs newly linked enemy
        -- art, so unsynced linked skins wait for Validate All.
        local pok, _, summary = pcall(Validator.validate_dir, PATH.tilemaps, { quick = true, enemy_art_pending = true })
        if pok and type(summary) == "table" and not summary.empty then
            local map_errors, map_warnings = 0, 0
            for _, rep in ipairs(summary.files or {}) do
                map_errors = map_errors + #(rep.errors or {})
                map_warnings = map_warnings + #(rep.warnings or {})
                for _, e in ipairs(rep.errors or {}) do
                    info(string.format("[BUILD]   ERROR %s: %s", tostring(rep.name), tostring(e)))
                end
                for _, w in ipairs(rep.warnings or {}) do
                    info(string.format("[BUILD]   WARN  %s: %s", tostring(rep.name), tostring(w)))
                end
            end
            if map_errors > 0 then
                show_dialog = true
                local msg = string.format(
                    "Room validation: %d error(s), %d warning(s). See the console for specifics.",
                    map_errors, map_warnings)
                info("[BUILD] " .. msg)
                dialog_lines[#dialog_lines + 1] = msg
            elseif map_warnings > 0 then
                info(string.format("[BUILD] Room validation: %d warning(s) (see console).", map_warnings))
            else
                info("[BUILD] Room validation: all maps OK")
            end
        end
    end

    -- 3. If collections already exist, enforce the Tiled object <-> baked
    --    instance contract and compare sibling TMX template identities. A
    --    first-time project may not have run Prepare & Check yet, so missing
    --    collection files are ignored here; Create Rooms requires them above.
    local bake_audit = audit_baked_rooms(room_ids, { require_collections = false })
    if bake_audit.errors > 0 then
        show_dialog = true
        local msg = string.format(
            "Baked object audit: %d error(s), %d warning(s). Run Prepare & Check and see the console for object ids.",
            bake_audit.errors, bake_audit.warnings
        )
        dialog_lines[#dialog_lines + 1] = msg
    end

    info("[BUILD] === end report ===")
    if show_dialog and not (opts and opts.suppress_dialog) then
        dialog_lines[#dialog_lines + 1] = ""
        dialog_lines[#dialog_lines + 1] = "Full details are in the Defold Console panel below."
        pcall(show_editor_status_dialog, "Import Assets — report", dialog_lines, { cancel_text = "Close" })
    end
end

local function import_assets(opts)
    opts = opts or {}
    if not opts.exports_checked then
    require("developer.tools.preparation").require_exports({root=ROOT,list_dir_filesystem=list_dir_filesystem,world_manifest=opts.world_manifest})
    end
    if not opts.profile_session then profiler.reset() end
    profiler.start("TOTAL import_assets()")
    _C.clear_ensure_dir_cache()
    info("[IMPORT] === Import Assets ===")
    pcall(sync_tiled_template_defaults)
    -- Relink tilemaps using the same tileset pipeline as room generation.
    -- This includes auto-import of missing biome tilesheets/tilesources.
    local room_ids = list_room_ids_checked("import_assets",opts.world_manifest)
    -- Clear tilesource metadata cache so updated images are re-measured
    for k in pairs(_visual.TILESOURCE_METADATA_CACHE) do _visual.TILESOURCE_METADATA_CACHE[k] = nil end
    if #room_ids > 0 then
        warn_missing_room_collision(room_ids)
        -- Regenerate .tilemap files from Tiled .lua exports so the .lua is the
        -- single source of truth (users no longer need to export .tilemap separately).
        profiler.start("regenerate_all_tilemaps_from_lua")
        local regenerated, regeneration_error=pcall(regenerate_all_tilemaps_from_lua, room_ids)
        if opts.strict then assert(regenerated,"Tilemap import failed: "..tostring(regeneration_error)) end
        profiler.stop("regenerate_all_tilemaps_from_lua")
        -- Sync tilesheet images from Tiled sources before relinking
        profiler.start("sync_tilesheet_images")
        local synced, sync_error=pcall(sync_tilesheet_images, room_ids)
        if opts.strict then assert(synced,"Tilesheet synchronization failed: "..tostring(sync_error)) end
        profiler.stop("sync_tilesheet_images")
        profiler.start("update_all_tilemap_tilesources")
        local ok_relink, relink_err = pcall(update_all_tilemap_tilesources, room_ids)
        profiler.stop("update_all_tilemap_tilesources")
        if not ok_relink then
            error("[IMPORT] Tilemap relink via editor pipeline failed: " .. tostring(relink_err), 0)
        end
        require("hooks.core.tilesource").cleanup_collection_tilesources(room_ids)
        profiler.start("standardize_tilesource_collision")
        standardize_tilesource_collision_setup()
        profiler.stop("standardize_tilesource_collision")
    else
        if not has_tiled_room_exports() then
            info("[IMPORT] No Tiled room exports found in " .. PATH.tilemaps)
            info("[IMPORT] If you just ran Delete My Rooms, export fresh .lua/.tilemap room files from Tiled here before running Import Assets.")
            profiler.stop("TOTAL import_assets()")
            if not opts.profile_session then profiler.report() end
            return false
        end
        error("[IMPORT] Tiled exports exist in " .. PATH.tilemaps .. " but no room ids were discovered.", 0)
    end

    -- Import image layers and background visual tile objects for all Tiled Lua exports
    profiler.start("import_tiled_images (all maps)")
    do
        local dir = PATH.tilemaps
        local imported_any = false
        if lfs_ok and lfs then
            local attr = lfs.attributes(dir, "mode")
            if attr == "directory" then
                for file in lfs.dir(dir) do
                    if file:match("%.lua$") then
                        profiler.start("  import_tiled_images [" .. file .. "]")
                        import_tiled_images(dir .. "/" .. file)
                        profiler.stop("  import_tiled_images [" .. file .. "]")
                        imported_any = true
                    end
                end
            end
        else
            local _, files = list_dir_filesystem(dir)
            if files then
                for _, file in ipairs(files) do
                    if file:match("%.lua$") then
                        profiler.start("  import_tiled_images [" .. file .. "]")
                        import_tiled_images(dir .. "/" .. file)
                        profiler.stop("  import_tiled_images [" .. file .. "]")
                        imported_any = true
                    end
                end
            end
        end
        if not imported_any then
            info("[IMPORT] No Tiled Lua maps found to import background assets")
        end
    end
    profiler.stop("import_tiled_images (all maps)")

    -- Update tilemap animation config from Tiled tileset animations
    if #room_ids > 0 then
        profiler.start("update_generated_tilemap_animation_config")
        update_generated_tilemap_animation_config(room_ids)
        profiler.stop("update_generated_tilemap_animation_config")
    end

    -- Asset scan
    profiler.start("asset_scanner.lua")
    local Scanner = require "mvtk.editor.asset_scanner"
    local scan_report = Scanner.scan({root=ROOT, list=list_dir_filesystem,
        read=read_text, exists=file_exists})
    info(Scanner.format(scan_report))
    profiler.stop("asset_scanner.lua")
    if opts.strict then assert(scan_report.ok, "Asset scan failed: " .. Scanner.format(scan_report, 3)
        .. "\nSee debug_output.txt for the full asset scan.") end

    -- One consolidated build report (scenery + schema validation). Non-fatal.
    pcall(report_build_results, room_ids, opts)

    profiler.stop("TOTAL import_assets()")
    if not opts.profile_session then profiler.report() end
    if not opts.suppress_dialog then
        show_perf_report_completion_dialog("Import Assets")
    end
    info("[IMPORT] Asset import complete; preparation continues with room generation.")
    return true
end

local MUSIC_DIR = "developer/assets/music"
local AUDIO_CONTROLLER_GO = "developer/game/audio/audio_controller.go"
local AUDIO_CONTROLLER_SCRIPT = "mvtk/audio/audio_controller.script"
local MUSIC_TRACKS_MANIFEST = "developer/config/music_tracks_generated.lua"
local TILED_ENUM_FILES = {
    { path = "MVTK.tiled-project" },
    { path = "tiled/custom_types/MV_ToolKit.custom-types.json" },
    { path = "tiled/custom_types/MV_ToolKit.custom-types.array.json" },
}
local MUSIC_ENUM_FILES = TILED_ENUM_FILES
local MUSIC_ENUM_NAMES = {
    "music_tracks",
    "boss_music_tracks",
}

local function music_sync_ext(filename)
    local ext = tostring(filename or ""):match("%.([^%.]+)$")
    return ext and ext:lower() or ""
end

local function sorted_copy(list)
    local out = {}
    for _, value in ipairs(list or {}) do
        out[#out + 1] = value
    end
    table.sort(out, function(a, b)
        local aa = tostring(a):lower()
        local bb = tostring(b):lower()
        if aa ~= bb then return aa < bb end
        return tostring(a) < tostring(b)
    end)
    return out
end

local function format_name_list(list, empty_label)
    if not list or #list == 0 then
        return empty_label or "none"
    end
    local limit = 8
    local shown = {}
    for i = 1, math.min(#list, limit) do
        shown[#shown + 1] = tostring(list[i])
    end
    if #list > limit then
        shown[#shown + 1] = string.format("and %d more", #list - limit)
    end
    return table.concat(shown, ", ")
end

local function set_from_list(list)
    local set = {}
    for _, value in ipairs(list or {}) do
        set[tostring(value)] = true
    end
    return set
end

local function compare_track_lists(old_ids, new_ids)
    local old_set = set_from_list(old_ids)
    local new_set = set_from_list(new_ids)
    local added = {}
    local removed = {}
    local unchanged = {}

    for _, id in ipairs(new_ids or {}) do
        if old_set[id] then
            unchanged[#unchanged + 1] = id
        else
            added[#added + 1] = id
        end
    end
    for _, id in ipairs(old_ids or {}) do
        if not new_set[id] then
            removed[#removed + 1] = id
        end
    end

    table.sort(added)
    table.sort(removed)
    table.sort(unchanged)
    return added, removed, unchanged
end

local function show_music_sync_summary(lines)
    for _, line in ipairs(lines or {}) do
        info("[MUSIC_SYNC] " .. tostring(line))
    end
    show_editor_status_dialog("Sync Music Complete", lines, { cancel_text = "Close" })
end

local function music_sync_project_path(path)
    if not path or path == "" then
        return path
    end
    if path:match("^[A-Za-z]:") or path:sub(1, 1) == "/" then
        return path
    end
    return join(ROOT or ".", path)
end

local function read_required_text(path)
    local text = read_text(music_sync_project_path(path))
    if text == nil then
        return nil, "Could not read " .. tostring(path)
    end
    return text
end

local function collect_music_files()
    local music_dir_abs = join(ROOT or ".", MUSIC_DIR)
    local _, files = list_dir_filesystem(music_dir_abs)
    files = sorted_copy(files or {})

    local audio_files = {}
    local unsupported = {}
    for _, file in ipairs(files) do
        local ext = music_sync_ext(file)
        if MusicSync.SUPPORTED_MUSIC_EXTENSIONS[ext] then
            audio_files[#audio_files + 1] = file
        else
            unsupported[#unsupported + 1] = file
        end
    end
    return files, audio_files, unsupported
end

local function append_music_sync_issue_lines(lines, unsupported, issues, dangling, map_music, skipped_enum_files)
    map_music = map_music or {}
    if map_music.copied and #map_music.copied > 0 then
        lines[#lines + 1] = "Copied from maps: " .. format_name_list(map_music.copied)
    end
    if map_music.unchanged and #map_music.unchanged > 0 then
        lines[#lines + 1] = "Map music already copied: " .. format_name_list(map_music.unchanged)
    end
    if map_music.skipped_legacy and #map_music.skipped_legacy > 0 then
        lines[#lines + 1] = "Skipped legacy room music values: " .. format_name_list(map_music.skipped_legacy)
    end
    if map_music.errors and #map_music.errors > 0 then
        for _, err in ipairs(map_music.errors) do
            lines[#lines + 1] = tostring(err)
        end
    end

    if skipped_enum_files and #skipped_enum_files > 0 then
        lines[#lines + 1] = "Skipped dev-only enum file (not in this install): "
            .. format_name_list(skipped_enum_files)
    end

    if unsupported and #unsupported > 0 then
        lines[#lines + 1] = "Skipped unsupported files: " .. format_name_list(unsupported)
        lines[#lines + 1] = "Defold loads WAV and Ogg Vorbis only."
    end

    issues = issues or {}
    for _, invalid in ipairs(issues.invalid or {}) do
        lines[#lines + 1] = string.format("Skipped %s: %s.",
            tostring(invalid.filename), tostring(invalid.reason or "invalid track id"))
    end
    for _, collision in ipairs(issues.collisions or {}) do
        lines[#lines + 1] = string.format("Skipped filename collision for '%s': %s.",
            tostring(collision.track_id), format_name_list(collision.filenames))
    end

    if dangling and #dangling > 0 then
        local shown = {}
        for _, warning in ipairs(dangling) do
            shown[#shown + 1] = string.format("%s -> %s", tostring(warning.theme), tostring(warning.track_id))
        end
        lines[#lines + 1] = "Dangling _music_map themes: " .. format_name_list(shown)
        lines[#lines + 1] = "Repoint those theme values in mvtk/audio/audio_controller.script."
    end
end

local MAP_MUSIC_PROPERTY_NAMES = { "music", "Music", "ambience", "Ambience" }

local function basename_from_path(path)
    path = tostring(path or ""):gsub("\\", "/")
    return path:match("([^/]+)$") or path
end

local function get_map_music_value(props)
    if type(props) ~= "table" then
        return nil
    end
    for _, name in ipairs(MAP_MUSIC_PROPERTY_NAMES) do
        if props[name] ~= nil then
            return props[name]
        end
    end
    return nil
end

local function sync_map_music_files()
    local result = {
        copied = {},
        unchanged = {},
        skipped_legacy = {},
        errors = {},
    }

    local ok_ids, room_ids_or_err = pcall(list_room_ids)
    if not ok_ids then
        result.errors[#result.errors + 1] = "Could not list Tiled rooms for map music sync: " .. tostring(room_ids_or_err)
        return result
    end

    local room_ids = sorted_copy(room_ids_or_err or {})
    local tiled_maps_path = select(1, get_tiled_paths())
    local maps_dir = join(ROOT or ".", tiled_maps_path or "developer/assets/tiled/maps")
    local source_cache = {}
    local basename_claims = {}

    local function read_source(path)
        if source_cache[path] == nil then
            local bytes = read_binary_any(path)
            local exists = bytes ~= nil
            if not exists and file_exists_any then
                local ok_exists, exists_value = pcall(file_exists_any, path)
                exists = ok_exists and exists_value == true
            end
            source_cache[path] = {
                source = path,
                bytes = bytes,
                exists = exists,
            }
        end
        return source_cache[path]
    end

    for _, room_id in ipairs(room_ids) do
        local ok_load, data = pcall(load_tiled_export, room_id)
        if ok_load and type(data) == "table" then
            local raw_value = get_map_music_value(data.properties)
            local kind, ext = MusicSync.classify_music_value(raw_value)
            if kind == "legacy" then
                result.skipped_legacy[#result.skipped_legacy + 1] =
                    string.format("%s=%s", tostring(room_id), tostring(raw_value))
            elseif kind == "file" then
                local raw = tostring(raw_value or "")
                if not MusicSync.SUPPORTED_MUSIC_EXTENSIONS[ext] then
                    result.errors[#result.errors + 1] = string.format(
                        "Room '%s': music file '%s' is .%s. Defold plays only Ogg Vorbis (.ogg) and WAV (.wav). Convert the file and update the map property.",
                        tostring(room_id), raw, tostring(ext))
                else
                    local resolved = MusicSync.resolve_map_music_path(raw, maps_dir)
                    local source = read_source(resolved)
                    if not source.exists then
                        result.errors[#result.errors + 1] = string.format(
                            "Room '%s': music file not found. Raw value '%s' resolved to '%s'.",
                            tostring(room_id), raw, tostring(resolved))
                    else
                        local base = basename_from_path(resolved)
                        local claim_key = base:lower()
                        local claim = basename_claims[claim_key]
                        local conflict, conflict_reason = MusicSync.map_music_sources_conflict(claim, source)
                        if conflict then
                            local reason = (conflict_reason == "unverified")
                                and "because at least one source could not be read directly, so the contents could not be compared. Rename one file to give each track a unique filename."
                                or "because both copy to the same destination but have different contents."
                            result.errors[#result.errors + 1] = string.format(
                                "Room '%s': music file '%s' conflicts with '%s' at developer/assets/music/%s %s",
                                tostring(room_id), tostring(resolved), tostring(claim.source), tostring(base), reason)
                        elseif not claim then
                            local dest = music_sync_project_path(MUSIC_DIR .. "/" .. base)
                            local copied_ok, copied = MusicSync.copy_map_music_source({
                                source = resolved,
                                dest = dest,
                                bytes = source.bytes,
                                exists = source.exists,
                                read_binary = read_binary_any,
                                file_exists = file_exists_any,
                                write_binary = write_binary_if_changed,
                                copy_file = copy_file_any,
                            })
                            if not copied_ok then
                                result.errors[#result.errors + 1] = string.format(
                                    "Room '%s': music file exists but could not be copied. Raw value '%s' resolved to '%s' (status: %s).",
                                    tostring(room_id), raw, tostring(resolved), tostring(copied and copied.status or "unknown"))
                            else
                                basename_claims[claim_key] = {
                                    source = resolved,
                                    bytes = copied.bytes,
                                }
                            end
                            if copied_ok and copied.status == "copied" then
                                result.copied[#result.copied + 1] = base
                            elseif copied_ok then
                                result.unchanged[#result.unchanged + 1] = base
                            end
                        end
                    end
                end
            end
        elseif not ok_load then
            result.errors[#result.errors + 1] =
                string.format("Room '%s': could not load Tiled export for map music sync: %s", tostring(room_id), tostring(data))
        end
    end

    table.sort(result.copied)
    table.sort(result.unchanged)
    table.sort(result.skipped_legacy)
    table.sort(result.errors)
    return result
end

-- Core music-registration pass with no dialog/UI. Reads developer/assets/
-- music/*, rewrites the audio controller (.go + .script) and the Tiled
-- music_tracks/boss_music_tracks enums, and writes only changed files. Returns
-- (true, summary)
-- on success or (false, err) on a hard failure. `summary` fields:
--   empty        -> true when there was nothing to register (see .reason)
--   reason       -> "no_files" | "no_tracks"
--   tracks, unsupported, issues, added, removed, unchanged, dangling
--   changed_files
--   skipped_enum_files
-- Shared by the manual "Sync Music" command and the automatic pass folded
-- into Create Rooms (safe_generate).
sync_music_core = function()
    local map_music = sync_map_music_files()
    local all_files, audio_files, unsupported = collect_music_files()
    if #all_files == 0 then
        return true, {
            empty = true,
            reason = "no_files",
            unsupported = {},
            issues = {},
            map_music = map_music,
            skipped_enum_files = {},
        }
    end

    local tracks, issues = MusicSync.prepare_tracks(audio_files)
    if #tracks == 0 then
        return true, {
            empty = true,
            reason = "no_tracks",
            unsupported = unsupported,
            issues = issues,
            map_music = map_music,
            skipped_enum_files = {},
        }
    end

    local go_text, go_err = read_required_text(AUDIO_CONTROLLER_GO)
    if not go_text then return false, go_err end
    local script_text, script_err = read_required_text(AUDIO_CONTROLLER_SCRIPT)
    if not script_text then return false, script_err end

    local enum_texts = {}
    local skipped_enum_files = {}
    for _, entry in ipairs(MUSIC_ENUM_FILES) do
        local path = entry.path
        local text, err = read_required_text(path)
        if not text then
            if entry.optional then
                skipped_enum_files[#skipped_enum_files + 1] = path
                info("[MUSIC_SYNC] Skipping optional enum file (not present): " .. tostring(path))
            else
                return false, err
            end
        else
            enum_texts[path] = text
        end
    end

    local old_ids = MusicSync.parse_music_table_ids(script_text)
    local new_ids = MusicSync.sorted_track_ids(tracks)
    local added, removed, unchanged = compare_track_lists(old_ids, new_ids)
    local dangling = MusicSync.detect_dangling_music_map(script_text, tracks)

    local new_go_text, go_stats_or_err = MusicSync.rewrite_audio_go(go_text, tracks)
    if not new_go_text then
        return false, go_stats_or_err
    end
    local new_script_text, music_err = MusicSync.rewrite_music_table(script_text, tracks)
    if not new_script_text then
        return false, music_err
    end

    local writes = {
        { path = AUDIO_CONTROLLER_GO, text = new_go_text },
        { path = AUDIO_CONTROLLER_SCRIPT, text = new_script_text },
        { path = MUSIC_TRACKS_MANIFEST, text = MusicSync.generate_music_tracks_manifest(tracks) },
    }
    for _, entry in ipairs(MUSIC_ENUM_FILES) do
        local path = entry.path
        if enum_texts[path] ~= nil then
            local new_enum_text = enum_texts[path]
            for _, enum_name in ipairs(MUSIC_ENUM_NAMES) do
                local rewritten, enum_err = MusicSync.rewrite_music_tracks_enum(
                    new_enum_text, tracks, enum_name
                )
                if not rewritten then
                    return false, enum_err .. " in " .. path
                end
                new_enum_text = rewritten
            end
            writes[#writes + 1] = { path = path, text = new_enum_text }
        end
    end

    local changed_files = {}
    for _, write in ipairs(writes) do
        if write_if_changed(music_sync_project_path(write.path), write.text) then
            changed_files[#changed_files + 1] = write.path
        end
    end

    return true, {
        tracks = tracks,
        unsupported = unsupported,
        issues = issues,
        added = added,
        removed = removed,
        unchanged = unchanged,
        dangling = dangling,
        changed_files = changed_files,
        map_music = map_music,
        skipped_enum_files = skipped_enum_files,
    }
end

local function enemy_art_sync_deps()
    return {
        root = ROOT,
        join = join,
        info = info,
        list_dir_filesystem = list_dir_filesystem,
        read_binary_any = read_binary_any,
        read_text = read_text,
        write_if_changed = write_if_changed,
        show_dialog = show_editor_status_dialog,
    }
end

local function load_enemy_art_sync()
    local ok, mod = pcall(require, "hooks.enemy_art_sync")
    if not ok or type(mod) ~= "table" then
        return nil, "Could not load hooks.enemy_art_sync: " .. tostring(mod)
    end
    return mod
end

sync_enemy_art_core = function()
    local mod, err = load_enemy_art_sync()
    if not mod then
        return false, err
    end
    return mod.sync_core(enemy_art_sync_deps())
end

local function run_sync_enemy_art()
    local mod, err = load_enemy_art_sync()
    if not mod then
        return false, err
    end
    return mod.run(enemy_art_sync_deps())
end

local function run_sync_music()
    info("[MUSIC_SYNC] Starting music sync...")

    local ok, result = sync_music_core()
    if not ok then
        return false, result
    end

    if result.empty then
        if result.reason == "no_files" then
            local lines = {
                "No files were found in " .. MUSIC_DIR .. ".",
                "No generated files were changed.",
            }
            append_music_sync_issue_lines(lines, nil, nil, nil, result.map_music, result.skipped_enum_files)
            show_music_sync_summary(lines)
        else
            local lines = {
                "No supported, non-conflicting music tracks were found.",
                "No generated files were changed.",
            }
            append_music_sync_issue_lines(lines, result.unsupported, result.issues, nil, result.map_music, result.skipped_enum_files)
            show_music_sync_summary(lines)
        end
        return true
    end

    local lines = {
        string.format("Tracks synced: %d (%d added, %d removed, %d unchanged).",
            #result.tracks, #result.added, #result.removed, #result.unchanged),
        "Added: " .. format_name_list(result.added),
        "Removed: " .. format_name_list(result.removed),
        "Unchanged: " .. format_name_list(result.unchanged),
        (#result.changed_files > 0)
            and ("Changed files: " .. format_name_list(result.changed_files))
            or "No generated files changed.",
    }
    append_music_sync_issue_lines(lines, result.unsupported, result.issues, result.dangling, result.map_music,
        result.skipped_enum_files)

    show_music_sync_summary(lines)
    return true
end

M.preparation_commands=require("hooks.preparation_commands").new({root=ROOT,headless=HEADLESS,editor=editor_api,
    profiler=profiler, list=list_dir_filesystem,info=info,join=join,write=write_if_changed,dialog=show_editor_status_dialog,
    import=import_assets,generate=safe_generate,validate=run_validate_all,
    apply_settings=function()
        local written,err=require("mvtk.editor.creator_settings_writer").prepare({
            base=(ROOT or ".").."/developer",
        })
        assert(written,err and err.message)
        return true
    end})
M.on_target_launched=M.preparation_commands.on_target_launched
M.on_target_terminated=M.preparation_commands.on_target_terminated
M.on_build_finished=M.preparation_commands.on_build_finished
function M.on_build_started(_)
    M.preparation_commands.on_build_started()
    -- Manual-only editor workflow: room generation is triggered from the
    -- Project/Assets menu commands, not automatically on every build.
    -- Read-only validation prevents invalid drafts from replacing the last
    -- runnable build even when a creator skips Validate All.
    local world_opts={root=ROOT,list_dir_filesystem=list_dir_filesystem}
    local world=require("developer.tools.world_layout").manifest(world_opts)
    local map_files
    if world then
        map_files={};for _,map in ipairs(world.maps) do map_files[#map_files+1]=map.id..".lua" end
        require("developer.tools.preparation").require_published(world_opts)
    end
    require("developer.tools.relationship_project").require_valid({
        root=ROOT, list_dir_filesystem=list_dir_filesystem, log=info, files=map_files,
    })
end

function M.on_project_loaded(_)
    -- Mutations are explicit commands, after stopping the game and saving buffers.
end

-- The menu wrapper saves buffers and checks hooks before opening this window.
-- The run guard outlives the window if it is closed during a yielding stage.
function M.run_export_visible()
    local function blocked_message()
        if export_activity.running then return "Export Game is already running. Wait for it to finish." end
        local _,stage=M.preparation_commands.active_stage()
        if stage then
            return "Prepare & Check is still running ("..stage.."). Wait for it to finish, then export."
        end
    end
    local function run_export(progress)
        local blocked=blocked_message()
        if blocked then return false,blocked end
        export_activity.running=true
        local ok,result,err=pcall(export_game_assets,{
            force=true,context="project_menu_command",progress=progress,
        })
        export_activity.running=false
        if not ok then error(result,0) end
        return result,err
    end
    local blocked=blocked_message()
    if blocked then return false,blocked end
    if HEADLESS then return run_export() end
    if export_activity.open then return false,"Export Game is already open. Use its Export button." end
    export_activity.open=true
    local ok,result,err=pcall(function()
        -- Reading this one publication is optional context for the idle window.
        -- Validation and dependency selection only start after pressing Export.
        local readable,layout=pcall(require("developer.tools.preparation").load,
            {root=ROOT,read=read_text},"runtime/layout/world_layout.local.lua")
        local count=readable and type(layout)=="table" and type(layout.rooms)=="table" and #layout.rooms
        local rooms=count and string.format(" (%d rooms)",count) or ""
        return require("hooks.preparation_activity").show(editor_api.ui,run_export,{
            title="Export Game: Progress",start_text="Export",
            idle_message="Exports the published world"..rooms.." to export/ as a standalone Defold project.\n"
                .."Your previous export/ is replaced only after the new one is fully written and verified.",
            first_running_message="Checking the published world and game ID...",
            running_note="Export is running. Closing this window does not cancel it.",
            stopped_note="Export has stopped. You can close this window.",
            idle_note="Press Export to start.",failure_prefix="Export failed: ",
            failure_suffix="\nYour previous export/ folder was kept.",
            cancelled_text="Export cancelled.",finished_text="Export finished. Review the result above.",
            settle=function()
                local quiet={reload_resources=false,out="discard",err="discard"}
                if editor_api.platform:find("win32",1,true) then editor_api.execute("cmd","/c","exit","0",quiet)
                else editor_api.execute("true",quiet) end
            end,
        })
    end)
    export_activity.open=false
    if not ok then error(result,0) end
    return result,err
end

-- Individual stages remain callable by repository tools, never as creator
-- shortcuts that bypass the complete preparation/publication workflow.
function M.get_maintenance_commands()
    -- Defold evaluates command discovery in immediate mode. Keep this function
    -- side-effect-free: the logger also appends to debug_output.txt, and file
    -- writes are rejected in immediate mode, causing the editor to discard the
    -- entire command list and remove the Project menu entries.
    local commands = {
        {id="mvtk.prepare_check",label="Prepare & Check",locations={"Project"},run=function()
            run_menu_command("Prepare & Check",M.preparation_commands.run_visible); return {}
        end},
        {id="mvtk.publish_tiled_world",label="Publish Tiled World",locations={"Project"},run=function()
            run_menu_command("Publish Tiled World",M.preparation_commands.publish_world);return {}
        end},
        {id="mvtk.use_tiled_world",label="Use Tiled World Layout",locations={"Project"},run=function()
            run_menu_command("Use Tiled World Layout",M.preparation_commands.use_world);return {}
        end},
        {id="mvtk.preparation_status",label="Preparation Status",locations={"Project"},run=function()
            run_menu_command("Preparation Status",M.preparation_commands.status); return {}
        end},
        -- Writes only inside the project, so it needs no installer on any OS.
        {id="mvtk.setup_toolkit",label="Set Up This Toolkit",locations={"Project"},run=function()
            run_menu_command("Set Up This Toolkit",function()
                return require("hooks.toolkit_setup").run({editor=editor_api,headless=HEADLESS,root=ROOT,
                    read=read_text,write=write_if_changed,info=info,dialog=show_editor_status_dialog})
            end); return {}
        end},
        -- Native settings window; Save uses the shared settings transaction.
        {id="mvtk.game_settings",label="Game Settings…",locations={"Project"},run=function()
            run_menu_command("Game Settings",function()
                return require("mvtk.editor.game_settings_window").run({editor=editor_api,headless=HEADLESS,
                    root=ROOT,read=read_text,prepare=M.preparation_commands.run_visible})
            end); return {}
        end},
        {id="mvtk.spine_addon",label="Spine Add-on…",locations={"Project"},run=function()
            run_menu_command("Spine Add-on",function()
                return require("hooks.spine_addon").run({editor=editor_api,headless=HEADLESS,root=ROOT,
                    read=read_text,list=list_dir_filesystem,info=info,dialog=show_editor_status_dialog})
            end); return {}
        end},
        {
            id = "mvtk.import_assets",
            label = "Import Assets",
            locations = { "Project" },
            run = function()
                run_menu_command("Import Assets", function()
                    return import_assets()
                end, {
                    intro_line = "Asset import did not complete.",
                })
                return {}
            end,
        },
        {
            id = "mvtk.apply_player_scale",
            label = "Apply Player Scale",
            locations = { "Project" },
            run = function()
                run_menu_command("Apply Player Scale", function()
                    local written, err = require("mvtk.editor.creator_settings_writer").save({}, {
                        base = (ROOT or ".") .. "/developer", force_geometry = true,
                    })
                    assert(written, err and err.message)
                    local result = { written = written, changed = #written > 0,
                        scale = PlayerScaleWriter.read_player_scale((ROOT or ".") .. "/developer/config/player_settings.lua") }
                    local summary = string.format("Apply Player Scale: scale=%.2f, %d files written",
                        result.scale, #result.written)
                    info(summary)
                    show_editor_status_dialog("Apply Player Scale Complete", {
                        summary,
                        "Run a normal Build to use the rebaked player resources.",
                    })
                    return result
                end, {
                    intro_line = "Player scale baking did not complete.",
                })
                return {}
            end,
        },
        {
            id = "mvtk.sync_music",
            label = "Sync Music",
            locations = { "Project" },
            run = function()
                run_menu_command("Sync Music", function()
                    return run_sync_music()
                end, {
                    intro_line = "Music sync did not complete.",
                })
                return {}
            end,
        },
        {
            id = "mvtk.sync_enemy_art",
            label = "Sync Enemy Art",
            locations = { "Project" },
            run = function()
                run_menu_command("Sync Enemy Art", function()
                    return run_sync_enemy_art()
                end, {
                    intro_line = "Enemy art sync did not complete.",
                })
                return {}
            end,
        },
        {
            id = "mvtk.regenerate_rooms",
            label = "Create Rooms",
            locations = { "Project" },
            run = function()
                local ok, err = run_menu_command("Create Rooms", function()
                    return safe_generate()
                end, {
                    intro_line = "Creating rooms did not complete.",
                })
                if HEADLESS and not ok then error(err, 0) end
                return {}
            end,
        },
        {
            id = "mvtk.validate_all",
            label = "Validate All",
            locations = { "Project" },
            run = function()
                local ok, _, summary = run_menu_command("Validate All", function()
                    return run_validate_all()
                end, {
                    intro_line = "Validation did not complete.",
                })
                if ok then
                    show_editor_status_dialog("Validate All Passed", {
                        "All validation steps completed successfully.",
                        summary,
                    })
                end
                return {}
            end,
        },
        {
            id = "mvtk.analyze_progression",
            label = "Analyze Progression",
            locations = { "Project" },
            run = function()
                local ok,err=run_menu_command("Analyze Progression",function()
                    local P=require "developer.tools.progression_project"
                    local opts={root=ROOT,list_dir_filesystem=list_dir_filesystem}
                    local result=P.check(opts)
                    P.publish(result,opts); info(result.message)
                    assert(result.ok,"Progression model has structural/source errors; see Console and progression_diagnostics.txt")
                    show_editor_status_dialog("Progression Analysis",{
                        result.complete and "Search complete" or "INCOMPLETE: some routes remain unknown",
                        "Campaign: " .. result.campaign,
                        "See developer/assets/tiled/progression_diagnostics.txt. Use Layout Editor > Progression for preview controls.",
                    })
                end,{intro_line="Progression analysis did not complete."})
                if HEADLESS and not ok then error(err,0) end
                return {}
            end,
        },
        {
            id = "mvtk.delete_my_rooms",
            label = "Delete My Rooms",
            locations = { "Project" },
            run = function()
                info("Delete My Rooms: starting...")
                run_menu_command("Delete My Rooms", function()
                    return run_delete_my_rooms()
                end, {
                    intro_line = "Deleting your room files did not complete.",
                })
                return {}
            end,
        },
        {
            id = "mvtk.export_game",
            label = "Export Game",
            locations = { "Project" },
            run = function()
                run_menu_command("Export Game", M.run_export_visible, {
                    intro_line = "Standalone export did not complete.",
                })
                return {}
            end,
        },
        {
            id = "mvtk.reset_project_to_empty",
            label = "Reset Project to Empty (destructive)",
            locations = { "Project" },
            run = function()
                info("Reset Project to Empty: starting...")
                run_menu_command("Reset Project to Empty", function()
                    return run_reset_project_to_empty()
                end, {
                    intro_line = "Reset Project to Empty did not complete.",
                })
                return {}
            end,
        },
        {
            id = "mvtk.generate_room_from_tilemap",
            label = "Generate Room From Tilemap",
            locations = { "Assets" },
            query = { selection = { type = "resource", cardinality = "many" } },
            active = function(opts)
                local ids = get_selected_tilemap_ids(opts)
                return #ids > 0
            end,
            run = function(opts)
                local ids = get_selected_tilemap_ids(opts)
                if #ids == 0 then
                    info("Generate Room From Tilemap: no tilemap selected")
                    return {}
                end
                info("Generate Room From Tilemap: " .. table.concat(ids, ", "))
                run_menu_command("Generate Room From Tilemap", function()
                    return safe_generate(ids)
                end, {
                    intro_line = "Room generation for the selected tilemap did not complete.",
                })
                return {}
            end,
        },
    }
    local read_only={ ["mvtk.preparation_status"]=true,["mvtk.analyze_progression"]=true,["mvtk.validate_all"]=true }
    for _,command in ipairs(commands) do if command.run and not read_only[command.id] then
        local run=command.run
        command.run=function(opts)
            if not HEADLESS then
                if next(_G.MVTK_RUNNING_TARGETS or {}) then
                    show_menu_command_failure(command.label,"Stop the running game before changing project resources."); return {}
                end
                M.preparation_commands.require_current_hooks()
                -- Flush dirty buffers BEFORE generation. Never save stale buffers
                -- after writes; execute's documented reload refreshes clean resources.
                editor_api.save()
            end
            local ok,result=pcall(run,opts)
            -- Spine refreshes before its final fetch_libraries call, which may
            -- replace editor scripts; no editor operation may follow it here.
            if not HEADLESS and command.id ~= "mvtk.spine_addon" then
                if editor_api.platform:find("win32",1,true) then editor_api.execute("cmd","/c","exit","0")
                else editor_api.execute("true") end
            end
            if not ok then error(result,0) end
            return result
        end
    end end
    return commands
end

function M.get_commands()
    local visible={
        ["mvtk.prepare_check"]=true,
        ["mvtk.preparation_status"]=true,
        ["mvtk.setup_toolkit"]=true,
        ["mvtk.game_settings"]=true,
        ["mvtk.spine_addon"]=true,
        ["mvtk.use_tiled_world"]=true,
        ["mvtk.analyze_progression"]=true,
        ["mvtk.export_game"]=true,
        ["mvtk.reset_project_to_empty"]=true,
    }
    local commands={}
    for _,command in ipairs(M.get_maintenance_commands()) do
        if visible[command.id] then commands[#commands+1]=command end
    end
    return commands
end

return M

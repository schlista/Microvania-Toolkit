-- mvtk/editor/background_atlas.lua
-- Room background image flattening, atlas import, and metadata generation.

local RenderOrder = require("mvtk.core.render_order")
local ParallaxRepeat = require("mvtk.tiled.parallax_repeat")
local VisualProperties = require("mvtk.tiled.visual_ownership")

local M = {}

local _deps = {}
local _visual = {}
local PARALLAX_BACKGROUND_MATERIAL = "/mvtk/tiled/materials/parallax_clip_background.material"
local PARALLAX_FOREGROUND_MATERIAL = "/mvtk/tiled/materials/parallax_clip_foreground.material"

local function apply_visual_constants()
    _visual.TILED_FLIP_H = 2147483648
    _visual.TILED_FLIP_V = 1073741824
    _visual.TILED_FLIP_D = 536870912
    _visual.TILED_GID_MASK = 536870911
end
apply_visual_constants()

-- Aggregated scenery-import warnings. Each picture (background_visual) object
-- that cannot be turned into a sprite increments this, instead of only emitting
-- a per-object log line that scrolls past unseen. Create Rooms drains this at
-- the end and surfaces ONE actionable summary line to the creator.
local _import_warnings = { skipped = 0, rooms = {} }

local function note_background_skip(room_id)
    _import_warnings.skipped = _import_warnings.skipped + 1
    if room_id ~= nil and room_id ~= "" then
        _import_warnings.rooms[tostring(room_id)] = true
    end
end

-- Drain (read + reset) the accumulated warnings. Returns
-- { skipped = N, rooms = { "room_a", ... } }.
function M.take_import_warnings()
    local rooms = {}
    for room_id in pairs(_import_warnings.rooms) do
        rooms[#rooms + 1] = room_id
    end
    table.sort(rooms)
    local out = { skipped = _import_warnings.skipped, rooms = rooms }
    _import_warnings = { skipped = 0, rooms = {} }
    return out
end

function M.configure(opts)
    opts = opts or {}
    for k, v in pairs(opts) do
        if k ~= "visual_helpers" then
            _deps[k] = v
        end
    end
    if opts.visual_helpers ~= nil then
        _visual = opts.visual_helpers
        apply_visual_constants()
    end
    if opts.parallax_background_material ~= nil then
        PARALLAX_BACKGROUND_MATERIAL = opts.parallax_background_material
    end
    if opts.parallax_foreground_material ~= nil then
        PARALLAX_FOREGROUND_MATERIAL = opts.parallax_foreground_material
    end
end

local function require_collab(name, value)
    assert(value, "mvtk.editor.background_atlas: missing collaborator '" .. name
        .. "'; configure{} must supply it before calling background atlas helpers")
    return value
end

local function call_dep(name, ...)
    return require_collab(name, _deps[name])(...)
end

local _C = setmetatable({}, {
    __index = function(_, key)
        return require_collab(key, _deps[key])
    end,
})

local function info(msg) return call_dep("logger", msg) end
local function path_basename(...) return call_dep("path_basename", ...) end
local function path_dirname(...) return call_dep("path_dirname", ...) end
local function sanitize_asset_name(...) return call_dep("sanitize_asset_name", ...) end
local function get_tiled_property(...) return call_dep("get_tiled_property", ...) end
local function resolve_source_file(...) return call_dep("resolve_source_file", ...) end
local function normalize(...) return call_dep("normalize", ...) end
local function join(...) return call_dep("join", ...) end
local function file_exists_any(...) return call_dep("file_exists_any", ...) end
local function ensure_dir(...) return call_dep("ensure_dir", ...) end
local function write_if_changed(...) return call_dep("write_if_changed", ...) end
local function to_project_resource_path(...) return call_dep("to_project_resource_path", ...) end
local function tiled_image_layer_to_defold_pos(...) return call_dep("tiled_image_layer_to_defold_pos", ...) end
local function is_background_visual_object_candidate(...) return call_dep("is_background_visual_object_candidate", ...) end

local DEFAULT_BACKGROUND_ATLAS = "/developer/assets/atlas/background_default.atlas"

_visual.TILED_FLIP_H = 2147483648
_visual.TILED_FLIP_V = 1073741824
_visual.TILED_FLIP_D = 536870912
_visual.TILED_GID_MASK = 536870911

-- Extract animation name from image filename (e.g., "moon.png" -> "moon")
local function get_animation_name_from_image(image_path)
    local filename = path_basename(image_path or "")
    local base = filename:gsub("%.[^%.]+$", "")
    return sanitize_asset_name(base, "image")
end

local function atlas_resource_to_abs(atlas_resource)
    if not atlas_resource or atlas_resource == "" then
        return nil
    end
    return _C.to_project_fs_path(atlas_resource)
end

local function get_room_background_atlas_paths(tiled_data, room_id)
    local biome = get_tiled_property(tiled_data and tiled_data.properties, "biome")
    if biome and tostring(biome) ~= "" then
        local biome_id = sanitize_asset_name(biome, "biome")
        local atlas_resource = "/developer/assets/atlas/" .. biome_id .. ".atlas"
        return atlas_resource, atlas_resource_to_abs(atlas_resource), biome_id
    end

    info(string.format(
        "[MVTK] map '%s' has no 'biome' map property; baking backgrounds into default atlas. Set 'biome' in Tiled.",
        tostring(room_id)
    ))
    return DEFAULT_BACKGROUND_ATLAS, atlas_resource_to_abs(DEFAULT_BACKGROUND_ATLAS), nil
end

local PNG_DIM_ANY_CACHE = {}

local function get_png_dimensions_any(image_path, base_dir)
    -- Cache key combines path + base_dir
    local cache_key = tostring(image_path or "") .. "\0" .. tostring(base_dir or "")
    if PNG_DIM_ANY_CACHE[cache_key] then
        local c = PNG_DIM_ANY_CACHE[cache_key]
        return c[1], c[2], c[3]
    end

    local resolved = resolve_source_file(image_path, base_dir)
    if not resolved then
        resolved = _C.resolve_image_path(image_path)
    end
    if not resolved then
        PNG_DIM_ANY_CACHE[cache_key] = { nil, nil, nil }
        return nil, nil, nil
    end

    local ok_open, fh = pcall(io.open, resolved, "rb")
    if not ok_open or not fh then
        -- Can't read the file (likely outside project sandbox), but we still
        -- know where it is — return resolved path so callers can copy it.
        PNG_DIM_ANY_CACHE[cache_key] = { nil, nil, resolved }
        return nil, nil, resolved
    end

    local header = fh:read(24)
    fh:close()
    if not header or #header < 24 or header:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        PNG_DIM_ANY_CACHE[cache_key] = { nil, nil, resolved }
        return nil, nil, resolved
    end

    local function read_int(str, offset)
        local b1, b2, b3, b4 = str:byte(offset, offset + 3)
        if not b4 then return nil end
        return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end

    local width = read_int(header, 17)
    local height = read_int(header, 21)
    PNG_DIM_ANY_CACHE[cache_key] = { width, height, resolved }
    return width, height, resolved
end

local function load_existing_atlas_index(atlas_abs)
    local ids = {}
    local id_to_image = {}
    local image_to_id = {}
    local current_id = nil

    local ok_open, fh = pcall(io.open, atlas_abs, "rb")
    if not ok_open or not fh then
        return ids, id_to_image, image_to_id
    end

    for line in fh:lines() do
        local id = line:match('id:%s*"([^"]+)"')
        if id then
            current_id = id
            ids[id] = true
        end
        local image = line:match('image:%s*"([^"]+)"')
        if image and current_id then
            id_to_image[current_id] = image
            image_to_id[image] = current_id
        end
    end
    fh:close()
    return ids, id_to_image, image_to_id
end

local function ensure_images_in_background_atlas(atlas_resource, atlas_abs, source_images)
    local animation_by_source = {}
    local copied_abs_by_source = {}
    if type(source_images) ~= "table" or #source_images == 0 or not atlas_abs then
        return animation_by_source, copied_abs_by_source, 0, 0
    end

    local atlas_dir = path_dirname(atlas_abs)
    if atlas_dir ~= "" then
        ensure_dir(atlas_dir)
    end
    if not file_exists_any(atlas_abs) then
        -- Extruded borders keep linear filtering from sampling a packed
        -- neighbour: scenery with transparent edges (clouds, silhouettes)
        -- otherwise shows faint lines along its image bounds.
        local starter = table.concat({
            "margin: 0",
            "extrude_borders: 2",
            "inner_padding: 0",
            "max_page_width: 0",
            "max_page_height: 0",
            "",
        }, "\n")
        write_if_changed(atlas_abs, starter)
    end

    local image_dir = atlas_abs:gsub("%.atlas$", "_images")
    ensure_dir(image_dir)

    local existing_ids, id_to_image, image_to_id = load_existing_atlas_index(atlas_abs)
    local copied = 0
    local appended = 0
    local append_blocks = {}
    local used_ids = {}
    for id, _ in pairs(existing_ids) do
        used_ids[id] = true
    end

    local function alloc_id(base)
        local id = base
        local n = 2
        while used_ids[id] do
            id = base .. "_" .. tostring(n)
            n = n + 1
        end
        used_ids[id] = true
        return id
    end

    for _, source_image in ipairs(source_images) do
        local source_abs = resolve_source_file(source_image, nil) or normalize(source_image or "")
        if source_abs ~= "" and file_exists_any(source_abs) then
            local original_name = path_basename(source_abs)
            local ext = original_name:match("(%.[^%.]+)$") or ".png"
            ext = ext:lower()
            local base_name = sanitize_asset_name(original_name:gsub("%.[^%.]+$", ""), "image")

            local dest_name = base_name .. ext
            local dest_abs = normalize(join(image_dir, dest_name))
            local suffix = 2
            while true do
                if not file_exists_any(dest_abs) then
                    if _C.copy_file_any(source_abs, dest_abs) then
                        copied = copied + 1
                    end
                    break
                end

                -- Use size + mtime comparison instead of full binary read
                if _C.source_is_newer(source_abs, dest_abs) then
                    if _C.copy_file_any(source_abs, dest_abs) then
                        copied = copied + 1
                        info(string.format("[BG_ATLAS] Updated changed image: %s", dest_name))
                    end
                end
                break
            end

            local image_resource = to_project_resource_path(dest_abs)
            if image_resource then
                local anim_id = image_to_id[image_resource]
                if not anim_id then
                    local desired_id = sanitize_asset_name(dest_name:gsub("%.[^%.]+$", ""), "image")
                    if existing_ids[desired_id] and id_to_image[desired_id] == image_resource then
                        anim_id = desired_id
                    elseif existing_ids[desired_id] and id_to_image[desired_id] ~= image_resource then
                        anim_id = alloc_id(desired_id)
                    else
                        anim_id = desired_id
                        used_ids[anim_id] = true
                    end

                    if not existing_ids[anim_id] then
                        existing_ids[anim_id] = true
                        id_to_image[anim_id] = image_resource
                        image_to_id[image_resource] = anim_id
                        append_blocks[#append_blocks + 1] = table.concat({
                            "animations {",
                            string.format('  id: "%s"', anim_id),
                            "  images {",
                            string.format('    image: "%s"', image_resource),
                            "    sprite_trim_mode: SPRITE_TRIM_MODE_OFF",
                            "  }",
                            "  playback: PLAYBACK_ONCE_FORWARD",
                            "  fps: 0",
                            "  flip_horizontal: 0",
                            "  flip_vertical: 0",
                            "}",
                            "",
                        }, "\n")
                        appended = appended + 1
                    end
                end

                if anim_id then
                    animation_by_source[source_abs] = anim_id
                    copied_abs_by_source[source_abs] = dest_abs
                end
            end
        end
    end

    if #append_blocks > 0 then
        local ok_open, fh = pcall(io.open, atlas_abs, "a")
        if ok_open and fh then
            fh:write(table.concat(append_blocks))
            fh:close()
        end
    end

    return animation_by_source, copied_abs_by_source, copied, appended
end

local function decode_tiled_gid(gid)
    local value = tonumber(gid) or 0
    local flip_h = false
    local flip_v = false
    local flip_d = false

    if value >= _visual.TILED_FLIP_H then
        flip_h = true
        value = value - _visual.TILED_FLIP_H
    end
    if value >= _visual.TILED_FLIP_V then
        flip_v = true
        value = value - _visual.TILED_FLIP_V
    end
    if value >= _visual.TILED_FLIP_D then
        flip_d = true
        value = value - _visual.TILED_FLIP_D
    end

    if value < 0 then value = 0 end
    if value > _visual.TILED_GID_MASK then value = value % (_visual.TILED_GID_MASK + 1) end
    return value, flip_h, flip_v, flip_d
end

local function build_tileset_gid_lookup(tiled_data, tiled_export_path)
    local lookup = {}
    if not tiled_data or type(tiled_data.tilesets) ~= "table" then
        return lookup
    end

    for _, tileset in ipairs(tiled_data.tilesets) do
        local firstgid = tonumber(tileset and tileset.firstgid)
        if firstgid and firstgid > 0 then
            lookup[#lookup + 1] = {
                firstgid = firstgid,
                name = tostring((tileset and tileset.name) or ""),
                meta = _C.get_tileset_meta(tileset, tiled_export_path),
            }
        end
    end

    table.sort(lookup, function(a, b)
        return (a.firstgid or 0) < (b.firstgid or 0)
    end)

    for i, entry in ipairs(lookup) do
        local next_entry = lookup[i + 1]
        entry.lastgid = next_entry and (next_entry.firstgid - 1) or _visual.TILED_GID_MASK
    end

    return lookup
end

local function find_tileset_for_gid(lookup, gid)
    local g = tonumber(gid) or 0
    for _, entry in ipairs(lookup) do
        if g >= entry.firstgid and g <= entry.lastgid then
            return entry, (g - entry.firstgid)
        end
    end
    return nil, nil
end

-- Flatten Tiled layers, including nested groups, while applying inherited transforms.
local function flatten_tiled_layers(layers, inherited, out)
    if type(layers) ~= "table" then
        return out or {}
    end

    inherited = inherited or {
        offsetx = 0,
        offsety = 0,
        parallaxx = 1.0,
        parallaxy = 1.0,
        visible = true,
        opacity = 1.0,
    }
    out = out or {}

    for _, layer in ipairs(layers) do
        if type(layer) == "table" then
            local local_visible = layer.visible ~= false
            local next_state = {
                offsetx = (inherited.offsetx or 0) + (tonumber(layer.offsetx) or 0),
                offsety = (inherited.offsety or 0) + (tonumber(layer.offsety) or 0),
                parallaxx = (inherited.parallaxx or 1.0) * (tonumber(layer.parallaxx) or 1.0),
                parallaxy = (inherited.parallaxy or 1.0) * (tonumber(layer.parallaxy) or 1.0),
                visible = (inherited.visible ~= false) and local_visible,
                opacity = (inherited.opacity or 1.0) * (tonumber(layer.opacity) or 1.0),
            }

            if layer.type == "group" and type(layer.layers) == "table" then
                flatten_tiled_layers(layer.layers, next_state, out)
            else
                out[#out + 1] = {
                    layer = layer,
                    offsetx = next_state.offsetx,
                    offsety = next_state.offsety,
                    parallaxx = next_state.parallaxx,
                    parallaxy = next_state.parallaxy,
                    visible = next_state.visible,
                    opacity = next_state.opacity,
                }
            end
        end
    end

    return out
end

-- Generate embedded sprite components for Tiled image layers.
-- Components are returned with source_image and atlas_path populated;
-- animation_name is assigned later after atlas import.
-- Paired foreground tile/object layers can precede another tile layer. Their
-- names explicitly request foreground placement, even with empty layers above.
local function foreground_offset(layers,index,last_tile)
    local function named_foreground(entry)
        return tostring(entry.layer and entry.layer.name or ""):lower():find("foreground",1,true)~=nil
    end
    if named_foreground(layers[index]) then
        for i,entry in ipairs(layers) do if named_foreground(entry) then return index-i+1 end end
    end
    return math.max(0,index-last_tile)
end

local function gen_sprite_components_for_image_layers(tiled_data, map_width, map_height, room_id, tiled_export_path)
    local components = {}
    if not tiled_data or not tiled_data.layers then
        return components
    end

    local atlas_path = get_room_background_atlas_paths(tiled_data, room_id)
    local map_dir = path_dirname(tiled_export_path)

    local flattened_layers = flatten_tiled_layers(tiled_data.layers)

    -- Find the highest index of any tile layer to determine the "tilemap level"
    -- Flattened layers preserve Tiled draw order (bottom-to-top).
    local max_tile_layer_index = 0
    for i, entry in ipairs(flattened_layers) do
        local layer = entry.layer
        if layer and layer.type == "tilelayer" then
            max_tile_layer_index = math.max(max_tile_layer_index, i)
        end
    end

    for layer_index, entry in ipairs(flattened_layers) do
        local layer = entry.layer
        if layer and layer.type == "imagelayer" and layer.image and layer.image ~= "" and entry.visible ~= false then
            local sprite_id = "parallax_" .. layer.name
            local image_path = layer.image
            local img_w, img_h, resolved_image = get_png_dimensions_any(image_path, map_dir)
            local animation_name = get_animation_name_from_image(resolved_image or image_path)

            -- Use effective values after group inheritance
            local parallaxx = entry.parallaxx or 1.0
            local parallaxy = entry.parallaxy or 1.0

            -- Use one biome atlas for room background sprites.

            -- Calculate Z position based on layer order relative to tile layers
            -- Layers below tile layers in Tiled (lower index) = negative Z (behind tilemap)
            -- Layers above tile layers in Tiled (higher index) = positive Z (in front of tilemap)
            -- Tilemap itself is at z=0
            --
            -- Within background layers, use Tiled layer order to determine
            -- draw order so layers stacked later in Tiled render in front.
            local z_pos
            local material_path
            local layers_above=foreground_offset(flattened_layers,layer_index,max_tile_layer_index)
            if layers_above == 0 then
                -- Background layers: z from -0.15 (farthest) to just below 0
                -- Each layer gets a unique z based on its position in the stack.
                -- layer_index 1 = farthest back, max_tile_layer_index = closest to tilemap
                local t = max_tile_layer_index > 1
                    and (layer_index - 1) / (max_tile_layer_index - 1)
                    or 0.5
                z_pos = -0.15 + t * 0.14  -- range: -0.15 to -0.01
                material_path = PARALLAX_BACKGROUND_MATERIAL
            else
                -- Above tile layers - render in front of tilemap
                -- Calculate based on distance from tile layers
                z_pos = RenderOrder.imported_foreground_layer_z(layers_above)
                material_path = PARALLAX_FOREGROUND_MATERIAL
            end
            
            -- Calculate position based on effective offsets (including parent groups).
            local offset_x = entry.offsetx or 0
            local offset_y = entry.offsety or 0

            -- Calculate sprite position
            local pos_x, pos_y

            if img_w and img_h then
                pos_x, pos_y = tiled_image_layer_to_defold_pos(offset_x, offset_y, img_w, img_h, map_height)

                info(string.format("  - Image layer '%s': offset=(%.0f, %.0f) size=(%dx%d) -> pos=(%.1f, %.1f) parallax=(%.2f, %.2f)",
                    layer.name, offset_x, offset_y, img_w, img_h, pos_x, pos_y, parallaxx, parallaxy))
            else
                -- Fallback if we can't read image dimensions.
                -- Use raw offsets for now; positions will be corrected in
                -- collect_room_background_sprite_components once finalize
                -- resolves the dimensions from the copied atlas image.
                pos_x = offset_x
                pos_y = map_height - offset_y
                info(string.format("  - Could not read PNG dimensions for %s (will fix position after atlas copy)", tostring(image_path)))
            end

            local base_component = {
                id = sprite_id,
                animation_name = animation_name,
                atlas_path = atlas_path,          -- Use biome-specific atlas
                pos_x = pos_x,
                pos_y = pos_y,
                pos_z = z_pos,
                material_path = material_path,
                parallaxx = parallaxx,
                parallaxy = parallaxy,
                opacity = entry.opacity,
                layer_name = layer.name,
                source_image = resolved_image,
                source_width = img_w,
                source_height = img_h,
                repeatx = layer.repeatx == true,
                repeaty = layer.repeaty == true,
                -- Store original Tiled offsets so position can be recalculated
                -- when source dimensions become available after atlas copy.
                tiled_offsetx = offset_x,
                tiled_offsety = offset_y,
                needs_center_fix = (img_w == nil or img_h == nil),
            }

            -- Don't expand repeats here; source_width/source_height may not
            -- be available yet (image outside sandbox).  Expansion happens in
            -- collect_room_background_sprite_components after finalize fills
            -- in dimensions from the copied atlas image.
            components[#components + 1] = base_component
        end
    end

    return components
end

local function gen_sprite_components_for_background_visual_objects(tiled_data, map_height, room_id, tiled_export_path)
    local components = {}
    if not tiled_data or not tiled_data.layers then
        return components
    end

    local atlas_path = get_room_background_atlas_paths(tiled_data, room_id)
    local flattened_layers = flatten_tiled_layers(tiled_data.layers)
    local tileset_lookup = build_tileset_gid_lookup(tiled_data, tiled_export_path)

    local max_tile_layer_index = 0
    for i, entry in ipairs(flattened_layers) do
        local layer = entry.layer
        if layer and layer.type == "tilelayer" then
            max_tile_layer_index = math.max(max_tile_layer_index, i)
        end
    end

    -- Build per-layer draw ranks to mirror Tiled object draw order.
    -- `topdown`: lower Y first, higher Y on top.
    -- `index`: original object array order.
    local function build_object_draw_ranks(layer)
        local rank_by_obj = {}
        local ordered = {}
        if type(layer) ~= "table" or type(layer.objects) ~= "table" then
            return rank_by_obj, 0
        end

        local draworder = tostring(layer.draworder or "topdown"):lower()
        for index, obj in ipairs(layer.objects) do
            if obj then
                ordered[#ordered + 1] = {
                    obj = obj,
                    index = index,
                    y = tonumber(obj.y) or 0,
                }
            end
        end

        if draworder == "topdown" then
            table.sort(ordered, function(a, b)
                if a.y ~= b.y then
                    return a.y < b.y
                end
                return a.index < b.index
            end)
        end

        for rank, item in ipairs(ordered) do
            rank_by_obj[item.obj] = rank
        end
        return rank_by_obj, #ordered
    end

    for layer_index, entry in ipairs(flattened_layers) do
        local layer = entry.layer
        if layer and layer.type == "objectgroup" and entry.visible ~= false and type(layer.objects) == "table" then
            local draw_rank_by_obj, draw_count = build_object_draw_ranks(layer)
            local object_z_step = RenderOrder.imported_foreground_object_step(draw_count)
            if draw_count > 0 then
                -- Keep per-object depth offsets bounded so they don't jump
                -- across major layer buckets.
                object_z_step = math.min(object_z_step, 0.009 / draw_count)
            end

            for object_index, obj in ipairs(layer.objects) do
                if obj and obj.visible ~= false and is_background_visual_object_candidate(obj, layer.name) then
                    local gid, flip_h, flip_v, flip_d = decode_tiled_gid(obj.gid)
                    local tileset_entry, local_tile_id = find_tileset_for_gid(tileset_lookup, gid)
                    local resolved_image = nil
                    local extracted_w, extracted_h = nil, nil
                    local is_tint_fill = false

                    -- Tintcolor takes precedence: if the parent layer carries a
                    -- `tintcolor`, treat this object as a flat-colored fill,
                    -- regardless of any leftover gid.  Authors set tintcolor
                    -- specifically to express "render this region as a solid
                    -- color"; using the underlying tile image would defeat
                    -- that intent and is also how Tiled itself displays the
                    -- layer when tintcolor is opaque.
                    if _deps.ensure_solid_color_quad_image then
                        local tc = layer and layer.tintcolor
                        if type(tc) == "table" and #tc >= 3 then
                            local tr, tg, tb, ta = tc[1], tc[2], tc[3], tc[4]
                            local fill_abs, _, fw, fh, fill_err = _deps.ensure_solid_color_quad_image(tr, tg, tb, ta)
                            if fill_abs then
                                resolved_image = fill_abs
                                extracted_w, extracted_h = fw, fh
                                is_tint_fill = true
                                flip_h, flip_v, flip_d = false, false, false
                            elseif fill_err then
                                info(string.format(
                                    "background_visual: tint fill generation failed room=%s object=%s err=%s",
                                    tostring(room_id),
                                    tostring(obj.id),
                                    tostring(fill_err)
                                ))
                            end
                        end
                    end

                    if (not resolved_image) and tileset_entry and local_tile_id ~= nil then
                        resolved_image = tileset_entry.meta and tileset_entry.meta.tile_images and tileset_entry.meta.tile_images[local_tile_id] or nil
                        if (not resolved_image) and tileset_entry.meta then
                            resolved_image = _C.maybe_infer_missing_collection_tile_image(
                                tileset_entry.meta,
                                local_tile_id,
                                tileset_entry.name,
                                room_id,
                                obj.id
                            )
                        end

                        -- Fallback: if the tileset is a sheet-style (single
                        -- image grid) tilesource rather than a Collection of
                        -- Images, crop the referenced tile out of the sheet
                        -- PNG into a generated per-tile PNG and use that as
                        -- the sprite source.  This lets picture objects
                        -- authored from regular tilesheets export the same
                        -- way Collection-of-Images picture objects already
                        -- do, without requiring authors to re-package every
                        -- scenery tile as a separate PNG.
                        if (not resolved_image) and _deps.ensure_extracted_background_tile_image then
                            local extracted_abs, _, ew, eh, ex_err = _deps.ensure_extracted_background_tile_image(
                                tileset_entry.name,
                                local_tile_id
                            )
                            if extracted_abs then
                                resolved_image = extracted_abs
                                extracted_w, extracted_h = ew, eh
                            elseif ex_err and ex_err ~= "tilesource_not_sheet" then
                                info(string.format(
                                    "background_visual: tile extraction failed room=%s object=%s tileset=%s tile=%s err=%s",
                                    tostring(room_id),
                                    tostring(obj.id),
                                    tostring(tileset_entry.name),
                                    tostring(local_tile_id),
                                    tostring(ex_err)
                                ))
                            end
                        end
                    end

                    if resolved_image then
                        local img_w, img_h = get_png_dimensions_any(resolved_image, nil)
                        if (not img_w or not img_h) and extracted_w and extracted_h then
                            img_w, img_h = extracted_w, extracted_h
                        end
                        local obj_w = tonumber(obj.width) or 0
                        local obj_h = tonumber(obj.height) or 0
                        if obj_w <= 0 then obj_w = tonumber(img_w) or tonumber(tiled_data.tilewidth) or 128 end
                        if obj_h <= 0 then obj_h = tonumber(img_h) or tonumber(tiled_data.tileheight) or obj_w end

                        local scale_x = 1.0
                        local scale_y = 1.0
                        if img_w and img_w > 0 then
                            scale_x = obj_w / img_w
                        end
                        if img_h and img_h > 0 then
                            scale_y = obj_h / img_h
                        end

                        local obj_x = (tonumber(obj.x) or 0) + (entry.offsetx or 0)
                        local obj_y = (tonumber(obj.y) or 0) + (entry.offsety or 0)
                        local pos_x = obj_x + (obj_w * 0.5)
                        local pos_y = (map_height - obj_y) + (obj_h * 0.5)
                        -- Optional per-image factors multiply its layer/group factors.
                        local parallaxx = (entry.parallaxx or 1.0) * (tonumber(VisualProperties.property_value(obj,"parallaxx")) or 1)
                        local parallaxy = (entry.parallaxy or 1.0) * (tonumber(VisualProperties.property_value(obj,"parallaxy")) or 1)

                        -- Place picture-object sprites using the SAME Tiled
                        -- layer-order ramp as image layers (see image-layer
                        -- branch above). This preserves Tiled's stacking when
                        -- an object layer sits between tile layers (e.g.
                        -- between `solid` and `environment`), so picture
                        -- objects render in front of layers below them and
                        -- behind layers above them — matching what is shown
                        -- in Tiled. Bucketing by parallax (the previous
                        -- behavior) collapsed multiple layers to the same Z
                        -- and broke that ordering.
                        local z_pos
                        local material_path
                        local layers_above=foreground_offset(flattened_layers,layer_index,max_tile_layer_index)
                        if layers_above == 0 then
                            local t = max_tile_layer_index > 1
                                and (layer_index - 1) / (max_tile_layer_index - 1)
                                or 0.5
                            z_pos = -0.15 + t * 0.14  -- range: -0.15 to -0.01
                            material_path = PARALLAX_BACKGROUND_MATERIAL
                        else
                            z_pos = RenderOrder.imported_foreground_layer_z(layers_above)
                            material_path = PARALLAX_FOREGROUND_MATERIAL
                        end
                        local draw_rank = draw_rank_by_obj[obj] or object_index
                        z_pos = z_pos + (draw_rank * object_z_step)

                        local sprite_id = string.format(
                            "background_visual_%s_%s",
                            sanitize_asset_name(layer.name or "layer", "layer"),
                            tostring(obj.id or object_index)
                        )

                        components[#components + 1] = {
                            id = sprite_id,
                            animation_name = get_animation_name_from_image(resolved_image),
                            atlas_path = atlas_path,
                            pos_x = pos_x,
                            pos_y = pos_y,
                            pos_z = z_pos,
                            material_path = material_path,
                            parallaxx = parallaxx,
                            parallaxy = parallaxy,
                            opacity = entry.opacity,
                            layer_name = layer.name or "background",
                            source_image = normalize(resolved_image),
                            flip_horizontal = flip_h,
                            flip_vertical = flip_v,
                            scale_x = scale_x,
                            scale_y = scale_y,
                            source_width = img_w,
                            source_height = img_h,
                            target_width = obj_w,
                            target_height = obj_h,
                            import_kind = "background_visual",
                        }

                        if flip_d then
                            info(string.format("background_visual: room=%s object=%s has diagonal tile flip flag; diagonal flip is not supported in sprite import", tostring(room_id), tostring(obj.id)))
                        end
                    else
                        -- This scenery object produced no sprite. Count it so
                        -- Create Rooms can report one summary instead of N
                        -- per-object log lines the creator never scrolls back to.
                        note_background_skip(room_id)
                        if tileset_entry then
                            info(string.format(
                                "background_visual: skipped room=%s object=%s because tileset '%s' is not a collection image tile",
                                tostring(room_id),
                                tostring(obj.id),
                                tostring(tileset_entry.name)
                            ))
                        else
                            info(string.format(
                                "background_visual: skipped room=%s object=%s because gid=%s did not resolve to a tileset",
                                tostring(room_id),
                                tostring(obj.id),
                                tostring(gid)
                            ))
                        end
                    end
                end
            end
        end
    end

    return components
end

local function finalize_background_sprite_components(room_id, tiled_data, components)
    if type(components) ~= "table" or #components == 0 then
        return components or {}
    end

    local atlas_path = components[1].atlas_path or get_room_background_atlas_paths(tiled_data, room_id)
    local atlas_abs = atlas_resource_to_abs(atlas_path)
    local source_images = {}
    local seen_sources = {}
    for _, comp in ipairs(components) do
        if comp.source_image and comp.source_image ~= "" then
            local key = normalize(comp.source_image)
            if not seen_sources[key] then
                seen_sources[key] = true
                source_images[#source_images + 1] = key
            end
        end
    end

    local animation_by_source, copied_abs_by_source, _, appended = ensure_images_in_background_atlas(atlas_path, atlas_abs, source_images)
    if appended > 0 then
        info(string.format("background_visual: updated atlas %s with %d new images", tostring(atlas_abs), appended))
    end

    for _, comp in ipairs(components) do
        local key = comp.source_image and normalize(comp.source_image) or nil
        local mapped = key and animation_by_source[key] or nil
        local copied_abs = key and copied_abs_by_source[key] or nil

        if copied_abs and ((not comp.source_width or comp.source_width <= 0) or (not comp.source_height or comp.source_height <= 0)) then
            local copied_w, copied_h = get_png_dimensions_any(copied_abs, nil)
            if copied_w and copied_h then
                if not comp.source_width or comp.source_width <= 0 then
                    comp.source_width = copied_w
                end
                if not comp.source_height or comp.source_height <= 0 then
                    comp.source_height = copied_h
                end
            end
        end

        if comp.import_kind == "background_visual" then
            local target_w = tonumber(comp.target_width) or 0
            local target_h = tonumber(comp.target_height) or 0
            local source_w = tonumber(comp.source_width) or 0
            local source_h = tonumber(comp.source_height) or 0
            if target_w > 0 and target_h > 0 and source_w > 0 and source_h > 0 then
                comp.scale_x = target_w / source_w
                comp.scale_y = target_h / source_h
            end
        end

        if mapped then
            comp.animation_name = mapped
        elseif not comp.animation_name or comp.animation_name == "" then
            comp.animation_name = get_animation_name_from_image(comp.source_image or comp.id or "image")
        end
    end

    return components
end

local function collect_room_background_sprite_components(tiled_data, map_width, map_height, room_id, tiled_export_path)
    local components = {}

    local image_layer_components = gen_sprite_components_for_image_layers(tiled_data, map_width, map_height, room_id, tiled_export_path)
    for _, comp in ipairs(image_layer_components) do
        components[#components + 1] = comp
    end

    local background_visual_components = gen_sprite_components_for_background_visual_objects(tiled_data, map_height, room_id, tiled_export_path)
    for _, comp in ipairs(background_visual_components) do
        components[#components + 1] = comp
    end

    -- Finalize first so source_width/source_height are populated from
    -- copied atlas images (the originals may be outside the sandbox).
    local finalized = finalize_background_sprite_components(room_id, tiled_data, components)

    -- Fix positions for components whose dimensions were not available
    -- when initially computed (image outside sandbox).
    for _, comp in ipairs(finalized) do
        if comp.needs_center_fix then
            local sw = tonumber(comp.source_width) or 0
            local sh = tonumber(comp.source_height) or 0
            if sw > 0 and sh > 0 then
                comp.pos_x, comp.pos_y = tiled_image_layer_to_defold_pos(
                    comp.tiled_offsetx, comp.tiled_offsety, sw, sh, map_height)
                comp.needs_center_fix = nil
                info(string.format("  - Fixed center position for '%s': offset=(%.0f, %.0f) size=(%dx%d) -> pos=(%.1f, %.1f)",
                    tostring(comp.id),
                    tonumber(comp.tiled_offsetx) or 0, tonumber(comp.tiled_offsety) or 0,
                    sw, sh, comp.pos_x, comp.pos_y))
            end
        end
    end

    -- Now expand repeat-x / repeat-y components with correct dimensions.
    local expanded = {}
    for _, comp in ipairs(finalized) do
        comp.parallax_origin_x, comp.parallax_origin_y = ParallaxRepeat.map_origin(tiled_data)
        if (comp.repeatx or comp.repeaty) and (tonumber(comp.source_width) or 0) > 0 and (tonumber(comp.source_height) or 0) > 0 then
            local copies = ParallaxRepeat.expand_component(comp, map_width, map_height)
            for _, c in ipairs(copies) do
                expanded[#expanded + 1] = c
            end
        else
            expanded[#expanded + 1] = comp
        end
    end

    return expanded
end

local function gen_backgrounds_metadata(sprite_components)
    local layer_order = {}
    local layer_to_ids = {}
    local layer_to_base = {}

    for _, comp in ipairs(sprite_components or {}) do
        local layer_name = tostring(comp.layer_name or "")
        if layer_name ~= "" then
            if not layer_to_ids[layer_name] then
                layer_to_ids[layer_name] = {}
                layer_order[#layer_order + 1] = layer_name
            end

            layer_to_ids[layer_name][#layer_to_ids[layer_name] + 1] = tostring(comp.id or "")
            if not layer_to_base[layer_name] and not tostring(comp.id or ""):find("__repeat_", 1, true) then
                layer_to_base[layer_name] = tostring(comp.id or "")
            end
        end
    end

    local rows = {
        "return {",
        "  layers = {",
    }

    for _, layer_name in ipairs(layer_order) do
        local component_ids = layer_to_ids[layer_name] or {}
        rows[#rows + 1] = string.format("    [%q] = {", layer_name)
        rows[#rows + 1] = string.format("      base_component_id = %q,", layer_to_base[layer_name] or "")
        rows[#rows + 1] = "      component_ids = {"
        for _, component_id in ipairs(component_ids) do
            rows[#rows + 1] = string.format("        %q,", component_id)
        end
        rows[#rows + 1] = "      },"
        rows[#rows + 1] = "    },"
    end

    rows[#rows + 1] = "  },"
    rows[#rows + 1] = "}"
    rows[#rows + 1] = ""

    return table.concat(rows, "\n")
end


M.get_room_background_atlas_paths = get_room_background_atlas_paths
M.get_png_dimensions_any = get_png_dimensions_any
M.load_existing_atlas_index = load_existing_atlas_index
M.ensure_images_in_background_atlas = ensure_images_in_background_atlas
M.flatten_tiled_layers = flatten_tiled_layers
M.gen_sprite_components_for_image_layers = gen_sprite_components_for_image_layers
M.gen_sprite_components_for_background_visual_objects = gen_sprite_components_for_background_visual_objects
M.finalize_background_sprite_components = finalize_background_sprite_components
M.collect_room_background_sprite_components = collect_room_background_sprite_components
M.gen_backgrounds_metadata = gen_backgrounds_metadata

return M

--- Tiled Lua Export Parser
-- Parses Tiled map exports (.lua format) to extract layers, objects, and custom properties
--
-- Usage in Tiled:
--   1. File -> Export As -> Lua files (*.lua)
--   2. Save to the tiled_maps_dir configured in developer/config/stream_settings.lua
--   3. Use this parser to read the exported data
--
-- @module tiled_parser

local Util = require "mvtk.core.util"
local PropertyFlattener = require "mvtk.tiled.property_flattener"

local M = {}

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.tiled and _Dbg.tiled.parser then
        _orig_print(...)
    end
end

local function get_texture_info_safe(path)
    if not resource or not resource.get_texture_info then
        return nil
    end
    local ok, info = pcall(resource.get_texture_info, path)
    if ok then
        return info
    end
    return nil
end

local function load_resource_map(file_path)
    local success_load, resource_data = pcall(sys.load_resource, file_path)
    if not success_load or not resource_data then
        return nil, resource_data
    end

    print("[TILED_PARSER] Resource loaded, size:", #resource_data, "bytes")
    local loader = loadstring or load
    if not loader then
        return nil, "No Lua resource loader available"
    end
    local chunk, load_err = loader(resource_data, "@" .. tostring(file_path))
    if not chunk then
        return nil, "Failed to parse Tiled Lua: " .. tostring(load_err)
    end

    local success_exec, map_result = pcall(chunk)
    if success_exec and type(map_result) == "table" then
        return map_result
    end
    return nil, "Failed to execute Tiled Lua: " .. tostring(map_result)
end

local function is_resource_path(path)
    return type(path) == "string" and (path:find("/", 1, true) or path:match("%.lua$"))
end

local function make_color4(x, y, z, w)
    if vmath and vmath.vector4 then
        return vmath.vector4(x, y, z, w)
    end
    return {
        x = x or 0,
        y = y or 0,
        z = z or 0,
        w = w or 0,
    }
end

-- Try to resolve a Tiled image path to a bundled texture resource
local function resolve_image_resource(image_path)
    if not image_path or image_path == "" then
        return nil
    end

    local cleaned = image_path:gsub("\\", "/")
    local filename = cleaned:match("([^/]+)$")
    local candidates = {}
    local seen = {}

    local function add(path)
        if not path or path == "" then return end
        path = path:gsub("^/+", "/")
        if path:sub(1, 1) ~= "/" then
            path = "/" .. path
        end
        if not seen[path] then
            seen[path] = true
            table.insert(candidates, path)
        end
    end

    -- Paths relative to configured Tiled map exports (strip ../)
    local relative = cleaned:gsub("^%.%./+", "")
    add(relative)
    add("developer/assets/tiled/" .. relative)
    add("assets/" .. relative)

    -- Common fallback locations by filename
    if filename then
        add("developer/assets/tiled/" .. filename)
        add("developer/assets/tiled/backgrounds/" .. filename)
        add("developer/assets/tiled/images/" .. filename)
    end

    for _, candidate in ipairs(candidates) do
        local info = get_texture_info_safe(candidate)
        if info then
            return candidate, info.width, info.height
        end
    end

    return nil
end

--- Parse a Tiled Lua export file
-- @param path Module path or file path to the exported .lua file
--             Module: "assets.tiled.maps.level_01"
--             File: a Defold resource path ending in ".lua"
-- @return Table with map data or nil, error
function M.load(path)
    print("[TILED_PARSER] ========== LOADING TILED MAP ==========")
    print("[TILED_PARSER] Input path:", path)

    local map = nil
    local err = nil

    local resource_path_input = is_resource_path(path)
    if resource_path_input then
        local file_path = tostring(path)
        if file_path:sub(1, 1) ~= "/" then
            file_path = "/" .. file_path
        end
        print("[TILED_PARSER] File path:", file_path)
        map, err = load_resource_map(file_path)
    end

    -- Try method 1: require() for module paths
    -- Convert dots to module path: "assets.tiled.maps.room" -> require("assets.tiled.maps.room")
    local success_require, result = false, nil
    if not map and not resource_path_input then
        success_require, result = pcall(require, path)
        if success_require and type(result) == "table" then
            print("[TILED_PARSER] Loaded via require()")
            map = result
        elseif success_require then
            err = "Tiled Lua module did not return a table"
            success_require = false
        end
    end

    if not map and not success_require and not resource_path_input then
        print("[TILED_PARSER] require() failed, trying sys.load_resource()...")

        -- Try method 2: sys.load_resource() for file paths
        -- Convert module path to file path.
        local file_path = "/" .. path:gsub("%.", "/") .. ".lua"
        print("[TILED_PARSER] File path:", file_path)

        map, err = load_resource_map(file_path)
        if map then
            print("[TILED_PARSER] Loaded via sys.load_resource()")
        else
            err = string.format("Failed to load Tiled map file.\n" ..
                "  Attempted path: '%s'\n" ..
                "  Original input: '%s'\n" ..
                "  Common causes:\n" ..
                "    1. File does not exist at the path\n" ..
                "    2. File not included in game.project bundle\n" ..
                "    3. Path format incorrect (use dots for require, slashes for files)\n" ..
                "  TIP: Export from Tiled as Lua format to the configured tiled_maps_dir.",
                file_path, path)
        end
    end

    if not map then
        print("[TILED_PARSER] ========== ERROR: FAILED TO LOAD TILED MAP ==========")
        print("[TILED_PARSER] Input path:", path)
        print("[TILED_PARSER] Error details:")
        print(err or "Unknown error")
        print("[TILED_PARSER] ======================================================")
        return nil, err or "Failed to load Tiled map"
    end

    if type(map) ~= "table" then
        print("[TILED_PARSER] ERROR: Result is not a table")
        print("[TILED_PARSER] Result type:", type(map))
        return nil, "Tiled export did not return a valid map table"
    end

    print("[TILED_PARSER] Map loaded successfully!")
    print("[TILED_PARSER] Map size:", map.width, "x", map.height)
    print("[TILED_PARSER] Tile size:", map.tilewidth, "x", map.tileheight)
    print("[TILED_PARSER] Layers:", #(map.layers or {}))
    print("[TILED_PARSER] =========================================")

    return map
end

--- Get a property value from a modern Tiled properties table.
-- @param properties Table of properties from Tiled
-- @param prop_name Name of the property to find
-- @return Property value or nil
local function get_property(properties, prop_name)
    if type(properties) ~= "table" then return nil end
    return properties[prop_name]
end

--- Extract all parallax layers from a Tiled map
-- Supports both:
-- 1. Tile layers with custom property "parallax_factor"
-- 2. Image layers with Tiled's built-in "parallaxx" property
-- @param map The loaded Tiled map data
-- @return Array of layer data: { id, name, parallax_factor, z_index, visible, opacity, layer_type, ... }
function M.get_parallax_layers(map)
    if not map or not map.layers then return {} end

    local parallax_layers = {}
    local map_height_px = (map.height or 0) * (map.tileheight or 0)
    local flattened = {}

    local function walk_layers(layers, inherited)
        if type(layers) ~= "table" then return end
        inherited = inherited or {
            offsetx = 0,
            offsety = 0,
            parallaxx = 1.0,
            parallaxy = 1.0,
            visible = true,
            opacity = 1.0,
        }

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
                    walk_layers(layer.layers, next_state)
                else
                    flattened[#flattened + 1] = {
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
    end

    walk_layers(map.layers, nil)

    for i, entry in ipairs(flattened) do
        local layer = entry.layer
        local parallax_factor = nil
        local layer_data = nil

        -- Handle TILE LAYERS (use built-in parallax, fallback to custom property)
        if layer.type == "tilelayer" then
            local parallaxx = entry.parallaxx or 1.0
            parallax_factor = parallaxx ~= 1.0 and parallaxx or nil

            -- Fallback: custom property "parallax_factor" (legacy)
            if not parallax_factor and layer.properties then
                local pf = get_property(layer.properties, "parallax_factor")
                if pf then
                    parallax_factor = tonumber(pf)
                end
            end

            if parallax_factor then
                layer_data = {
                    id = layer.id,
                    name = layer.name,
                    layer_type = "tilelayer",
                    parallax_factor = parallax_factor,
                    z_index = (i * 0.1),  -- Default z-index based on draw order
                    visible = entry.visible ~= false,
                    opacity = entry.opacity or 1.0,
                    width = layer.width,
                    height = layer.height,
                    data = layer.data,  -- Tile GIDs
                    offsetx = entry.offsetx or 0,
                    offsety = entry.offsety or 0,
                }
            end

        -- Handle IMAGE LAYERS with Tiled's built-in parallaxx property
        elseif layer.type == "imagelayer" then
            -- Use effective parallax (including parent groups)
            local parallaxx = entry.parallaxx or 1.0
            local base_x = entry.offsetx or 0
            local base_y = map_height_px - (entry.offsety or 0)
            local _, img_w, img_h = resolve_image_resource(layer.image)
            if img_w and img_h then
                base_x = base_x + (img_w * 0.5)
                base_y = base_y - (img_h * 0.5)
            end
            local z_index = -0.1
            if parallaxx < 1.0 then
                z_index = -0.12
            else
                z_index = -0.08
            end

            -- Create layer data for ALL image layers (parallax or not)
            layer_data = {
                id = layer.id,
                name = layer.name,
                layer_type = "imagelayer",
                parallax_factor = parallaxx,  -- Use parallaxx directly
                z_index = z_index,
                visible = entry.visible ~= false,
                opacity = entry.opacity or 1.0,
                image = layer.image or "",  -- Image file path
                offsetx = entry.offsetx or 0,
                offsety = entry.offsety or 0,
                repeatx = layer.repeatx or false,
                repeaty = layer.repeaty or false,
                base_position = vmath.vector3(base_x, base_y, 0),
            }
        end

        -- Check for custom z_index property (both tile and image layers)
        if layer_data and layer.properties then
            local z = get_property(layer.properties, "z_index")
            if z then
                layer_data.z_index = tonumber(z)
            end
        end

        if layer_data then
            table.insert(parallax_layers, layer_data)
        end
    end

    -- Sort by z_index (background to foreground)
    table.sort(parallax_layers, function(a, b)
        return (a.z_index or 0) < (b.z_index or 0)
    end)

    return parallax_layers
end

--- Extract all object layers from a Tiled map
-- @param map The loaded Tiled map data
-- @param filter_name Optional: only return object layers with this name
-- @return Array of object layer data
function M.get_object_layers(map, filter_name)
    if not map or not map.layers then return {} end

    local object_layers = {}

    for _, layer in ipairs(map.layers) do
        if layer.type == "objectgroup" then
            if not filter_name or layer.name == filter_name then
                table.insert(object_layers, {
                    id = layer.id,
                    name = layer.name,
                    visible = layer.visible ~= false,
                    opacity = layer.opacity or 1.0,
                    offsetx = layer.offsetx or 0,
                    offsety = layer.offsety or 0,
                    objects = layer.objects or {},
                    properties = M.extract_properties(layer.properties),
                })
            end
        end
    end

    return object_layers
end

--- Extract all objects from all object layers
-- @param map The loaded Tiled map data
-- @param object_type Optional: filter by object type property
-- @return Array of objects with layer context
function M.get_all_objects(map, object_type)
    if not map or not map.layers then return {} end

    local all_objects = {}

    for _, layer in ipairs(map.layers) do
        if layer.type == "objectgroup" and layer.objects then
            for _, obj in ipairs(layer.objects) do
                -- Check if this object matches the type filter
                local matches_type = true
                if object_type and obj.type ~= object_type then
                    matches_type = false
                end

                if matches_type then
                    local object_data = {
                        id = obj.id,
                        name = obj.name or "",
                        type = obj.type or "",
                        x = obj.x,
                        y = obj.y,
                        width = obj.width or 0,
                        height = obj.height or 0,
                        rotation = obj.rotation or 0,
                        visible = obj.visible ~= false,
                        properties = M.extract_properties(obj.properties),
                        layer_name = layer.name,
                        layer_id = layer.id,

                        -- Shape data
                        shape = obj.shape or "rectangle",
                        polygon = obj.polygon,
                        polyline = obj.polyline,
                        ellipse = obj.ellipse,
                        point = obj.point,

                        -- Tile object (gid)
                        gid = obj.gid,
                    }

                    table.insert(all_objects, object_data)
                end
            end
        end
    end

    return all_objects
end

--- Extract custom properties from a modern Tiled key-value table.
--- @param properties Table of properties from Tiled
-- @return Table with property names as keys
function M.extract_properties(properties)
    local flattened = PropertyFlattener.flatten(properties)
    local props = {}

    -- Normalize both bundled keyed exports and native Tiled property records
    -- before applying runtime-friendly value conversions.
    for name, value in pairs(flattened) do
        -- Handle color strings.
        if type(value) == "string" and value:match("^#%x+$") then
            props[name] = M.parse_color(value)
        else
            props[name] = value
        end
    end

    return props
end

--- Parse Tiled color string to RGBA vector
-- @param color_str String in format "#AARRGGBB" or "#RRGGBB"
-- @return vmath.vector4 or nil
local function normalize_color_channel(value, default_value)
    if value == nil then
        return default_value
    end

    local numeric = tonumber(value)
    if numeric == nil then
        return default_value
    end

    if numeric < 0 then
        numeric = 0
    end

    if numeric > 1 then
        numeric = numeric / 255
    end

    if numeric < 0 then
        numeric = 0
    elseif numeric > 1 then
        numeric = 1
    end

    return numeric
end

function M.parse_color(color_value)
    if type(color_value) == "string" then
        -- Remove # prefix
        local hex = color_value:match("^#?(%x+)$")
        if not hex then return nil end

        local r, g, b, a

        if #hex == 8 then
            -- #AARRGGBB
            a = tonumber(hex:sub(1, 2), 16) / 255
            r = tonumber(hex:sub(3, 4), 16) / 255
            g = tonumber(hex:sub(5, 6), 16) / 255
            b = tonumber(hex:sub(7, 8), 16) / 255
        elseif #hex == 6 then
            -- #RRGGBB
            r = tonumber(hex:sub(1, 2), 16) / 255
            g = tonumber(hex:sub(3, 4), 16) / 255
            b = tonumber(hex:sub(5, 6), 16) / 255
            a = 1.0
        else
            return nil
        end

        return make_color4(r, g, b, a)
    end

    if type(color_value) == "table" then
        local r = normalize_color_channel(color_value.r or color_value.red or color_value[1], nil)
        local g = normalize_color_channel(color_value.g or color_value.green or color_value[2], nil)
        local b = normalize_color_channel(color_value.b or color_value.blue or color_value[3], nil)
        local a = normalize_color_channel(color_value.a or color_value.alpha or color_value[4], 1.0)

        if r == nil or g == nil or b == nil then
            return nil
        end

        return make_color4(r, g, b, a)
    end

    return nil
end

function M.get_background_color(map)
    if type(map) ~= "table" then
        return nil
    end
    return M.parse_color(map.backgroundcolor)
end

function M.get_default_clear_color()
    local get_number = sys and sys.get_config_number
    return make_color4(
        get_number and get_number("render.clear_color_red", 0) or 0,
        get_number and get_number("render.clear_color_green", 0) or 0,
        get_number and get_number("render.clear_color_blue", 0) or 0,
        get_number and get_number("render.clear_color_alpha", 0) or 0
    )
end

--- Get map dimensions and properties
-- @param map The loaded Tiled map data
-- @return Table with width, height, tilewidth, tileheight, orientation, properties
function M.get_map_info(map)
    if not map then return nil end

    return {
        width = map.width,
        height = map.height,
        tilewidth = map.tilewidth,
        tileheight = map.tileheight,
        orientation = map.orientation or "orthogonal",
        renderorder = map.renderorder or "right-down",
        backgroundcolor = M.get_background_color(map),
        properties = M.extract_properties(map.properties),
        infinite = map.infinite or false,
    }
end

--- Get tile layer by name
-- @param map The loaded Tiled map data
-- @param layer_name Name of the layer
-- @return Layer data or nil
function M.get_layer(map, layer_name)
    if not map or not map.layers then return nil end

    for _, layer in ipairs(map.layers) do
        if layer.name == layer_name then
            return layer
        end
    end

    return nil
end

--- Convert Tiled coordinates to Defold world coordinates
-- Tiled uses top-left origin, Defold uses bottom-left
-- @param tiled_x X position in Tiled
-- @param tiled_y Y position in Tiled
-- @param map_height Height of the map in pixels
-- @return defold_x, defold_y
function M.tiled_to_defold(tiled_x, tiled_y, map_height)
    return tiled_x, map_height - tiled_y
end

--- Print map structure for debugging
-- @param map The loaded Tiled map data
function M.debug_print(map)
    if not map then
        print("[TILED_PARSER] No map data")
        return
    end

    print("[TILED_PARSER] Map info:")
    print("  Size:", map.width, "x", map.height)
    print("  Tile size:", map.tilewidth, "x", map.tileheight)
    print("  Orientation:", map.orientation)

    if map.layers then
        print("  Layers:", #map.layers)
        for i, layer in ipairs(map.layers) do
            local props_str = ""
            if layer.properties then
                local extracted = M.extract_properties(layer.properties)
                for name, value in pairs(extracted) do
                    props_str = props_str .. tostring(name) .. "=" .. tostring(value) .. " "
                end
            end

            print(string.format("    [%d] %s (%s) - %s",
                i, layer.name, layer.type, props_str))

            if layer.type == "objectgroup" and layer.objects then
                print(string.format("        Objects: %d", #layer.objects))
            end
        end
    end
end

return M

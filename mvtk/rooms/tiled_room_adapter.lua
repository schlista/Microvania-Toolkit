--- Tiled Room Adapter
-- Automatically loads Tiled maps at runtime when rooms are streamed
-- Integrates with your existing room_manager system
--
-- Setup:
-- 1. Export from Tiled to the directory configured in developer/config/stream_settings.lua
-- 2. That's it! The system handles everything else automatically
--
-- @module tiled_room_adapter

local Util = require "mvtk.core.util"

local M = {}

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.tiled and _Dbg.tiled.adapter then
        _orig_print(...)
    end
end

local TiledParser = require "mvtk.tiled.tiled_parser"
local TiledRegistry = require "mvtk.tiled.tiled_room_registry"
local ParallaxManager = require "mvtk.tiled.parallax_layer_manager"
local ObjectSpawner = require "mvtk.tiled.object_spawner"
local StreamPaths = require "mvtk.rooms.stream_paths"
local C = require "mvtk.core.constants"

-- Track loaded Tiled rooms
local loaded_tiled_rooms = {}
local parallax_initialized = false
local REQUIRED_LAYERS = { "collectibles", "gates", "breakables", "hazards" }

local background_layers_cache = {}

local function get_background_layers(room)
    if not room or room == "" then
        return nil
    end
    if background_layers_cache[room] ~= nil then
        return background_layers_cache[room]
    end

    local path = StreamPaths.backgrounds_meta(room)
    local ok, data = pcall(sys.load_resource, path)
    if not ok or not data then
        print(string.format("[TILED_ADAPTER] Background metadata unavailable for '%s': %s", tostring(path), tostring(data)))
        background_layers_cache[room] = false
        return nil
    end

    local loader = loadstring or load
    if not loader then
        print(string.format("[TILED_ADAPTER] Background metadata loader unavailable for '%s'", tostring(path)))
        background_layers_cache[room] = false
        return nil
    end

    local chunk, load_err = loader(data, "@" .. path)
    if not chunk then
        print(string.format("[TILED_ADAPTER] Failed to parse background metadata '%s': %s", tostring(path), tostring(load_err)))
        background_layers_cache[room] = false
        return nil
    end

    local ok_chunk, meta = pcall(chunk)
    local layers = ok_chunk and type(meta) == "table" and type(meta.layers) == "table" and meta.layers or nil
    if not layers then
        print(string.format("[TILED_ADAPTER] Background metadata invalid for '%s'", tostring(path)))
        background_layers_cache[room] = false
        return nil
    end

    local summary = {}
    for layer_name, layer_meta in pairs(layers) do
        local count = type(layer_meta) == "table" and type(layer_meta.component_ids) == "table" and #layer_meta.component_ids or 0
        summary[#summary + 1] = string.format("%s=%d", tostring(layer_name), count)
    end
    table.sort(summary)
    print(string.format("[TILED_ADAPTER] Background metadata '%s': %s",
        tostring(room), (#summary > 0) and table.concat(summary, ", ") or "none"))

    background_layers_cache[room] = layers
    return layers
end

local function validate_required_layers(map)
    if not (map and map.layers) then return end
    local present = {}
    for _, layer in ipairs(map.layers) do
        if layer.name then
            present[layer.name] = true
        end
    end
    local missing = {}
    for _, name in ipairs(REQUIRED_LAYERS) do
        if not present[name] then
            missing[#missing + 1] = name
        end
    end
    if #missing > 0 then
        print(string.format("[TILED_ADAPTER][WARN] Missing required object layers in map '%s': %s", tostring(map and map.name), table.concat(missing, ", ")))
    end
end

local function get_tiled_property(properties, key)
    if type(properties) ~= "table" or key == nil then
        return nil
    end

    local direct = properties[key]
    if direct ~= nil then
        return direct
    end

    for _, entry in ipairs(properties) do
        if type(entry) == "table" and entry.name == key then
            return entry.value
        end
    end

    return nil
end

local function register_room_zone(room_id, properties)
    -- Optional map-level room camera zone override.
    -- Example in Tiled map custom properties:
    --   room_zone = "boss_arena"
    local room_zone = get_tiled_property(properties, "room_zone")
    if room_zone ~= nil and tostring(room_zone) ~= "" then
        local ok_zone, err_zone = pcall(msg.post, "main:/camera#script", hash("register_room_zone"), {
            room_id = tostring(room_id),
            zone = room_zone,
        })
        if ok_zone then
            print(string.format("[TILED_ADAPTER] Applied map room_zone '%s' for room '%s'",
                tostring(room_zone), tostring(room_id)))
        else
            print(string.format("[TILED_ADAPTER] Failed to apply room_zone for room '%s': %s",
                tostring(room_id), tostring(err_zone)))
        end
    end
end

--- Check if a Tiled map exists for a room
-- @param room_id Room identifier
-- @return boolean True if Tiled map exists
function M.has_tiled_map(room_id)
    return TiledRegistry.has_room(room_id)
end

--- Load a room from Tiled export
-- @param room_id Room identifier
-- @param room_url URL of the loaded room collection
-- @param opts Optional table:
--   spawn_objects: bool (default true) - spawn object-layer game objects via ObjectSpawner
--   ignore_types: table<string,bool> - object types to ignore when spawning
-- @return boolean Success
function M.load_room(room_id, room_url, opts)
    if loaded_tiled_rooms[room_id] then
        print("[TILED_ADAPTER] Room already loaded:", room_id)
        return true
    end

    opts = opts or {}
    local spawn_objects = opts.spawn_objects
    if spawn_objects == nil then
        spawn_objects = true
    end

    if spawn_objects == false then
        local metadata = TiledRegistry.get_room_metadata(room_id)
        register_room_zone(room_id, metadata.authored_properties)
        loaded_tiled_rooms[room_id] = { parallax_layers = 0, objects_spawned = 0 }
        return true
    end

    local tiled_path = StreamPaths.tiled_map_lua(room_id)

    print(string.format("[TILED_ADAPTER] Loading Tiled room '%s' from '%s'", room_id, tiled_path))

    -- Load Tiled map data
    local map, err = TiledParser.load(tiled_path)
    if not map then
        print("[TILED_ADAPTER] Failed to load Tiled map:", err)
        return false
    end

    validate_required_layers(map)

    register_room_zone(room_id, map.properties)

    -- Baked rooms own scenery motion through their generated game objects.
    -- Only the legacy non-baked adapter path uses the room-wide manager.
    local parallax_count = 0
    if spawn_objects then
        -- Initialize parallax manager (once)
        if not parallax_initialized then
            local camera_url = C.URL.CAMERA
            if camera_url and go.exists(camera_url) then
                ParallaxManager.init(camera_url)
                parallax_initialized = true
            else
                print("[TILED_ADAPTER] Camera not ready, parallax will be set up later")
            end
        end

        -- Map bounds (clipping + anchor)
        local info = TiledParser.get_map_info(map)
        local map_width, map_height = 0, 0
        if info then
            map_width = info.width * info.tilewidth
            map_height = info.height * info.tileheight
            -- Clip rect must be in world space since the shader compares
            -- against world-space fragment positions.
            local origin = vmath.vector3(0, 0, 0)
            if room_url then
                local ok_pos, wp = pcall(go.get_world_position, room_url)
                if ok_pos and wp then origin = wp end
            end
            ParallaxManager.set_clip_rect({
                min_x = origin.x, min_y = origin.y,
                max_x = origin.x + map_width, max_y = origin.y + map_height,
            })
        end

        -- Setup parallax layers
        local parallax_layers = TiledParser.get_parallax_layers(map)
        parallax_count = #parallax_layers
        print(string.format("[TILED_ADAPTER] Found %d parallax layers", #parallax_layers))

        local bg_layers = get_background_layers(room_id)
        for _, layer in ipairs(parallax_layers) do
            ParallaxManager.create_layer(layer, nil)

            -- Try to find matching sprite in the room backgrounds
            local layer_meta = bg_layers and bg_layers[layer.name] or nil
            local base_component_id = layer_meta and layer_meta.base_component_id or nil
            local component_ids = layer_meta and layer_meta.component_ids or nil
            if base_component_id and base_component_id ~= "" then
                print(string.format("[TILED_ADAPTER] Layer '%s' repeat=(%s,%s) visual ids: %s | parallax base: %s",
                    tostring(layer.name),
                    tostring(layer.repeatx),
                    tostring(layer.repeaty),
                    (type(component_ids) == "table" and #component_ids > 0) and table.concat(component_ids, ", ") or "none",
                    tostring(base_component_id)))
                local sprite_url = msg.url(room_url, room_id .. "_backgrounds", base_component_id)
                ParallaxManager.register_sprite(layer.name, sprite_url)
                print(string.format("[TILED_ADAPTER]   Registered base sprite '%s' for: %s", tostring(base_component_id), layer.name))
            else
                print(string.format("[TILED_ADAPTER]   No sprite found for: %s (will use data only)", layer.name))
            end
        end

        -- Set parallax anchor from map bounds
        if info then
            local center = vmath.vector3(map_width / 2, map_height / 2, 0)
            ParallaxManager.set_anchor(center)
        end

    end

    -- Spawn objects from Tiled (optional; disable when room collections already bake objects)
    local spawned_count = 0
    if spawn_objects then
        local spawner_opts = nil
        if type(opts.ignore_types) == "table" then
            spawner_opts = { ignore_types = opts.ignore_types }
        end
        spawned_count = ObjectSpawner.process_map(map, tostring(room_id), nil, spawner_opts)
        print(string.format("[TILED_ADAPTER] Spawned %d objects", spawned_count))
    else
        print("[TILED_ADAPTER] Skipping object spawn (spawn_objects=false)")
    end

    -- Track this room
    loaded_tiled_rooms[room_id] = {
        parallax_layers = parallax_count,
        objects_spawned = spawned_count
    }

    print(string.format("[TILED_ADAPTER] Successfully loaded Tiled room '%s'", room_id))
    return true
end

--- Unload a Tiled room
-- @param room_id Room identifier
function M.unload_room(room_id)
    if not loaded_tiled_rooms[room_id] then
        return
    end

    print("[TILED_ADAPTER] Unloading Tiled room:", room_id)

    -- Clear objects
    ObjectSpawner.clear_room(tostring(room_id))

    -- Note: We don't clear parallax layers here because they might be shared
    -- The parallax manager handles layer lifecycle

    loaded_tiled_rooms[room_id] = nil
end

--- Per-frame hook kept for API compatibility. Parallax repositions from the
-- camera's CameraState publish hook (registered by ParallaxManager.init)
-- inside the camera's late_update, so there is nothing to do per frame here.
function M.update(_dt)
end

--- Initialize parallax when camera becomes available
function M.init_parallax()
    if parallax_initialized then
        return true
    end

    local camera_url = C.URL.CAMERA
    if not camera_url or not go.exists(camera_url) then
        return false
    end

    ParallaxManager.init(camera_url)
    parallax_initialized = true
    print("[TILED_ADAPTER] Parallax manager initialized")

    return true
end

--- Check if a room is loaded
-- @param room_id Room identifier
-- @return boolean
function M.is_loaded(room_id)
    return loaded_tiled_rooms[room_id] ~= nil
end

--- Get loaded room info
-- @param room_id Room identifier
-- @return table or nil
function M.get_room_info(room_id)
    return loaded_tiled_rooms[room_id]
end

--- Clear all loaded Tiled rooms
function M.clear_all()
    for room_id, _ in pairs(loaded_tiled_rooms) do
        M.unload_room(room_id)
    end

    ParallaxManager.clear_all()
    parallax_initialized = false

    print("[TILED_ADAPTER] Cleared all Tiled rooms")
end

--- Debug: Print loaded rooms
function M.debug_print()
    print("[TILED_ADAPTER] Loaded Tiled rooms:")
    for room_id, info in pairs(loaded_tiled_rooms) do
        print(string.format("  %s: %d parallax layers, %d objects",
            room_id, info.parallax_layers, info.objects_spawned))
    end

    if parallax_initialized then
        ParallaxManager.debug_print()
    end
end

return M

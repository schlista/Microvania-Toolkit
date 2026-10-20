--- Tiled Room Registry
-- Auto-discovers exported Tiled rooms from the configured Tiled maps directory.
-- Extracts metadata (biome, music, starting room) from Tiled exports
--
-- @module tiled_room_registry

local Util = require "mvtk.core.util"
local TiledParser = require "mvtk.tiled.tiled_parser"
local StreamPaths = require "mvtk.rooms.stream_paths"
local OP = require "mvtk.tiled.object_props"
local MusicSync = require "mvtk.audio.music_sync"
local RoomDiscovery = require "mvtk.tiled.room_discovery"
local WorldProperties = require "mvtk.tiled.world_properties"
local Debug = Util.require_config("developer.config.debug_config", { global = {}, gameplay = {} })

local M = {}

local TILED_MAPS_MODULE_PREFIX = StreamPaths.tiled_maps_module_prefix()

-- Load Config for spawn_room fallback
local ok_config, Config = pcall(require, "developer.config.resolved_config")
if not ok_config then Config = nil end
local ok_rooms_config, RoomsConfig = pcall(require, "developer.config.rooms_config")
if not ok_rooms_config or type(RoomsConfig) ~= "table" then
    RoomsConfig = { factories = {} }
end

-- Cache of discovered rooms
local room_cache = nil
local room_metadata_cache = nil
local starting_room_id = nil

-- Debug logging
local log = Util.make_debug_log("[TILED_REGISTRY]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.tiled)
end)

local function norm_token(v)
    if v == nil then return "" end
    local s = tostring(v):lower()
    s = s:gsub("[%s%-]+", "_")
    return s
end

local function is_true(v)
    if v == true then return true end
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then
        local s = norm_token(v)
        return s == "true" or s == "1" or s == "yes" or s == "on"
    end
    return false
end

local function normalize_room_id(room_id)
    return Util.normalize_room_id(room_id)
end

local function normalize_config_spawn_room()
    if not (Config and Config.player and Config.player.spawn_room) then
        return ""
    end
    return normalize_room_id(Config.player.spawn_room)
end

local function normalize_music_value(value)
    local kind = MusicSync.classify_music_value(value)
    if kind == "file" then
        return MusicSync.sanitize_track_id(value)
    end
    return value
end

local function layout_room_ids(layout_data)
    local ordered = {}
    local set = {}
    local rooms = nil

    if type(layout_data) == "table" then
        if type(layout_data.rooms) == "table" then
            rooms = layout_data.rooms
        else
            rooms = layout_data
        end
    end
    if type(rooms) ~= "table" then
        return ordered, set
    end

    local function add(id)
        if id ~= "" and not set[id] then
            set[id] = true
            ordered[#ordered + 1] = id
        end
    end

    for _, room in ipairs(rooms) do
        if type(room) == "table" then
            add(normalize_room_id(room.id))
            add(normalize_room_id(room.path))
        else
            add(normalize_room_id(room))
        end
    end

    return ordered, set
end

local function choose_starting_room(starting_candidates, metadata)
    if not starting_candidates or #starting_candidates == 0 then
        return nil
    end

    local config_room = normalize_config_spawn_room()
    if config_room ~= "" then
        local config_meta = metadata and metadata[config_room]
        if config_meta and config_meta.is_starting_room then
            return config_room
        end
    end

    table.sort(starting_candidates)
    return starting_candidates[1]
end

-- Process a single room module and extract metadata
local function process_room_module(room_id, result, rooms, metadata)
    log("Processing room:", room_id)

    -- Successfully loaded - this is a valid Tiled export
    local module_path = StreamPaths.tiled_map_module(room_id)
    rooms[room_id] = module_path

    -- Extract metadata from Tiled properties
    local props = result.properties or {}
    log("  Properties table:", props and "exists" or "nil")
    if props then
        for k, v in pairs(props) do
            log("    Property:", k, "=", tostring(v))
        end
    end

    local raw_music = OP.get(props, "music")
    local room_meta = {
        biome = OP.get(props, "biome"),
        music = normalize_music_value(raw_music),
        music_raw = raw_music,
        authored_properties = props,
        background_color = TiledParser.parse_color(result.backgroundcolor),
        is_starting_room =
            is_true(props.is_starting_room) or
            is_true(props.starting_room) or
            is_true(props.start_room),
    }

    log("  Initial is_starting_room from properties:", tostring(room_meta.is_starting_room))

    -- Always scan for player_start object to get exact spawn coordinates (player_start_x/y),
    -- even if the room is already flagged as starting_room from a map property.
    if result.layers then
        log("  Checking layers for player_start object...")
        log("  Number of layers:", #result.layers)

        for layer_idx, layer in ipairs(result.layers) do
            log("    Layer", layer_idx, ":", layer.name or "unnamed", "type:", layer.type or "unknown")

            if layer.type == "objectgroup" and layer.objects then
                log("      Object layer with", #layer.objects, "objects")

                for obj_idx, obj in ipairs(layer.objects) do
                    local obj_type_raw = ((obj.type ~= nil and obj.type ~= "") and obj.type) or obj.class or ""
                    local obj_name_raw = obj.name or ""
                    local obj_type = norm_token(obj_type_raw)
                    local obj_name = norm_token(obj_name_raw)
                    local obj_props = obj.properties or {}
                    local spawn_type = norm_token(obj_props.spawn_type)
                    local is_default = is_true(obj_props.is_default) or is_true(obj_props.default)
                    local checkpoint_id = norm_token(obj_props.checkpoint_id or obj_props.spawn_id)
                    local has_start_checkpoint = (checkpoint_id == "start" or checkpoint_id == "player_start")

                    log("        Object", obj_idx, ": name='" .. obj_name_raw .. "' type='" .. obj_type_raw .. "'")

                    -- Support multiple export styles:
                    -- - legacy object "type"
                    -- - newer class/name formatting ("Player Start")
                    -- - spawn point templates using properties (spawn_type/is_default)
                    local looks_like_player_start =
                        obj_type == "player_start" or
                        obj_name == "player_start" or
                        obj_type == "game_start" or
                        obj_name == "game_start" or
                        obj_type == "player_spawn" or
                        obj_name == "player_spawn" or
                        ((obj_type == "spawn_point" or obj_name == "spawn_point") and spawn_type == "player" and (is_default or has_start_checkpoint)) or
                        (spawn_type == "player" and is_default)

                    if looks_like_player_start then
                        log("        >>> FOUND player_start!")
                        -- Always print for spawn diagnostics
                        print(string.format("[SPAWN_DIAG][REGISTRY] FOUND player_start in room '%s': tiled_x=%.2f tiled_y=%.2f (obj name='%s' type='%s' spawn_type='%s' is_default=%s checkpoint_id='%s')",
                            tostring(room_id), obj.x or 0, obj.y or 0,
                            obj_name_raw, obj_type_raw, tostring(obj_props.spawn_type),
                            tostring(is_default), tostring(obj_props.checkpoint_id)))
                        room_meta.is_starting_room = true
                        room_meta.player_start_x = obj.x
                        room_meta.player_start_y = obj.y
                        break
                    end
                end
            end
            -- Only break early if we found the player_start coordinates
            if room_meta.player_start_x then break end
        end
    end

    log("  Final is_starting_room:", tostring(room_meta.is_starting_room))
    metadata[room_id] = room_meta

    return room_meta.is_starting_room and room_id or nil
end

-- Try to load a room by ID using sys.load_resource (like tiled_parser.lua does)
local function try_load_room(room_id)
    local file_path = StreamPaths.tiled_map_lua(room_id)
    log("Trying to load:", file_path)

    -- Method 1: Try sys.load_resource (works in Defold)
    local ok, resource_data = pcall(sys.load_resource, file_path)
    if ok and resource_data then
        log("  sys.load_resource succeeded, size:", #resource_data, "bytes")
        -- Execute the Lua code to get the map table
        local chunk, load_err = loadstring(resource_data)
        if chunk then
            local exec_ok, map_result = pcall(chunk)
            if exec_ok and type(map_result) == "table" then
                log("  SUCCESS - loaded", room_id)
                return map_result
            else
                log("  FAILED to execute chunk:", tostring(map_result))
            end
        else
            log("  FAILED to parse Lua:", tostring(load_err))
        end
    else
        log("  sys.load_resource failed:", tostring(resource_data))
    end

    -- Method 2: Fallback to require (in case it works in some environments)
    local module_path = StreamPaths.tiled_map_module(room_id)
    local req_ok, req_result = pcall(require, module_path)
    if req_ok and type(req_result) == "table" then
        log("  SUCCESS via require fallback")
        return req_result
    end

    log("  FAILED - could not load room")
    return nil
end

local function ensure_room_cached(room_id)
    local id = normalize_room_id(room_id)
    if id == "" then return nil end

    M.get_all_rooms()
    room_cache = room_cache or {}
    room_metadata_cache = room_metadata_cache or {}

    if room_metadata_cache[id] then
        return room_metadata_cache[id]
    end

    local result = try_load_room(id)
    if type(result) == "table" then
        process_room_module(id, result, room_cache, room_metadata_cache)
        return room_metadata_cache[id]
    end
    return nil
end

--- Get all available Tiled room exports
-- Scans the configured Tiled maps directory for .lua files and generates room_id -> module_path mappings.
-- @return Table of {room_id = "<configured module path>.<room_id>", ...}
function M.get_all_rooms()
    -- Built exports remain unchanged during gameplay. Expiring this cache
    -- reparsed every map on a room transition, causing a world-sized hitch.
    -- The layout editor's Rescan command explicitly calls refresh().
    if room_cache then
        log("Returning cached data")
        return room_cache
    end

    log("========== SCANNING FOR ROOMS ==========")

    local rooms = {}
    local metadata = {}
    local starting_candidates = {}
    local starting_seen = {}
    local function add_starting_candidate(room_id)
        if room_id and room_id ~= "" and not starting_seen[room_id] then
            starting_seen[room_id] = true
            starting_candidates[#starting_candidates + 1] = room_id
        end
    end

    -- Generated room wiring is the runtime authority. Defold game runtime has
    -- no supported cross-platform directory/process API, so discovery must use
    -- the config emitted by Project > Create Rooms.
    log("Method 1: Generated rooms_config...")
    local configured_ids = RoomDiscovery.configured_room_ids(RoomsConfig.factories)
    for _, room_id in ipairs(configured_ids) do
        if not rooms[room_id] then
            local result = try_load_room(room_id)
            if result then
                local starting = process_room_module(room_id, result, rooms, metadata)
                if starting then add_starting_candidate(starting) end
            end
        end
    end

    -- Method 2: Check package.loaded for explicitly preloaded/custom modules.
    -- This catches rooms that were loaded via require elsewhere
    log("Method 2: Checking package.loaded...")
    local loaded_prefix = "^" .. TILED_MAPS_MODULE_PREFIX:gsub("%.", "%%.") .. "%."
    for mod_name, _ in pairs(package.loaded) do
        if mod_name:match(loaded_prefix) then
            local room_id = mod_name:match(loaded_prefix .. "(.+)$")
            if room_id and not rooms[room_id] then
                log("  Found loaded module:", room_id)
                local result = package.loaded[mod_name]
                if type(result) == "table" then
                    local starting = process_room_module(room_id, result, rooms, metadata)
                    if starting then add_starting_candidate(starting) end
                end
            end
        end
    end

    -- Update cache
    room_cache = rooms
    room_metadata_cache = metadata
    starting_room_id = choose_starting_room(starting_candidates, metadata)

    local count = 0
    for _ in pairs(rooms) do count = count + 1 end

    log("========== SCAN COMPLETE ==========")
    log("Total rooms discovered:", count)
    log("Starting room:", starting_room_id or "(none)")

    if count > 0 then
        log("Room list:")
        for room_id, _ in pairs(rooms) do
            local meta = metadata[room_id] or {}
            log("  -", room_id, "(biome:", meta.biome or "none", ", starting:", tostring(meta.is_starting_room), ")")
        end
    else
        log("WARNING: No rooms discovered! Check that .lua files exist in tiled_maps_dir.")
    end

    return rooms
end

--- Get module path for a specific room
-- @param room_id Room identifier (e.g., "room_01", "room_1a")
-- @return Module path string or nil if not found
function M.get_room_path(room_id)
    if not room_id then return nil end

    local rooms = M.get_all_rooms()
    return rooms[normalize_room_id(room_id)]
end

--- Check if a room has a Tiled export
-- @param room_id Room identifier
-- @return true if room has Tiled data
function M.has_room(room_id)
    return M.get_room_path(room_id) ~= nil
end

--- Force refresh of room cache
function M.refresh()
    room_cache = nil
    room_metadata_cache = nil
    starting_room_id = nil
    return M.get_all_rooms()
end

--- Get list of all discovered room IDs
-- @return Array of room ID strings
function M.get_room_ids()
    local rooms = M.get_all_rooms()
    local ids = {}
    for id, _ in pairs(rooms) do
        table.insert(ids, id)
    end
    table.sort(ids)
    return ids
end

--- Manually register a custom room
-- Use this to add rooms with non-standard naming conventions
-- @param room_id Room identifier (e.g., "my_custom_room")
-- @param module_path Module path for the exported Tiled map
function M.register_room(room_id, module_path)
    if not room_id or not module_path then
        print("[TILED_REGISTRY] ERROR: Cannot register room - missing room_id or module_path")
        return false
    end

    -- Verify the module can be loaded
    local ok, result = pcall(require, module_path)
    if not ok or type(result) ~= "table" then
        print(string.format("[TILED_REGISTRY] ERROR: Cannot load module '%s': %s", module_path, tostring(result)))
        return false
    end

    -- Initialize cache if needed
    if not room_cache then
        room_cache = {}
    end

    room_cache[room_id] = module_path
    print(string.format("[TILED_REGISTRY] Manually registered room: %s -> %s", room_id, module_path))
    return true
end

--- Get metadata for a specific room (biome, music, is_starting_room)
-- @param room_id Room identifier
-- @return Table with metadata or empty table if not found
function M.get_room_metadata(room_id)
    if not room_id then return {} end

    local id = normalize_room_id(room_id)
    if id == "" then return {} end
    local meta = ensure_room_cached(id)
    if meta then
        local result = {}
        for key, value in pairs(meta) do result[key] = value end
        local world = WorldProperties.for_room(id)
        local props = WorldProperties.resolve(meta.authored_properties, world)
        result.biome = props.biome
        result.music_raw = props.music
        result.music = normalize_music_value(props.music)
        result.ambient_sound = props.ambient_sound
        -- Preserve legacy "none = keep playing" for worlds without this feature.
        result.world_music_enabled = world.default_music ~= nil and world.default_music ~= "" and world.default_music ~= "inherit"
        return result
    end
    return {}
end

--- Get the starting room ID (room with player_start or is_starting_room property)
-- @param layout_data Optional: layout table or rooms array. When provided,
--                    only rooms present in the layout are considered.
-- @return Room ID string or nil if no starting room found
function M.get_starting_room(layout_data)
    -- Ensure rooms are scanned
    M.get_all_rooms()

    local layout_ids, layout_set = layout_room_ids(layout_data)
    if #layout_ids > 0 then
        -- Primary: explicit starting room markers on rooms that are in this layout.
        for _, room_id in ipairs(layout_ids) do
            local meta = ensure_room_cached(room_id)
            if meta and meta.is_starting_room then
                return room_id
            end
        end

        -- Secondary: configured spawn room, if included in this layout.
        local config_room = normalize_config_spawn_room()
        if config_room ~= "" and layout_set[config_room] then
            local meta = ensure_room_cached(config_room)
            if meta then
                return config_room
            end
        end

        -- Last resort for layout-filtered queries: reuse cached global start if it belongs to this layout.
        local cached = normalize_room_id(starting_room_id)
        if cached ~= "" and layout_set[cached] then
            local meta = ensure_room_cached(cached)
            if meta then
                return cached
            end
        end

        return nil
    end

    -- If no global starting room found, fallback to Config.player.spawn_room.
    if not starting_room_id and Config and Config.player and Config.player.spawn_room then
        local config_room = normalize_config_spawn_room()
        log("No is_starting_room found, using Config.player.spawn_room:", config_room)
        if config_room ~= "" and ensure_room_cached(config_room) then
            starting_room_id = config_room
        end
    end

    return starting_room_id
end

--- Check if a room is the starting room
-- @param room_id Room identifier
-- @return true if this is the starting room
function M.is_starting_room(room_id)
    if not room_id then return false end
    local id = normalize_room_id(room_id)
    if id == "" then return false end

    local meta = ensure_room_cached(id)
    if meta and meta.is_starting_room then
        return true
    end

    local global_start = normalize_room_id(M.get_starting_room())
    return global_start ~= "" and global_start == id
end

--- Get all room metadata
-- @return Table of {room_id = {biome, music, is_starting_room}, ...}
function M.get_all_metadata()
    M.get_all_rooms()
    return room_metadata_cache or {}
end

return M

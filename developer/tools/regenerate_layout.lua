#!/usr/bin/env lua
-- developer/tools/regenerate_layout.lua
-- ============================================================================
-- MV Toolkit Layout Regeneration Script
-- Auto-regenerates room layout from Tiled exports.
-- Run this after adding new Tiled rooms to auto-update the manifest.
--
-- Usage:
--   lua developer/tools/regenerate_layout.lua
--   lua developer/tools/regenerate_layout.lua --maps-dir developer/assets/tiled/maps
--   lua developer/tools/regenerate_layout.lua --output developer/assets/layout.lua
-- ============================================================================

local lfs = require "lfs"
local H   = require "developer.tools.dev_helpers"
local Tile = require "developer.config.tile_settings"

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local DEFAULT_CONFIG = {
    -- Directory containing Tiled .lua exports
    maps_dir = "developer/assets/tiled/maps",
    
    -- Output layout file
    output_file = "developer/assets/layout.lua",
    
    -- Room manifest file (list of all rooms)
    manifest_file = "developer/config/rooms_manifest.lua",
    
    -- Tile size for position calculations
    tile_width = Tile.width or 128,
    tile_height = Tile.height or 128,

    -- Include these file patterns
    include_patterns = { "%.lua$" },
    
    -- Exclude files prefixed with an underscore (generator conventions).
    exclude_patterns = { "^_" },
}

-- ============================================================================
-- UTILITIES
-- ============================================================================

local function parse_args()
    local args = {}
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--maps-dir" then
            args.maps_dir = arg[i + 1]
            i = i + 1
        elseif a == "--output" then
            args.output_file = arg[i + 1]
            i = i + 1
        elseif a == "--manifest" then
            args.manifest_file = arg[i + 1]
            i = i + 1
        elseif a == "--tile-size" then
            local size = tonumber(arg[i + 1])
            if size then
                args.tile_width = size
                args.tile_height = size
            end
            i = i + 1
        elseif a == "--help" or a == "-h" then
            args.show_help = true
        elseif a == "--verbose" or a == "-v" then
            args.verbose = true
        end
        i = i + 1
    end
    return args
end

local function log(msg, verbose_only)
    if verbose_only and not CONFIG.verbose then return end
    print(msg)
end

-- ============================================================================
-- ROOM SCANNING
-- ============================================================================

local function should_include_file(filename)
    -- Check exclude patterns first
    for _, pattern in ipairs(CONFIG.exclude_patterns) do
        if filename:match(pattern) then
            return false
        end
    end
    
    -- Check include patterns
    for _, pattern in ipairs(CONFIG.include_patterns) do
        if filename:match(pattern) then
            return true
        end
    end
    
    return false
end

local function extract_room_id(filepath)
    -- Convert path to room ID
    -- developer/assets/tiled/maps/forest/room_01.lua -> forest/room_01
    local id = H.normalize_path(filepath)
    id = id:gsub("%.lua$", "")
    id = id:gsub("^.*/maps/", "")
    return id
end

local function extract_room_data(filepath, map_data)
    local room_id = extract_room_id(filepath)
    
    -- Calculate room bounds
    local width_tiles = map_data.width or 10
    local height_tiles = map_data.height or 10
    local tile_w = map_data.tilewidth or CONFIG.tile_width
    local tile_h = map_data.tileheight or CONFIG.tile_height
    
    local room = {
        id = room_id,
        file = filepath,
        width = width_tiles * tile_w,
        height = height_tiles * tile_h,
        width_tiles = width_tiles,
        height_tiles = height_tiles,
        tile_width = tile_w,
        tile_height = tile_h,
    }
    
    -- Extract custom properties from map
    if map_data.properties then
        for _, prop in ipairs(map_data.properties) do
            if type(prop) == "table" and prop.name then
                room[prop.name] = prop.value
            end
        end
        -- Also handle flat property format
        for key, val in pairs(map_data.properties) do
            if type(key) == "string" then
                room[key] = val
            end
        end
    end
    
    -- Extract connections from object layers
    room.connections = {}
    if map_data.layers then
        for _, layer in ipairs(map_data.layers) do
            if layer.type == "objectgroup" and layer.objects then
                for _, obj in ipairs(layer.objects) do
                    if obj.type == "door" or obj.type == "connection" then
                        local conn = {
                            target_room = obj.properties and obj.properties.target_room,
                            side = obj.properties and obj.properties.side,
                            x = obj.x,
                            y = obj.y,
                        }
                        if conn.target_room then
                            table.insert(room.connections, conn)
                        end
                    end
                end
            end
        end
    end
    
    return room
end

local function scan_directory(dir, rooms)
    rooms = rooms or {}
    
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            
            if attr then
                if attr.mode == "directory" then
                    -- Recurse into subdirectories
                    scan_directory(path, rooms)
                elseif attr.mode == "file" and should_include_file(entry) then
                    log(string.format("[SCAN] Found: %s", path), true)
                    
                    local map_data, map_err = H.load_tiled_map(path)
                    if not map_data and map_err then
                        log(string.format("[WARN] Failed to load %s: %s", path, map_err))
                    end
                    if map_data then
                        local room = extract_room_data(path, map_data)
                        table.insert(rooms, room)
                        log(string.format("[OK] Loaded room: %s (%dx%d tiles)",
                            room.id, room.width_tiles, room.height_tiles))
                    end
                end
            end
        end
    end
    
    return rooms
end

-- ============================================================================
-- LAYOUT GENERATION
-- ============================================================================

local function generate_layout_file(rooms)
    local lines = {
        "-- Auto-generated by regenerate_layout.lua",
        "-- DO NOT EDIT MANUALLY - changes will be overwritten",
        string.format("-- Generated: %s", os.date("%Y-%m-%d %H:%M:%S")),
        string.format("-- Total rooms: %d", #rooms),
        "",
        "return {",
        "    rooms = {",
    }
    
    -- Sort rooms by ID for consistent output
    table.sort(rooms, function(a, b) return a.id < b.id end)
    
    for _, room in ipairs(rooms) do
        table.insert(lines, string.format("        [\"%s\"] = {", room.id))
        table.insert(lines, string.format("            file = \"%s\",", room.file))
        table.insert(lines, string.format("            width = %d,", room.width))
        table.insert(lines, string.format("            height = %d,", room.height))
        table.insert(lines, string.format("            width_tiles = %d,", room.width_tiles))
        table.insert(lines, string.format("            height_tiles = %d,", room.height_tiles))
        
        -- Add connections if present
        if #room.connections > 0 then
            table.insert(lines, "            connections = {")
            for _, conn in ipairs(room.connections) do
                table.insert(lines, string.format("                { target = \"%s\", side = \"%s\" },",
                    conn.target_room, conn.side or "right"))
            end
            table.insert(lines, "            },")
        end
        
        table.insert(lines, "        },")
    end
    
    table.insert(lines, "    },")
    table.insert(lines, "}")
    table.insert(lines, "")
    
    return table.concat(lines, "\n")
end

local function generate_manifest_file(rooms)
    local lines = {
        "-- Auto-generated room manifest by regenerate_layout.lua",
        "-- Lists all room IDs for iteration/validation",
        string.format("-- Generated: %s", os.date("%Y-%m-%d %H:%M:%S")),
        "",
        "return {",
    }
    
    -- Sort rooms by ID
    table.sort(rooms, function(a, b) return a.id < b.id end)

    for _, room in ipairs(rooms) do
        table.insert(lines, string.format("    \"%s\",", room.id))
    end
    
    table.insert(lines, "}")
    table.insert(lines, "")
    
    return table.concat(lines, "\n")
end

-- ============================================================================
-- MAIN
-- ============================================================================

local function show_help()
    print([[
MV Toolkit Layout Regeneration Script

Usage:
    lua developer/tools/regenerate_layout.lua [options]

Options:
    --maps-dir <path>    Directory containing Tiled .lua exports
                         Default: developer/assets/tiled/maps
    
    --output <path>      Output layout file path
                         Default: developer/assets/layout.lua
    
    --manifest <path>    Output manifest file path
                         Default: developer/config/rooms_manifest.lua
    
    --tile-size <n>      Default tile size in pixels
                         Default: 128
    
    --verbose, -v        Show detailed output
    
    --help, -h           Show this help message

Examples:
    lua developer/tools/regenerate_layout.lua
    lua developer/tools/regenerate_layout.lua --maps-dir my_maps --verbose
]])
end

local function main()
    -- Parse command line arguments
    local args = parse_args()
    
    if args.show_help then
        show_help()
        return 0
    end
    
    -- Merge args with defaults
    CONFIG = {}
    for k, v in pairs(DEFAULT_CONFIG) do
        CONFIG[k] = args[k] or v
    end
    CONFIG.verbose = args.verbose
    
    log("==============================================")
    log("MV Toolkit Layout Regeneration")
    log("==============================================")
    log(string.format("Maps directory: %s", CONFIG.maps_dir))
    log(string.format("Output layout:  %s", CONFIG.output_file))
    log(string.format("Output manifest: %s", CONFIG.manifest_file))
    log("")
    
    -- Check if maps directory exists
    local attr = lfs.attributes(CONFIG.maps_dir)
    if not attr or attr.mode ~= "directory" then
        print(string.format("[ERROR] Maps directory not found: %s", CONFIG.maps_dir))
        return 1
    end
    
    -- Scan for rooms
    log("[SCAN] Scanning for Tiled maps...")
    local rooms = scan_directory(CONFIG.maps_dir)
    
    if #rooms == 0 then
        print("[WARN] No rooms found!")
        return 1
    end
    
    log("")
    log(string.format("[OK] Found %d rooms", #rooms))
    
    -- Generate layout file
    log("[GEN] Generating layout file...")
    local layout_content = generate_layout_file(rooms)
    local ok, err = H.write_file(CONFIG.output_file, layout_content)
    if not ok then
        print(string.format("[ERROR] Failed to write layout: %s", err))
        return 1
    end
    log(string.format("[OK] Wrote layout to: %s", CONFIG.output_file))
    
    -- Generate manifest file
    log("[GEN] Generating manifest file...")
    local manifest_content = generate_manifest_file(rooms)
    ok, err = H.write_file(CONFIG.manifest_file, manifest_content)
    if not ok then
        print(string.format("[ERROR] Failed to write manifest: %s", err))
        return 1
    end
    log(string.format("[OK] Wrote manifest to: %s", CONFIG.manifest_file))
    
    log("")
    log("==============================================")
    log("Layout regeneration complete!")
    log(string.format("  Rooms: %d", #rooms))
    
    log("==============================================")
    
    return 0
end

os.exit(main())

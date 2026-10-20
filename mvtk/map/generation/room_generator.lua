-- mvtk/map/generation/room_generator.lua
-- Procedural room layout generation utilities

local Util = require "mvtk.core.util"
local Tile = Util.require_config("developer.config.tile_settings")

local M = {}

local rng_seeded = false

local function mix_entropy(base)
    local entropy = base or os.time()
    local addr = tostring({}):match("0x(%x+)")
    if addr then
        entropy = entropy + tonumber(addr, 16)
    end
    return entropy
end

local function seed_rng(seed)
    if seed then
        math.randomseed(seed)
        rng_seeded = true
        return
    end
    if not rng_seeded then
        math.randomseed(mix_entropy(os.time()))
        -- Warm the RNG to avoid low-order correlations after seeding
        math.random()
        math.random()
        math.random()
        rng_seeded = true
    end
end

local ROOM_MIN_WIDTH = 15
local ROOM_MAX_WIDTH = 35
local ROOM_MIN_HEIGHT = 10
local ROOM_MAX_HEIGHT = 25

local TILE_SIZE = Tile.width

local ROOM_TYPES = {
    normal = {
        width_range = {15, 25},
        height_range = {10, 18},
        connection_count = {2, 4},
        special_features = 0.1
    },
    large = {
        width_range = {25, 35},
        height_range = {18, 25},
        connection_count = {3, 5},
        special_features = 0.2
    },
    corridor = {
        width_range = {8, 12},
        height_range = {6, 10},
        connection_count = {2, 3},
        special_features = 0.05
    },
    arena = {
        width_range = {20, 30},
        height_range = {15, 25},
        connection_count = {1, 2},
        special_features = 0.3
    },
    treasure = {
        width_range = {12, 18},
        height_range = {8, 15},
        connection_count = {1, 2},
        special_features = 0.8
    }
}

local BIOMES = {
    forest = {
        wall_tiles = {1, 2, 3},
        floor_tiles = {10, 11},
        decoration_chance = 0.15,
        hazard_chance = 0.05
    },
    cave = {
        wall_tiles = {4, 5, 6},
        floor_tiles = {12, 13},
        decoration_chance = 0.08,
        hazard_chance = 0.10
    },
    ruins = {
        wall_tiles = {7, 8, 9},
        floor_tiles = {14, 15},
        decoration_chance = 0.20,
        hazard_chance = 0.07
    }
}

function M.init(seed)
    seed_rng(seed)
    print("[ROOM_GENERATOR] Room generator initialized")
end

function M.generate_room(room_type, biome, seed)
    room_type = room_type or "normal"
    biome = biome or "forest"
    
    seed_rng(seed)
    
    local room_config = ROOM_TYPES[room_type] or ROOM_TYPES.normal
    local biome_config = BIOMES[biome] or BIOMES.forest
    
    -- Generate room dimensions
    local width = math.random(room_config.width_range[1], room_config.width_range[2])
    local height = math.random(room_config.height_range[1], room_config.height_range[2])
    
    -- Create base room structure
    local room_data = {
        type = room_type,
        biome = biome,
        width = width,
        height = height,
        world_width = width * TILE_SIZE,
        world_height = height * TILE_SIZE,
        tiles = {},
        entities = {},
        connections = {},
        features = {}
    }
    
    -- Initialize tile grid
    for y = 1, height do
        room_data.tiles[y] = {}
        for x = 1, width do
            room_data.tiles[y][x] = M.get_base_tile(x, y, width, height, biome_config)
        end
    end
    
    -- Add special features
    M.add_room_features(room_data, room_config, biome_config)
    
    -- Generate connection points
    M.generate_connection_points(room_data, room_config)
    
    print(string.format("[ROOM_GENERATOR] Generated %s room (%dx%d) in %s biome", 
        room_type, width, height, biome))
    
    return room_data
end

function M.get_base_tile(x, y, width, height, biome_config)
    -- Walls around the perimeter
    if x == 1 or x == width or y == 1 or y == height then
        return biome_config.wall_tiles[math.random(#biome_config.wall_tiles)]
    else
        -- Interior floor
        return biome_config.floor_tiles[math.random(#biome_config.floor_tiles)]
    end
end

function M.add_room_features(room_data, room_config, biome_config)
    local feature_chance = room_config.special_features
    
    -- Add decorative elements
    if math.random() < biome_config.decoration_chance then
        M.add_decorations(room_data, biome_config)
    end
    
    -- Add hazards
    if math.random() < biome_config.hazard_chance then
        M.add_hazards(room_data, biome_config)
    end
    
    -- Add special room features based on type
    if room_data.type == "arena" then
        M.add_arena_features(room_data)
    elseif room_data.type == "treasure" then
        M.add_treasure_features(room_data)
    elseif room_data.type == "large" then
        M.add_large_room_features(room_data)
    end
end

function M.add_decorations(room_data, biome_config)
    local decoration_count = math.random(2, 5)
    
    for i = 1, decoration_count do
        local x = math.random(3, room_data.width - 2)
        local y = math.random(3, room_data.height - 2)
        
        -- Only place on floor tiles
        if room_data.tiles[y][x] and room_data.tiles[y][x] >= 10 then
            table.insert(room_data.features, {
                type = "decoration",
                x = x,
                y = y,
                world_x = (x - 1) * TILE_SIZE,
                world_y = (y - 1) * TILE_SIZE,
                variant = math.random(1, 3)
            })
        end
    end
end

function M.add_hazards(room_data, biome_config)
    local hazard_count = math.random(1, 3)
    
    for i = 1, hazard_count do
        local x = math.random(3, room_data.width - 2)
        local y = math.random(3, room_data.height - 2)
        
        table.insert(room_data.entities, {
            type = "hazard",
            subtype = room_data.biome == "cave" and "spikes" or "thorns",
            x = x,
            y = y,
            world_x = (x - 1) * TILE_SIZE,
            world_y = (y - 1) * TILE_SIZE
        })
    end
end

function M.add_arena_features(room_data)
    -- Central platform
    local center_x = math.floor(room_data.width / 2)
    local center_y = math.floor(room_data.height / 2)
    
    table.insert(room_data.features, {
        type = "platform",
        x = center_x,
        y = center_y,
        world_x = (center_x - 1) * TILE_SIZE,
        world_y = (center_y - 1) * TILE_SIZE,
        size = "large"
    })
    
    -- Enemy spawn points
    local spawn_points = {
        {x = 3, y = 3},
        {x = room_data.width - 2, y = 3},
        {x = 3, y = room_data.height - 2},
        {x = room_data.width - 2, y = room_data.height - 2}
    }
    
    for _, point in ipairs(spawn_points) do
        table.insert(room_data.entities, {
            type = "enemy_spawn",
            x = point.x,
            y = point.y,
            world_x = (point.x - 1) * TILE_SIZE,
            world_y = (point.y - 1) * TILE_SIZE,
            enemy_type = "arena_fighter"
        })
    end
end

function M.add_treasure_features(room_data)
    -- Central treasure chest
    local center_x = math.floor(room_data.width / 2)
    local center_y = math.floor(room_data.height / 2)
    
    table.insert(room_data.entities, {
        type = "treasure_chest",
        x = center_x,
        y = center_y,
        world_x = (center_x - 1) * TILE_SIZE,
        world_y = (center_y - 1) * TILE_SIZE,
        treasure_tier = "rare"
    })
    
    -- Guardian enemies
    local guard_positions = {
        {x = center_x - 2, y = center_y},
        {x = center_x + 2, y = center_y}
    }
    
    for _, pos in ipairs(guard_positions) do
        table.insert(room_data.entities, {
            type = "enemy_spawn",
            x = pos.x,
            y = pos.y,
            world_x = (pos.x - 1) * TILE_SIZE,
            world_y = (pos.y - 1) * TILE_SIZE,
            enemy_type = "treasure_guardian"
        })
    end
end

function M.add_large_room_features(room_data)
    -- Multiple platforms
    local platform_count = math.random(2, 4)
    
    for i = 1, platform_count do
        local x = math.random(4, room_data.width - 3)
        local y = math.random(4, room_data.height - 3)
        
        table.insert(room_data.features, {
            type = "platform",
            x = x,
            y = y,
            world_x = (x - 1) * TILE_SIZE,
            world_y = (y - 1) * TILE_SIZE,
            size = "medium"
        })
    end
    
    -- Scattered enemies
    local enemy_count = math.random(3, 6)
    
    for i = 1, enemy_count do
        local x = math.random(3, room_data.width - 2)
        local y = math.random(3, room_data.height - 2)
        
        table.insert(room_data.entities, {
            type = "enemy_spawn",
            x = x,
            y = y,
            world_x = (x - 1) * TILE_SIZE,
            world_y = (y - 1) * TILE_SIZE,
            enemy_type = "patrol_guard"
        })
    end
end

function M.generate_connection_points(room_data, room_config)
    local connection_count = math.random(room_config.connection_count[1], room_config.connection_count[2])
    local sides = {"north", "south", "east", "west"}
    
    -- Shuffle sides to randomize connection placement
    for i = #sides, 2, -1 do
        local j = math.random(i)
        sides[i], sides[j] = sides[j], sides[i]
    end
    
    for i = 1, math.min(connection_count, #sides) do
        local side = sides[i]
        local connection = M.generate_connection_for_side(room_data, side)
        
        if connection then
            table.insert(room_data.connections, connection)
        end
    end
end

function M.generate_connection_for_side(room_data, side)
    local width, height = room_data.width, room_data.height
    local connection = {
        side = side,
        type = "door"
    }
    
    if side == "north" then
        connection.x = math.random(3, width - 2)
        connection.y = height
        connection.world_x = (connection.x - 1) * TILE_SIZE
        connection.world_y = (height - 1) * TILE_SIZE
    elseif side == "south" then
        connection.x = math.random(3, width - 2)
        connection.y = 1
        connection.world_x = (connection.x - 1) * TILE_SIZE
        connection.world_y = 0
    elseif side == "east" then
        connection.x = width
        connection.y = math.random(3, height - 2)
        connection.world_x = (width - 1) * TILE_SIZE
        connection.world_y = (connection.y - 1) * TILE_SIZE
    elseif side == "west" then
        connection.x = 1
        connection.y = math.random(3, height - 2)
        connection.world_x = 0
        connection.world_y = (connection.y - 1) * TILE_SIZE
    end
    
    return connection
end

function M.generate_layout(room_count, seed)
    room_count = room_count or 10
    seed_rng(seed)
    
    print(string.format("[ROOM_GENERATOR] Generating layout with %d rooms", room_count))
    
    local layout = {
        rooms = {},
        connections = {}
    }
    
    -- Generate rooms with different types and biomes
    local biomes = {"forest", "cave", "ruins"}
    local room_types = {"normal", "normal", "normal", "large", "corridor", "arena", "treasure"}
    
    for i = 1, room_count do
        local room_id = string.format("gen_room_%02d", i)
        local room_type = room_types[math.random(#room_types)]
        local biome = biomes[math.random(#biomes)]
        
        local room_data = M.generate_room(room_type, biome)
        room_data.id = room_id
        
        -- Position rooms in a rough grid pattern
        local grid_size = math.ceil(math.sqrt(room_count))
        local grid_x = ((i - 1) % grid_size)
        local grid_y = math.floor((i - 1) / grid_size)
        
        room_data.grid_x = grid_x
        room_data.grid_y = grid_y
        room_data.world_pos_x = grid_x * (room_data.world_width + 500)
        room_data.world_pos_y = grid_y * (room_data.world_height + 500)
        
        layout.rooms[room_id] = room_data
    end
    
    -- Generate connections between adjacent rooms
    M.generate_layout_connections(layout)
    
    print(string.format("[ROOM_GENERATOR] Generated layout complete: %d rooms, %d connections", 
        room_count, #layout.connections))
    
    return layout
end

function M.generate_layout_connections(layout)
    local added_pairs = {}
    for room_id, room_data in pairs(layout.rooms) do
        -- Connect to adjacent rooms in grid
        local adjacent_rooms = M.get_adjacent_rooms(layout, room_data)
        
        for _, adjacent in ipairs(adjacent_rooms) do
            local a = tostring(room_id)
            local b = tostring(adjacent.id)
            local key
            if a <= b then
                key = a .. "::" .. b
            else
                key = b .. "::" .. a
            end

            if not added_pairs[key] then
                added_pairs[key] = true
                local connection = {
                    room_a = room_id,
                    room_b = adjacent.id,
                    side_a = adjacent.side_a,
                    side_b = adjacent.side_b,
                    type = "door"
                }
                
                table.insert(layout.connections, connection)
            end
        end
    end
end

function M.get_adjacent_rooms(layout, room_data)
    local adjacent = {}
    local grid_x, grid_y = room_data.grid_x, room_data.grid_y
    
    -- Check all four directions
    local directions = {
        {dx = 0, dy = 1, side_a = "north", side_b = "south"},  -- North
        {dx = 0, dy = -1, side_a = "south", side_b = "north"}, -- South
        {dx = 1, dy = 0, side_a = "east", side_b = "west"},    -- East
        {dx = -1, dy = 0, side_a = "west", side_b = "east"}    -- West
    }
    
    for _, dir in ipairs(directions) do
        local check_x = grid_x + dir.dx
        local check_y = grid_y + dir.dy
        
        -- Find room at this grid position
        for other_id, other_data in pairs(layout.rooms) do
            if other_data.grid_x == check_x and other_data.grid_y == check_y then
                -- Only connect if both rooms have availability on the connecting sides
                if M.can_connect_rooms(room_data, other_data, dir.side_a, dir.side_b) then
                    table.insert(adjacent, {
                        id = other_id,
                        side_a = dir.side_a,
                        side_b = dir.side_b
                    })
                end
                break
            end
        end
    end
    
    return adjacent
end

function M.can_connect_rooms(room_a, room_b, side_a, side_b)
    -- Check if rooms have available connection points on these sides
    local has_connection_a = false
    local has_connection_b = false
    
    for _, conn in ipairs(room_a.connections or {}) do
        if conn.side == side_a then
            has_connection_a = true
            break
        end
    end
    
    for _, conn in ipairs(room_b.connections or {}) do
        if conn.side == side_b then
            has_connection_b = true
            break
        end
    end
    
    return has_connection_a and has_connection_b
end

function M.layout_to_save_format(layout)
    local save_data = {
        version = "1.0.0",
        rooms = {}
    }
    
    for room_id, room_data in pairs(layout.rooms) do
        local save_room = {
            id = room_id,
            x = room_data.world_pos_x or 0,
            y = room_data.world_pos_y or 0,
            w = room_data.world_width or 0,
            h = room_data.world_height or 0,
            ox = 0, -- SW bounds offset
            oy = 0,
            neighbors = {}
        }
        
        -- Add neighbor connections
        for _, connection in ipairs(layout.connections) do
            if connection.room_a == room_id then
                table.insert(save_room.neighbors, {
                    id = connection.room_b,
                    side = connection.side_a
                })
            elseif connection.room_b == room_id then
                table.insert(save_room.neighbors, {
                    id = connection.room_a,
                    side = connection.side_b
                })
            end
        end
        
        table.insert(save_data.rooms, save_room)
    end
    
    return save_data
end

return M

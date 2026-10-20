--- Room-Specific Collectible Placement Configuration
-- Define collectibles to spawn in specific rooms
-- Alternative to tilemap placement for more control
--
-- This file is optional - you can use:
-- 1. Tilemap placement (visual in Tiled editor)
-- 2. This config file (for precise control)
-- 3. Both (config adds to tilemap collectibles)
--
-- @module room_collectibles

return {
    --[[
    Example room configuration:

    room_01 = {
        {
            type = "health_container",
            position = {x = 200, y = 128},
            id = "health_container_room_01_01",  -- Unique ID for persistence
        },
        {
            type = "relic_ancient_sword",
            position = {x = 350, y = 96},
            id = "relic_sword_room_01",
            -- Optional: override collectible_types.lua defaults
            config = {
                relic_name = "Rusty Blade",  -- Custom name
                description = "A weathered sword...",
            }
        },
        {
            type = "map_piece_forest",
            position = {x = 150, y = 160},
            id = "map_forest_room_01",
        },
    },

    room_02 = {
        {
            type = "energy_container",
            position = {x = 180, y = 100},
            id = "energy_container_room_02_01",
        },
        {
            type = "key_red",
            position = {x = 250, y = 80},
            id = "key_red_room_02",
        },
    },

    secret_room_01 = {
        {
            type = "relic_crystal_shard",
            position = {x = 120, y = 96},
            id = "relic_crystal_secret_01",
        },
        {
            type = "health_container",
            position = {x = 180, y = 96},
            id = "health_container_secret_01",
        },
    },

    boss_room_01 = {
        {
            type = "health_container",
            position = {x = 100, y = 64},
            id = "health_container_boss_room_pre",
            -- Health pickup before boss fight
        },
        {
            type = "key_boss",
            position = {x = 200, y = 128},
            id = "key_boss_room_01",
            -- Appears after defeating boss
            config = {
                requires_flag = "boss_01_defeated",
            }
        },
    },
    ]]

    -- Your room collectible configurations go here
    -- Leave empty to use only tilemap placement
}

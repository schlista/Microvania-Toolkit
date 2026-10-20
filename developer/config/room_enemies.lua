--- Room-Specific Enemy Placement Configuration
-- Define enemies to spawn in specific rooms
-- Alternative to tilemap placement for more control
--
-- This file is optional - you can use:
-- 1. Tilemap placement (visual in Tiled editor)
-- 2. This config file (for precise control)
-- 3. Both (config adds to tilemap enemies)
--
-- @module room_enemies

return {
    --[[
    Example room configuration:

    room_01 = {
        {
            enemy_type = "slime",
            position = {x = 100, y = 64},
            -- Optional: override enemy_types.lua defaults
            config = {
                speed = 60,  -- Faster than default
                health = 5,  -- More health
            }
        },
        {
            enemy_type = "bat",
            position = {x = 200, y = 128},
        },
    },

    room_02 = {
        {
            enemy_type = "charger",
            position = {x = 150, y = 64},
        },
        {
            enemy_type = "spike_roller",
            position = {x = 300, y = 64},
        },
    },

    boss_room_01 = {
        {
            enemy_type = "mini_boss_guardian",
            position = {x = 200, y = 128},
            config = {
                health = 50,  -- Boss has more health
                damage = 3,
                drops = {
                    currency = {min = 50, max = 100, chance = 1.0},
                    health_large = {chance = 1.0},
                    item_ability_dash = {chance = 1.0},  -- Guaranteed ability drop
                }
            }
        },
    },
    ]]

    -- Your room enemy configurations go here
    -- Leave empty to use only tilemap placement
}

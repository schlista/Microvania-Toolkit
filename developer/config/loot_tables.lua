--- Loot Tables Configuration
-- Defines loot drops for chests and other containers
-- Referenced by chest_id or loot_table property in Tiled
--
-- Each loot table contains:
--   items: array of { type, amount, chance }
--     type: collectible type from collectible_types.lua
--     amount: number of items to spawn (default: 1)
--     chance: probability 0.0-1.0 (default: 1.0)
--
-- @module loot_tables

return {
    -- Common chest loot
    common = {
        items = {
            { type = "gem_small", amount = 3, chance = 1.0 },
            { type = "health_small", chance = 0.3 },
        }
    },
    
    -- Uncommon chest loot
    uncommon = {
        items = {
            { type = "gem_medium", amount = 2, chance = 1.0 },
            { type = "gem_small", amount = 5, chance = 0.5 },
            { type = "health_small", chance = 0.5 },
            { type = "energy_small", chance = 0.3 },
        }
    },
    
    -- Rare chest loot
    rare = {
        items = {
            { type = "gem_large", amount = 1, chance = 1.0 },
            { type = "gem_medium", amount = 3, chance = 0.7 },
            { type = "health_medium", chance = 0.5 },
        }
    },
    
    -- Key chest (contains a key)
    key_red = {
        items = {
            { type = "key_red", amount = 1, chance = 1.0 },
        }
    },
    
    key_blue = {
        items = {
            { type = "key_blue", amount = 1, chance = 1.0 },
        }
    },
    
    key_boss = {
        items = {
            { type = "key_boss", amount = 1, chance = 1.0 },
        }
    },
    
    -- Map piece chest
    map_forest = {
        items = {
            { type = "map_piece_forest", amount = 1, chance = 1.0 },
            { type = "gem_medium", amount = 2, chance = 1.0 },
        }
    },
    
    -- Ability upgrade chest
    ability = {
        items = {
            -- Ability type should be set via chest properties
            { type = "gem_large", amount = 1, chance = 1.0 },
        }
    },
    
    -- Health upgrade chest
    health_upgrade = {
        items = {
            { type = "health_container", amount = 1, chance = 1.0 },
        }
    },
    
    -- Energy upgrade chest
    energy_upgrade = {
        items = {
            { type = "energy_container", amount = 1, chance = 1.0 },
        }
    },
    
    -- Empty (already looted or trap)
    empty = {
        items = {}
    },
    
    -- Currency only
    currency = {
        items = {
            { type = "gem_small", amount = 10, chance = 1.0 },
        }
    },
    
    -- Currency large
    currency_large = {
        items = {
            { type = "gem_large", amount = 1, chance = 1.0 },
            { type = "gem_medium", amount = 3, chance = 1.0 },
        }
    },
}

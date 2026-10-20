--- Collectible Type Definitions
-- Defines all collectible types available in the game
-- Each type specifies behavior, visuals, audio, and rewards
--
-- Ability pickups are auto-generated from abilities.lua at the bottom of this file
--
-- @module collectible_types

local collectible_types = {
    --[[========================================================================
        CONSUMABLES (Health/Energy Pickups)
    ========================================================================]]

    health_small = {
        category = "consumable",
        name = "Small Health",
        description = "Restores a small amount of health",

        animation = "health_small",
        glow = false,

        audio = {
            collect = "/sound#health_pickup",
        },

        on_collect = "restore_health",
        value = 5,

        notification = nil,  -- No notification for small pickups
        popup_duration = 0,
        show_in_collection = false,

        respawns = true,  -- Respawns
        respawn_time = 60,
    },

    health_medium = {
        category = "consumable",
        name = "Medium Health",
        description = "Restores a moderate amount of health",

        animation = "health_medium",
        glow = true,
        glow_color = {r = 1.0, g = 0.4, b = 0.4, a = 1.0},

        audio = {
            collect = "/sound#health_pickup",
        },

        on_collect = "restore_health",
        value = 10,

        notification = nil,
        popup_duration = 0,
        show_in_collection = false,

        respawns = true,
        respawn_time = 90,
    },

    health_large = {
        category = "consumable",
        name = "Large Health",
        description = "Restores a large amount of health",

        animation = "health_large",
        glow = true,
        glow_color = {r = 1.0, g = 0.3, b = 0.3, a = 1.0},

        audio = {
            collect = "/sound#health_pickup",
        },

        on_collect = "restore_health",
        value = 20,

        notification = nil,
        popup_duration = 0,
        show_in_collection = false,

        respawns = true,
        respawn_time = 120,
    },

    energy_small = {
        category = "consumable",
        name = "Small Energy",
        description = "Restores a small amount of energy",

        animation = "energy_small",
        glow = false,

        audio = {
            collect = "/sound#energy_pickup",
        },

        on_collect = "restore_energy",
        value = 5,

        notification = nil,
        popup_duration = 0,
        show_in_collection = false,

        respawns = true,
        respawn_time = 60,
    },

    energy_large = {
        category = "consumable",
        name = "Large Energy",
        description = "Restores a large amount of energy",

        animation = "energy_large",
        glow = true,
        glow_color = {r = 0.3, g = 0.5, b = 1.0, a = 1.0},

        audio = {
            collect = "/sound#energy_pickup",
        },

        on_collect = "restore_energy",
        value = 20,

        notification = nil,
        popup_duration = 0,
        show_in_collection = false,

        respawns = true,
        respawn_time = 120,
    },

    --[[========================================================================
        CURRENCY
    ========================================================================]]

    currency = {
        category = "currency",
        name = "Coin",
        description = "Currency used to buy items",

        animation = "currency",
        glow = false,

        audio = {
            collect = "/sound#coin_pickup",
        },

        on_collect = "add_currency",
        currency_type = "gold",
        value = 1,

        notification = nil,
        popup_duration = 0,
        show_in_collection = false,

        respawns = true,  -- Coins respawn
        respawn_time = 300,
    },

    currency_large = {
        category = "currency",
        name = "Large Coin",
        description = "A valuable pile of currency",

        animation = "currency_large",
        glow = true,
        glow_color = {r = 1.0, g = 0.85, b = 0.2, a = 1.0},

        audio = {
            collect = "/sound#coin_pickup",
        },

        on_collect = "add_currency",
        currency_type = "gold",
        value = 50,

        notification = "Currency +50",
        popup_duration = 1.5,
        show_in_collection = false,

        respawns = true,
        respawn_time = 300,
    },

    --[[========================================================================
        GEMS (Valuable Currency)
    ========================================================================]]

    gem_red = {
        category = "currency",
        name = "Red Gem",
        description = "A valuable red gemstone",

        animation = "gem_red",
        glow = true,
        glow_color = {r = 1.0, g = 0.2, b = 0.2, a = 1.0},

        audio = {
            collect = "/sound#gem_collect",
        },

        on_collect = "add_currency",
        currency_type = "gems",
        value = 25,

        notification = "Gem +25",
        popup_duration = 1.5,
        show_in_collection = false,

        minimap_icon = "gem",
        minimap_color = {r = 1.0, g = 0.2, b = 0.2},
    },

    gem_green = {
        category = "currency",
        name = "Green Gem",
        description = "A valuable green gemstone",

        animation = "gem_green",
        glow = true,
        glow_color = {r = 0.2, g = 1.0, b = 0.2, a = 1.0},

        audio = {
            collect = "/sound#gem_collect",
        },

        on_collect = "add_currency",
        currency_type = "gems",
        value = 100,

        notification = "Gem +100",
        popup_duration = 1.5,
        show_in_collection = false,

        minimap_icon = "gem",
        minimap_color = {r = 0.2, g = 1.0, b = 0.2},
    },

    gem_blue = {
        category = "currency",
        name = "Blue Gem",
        description = "A valuable blue gemstone",

        animation = "gem_blue",
        glow = true,
        glow_color = {r = 0.2, g = 0.5, b = 1.0, a = 1.0},

        audio = {
            collect = "/sound#gem_collect",
        },

        on_collect = "add_currency",
        currency_type = "gems",
        value = 50,

        notification = "Gem +50",
        popup_duration = 1.5,
        show_in_collection = false,

        minimap_icon = "gem",
        minimap_color = {r = 0.2, g = 0.5, b = 1.0},
    },

    --[[========================================================================
        KEYS (Generic)
    ========================================================================]]

    key = {
        category = "key",
        name = "Key",
        description = "Opens locked doors and chests",

        animation = "key",
        glow = true,
        glow_color = {r = 1.0, g = 0.8, b = 0.0, a = 1.0},

        audio = {
            collect = "/sound#key_found",
        },

        on_collect = "add_to_inventory",
        item_id = "key",

        notification = "Key obtained!",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "key",
        minimap_color = {r = 1.0, g = 0.8, b = 0.0},
    },

    --[[========================================================================
        PERMANENT UPGRADES
    ========================================================================]]

    health_container = {
        category = "upgrade",
        name = "Health Container",
        description = "Increases maximum health by 1",

        -- Visual
        animation = "health_container",
        glow = true,  -- Add glowing particle effect
        glow_color = {r = 1.0, g = 0.2, b = 0.2, a = 1.0},  -- Red glow

        -- Audio
        audio = {
            collect = "/sound#health_upgrade",
            ambient = "/sound#item_hum",  -- Looping ambient sound
        },

        -- Behavior
        on_collect = "increase_max_health",
        value = 1,  -- Amount to increase

        -- UI
        notification = "Max Health +1!",
        popup_duration = 3.0,
        show_in_collection = false,  -- Don't show in collection menu

        -- Minimap
        minimap_icon = "health_container",
        minimap_color = {r = 1.0, g = 0.2, b = 0.2},
    },

    energy_container = {
        category = "upgrade",
        name = "Energy Container",
        description = "Increases maximum energy by 10",

        animation = "energy_container",
        glow = true,
        glow_color = {r = 0.2, g = 0.5, b = 1.0, a = 1.0},  -- Blue glow

        audio = {
            collect = "/sound#energy_upgrade",
            ambient = "/sound#item_hum",
        },

        on_collect = "increase_max_energy",
        value = 10,

        notification = "Max Energy +10!",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "energy_container",
        minimap_color = {r = 0.2, g = 0.5, b = 1.0},
    },

    stamina_vessel = {
        category = "upgrade",
        name = "Stamina Vessel",
        description = "Increases maximum stamina",

        animation = "stamina_vessel",
        glow = true,
        glow_color = {r = 0.2, g = 1.0, b = 0.2, a = 1.0},  -- Green glow

        audio = {
            collect = "/sound#stamina_upgrade",
            ambient = "/sound#item_hum",
        },

        on_collect = "increase_max_stamina",
        value = 1,

        notification = "Max Stamina +1!",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "stamina_vessel",
        minimap_color = {r = 0.2, g = 1.0, b = 0.2},
    },

    health_upgrade = {
        category = "upgrade",
        name = "Health Upgrade",
        description = "Increases maximum health",

        animation = "health_upgrade",
        glow = true,
        glow_color = {r = 1.0, g = 0.3, b = 0.3, a = 1.0},

        audio = {
            collect = "/sound#health_upgrade",
            ambient = "/sound#item_hum",
        },

        on_collect = "increase_max_health",
        value = 1,

        notification = "Max Health +1!",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "health_container",
        minimap_color = {r = 1.0, g = 0.2, b = 0.2},
    },

    charm_slot = {
        category = "upgrade",
        name = "Charm Slot",
        description = "Adds a charm slot",

        animation = "charm_slot",
        glow = true,
        glow_color = {r = 0.9, g = 0.8, b = 0.3, a = 1.0},

        audio = {
            collect = "/sound#item_hum",
        },

        on_collect = "add_to_inventory",
        item_id = "charm_slot",

        notification = "Charm Slot +1",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "relic",
        minimap_color = {r = 0.9, g = 0.8, b = 0.3},
    },

    --[[========================================================================
        MAP & PROGRESSION ITEMS
    ========================================================================]]

    map_piece_forest = {
        category = "progression",
        name = "Forest Map",
        description = "Reveals the Ancient Forest on your map",

        animation = "map_piece_forest",
        glow = true,
        glow_color = {r = 1.0, g = 1.0, b = 0.5, a = 1.0},  -- Yellow glow

        audio = {
            collect = "/sound#map_found",
        },

        on_collect = "reveal_map_area",
        area_id = "forest",
        area_name = "Ancient Forest",

        notification = "Map Updated: Ancient Forest",
        popup_duration = 4.0,
        show_in_collection = false,

        minimap_icon = "map_piece",
        minimap_color = {r = 1.0, g = 1.0, b = 0.5},
    },

    map_piece_caves = {
        category = "progression",
        name = "Cave Map",
        description = "Reveals the Cave System on your map",

        animation = "map_piece_caves",
        glow = true,
        glow_color = {r = 0.6, g = 0.4, b = 0.2, a = 1.0},

        audio = {
            collect = "/sound#map_found",
        },

        on_collect = "reveal_map_area",
        area_id = "caves",
        area_name = "Crystal Caves",

        notification = "Map Updated: Crystal Caves",
        popup_duration = 4.0,
        show_in_collection = false,

        minimap_icon = "map_piece",
        minimap_color = {r = 0.6, g = 0.4, b = 0.2},
    },

    map_piece_castle = {
        category = "progression",
        name = "Castle Map",
        description = "Reveals the Dark Castle on your map",

        animation = "map_piece_castle",
        glow = true,
        glow_color = {r = 0.5, g = 0.0, b = 0.8, a = 1.0},

        audio = {
            collect = "/sound#map_found",
        },

        on_collect = "reveal_map_area",
        area_id = "castle",
        area_name = "Dark Castle",

        notification = "Map Updated: Dark Castle",
        popup_duration = 4.0,
        show_in_collection = false,

        minimap_icon = "map_piece",
        minimap_color = {r = 0.5, g = 0.0, b = 0.8},
    },

    map_fragment = {
        category = "progression",
        name = "Map Fragment",
        description = "Reveals nearby rooms on the map",

        animation = "map_fragment",
        glow = true,
        glow_color = {r = 1.0, g = 1.0, b = 0.6, a = 1.0},

        audio = {
            collect = "/sound#map_found",
        },

        on_collect = "reveal_nearby",
        reveal_radius = 1600,

        notification = "Map Updated",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "map_piece",
        minimap_color = {r = 1.0, g = 1.0, b = 0.5},
    },

    --[[========================================================================
        KEYS & STORY ITEMS
    ========================================================================]]

    key_red = {
        category = "key",
        name = "Red Key",
        description = "Opens red doors",

        animation = "key_red",
        glow = true,
        glow_color = {r = 1.0, g = 0.0, b = 0.0, a = 1.0},

        audio = {
            collect = "/sound#key_found",
        },

        on_collect = "add_to_inventory",
        item_id = "key_red",

        notification = "Red Key obtained!",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "key",
        minimap_color = {r = 1.0, g = 0.0, b = 0.0},
    },

    key_blue = {
        category = "key",
        name = "Blue Key",
        description = "Opens blue doors",

        animation = "key_blue",
        glow = true,
        glow_color = {r = 0.0, g = 0.5, b = 1.0, a = 1.0},

        audio = {
            collect = "/sound#key_found",
        },

        on_collect = "add_to_inventory",
        item_id = "key_blue",

        notification = "Blue Key obtained!",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "key",
        minimap_color = {r = 0.0, g = 0.5, b = 1.0},
    },

    key_gold = {
        category = "key",
        name = "Gold Key",
        description = "Opens ornate gold doors",

        sprite = "/developer/assets/atlas/collectibles/keys.atlas",
        animation = "gold",
        glow = true,
        glow_color = {r = 1.0, g = 0.75, b = 0.1, a = 1.0},

        audio = {
            collect = "/sound#key_found",
        },

        on_collect = "add_to_inventory",
        item_id = "key_gold",

        notification = "Gold Key obtained!",
        popup_duration = 3.0,
        show_in_collection = false,

        minimap_icon = "key",
        minimap_color = {r = 1.0, g = 0.75, b = 0.1},
    },

    key_boss = {
        category = "key",
        name = "Boss Key",
        description = "Opens the door to the final boss",

        animation = "key_boss",
        glow = true,
        glow_color = {r = 1.0, g = 0.8, b = 0.0, a = 1.0},

        audio = {
            collect = "/sound#boss_key_found",
        },

        on_collect = "add_to_inventory",
        item_id = "key_boss",

        notification = "Boss Key obtained!",
        popup_duration = 4.0,
        show_in_collection = false,

        minimap_icon = "key_boss",
        minimap_color = {r = 1.0, g = 0.8, b = 0.0},
    },

    upgrade_material = {
        category = "material",
        name = "Upgrade Material",
        description = "A crafting material for upgrades",

        animation = "upgrade_material",
        glow = true,
        glow_color = {r = 0.8, g = 0.9, b = 1.0, a = 1.0},

        audio = {
            collect = "/sound#coin_pickup",
        },

        on_collect = "add_to_inventory",
        item_id = "upgrade_material",

        notification = "Material Acquired",
        popup_duration = 2.0,
        show_in_collection = false,

        minimap_icon = "relic",
        minimap_color = {r = 0.6, g = 0.8, b = 1.0},
    },

    --[[========================================================================
        RELICS & COLLECTIBLES (100% Completion)
    ========================================================================]]
    --
    -- HOW TO RECORD A RELIC PICKUP WITH A FLAG:
    --
    -- Use a custom on_collect function to call Flags.set("relic_found", true).
    -- Dialogue and gates can check this flag to react to the collected relic.
    -- In Tiled, place a collectible template and select the custom type here.
    --

    relic = {
        category = "relic",
        name = "Relic",
        description = "A mysterious relic from a forgotten age",

        animation = "relic",
        glow = true,
        glow_color = {r = 0.9, g = 0.8, b = 0.5, a = 1.0},

        audio = {
            collect = "/sound#relic_found",
        },

        on_collect = "add_to_collection",
        relic_id = "relic_generic",

        notification = "Relic Found",
        popup_duration = 4.0,
        show_in_collection = true,
        collection_number = 0,

        minimap_icon = "relic",
        minimap_color = {r = 0.9, g = 0.8, b = 0.5},
    },

    relic_ancient_sword = {
        category = "relic",
        name = "Ancient Sword",
        description = "A legendary blade from the Old Kingdom. Its edge still gleams despite centuries of slumber.",

        animation = "relic_ancient_sword",
        glow = true,
        glow_color = {r = 0.8, g = 0.8, b = 1.0, a = 1.0},

        audio = {
            collect = "/sound#relic_found",
        },

        on_collect = "add_to_collection",
        relic_id = "ancient_sword",

        notification = "Relic Found: Ancient Sword",
        popup_duration = 5.0,
        show_in_collection = true,
        collection_number = 1,

        minimap_icon = "relic",
        minimap_color = {r = 1.0, g = 0.8, b = 0.0},
    },

    relic_crystal_shard = {
        category = "relic",
        name = "Crystal Shard",
        description = "A fragment of pure crystal energy. It pulses with an otherworldly light.",

        animation = "relic_crystal_shard",
        glow = true,
        glow_color = {r = 0.5, g = 0.8, b = 1.0, a = 1.0},

        audio = {
            collect = "/sound#relic_found",
        },

        on_collect = "add_to_collection",
        relic_id = "crystal_shard",

        notification = "Relic Found: Crystal Shard",
        popup_duration = 5.0,
        show_in_collection = true,
        collection_number = 2,

        minimap_icon = "relic",
        minimap_color = {r = 0.5, g = 0.8, b = 1.0},
    },

    relic_golden_chalice = {
        category = "relic",
        name = "Golden Chalice",
        description = "An ornate chalice once used in royal ceremonies. Still bears ancient inscriptions.",

        animation = "relic_golden_chalice",
        glow = true,
        glow_color = {r = 1.0, g = 0.8, b = 0.0, a = 1.0},

        audio = {
            collect = "/sound#relic_found",
        },

        on_collect = "add_to_collection",
        relic_id = "golden_chalice",

        notification = "Relic Found: Golden Chalice",
        popup_duration = 5.0,
        show_in_collection = true,
        collection_number = 3,

        minimap_icon = "relic",
        minimap_color = {r = 1.0, g = 0.8, b = 0.0},
    },

    -- -------------------------------------------------------------------------
    -- STORY RELIC EXAMPLE: Hermit Medal
    --
    -- This keepsake records the Desert Hermit's lost medal in the collection.
    -- It uses the same pickup feedback and collection display as other relics.
    --
    -- To use in Tiled:
    --   - Place a collectible template on the top-level templates layer
    --   - Set collectible_type = relic_hermit
    --   - Picking it up adds the Hermit Medal to the player's collection
    -- -------------------------------------------------------------------------
    relic_hermit = {
        category = "relic",
        name = "Hermit Medal",
        description = "The weathered medal the Desert Hermit lost in the ruined spires above the dunes.",

        sprite = "/developer/assets/atlas/collectibles/relics.atlas",
        animation = "sword",
        glow = true,
        glow_color = {r = 0.9, g = 0.8, b = 0.5, a = 1.0},

        audio = {
            collect = "/sound#relic_found",
        },

        on_collect = "add_to_collection",
        relic_id = "hermit",

        notification = "Relic Found: Hermit Medal",
        popup_duration = 4.0,
        show_in_collection = true,
        collection_number = 4,

        minimap_icon = "relic",
        minimap_color = {r = 0.9, g = 0.8, b = 0.5},
    },

    relic_coyote = {
        category = "relic",
        name = "Coyote Heart",
        description = "A talisman cherished by the Desert Coyote, lost somewhere in the old sandstone ruins.",

        sprite = "/developer/assets/atlas/collectibles/relics.atlas",
        animation = "sword",
        glow = true,
        glow_color = {r = 1.0, g = 0.55, b = 0.45, a = 1.0},

        audio = {
            collect = "/sound#relic_found",
        },

        on_collect = "add_to_collection",
        relic_id = "coyote",

        notification = "Relic Found: Coyote Heart",
        popup_duration = 4.0,
        show_in_collection = true,
        collection_number = 5,

        minimap_icon = "relic",
        minimap_color = {r = 1.0, g = 0.55, b = 0.45},
    },

    --[[========================================================================
        LORE TABLETS
    ========================================================================]]

    lore_item = {
        category = "lore",
        name = "Lore Item",
        description = "Unlocks a lore entry",

        animation = "lore_item",
        glow = false,

        audio = {
            collect = "/sound#lore_found",
        },

        on_collect = "unlock_lore_entry",
        lore_id = "lore_entry",
        lore_text = "An ancient inscription awaits discovery...",

        notification = "Lore Entry Unlocked!",
        popup_duration = 2.5,
        show_in_collection = false,

        minimap_icon = "lore",
        minimap_color = {r = 0.8, g = 0.8, b = 0.8},
    },

    lore_tablet_origins = {
        category = "lore",
        name = "Tablet of Origins",
        description = "An ancient stone tablet inscribed with the history of this land.",

        animation = "lore_tablet_origins",
        glow = true,
        glow_color = {r = 0.6, g = 0.6, b = 0.6, a = 1.0},

        audio = {
            collect = "/sound#lore_found",
        },

        on_collect = "unlock_lore_entry",
        lore_id = "origins",
        lore_text = "In the beginning, the land was forged by the Ancient Ones...",

        notification = "Lore Discovered: Origins",
        popup_duration = 4.0,
        show_in_collection = true,

        minimap_icon = "lore",
        minimap_color = {r = 0.8, g = 0.8, b = 0.8},
    },

    --[[========================================================================
        GEMS (Size Variants for Loot Tables)
    ========================================================================]]

    gem_small = {
        category = "currency",
        name = "Small Gem",
        description = "A small valuable gemstone",

        animation = "gem_small",
        glow = false,

        audio = {
            collect = "/sound#gem_collect",
        },

        on_collect = "add_currency",
        currency_type = "gems",
        value = 5,

        notification = nil,
        popup_duration = 0,
        show_in_collection = false,

        respawns = true,
    },

    gem_medium = {
        category = "currency",
        name = "Medium Gem",
        description = "A medium-sized valuable gemstone",

        animation = "gem_medium",
        glow = true,
        glow_color = {r = 0.6, g = 0.3, b = 0.9, a = 1.0},

        audio = {
            collect = "/sound#gem_collect",
        },

        on_collect = "add_currency",
        currency_type = "gems",
        value = 15,

        notification = nil,
        popup_duration = 0,
        show_in_collection = false,

        respawns = true,
    },

    gem_large = {
        category = "currency",
        name = "Large Gem",
        description = "A valuable gemstone",

        animation = "gem_large",
        glow = true,
        glow_color = {r = 0.5, g = 0.0, b = 1.0, a = 1.0},

        audio = {
            collect = "/sound#gem_collect",
        },

        on_collect = "add_currency",
        currency_type = "gems",
        value = 50,

        notification = "Gem +50",
        popup_duration = 1.5,
        show_in_collection = false,

        minimap_icon = "gem",
        minimap_color = {r = 0.5, g = 0.0, b = 1.0},
    },
}

--[[========================================================================
    AUTO-GENERATE ABILITY PICKUPS FROM abilities.lua

    This reads the ability definitions from abilities.lua and creates
    collectible pickup entries automatically. No need to manually define
    ability pickups - they are generated based on the source of truth.
========================================================================]]

-- Default glow colors per ability category
local category_colors = {
    movement = {r = 0.5, g = 1.0, b = 0.5, a = 1.0},   -- Green
    combat = {r = 1.0, g = 0.3, b = 0.3, a = 1.0},     -- Red
    defensive = {r = 0.3, g = 0.7, b = 1.0, a = 1.0},  -- Blue
    utility = {r = 0.8, g = 0.3, b = 1.0, a = 1.0},    -- Purple
}

local default_color = {r = 0.9, g = 0.8, b = 0.3, a = 1.0}  -- Gold fallback
local ability_icon_pool = {
    "xbox_a",
    "xbox_b",
    "xbox_x",
    "xbox_y",
    "xbox_lb",
    "xbox_rb",
    "xbox_lt",
    "xbox_rt",
    "xbox_menu",
    "xbox_view",
    "ps_cross",
    "ps_circle",
    "ps_square",
    "ps_triangle",
    "ps_l1",
    "ps_r1",
    "ps_l2",
    "ps_r2",
    "ps_options",
    "ps_share",
}

-- Try to load abilities config
local ok, ability_config = pcall(require, "developer.config.abilities")
if ok and ability_config and ability_config.abilities then
    local ordered_ability_ids = {}
    for ability_id in pairs(ability_config.abilities) do
        ordered_ability_ids[#ordered_ability_ids + 1] = ability_id
    end
    table.sort(ordered_ability_ids)

    for idx, ability_id in ipairs(ordered_ability_ids) do
        local ability_data = ability_config.abilities[ability_id]
        local key = "ability_" .. ability_id
        local glow_color = category_colors[ability_data.category] or default_color
        local minimap_color = {r = glow_color.r, g = glow_color.g, b = glow_color.b}
        local icon = ability_icon_pool[((idx - 1) % #ability_icon_pool) + 1]

        collectible_types[key] = {
            category = "ability",
            name = ability_data.name,
            description = ability_data.description,

            -- Visual: use the gameplay visuals atlas which has ability-specific animations
            -- (ability_double_jump, ability_air_dash, etc.) built in.
            sprite = "/developer/assets/atlas/gameplay_visuals.atlas",
            animation = "ability_" .. ability_id,
            glow = true,
            glow_color = glow_color,

            -- Audio
            audio = {
                collect = "/sound#ability_found",
                ambient = "/sound#item_hum",
            },

            -- Behavior
            on_collect = "unlock_ability",
            ability_id = ability_id,

            -- UI
            notification = "Ability Unlocked: " .. ability_data.name .. "!",
            show_popup = true,
            popup_title = ability_data.name,
            popup_description = ability_data.description,
            popup_duration = 4.0,
            show_in_collection = false,

            -- Minimap
            minimap_icon = "ability",
            minimap_color = minimap_color,
        }
    end
end

return collectible_types

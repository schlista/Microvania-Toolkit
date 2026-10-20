--- Secret Rooms and Hidden Areas Configuration
-- Define secret rooms, breakable walls, and hidden passages
--
-- @module secret_rooms
-- Runtime concealment policy (world scenery, world map and minimap):
--   room_id: exported room name, with or without developer/rooms/.
--   hidden_on_map: true keeps the entire room and its markers concealed,
--     including map stations/fragments and games with ordinary fog disabled.
--   hidden_in_world: true also conceals the room's scenery and gameplay objects
--     until its entrance flag unlocks. Resources may preload, but the baked room
--     collection is created only after unlock. Defaults false; map-only secrets
--     keep their normal scenery. Uses the same durable flag as hidden_on_map.
--   wall_id: the authored breakable wall's wall_id; breaking that wall unlocks
--     this room using the wall's existing persistent checkpoint flag.
--   reveal_flag: optional explicit flag name; overrides wall_id when supplied.
--     Without either field the flag defaults to "secret_" .. this entry's key.
--   reveal_on_unlock: defaults true (show the room on both maps when the wall
--     breaks). Set false to allow ordinary map exploration after unlock. This
--     does not delay the actual scenery once hidden_in_world is unlocked.
--   map_padding: optional nonnegative world pixels on left/right/top/bottom of
--     the concealed room. Extend only toward a hidden entrance to cover a door
--     line painted inside the neighboring room's map. Missing sides default 0.
-- Multiple entries for one room represent alternative entrances; any one opens
-- visibility in each opted-in domain. Wall/secret flags are saved with the active
-- save slot, so broken entrances stay open and their rooms stay visible on load.
-- Other fields below describe authoring intent; they do not spawn gameobjects.

local Tile = require "developer.config.tile_settings"

return {
    --[[========================================================================
        EXAMPLE SECRET ROOM CONFIGURATIONS
    ========================================================================]]

    --[[
    -- Example 1: Secret room behind breakable wall
    secret_waterfall_cave = {
        room_id = "secret_01",
        type = "hidden_room",
        entrance_type = "breakable_wall",
        entrance_position = {x = 150, y = 96},
        entrance_room = "room_05",  -- Which room the entrance is in

        -- Breakable wall config
        wall_config = {
            wall_type = "cracked",  -- "cracked", "subtle", "invisible", "bomb_only"
            health = 3,
            required_ability = nil,  -- nil = any attack, or "bomb", "power_beam", etc.
        },

        -- Map behavior
        hidden_on_map = true,  -- Don't show until discovered
        completion_bonus = 5,  -- Extra % for finding

        -- Contents
        contains = {
            "health_container_secret_01",
            "relic_waterfall_gem",
        },
    },

    -- Example 2: Secret behind bomb wall
    secret_ancient_chamber = {
        room_id = "secret_02",
        type = "hidden_room",
        entrance_type = "breakable_wall",
        entrance_position = {x = 250, y = 80},
        entrance_room = "room_12",

        wall_config = {
            wall_type = "bomb_only",
            health = 1,  -- One bomb destroys it
            required_ability = "bomb",
        },

        hidden_on_map = true,
        completion_bonus = 10,

        contains = {
            "relic_ancient_tome",
            "energy_container_secret_02",
            "lore_tablet_ancient_ones",
        },
    },

    -- Example 3: Hidden passage (no wall, just secret entrance)
    secret_underwater_tunnel = {
        room_id = "secret_03",
        type = "hidden_passage",
        entrance_type = "hidden_door",
        entrance_position = {x = 180, y = 64},
        entrance_room = "room_08",

        -- Requires ability to access
        required_ability = "swim",

        hidden_on_map = true,
        completion_bonus = 8,

        contains = {
            "map_piece_underwater",
            "key_blue_secret",
        },
    },

    -- Example 4: Illusory wall (walk through)
    secret_illusion_chamber = {
        room_id = "secret_04",
        type = "hidden_room",
        entrance_type = "illusory_wall",
        entrance_position = {x = 200, y = 100},
        entrance_room = "room_15",

        -- Wall appears solid but player can walk through
        wall_config = {
            wall_type = "invisible",
            tangible = false,  -- Can walk through
            visible = true,  -- Looks like normal wall
        },

        hidden_on_map = true,
        completion_bonus = 15,  -- Hard to find!

        contains = {
            "relic_phantom_crystal",
            "health_container_secret_04",
        },
    },

    -- Example 5: Secret room with multiple entrances
    secret_hub_chamber = {
        room_id = "secret_05",
        type = "hidden_room",
        hidden_on_map = true,
        completion_bonus = 20,

        -- Multiple entrances
        entrances = {
            {
                type = "breakable_wall",
                position = {x = 100, y = 96},
                entrance_room = "room_10",
                wall_config = {wall_type = "cracked", health = 3},
            },
            {
                type = "hidden_door",
                position = {x = 300, y = 128},
                entrance_room = "room_14",
                required_ability = "wall_climb",
            },
        },

        contains = {
            "relic_golden_idol",
            "stamina_vessel_secret",
            "gem_large_1",
            "gem_large_2",
        },
    },
    ]]

    --[[========================================================================
        BREAKABLE WALL STANDALONE DEFINITIONS
        (Walls that don't lead to secret rooms, just shortcuts/paths)
    ========================================================================]]

    --[[
    -- Example: Shortcut wall
    wall_shortcut_forest_to_cave = {
        type = "breakable_wall",
        position = {x = 180, y = 80},
        room_id = "room_03",

        wall_config = {
            wall_type = "cracked",
            health = 3,
        },

        -- What breaking it does
        on_break = function()
            -- Opens shortcut between two areas
            print("Shortcut opened!")
        end,
    },

    -- Example: Bomb-required wall
    wall_explosive_barrier = {
        type = "breakable_wall",
        position = {x = 220, y = 96},
        room_id = "room_07",

        wall_config = {
            wall_type = "bomb_only",
            health = 1,
            required_ability = "bomb",
        },
    },
    ]]

    --[[========================================================================
        ILLUSORY PLATFORM DEFINITIONS
    ========================================================================]]

    --[[
    -- Example: Invisible platform
    platform_hidden_path = {
        type = "illusory_platform",
        position = {x = 150, y = 120},
        room_id = "room_06",

        platform_config = {
            visible = false,  -- Invisible
            tangible = true,  -- Can stand on it
            required_ability = "reveal",  -- Need "reveal" ability to see it
            auto_reveal_distance = 30,  -- Auto-reveal when player is this close
        },

        -- Could lead to collectible
        nearby_collectible = "health_container_hidden_platform",
    },

    -- Example: False floor (looks solid but falls through)
    platform_false_floor = {
        type = "illusory_platform",
        position = {x = 200, y = 64},
        room_id = "room_11",

        platform_config = {
            visible = true,  -- Looks like normal floor
            tangible = false,  -- Falls through!
            -- No ability requirement - it's a trap/puzzle
        },
    },
    ]]

    --[[========================================================================
        YOUR SECRET CONFIGURATIONS
    ========================================================================]]

    -- Add your secret rooms, breakable walls, and hidden areas here
}

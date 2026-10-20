-- developer/config/camera_zones.lua
-- Camera zone configurations for different room types
-- Define custom camera behavior for specific rooms or areas

local M = {}

-- Named camera zones selected by a Tiled map's room_zone property.
M.zones = {
    -- Lanternfall: caves of 64 px tiles on 2048 x 1152 px world cells (one
    -- screen each). The camera follows the explorer and stops at the room's
    -- edges, so the scrolling drives the parallax and the vignette stays
    -- centred on the torch-bearer.
    lanternfall_room = {
        lock_camera = false, -- Follow the explorer across multi-screen caves.
        clamp_to_room = true, -- Stop at the room's edges; never show past the rock.
        auto_fit = false, -- Keep one consistent scale in every biome.
        zoom_level = 0.95, -- Slightly wider than 1:1 so the ceilings stay in view for the grapple.
        bounds_padding = 0, -- Clamp exactly to the room's edges.
        allow_look_around = false, -- Up/Down reels the grapple rope; the view must not drift.
        smooth_transition = false, -- Adopt the destination room's camera on entry.
    },
    -- Aureole: wide, shallow halls reveal ceiling routes while scrolling east/west.
    aureole_room = {
        lock_camera = false, -- Follow the explorer across each 2560px hall.
        clamp_to_room = true, -- Stop at the room's authored bounds.
        auto_fit = false, -- Keep one consistent scale between all four biomes.
        zoom_level = 1.35, -- Show the 768px vault and floor together on a 1080px display.
        bounds_padding = 0, -- Use the exact painted room edges.
        allow_look_around = false, -- Up/Down reels the rope without camera drift.
        smooth_transition = false, -- Adopt the destination room's camera on entry.
    },
    -- Crystal Cavern: native 60 x 34 rooms made from 16px tiles.
    cavern_screen = {
        -- Show the current 960 x 544 room as a single centered screen.
        lock_camera = true,
        -- Use an exact pixel-art magnification instead of fitting each room.
        auto_fit = false,
        -- Enlarge the native art by two for the 1920 x 1080 display.
        zoom_level = 2.0,
        -- Include the full authored room border in the camera area.
        bounds_padding = 0,
        -- Ladder input keeps the screen centered on the current room.
        allow_look_around = false,
        -- Apply the room camera immediately on entering its painted door.
        smooth_transition = false,
    },

    -- Ice cavern: one 60 x 34 room of 32 px tiles fills a 1920 x 1080 view.
    -- The room is 1920 x 1088 px, so its outer border is cropped by 4 px
    -- at the top and bottom while each tile keeps its exact 32 px size.
    ice_screen = {
        -- Center on the current room rather than following the player.
        lock_camera = true,
        -- Keep the configured zoom instead of scaling to fit room height.
        auto_fit = false,
        -- Multiply the project's default zoom (1.0) by this amount.
        zoom_level = 1.0,
        -- Add no extra inset or border to the room's camera area.
        bounds_padding = 0,
        -- Holding up/down must keep the full room centered.
        allow_look_around = false,
        -- Apply this room's camera settings when the player enters it.
        smooth_transition = false,
    },

    -- Emberfall: 64 px tiles; rooms are one or two 30 x 17 tile screens.
    -- The camera follows the player and stops at the room edges, so a
    -- one-screen room stays still while halls and shafts scroll.
    emberfall_room = {
        -- Follow the player instead of pinning the room center.
        lock_camera = false,
        -- Keep the configured zoom instead of scaling to fit the room.
        auto_fit = false,
        -- Multiply the project's default zoom (1.0): one tile = 64 px on screen.
        zoom_level = 1.0,
        -- Clamp exactly to the room's edges; no extra inset.
        bounds_padding = 0,
        -- Holding up/down on ladders must not shift the view.
        allow_look_around = false,
        -- Apply this room's camera immediately when entering its door.
        smooth_transition = false,
    },

    -- Inkreach: hand-drawn rooms of 64 px tiles, each larger than one screen
    -- (2-3 world cells of 1280 x 768 px). The camera follows the player and
    -- stops at the room edges; that scrolling is what drives the painted
    -- parallax backgrounds and foregrounds.
    inkreach_room = {
        -- Follow the player instead of pinning the room center.
        lock_camera = false,
        -- Stop the view at the room's painted edges (no empty space beyond).
        clamp_to_room = true,
        -- Keep the configured zoom instead of scaling to fit the room.
        auto_fit = false,
        -- Multiply the project's default zoom (1.0): one tile = 64 px on screen.
        zoom_level = 1.0,
        -- Clamp exactly to the room's edges; no extra inset.
        bounds_padding = 0,
        -- Holding up/down on ladders must not shift the view.
        allow_look_around = false,
        -- Apply this room's camera immediately when entering its door.
        smooth_transition = false,
    },

    -- Starting area - comfortable exploration
    micro_start_room = {
        type = "exploration",
        deadzone = vmath.vector3(80, 40, 0),
        speed = vmath.vector3(4.0, 4.0, 0),
        lookahead = 100,
        allow_look_around = true
    },

    -- Boss arena - tight tracking
    boss_arena_1 = {
        type = "boss_arena",
        deadzone = vmath.vector3(200, 150, 0),
        speed = vmath.vector3(8.0, 8.0, 0),
        lookahead = 0,
        lock_camera = false,  -- Set to true to completely lock
        allow_look_around = false
    },

    -- Platforming challenge - tight vertical tracking
    vertical_shaft = {
        type = "platforming",
        deadzone = vmath.vector3(60, 80, 0),
        speed = vmath.vector3(5.0, 6.0, 0),
        lookahead = 120,
        allow_look_around = true
    },

    -- Tight corridor
    narrow_passage = {
        type = "tight_corridor",
        deadzone = vmath.vector3(40, 20, 0),
        speed = vmath.vector3(6.0, 6.0, 0),
        lookahead = 80,
        allow_look_around = true
    },

    -- Cutscene room
    story_room = {
        type = "cutscene",
        deadzone = vmath.vector3(1000, 1000, 0),
        speed = vmath.vector3(2.0, 2.0, 0),
        lookahead = 0,
        allow_look_around = false
    }
}

-- Register zones with room IDs
-- Format: room_id = zone_config or zone_type_string
M.room_zones = {
    -- Examples (replace with your actual room IDs)
    ["room_start"] = "exploration",
    ["room_boss_1"] = "boss_arena",
    ["room_vertical_1"] = "platforming",
    ["room_corridor_1"] = "tight_corridor",
    ["room_cutscene_1"] = "cutscene",

    -- You can also use custom configs inline
    ["room_special"] = {
        deadzone = vmath.vector3(100, 50, 0),
        speed = vmath.vector3(5.0, 5.0, 0),
        lookahead = 150,
        allow_look_around = true,
        smooth_transition = true
    }
}

return M

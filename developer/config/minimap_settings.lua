-- developer/config/minimap_settings.lua
-- Minimap UI settings.

local Tile = require "developer.config.tile_settings"
local TILE_PX = Tile.width or 128  -- used for tile-relative pixel distances

local M = {
    enabled = true, -- Show the panel minimap; full-map visibility is independent.
    -- panel
    size_px   = { w = 200, h = 200 },   -- minimap size in pixels
    margin_px = 40,                     -- distance from screen edges
    panel_offset_px = { x = 0, y = 0 }, -- fine-tune panel position (pixels)
    anchor    = "top_right",            -- reserved (we place at top-right)
    alignment = "center",               -- align panel relative to anchor
    map_world_offset_px = { x = 0, y = 0 }, -- align minimap sprite to world coords

    -- colors (vmath.vector4 r,g,b,a) 0..1
    bg_rgba        = vmath.vector4(0.00, 0.00, 0.00, 0.55),  -- soft overlay to match world map panel
    frame_rgba     = vmath.vector4(0.80, 0.93, 0.99, 0.95),  -- light blue outline like world map
    frame_px       = 4,                 -- frame border thickness for normal minimap mode
    frame_px_fullscreen = 4,            -- consistent thickness when delegating fullscreen to world map

    -- Room style (match layout editor)
    room_outline   = vmath.vector4(0.80, 0.93, 0.99, 1.00), -- light blue
    room_fill      = nil,               -- Disable blocky fill; show only line outline
    -- outline_px     = 2,                 -- outline thickness for normal minimap mode
    -- outline_px_fullscreen = 1,          -- outline thickness for fullscreen mode (thinner)
    -- Make baked outline thicker so butted walls look seamless on the minimap sprite.
    export_outline_px = 3,

    -- player marker
    player_rgba    = vmath.vector4(1.00, 0.92, 0.20, 1.00), -- keep visible
    player_px      = 6,
    player_fullscreen_px = 8,
    custom_markers = {
        max_count = 20,
        size_px = 6,
        rgba = vmath.vector4(0.95, 0.65, 0.25, 0.9),
    },
    -- How to compute the marker position:
    --   'world' -> direct MapData world->sprite transform (no clamping/padding)
    --   'room'  -> per-room relative position mapped into room rect
    player_position_mode = 'world',
    -- Adjust player Y by half a tile so the minimap marker tracks the character's visual center
    -- Set to false if your player pivot is already centered
    player_apply_tile_half_height = true,
    -- World-space calibration applied before mapping to the sprite.
    -- Keep X at 0: the player's collision box is X-centered on the root, so any
    -- constant X shift creates an asymmetric wall gap (dot biased toward one wall).
    -- Y stays nudged upward to better match the player on slopes.
    player_world_offset_px = { x = 0, y = 6 },
    -- GUI-only visual offset of the marker (X must stay 0; see note above)
    player_offset_px = { x = 0, y = 13 }, -- panel/normal mode offset
    player_offset_fullscreen_px = { x = 0, y = 10 }, -- fullscreen-only adjustment
    -- Wall-contact remap: inside the current room, stretch the marker's X so the
    -- dot's edge touches the baked wall outline exactly when the player's
    -- collision box (half-width = player_half_width_px world px) touches a wall.
    -- outline_inset_sprite_px keeps the dot flush with the INNER edge of the
    -- baked 3px wall line (the line straddles the room edge by 1.5 sprite px).
    player_wall_contact = {
        enabled = true,
        player_half_width_px = 15,   -- from developer/game/player/collisionobject.collisionobject (box half-extent x)
        outline_inset_sprite_px = 1.5,
    },

    -- Freeze behavior settings - controls when the player marker locks during door transitions
    enable_freeze = false,                 -- master switch: disable all freeze/snap behavior
    freeze_min_duration_sec = 0.5,         -- minimum time freeze stays active (prevents flickering)
    freeze_release_distance_px = 180,      -- distance from ALL seams required to release freeze
    freeze_movement_distance_px = 160,     -- distance from freeze point required to release freeze
    freeze_quick_release_after_room_change = true, -- allow faster release after room transitions

    -- Door-specific freeze settings (more precise than room boundary detection)
    use_door_based_freeze = false,         -- use exact door positions instead of room boundaries (100% accurate)
    door_freeze_depth_px = 0,              -- freeze once the player overlaps the door seam (0 uses minimum tolerance)
    door_freeze_min_depth_px = 12,         -- fallback tolerance (px) when depth <= 0 so seams still trigger
    door_release_distance_px = TILE_PX,    -- stay frozen until one tile from the seam (roughly one tile past the doorway)
    door_freeze_trigger_px = 64,           -- trigger freeze when within this many px of the seam (guarantees capture even if depth=0)
    door_proximity_radius_px = 256,        -- only consider doors within this radius of the player
    door_player_room_margin_px = 96,       -- margin when checking if the player is inside a room for door scans
    door_neighbor_margin_px = 256,         -- consider nearby rooms within this distance for door scans
    door_boundary_tolerance_px = TILE_PX,  -- tolerance when matching player position to door overlap bounds
    door_horizontal_band_px = TILE_PX,     -- require player to be within this vertical band around horizontal doors
    door_freeze_allow_vertical = false,    -- disable vertical (top/bottom) door freezes for minimap alignment

    -- camera/scale
    zoom           = 2.0,             -- slight zoom-out for more context
    fullscreen_zoom = 1.0,            -- multiplier applied in fullscreen mode (set <1 to zoom out)
    fullscreen_fit = "contain",       -- "contain" keeps full atlas inside view, scales to fit screen
    auto_zoom = {
        enabled = true,
        reference_width_px = 480,
        reference_height_px = 220,
        exponent = 1.0,
        min_zoom = 0.9,
        max_zoom = 2.5,
        fullscreen_min_zoom = 1.1,
        fullscreen_max_zoom = 2.8,
    },
    follow_player  = true,               -- try to keep player centered
    clamp_to_world = false,              -- clamp view so rooms stay within the panel when possible

    -- view window configuration (moved from gui_script defaults)
    follow = {
        window = {
            mode   = "fraction",     -- "fraction" | "fixed"
            frac_w = 0.22,           -- fraction of world width shown (when mode="fraction")
            frac_h = 0.22,           -- fraction of world height shown
            fixed_w = nil,           -- absolute world width (when mode="fixed")
            fixed_h = nil,           -- absolute world height
        }
    },

    -- Panel clipping toggle
    clip_panel = true,                  -- clip all minimap content to the panel rectangle
    -- Use the baked map's world extents for coordinate mapping
    lock_world_to_mapdata = true,              -- use exported bounds/shifts for perfect scale match

    -- Map data overrides - set to nil to use layout_map.lua values
    map_width = nil,
    map_height = nil,
    map_world_min = nil,
    map_world_max = nil,
    map_scale = nil,

    -- Snap marker and map movement to the minimap's pixel grid
    pixel_snap = false,

    -- debug logging for minimap GUI transforms and first-door mapping per room
    debug = true,
}

return M

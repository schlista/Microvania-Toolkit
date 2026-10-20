-- developer/config/layout_editor_settings.lua
-- Settings (z22): simplifies snap style to S.snap.overlap (true=overlap, false=butt)
-- 2025-09-01

local Tile = require "developer.config.tile_settings"

local function scale_px(px)
    return (px * Tile.width) / 128
end

local S = {}

-- Core application settings
S.app_id                  = require("mvtk.core.save_paths").app_id("layout") -- Project-specific authoring saves
S.layout_filename         = "world_layout.json"     -- Main layout file containing room positions
S.auto_manifest_filename  = "rooms_auto"            -- Auto-generated manifest for room discovery

-- Canvas display and interaction settings
S.canvas = {
    margin_px  = 12,     -- Border padding around the canvas area (pixels)
    zoom       = 0.02,   -- Initial zoom level (1.0 = 100%)
    zoom_step  = 0.15,   -- Amount to zoom in/out per step
    zoom_min   = 0.015,   -- Minimum allowed zoom level (1% - for seeing very large maps)
    zoom_max   = 0.2,   -- Maximum allowed zoom level (225% - reduced from 800%)
    pixel_snap = true,   -- Enable pixel-perfect positioning
    spawn_columns = 3,        -- Grid columns used when auto-placing newly spawned rooms
    spawn_padding_px = 512,   -- Extra spacing (world units) reserved when testing spawn slots
    spawn_step_x_px = nil,    -- Optional override for horizontal spawn spacing (defaults to room width + padding)
    spawn_step_y_px = nil,    -- Optional override for vertical spawn spacing (defaults to room height + padding)
    show_zero_door_rooms = true, -- Flag rooms (UI) when no door geometry was found
}

-- UI layout settings
S.sidebar = {
    width_px = 280,      -- Width of the sidebar panel (pixels)
    list_offset_px = 70, -- Horizontal offset to align room entries relative to the header
}

-- Color palette (RGBA values 0.0-1.0)
S.palette = {
    text         = vmath.vector4(1,1,1,1),                -- White text color
    room_outline = vmath.vector4(0.80, 0.93, 0.99, 1.00), -- Light blue room borders
    room_fill    = vmath.vector4(0.12, 0.26, 0.33, 0.65), -- Dark blue-green room fill (with transparency)
}

-- Room rendering and preview settings
S.preview = {
    outline_thick_px        = 88,        -- Thickness of room outline borders (pixels)
    fill_step_px            = 8,         -- Step size for room fill pattern generation (pixels)
    fill_mode               = "precise", -- Fill algorithm mode ("texture", "precise", or "disabled" for no fill)
    fill_texture_scale       = 0.5,      -- Relative resolution for texture masks (1.0 = full native size)
    fill_texture_max_px      = 768,       -- Clamp maximum texture dimension per room (pixels)
    fill_texture_min_scale   = 0.15,      -- Minimum scale safeguard for very small rooms
    fill_texture_samples     = 9,         -- Coverage samples per texel for anti-aliased edges
    max_rects_per_room      = 2048,     -- Maximum rectangles to generate per room (performance limit)
    outline_extend_ratio    = 0.35,     -- How far outline extends beyond room bounds (ratio)
    join_len_max_factor     = 0.5,      -- Maximum length factor for joining outline segments
    fill_coverage_bias_px   = 1,        -- Bias adjustment for fill coverage calculations (pixels)
    room_label_scale        = 2.5,      -- Base GUI scale for room name labels (1.0 = default size)
    node_budget             = 1024,     -- Total GUI node budget for rendered rooms (higher if fills disappear)
    node_safe_margin        = 48,       -- Reserve nodes to avoid hitting the cap exactly
}

-- Door appearance and positioning settings
S.door = {
    open_rgba       = vmath.vector4(1.00, 0.92, 0.20, 1.0), -- Yellow color for open doors
    locked_rgba     = vmath.vector4(1.00, 0.00, 0.00, 1.0), -- Red color for locked doors
    contact_rgba    = vmath.vector4(1.00, 0.55, 0.10, 1.0), -- Orange color for doors that overlap between two rooms
    thickness_scale = 1.0,      -- Multiplier for door line thickness (reduced for narrower doors)
    extend_ratio    = 0.1,      -- How far door extends beyond its core segment (ratio)
    z_bias          = 0.02,      -- Small Z-offset to ensure doors render above room outlines
     
    -- Door positioning relative to the configured tile size
    seam_bias_px        = 0,     -- Keep walls flush when snapped; inset handled visually
    -- Door visual center bias: final inward inset = (outline_thick_px * thickness_scale) / 2 + this value.
    -- Positive moves the bar into the room; negative moves it toward the seam.
    door_position_offset = 10,  -- Move doors 10px inward toward room interior

    -- Visual inset for overlapping doors to show both when snapped
    overlap_inset_px = 0,   -- Snap maths stay aligned at the seam (visual push handled in render)
    overlap_visual_push_px = 65, -- Render-only: move snapped doors this many px into their room
    door_width_reduction = 00,  -- Reduce rendered door thickness by this many pixels
}

-- Locked door key marker settings (layout editor preview)
S.locked_key = {
    offset_px          = Tile.half_width + 64,     -- Distance from door center into the room
    shaft_len_px       = math.floor(Tile.width * 0.65), -- Length of key shaft
    shaft_thickness_px = 18,                       -- Thickness of the shaft bar
    head_size_px       = 52,                       -- Size of the square key head
    head_hole_px       = 22,                       -- Size of the cut-out inside the head
    z_offset           = 0.085,                    -- Z-bias so the key renders above doors
    head_rgba          = vmath.vector4(0.95, 0.97, 1.00, 0.92),
    shaft_rgba         = vmath.vector4(0.95, 0.97, 1.00, 0.92),
    hole_rgba          = vmath.vector4(0.05, 0.08, 0.12, 0.85),
}

-- Door snapping behavior settings
S.snap = {
    enabled             = true,  -- Enable/disable snapping functionality
    threshold_px        = scale_px(180),   -- Maximum distance for snap detection (pixels)
    center_tolerance_px = Tile.width,   -- Tolerance for door center alignment (pixels)

    -- Primary snap mode selection
    --   true  = doors perfectly overlap (walls aligned)
    --   false = doors butt edge-to-edge using edge_gap_px
    overlap            = true,

    -- Edge spacing when overlap=false
    edge_gap_px        = 0,      -- Gap between door edges: 0=touching, +N=gap, -N=slight overlap
    min_edge_gap_px    = -100, -- Allow up to 100px overlap (negative pulls rooms together)
    max_edge_gap_px    = 200,  -- Allow up to 200px separation when snapping

    -- Advanced snapping tolerances
    crossing_slack_px  = scale_px(200),    -- Allow doors to cross the snap seam and still snap (pixels)
    fallback_release_px = scale_px(480),     -- Fallback snap distance on release (0=disabled)
}

-- Room file discovery and loading settings
S.rooms_path            = "/developer/assets/tiled/maps"        -- Primary path to search for room files
S.rooms_path_candidates = { "/developer/assets/tiled/maps" }    -- List of paths to search (fallback support)
S.rooms_zero_pad        = 2                       -- Zero-pad room numbers (2 = "01", "02", etc.)
S.rooms_tilemap_ext     = ".tilemap"              -- File extension for room tilemap files

print(string.format(
"[LE.Settings] outline=%.2f door.scale=%.2f seam_bias_px=%s snap.overlap=%s gap=%s (compat align_edges=%s mode=%s)",
S.preview.outline_thick_px,
S.door.thickness_scale,
tostring(S.door.seam_bias_px),
tostring(S.snap.overlap),
tostring(S.snap.edge_gap_px),
tostring(S.snap.align_edges),
tostring(S.snap.door_pair_mode)
))

return S

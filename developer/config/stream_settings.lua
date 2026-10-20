-- ============================================================================
-- developer/config/stream_settings.lua
-- ============================================================================
-- ROOM STREAMING CONFIGURATION
-- ============================================================================
--
-- This file controls how rooms are loaded, unloaded, and connected in your
-- Metroidvania world. The streaming system keeps nearby rooms loaded while
-- unloading distant ones to manage memory.
--
-- KEY CONCEPTS:
--   Room    - A single playable area (one Tiled map = one room)
--   Door    - A connection point between two rooms
--   Bounds  - The collision layer that defines room boundaries
--   Seam    - Where two rooms meet at a door connection
--
-- WORKFLOW:
--   1. Create rooms in Tiled with required layers (bounds, doors)
--   2. Export as Lua to developer/assets/tiled/maps/
--   3. Connect rooms in the Layout Editor
--   4. System auto-loads/unloads rooms as player moves
--
-- RELATED FILES:
--   tile_settings.lua     - Tile dimensions (used for door alignment)
--   game_config.lua       - High-level streaming settings
--   rooms_config.lua      - Per-room metadata and overrides
--
-- ============================================================================

local Tile = require "developer.config.tile_settings"

local S = {}

-- ============================================================================
-- TILED EXPORT AND GENERATED ROOM PATHS
-- ============================================================================
-- These paths tell runtime streaming, editor tools, and Tiled import helpers
-- where to find exported map files and generated room assets.

-- Directory containing Tiled Lua and tilemap exports.
-- Valid values: Defold resource directory path with leading and trailing slash.
-- Default: "/developer/assets/tiled/maps/"
S.tiled_maps_dir = "/developer/assets/tiled/maps/"

-- Directory containing generated room game objects and metadata.
-- Valid values: Defold resource directory path with leading and trailing slash.
-- Default: "/developer/rooms/generated/"
S.generated_rooms_dir = "/developer/rooms/generated/"

-- Resource path template for generated background-layer metadata.
-- Valid values: Defold resource path containing the literal "<room_id>" placeholder.
-- Default: "/developer/rooms/generated/<room_id>_backgrounds_meta.lua"
S.room_backgrounds_meta_template = "/developer/rooms/generated/<room_id>_backgrounds_meta.lua"

-- ============================================================================
-- ROOM DIMENSIONS & STREAMING
-- ============================================================================
-- Controls how rooms are measured and when they load/unload.

S.room = {
    -- Tile dimensions (inherited from tile_settings.lua)
    -- Change these in tile_settings.lua, not here
    tile_w = Tile.width,
    tile_h = Tile.height,

    -- Legacy axis settings, used only when preload_distance is absent.
    -- Their maximum selects the graph-distance preload radius below.
    -- Higher values use more memory; direct neighbors always stay loaded and
    -- visible once ready, preserving the world around the current room.
    --
    -- preload_x: Horizontal neighbors
    --   0 or 1 = current room plus direct neighbors
    --   2 = also preload rooms two connections away
    --
    -- preload_y: Combined with preload_x; connections may be on any side.
    preload_x = 1,
    preload_y = 1,

    -- Graph-distance radius around the current room. This is the preferred
    -- unified setting; preload_x/preload_y remain supported for older projects.
    -- 0 or 1 = current room plus direct neighbors (always loaded and visible).
    -- 2+ also preloads more distant rooms, which stay hidden until needed.
    -- Authored hidden layers and map discovery keep their own visibility.
    preload_distance = 1,

    -- Start preparing the next room's neighbor set while approaching a seam.
    -- Distance is in project tiles, capped at half the current room per axis.
    -- Uses actual motion and connected doors; only one route is predicted.
    -- Extra rooms stay hidden/disabled and undiscovered until normally needed.
    -- 0 disables lookahead. Higher values trade earlier work/memory for fewer
    -- first-visit seam stalls; whole-collection creation still uses the budget.
    lookahead_tiles = 8,

    -- Warm every published room's resources during the game's loading state.
    -- This avoids first-visit disk/GPU upload stalls during play. It loads
    -- resources only: room objects still stream with the budgets below.
    -- Costs extra startup time and memory for unvisited assets. Once a room
    -- is used, its resources return to the normal bounded cache. Set false
    -- for memory-constrained targets or worlds whose assets do not fit RAM.
    prewarm_resources_on_start = true,

    -- Maximum number of whole room collections created or scheduled for
    -- unload in one frame. Keep these at 1 to amortize seam traversal work.
    load_budget_per_frame = 1,
    unload_budget_per_frame = 1,

    -- Large room unloads delete this many root objects per frame.
    unload_delete_chunk_size = 24,

    -- Maximum simultaneous asynchronous room-resource loads (integer >= 1).
    -- Object creation still obeys load_budget_per_frame after loading finishes.
    resource_load_concurrency = 2,
    -- Keep resources for this many recently unloaded rooms (objects still
    -- unload normally). Avoids repeated texture/resource uploads when walking
    -- back through visited rooms. Oldest unused resources are evicted first;
    -- room-manager shutdown releases all. Set 0 for minimum memory. Larger values trade
    -- asset memory for fewer reload stalls; this counts rooms, not megabytes.
    resource_cache_rooms = 8,
    -- Additional ready rooms to retain outside the active/neighbor set.
    -- They stay disabled and hidden, avoiding whole-collection recreation
    -- when backtracking. Least recently shown rooms are evicted first. Set 0 to unload
    -- immediately; larger values use more gameobject/component memory.
    -- This is separate from the resource-only cache above. World reset clears it.
    inactive_room_cache = 4,
    -- Seconds before a load is reported as stuck. Defold cannot cancel a load;
    -- a late callback is drained before that factory can be loaded again.
    resource_load_timeout = 15,
    -- Failed loads retry this many times in total, with this delay in seconds.
    resource_load_attempts = 3,
    resource_retry_delay = 1,

    -- Keep all visited rooms in memory (no unloading)
    -- true  = All rooms stay loaded once visited (uses more memory)
    -- false = Distant rooms unload to save memory (recommended for large maps)
    --
    -- Set to true for:
    --   - Small maps with < 20 rooms
    --   - Development/debugging
    --   - When streaming causes issues
    --
    -- Set to false for:
    --   - Large maps (20+ rooms)
    --   - Memory-constrained platforms (mobile, web)
    --   - Production builds
    keep_all_loaded = false,
}

-- ============================================================================
-- ROOM PLACEMENT & SEAMS
-- ============================================================================
-- How rooms are positioned relative to each other at door connections.

S.placement = {
    -- Allow collision tiles to overlap at room seams
    -- false = Rooms butt up against each other (recommended)
    -- true  = Rooms can overlap, useful for special visual effects
    allow_wall_overlap = false,

    -- Gap between rooms at seams (pixels)
    -- Positive = push rooms apart (creates gap)
    -- Negative = pull rooms together (creates overlap)
    -- 0 = perfect seam (recommended)
    --
    -- Adjust this if you see visual gaps or overlaps at door transitions
    seam_gap_px = 0,
}

-- ============================================================================
-- BOUNDS LAYER CONFIGURATION
-- ============================================================================
-- How room boundaries are calculated from tilemap layers.
-- The bounds layer defines the playable area of each room.

S.bounds = {
    -- Layer names to scan for room boundaries
    -- These layers should contain collision tiles that form the room shape
    -- Multiple layers are merged to compute the overall bounds
    layers = { "bounds" },

    -- Minimum tile Y coordinate to consider when measuring bounds
    -- Tiled editors sometimes create stray tiles at negative coordinates
    -- Setting this to 0 makes the measured bottom match the playable floor
    --
    -- nil = No clamping, use all tiles
    -- 0   = Ignore negative Y tiles (recommended)
    -- N   = Ignore tiles below row N
    min_tile_y = 0,
}

-- ============================================================================
-- DOOR LAYER CONFIGURATION
-- ============================================================================
-- Door layers mark where rooms can connect to each other.
-- Each room should have these four layers (they can be empty if no door exists).

S.doors = {
    -- Layer names for door markers in each direction
    -- Paint ONE marker tile per doorway using a non-colliding tile
    --
    -- Example Tiled setup:
    --   1. Create layer "door_left" in your tilemap
    --   2. Paint a marker tile where the left door should be
    --   3. Use a tile that doesn't have collision (decoration tile)
    --   4. The marker's Y position determines door alignment
    layer_left   = "door_left",
    layer_right  = "door_right",
    layer_top    = "door_top",
    layer_bottom = "door_bottom",

    -- Door placement algorithm
    -- How rooms are aligned when connected at doors
    --
    -- "touch_only"       - Make door tiles touch, no additional alignment
    -- "touch_then_flush" - Touch doors, then align room edges (recommended)
    --
    -- touch_then_flush ensures rooms line up cleanly at transitions
    place_mode = "touch_then_flush",

    -- Per-direction position nudges (pixels)
    -- Fine-tune door alignment after automatic placement
    -- Use these to fix small visual misalignments
    --
    -- Example: If left doors are 2 pixels too high:
    --   nudge = { left = { x = 0, y = -2 }, ... }
    nudge = {
        left   = { x = 0, y = 0 },
        right  = { x = 0, y = 0 },
        top    = { x = 0, y = 0 },
        bottom = { x = 0, y = 0 },
    },

    -- Final position snap grid (pixels)
    -- After all alignment, snap room positions to this grid
    -- Helps ensure pixel-perfect alignment
    --
    -- 0 = No snapping (positions can be any value)
    -- N = Snap to N-pixel grid
    --
    -- Set to your tile size for cleanest alignment
    snap_grid = { x = 0, y = 0 },

    -- ========================================================================
    -- DOOR CARVING (Runtime collision removal)
    -- ========================================================================
    -- When rooms connect, collision tiles at the seam are removed
    -- This prevents invisible walls at door transitions

    carve = {
        -- Enable collision tile removal at door seams
        -- true  = Remove blocking tiles where doors connect (recommended)
        -- false = Leave collision tiles in place (may cause invisible walls)
        enabled = true,

        -- Layers to carve at door seams
        -- Any collision tiles in these layers at the door location are removed
        -- Include all layers that might have blocking tiles at doorways
        layers = { "bounds", "solid" },

        -- Also carve the primary walkable collision layer at horizontal doors
        -- true  = Remove solid collision tiles at left/right door seams
        -- false = Keep the walkable seam intact
        include_ground = true,

        -- Carve depth: how many tiles deep to carve from the seam
        -- 1 = Only tiles directly at the door (usually sufficient)
        -- 2 = Two tiles deep (for thick walls)
        depth_tiles = 1,
    },
}

-- ============================================================================
-- EXPORTS
-- ============================================================================
return S

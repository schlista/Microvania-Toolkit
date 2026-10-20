-- ============================================================================
-- developer/config/gameplay_constants.lua
-- ============================================================================
-- GAMEPLAY CONSTANTS
-- ============================================================================
--
-- This file contains low-level gameplay tuning constants used across multiple
-- systems. These are typically values that don't fit into more specific config
-- files but need to be configurable.
--
-- WHEN TO USE THIS FILE:
--   - Values used by multiple unrelated systems
--   - Engine-level constants that affect gameplay
--   - Fallback defaults when more specific configs are missing
--
-- FOR SPECIFIC SYSTEMS, USE THESE INSTEAD:
--   player_settings.lua    - Player movement, stats, abilities
--   combat_config.lua      - Combat damage, hitboxes, and timing
--   enemy_types.lua        - Enemy definitions
--   game_config.lua        - Master game settings
--
-- ============================================================================

return {
    -- =========================================================================
    -- AUDIO CONSTANTS
    -- =========================================================================
    -- Sound system timing and limits

    audio = {
        -- Minimum time between repeated sound effects (seconds)
        -- Prevents audio stuttering when same SFX triggers rapidly
        -- Lower = more responsive but risk of overlapping sounds
        -- Higher = cleaner but might miss rapid events
        -- Standard: 0.05 - 0.10
        default_sfx_cooldown = 0.08,

        -- Maximum concurrent sound effects playing
        -- Set based on target platform performance
        -- Desktop: 32-64, Mobile: 16-32
        max_concurrent_sfx = 32,

        -- Audio fade durations (seconds)
        music_fade_in = 1.0,
        music_fade_out = 0.5,
        ambient_fade = 0.3,
    },

    -- =========================================================================
    -- PLAYER CONSTANTS
    -- =========================================================================
    -- Low-level player physics and timing values
    -- For movement speeds and abilities, see player_settings.lua

    player = {
        -- Velocity epsilon for "stopped" detection
        -- Speeds below this are treated as zero
        -- Prevents jittering at rest
        eps = 0.5,

        -- Duration of parry counter-attack stun (seconds)
        -- How long enemies are stunned after player parries successfully
        -- Standard: 0.3 - 0.5
        parry_counter_stun = 0.40,

        -- Ground detection ray length (pixels below feet)
        -- Used to check if player is on ground
        ground_ray_length = 8,

        -- Wall detection ray length (pixels to side)
        -- Used for wall climb and wall jump detection
        wall_ray_length = 12,

        -- Minimum time between taking damage (invincibility frames)
        -- Configured per-system, this is the absolute minimum
        min_iframes = 0.1,

        -- Animation blend time defaults (seconds)
        -- Used when specific blend times aren't specified
        default_blend_time = 0.1,
        quick_blend_time = 0.05,
        slow_blend_time = 0.2,
    },

    -- =========================================================================
    -- ROOM / STREAMING CONSTANTS
    -- =========================================================================
    -- Level streaming and room transition timing

    rooms = {
        -- Distance from door before transition triggers (pixels)
        -- Player must be within this distance of door to transition
        -- Lower = need to be closer, Higher = trigger from further away
        -- Standard: 32 - 64
        transition_threshold = 50,

        -- Minimum time between room transitions (seconds)
        -- Prevents accidental rapid transitions
        transition_cooldown = 0.5,

        -- Fade duration for room transitions (seconds)
        fade_duration = 0.3,

        -- How long to wait before unloading distant rooms (seconds)
        -- Allows player to backtrack without reload
        unload_delay = 2.0,
    },

    -- =========================================================================
    -- PHYSICS CONSTANTS
    -- =========================================================================
    -- Low-level physics values (high-level in game_config.lua)

    physics = {
        -- Collision resolution iterations
        -- More = more accurate but slower
        -- Standard: 4-8
        collision_iterations = 4,

        -- Slope angle limits (degrees)
        -- Slopes steeper than this are treated as walls
        max_walkable_slope = 45,

        -- Platform drop-through time (seconds)
        -- How long player ignores one-way platforms after pressing down+jump
        platform_drop_time = 0.25,
    },

    -- =========================================================================
    -- COMBAT CONSTANTS
    -- =========================================================================
    -- For detailed combat config, see combat_config.lua

    combat = {
        -- Minimum time between enemy hits on player (seconds)
        -- Prevents instant death from overlapping hitboxes
        hit_cooldown = 0.1,

        -- Knockback friction (0-1)
        -- How quickly knockback velocity decays
        -- 0 = instant stop, 1 = no friction (slides forever)
        knockback_friction = 0.15,

        -- Poise recovery rate (per second) when not being hit
        -- Higher = recover stagger resistance faster
        poise_recovery_rate = 1.0,
    },

    -- =========================================================================
    -- UI CONSTANTS
    -- =========================================================================
    -- For theming and layout, see ui_theme.lua and hud_layout.lua

    ui = {
        -- Tooltip display delay (seconds)
        tooltip_delay = 0.5,

        -- Menu transition duration (seconds)
        menu_transition = 0.2,

        -- Popup message duration (seconds)
        popup_duration = 3.0,

        -- Button repeat delay (seconds)
        -- Initial delay before repeat when holding direction
        repeat_delay = 0.4,

        -- Button repeat rate (seconds)
        -- Time between repeats after initial delay
        repeat_rate = 0.08,
    },

    -- =========================================================================
    -- TILE CONSTANTS
    -- =========================================================================
    -- For tile dimensions, see tile_settings.lua
    -- These are derived/related values

    tiles = {
        -- Collision margin (pixels)
        -- Small buffer to prevent getting stuck in walls
        collision_margin = 1,

        -- Tile lookup cache size
        -- Number of recent tile lookups to cache
        cache_size = 256,
    },
}

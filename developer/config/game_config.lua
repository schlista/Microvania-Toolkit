-- ============================================================================
-- developer/config/game_config.lua
-- ============================================================================
-- MASTER GAME CONFIGURATION FILE
-- ============================================================================
--
-- This is the SINGLE SOURCE OF TRUTH for all game-wide configuration.
-- All settings a developer might want to change should be here or in a
-- specialized config file (player_settings.lua, enemy_types.lua, etc.)
--
-- CONFIGURATION HIERARCHY (priority order):
--   1. Tiled Properties - Per-object overrides in your Tiled maps
--   2. Project > Game Settings... - Project-owned creator_settings.lua overrides
--   3. This Config File - Default values for everything
--   4. MVTK Defaults    - Fallbacks if config files are missing (never edit)
--
-- HOW TO USE:
--   - Edit values in this file to change game behavior
--   - Choose Project > Game Settings... in Defold for guided configuration
--   - Use Tiled custom properties for per-instance overrides
--   - NEVER edit files in the mvtk/ folder
--
-- RELATED CONFIG FILES:
--   player_settings.lua    - Player movement, stats, abilities
--   enemy_types.lua        - Enemy definitions and behaviors
--   combat_config.lua      - Attack types and damage
--   hazard_types.lua       - Spikes, lava, pits, etc.
--   abilities.lua          - Ability metadata and unlock states
--   items.lua              - Collectible item definitions
--   ui_theme.lua           - Colors, fonts, HUD layout
--   sound_bank.lua         - Audio IDs and settings
--
-- ============================================================================

local Config = {}

-- ============================================================================
-- BUILD & VERSION
-- ============================================================================
-- These values identify your game build and save format.

Config.build = {
    -- Game version string (shown in menus, logs)
    -- Format: major.minor.patch (e.g., "1.0.0", "0.5.2")
    version = "0.1.0",

    -- Save format version number
    -- IMPORTANT: Increment this when you change save data structure
    -- Old saves with different versions may need migration
    save_version = 1,

    -- Build type identifier ("dev", "alpha", "beta", "release")
    -- Used for session logging
    build_type = "dev",
}

-- ============================================================================
-- DEBUG FLAGS
-- ============================================================================
-- Master switches for debug features. Set all to false for release builds.
-- For fine-grained debug control, see debug_config.lua

Config.debug = {
    -- Master switch for ALL debug output
    -- When false, suppresses most debug prints regardless of other flags
    prints = false,

    -- Draw collision bounds, room boundaries, trigger zones
    draw_bounds = false,

    -- Show physics debug visualization
    physics_debug = false,

    -- Enable debug overlay (F1 key)
    overlay_enabled = true,

    -- Show FPS counter in debug builds
    show_fps = false,

    -- Allow debug teleport commands
    teleport_enabled = true,

    -- Log room transitions and streaming events
    room_logging = false,
}

-- ============================================================================
-- WINDOW & RENDERING
-- ============================================================================
-- Display settings for your game window.

Config.window = {
    -- Base resolution for UI layout calculations
    -- This is your "virtual" resolution - UI elements scale from this
    -- Common values: 320x180, 384x216, 480x270, 640x360, 960x540
    base_width = 960,
    base_height = 640,

    -- Target window size when running in windowed mode
    -- The actual size will be clamped to fit the display
    target_width = 1920,
    target_height = 1080,

    -- Aspect ratio behavior
    -- "letterbox" - Black bars to maintain ratio
    -- "stretch"   - Stretch to fill (may distort)
    -- "expand"    - Show more of the world on wider screens
    aspect_mode = "letterbox",

    -- Default window mode on first launch
    -- "windowed", "fullscreen_windowed", "fullscreen"
    default_mode = "windowed",
}

-- ============================================================================
-- VISUAL TOGGLES
-- ============================================================================
-- Global visual feature switches.

Config.visual = {
    -- Enable parallax background layers
    -- Set to false to disable all parallax for performance or starter art
    parallax_enabled = false,

    -- Screen shake effects
    screen_shake_enabled = true,

    -- Damage number popups
    damage_numbers_enabled = true,

    -- Hit flash effect on damaged entities
    hit_flash_enabled = true,

    -- Particle effects
    particles_enabled = true,

    -- Weather effects (rain, snow, etc.)
    weather_enabled = true,

    -- Darkness overlay (0 = none, 0.9 = nearly black) used for a room whose
    -- Tiled map has no `darkness` property, and before a room registers one.
    -- A map's `darkness` property always overrides this.
    default_room_darkness = 0.0,
}

-- ============================================================================
-- PHYSICS
-- ============================================================================
-- Engine-level physics values. The player uses kinematic physics,
-- so these mainly affect physics-based objects and particles.

Config.physics = {
    -- World gravity (pixels per second squared)
    -- Standard platformer gravity is around -1200 to -3000
    -- Negative = downward
    gravity_y = -1200,

    -- Terminal velocity (maximum fall speed)
    -- Prevents infinite acceleration during long falls
    -- Negative = downward
    max_fall_speed = -12000,

    -- Physics simulation rate
    -- Higher = more accurate but slower
    -- Standard: 60
    fixed_timestep = 60,
}

-- ============================================================================
-- PLAYER SPAWN & RESPAWN
-- ============================================================================
-- Where the player starts and respawns.

Config.player = {
    -- Player rendering type
    -- "sprite" - Uses traditional flipbook animation (the shipped default).
    -- "spine"  - Uses the optional Spine add-on. You need your own Spine Editor
    --            license; run Project > Spine Add-on... > Turn On and follow
    --            its library-refresh instructions before Prepare & Check.
    -- See developer/addons/spine/README.md for rig and animation setup.
    player_type = "sprite",

    -- ------------------------------------------------------------------
    -- SPINE-BONE-DRIVEN PHYSICS (only active when player_type == "spine")
    -- ------------------------------------------------------------------
    -- When enabled, the player's environment / damage / sensor collision is
    -- driven by sibling collision GOs that follow individual Spine bones
    -- (body, feet, head) instead of the legacy single offset box (`#co`).
    --
    -- This eliminates the left/right collision asymmetry caused by the
    -- legacy collider's Y offset combining with parent transforms used
    -- for facing flips.
    --
    -- This flag is read ONCE at player init. Mid-session toggling is not
    -- supported in v1; change the value and respawn / restart for it to
    -- take effect.
    --
    -- Sprite mode is never affected by anything in this block.
    spine_physics = {
        -- Master toggle. Only takes effect when player_type == "spine".
        -- Set to false to fall back to the legacy `#co` collider while
        -- still rendering with Spine.
        enabled = true,

        -- Per-part Spine bone names. Override these if your rig uses
        -- different bone names than the bundled toolkit rig. Player-settings
        -- values take precedence so Game Settings overrides remain the
        -- creator-facing source of truth.
        -- The relay script reads bone world position each frame and
        -- positions the matching collider at that point.
        bone_map = {
            body   = "waist",      -- Body / damage hurtbox follows this bone
            foot_l = "foot_far",   -- Far foot terrain probe
            foot_r = "foot_near",  -- Near foot terrain probe
            head   = "head",       -- Head ceiling-bonk probe
        },

        -- Per-part on/off. Disable a part to skip its collider entirely.
        -- The body hurtbox is the sole damage / sensor router; disabling
        -- it will stop the player from taking damage or interacting with
        -- pickups, ladders, water, etc. Only disable for testing.
        enable_parts = {
            body   = true,
            foot_l = true,
            foot_r = true,
            head   = true,
        },

        -- How many frames the bone collider relay script will retry
        -- resolving its Spine bone via spine.get_go() before giving up.
        -- On exhaustion the script logs ONE warning per missing part and
        -- disables that collider. Misnamed bones fail loudly, not silently.
        bone_resolve_max_retries = 30,

        -- When true, draws debug AABBs for each enabled bone collider and
        -- ground / wall / ceiling raycasts each frame. Off by default.
        debug_draw = false,
    },

    -- Starting room for new games. Leave this commented out: the game starts
    -- in the room that holds your Tiled player_start object, and without one,
    -- in the first room of the exported layout. To force a room instead,
    -- uncomment the line and give that room's collection path. It is used
    -- only when the room exists in the layout.
    -- spawn_room = "developer/rooms/my_first_room",
    spawn_marker = "spawn_a",

    -- Force a fixed spawn position (for testing only)
    -- ALWAYS set enabled = false for release builds!
    force_spawn = {
        enabled = false,  -- Set to true for quick testing
        x = 300,          -- World X position
        y = 400,          -- World Y position
    },

    -- Respawn behavior after death
    respawn = {
        -- Where to respawn after death
        -- "checkpoint" - Last activated save point
        -- "room_start" - Beginning of current room
        -- "death_spot" - Where player died (souls-like)
        mode = "checkpoint",

        -- Invincibility time after respawn (seconds)
        iframes = 2.0,

        -- Fade transition duration (seconds)
        fade_duration = 0.5,
    },

    -- Optional player animation remaps.
    -- Keys are the gameplay animation ids requested by the toolkit.
    -- Values are the atlas/Spine animation ids that should play instead.
    -- Leave this empty to keep the default mappings.
    --
    -- This is the main "opt in" hook for the imported sprite pack extras.
    -- Example values:
    --   idle = "sword_idle"
    --   run = "sword_run"
    --   climb = "climb_facing_back_of_player"
    --   punch = "punch_jab"
    --   weapon_attack = "sword_stab"
    --   shoot = "shooting_two_handed"
    --
    -- Values are canonicalized at runtime, so imported folder labels such as
    -- "Climb (facing back of player)" also work.
    animation_overrides = {
    },

    -- ------------------------------------------------------------------
    -- WATER & SWIMMING
    -- ------------------------------------------------------------------
    -- Gating and in-water gravity live here. Swimming physics itself lives in
    -- swim_settings.lua so individual water volumes can override it safely.
    swim = {
        enabled = true,              -- Master switch for in-water behaviour
        require_ability = true,      -- false = anyone can swim (no gate)
        ability_id = "swim",         -- ID in developer/config/abilities.lua
        gravity_mult = 0.35,         -- Multiplies gravity while in water
        max_fall_speed = 220,        -- Clamps downward speed while in water
        no_swim_sink_speed = 220,    -- Forced sink speed without the ability
        no_swim_horizontal_mult = 0, -- 0 = locked; 1 = full horizontal control
        drown_damage = 1,            -- Damage per drowning tick (oxygen empty)
        drown_damage_interval = 1.0, -- Seconds between drowning ticks
        surface_jump_out = true,     -- Jump near the surface exits the water
        surface_jump_band = 24,      -- Pixels below the surface for jump-out
        surface_jump_boost = 1.0,    -- Multiplier on normal jump speed
    },
}

-- ============================================================================
-- CAMERA
-- ============================================================================
-- Camera follow behavior and transitions.

Config.camera = {
    -- Snap the rendered camera to screen pixels while preserving fractional
    -- simulation state. Disable for smooth non-pixel-art rendering.
    pixel_snap = true,

    -- Dead zone: player can move this far without camera following
    -- Set to 0,0 for instant/locked follow
    -- Higher values = more "loose" feeling
    -- Defaulted to 0,0 for instant follow during early tuning (override per project)
    deadzone = { x = 0, y = 0 },

    -- Look-ahead: camera shifts in movement direction
    -- Creates a sense of seeing where you're going
    -- Set to 0 to disable
    -- Disabled by default for precise camera tests (override per project)
    lookahead = { x = 0 },

    -- Follow speed: how fast camera catches up
    -- Higher = snappier, Lower = more cinematic lag
    -- Range: 1.0 (very slow) to 99.0 (near instant)
    -- Fast snap-follow for testing; reduce for cinematic follow
    speed = { x = 99.0, y = 99.0 },

    -- Respawn camera behavior
    -- true = snap instantly to player on respawn
    -- false = smooth lerp to player position
    snap_on_respawn = true,

    -- Lerp time when snap_on_respawn is false (seconds)
    respawn_lerp_time = 0.20,

    -- Camera parenting mode
    -- pull_from_go: Read player position each frame
    -- parent_to_player: Camera is child of player GO (most robust)
    pull_from_go = true,
    parent_to_player = true,

    -- Fixed offset from player center
    offset = { x = 0, y = 0 },

    -- Default zoom level (1.0 = 100%, 0.9 = slightly zoomed out)
    -- Adjusts how much of the world is visible
    default_zoom = 1.0,

    -- Maximum arena auto-fit zoom as a multiplier of default_zoom (unitless).
    -- Safe range: 1..8. Above 1 lets small locked arenas zoom in while the
    -- full arena remains visible; 2 allows twice the project's normal zoom.
    arena_max_zoom = 2.0,

    -- Rooms smaller than the screen. true zooms the camera in until the room
    -- fills the view, so no empty space shows past the room's edges; false
    -- keeps the normal zoom and centres the room. It applies on top of a
    -- camera zone's zoom_level. Boss arenas use auto-fit instead.
    fill_small_rooms = true,

    -- Most fill_small_rooms may zoom in, as a multiplier of default_zoom
    -- (unitless). Safe range: 1..4. A room needing more stays centred here.
    small_room_max_zoom = 2.0,

    -- Vertical look (when player holds up/down)
    look_y_enabled = true,
    look_y_amount = 64,       -- Pixels to shift camera
    look_y_delay = 0.3,       -- Seconds before look activates
    look_y_speed = 100,       -- Pixels per second
}

-- ============================================================================
-- PERFORMANCE
-- ============================================================================
-- Frame pacing controls (mvtk/core/frame_clock.lua).

Config.performance = {
    -- false (recommended): preserve the engine's elapsed time for movement.
    -- This keeps player/camera motion on the same clock as bosses and timers.
    -- true: experimental rounding within 3% of common refresh intervals.
    -- A single dt cannot distinguish measurement noise from a genuinely
    -- late frame; rounding can introduce speed changes and simulation drift.
    -- Enable only after measuring that it improves your particular display.
    dt_snap = false,
}

-- ============================================================================
-- INPUT
-- ============================================================================
-- Input handling configuration.

Config.input = {
    -- Analog stick deadzone (0.0 to 1.0)
    -- Inputs below this threshold are ignored
    -- Standard: 0.2-0.3
    deadzone = 0.25,

    -- Input buffering: how long button presses are remembered
    -- Allows inputs during animations to execute when available
    jump_buffer = 0.12,      -- Jump input buffer
    attack_buffer = 0.15,    -- Attack input buffer
    action_buffer = 0.10,    -- General action buffer

    -- Coyote time: grace period after leaving platform
    -- Player can still jump for this long after walking off edge
    coyote_time = 0.08,
}

-- ============================================================================
-- FAST TRAVEL
-- ============================================================================
-- Teleportation and fast travel settings.

Config.fast_travel = {
    -- Allow teleporting to discovered points from map menu
    allow_menu_travel = true,

    -- Cost to fast travel (currency units, 0 = free)
    travel_cost = 0,

    -- Require all enemies cleared in current room to travel
    require_clear = false,

    -- Animation/transition duration (seconds)
    transition_time = 0.5,
}

-- ============================================================================
-- PROGRESSION & DEATH PENALTIES
-- ============================================================================
-- Currency and death consequences.

Config.progression = {
    -- Death reloads the last save, including its currency, inventory and flags.
    death = {
        -- Optional currency drop at the last safe grounded position in the death
        -- room. Off restores all loot from the last save without a penalty and
        -- leaves any previous drop dormant. Without safe ground, no loss is
        -- charged and a previous drop is preserved. An eligible death replaces
        -- that drop, including clearing it when the computed loss is zero.
        -- Currency and the drop record are saved immediately; unrelated saved
        -- inventory and flags retain their restored values.
        drop_enabled = false,

        -- Fraction of restored saved currency to drop (0.0..1.0), rounded down.
        -- Example: 0.20 drops 20% before the minimum/maximum bounds below.
        currency_loss_fraction = 0.20,

        -- Minimum amount to drop. The loss is always capped by held currency.
        min_loss = 0,

        -- Maximum amount to drop; 0 leaves the maximum uncapped.
        max_loss = 0,

        -- Drop lifetime in seconds; 0 stays until collected or replaced.
        drop_lifetime = 0,

        -- Pickup radius in world pixels, independent of player scale.
        drop_pickup_radius = 16,

        -- Sound-bank ID played when the player recovers the dropped currency.
        drop_sound = "collect_gem",
    },

    -- Save system settings
    saves = {
        -- Maximum save slots available
        max_slots = 3,

        -- Enable auto-save feature
        autosave_enabled = true,

        -- Seconds between wall-clock auto-saves. Set to 0 to rely on
        -- checkpoint/progression event saves and avoid mid-gameplay disk hitches.
        autosave_interval = 0,

        -- Auto-save on room transitions
        autosave_on_room_change = true,

        -- Auto-save whenever a collectible is picked up
        -- true = save after every collectible pickup
        -- false = collectible pickups never trigger a save
        autosave_on_collectible_pickup = false,
    },

}

-- ============================================================================
-- ELITE ENEMY VARIANTS
-- ============================================================================
-- When enemies are marked as "elite" in Tiled, these multipliers apply.
-- Elite enemies are stronger versions of normal enemies.

Config.elite = {
    -- Health multiplier for elite enemies
    -- 2.0 = double health
    health_mult = 2.0,

    -- Damage multiplier for elite enemies
    -- 1.5 = 50% more damage
    damage_mult = 1.5,

    -- Speed multiplier for elite enemies
    -- 1.0 = same speed, 1.2 = 20% faster
    speed_mult = 1.0,

    -- Drop rate multiplier for elite enemies
    -- 2.0 = double drop chance
    drop_mult = 2.0,

    -- Visual indicator scale (relative to normal)
    -- 1.2 = 20% larger
    scale_mult = 1.2,

    -- Tint color for elite enemies (RGBA, nil = no tint)
    -- Example: { 1.0, 0.8, 0.3, 1.0 } for golden tint
    tint = nil,
}

-- ============================================================================
-- ROOM STREAMING
-- ============================================================================
-- How rooms are loaded and unloaded as player moves.

Config.streaming = {
    -- Preload adjacent rooms in each direction
    -- Higher = smoother transitions but more memory
    preload_x = 1,  -- Horizontal neighbors
    preload_y = 1,  -- Vertical neighbors

    -- Keep all visited rooms in memory
    -- true = no streaming, all rooms stay loaded (more memory)
    -- false = unload distant rooms (recommended for large maps)
    keep_all_loaded = false,

    -- Room transition threshold (pixels)
    -- How close to door before triggering transition
    transition_threshold = 50,
}

-- ============================================================================
-- DAMAGE NUMBERS
-- ============================================================================
-- Floating damage number display settings.

Config.damage_numbers = {
    -- Show damage dealt to enemies
    show_enemy_damage = true,

    -- Show damage taken by player
    show_player_damage = true,

    -- Show healing numbers
    show_healing = true,

    -- Show critical hit indicator
    show_crits = true,

    -- Display duration (seconds)
    duration = 0.8,

    -- Rise speed (pixels per second)
    rise_speed = 100,

    -- Font size multiplier
    font_scale = 1.0,

    -- Critical hit color (RGBA)
    crit_color = { 1.0, 0.9, 0.1, 1.0 },  -- Yellow

    -- Healing color (RGBA)
    heal_color = { 0.2, 1.0, 0.2, 1.0 },  -- Green

    -- Enemy damage color (RGBA)
    enemy_color = { 1.0, 1.0, 1.0, 1.0 }, -- White

    -- Player damage color (RGBA)
    player_color = { 1.0, 0.3, 0.3, 1.0 }, -- Red
}

-- ============================================================================
-- HIT FEEDBACK
-- ============================================================================
-- Visual and audio feedback when attacks connect.

Config.hit_feedback = {
    -- Hitstop: brief pause when attacks connect
    -- Creates impact feeling
    hitstop_enabled = true,
    hitstop_duration = 0.05,  -- Seconds

    -- Screen shake on hit
    shake_enabled = true,
    shake_intensity = 3,       -- Pixels
    shake_duration = 0.1,      -- Seconds

    -- Controller rumble on hit
    rumble_enabled = true,
    rumble_intensity = 0.3,    -- 0.0 to 1.0
    rumble_duration = 0.1,     -- Seconds

    -- Hit flash (white flash on damaged sprite)
    flash_enabled = true,
    flash_duration = 0.08,     -- Seconds
    flash_color = { 1.0, 1.0, 1.0, 1.0 },  -- White
}

-- ============================================================================
-- ATTACK HITBOX CONFIGURATION
-- ============================================================================
-- Default values for spawned attack hitboxes.
-- Individual attacks can override these in combat_config.lua

Config.attack_hitbox = {
    -- Light melee attack defaults
    light = {
        offset_x = 48,          -- Horizontal offset from player (pixels)
        offset_y = 10,          -- Vertical offset from player (pixels)
        lifetime = 0.58,        -- Hitbox active window
        stun_t = 0.12,          -- Enemy stun duration on hit (seconds)
    },

    -- Heavy melee attack defaults
    heavy = {
        offset_x = 60,          -- Horizontal offset
        offset_y = 20,          -- Vertical offset
        lifetime = 1.5,        -- Hitbox active window
        stun_t = 0.25,          -- Enemy stun duration
    },

    -- Down strike attack defaults
    down_strike = {
        offset_y = -32,         -- Below player
        lifetime = 0.18,        -- Short hitbox
        stun_t = 0.15,          -- Stun duration
    },
}

-- ============================================================================
-- ALLY ALERT SYSTEM
-- ============================================================================
-- Enemies can alert nearby allies when they detect the player.

Config.enemy_coordination = {
    -- Default detection range for alerting allies (pixels)
    ally_detection_range = 200,

    -- Cooldown between alerts (seconds)
    -- Prevents spam when player enters/exits range repeatedly
    alert_cooldown = 3.0,

    -- Enable group attack coordination
    -- When enabled, groups of enemies coordinate their attacks
    group_coordination = true,
}

-- ============================================================================
-- DEFAULT GO PROPERTIES
-- ============================================================================
-- Default values for Defold go.property() fields.
-- MVTK scripts use these when no config override is specified.
-- These match the go.property() defaults in mvtk/ scripts.

Config.go_defaults = {
    -- Camera defaults (camera.script)
    camera = {
        deadzone_x = 80,
        deadzone_y = 40,
        lookahead_x = 0,
        offset_x = 0,
        offset_y = 0,
        speed_x = 4.0,
        speed_y = 4.0,
        snap_on_respawn = 0,
        respawn_lerp_time = 0.20,
        look_y_amount = 64,
    },

    -- Enemy defaults (enemy.script)
    enemy = {
        max_health = 3,
        speed = 100,
        contact_damage = 1,
        contact_knockback_px = 220,
        poise_threshold = 2,
        poise_recover_per_s = 1,
        knockback_mult = 1,
        patrol_width = 64,
        patrol_height = 48,
    },

    -- Player defaults (player.script)
    player = {
        collider_half_height = 31,
        collider_half_width = 24,
        foot_floor_adjust = -8,
    },
}

-- ============================================================================
-- EXPORTS
-- ============================================================================
return Config
